# KYZU first patch

## Fixed

- `game.cmd.spawn` now validates longitude/latitude before converting to grid coordinates.
- `game.cmd.move` now validates destination longitude/latitude before converting to grid coordinates.
- Rejects NaN/infinite coordinates as out of bounds.
- Valid endpoint coordinates (`-180..180` longitude, `-90..90` latitude) retain the existing endpoint-to-cell mapping.

## Why

`LonToGridX()` and `LatToGridY()` intentionally clamp converted coordinates to the grid edges. The old command handlers validated only the converted cell, so an input such as `lon=999` or `lat=-999` was silently accepted as an edge-cell operation.


# KYZU JSON serialization patch #2

Base: the first patch that compiled successfully in the user's environment.

Changes:
- Added JsonQuote(), which emits RFC 8259-compatible JSON string literals.
- Added MakeEventLine(), preserving KYZU's existing topic + string-valued payload wire format.
- Converted node-list output to structured escaping.
- Converted spawn/despawn/move/collect event output and event-log strings to use JsonQuote().
- Preserved the coordinate-validation changes from patch #1.

This is intentionally incremental: other hand-built JSON sites remain for later passes.

Validation in this environment:
- Source-level string/escape checks passed.
- Free Pascal compiler is not installed here, so a local compile is still required.




# KYZU patch 3 – complete JSON serialization pass

Built on the previously compiled patch 2.

## What changed
- Uses `JsonQuote` for remaining JSON string values in events/snapshots/AI-generated command payloads.
- Uses `MakeEventLine` for remaining nested VDRX event payloads, preserving the existing `payload`-as-JSON-string wire format.
- Fixes JSON escaping in city, road, combat, research, diplomacy, tech-status and movement/position events.
- Fixes nested JSON lists such as costs, tech prerequisites, cities, roads and diplomacy relations.
- Preserves the coordinate validation and earlier JSON changes from patches 1 and 2.

## Verification
The source was statically checked for remaining `Format('{...%s...}')` JSON builders and `SendLine(Format(...payload...))` builders; none remain except the numeric-only `game.tick` line. No Free Pascal compiler is available in this environment, so compilation must be performed locally as before.
