#!/usr/bin/env python3
"""Black-box KYZU JSONL protocol tests.

Zero third-party dependencies. Intended to run against an already-built deployment.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Optional


class TimeoutError(RuntimeError):
    pass


class KyzuProcess:
    def __init__(self, binary: Path, workdir: Path, startup_timeout: float = 8.0):
        self.binary = binary
        self.workdir = workdir
        self.startup_timeout = startup_timeout
        self.proc: Optional[subprocess.Popen[str]] = None
        self._pending: List[Dict[str, Any]] = []

    def start(self) -> None:
        creationflags = 0
        if os.name == "nt":
            creationflags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        self.proc = subprocess.Popen(
            [str(self.binary)],
            cwd=str(self.workdir),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            creationflags=creationflags,
        )
        deadline = time.monotonic() + self.startup_timeout
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                stderr = self.proc.stderr.read() if self.proc.stderr else ""
                raise AssertionError(f"KYZU exited during startup ({self.proc.returncode}): {stderr[:2000]}")
            msg = self._read_one(timeout=0.25)
            if msg is not None:
                self._pending.append(msg)
                if msg.get("topic") == "game.tick":
                    return
        raise TimeoutError("KYZU did not emit game.tick during startup")

    def stop(self) -> None:
        if not self.proc:
            return
        if self.proc.poll() is None:
            try:
                if os.name == "nt":
                    self.proc.send_signal(signal.CTRL_BREAK_EVENT)
                    self.proc.wait(timeout=2)
                else:
                    self.proc.terminate()
                    self.proc.wait(timeout=2)
            except Exception:
                self.proc.kill()
                self.proc.wait(timeout=2)
        self.proc = None

    def send_raw(self, line: str) -> None:
        if not self.proc or not self.proc.stdin:
            raise RuntimeError("KYZU is not running")
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def send(self, topic: str, payload: Optional[Dict[str, Any]] = None) -> None:
        self.send_raw(json.dumps({"topic": topic, "payload": payload or {}}, separators=(",", ":")))

    def recv(self, topic: Optional[str] = None, timeout: float = 2.0) -> Dict[str, Any]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for i, msg in enumerate(self._pending):
                if topic is None or msg.get("topic") == topic:
                    return self._pending.pop(i)
            msg = self._read_one(timeout=max(0.01, min(0.25, deadline - time.monotonic())))
            if msg is not None:
                if topic is None or msg.get("topic") == topic:
                    return msg
                self._pending.append(msg)
        raise TimeoutError(f"Timed out waiting for topic {topic!r}")

    def ping(self, timeout: float = 2.0) -> float:
        started = time.perf_counter()
        self.send("game.cmd.ping")
        self.recv("game.event.pong", timeout)
        return time.perf_counter() - started

    def _read_one(self, timeout: float) -> Optional[Dict[str, Any]]:
        if not self.proc or not self.proc.stdout:
            return None
        # The test suite is intentionally single-threaded. KYZU is line-buffered on
        # stdout, so the portable way to avoid blocking forever is select() on POSIX
        # and a small helper thread on Windows.
        if os.name != "nt":
            import select
            ready, _, _ = select.select([self.proc.stdout], [], [], timeout)
            if not ready:
                return None
            line = self.proc.stdout.readline()
        else:
            import queue
            import threading
            if not hasattr(self, "_stdout_queue"):
                self._stdout_queue = queue.Queue()
                def reader() -> None:
                    assert self.proc is not None and self.proc.stdout is not None
                    for line in self.proc.stdout:
                        self._stdout_queue.put(line)
                threading.Thread(target=reader, daemon=True).start()
            try:
                line = self._stdout_queue.get(timeout=timeout)
            except queue.Empty:
                return None
        if not line:
            return None
        try:
            obj = json.loads(line)
        except json.JSONDecodeError as exc:
            raise AssertionError(f"KYZU emitted invalid JSON: {line[:500]!r}: {exc}") from exc
        if not isinstance(obj, dict):
            raise AssertionError(f"KYZU emitted non-object JSON: {obj!r}")
        return obj


def assert_equal(actual: Any, expected: Any, label: str) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


def payload(msg: Dict[str, Any]) -> Dict[str, Any]:
    raw = msg.get("payload", {})
    if isinstance(raw, str):
        parsed = json.loads(raw)
    else:
        parsed = raw
    if not isinstance(parsed, dict):
        raise AssertionError(f"payload is not an object: {parsed!r}")
    return parsed


def run_suite(binary: Path, workdir: Path, isolated: bool) -> int:
    temp_root: Optional[tempfile.TemporaryDirectory[str]] = None
    launch_dir = workdir
    launch_binary = binary
    if isolated:
        temp_root = tempfile.TemporaryDirectory(prefix="kyzu-test-")
        launch_dir = Path(temp_root.name) / "deployment"
        shutil.copytree(workdir, launch_dir)
        launch_binary = launch_dir / binary.name

    k = KyzuProcess(launch_binary, launch_dir)
    results: List[str] = []
    try:
        k.start()
        results.append("startup/game.tick")

        # Basic protocol and latency baseline.
        baseline = k.ping()
        if baseline > 1.0:
            raise AssertionError(f"baseline ping took {baseline:.3f}s")
        results.append("ping round-trip")

        # Malformed input must not silently kill the stdin reader.
        k.send_raw("{ definitely not json")
        time.sleep(0.05)
        k.ping()
        results.append("malformed JSON resilience")

        # Geographic bounds should reject rather than clamp into the edge cells.
        for lon, lat in ((181.0, 0.0), (-181.0, 0.0), (0.0, 91.0), (0.0, -91.0)):
            unit_id = f"bounds-{lon}-{lat}"
            k.send("game.cmd.spawn", {"unit_id": unit_id, "lon": lon, "lat": lat})
            msg = k.recv("game.event.spawn_failed")
            p = payload(msg)
            assert_equal(p.get("unit_id"), unit_id, "bounds rejection unit_id")
            assert_equal(p.get("reason"), "out of bounds", "bounds rejection reason")
        results.append("coordinate bounds")

        # JSON escaping regression: the id is deliberately awkward. A previous
        # implementation could corrupt the JSON envelope or persisted event.
        weird_id = 'qa"\\control\nunit'
        k.send("game.cmd.spawn", {"unit_id": weird_id, "lon": 0.0, "lat": 0.0})
        spawned = k.recv("game.event.spawned")
        assert_equal(payload(spawned).get("unit_id"), weird_id, "escaped unit id")
        results.append("JSON string escaping")

        # Snapshot commands should remain responsive after real activity.
        snapshot_topics = [
            ("game.cmd.list_nodes", "game.event.node_list"),
            ("game.cmd.list_cities", "game.event.city_list"),
            ("game.cmd.list_roads", "game.event.road_list"),
            ("game.cmd.list_tech_defs", "game.event.tech_list"),
            ("game.cmd.get_diplomacy", "game.event.diplomacy_status"),
            ("game.cmd.get_ledger", "game.event.ledger"),
        ]
        for cmd, reply in snapshot_topics:
            k.send(cmd, {"by": "qa"} if cmd.endswith("ledger") or cmd.endswith("diplomacy") else {})
            k.recv(reply, timeout=3.0)
        results.append("snapshot responsiveness")

        # Sustained ping latency test. This catches output/input stalls that are
        # invisible in a single request and gives us a baseline before testing VDRX.
        samples: List[float] = []
        for _ in range(100):
            samples.append(k.ping(timeout=3.0))
        p50 = statistics.median(samples)
        p95 = sorted(samples)[int(len(samples) * 0.95) - 1]
        p99 = sorted(samples)[int(len(samples) * 0.99) - 1]
        if p95 > 0.5:
            raise AssertionError(f"ping p95 too high: {p95:.3f}s (p50={p50:.3f}s, p99={p99:.3f}s)")
        results.append(f"100-ping latency p50={p50:.3f}s p95={p95:.3f}s p99={p99:.3f}s")

        print("PASS")
        for result in results:
            print(f"  {result}")
        return 0
    finally:
        k.stop()
        if temp_root:
            temp_root.cleanup()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True, help="Path to the built kyzu executable")
    parser.add_argument("--workdir", type=Path, required=True, help="KYZU deployment directory")
    parser.add_argument("--isolated-copy", action="store_true", help="Copy the deployment to a temporary directory before testing")
    args = parser.parse_args()
    binary = args.binary.resolve()
    workdir = args.workdir.resolve()
    if not binary.exists():
        print(f"ERROR: binary not found: {binary}", file=sys.stderr)
        return 2
    if not workdir.is_dir():
        print(f"ERROR: workdir not found: {workdir}", file=sys.stderr)
        return 2
    try:
        return run_suite(binary, workdir, args.isolated_copy)
    except (AssertionError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
