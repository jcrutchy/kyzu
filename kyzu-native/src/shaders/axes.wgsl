// ──────────────────────────────────────────────────────────────
//   Camera Uniform (shared with cube pipeline)
// ──────────────────────────────────────────────────────────────

struct CameraUniform
{
  view_proj : mat4x4<f32>,
};

@group(0) @binding(0)
var<uniform> camera : CameraUniform;

// ──────────────────────────────────────────────────────────────
//   Vertex / fragment structs
// ──────────────────────────────────────────────────────────────

struct VsIn
{
  @location(0) position : vec3<f32>,
  @location(1) colour   : vec3<f32>,
};

struct VsOut
{
  @builtin(position) pos    : vec4<f32>,
  @location(0)       colour : vec3<f32>,
};

// ──────────────────────────────────────────────────────────────
//   Vertex shader
// ──────────────────────────────────────────────────────────────

@vertex
fn vs_main(in : VsIn) -> VsOut
{
  var out : VsOut;
  out.pos    = camera.view_proj * vec4<f32>(in.position, 1.0);
  out.colour = in.colour;
  return out;
}

// ──────────────────────────────────────────────────────────────
//   Fragment shader
// ──────────────────────────────────────────────────────────────

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32>
{
  return vec4<f32>(in.colour, 1.0);
}
