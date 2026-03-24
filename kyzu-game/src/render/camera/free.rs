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
  pub speed_gear: i32, // 0 = stopped, 1..=8 = 10^(gear-1) m/s
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

// Gear 0 = stopped. Gear N = 10^(N-1) m/s:
//   1 =        10 m/s  (walking pace)
//   2 =       100 m/s
//   3 =     1,000 m/s  (~Mach 3)
//   4 =    10,000 m/s  (low orbit)
//   5 =   100,000 m/s
//   6 = 1,000,000 m/s  (Earth-Moon in ~6 mins)
//   7 =    10,000 km/s
//   8 =   100,000 km/s (inner solar system in minutes)
fn gear_to_speed(gear: i32) -> f64
{
  if gear <= 0
  {
    0.0
  }
  else
  {
    10.0_f64.powi(gear - 1)
  }
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

    // Scroll: instant positional nudge — 10% of distance from origin per notch.
    // Works in both directions so you can back away from a planet while keeping
    // it in view for spatial orientation.
    if input.scroll_delta != 0.0
    {
      let dist = self.position.length().max(100.0); // clamp so nudge never collapses to zero
      let scroll_clamped = input.scroll_delta.clamp(-3.0, 3.0) as f64;
      self.position += forward.as_dvec3() * dist * 0.1 * scroll_clamped;
    }

    // Shift+scroll: bump gear up/down for sustained WASD flight speed.
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
      self.speed_gear = self.speed_gear.clamp(0, 8);
    }

    let speed = gear_to_speed(self.speed_gear);

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
      self.position += move_norm.as_dvec3() * speed * (dt as f64);
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
