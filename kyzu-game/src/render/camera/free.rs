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
  fn update(&mut self, shared: &mut SharedState, input: &InputState, dt: f32)
  {
    // --- 1. HANDLE INPUT (Rotation) ---
    self.yaw -= input.mouse_delta.x * self.sensitivity * 0.1;
    self.pitch -= input.mouse_delta.y * self.sensitivity * 0.1;
    self.pitch = self.pitch.clamp(-1.5, 1.5);

    // --- 2. HANDLE INPUT (Movement) ---
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

    // Speed Adjustment
    if input.scroll_delta != 0.0
    {
      self.speed = (self.speed + input.scroll_delta).max(0.1);
    }

    // Apply movement to the HIGH-PRECISION position
    if move_dir.length_squared() > 0.0
    {
      // We normalize so diagonal movement isn't faster
      let move_norm = move_dir.normalize();
      self.position += move_norm.as_dvec3() * (self.speed as f64) * (dt as f64);
    }

    // --- 3. FLOATING ORIGIN MATRICES ---

    // Update the CPU "Source of Truth"
    shared.eye_world = self.position;

    // In Floating Origin, the view matrix for a Free camera
    // has NO translation (we are at 0,0,0), only the inverse rotation!
    let view_rel = glam::DMat4::from_quat(rotation.as_dquat()).inverse();

    let aspect = shared.screen_width as f32 / shared.screen_height as f32;
    let proj = glam::Mat4::perspective_rh(self.fov.to_radians(), aspect, self.z_near, self.z_far);

    let view_proj = proj * view_rel.as_mat4();

    shared.camera.view_proj = view_proj.to_cols_array_2d();
    shared.camera.inv_view_proj = view_proj.inverse().to_cols_array_2d(); // Good for raycasting!
    shared.camera.eye_rel = [0.0, 0.0, 0.0];
  }
}
