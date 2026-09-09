# kyzu

Global terrain map server and macro-strategy unit simulation running on a real-world geographic grid.

Bakes landcover / heightmap / movement tiles from GlobCover + ETOPO GeoTIFFs, then runs a lightweight game server that pathfinds and moves units, manages factions, resource collection, cities, roads, and combat over the resulting movement grid — including a built-in AI-controlled faction.

Runs as a supervised child process under [vdrx](https://github.com/jcrutchy/vdrx), which provides the message bus, process supervision, HTTP static/tile serving, and the WebSocket bridge that browser clients connect through. kyzu itself only ever speaks JSON lines on stdin/stdout — it has no knowledge of HTTP, WebSockets, or vdrx's own internals.

See **[KYZU_VDRX_API.md](KYZU_VDRX_API.md)** for the full command/event protocol reference and a detailed look at how the game server and its built-in AI interface with vdrx's bus, HTTP sites, and WebSocket bridge.

## Components

| Binary | Purpose |
| --- | --- |
| `kyzu` | Game server: units, ownership, pathfinding, resource collection, cities/roads, combat, veterancy, an AI opponent faction, event-log replay |
| `kyzu_bake_tiles` | Landcover tile pyramid (PNG) |
| `kyzu_bake_heightmap_tiles` | Heightmap tiles |
| `kyzu_bake_combined_tiles` | Combined landcover + shaded heightmap |
| `kyzu_bake_movecost_tiles` | Movement-cost visualization tiles |
| `kyzu_bake_movement_grid` | Binary movement grid (`KYTR` format) used by the server |
| `kyzu_bake_terrain` | Terrain bake helper |

## Requirements

- Free Pascal (FPC 3.2.2+)
- GeoTIFF sources (GlobCover landcover, ETOPO elevation) for the bake pipeline
- [vdrx](https://github.com/jcrutchy/vdrx) to run the server under supervision and expose it over HTTP/WebSocket

## Config & data files

All of these are loaded once at startup with tolerant, non-fatal fallbacks — a missing or malformed file never stops the server from starting, it just means that piece of content/tuning falls back to built-in defaults.

| File | Purpose | If missing |
| --- | --- | --- |
| `bake_config.json` | Paths, tile size, landcover classes (with `move_cost`), shading, hypsometric colors — used by both the bake tools and the running server | Required for the bake pipeline; server needs it to find the movement grid |
| `game_balance.json` | Every tunable gameplay number — movement speed, collection amounts/radius, city growth/upkeep costs and intervals, development radii, combat range/damage, veterancy thresholds, AI worker targets, etc. | Falls back to built-in defaults matching the values shipped in code |
| `unit_types.json` | Unit type registry: `speed_multiplier`, `can_found_city`, `can_collect`, `collect_multiplier`, `hp`, `attack` per `type_id` | All unit types fall back to a generic default (normal speed, can found, can collect, 20 HP, non-combatant) |
| `resource_nodes.json` | Static, depletable resource nodes: `id`, `resource_type`, `lon`, `lat`, `amount` | Server starts with zero nodes |
| `cities.json` | Seed cities: `id`, `owner`, `lon`, `lat`, `population` | Server starts with zero seed cities — cities can still be founded live |
| `events.jsonl` | Append-only outcome log (spawns, paths, collections, city/road/combat events) — **not hand-edited**, replayed on every startup to reconstruct state | Server starts fresh with empty state |

## Protocol (kyzu ↔ vdrx)

kyzu reads one JSON command per line on stdin and writes one JSON event per line on stdout, in the `{"topic":"...","payload":"..."}` envelope vdrx's bridge expects. Full reference — every command, every event, the ownership model, and how the built-in AI uses the exact same command handlers a real client does — is in **[KYZU_VDRX_API.md](KYZU_VDRX_API.md)**.

Quick summary of the command surface:

- **Units** — `game.cmd.spawn`, `despawn`, `move`, `collect`
- **Factions** — `game.cmd.get_ledger`
- **Cities & roads** — `game.cmd.found_city`, `build_road`, `list_cities`, `list_roads`, `get_development`
- **Combat** — `game.cmd.attack` (unit-vs-unit or unit-vs-city, with veterancy)
- **Misc** — `game.cmd.ping`, `game.cmd.list_nodes`

State is persisted as resolved outcomes (not raw commands) in `events.jsonl` and replayed in full before the server accepts any live commands.

## Frontends

Two browser clients live under `web/`, both connecting to vdrx's WebSocket bridge:

- `web/static/index.html` — a bus terminal dev console: live pub/sub log, topic filter, quick-command buttons. Useful for poking at the protocol directly.
- `web/map/static/index.html` — the full map viewer: tile layers (landcover/heightmap/combined/movecost), live WebSocket-driven units with position interpolation, click-to-select/click-to-move, resource nodes, cities, roads, development overlay, combat, pan/zoom, touch support.

## Running under vdrx

vdrx supervises the `kyzu` process and serves its static/tile content and WebSocket bridge on separate ports (see `kyzu.vdrx.conf`, loaded via vdrx's `includes` mechanism). See **KYZU_VDRX_API.md** for the exact HTTP/WS wiring.

## Build

```
fpc -Mobjfpc -Sh kyzu.lpr
# same for the bake_* programs
```

## License

See repository.
