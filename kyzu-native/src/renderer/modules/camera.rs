use glam::DVec3;

use crate::input::InputState;
use crate::renderer::shared::{CameraMatrices, SharedState};

//
// ──────────────────────────────────────────────────────────────
//   Constants
// ──────────────────────────────────────────────────────────────
//

const RADIUS_MIN: f64 = 0.1;
const RADIUS_MAX: f64 = 1.0e12;
const ELEVATION_MIN: f64 = 0.01;
const ELEVATION_MAX: f64 = std::f64::consts::FRAC_PI_2 - 0.01;

const ORBIT_SENSITIVITY: f64 = 0.005;

//
// ──────────────────────────────────────────────────────────────
//   CameraModule
// ──────────────────────────────────────────────────────────────
//

pub struct CameraModule
{
  // Spherical coordinates
  pub target: DVec3,
  pub radius: f64,
  pub azimuth: f64,
  pub elevation: f64,

  // Projection
  pub aspect: f32,
  pub fovy: f64,
}

impl CameraModule
{
  pub fn new(aspect: f32) -> Self
  {
    Self {
      target: DVec3::ZERO,
      radius: 20.0,
      azimuth: -std::f64::consts::FRAC_PI_4,
      elevation: std::f64::consts::FRAC_PI_6,
      aspect,
      fovy: std::f64::consts::FRAC_PI_4,
    }
  }

  pub fn set_aspect(&mut self, aspect: f32)
  {
    self.aspect = aspect;
  }

  /// Apply input and compute new matrices into shared state.
  pub fn update(&mut self, input: &InputState, shared: &mut SharedState)
  {
    self.apply_input(input, shared.screen_width, shared.screen_height);
    shared.camera = self.compute_matrices();
  }

  /// Process input and mutate camera state.
  pub fn apply_input(&mut self, input: &InputState, screen_width: u32, screen_height: u32)
  {
    self.apply_orbit(input);
    self.apply_pan(input, screen_width, screen_height);
    self.apply_zoom(input, screen_width, screen_height);
  }

  /// Compute fresh CameraMatrices from current state.
  /// Called by update() and also by the kernel after resize.
  pub fn compute_matrices(&self) -> CameraMatrices
  {
    let eye = self.eye_position();
    let radius = self.radius as f32;
    let view_proj = self.build_view_proj();

    let log_zoom = ((self.radius / 5.0) as f32).log10();
    let lod_level = log_zoom.floor();
    let lod_fade = log_zoom - lod_level;

    let target_rel = self.target - eye; // DVec3 subtraction, full f64

    CameraMatrices {
      view_proj: view_proj.to_cols_array_2d(),
      inv_view_proj: view_proj.inverse().to_cols_array_2d(),
      eye_world: [eye.x as f32, eye.y as f32, eye.z as f32],
      _pad: 0.0,
      fade_near: (radius * 4.0).max(20.0),
      fade_far: (radius * 15.0).max(80.0),
      lod_scale: 10.0_f32.powf(lod_level),
      lod_fade,
      target: [self.target.x as f32, self.target.y as f32, self.target.z as f32],
      _pad2: 0.0,
      radius: self.radius as f32,
      _pad3: 0.0,
      target_rel: [target_rel.x as f32, target_rel.y as f32, target_rel.z as f32],
    }
  }
}

//
// ──────────────────────────────────────────────────────────────
//   Spherical coordinate helpers
// ──────────────────────────────────────────────────────────────
//

impl CameraModule
{
  pub fn eye_position(&self) -> DVec3
  {
    let cos_el = self.elevation.cos();
    let sin_el = self.elevation.sin();
    let cos_az = self.azimuth.cos();
    let sin_az = self.azimuth.sin();

    self.target
      + DVec3::new(
        self.radius * cos_el * sin_az,
        self.radius * cos_el * cos_az,
        self.radius * sin_el,
      )
  }

  fn build_view_proj(&self) -> glam::Mat4
  {
    self.build_projection() * self.build_view()
  }

  fn build_view(&self) -> glam::Mat4
  {
    let eye = self.eye_position();
    let target_rel = (self.target - eye).as_vec3();
    glam::Mat4::look_at_rh(glam::Vec3::ZERO, target_rel, glam::Vec3::Z)
  }

  fn build_projection(&self) -> glam::Mat4
  {
    let znear = ((self.radius * 0.01) as f32).max(0.001);
    let zfar = ((self.radius * 1000.0) as f32).max(1000.0);

    glam::Mat4::perspective_rh(self.fovy as f32, self.aspect, znear, zfar)
  }
}

//
// ──────────────────────────────────────────────────────────────
//   Input handlers
// ──────────────────────────────────────────────────────────────
//

impl CameraModule
{
  fn apply_orbit(&mut self, input: &InputState)
  {
    if !input.right_held || (input.mouse_dx == 0.0 && input.mouse_dy == 0.0)
    {
      return;
    }

    self.azimuth += input.mouse_dx as f64 * ORBIT_SENSITIVITY;
    self.elevation = (self.elevation + input.mouse_dy as f64 * ORBIT_SENSITIVITY)
      .clamp(ELEVATION_MIN, ELEVATION_MAX);
  }

  fn apply_pan(&mut self, input: &InputState, screen_width: u32, screen_height: u32)
  {
    if !input.middle_held || (input.mouse_dx == 0.0 && input.mouse_dy == 0.0)
    {
      return;
    }

    let inv_vp = glam::Mat4::from_cols_array_2d(&self.compute_matrices().inv_view_proj);
    let eye = self.eye_position();

    let prev_world = unproject_to_ground(
      input.mouse_x - input.mouse_dx,
      input.mouse_y - input.mouse_dy,
      screen_width,
      screen_height,
      inv_vp,
      eye,
    );

    let curr_world =
      unproject_to_ground(input.mouse_x, input.mouse_y, screen_width, screen_height, inv_vp, eye);

    if let (Some(prev), Some(curr)) = (prev_world, curr_world)
    {
      self.target += prev - curr;
      self.target.z = 0.0;
    }
  }

  fn apply_zoom(&mut self, input: &InputState, screen_width: u32, screen_height: u32)
  {
    if input.scroll == 0.0
    {
      return;
    }

    let factor = (1.1_f64).powf(-input.scroll as f64);
    let old_radius = self.radius;
    let new_radius = (self.radius * factor).clamp(RADIUS_MIN, RADIUS_MAX);

    if new_radius == old_radius
    {
      return;
    }

    let actual_factor = new_radius / old_radius;
    let inv_vp = glam::Mat4::from_cols_array_2d(&self.compute_matrices().inv_view_proj);
    let eye = self.eye_position();

    self.radius = new_radius;

    if let Some(p) =
      unproject_to_ground(input.mouse_x, input.mouse_y, screen_width, screen_height, inv_vp, eye)
    {
      self.target.x += (p.x - self.target.x) * (1.0 - actual_factor);
      self.target.y += (p.y - self.target.y) * (1.0 - actual_factor);
      self.target.z = 0.0;
    }
  }
}

//
// ──────────────────────────────────────────────────────────────
//   Geometry helpers
//
//   Ray-plane intersection done entirely in f64 to avoid
//   catastrophic cancellation when eye.z is large. The f32 matrix
//   outputs are promoted to f64 before any subtraction that would
//   otherwise lose precision.
// ──────────────────────────────────────────────────────────────
//

fn unproject_to_ground(
  screen_x: f32,
  screen_y: f32,
  screen_width: u32,
  screen_height: u32,
  inv_vp: glam::Mat4,
  eye: DVec3,
) -> Option<DVec3>
{
  let ndc_x = (screen_x / screen_width as f32) * 2.0 - 1.0;
  let ndc_y = -(screen_y / screen_height as f32) * 2.0 + 1.0;

  let near_h = inv_vp * glam::Vec4::new(ndc_x, ndc_y, 0.0, 1.0);
  let far_h = inv_vp * glam::Vec4::new(ndc_x, ndc_y, 1.0, 1.0);

  // Camera-relative ray endpoints, still f32
  let near_rel = near_h.truncate() / near_h.w;
  let far_rel = far_h.truncate() / far_h.w;

  // Promote z to f64 before subtracting eye.z — both values can be
  // ~1e7 in magnitude, and subtracting them in f32 causes catastrophic
  // cancellation that makes t wildly imprecise.
  let near_z = near_rel.z as f64;
  let far_z = far_rel.z as f64;
  let dir_z = far_z - near_z;

  if dir_z.abs() < 1e-10
  {
    return None;
  }

  // World z=0 is at camera-relative z = -eye.z
  let t = (-eye.z - near_z) / dir_z;

  if t < 0.0
  {
    return None;
  }

  // Interpolate x/y in f64 — t is precise now so keep it that way
  let hit_x = near_rel.x as f64 + (far_rel.x - near_rel.x) as f64 * t;
  let hit_y = near_rel.y as f64 + (far_rel.y - near_rel.y) as f64 * t;

  // z is exactly 0 by construction — no need to compute it
  let result = DVec3::new(eye.x + hit_x, eye.y + hit_y, 0.0);

  if !result.is_finite()
  {
    return None;
  }

  Some(result)
}
