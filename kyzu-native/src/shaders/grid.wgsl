// ──────────────────────────────────────────────────────────────
//   Grid Uniform
// ──────────────────────────────────────────────────────────────

struct GridUniform
{
  view_proj:     mat4x4<f32>,   //  64 bytes
  inv_view_proj: mat4x4<f32>,   //  64 bytes
  eye_pos:       vec3<f32>,     //  16 bytes (vec3 is 16-byte aligned in WGSL)
  fade_near:     f32,           //   4 bytes
  fade_far:      f32,           //   4 bytes
  _pad:          vec2<f32>,     //   8 bytes  → 176 total
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
  let grid   = abs(fract(scaled - 0.5) - 0.5) / fwidth(scaled);
  return 1.0 - clamp(grid, 0.0, 1.0);
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

  // Ray-plane intersection at Z = 0
  let t = -pos_near.z / (pos_far.z - pos_near.z);

  if t <= 0.0
  {
    discard;
  }

  let world_pos = pos_near + t * (pos_far - pos_near);

  // Distance fade — scales with camera radius via uniform
  let dist = length(world_pos.xy - grid.eye_pos.xy);
  let fade = 1.0 - clamp(
    (dist - grid.fade_near) / (grid.fade_far - grid.fade_near),
    0.0,
    1.0,
  );

  if fade <= 0.0
  {
    discard;
  }

  // Grid line factors
  let minor_x = grid_factor(world_pos.x, MINOR_SPACING);
  let minor_y = grid_factor(world_pos.y, MINOR_SPACING);
  let major_x = grid_factor(world_pos.x, MAJOR_SPACING);
  let major_y = grid_factor(world_pos.y, MAJOR_SPACING);

  let on_minor = max(minor_x, minor_y);
  let on_major = max(major_x, major_y);

  if on_minor < 0.01 && on_major < 0.01
  {
    discard;
  }

  let color = mix(MINOR_COLOR, MAJOR_COLOR, on_major);
  let alpha  = max(on_minor, on_major) * fade;

  var out : FsOut;
  out.color = vec4<f32>(color, alpha);
  return out;
}
