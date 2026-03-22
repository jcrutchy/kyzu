use glam;

// Double precision for the "Infinite" simulation
pub type WorldVec3 = glam::DVec3;
pub type WorldMat4 = glam::DMat4;

// Single precision for the GPU (wgpu-compatible)
pub type RenderVec2 = glam::Vec2;
pub type RenderVec3 = glam::Vec3;
pub type RenderMat4 = glam::Mat4;

pub struct Viewport
{
  pub width: f32,
  pub height: f32,
}

// Crucial: Translates a high-precision world position to a camera-relative GPU position
pub fn world_to_render_pos(world_pos: WorldVec3, camera_pos: WorldVec3) -> RenderVec3
{
  let relative = world_pos - camera_pos;

  // Cast to f32 only after the subtraction to preserve precision
  glam::vec3(relative.x as f32, relative.y as f32, relative.z as f32)
}

pub fn get_aspect_ratio(viewport: &Viewport) -> f32
{
  if viewport.height > 0.0
  {
    return viewport.width / viewport.height;
  }
  1.0
}
