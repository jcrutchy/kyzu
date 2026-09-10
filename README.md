# kyzu

Global terrain map server and macro-strategy unit simulation running on a real-world geographic grid.

Bakes landcover / heightmap / movement tiles from GlobCover + ETOPO GeoTIFFs, then runs a lightweight game server that pathfinds and moves units, manages factions, resource collection, cities, roads, tech/research, diplomacy, and combat over the resulting movement grid — including any number of built-in AI-controlled factions, each with its own personality.

Runs as a supervised child process under [vdrx](https://github.com/jcrutchy/vdrx), which provides the message bus, process supervision, HTTP static/tile serving, and the WebSocket bridge that browser clients connect through. kyzu itself only ever speaks JSON lines on stdin/stdout — it has no knowledge of HTTP, WebSockets, or vdrx's own internals. A second, independent process (`kyzu_logger`) subscribes to the same bus purely to log history into SQLite; kyzu has no knowledge of it either.

See **[KYZU_VDRX_API.md](KYZU_VDRX_API.md)** for the full command/event protocol reference and a detailed look at how the game server, its AI factions, and the event logger interface with vdrx's bus, HTTP sites, and WebSocket bridge.

## Components

| Binary | Purpose |
| --- | --- |
| `kyzu` | Game server: units, ownership, pathfinding, resource collection, cities/roads, tech/research, diplomacy & territory, combat, veterancy, any number of AI opponent factions, event-log replay |
| `kyzu_logger` | Standalone VDRX subscriber: logs the live event stream into an indexed SQLite database (raw event log + periodic per-faction stat snapshots) for history and trending |
| `kyzu_bake_tiles` | Landcover tile pyramid (PNG) |
| `kyzu_bake_heightmap_tiles` | Heightmap tiles |
| `kyzu_bake_combined_tiles` | Combined landcover + shaded heightmap |
| `kyzu_bake_movecost_tiles` | Movement-cost visualization tiles |
| `kyzu_bake_movement_grid` | Binary movement grid (`KYTR` format) used by the server |
| `kyzu_bake_terrain` | Terrain bake helper |

## Requirements

- Free Pascal (FPC 3.2.2+)
- GeoTIFF sources (GlobCover landcover, ETOPO elevation) for the bake pipeline
- SQLite3 runtime library (`sqlite3.dll` / `libsqlite3.so`) for `kyzu_logger` — loaded dynamically via `sqlite3dyn`, not needed by `kyzu` itself
- [vdrx](https://github.com/jcrutchy/vdrx) to run the server (and logger) under supervision and expose it over HTTP/WebSocket

## Config & data files

All of these are loaded once at startup with tolerant, non-fatal fallbacks — a missing or malformed file never stops the server from starting, it just means that piece of content/tuning falls back to built-in defaults.

| File | Purpose | If missing |
| --- | --- | --- |
| `bake_config.json` | Paths, tile size, landcover classes (with `move_cost`), shading, hypsometric colors — used by both the bake tools and the running server | Required for the bake pipeline; server needs it to find the movement grid |
| `game_balance.json` | Every tunable gameplay number — movement speed, collection amounts/radius, city growth/upkeep costs and intervals, development radii, combat range/damage, veterancy thresholds, and the default AI knobs `ai_factions.json` entries inherit from | Falls back to built-in defaults matching the values shipped in code |
| `unit_types.json` | Unit type registry: `speed_multiplier`, `can_found_city`, `can_collect`, `collect_multiplier`, `hp`, `attack`, `requires_tech` per `type_id` | All unit types fall back to a generic default (normal speed, can found, can collect, 20 HP, non-combatant, no tech requirement) |
| `tech.json` | Research tree: `tech_id`, `display_name`, `prerequisites`, `cost`, `research_ticks` per entry | Server starts with zero researchable techs — any `requires_tech` unit type becomes permanently unspawnable |
| `ai_factions.json` | Which AI factions run and their personalities — `faction_name` plus per-faction overrides of the `ai_*` knobs in `game_balance.json` | Falls back to a single AI faction built from `game_balance.json`'s `ai_faction_name`/`ai_*` fields directly |
| `resource_nodes.json` | Static, depletable resource nodes: `id`, `resource_type`, `lon`, `lat`, `amount` | Server starts with zero nodes |
| `cities.json` | Seed cities: `id`, `owner`, `lon`, `lat`, `population` | Server starts with zero seed cities — cities can still be founded live |
| `events.jsonl` | Append-only outcome log (spawns, paths, collections, city/road/tech/diplomacy/combat events) — **not hand-edited**, replayed on every startup to reconstruct state | Server starts fresh with empty state |

## Protocol (kyzu ↔ vdrx)

kyzu reads one JSON command per line on stdin and writes one JSON event per line on stdout, in the `{"topic":"...","payload":"..."}` envelope vdrx's bridge expects. Full reference — every command, every event, the ownership model, and how the AI factions use the exact same command handlers a real client does — is in **[KYZU_VDRX_API.md](KYZU_VDRX_API.md)**.

Quick summary of the command surface:

- **Units** — `game.cmd.spawn`, `despawn`, `move`, `collect`
- **Factions** — `game.cmd.get_ledger`
- **Cities & roads** — `game.cmd.found_city`, `build_road`, `list_cities`, `list_roads`, `get_development`
- **Tech & research** — `game.cmd.list_tech_defs`, `get_tech`, `start_research`
- **Diplomacy** — `game.cmd.get_diplomacy`, `declare_war`, `propose_alliance`, `accept_alliance`, `break_alliance`, `propose_peace`, `accept_peace`
- **Combat** — `game.cmd.attack` (unit-vs-unit or unit-vs-city, with veterancy; blocked between allies, auto-declares war on a first strike between neutral factions)
- **Misc** — `game.cmd.ping`, `game.cmd.list_nodes`

State is persisted as resolved outcomes (not raw commands) in `events.jsonl` and replayed in full before the server accepts any live commands.

## The AI

kyzu can run any number of AI-controlled factions side by side, configured in `ai_factions.json` — each with its own city, its own economy, and its own tuning for expansion, military posture, and research. Every action an AI faction takes (spawning, moving, collecting, founding, road-building, attacking, researching) goes through the exact same command handlers a real client would call — there is no separate AI code path, so every rule change applies to the AI automatically. AI factions only ever fight a faction they're already at war with; by default multiple AI factions just coexist neutrally. See **KYZU_VDRX_API.md §9** for the full behavior breakdown.

## Frontends

Three browser clients live under `web/`, all connecting to vdrx's WebSocket bridge:

- `web/static/index.html` — a bus terminal dev console: live pub/sub log, topic filter, quick-command buttons. Useful for poking at the protocol directly.
- `web/map/static/index.html` — the full map viewer: tile layers (landcover/heightmap/combined/movecost), live WebSocket-driven units with position interpolation, click-to-select/click-to-move, resource nodes, cities, roads, development overlay, combat, pan/zoom, touch support.
- `web/dashboard/kyzu_dashboard.html` — a live per-faction stats dashboard: population, unit counts, kills/deaths, cities founded/captured, resources collected/spent, and a running combat/growth log feed, all reconstructed purely from the event stream. Complements `kyzu_logger` — this shows *now*, the logger keeps *history*.

## History & analytics (`kyzu_logger`)

`kyzu_logger` is a separate VDRX-supervised process, subscribed to `game.event.>` and `game.tick`, that writes everything into a SQLite database (`kyzu_events.sqlite3` by default): a full indexed raw event log, plus a periodic per-faction snapshot table (population, units, kills/deaths, cities, tech) written roughly every 5 seconds so trend queries don't need to aggregate the raw log from scratch. It's a pure bystander — kyzu never knows it's running, and deleting its database affects nothing about how the game runs. See **KYZU_VDRX_API.md §13** for the schema and batching/WAL details.

## Running under vdrx

vdrx supervises the `kyzu` and `kyzu_logger` processes and serves kyzu's static/tile content and WebSocket bridge on separate ports (see `kyzu.vdrx.conf`, loaded via vdrx's `includes` mechanism). See **KYZU_VDRX_API.md** for the exact HTTP/WS wiring.

## Build

```
fpc -Mobjfpc -Sh kyzu.lpr
fpc -Mobjfpc -Sh kyzu_logger.lpr
# same for the bake_* programs
```

## License

See repository.
