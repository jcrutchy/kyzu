use glam::Mat4;

use super::spherical::Camera;

//
// ──────────────────────────────────────────────────────────────
//   Camera Uniform (GPU side)
// ──────────────────────────────────────────────────────────────
//

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct CameraUniform
{
  pub view_proj: [[f32; 4]; 4],
}

impl CameraUniform
{
  pub fn from_camera(camera: &Camera) -> Self
  {
    let mat: Mat4 = camera.build_view_proj();
    Self { view_proj: mat.to_cols_array_2d() }
  }
}
