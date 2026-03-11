// ──────────────────────────────────────────────────────────────
//   Earth Terrain Shader
//
//   Vertices are stored in world-space ENU (East-North-Up).
//   The vertex shader subtracts eye position to get
//   camera-relative coords before applying view_proj.
//
//   This means chunks never need re-uploading when camera moves.
// ──────────────────────────────────────────────────────────────

struct CameraUniform {
    view_proj     : mat4x4<f32>,
    inv_view_proj : mat4x4<f32>,
    eye_world     : vec3<f32>,
    _pad          : f32,
};

@group(0) @binding(0) var<uniform> camera : CameraUniform;

// ──────────────────────────────────────────────────────────────
//   Vertex
// ──────────────────────────────────────────────────────────────

struct VsIn {
    @location(0) world_pos : vec3<f32>,  // ENU world-space position
    @location(1) normal    : vec3<f32>,  // surface normal
    @location(2) elevation : f32,        // raw elevation metres (for colouring)
};

struct VsOut {
    @builtin(position) clip_pos : vec4<f32>,
    @location(0) normal         : vec3<f32>,
    @location(1) elevation      : f32,
    @location(2) cam_dist       : f32,
};

@vertex
fn vs_main(in: VsIn) -> VsOut {
    // Subtract eye in world space — keeps values small for GPU precision
    let rel = in.world_pos - camera.eye_world;

    var out: VsOut;
    out.clip_pos  = camera.view_proj * vec4<f32>(rel, 1.0);
    out.normal    = in.normal;
    out.elevation = in.elevation;
    out.cam_dist  = length(rel);
    return out;
}

// ──────────────────────────────────────────────────────────────
//   Colour bands
//
//   Simple elevation-based palette, Civ5-ish feel.
//   Ocean uses bathymetry depth for colour variation.
// ──────────────────────────────────────────────────────────────

fn terrain_color(elev: f32) -> vec3<f32> {
    // Ocean / bathymetry
    if elev < -200.0 {
        let t = clamp((-elev - 200.0) / 8000.0, 0.0, 1.0);
        return mix(vec3<f32>(0.10, 0.28, 0.52), vec3<f32>(0.03, 0.10, 0.28), t);
    }
    if elev < 0.0 {
        let t = clamp(-elev / 200.0, 0.0, 1.0);
        return mix(vec3<f32>(0.22, 0.52, 0.72), vec3<f32>(0.10, 0.28, 0.52), t);
    }

    // Coast / beach
    if elev < 30.0 {
        let t = elev / 30.0;
        return mix(vec3<f32>(0.82, 0.78, 0.58), vec3<f32>(0.82, 0.78, 0.58), t);
    }

    // Lowland
    if elev < 200.0 {
        let t = (elev - 30.0) / 170.0;
        return mix(vec3<f32>(0.52, 0.68, 0.35), vec3<f32>(0.42, 0.60, 0.28), t);
    }

    // Highland
    if elev < 1000.0 {
        let t = (elev - 200.0) / 800.0;
        return mix(vec3<f32>(0.42, 0.60, 0.28), vec3<f32>(0.48, 0.44, 0.36), t);
    }

    // Mountain
    if elev < 2500.0 {
        let t = (elev - 1000.0) / 1500.0;
        return mix(vec3<f32>(0.48, 0.44, 0.36), vec3<f32>(0.62, 0.58, 0.52), t);
    }

    // Snow
    let t = clamp((elev - 2500.0) / 1500.0, 0.0, 1.0);
    return mix(vec3<f32>(0.62, 0.58, 0.52), vec3<f32>(0.93, 0.95, 0.98), t);
}

// ──────────────────────────────────────────────────────────────
//   Fragment
// ──────────────────────────────────────────────────────────────

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let base = terrain_color(in.elevation);

    // Simple directional light + ambient
    let light_dir = normalize(vec3<f32>(0.4, 0.3, 1.0));
    let n         = normalize(in.normal);
    let diffuse   = clamp(dot(n, light_dir), 0.0, 1.0);
    let ambient   = 0.35;
    let lit       = base * (ambient + (1.0 - ambient) * diffuse);

    return vec4<f32>(lit, 1.0);
}
