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
| `game.cmd.attack` | `attacker_unit_id`, `target_unit_id` **or** `target_city_id`, `by` | Requires an owned, combat-capable (`attack`>0) attacker within `attack_range_cells`; see §6. Also the trigger for auto-war (§8) and blocked outright between allies |
| `game.cmd.list_nodes` | *(none)* | Full snapshot of every resource node |
| `game.cmd.list_tech_defs` | *(none)* | Full snapshot of the tech.json registry (id, prerequisites, cost, research_ticks) |
| `game.cmd.get_tech` | `by` | The caller's own researched techs + in-progress research only |
| `game.cmd.start_research` | `tech_id`, `by` | Requires unresearched, prerequisites met, no research already in flight for `by`, and an affordable `cost`; deducts cost immediately, completes after `research_ticks` |
| `game.cmd.get_diplomacy` | `by` | The caller's own non-neutral relationships (war/allied) with other factions |
| `game.cmd.declare_war` | `by`, `target` | Unilateral; clears any standing alliance and pending proposals between the two |
| `game.cmd.propose_alliance` | `by`, `target` | Rejected if the two are at war; takes effect once `target` calls `accept_alliance` |
| `game.cmd.accept_alliance` | `by`, `target` | `by` accepts an alliance `target` proposed **to** them; fails with no pending proposal |
| `game.cmd.break_alliance` | `by`, `target` | Unilateral; only meaningful if currently allied |
| `game.cmd.propose_peace` | `by`, `target` | Only valid while at war; takes effect once `target` calls `accept_peace` |
| `game.cmd.accept_peace` | `by`, `target` | `by` accepts peace `target` proposed **to** them; returns the pair to neutral |

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
| `game.event.tech_list` | Reply to `list_tech_defs` |
| `game.event.tech_status` | Reply to `get_tech` — caller's researched list + in-progress research |
| `game.event.research_started` / `research_failed` | Research start outcome |
| `game.event.research_cost_spent` | Resources deducted for a research start (mirrors `city_growth_spent`) |
| `game.event.research_completed` | A faction's in-progress research finished (see §7's research pass) |
| `game.event.diplomacy_status` | Reply to `get_diplomacy` |
| `game.event.diplomacy_status_changed` | Broadcast whenever two factions' relationship changes (war declared, alliance formed, peace made, alliance/peace broken, or an attack auto-declares war) |
| `game.event.alliance_proposed` / `alliance_proposal_failed` | Alliance proposal outcome |
| `game.event.alliance_accept_failed` | `accept_alliance` had no matching pending proposal |
| `game.event.peace_proposed` / `peace_proposal_failed` | Peace proposal outcome |
| `game.event.peace_accept_failed` | `accept_peace` had no matching pending proposal |
| `game.tick` | Broadcast every tick (~20/sec) with the current tick number |

## 5. Ownership model

Every mutating command that targets an existing unit or city carries a `by` field naming the acting faction. The rule, applied consistently across move/despawn/collect/found_city/build_road/attack:

- A unit or city with `owner=''` (**unowned**) is free-for-all — anyone (including a raw client that never sends `by` at all, like the bus terminal's quick-command buttons) can act on it.
- A unit or city with a non-empty `owner` can only be acted on by a matching `by`. A mismatch produces the corresponding `*_failed` event with `"reason":"not your unit"` (or the city/road equivalent).
- `attack` additionally forbids an **unowned** attacker outright (`"unowned units cannot attack"`) — there's no one to credit a conquest to — and forbids attacking your own faction.
- `build_road` uses a looser two-endpoint version: blocked only if **both** cities are owned by someone else, so linking your own city to a neutral one always works.
- Resource collection is credited to the **acting** `by`, not the collecting unit's own `owner` — a shared/unowned unit's harvest still lands in a real faction's ledger. An empty `by` still depletes the node but credits no one.
- `attack` and `move` are also gated by diplomacy (§8): attacking an ally is blocked outright regardless of ownership, and moving an owned unit into another faction's territory is blocked unless the mover is allied or at war with that territory's owner.

## 6. Combat & veterancy

`game.cmd.attack` distinguishes unit-vs-unit and unit-vs-city by which of `target_unit_id`/`target_city_id` is set:

- **Unit vs unit**: damage = attacker's base `attack` + `level * veterancy_attack_bonus_per_level`. Every landed hit grants XP regardless of outcome; leveling up (up to `veterancy_max_level`) also heals the attacker by `veterancy_hp_bonus_per_level`. A target reaching 0 HP is removed via the same event path as a normal despawn.
- **Unit vs city**: a city's `population` doubles as its defense pool. Each hit subtracts `siege_damage_per_attack`; hitting zero flips the city's owner to the attacker and resets population to `city_capture_reset_population`, with both its growth and upkeep clocks reset (no back-charged upkeep from being conquered).

## 7. Tech & research

`tech.json` defines a small flat research tree — each entry has a `tech_id`, `prerequisites` (other tech_ids, all of which must already be researched), a resource `cost`, and `research_ticks` (how long research takes once started). Unit types opt into gating via `requires_tech` in `unit_types.json`; `spawn` for a gated type fails with `"reason":"tech not researched"` until the spawning faction has completed that tech. `requires_tech` is never enforced for `owner=''` (unowned) spawns — there's no faction to check against, the same free-for-all carve-out unowned units get elsewhere.

Research is one-at-a-time per faction: `start_research` pays `cost` up front (à la `city_growth_cost`) and fails outright — no queueing — if a research is already in flight for that faction. A single tick-loop pass (`ProcessResearch`) advances every in-flight research and completes any that have run `research_ticks` ticks, marking the tech researched and freeing that faction up to start another. On restart, an in-flight research's clock resets to 0 (same "restart forgives partial progress" precedent as city growth/upkeep clocks) rather than trying to preserve fractional progress.

The shipped tree: `masonry` and `bronze_working` and `horseback_riding` have no prerequisites; `siege_engineering` requires both `bronze_working` and `masonry`; `logistics` requires `horseback_riding`. Three unit types are gated: `spearman` (bronze_working), `cavalry` (horseback_riding), `catapult` (siege_engineering).

## 8. Diplomacy & territory

Every pair of factions has one of three relationships — `war`, `allied`, or the unstored default `neutral` — tracked in a single map keyed by an order-independent pair (so `get_diplomacy` returns the same answer regardless of who's asking about whom). Only `war` and `allied` are ever written; returning to neutral (accepted peace, broken alliance) removes the entry rather than writing a `"neutral"` value.

- **Declaring war** (`declare_war`) is unilateral and immediate — no acceptance needed — and also happens **automatically** the first time one faction's unit or city is hit by another faction's attack (a "the first strike is itself a declaration" convention). This means `attack` never needs a prior `declare_war` to work between two neutral factions; it just costs you the relationship.
- **Alliances and peace** are the two-step kind: `propose_alliance`/`propose_peace` register a pending offer (kept in memory only — never logged, never restored on restart, the same way an unanswered real-world offer just lapses if the server bounces), and the other side's `accept_alliance`/`accept_peace` is what actually changes the relationship. `break_alliance` and reaching peace both return the pair to plain neutral, not to some third "formerly allied" state.
- **Attacking an ally is blocked outright** (`"reason":"cannot attack an allied faction - break the alliance first"`) for both unit and city targets — there's no accidental-friendly-fire path.
- **Territory**: each city projects a claim over nearby cells using the exact same radius/falloff formula `development_delta` already uses (so "whose territory this is" always lines up with what a viewer sees as development, not a second inconsistent notion of ownership). `move` rejects a destination inside another faction's territory (`"reason":"neutral territory - declare war or ally to enter"`) unless the mover is **allied** with that territory's owner (open borders) or **at war** with them (invasion is the point of being at war). Unowned units are exempt, as with every other ownership rule.

## 9. The AI opponent(s)

kyzu can run any number of AI-controlled factions side by side, each configured independently in `ai_factions.json` and each driven once per tick by `RunAI`, called once per faction from `RunAllAI`. The important architectural point hasn't changed: **the AI is not a parallel code path.**

- Each AI faction never bootstraps its own city — it only manages the economy of a city seeded for it in `cities.json` (owner = that faction's `faction_name`).
- Every action it takes — spawning a unit, moving, collecting, founding a city, building a road, attacking, starting research — is issued by constructing the **exact same JSON payload** a real client would send and calling the **same `Handle*` procedures** directly.
- That means every AI faction is bound by identical ownership, range, terrain, and diplomacy/territory rules as any human/bridge client, and any future rule change automatically applies to all of them too — there is nothing AI-specific to keep in sync.
- Each faction's city's growth and upkeep are handled by the same `GrowCities`/`ProcessCityUpkeep` logic every other owned city goes through — no special-casing.
- Per-worker node assignment and per-settler founding-site assignment for ALL factions share one map (`AiUnitTargets`, a unit_id→string map) — safe because generated unit IDs are prefixed with the owning faction's name (`ai_w_<faction>_...`, `ai_s_<faction>_...`), so no two factions' entries can collide. A worker's value is a bare node_id, a settler's is a `"GX,GY"` coordinate pair (distinguished by the presence of a comma). Deliberately touched only from the main tick-loop thread, so unlike every other shared collection in the process it needs no lock.

**`ai_factions.json`** is a flat array; each entry needs only `faction_name` — every other field (`tick_interval`, `target_worker_count`, `target_settler_count`, `expansion_search_radius_cells`, `expansion_min_city_distance_cells`, `target_soldier_count`, `aggression_range_cells`, `research_enabled`) falls back to the matching `ai_*` field in `game_balance.json` if omitted, so a faction can be as small as `{"faction_name":"ai_south"}` (a plain clone of the defaults) or fully customized into a distinct "personality". If `ai_factions.json` is missing or empty, kyzu synthesizes a single faction from `game_balance.json`'s `ai_faction_name` and `ai_*` fields directly — a deployment with no `ai_factions.json` at all runs exactly one AI faction, same as before this file existed. The shipped file defines three: `ai` (balanced), `ai_west` (aggressive — no settlers, 5 soldiers, wide aggression range, no research), `ai_east` (builder — 3 workers, 2 settlers, wide expansion radius, narrow aggression range, research on).

Each faction's heavier decision pass (spawning, road-building, research) is throttled to once per `tick_interval` ticks, offset by that faction's position in the array (`(Tick + Offset) mod TickInterval = 0`) so multiple factions sharing the same interval don't all recompute on the identical tick. The lighter per-unit pass (movement, collection, combat) still runs for every faction on every tick regardless.

Beyond the original worker/economy loop, each AI faction now also:

- **Expands**: keeps `target_settler_count` settlers in flight. An idle settler with no assigned site gets a bounded random search around the faction's city for a passable cell that's `expansion_min_city_distance_cells` away from **every** existing city (any owner), then walks there and founds on arrival.
- **Defends and fights back**: keeps `target_soldier_count` soldiers up. A soldier only ever pursues a faction it's **already at war with** (it never picks fights with neutral factions on its own — including other AI factions, which by default just coexist neutrally unless something triggers a war) — it attacks anyone at war within `aggression_range_cells`, preferring units over cities, and garrisons back at the home city when nothing's in range.
- **Builds roads** between every pair of its own cities that isn't already directly linked.
- **Researches** (only if `research_enabled`): when idle, walks `tech.json` in file order and starts the first tech whose prerequisites are met and whose cost it can currently afford.

From a client's perspective, every AI faction is indistinguishable from any other player faction on the wire — each shows up in `spawned`/`position`/`collected`/city/tech/diplomacy events with its own `owner` like anyone else.

## 10. HTTP integration

vdrx serves kyzu's static and tile content on three separate `http_sites` ports (configured in `kyzu.vdrx.conf`):

| Port | Site | Content |
| --- | --- | --- |
| 8090 | `kyzu` | `web/static` — the bus terminal dev console |
| 8091 | `kyzu_map` | `web/map/static` — the full map viewer |
| 8092 | `kyzu_data` | Static tile PNGs served from an external data directory (`C:/dev/kyzu_data/public`) |

These are plain static file sites — kyzu the process is not involved in serving them at all; they exist purely as vdrx `http_sites` config entries pointing at directories on disk.

## 11. WebSocket integration

vdrx's WebSocket bridge listens on port 8082 and exposes a small JSON-RPC surface to connecting clients: `subscribe` / `unsubscribe` / `unsubscribe_all` / `publish`, each connection registered as its own executive against the bus's topic-filter registry.

A client (either of kyzu's two web frontends, or any other WebSocket client) does roughly:

1. `subscribe` to `game.>` (or a narrower filter) to receive kyzu's outgoing events as they're published to the bus.
2. `publish` a `game.cmd.*` message with a `payload` to issue a command — this reaches kyzu via the bridge exactly as described in §1–2.

Because subscriptions are filter-based (vdrx's `*`/`>` wildcard topic matching), a client can subscribe as broadly (`game.>`) or narrowly (`game.event.position`) as it needs; multiple simultaneous filters per connection are supported.

## 12. External / non-browser clients

Because the wire protocol is just JSON-RPC over a WebSocket (or, at the process boundary, JSON lines on stdin/stdout), nothing about it is browser-specific. Any WebSocket-capable client — a script, another VDRX-supervised process talking through its own bridge, a CLI tool — can `subscribe`/`publish` against the same bus the two bundled web frontends use, and is subject to the exact same ownership rules as the AI and the map viewer: there is no privileged internal API distinct from what's documented here.

## 13. Event logging & analytics (`kyzu_logger`)

`kyzu_logger` is a separate, standalone process (`kyzu_logger.lpr`) that does nothing but turn the live event stream into permanent, indexed history in SQLite. It has no relationship to `kyzu.lpr` beyond being another bus subscriber — same principle `web/dashboard/kyzu_dashboard.html`'s own comment makes about itself, and it could run on a different machine entirely. Registered in `kyzu.vdrx.conf`'s `processes` list, subscribed to `["game.event.>", "game.tick"]`.

It writes two tables:

- **`events`** — every `game.event.*` message, verbatim, forever: `id, ts (unix epoch received), tick, topic, owner, payload`. `owner` is a best-effort convenience column (pulled from whichever of `owner`/`new_owner`/`by`/`previous_owner` the payload has, or recovered from the in-memory unit/city model for `despawned` which carries none of its own) so per-faction queries don't need to parse `payload` just to filter. Indexed on `topic`, `owner`, and `tick`. This is the full-fidelity source of truth — anything not covered by the table below is still in here.
- **`faction_snapshots`** — one row per faction every 100 ticks (~5 sec): `population, city_count, unit_count, max_level, kills, deaths, cities_founded, cities_captured, cities_lost, veteran_level_ups, techs_researched`, plus `ts`/`tick`. This is what makes a trend chart ("population over the last hour") a cheap indexed range query instead of an aggregation over however many raw event rows have piled up — the same population/unit-count figures the live dashboard computes fresh from its in-memory model on every render are pre-computed here and given a permanent timestamp.

`kyzu_logger` maintains its own tiny in-memory world model (unit owner/type/level, city owner/population, running kill/death/capture counters) purely to compute those snapshot rows — it is not a source of truth for anything, just a rollup cache, and is rebuilt from scratch (i.e. starts empty) every time the process restarts. This means a snapshot taken shortly after a `kyzu_logger` restart may undercount factions/cities/units that existed before it came up but haven't emitted a fresh event since — it catches up as soon as each entity's next event arrives. The `events` table has no such gap since every event it receives while running is written unconditionally.

Writes are batched: one SQLite transaction covers roughly one second of activity (committed every 20 ticks) rather than committing per row, so a busy multi-faction stream doesn't turn into one fsync per event. `PRAGMA journal_mode=WAL` also means a dashboard or reporting process can read the same `.sqlite3` file concurrently without blocking on `kyzu_logger`'s writes.

DB path defaults to `kyzu_events.sqlite3` next to the `kyzu_logger` executable, or a path given as its first argument.

## 14. Config & persistence notes relevant to the bus

- `game_balance.json` externalizes every tunable number (movement speed, costs, ranges, veterancy) — editing it and restarting the server is how the game is rebalanced; none of these values are renegotiated over the bus at runtime.
- `ai_factions.json` externalizes which AI factions run and their per-faction personality knobs, loaded once at startup alongside the other config files — adding, removing, or retuning a faction is an edit-and-restart, same as `game_balance.json`.
- `events.jsonl` is a resolved-outcome log (final positions/paths/amounts, not raw commands) replayed once, fully, before the stdin reader thread starts — so there's no window where a live command from the bus could race an in-progress replay.
- `cities.json` is loaded **before** replay (not after) specifically so that per-city update events in the log — `city_grew`, `city_captured`, etc. — have a city to apply against; the same ordering applies to `resource_nodes.json` relative to `collected` events, and to `tech.json` relative to `research_started`/`research_completed` events (a tech definition must exist for `ProcessResearch` to know its `research_ticks`).
- Development density (`development_delta`/`development_snapshot`) is never itself logged to `events.jsonl` — it's fully deterministic from replayed `city_founded`/`city_grew`/`road_built` events, the same principle that keeps the resource ledger rebuildable from `collected` events alone.
- Diplomatic status is logged as `diplomacy_status_changed` (one line per change, current value only) and replayed the same way; **pending** alliance/peace proposals are deliberately never logged — an unanswered offer just lapses on restart, the same as an unanswered real-world one.
- `kyzu_events.sqlite3` (via `kyzu_logger`, §13) is a completely separate persistence mechanism from `events.jsonl` — the latter is what `kyzu.lpr` itself replays on startup to rebuild live state; the former is a permanent analytics log that kyzu itself never reads. Deleting the `.sqlite3` file loses history but affects nothing about how the game runs; it's rebuilt fresh (with a gap for whatever happened before `kyzu_logger` restarts) the next time both processes are up.

