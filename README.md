# kyzu

Global terrain map server and unit simulation for a real-world geographic grid.

Bakes landcover / heightmap / movement tiles from GlobCover + ETOPO GeoTIFFs, then runs a lightweight game server that pathfinds and moves units over the resulting movement grid.

Uses [vdrx](https://github.com/jcrutchy/vdrx) for the message bus and process supervision. kyzu talks to the bus via JSON lines on stdin/stdout.

## Components

| Binary | Purpose |
|--------|---------|
| `kyzu` | Game server: spawn/move units, A* pathfinding, position updates, event log replay |
| `kyzu_bake_tiles` | Landcover tile pyramid (PNG) |
| `kyzu_bake_heightmap_tiles` | Heightmap tiles |
| `kyzu_bake_combined_tiles` | Combined landcover + shaded heightmap |
| `kyzu_bake_movecost_tiles` | Movement-cost visualization tiles |
| `kyzu_bake_movement_grid` | Binary movement grid (`KYTR` format) used by the server |
| `kyzu_bake_terrain` | Terrain bake helper |

## Requirements

- Free Pascal
- GeoTIFF sources (GlobCover landcover, ETOPO elevation)
- [vdrx](https://github.com/jcrutchy/vdrx) to run the server under supervision

## Config

`bake_config.json` holds paths, tile size, landcover classes (with `move_cost`), shading, and hypsometric colors.

## Protocol (kyzu ↔ vdrx)

Commands (stdin):

- `game.cmd.ping`
- `game.cmd.spawn` — `{unit_id, lon, lat}`
- `game.cmd.move` — `{unit_id, to_lon, to_lat}`

Events (stdout):

- `game.event.pong`
- `game.event.spawned` / `spawn_failed`
- `game.event.path_found` / `move_failed`
- `game.event.position`
- `game.event.arrived`

State is persisted in `events.jsonl` and replayed on startup.

## Build

```bash
fpc -Mobjfpc -Sh kyzu.lpr
# same for the bake_* programs
```

## License

See repository.