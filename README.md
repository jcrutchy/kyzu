# kyzu

Global terrain map server and unit simulation for a real-world geographic grid.

Bakes landcover / heightmap / movement tiles from GlobCover + ETOPO GeoTIFFs, then runs a lightweight game server that pathfinds and moves units over the resulting movement grid.

Uses [vdrx](https://github.com/jcrutchy/vdrx) for the message bus and process supervision. kyzu talks to the bus via JSON lines on stdin/stdout.

## Components

| Binary                      | Purpose                                                                            |
| --------------------------- | ---------------------------------------------------------------------------------- |
| `kyzu`                      | Game server: spawn/move/despawn units, A\* pathfinding, position updates, event log replay |
| `kyzu_bake_tiles`           | Landcover tile pyramid (PNG)                                                       |
| `kyzu_bake_heightmap_tiles` | Heightmap tiles                                                                    |
| `kyzu_bake_combined_tiles`  | Combined landcover + shaded heightmap                                              |
| `kyzu_bake_movecost_tiles`  | Movement-cost visualization tiles                                                  |
| `kyzu_bake_movement_grid`   | Binary movement grid (`KYTR` format) used by the server                            |
| `kyzu_bake_terrain`         | Terrain bake helper                                                                |

## Requirements

- Free Pascal
- GeoTIFF sources (GlobCover landcover, ETOPO elevation)
- [vdrx](https://github.com/jcrutchy/vdrx) to run the server under supervision

## Config

`bake_config.json` holds paths, tile size, landcover classes (with `move_cost`), shading, and hypsometric colors.

## Protocol (kyzu ↔ vdrx)

Commands (stdin):

- `game.cmd.ping`
- `game.cmd.spawn` — `{unit_id, lon, lat, owner, unit_type}` — `owner` and `unit_type` are both optional; an empty/omitted `owner` spawns an unowned unit anyone can command
- `game.cmd.move` — `{unit_id, to_lon, to_lat, by}` — `by` is the acting faction; required to move a unit that has a non-empty `owner`, ignored for unowned units
- `game.cmd.despawn` — `{unit_id, by}` — same ownership rule as `move`

Events (stdout):

- `game.event.pong`
- `game.event.spawned` — `{unit_id, owner, unit_type, lon, lat}` / `spawn_failed`
- `game.event.path_found` / `move_failed` (reasons include `unknown unit`, `no path`, `not your unit`)
- `game.event.position`
- `game.event.arrived`
- `game.event.despawned` — `{unit_id}` / `despawn_failed` (reasons: `unknown unit`, `not your unit`)

Ownership: a unit's `owner` is set once at spawn and never changes. `owner = ''` (the default) means the unit is unowned and free for anyone to `move`/`despawn` regardless of what `by` they send — this keeps quick ad-hoc testing (e.g. via the bus terminal, which never sends `by`) working without needing a faction identity. A unit spawned with a non-empty `owner` can only be moved or despawned by a matching `by`.

State is persisted in `events.jsonl` and replayed on startup.

## Build

```
fpc -Mobjfpc -Sh kyzu.lpr
# same for the bake_* programs
```

## License

See repository.
