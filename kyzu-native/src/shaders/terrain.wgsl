// ──────────────────────────────────────────────────────────────
//   Terrain Shader
//
//   Vertex positions are on a flat XY grid (camera-relative).
//   The vertex shader displaces Z by FBM noise to produce terrain.
//   Normals are computed via finite difference on the same noise.
//   Fragment shader applies height-based colour bands and optional
//   wireframe overlay via barycentric coordinates.
// ──────────────────────────────────────────────────────────────

// ──────────────────────────────────────────────────────────────
//   Uniforms
// ──────────────────────────────────────────────────────────────

struct CameraUniform {
    view_proj     : mat4x4<f32>,
    inv_view_proj : mat4x4<f32>,
    eye_world     : vec3<f32>,
    _pad          : f32,
};

struct TerrainUniform {
    // Noise parameters
    noise_scale    : f32,   // world-space frequency divisor
    amplitude      : f32,   // peak height
    octaves        : u32,   // FBM octave count (1..8)
    persistence    : f32,   // amplitude falloff per octave
    lacunarity     : f32,   // frequency multiplier per octave
    seed_offset    : f32,   // shifts the noise domain
    // Rendering
    wireframe      : u32,   // 0 = off, 1 = on
    _pad           : f32,
};

@group(0) @binding(0) var<uniform> camera  : CameraUniform;
@group(1) @binding(0) var<uniform> terrain : TerrainUniform;

// ──────────────────────────────────────────────────────────────
//   FBM / Value Noise
//   Uses a fast hash-based value noise so no texture is needed.
// ──────────────────────────────────────────────────────────────

fn hash2(p: vec2<f32>) -> f32 {
    var q = p;
    q = vec2<f32>(dot(q, vec2<f32>(127.1, 311.7)),
                  dot(q, vec2<f32>(269.5, 183.3)));
    return fract(sin(dot(q, vec2<f32>(1.0, 1.0))) * 43758.5453);
}

fn value_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f); // smoothstep

    let a = hash2(i + vec2<f32>(0.0, 0.0));
    let b = hash2(i + vec2<f32>(1.0, 0.0));
    let c = hash2(i + vec2<f32>(0.0, 1.0));
    let d = hash2(i + vec2<f32>(1.0, 1.0));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn fbm(world_xy: vec2<f32>) -> f32 {
    var p = world_xy / terrain.noise_scale + vec2<f32>(terrain.seed_offset);
    var value      = 0.0;
    var amplitude  = 1.0;
    var freq       = 1.0;
    var total_amp  = 0.0;

    for (var i = 0u; i < terrain.octaves; i++) {
        value     += value_noise(p * freq) * amplitude;
        total_amp += amplitude;
        amplitude *= terrain.persistence;
        freq      *= terrain.lacunarity;
    }

    // Normalise to [0, 1] then remap to [-1, 1]-ish ridge shape
    let n = value / total_amp;
    return (n - 0.5) * 2.0 * terrain.amplitude;
}

fn terrain_height(world_xy: vec2<f32>) -> f32 {
    return fbm(world_xy);
}

// Finite-difference normal — samples height at ±eps neighbours
fn terrain_normal(world_xy: vec2<f32>) -> vec3<f32> {
    let eps = terrain.noise_scale * 0.002;
    let hL  = terrain_height(world_xy - vec2<f32>(eps, 0.0));
    let hR  = terrain_height(world_xy + vec2<f32>(eps, 0.0));
    let hD  = terrain_height(world_xy - vec2<f32>(0.0, eps));
    let hU  = terrain_height(world_xy + vec2<f32>(0.0, eps));
    return normalize(vec3<f32>(hL - hR, hD - hU, 2.0 * eps));
}

// ──────────────────────────────────────────────────────────────
//   Vertex Shader
// ──────────────────────────────────────────────────────────────

struct VsIn {
    @location(0) pos_rel   : vec3<f32>,   // camera-relative XY flat position, Z=0
    @location(1) world_xy  : vec2<f32>,   // absolute world XY for noise sampling
    @location(2) bary      : vec3<f32>,   // barycentric coordinate for wireframe
};

struct VsOut {
    @builtin(position) clip_pos : vec4<f32>,
    @location(0) world_xy       : vec2<f32>,
    @location(1) height         : f32,
    @location(2) normal         : vec3<f32>,
    @location(3) bary           : vec3<f32>,
    @location(4) cam_dist       : f32,
};

@vertex
fn vs_main(in: VsIn) -> VsOut {
    let h       = terrain_height(in.world_xy);
    let n       = terrain_normal(in.world_xy);

    // Displace Z (up axis) by height, staying camera-relative
    let pos_displaced = vec3<f32>(in.pos_rel.x, in.pos_rel.y, h - camera.eye_world.z);

    var out: VsOut;
    out.clip_pos = camera.view_proj * vec4<f32>(pos_displaced, 1.0);
    out.world_xy = in.world_xy;
    out.height   = h;
    out.normal   = n;
    out.bary     = in.bary;
    out.cam_dist = length(in.pos_rel.xy);
    return out;
}

// ──────────────────────────────────────────────────────────────
//   Height-based colour bands
// ──────────────────────────────────────────────────────────────

fn terrain_color(h: f32, amp: f32) -> vec3<f32> {
    // Normalise height to [0, 1]
    let t = clamp((h / amp) * 0.5 + 0.5, 0.0, 1.0);

    let deep_water  = vec3<f32>(0.05, 0.15, 0.35);
    let shallow     = vec3<f32>(0.10, 0.40, 0.55);
    let sand        = vec3<f32>(0.76, 0.70, 0.50);
    let grass       = vec3<f32>(0.25, 0.55, 0.20);
    let rock        = vec3<f32>(0.45, 0.40, 0.35);
    let snow        = vec3<f32>(0.92, 0.94, 0.97);

    var c: vec3<f32>;
    if t < 0.30 {
        c = mix(deep_water, shallow, t / 0.30);
    } else if t < 0.38 {
        c = mix(shallow, sand, (t - 0.30) / 0.08);
    } else if t < 0.55 {
        c = mix(sand, grass, (t - 0.38) / 0.17);
    } else if t < 0.75 {
        c = mix(grass, rock, (t - 0.55) / 0.20);
    } else {
        c = mix(rock, snow, (t - 0.75) / 0.25);
    }
    return c;
}

// ──────────────────────────────────────────────────────────────
//   Fragment Shader
// ──────────────────────────────────────────────────────────────

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let base_color = terrain_color(in.height, terrain.amplitude);

    // Simple directional + ambient lighting
    let light_dir = normalize(vec3<f32>(0.4, 0.3, 1.0));
    let n         = normalize(in.normal);
    let diffuse   = clamp(dot(n, light_dir), 0.0, 1.0);
    let ambient   = 0.25;
    let lit       = base_color * (ambient + (1.0 - ambient) * diffuse);

    var final_color = lit;

    // Wireframe overlay
    if terrain.wireframe != 0u {
        let b         = in.bary;
        let fw        = fwidth(b);
        let edge_dist = smoothstep(vec3<f32>(0.0), fw * 1.5, b);
        let wire      = 1.0 - min(min(edge_dist.x, edge_dist.y), edge_dist.z);
        let wire_col  = vec3<f32>(0.9, 0.9, 0.6);
        final_color   = mix(final_color, wire_col, wire * 0.7);
    }

    return vec4<f32>(final_color, 1.0);
}
