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
    // --- DEBUG: log every Free-mode frame ---
    eprintln!("[FREE CAM frame]");
    eprintln!("  position : {:?}", self.position);
    eprintln!("  yaw={:.2}deg  pitch={:.2}deg", self.yaw.to_degrees(), self.pitch.to_degrees());
    eprintln!(
      "  right-drag: {}  scroll_delta: {:.3}",
      input.mouse_buttons_down.contains(&winit::event::MouseButton::Right),
      input.scroll_delta
    );

    // --- 1. HANDLE INPUT (Rotation) ---
    if input.mouse_buttons_down.contains(&winit::event::MouseButton::Right)
    {
      let sensitivity_scale = 0.005;
      let delta = input.mouse_delta;
      self.yaw -= delta.x * self.sensitivity * sensitivity_scale;
      self.pitch -= delta.y * self.sensitivity * sensitivity_scale;
      self.pitch = self.pitch.clamp(-1.5, 1.5);
    }

    // --- 2. Build direction vectors (one rotation, used for both movement and view) ---
    let rotation = Quat::from_euler(EulerRot::YXZ, self.yaw, self.pitch, 0.0);
    let forward = rotation * -Vec3::Z;
    let right = rotation * Vec3::X;
    let up = rotation * Vec3::Y;

    // --- 3. HANDLE INPUT (Movement) ---
    if input.scroll_delta != 0.0
    {
      let factor = if input.scroll_delta > 0.0 { 1.2 } else { 0.8 };
      self.speed = (self.speed * factor).clamp(1.0, 100_000_000.0);

      // Also directly move forward/back on scroll so it feels like zoom
      let scroll_move =
        forward.as_dvec3() * (self.speed as f64) * (input.scroll_delta as f64) * 0.05;
      self.position += scroll_move;
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
      self.position += move_norm.as_dvec3() * (self.speed as f64) * (dt as f64);
    }

    // --- 4. FLOATING ORIGIN MATRICES ---
    shared.eye_world = self.position;

    let view_rel = glam::Mat4::look_to_rh(Vec3::ZERO, forward, up);
    let aspect = shared.screen_width as f32 / shared.screen_height as f32;
    let proj = glam::Mat4::perspective_rh(self.fov.to_radians(), aspect, self.z_near, self.z_far);
    let view_proj = proj * view_rel;

    // --- DEBUG: confirm matrices ---
    eprintln!("  view_proj[3] (translation col): {:?}", view_proj.col(3));
    eprintln!("  planet relative to eye: {:?}", (DVec3::ZERO - self.position).as_vec3());

    shared.camera.view_proj = view_proj.to_cols_array_2d();
    shared.camera.inv_view_proj = view_proj.inverse().to_cols_array_2d();
    shared.camera.eye_rel = [0.0, 0.0, 0.0];
  }
}
