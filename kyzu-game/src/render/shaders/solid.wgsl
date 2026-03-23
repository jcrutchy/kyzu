struct CameraUniform 
{
  view_proj: mat4x4<f32>,
  inv_view_proj: mat4x4<f32>,
  eye_world: vec3<f32>,
};

@group(0) @binding(0)
var<uniform> camera: CameraUniform;

struct VertexOutput 
{
  @builtin(position) clip_pos: vec4<f32>,
  @location(0) world_pos: vec3<f32>,
};

@vertex
fn vs_main(
  @location(0) position: vec3<f32>,
) -> VertexOutput 
{
  var out: VertexOutput;
  
  // Apply the camera transformation
  out.clip_pos = camera.view_proj * vec4<f32>(position, 1.0);
  out.world_pos = position;
  
  return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> 
{
  // Color it based on coordinates so we can see the 3D depth
  let color = normalize(abs(in.world_pos)) * 0.8 + 0.2;
  return vec4<f32>(color, 1.0);
}
