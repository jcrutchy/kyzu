// ──────────────────────────────────────────────────────────────
//   Grid Uniform & Helpers
// ──────────────────────────────────────────────────────────────

struct GridUniform {
    view_proj:     mat4x4<f32>,
    inv_view_proj: mat4x4<f32>,
    eye_pos:       vec3<f32>,
    fade_near:     f32,
    fade_far:      f32,
    lod_scale:     f32,
    lod_fade:      f32,
    _pad:          f32,
    eye_mod_s0:    vec2<f32>,  // eye_pos rem s0, computed f64 CPU-side
    eye_mod_s1:    vec2<f32>,  // eye_pos rem s1, computed f64 CPU-side
    eye_mod_s2:    vec2<f32>,  // eye_pos rem s2, computed f64 CPU-side
    _pad2:         vec2<f32>,
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
//   Vertex Shader
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
    out.pos    = vec4<f32>(positions[vi], 1.0, 1.0);
    out.ndc_xy = positions[vi];
    return out;
}

// ──────────────────────────────────────────────────────────────
//   Unproject — returns camera-relative position (no eye_pos added)
//   Keeps values small regardless of where in world the eye is.
// ──────────────────────────────────────────────────────────────

fn unproject_rel(ndc_xy : vec2<f32>, ndc_z : f32) -> vec3<f32> {
    let clip  = vec4<f32>(ndc_xy, ndc_z, 1.0);
    let world = grid.inv_view_proj * clip;
    return world.xyz / world.w;
}

// ──────────────────────────────────────────────────────────────
//   Fragment Shader
// ──────────────────────────────────────────────────────────────

struct FsOut { @location(0) color : vec4<f32> };

@fragment
fn fs_main(in : VsOut) -> FsOut {
    // Unproject near and far in camera-relative space.
    // world z=0 is at camera-relative z = -eye_pos.z.
    let pos_near_rel = unproject_rel(in.ndc_xy, 0.0);
    let pos_far_rel  = unproject_rel(in.ndc_xy, 1.0);

    let target_z = -grid.eye_pos.z;
    let dz       = pos_far_rel.z - pos_near_rel.z;
    let t        = (target_z - pos_near_rel.z) / dz;

    if t <= 0.0 || t > 1.0 { discard; }

    // hit_rel: camera-relative intersection with world z=0 plane.
    // Always small — no absolute world coords used from here on.
    let hit_rel = pos_near_rel + t * (pos_far_rel - pos_near_rel);

    let view_dir     = normalize(pos_far_rel - pos_near_rel);
    let horizon_fade = smoothstep(0.0, 0.1, abs(view_dir.z));

    // Distance fade in camera-relative space (hit_rel.xy = offset from eye).
    let dist      = length(hit_rel.xy);
    let dist_fade = 1.0 - smoothstep(grid.fade_near, grid.fade_far, dist);

    let total_fade = dist_fade * horizon_fade;
    if total_fade <= 0.0 { discard; }

    let s0 = grid.lod_scale;
    let s1 = grid.lod_scale * 10.0;
    let s2 = grid.lod_scale * 100.0;

    // eye_mod_sN = eye_pos % sN, computed in f64 on the CPU — always in [0, sN).
    // Adding it to hit_rel maps the camera-relative hit back to world-grid space
    // so grid lines land at correct world-space integer multiples of each spacing,
    // without ever reconstructing the large absolute world coordinate in f32.
    let lod0 = max(grid_factor(hit_rel.x + grid.eye_mod_s0.x, s0),
                   grid_factor(hit_rel.y + grid.eye_mod_s0.y, s0));
    let lod1 = max(grid_factor(hit_rel.x + grid.eye_mod_s1.x, s1),
                   grid_factor(hit_rel.y + grid.eye_mod_s1.y, s1));
    let lod2 = max(grid_factor(hit_rel.x + grid.eye_mod_s2.x, s2),
                   grid_factor(hit_rel.y + grid.eye_mod_s2.y, s2));

    let final_minor = max(lod1, lod0 * (1.0 - grid.lod_fade));
    let final_major = lod2;

    // Axis lines: world x=0 / y=0.
    // hit_rel.xy + eye_pos.xy = absolute world xy — large when far from origin,
    // but axis lines naturally disappear then anyway (correct behaviour).
    let axis_xy = hit_rel.xy + grid.eye_pos.xy;
    let fw      = fwidth(axis_xy);
    let axis_x  = 1.0 - smoothstep(0.0, 1.0, abs(axis_xy.y) / fw.y);
    let axis_y  = 1.0 - smoothstep(0.0, 1.0, abs(axis_xy.x) / fw.x);

    let grid_base_color = mix(MINOR_COLOR, MAJOR_COLOR, final_major);

    var final_color = grid_base_color;
    final_color = mix(final_color, vec3<f32>(0.8, 0.1, 0.1), axis_x);
    final_color = mix(final_color, vec3<f32>(0.1, 0.6, 0.1), axis_y);

    let line_strength = max(max(final_minor, final_major), max(axis_x, axis_y));
    if line_strength < 0.001 { discard; }

    return FsOut(vec4<f32>(final_color, line_strength * total_fade));
}
