use glam::{DVec3, EulerRot, Quat, Vec3};
use winit::keyboard::KeyCode;

use super::CameraController;
use crate::input::state::InputState;
use crate::render::shared::SharedState;

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
      position: glam::DVec3::new(0.0, 0.0, 15_000_000.0),
      yaw: -90.0f32.to_radians(),
      pitch: 0.0,
      speed: 1000.0,
      sensitivity: 0.1,
      fov: 45.0,
      z_near: 100.0,
      z_far: 100_000_000.0,
    }
  }
}

impl CameraController for FreeController
{
  fn update(&mut self, shared: &mut SharedState, input: &mut InputState, dt: f32)
  {
    // --- 1. HANDLE INPUT (Rotation) ---
    if input.mouse_buttons_down.contains(&winit::event::MouseButton::Right)
    {
      // Standardize sensitivity: 0.1 should be a comfortable speed
      let sensitivity_scale = 0.005;
      let delta = input.mouse_delta; // Or use consume_mouse_delta() here instead

      self.yaw -= delta.x * self.sensitivity * sensitivity_scale;
      self.pitch -= delta.y * self.sensitivity * sensitivity_scale;
      self.pitch = self.pitch.clamp(-1.5, 1.5);
    }

    // --- 2. HANDLE INPUT (Movement) ---
    // Use the exact same Euler order as the hand-off (YXZ)
    let rotation = Quat::from_euler(EulerRot::YXZ, self.yaw, self.pitch, 0.0);

    // Calculate direction vectors based on new rotation
    let forward = rotation * -Vec3::Z;
    let right = rotation * Vec3::X;

    // Exponential Speed Adjustment (unchanged, as this part was working)
    if input.scroll_delta != 0.0
    {
      let factor = if input.scroll_delta > 0.0 { 1.2 } else { 0.8 };
      self.speed = (self.speed * factor).clamp(1.0, 10_000_000.0);
    }

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

    if move_dir.length_squared() > 0.0
    {
      let move_norm = move_dir.normalize();
      // Movement MUST be scaled by dt to be frame-rate independent
      self.position += move_norm.as_dvec3() * (self.speed as f64) * (dt as f64);
    }

    // --- 3. FLOATING ORIGIN MATRICES ---
    shared.eye_world = self.position;

    // Create the rotation matrix
    let rotation = Quat::from_euler(EulerRot::YXZ, self.yaw, self.pitch, 0.0);

    // View Matrix: The inverse of the rotation (since we are at origin)
    let view_rel = glam::Mat4::from_quat(rotation).inverse();

    let aspect = shared.screen_width as f32 / shared.screen_height as f32;
    let proj = glam::Mat4::perspective_rh(self.fov.to_radians(), aspect, self.z_near, self.z_far);

    // Combine
    let view_proj = proj * view_rel;

    shared.camera.view_proj = view_proj.to_cols_array_2d();
    shared.camera.inv_view_proj = view_proj.inverse().to_cols_array_2d();
    shared.camera.eye_rel = [0.0, 0.0, 0.0];
  }
}
