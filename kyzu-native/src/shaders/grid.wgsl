// ──────────────────────────────────────────────────────────────
//   Grid Uniform
// ──────────────────────────────────────────────────────────────

struct GridUniform {
    view_proj: mat4x4<f32>,
    inv_view_proj: mat4x4<f32>,
    eye_pos: vec3<f32>,
    fade_near: f32, // Automatically occupies the 4th component of the eye_pos alignment
    fade_far: f32,  // Starts the next 16-byte block
    lod_scale: f32,
    lod_fade: f32,
};

@group(0) @binding(0)
var<uniform> grid : GridUniform;

// ──────────────────────────────────────────────────────────────
//   Constants
// ──────────────────────────────────────────────────────────────

const MINOR_SPACING : f32       = 1.0;
const MAJOR_SPACING : f32       = 10.0;
const MINOR_COLOR   : vec3<f32> = vec3<f32>(0.15, 0.35, 0.55);
const MAJOR_COLOR   : vec3<f32> = vec3<f32>(0.20, 0.55, 0.80);

// ──────────────────────────────────────────────────────────────
//   Vertex shader — emits a full-screen triangle (3 verts, no VBO)
// ──────────────────────────────────────────────────────────────

struct VsOut
{
  @builtin(position) pos    : vec4<f32>,
  @location(0)       ndc_xy : vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi : u32) -> VsOut
{
  var positions = array<vec2<f32>, 3>(
    vec2<f32>(-1.0, -1.0),
    vec2<f32>( 3.0, -1.0),
    vec2<f32>(-1.0,  3.0),
  );

  let p = positions[vi];

  var out : VsOut;
  out.pos    = vec4<f32>(p, 1.0, 1.0);
  out.ndc_xy = p;
  return out;
}

// ──────────────────────────────────────────────────────────────
//   Helpers
// ──────────────────────────────────────────────────────────────

fn unproject(ndc_xy : vec2<f32>, ndc_z : f32) -> vec3<f32>
{
  let clip  = vec4<f32>(ndc_xy, ndc_z, 1.0);
  let world = grid.inv_view_proj * clip;
  return world.xyz / world.w;
}

fn grid_factor(world_coord : f32, spacing : f32) -> f32
{
    let scaled = world_coord / spacing;
    let derivative = fwidth(scaled);
    
    // We cap the derivative to prevent the line from getting 
    // infinitely thick/blurry at the horizon.
    let grid = abs(fract(scaled - 0.5) - 0.5) / derivative;
    
    // Falloff: If the line is narrower than half a pixel, we start fading it out
    // instead of letting it turn into a "dashed" artifact.
    let falloff = 1.0 - smoothstep(0.0, 0.5, derivative);
    
    return (1.0 - clamp(grid, 0.0, 1.0)) * falloff;
}

// ──────────────────────────────────────────────────────────────
//   Fragment shader
// ──────────────────────────────────────────────────────────────

struct FsOut
{
  @location(0) color : vec4<f32>,
};

@fragment
fn fs_main(in : VsOut) -> FsOut
{
    let pos_near = unproject(in.ndc_xy, 0.0);
    let pos_far  = unproject(in.ndc_xy, 1.0);

    let t = -pos_near.z / (pos_far.z - pos_near.z);
    if t <= 0.0 { discard; }

    let world_pos = pos_near + t * (pos_far - pos_near);

    // --- FIX: The Horizon Alpha Kill ---
    // This is the most important part for your screenshots.
    // It fades the grid as the view becomes parallel to the floor.
    let view_dir = normalize(pos_far - pos_near);
    let horizon_fade = clamp(abs(view_dir.z) * 10.0, 0.0, 1.0);

    let dist = length(world_pos.xy - grid.eye_pos.xy);
    let fade = 1.0 - clamp(
        (dist - grid.fade_near) / (grid.fade_far - grid.fade_near),
        0.0,
        1.0,
    );

    // Combine all fades
    let total_fade = fade * horizon_fade;
    if total_fade <= 0.0 { discard; }

    // --- Original LOD Logic (Unchanged Spacing) ---
    let s0 = grid.lod_scale;
    let s1 = grid.lod_scale * 10.0;
    let s2 = grid.lod_scale * 100.0;

    let lod0 = max(grid_factor(world_pos.x, s0), grid_factor(world_pos.y, s0));
    let lod1 = max(grid_factor(world_pos.x, s1), grid_factor(world_pos.y, s1));
    let lod2 = max(grid_factor(world_pos.x, s2), grid_factor(world_pos.y, s2));

    let on_minor = lod1;
    let on_major = lod2;
    let on_tiny  = lod0 * (1.0 - grid.lod_fade); 

    let final_minor = max(on_minor, on_tiny);
    let final_major = on_major;

    if final_minor < 0.01 && final_major < 0.01 { discard; }

    let color = mix(MINOR_COLOR, MAJOR_COLOR, final_major);
    let alpha = max(final_minor, final_major) * total_fade;

    var out : FsOut;
    out.color = vec4<f32>(color, alpha);
    return out;
}
