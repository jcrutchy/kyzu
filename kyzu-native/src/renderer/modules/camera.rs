use glam::DVec3;

use crate::input::InputState;
use crate::renderer::shared::{CameraMatrices, SharedState};

//
// ──────────────────────────────────────────────────────────────
//   Constants
// ──────────────────────────────────────────────────────────────
//

const RADIUS_MIN: f64 = 0.0001;
const RADIUS_MAX: f64 = 1_000_000_000_000.0;
const ELEVATION_MIN: f64 = 0.01;
const ELEVATION_MAX: f64 = std::f64::consts::FRAC_PI_2 - 0.01;

const ORBIT_SENSITIVITY: f64 = 0.005;
const PAN_SENSITIVITY: f64 = 0.002;

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
    self.apply_input(input);
    shared.camera = self.compute_matrices();
  }

  /// Process input and mutate camera state.
  /// Call this before update().
  pub fn apply_input(&mut self, input: &InputState)
  {
    self.apply_orbit(input);
    self.apply_pan(input);
    self.apply_zoom(input);
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
    let znear = ((self.radius * 0.001) as f32).max(0.0001);
    let zfar = ((self.radius * 100.0) as f32).max(10000.0);
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

  fn apply_pan(&mut self, input: &InputState)
  {
    if !input.middle_held || (input.mouse_dx == 0.0 && input.mouse_dy == 0.0)
    {
      return;
    }

    let scale = self.radius * PAN_SENSITIVITY;
    let eye = self.eye_position();

    // Right vector lies in the XY plane — correct for pan
    let right = compute_right(eye, self.target);

    // Use world XY forward instead of view-tilted up, so vertical
    // pan never moves the target out of the ground plane
    let fwd_flat = DVec3::new(-(eye.x - self.target.x), -(eye.y - self.target.y), 0.0).normalize();

    let dx = -input.mouse_dx as f64 * scale;
    let dy = input.mouse_dy as f64 * scale;

    self.target += right * dx + fwd_flat * dy;
  }

  fn apply_zoom(&mut self, input: &InputState)
  {
    if input.scroll == 0.0
    {
      return;
    }

    let factor = (1.1_f64).powf(-input.scroll as f64);
    self.radius = (self.radius * factor).clamp(RADIUS_MIN, RADIUS_MAX);
  }
}

//
// ──────────────────────────────────────────────────────────────
//   Geometry helpers
// ──────────────────────────────────────────────────────────────
//

fn compute_right(eye: DVec3, target: DVec3) -> DVec3
{
  let fwd = (target - eye).normalize();
  fwd.cross(DVec3::Z).normalize()
}

fn compute_up(eye: DVec3, target: DVec3, right: DVec3) -> DVec3
{
  let fwd = (target - eye).normalize();
  right.cross(fwd).normalize()
}
