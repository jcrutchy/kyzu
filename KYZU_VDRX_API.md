# kyzu ↔ vdrx integration reference

This document covers how the kyzu game server — and its built-in AI opponent — interface with [vdrx](https://github.com/jcrutchy/vdrx): the process supervision model, the stdin/stdout bus envelope, the full command/event protocol, ownership rules, the AI's integration path, and how vdrx exposes all of this over HTTP and WebSocket to real clients.

kyzu itself has **zero knowledge** of HTTP, WebSockets, or vdrx's internal bus mechanics. It only ever reads and writes JSON lines on stdin/stdout. Everything client-facing — the WebSocket bridge, the static file serving, the tile serving — is entirely vdrx's responsibility, configured declaratively and layered on top of a process that doesn't know any of it exists.

## 1. Process supervision

vdrx launches `kyzu` as a supervised child process (a `processes` entry in vdrx's config, split out into `kyzu.vdrx.conf` and pulled in via vdrx's `includes` mechanism rather than living in vdrx's own `vdrx.conf`). vdrx owns the process lifecycle — restart policy, stdin/stdout pipes — and a `vdrx_bridge` executive sits between the process and the bus:

```
 kyzu (stdin/stdout, JSON lines)
        ▲   │
        │   ▼
   TVDRX_BridgeExecutive
        │   ▲
        ▼   │
   VDRX message bus (topic + payload, pub/sub)
        │   ▲
   ┌────┴───┴─────────────────────────┐
   ▼                                  ▼
WebSocket bridge (browser clients)   HTTP sites (static/tile serving)
```

The bridge feeds every bus message addressed to kyzu's topics into kyzu's stdin as a JSON line, and republishes every line kyzu writes to stdout back onto the bus under its own topic. From kyzu's point of view it is just doing line-buffered `ReadLn`/`WriteLn` against `Input`/`Output` — the same idiom `TStdinReaderThread` uses, mirroring vdrx's own `vdrx_stdin.pas` pattern.

If kyzu's stdin is closed (the bridge process ends), kyzu's reader thread exits its loop and the process is expected to be restarted by vdrx's supervision — kyzu does not attempt to reconnect anything itself.

## 2. The bus envelope

Every line in both directions is a single JSON object of the shape:

```json
{"topic":"game.cmd.spawn","payload":"{\"unit_id\":\"u1\",\"lon\":10.5,\"lat\":20.0}"}
```

- `topic` — a dot-delimited string. Commands into kyzu use `game.cmd.*`; events out of kyzu use `game.event.*` (plus a bare `game.tick`).
- `payload` — kyzu's own outgoing events always encode this as a **JSON string** containing escaped JSON (`"payload":"{\"unit_id\":...}"`), matching vdrx's general bus message shape (topic + payload + source).

For **incoming** commands, kyzu is tolerant of both shapes: a `payload` sent as a nested JSON *object* is used directly, and a `payload` sent as a JSON *string* (kyzu's own outgoing convention) is parsed and used the same way. This means a client that just mirrors kyzu's own event shape back at it when issuing commands works without any special-casing — it doesn't have to know which of the two encodings the wire format technically uses.

Malformed JSON on a stdin line is silently ignored (not fatal) — the reader thread also wraps every `DispatchIncoming` call in its own exception handler so a bad payload in one command can never take the whole process's command handling down; it's logged to stderr and the reader continues.

## 3. Command reference (`game.cmd.*`, stdin)

All commands are fire-and-forget from the caller's side — a command either produces an event (success) or a corresponding `*_failed` event (failure); there's no separate acknowledgment.

| Command | Payload fields | Notes |
| --- | --- | --- |
| `game.cmd.ping` | *(none)* | Replies `game.event.pong` |
| `game.cmd.spawn` | `unit_id`, `lon`, `lat`, `owner` (optional, `''`=unowned), `unit_type` (optional, default `generic`) | Rejects an already-in-use `unit_id`, out-of-bounds coordinates, or impassable terrain |
| `game.cmd.despawn` | `unit_id`, `by` | Unowned units (`owner=''`) can be despawned by anyone |
| `game.cmd.move` | `unit_id`, `to_lon`, `to_lat`, `by` | A* pathfind to target; fails if the unit is unowned-mismatched or no path exists |
| `game.cmd.collect` | `unit_id`, `node_id`, `by` | Requires the unit's type to have `can_collect`, be within `collect_radius_cells` of the node, and the node to have remaining `amount` |
| `game.cmd.get_ledger` | `by` | Returns the caller's own faction totals only — not a scoreboard of every faction |
| `game.cmd.found_city` | `city_id`, `unit_id`, `by` | Founds at the unit's **current position** (no lon/lat accepted); requires an owned, idle unit whose type has `can_found_city`; consumes the unit |
| `game.cmd.build_road` | `road_id`, `from_city_id`, `to_city_id`, `by` | A* path between the two cities' cells; blocked only if **both** endpoints are owned by someone else |
| `game.cmd.list_cities` | *(none)* | Full snapshot of every city |
| `game.cmd.list_roads` | *(none)* | Full snapshot of every road |
| `game.cmd.get_development` | *(none)* | Full snapshot of the current density field |
| `game.cmd.attack` | `attacker_unit_id`, `target_unit_id` **or** `target_city_id`, `by` | Requires an owned, combat-capable (`attack`>0) attacker within `attack_range_cells`; see §6 |
| `game.cmd.list_nodes` | *(none)* | Full snapshot of every resource node |

## 4. Event reference (`game.event.*` / `game.tick`, stdout)

| Event | Trigger |
| --- | --- |
| `game.event.pong` | Reply to `ping` |
| `game.event.spawned` / `spawn_failed` | Unit spawn outcome |
| `game.event.despawned` / `despawn_failed` | Unit despawn outcome — also emitted on death-by-combat and on a unit consumed by `found_city` |
| `game.event.path_found` / `move_failed` | Move outcome (includes the full path) |
| `game.event.position` | Broadcast every tick for every currently-moving unit |
| `game.event.arrived` | A unit reaches the end of its path |
| `game.event.collected` / `collect_failed` | Resource collection outcome |
| `game.event.ledger` | Reply to `get_ledger` (scoped to the requesting faction) |
| `game.event.city_founded` / `city_failed` | City founding outcome |
| `game.event.city_grew` | Passive population growth tick |
| `game.event.city_growth_spent` | Resources deducted for a growth step (owned cities only) |
| `game.event.city_upkeep_spent` | Resources deducted for upkeep (owned, road-**disconnected** cities only) |
| `game.event.city_population_decayed` | Upkeep unaffordable — population shrinks instead |
| `game.event.city_abandoned` | Population hit zero — city removed, its roads pruned |
| `game.event.road_built` / `road_failed` | Road construction outcome |
| `game.event.road_removed` | A road pruned after its city was abandoned |
| `game.event.city_list` / `road_list` | Reply to `list_cities` / `list_roads` |
| `game.event.development_delta` | Incremental density-field change, broadcast every `development_update_ticks` |
| `game.event.development_snapshot` | Reply to `get_development` — full current field |
| `game.event.node_list` | Reply to `list_nodes` |
| `game.event.unit_attacked` / `attack_failed` | Unit-vs-unit combat outcome (includes attacker XP/level) |
| `game.event.unit_leveled_up` | Notification-only, redundant with fields already in `unit_attacked` |
| `game.event.city_attacked` / `city_captured` | Unit-vs-city siege outcome |
| `game.tick` | Broadcast every tick (~20/sec) with the current tick number |

## 5. Ownership model

Every mutating command that targets an existing unit or city carries a `by` field naming the acting faction. The rule, applied consistently across move/despawn/collect/found_city/build_road/attack:

- A unit or city with `owner=''` (**unowned**) is free-for-all — anyone (including a raw client that never sends `by` at all, like the bus terminal's quick-command buttons) can act on it.
- A unit or city with a non-empty `owner` can only be acted on by a matching `by`. A mismatch produces the corresponding `*_failed` event with `"reason":"not your unit"` (or the city/road equivalent).
- `attack` additionally forbids an **unowned** attacker outright (`"unowned units cannot attack"`) — there's no one to credit a conquest to — and forbids attacking your own faction.
- `build_road` uses a looser two-endpoint version: blocked only if **both** cities are owned by someone else, so linking your own city to a neutral one always works.
- Resource collection is credited to the **acting** `by`, not the collecting unit's own `owner` — a shared/unowned unit's harvest still lands in a real faction's ledger. An empty `by` still depletes the node but credits no one.

## 6. Combat & veterancy

`game.cmd.attack` distinguishes unit-vs-unit and unit-vs-city by which of `target_unit_id`/`target_city_id` is set:

- **Unit vs unit**: damage = attacker's base `attack` + `level * veterancy_attack_bonus_per_level`. Every landed hit grants XP regardless of outcome; leveling up (up to `veterancy_max_level`) also heals the attacker by `veterancy_hp_bonus_per_level`. A target reaching 0 HP is removed via the same event path as a normal despawn.
- **Unit vs city**: a city's `population` doubles as its defense pool. Each hit subtracts `siege_damage_per_attack`; hitting zero flips the city's owner to the attacker and resets population to `city_capture_reset_population`, with both its growth and upkeep clocks reset (no back-charged upkeep from being conquered).

## 7. The AI opponent

kyzu ships a single built-in AI faction (`ai_faction_name` in `game_balance.json`, default `"ai"`), driven once per tick by an internal `RunAI` routine. The important architectural point: **the AI is not a parallel code path.**

- It never bootstraps its own city — it only manages the economy of a city seeded for it in `cities.json` (owner = the AI faction name).
- Every action it takes — spawning a worker, moving toward a resource node, collecting from it — is issued by constructing the **exact same JSON payload** a real client would send and calling the **same `HandleSpawn`/`HandleMove`/`HandleCollect` procedures** directly.
- That means the AI is bound by identical ownership, range, and terrain rules as any human/bridge client, and any future rule change to spawning, moving, or collecting automatically applies to it too — there is nothing AI-specific to keep in sync.
- Its city's growth and upkeep are handled by the same `GrowCities`/`ProcessCityUpkeep` logic every other owned city goes through — no special-casing.
- Per-worker node assignment (`AiUnitTargets`, a unit_id→node_id map) is deliberately touched only from the main tick-loop thread, so unlike every other shared collection in the process it needs no lock.

From a client's perspective, the AI faction is indistinguishable from any other player faction on the wire — it shows up in `spawned`/`position`/`collected`/city events with `owner="ai"` like anyone else.

## 8. HTTP integration

vdrx serves kyzu's static and tile content on three separate `http_sites` ports (configured in `kyzu.vdrx.conf`):

| Port | Site | Content |
| --- | --- | --- |
| 8090 | `kyzu` | `web/static` — the bus terminal dev console |
| 8091 | `kyzu_map` | `web/map/static` — the full map viewer |
| 8092 | `kyzu_data` | Static tile PNGs served from an external data directory (`C:/dev/kyzu_data/public`) |

These are plain static file sites — kyzu the process is not involved in serving them at all; they exist purely as vdrx `http_sites` config entries pointing at directories on disk.

## 9. WebSocket integration

vdrx's WebSocket bridge listens on port 8082 and exposes a small JSON-RPC surface to connecting clients: `subscribe` / `unsubscribe` / `unsubscribe_all` / `publish`, each connection registered as its own executive against the bus's topic-filter registry.

A client (either of kyzu's two web frontends, or any other WebSocket client) does roughly:

1. `subscribe` to `game.>` (or a narrower filter) to receive kyzu's outgoing events as they're published to the bus.
2. `publish` a `game.cmd.*` message with a `payload` to issue a command — this reaches kyzu via the bridge exactly as described in §1–2.

Because subscriptions are filter-based (vdrx's `*`/`>` wildcard topic matching), a client can subscribe as broadly (`game.>`) or narrowly (`game.event.position`) as it needs; multiple simultaneous filters per connection are supported.

## 10. External / non-browser clients

Because the wire protocol is just JSON-RPC over a WebSocket (or, at the process boundary, JSON lines on stdin/stdout), nothing about it is browser-specific. Any WebSocket-capable client — a script, another VDRX-supervised process talking through its own bridge, a CLI tool — can `subscribe`/`publish` against the same bus the two bundled web frontends use, and is subject to the exact same ownership rules as the AI and the map viewer: there is no privileged internal API distinct from what's documented here.

## 11. Config & persistence notes relevant to the bus

- `game_balance.json` externalizes every tunable number (movement speed, costs, ranges, veterancy) — editing it and restarting the server is how the game is rebalanced; none of these values are renegotiated over the bus at runtime.
- `events.jsonl` is a resolved-outcome log (final positions/paths/amounts, not raw commands) replayed once, fully, before the stdin reader thread starts — so there's no window where a live command from the bus could race an in-progress replay.
- `cities.json` is loaded **before** replay (not after) specifically so that per-city update events in the log — `city_grew`, `city_captured`, etc. — have a city to apply against; the same ordering applies to `resource_nodes.json` relative to `collected` events.
- Development density (`development_delta`/`development_snapshot`) is never itself logged to `events.jsonl` — it's fully deterministic from replayed `city_founded`/`city_grew`/`road_built` events, the same principle that keeps the resource ledger rebuildable from `collected` events alone.
