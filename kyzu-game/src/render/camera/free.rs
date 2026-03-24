use glam::{DVec3, EulerRot, Mat4, Quat, Vec3};
use winit::keyboard::KeyCode;

use super::CameraController;
use crate::render::shared::CameraMatrices;

pub struct FreeController
{
  pub position: DVec3,
  pub yaw: f32,
  pub pitch: f32,
  pub speed: f32,
  pub sensitivity: f32,
  pub fov: f32,
  pub z_near: f32,
  pub z_far: f32,
}

impl Default for FreeController
{
  fn default() -> Self
  {
    Self {
      position: glam::DVec3::new(0.0, 0.0, 5.0),
      yaw: -90.0f32.to_radians(), // Point toward the origin
      pitch: 0.0,
      speed: 5.0,
      sensitivity: 0.1,
      fov: 45.0,
      z_near: 0.1,
      z_far: 10000.0,
    }
  }
}

impl CameraController for FreeController
{
  fn update_matrices(&self, matrices: &mut CameraMatrices, aspect: f32)
  {
    let rotation = Quat::from_euler(EulerRot::YXZ, self.yaw, self.pitch, 0.0);
    // Use DMat4 for the view calculation
    let view = glam::DMat4::from_rotation_translation(rotation.as_dquat(), self.position).inverse();
    let proj = Mat4::perspective_rh(self.fov.to_radians(), aspect, self.z_near, self.z_far);

    // Cast back to f32 for the final Uniform Buffer
    let view_proj = proj * view.as_mat4();

    matrices.view_proj = view_proj.to_cols_array_2d();
    matrices.inv_view_proj = view_proj.inverse().to_cols_array_2d();
    matrices.eye_world = self.position.as_vec3().to_array(); // Cast for GPU
  }
  fn get_eye_f64(&self) -> [f64; 3]
  {
    self.position.to_array()
  }
}

impl FreeController
{
  pub fn handle_input(&mut self, input: &crate::input::state::InputState, dt: f32)
  {
    // 1. Rotation: Use the delta from your InputState
    // We multiply by a small factor because raw pixel deltas are large
    self.yaw -= input.mouse_delta.x * self.sensitivity * 0.1;
    self.pitch -= input.mouse_delta.y * self.sensitivity * 0.1;

    self.pitch = self.pitch.clamp(-1.5, 1.5);

    // 2. Movement
    let rotation = Quat::from_euler(EulerRot::YXZ, self.yaw, self.pitch, 0.0);
    let forward = rotation * -Vec3::Z;
    let right = rotation * Vec3::X;

    let mut move_dir = Vec3::ZERO;
    if input.is_key_down(KeyCode::KeyW)
    {
      move_dir += forward;
    }
    if input.is_key_down(KeyCode::KeyS)
    {
      move_dir -= forward;
    }
    if input.is_key_down(KeyCode::KeyD)
    {
      move_dir += right;
    }
    if input.is_key_down(KeyCode::KeyA)
    {
      move_dir -= right;
    }

    // 3. Speed Boost with Scroll
    // In space, you often need to change speed scales
    if input.scroll_delta != 0.0
    {
      self.speed = (self.speed + input.scroll_delta).max(0.1);
    }

    if move_dir.length_squared() > 0.0
    {
      self.position += move_dir.as_dvec3() * (self.speed as f64) * (dt as f64);
    }
  }
}
