use glam::Mat4;

use super::spherical::Camera;

//
// ──────────────────────────────────────────────────────────────
//   Camera Uniform (GPU side)
//
//   WGSL layout (axes.wgsl, cube.wgsl):
//     view_proj : mat4x4<f32>   → 64 bytes
//   Total: 64 bytes
// ──────────────────────────────────────────────────────────────
//

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct CameraUniform
{
  pub view_proj: [[f32; 4]; 4], // 64 bytes
}

// Catch CPU/GPU layout mismatches at compile time
const _: () = assert!(std::mem::size_of::<CameraUniform>() == 64);

impl CameraUniform
{
  pub fn from_camera(camera: &Camera) -> Self
  {
    let mat: Mat4 = camera.build_view_proj();
    Self { view_proj: mat.to_cols_array_2d() }
  }
}
