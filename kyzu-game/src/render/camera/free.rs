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
  pub speed_gear: i32, // gear multiplier: each Shift+scroll notch = 2x/0.5x WASD speed
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
      speed_gear: 0,
      sensitivity: 0.1,
      fov: 45.0,
      z_near: 100_000.0,          // 100km — fine for solar system scale
      z_far: 1_000_000_000_000.0, // 1 trillion metres (~Pluto distance)
    }
  }
}

// Gear multiplier: 2^gear applied to the base distance-proportional speed.
// Gear  0 = 1x   (base: 10% of distance per second)
// Gear  1 = 2x
// Gear  2 = 4x
// Gear -1 = 0.5x (finer control close up)
// Gear -2 = 0.25x
// Range: -4 to +6 gives roughly 0.06x to 64x base speed
fn gear_multiplier(gear: i32) -> f64
{
  2.0_f64.powi(gear)
}

impl CameraController for FreeController
{
  fn update(&mut self, shared: &mut SharedState, input: &mut InputState, dt: f32)
  {
    // --- 1. HANDLE INPUT (Rotation) ---
    if input.mouse_buttons_down.contains(&winit::event::MouseButton::Right)
    {
      let sensitivity_scale = 0.005;
      let delta = input.mouse_delta;
      self.yaw -= delta.x * self.sensitivity * sensitivity_scale;
      self.pitch -= delta.y * self.sensitivity * sensitivity_scale;
      self.pitch = self.pitch.clamp(-1.5, 1.5);
    }

    // --- 2. Build direction vectors ---
    let rotation = Quat::from_euler(EulerRot::YXZ, self.yaw, self.pitch, 0.0);
    let forward = rotation * -Vec3::Z;
    let right = rotation * Vec3::X;
    let up = rotation * Vec3::Y;

    // --- 3. HANDLE INPUT (Movement) ---

    // Base speed: always proportional to distance from origin.
    // At any distance, gear 0 WASD moves you at 10% of that distance per second.
    // Scroll nudges you by 10% of distance per notch (same scale, feels consistent).
    let dist = self.position.length().max(100.0);
    let base_speed = dist * 0.1; // metres per second at gear 0

    // Scroll: instant positional nudge — 10% of distance from origin per notch.
    if input.scroll_delta != 0.0
    {
      let scroll_clamped = input.scroll_delta.clamp(-3.0, 3.0) as f64;
      self.position += forward.as_dvec3() * base_speed * scroll_clamped;
    }

    // Shift+scroll: adjust gear multiplier for WASD speed.
    // Negative gears give finer control when close to a surface.
    if input.is_key_down(KeyCode::ShiftLeft) || input.is_key_down(KeyCode::ShiftRight)
    {
      if input.scroll_delta > 0.0
      {
        self.speed_gear += 1;
      }
      else if input.scroll_delta < 0.0
      {
        self.speed_gear -= 1;
      }
      self.speed_gear = self.speed_gear.clamp(-4, 6);
    }

    // WASD: sustained flight at base speed * gear multiplier
    let wasd_speed = base_speed * gear_multiplier(self.speed_gear);

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
      self.position += move_norm.as_dvec3() * wasd_speed * (dt as f64);
    }

    // --- 4. FLOATING ORIGIN MATRICES ---
    shared.eye_world = self.position;

    let view_rel = glam::Mat4::look_to_rh(Vec3::ZERO, forward, up);
    let aspect = shared.screen_width as f32 / shared.screen_height as f32;
    let proj = glam::Mat4::perspective_rh(self.fov.to_radians(), aspect, self.z_near, self.z_far);
    let view_proj = proj * view_rel;

    shared.camera.view_proj = view_proj.to_cols_array_2d();
    shared.camera.inv_view_proj = view_proj.inverse().to_cols_array_2d();
    shared.camera.eye_rel = [0.0, 0.0, 0.0];
  }
}
