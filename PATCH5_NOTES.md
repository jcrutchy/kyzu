Patch 5 — AI road explosion + unit snapshot fix

Findings from the supplied events.jsonl and current map screenshot:
- 4,465 roads are owned by ai_east, exactly C(95,2): the AI was building a complete graph of 95 cities.
- 561 roads are owned by ai, exactly C(34,2): same complete-graph policy.
- The roads are not duplicate endpoint pairs; they are a deliberately over-connected mesh.
- The map's unit_list handler expected `id`, while KYZU emits `unit_id`, so snapshot units were being discarded.

Changes:
1. kyzu_ai.pas: connect each AI city to its two nearest AI-owned cities instead of every pair. This keeps road growth roughly linear while retaining a useful network.
2. kyzu_map.html: accept `unit_id` from game.event.unit_list, with `id` as a compatibility fallback.
3. kyzu_map.html: render the current road view once into an offscreen bitmap and blit it each frame. Rebuild only on view/road-data changes, avoiding a full multi-thousand-road vector stroke on every animation frame.

Important:
- Existing saved worlds still contain their historical 5,026 roads. Patch 5 prevents further quadratic growth and makes rendering of the existing network cheaper, but it does not automatically delete historical roads. A separate, explicit road-compaction migration would be safer than silently mutating the saved world.
