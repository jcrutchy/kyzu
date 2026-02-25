# Kyzu

A living-world simulation game built in Rust using wgpu. Single-player focus for now,
with the architecture designed from the ground up to support a massively multiplayer
online world with thousands of players and AI-driven NPCs.

---

## Vision

Most games feel stale after a while because their world model is fixed and authored.
Kyzu is built around the opposite philosophy: the world, its rules, its content layers,
and its NPC intelligence are all intended to emerge and evolve dynamically rather than
being hardcoded.

The core fantasy is a game you can watch running after a long day and find something
genuinely new happening — not because a designer scripted it, but because the simulation
produced it. Influences: Civ2/5, Minecraft, Timberborn, StarCraft: Broodwar, SimCity 2000.
What those games lack: continued playability at scale, dynamic world evolution, and
intelligent NPCs that grow over time.

---

## World Model

### Dynamic Layer System

Instead of fixed world layers (terrain, water, units, resources, etc.), Kyzu uses an
extensible layer abstraction. A handful of layers are defined at startup, but the engine
and AI can spawn new layers in response to local conditions — smog from industrialisation,
water pollution, magnetic field resources, plate tectonics, emergent "magic" systems, etc.

Layers can interact with each other. Those interaction rules may themselves be generated
dynamically. The player (and admin) relationship to the world is more like a gardener
than a game designer.

New layers and rules can also be injected manually via an in-game admin console or
config files.

### Scale

Truly infinite world — not "large enough that players won't reach the edge" but genuinely
unbounded, hosted across a distributed server architecture as required.

---

## Multiplayer Architecture (Future)

- Distributed world servers, each hosting a region
- Identity and world servers for authentication and world routing
- New players in a group spawn nearby each other
- Locally hostable for small friend groups, or joinable on large public worlds
- World servers can be added dynamically as the world expands

---

## NPC / AI System

NPCs are not scripted. The goal is neural-net-based agents with genetic evolution,
trained offline and periodically fed back into live servers to upgrade baseline
intelligence. Key properties:

- Agents model the world they exist in to make decisions, not just pattern-match
- Adversarial co-evolution: "red team" agents probe for exploits and cheats;
  "blue team" agents detect and patch rules to protect new players
  (essentially applying GAN-style dynamics to game integrity)
- NPC classes include: civilisation builders, traders, diplomats, world police,
  new-player protectors, and anti-cheat/anti-bully enforcers
- Offline training pits generations against each other continuously
- Trained weight improvements are pushed to live servers as upgrades
- No dependency on external LLMs — the agents must understand and model the
  game world specifically

---

## Gameplay Pillars

- Exploration of a truly infinite, ever-changing world
- Building, resource gathering, road/path optimisation
- Research and technology progression
- Diplomacy, religion, trade
- Strategic warfare
- "Watch it run" satisfaction — the simulation should be enjoyable to observe
  passively, not just to actively play
- Avoiding micromanagement hellscapes and repetitive late-game loops

---

## Technical Stack

| Concern | Choice | Notes |
|---|---|---|
| Language | Rust | Replaces JS prototype (Cartographica) |
| GPU | wgpu 0.20 | Vulkan/Metal/DX12 abstraction |
| Windowing | winit 0.29 | |
| Math | glam 0.27 | Retained despite NIH preference — too fundamental |
| Async | pollster 0.3 | Minimal, just for wgpu init |
| GPU casting | bytemuck 1.15 | |
| Editor | Geany | |
| Formatter | rustfmt (nightly) | Enforced via git pre-commit hook |

**Coordinate system:** Right-hand rule, Z-up (X right, Y forward, Z up).
This matches engineering convention (Autodesk Inventor, Strand7 FEA).

**Dependency philosophy:** Strong NIH preference. Avoid third-party crates unless
the alternative is implementing SIMD math or GPU internals from scratch.
glam is the main accepted exception.

**Target:** Native executable (Windows primary). No runtime dependencies outside
Windows core. WASM/kyzu-web is a possible future target but deprioritised — the
native path compiles to a self-contained exe which is preferable.

---

## Codebase Structure

```
kyzu-native/
  src/
    main.rs           -- entry point
    app.rs            -- event loop, window setup
    camera/
      mod.rs
      fixed.rs        -- Camera + CameraUniform (currently fixed, being refactored)
    input/
      mod.rs          -- InputState (mouse, keyboard, scroll)
    renderer/
      mod.rs
      core.rs         -- Renderer, wgpu init, render loop
      cube.rs         -- CubeMesh (placeholder geometry)
      depth.rs        -- DepthResources
    shaders/
      cube.wgsl       -- basic unlit cube shader
  Cargo.toml
  Cargo.lock          -- committed (binary crate)
```

---

## Coding Conventions

The author is a long-time Delphi/FreePascal and PHP developer learning Rust.
Hard preferences — all AI assistants should adhere to these:

- **Bracing:** Allman style (opening brace on its own line)
- **Indentation:** 2 spaces (Borland style)
- **Early returns** preferred over deeply nested conditionals
- **No closures** where a named function is feasible
- **No ternaries**
- **No regex**
- **Flat function structure** — extract helpers rather than nesting 15 levels deep
- **rustfmt** enforces formatting via nightly pre-commit hook

---

## Camera System (In Progress)

The camera is being refactored from a fixed position to a full CAD-style interactive
camera matching the feel of Autodesk Inventor and Strand7 FEA.

### Target design: Spherical coordinates

```
target:    Vec3   -- the world point being orbited/looked at
radius:    f32    -- distance from target to eye
azimuth:   f32    -- horizontal angle (radians)
elevation: f32    -- vertical angle from XY plane (radians)
```

Eye position is derived: `eye = target + spherical_to_cartesian(radius, azimuth, elevation)`

### Interaction model

| Input | Action |
|---|---|
| Right mouse drag | Orbit (change azimuth + elevation) |
| Middle mouse drag | Pan (translate target in camera-local XY) |
| Scroll wheel | Zoom (multiplicative: `radius *= factor`) |
| Click on geometry | Re-target orbit point |

### Zoom

Multiplicative zoom (`radius *= factor`) gives natural feel — slows near target,
accelerates when pulling back. Matches Inventor behaviour. A geometric clamp prevents
reaching zero or flipping.

Pitch clamp (limiting elevation away from ±90°) is desirable as an option to avoid
losing spatial orientation, but not mandatory.

### Floating origin (planned)

For infinite world support, camera and world positions will be stored as f64 internally.
The GPU uniform uploads only the f32 offset relative to the camera, keeping all GPU
values small and avoiding single-precision jitter at large coordinates.

---

## Known Issues / Immediate TODOs

1. **Depth buffer not resized on window resize** — `DepthResources` must be recreated
   alongside surface reconfigure when `WindowEvent::Resized` fires
2. **Surface not reconfigured on resize** — currently only reconfigured lazily on
   frame error; should be done explicitly in the resize handler
3. **Input collected but not consumed** — `InputState` tracks mouse/scroll/keyboard
   but nothing reads it yet to drive the camera
4. **Camera refactor** — replace fixed camera with spherical coordinate system (see above)
5. **Origin axis arrows** — X/Y/Z arrows at world origin for orientation reference
6. **Infinite XY grid** — Tron:Legacy-style fading grid on the XY plane

---

## History

Started as **Cartographica** — a JavaScript/WebGL/WebSocket massively multiplayer game
with a graph-of-tilemaps world architecture (each "island" hosted by its own server,
managed by a process manager). Hit fundamental performance and stability limits with
WebSocket latency, WebGL crashes on large worlds, and chunking overhead in the browser.

Pivoted to single-player to simplify, but the JS/browser stack remained a ceiling.
Renamed to **Kyzu** as the concept evolved from a tile-based map explorer to a
layer-based living simulation. Rewrote in Rust + wgpu to remove the browser ceiling
entirely and make a truly infinite world viable.
