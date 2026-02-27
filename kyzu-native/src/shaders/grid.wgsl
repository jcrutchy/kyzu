// ──────────────────────────────────────────────────────────────
//   Grid Uniform & Helpers
// ──────────────────────────────────────────────────────────────

struct GridUniform {
    view_proj: mat4x4<f32>,
    inv_view_proj: mat4x4<f32>,
    eye_pos: vec3<f32>,
    fade_near: f32,
    fade_far: f32,
    lod_scale: f32,
    lod_fade: f32,
};

@group(0) @binding(0)
var<uniform> grid : GridUniform;

const MINOR_COLOR : vec3<f32> = vec3<f32>(0.15, 0.35, 0.55);
const MAJOR_COLOR : vec3<f32> = vec3<f32>(0.20, 0.55, 0.80);

fn grid_factor(world_coord: f32, spacing: f32) -> f32 {
    let coord = world_coord / spacing;
    
    // derivative represents "how many world units fit in one pixel"
    let derivative = fwidth(coord);
    
    // Calculate distance to nearest line in screen-space pixels
    let dist = abs(fract(coord - 0.5) - 0.5) / derivative;
    
    // Standard 1-pixel wide line with 0.5-pixel AA edge
    let line = 1.0 - smoothstep(0.0, 1.0, dist);
    
    // Moiré Killer: Fades lines out if they are closer than 2 pixels apart
    let moire_fader = 1.0 - smoothstep(0.4, 0.5, derivative);
    
    return line * moire_fader;
}

// ──────────────────────────────────────────────────────────────
//   Vertex & Unproject
// ──────────────────────────────────────────────────────────────

struct VsOut {
    @builtin(position) pos : vec4<f32>,
    @location(0) ndc_xy : vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi : u32) -> VsOut {
    var positions = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0)
    );
    var out: VsOut;
    out.pos = vec4<f32>(positions[vi], 1.0, 1.0);
    out.ndc_xy = positions[vi];
    return out;
}

fn unproject(ndc_xy : vec2<f32>, ndc_z : f32) -> vec3<f32> {
    let clip = vec4<f32>(ndc_xy, ndc_z, 1.0);
    let world = grid.inv_view_proj * clip;
    return world.xyz / world.w;
}

// ──────────────────────────────────────────────────────────────
//   Fragment Shader (The Clean Solution)
// ──────────────────────────────────────────────────────────────

struct FsOut { @location(0) color : vec4<f32> };

@fragment
fn fs_main(in : VsOut) -> FsOut {
    let pos_near = unproject(in.ndc_xy, 0.0);
    let pos_far  = unproject(in.ndc_xy, 1.0);

    let t = -pos_near.z / (pos_far.z - pos_near.z);
    
    // Kill pixels above horizon or too far for float precision (relative to zoom)
    if t <= 0.0 || t > 1e9 { discard; }

    let world_pos = pos_near + t * (pos_far - pos_near);

    // 1. Horizon Safety: Fades grid when view is nearly parallel to plane
    let view_dir = normalize(pos_far - pos_near);
    let horizon_fade = smoothstep(0.0, 0.1, abs(view_dir.z));

    // 2. Relative Distance Fade
    let dist = length(world_pos.xy - grid.eye_pos.xy);
    let dist_fade = 1.0 - smoothstep(grid.fade_near, grid.fade_far, dist);

    let total_fade = dist_fade * horizon_fade;
    if total_fade <= 0.0 { discard; }

    // 3. Scale-Invariant Procedural Draw
    // s0 = fading sub-grid, s1 = standard grid, s2 = major grid
    let s0 = grid.lod_scale;
    let s1 = grid.lod_scale * 10.0;
    let s2 = grid.lod_scale * 100.0;

    let lod0 = max(grid_factor(world_pos.x, s0), grid_factor(world_pos.y, s0));
    let lod1 = max(grid_factor(world_pos.x, s1), grid_factor(world_pos.y, s1));
    let lod2 = max(grid_factor(world_pos.x, s2), grid_factor(world_pos.y, s2));

    // Transition math: lod0 dissolves as you zoom out
    let final_minor = max(lod1, lod0 * (1.0 - grid.lod_fade));
    let final_major = lod2;

    if final_minor < 0.001 && final_major < 0.001 { discard; }

    let color = mix(MINOR_COLOR, MAJOR_COLOR, final_major);
    let alpha = max(final_minor, final_major) * total_fade;

    return FsOut(vec4<f32>(color, alpha));
}
