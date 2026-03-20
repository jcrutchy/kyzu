struct SceneUniform
{
  view_proj: mat4x4<f32>,
};

struct EntityUniform
{
  model_mat: mat4x4<f32>,
  extra_data: vec4<f32>, 
};

@group(0) @binding(0) var<uniform> scene: SceneUniform;
@group(1) @binding(0) var<uniform> entity: EntityUniform;

struct VertexInput
{
  @location(0) pos: vec3<f32>,
  @location(1) hex_id: u32,
  @location(2) bary: vec2<f32>,
};

struct VertexOutput
{
  @builtin(position) clip_position: vec4<f32>,
  @location(0) world_pos: vec3<f32>,
  @location(1) bary: vec2<f32>,
  @location(2) @interpolate(flat) mode: f32,
};

@vertex
fn vs_main(model: VertexInput) -> VertexOutput
{
  var out: VertexOutput;
  let world_pos = entity.model_mat * vec4<f32>(model.pos, 1.0);
  out.world_pos = world_pos.xyz;
  out.clip_position = scene.view_proj * world_pos;
  out.bary = model.bary;
  out.mode = entity.extra_data.x;
  return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32>
{
  // --- MODE 2: ORBIT RINGS ---
  if (in.mode > 1.5)
  {
    return vec4<f32>(1.0, 0.0, 1.0, 1.0); // Neon Pink for debugging
  }

  // --- MODE 1: THE SUN ---
  if (in.mode > 0.5)
  {
    return vec4<f32>(1.0, 0.9, 0.4, 1.0);
  }

  // --- MODE 0: PLANET LIGHTING ---
  let planet_center = entity.model_mat[3].xyz;
  let normal = normalize(in.world_pos - planet_center);
  
  let sun_pos = vec3<f32>(0.0, 0.0, 0.0);
  let light_dir = normalize(sun_pos - in.world_pos);
  
  let dot_nl = dot(normal, light_dir);
  let light_intensity = saturate(dot_nl) + 0.05; 

  let dist = length(in.world_pos - planet_center);
  let scale = length(entity.model_mat[0].xyz);
  let h = dist / scale;

  var color: vec3<f32>;
  if (h < 1.01) { color = vec3<f32>(0.05, 0.15, 0.5); }
  else if (h < 1.03) { color = vec3<f32>(0.7, 0.65, 0.4); }
  else { color = vec3<f32>(0.1, 0.4, 0.15); }

  let b = vec3<f32>(in.bary.x, in.bary.y, 1.0 - in.bary.x - in.bary.y);
  let is_edge = step(min(b.x, min(b.y, b.z)), 0.03);
  let final_color = mix(color, color * 0.4, is_edge) * light_intensity;

  return vec4<f32>(final_color, 1.0);
}
