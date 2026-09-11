# KYZU protocol / smoke / performance tests

This is a zero-dependency Python 3 test harness for a **built KYZU deployment**.
It deliberately talks to KYZU exactly the way VDRX does: JSON lines on stdin/stdout.

## Running

From a deployment directory containing the compiled `kyzu` executable and its normal
JSON/config/grid files:

```bash
python qa/kyzu_protocol_test.py --binary ./kyzu --workdir .
```

On Windows:

```powershell
python qa\kyzu_protocol_test.py --binary .\kyzu.exe --workdir .
```

The harness does not modify `events.jsonl` by default. It starts KYZU with a temporary
copy of the deployment directory when `--isolated-copy` is supplied:

```bash
python qa/kyzu_protocol_test.py --binary .\kyzu.exe --workdir . --isolated-copy
```

The isolated mode copies files into a temporary directory before launch, so replay and
persistence tests are safe to run against a real deployment.

## What it checks

- process startup and first `game.tick`
- JSONL output validity
- `game.cmd.ping` round-trip latency
- malformed JSON does not kill the command reader
- out-of-range coordinates are rejected
- quote/backslash/control-character IDs round-trip as valid JSON
- basic snapshot commands remain responsive
- sustained ping throughput and latency distribution

The tests are intentionally black-box. They do not depend on FPC internals and can
therefore become the same regression suite used from CI later.
