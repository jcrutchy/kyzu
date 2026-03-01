use super::spherical::Camera;

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct CameraUniform
{
  pub view_proj: [[f32; 4]; 4], // 64 bytes  — offset 0
  pub eye_world: [f32; 3],      // 12 bytes  — offset 64
  pub _pad: f32,                //  4 bytes  — offset 76, pads to 80
}

const _: () = assert!(std::mem::size_of::<CameraUniform>() == 80);

impl CameraUniform
{
  pub fn from_camera(camera: &Camera) -> Self
  {
    let eye = camera.eye_position();
    Self {
      view_proj: camera.build_view_proj().to_cols_array_2d(),
      eye_world: [eye.x as f32, eye.y as f32, eye.z as f32],
      _pad: 0.0,
    }
  }
}
