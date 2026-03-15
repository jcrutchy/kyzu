use glam::DVec3;

use crate::input::InputState;
use crate::renderer::shared::{CameraMatrices, SharedState};

// ──────────────────────────────────────────────────────────────
//   Constants
// ──────────────────────────────────────────────────────────────

// Zoom limits relative to focus body radius
const RADIUS_MIN_FACTOR: f64 = 1.01; // just above surface
const RADIUS_MAX_FACTOR: f64 = 1.0e6; // ~384M km at Earth scale = well past solar system

const ELEVATION_MIN: f64 = 0.01;
const ELEVATION_MAX: f64 = std::f64::consts::FRAC_PI_2 - 0.01;

const ORBIT_SENSITIVITY: f64 = 0.005;
const _PAN_SENSITIVITY: f64 = 0.001;
const ZOOM_SENSITIVITY: f64 = 0.1;

// Sun position — fixed for now, ~1 AU along +X axis (metres)
const SUN_POSITION: DVec3 = DVec3::new(1.496e11, 0.0, 0.0);

// ──────────────────────────────────────────────────────────────
//   Focus body — describes the body being orbited
// ──────────────────────────────────────────────────────────────

#[derive(Clone)]
pub struct FocusBody
{
  pub name: &'static str,
  pub position: DVec3, // world-space centre, metres
  pub radius: f64,     // metres
}

// ──────────────────────────────────────────────────────────────
//   SolarSystemCamera
// ──────────────────────────────────────────────────────────────

pub struct SolarSystemCamera
{
  // Which body we're orbiting
  pub focus: FocusBody,

  // Spherical coords relative to focus body centre
  pub radius: f64,    // metres from focus centre
  pub azimuth: f64,   // radians
  pub elevation: f64, // radians

  // Projection
  pub aspect: f32,
  pub fovy: f64,
}

impl SolarSystemCamera
{
  pub fn new(aspect: f32) -> Self
  {
    let earth = FocusBody {
      name: "Earth",
      position: DVec3::ZERO,
      radius: 6.371e6, // 6,371 km
    };

    let start_radius = earth.radius * 3.0; // start 3× Earth radius out

    Self {
      focus: earth,
      radius: start_radius,
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

  /// Eye position in world space (f64)
  pub fn eye_world(&self) -> DVec3
  {
    let cos_el = self.elevation.cos();
    let sin_el = self.elevation.sin();
    let cos_az = self.azimuth.cos();
    let sin_az = self.azimuth.sin();

    self.focus.position
      + DVec3::new(
        self.radius * cos_el * sin_az,
        self.radius * cos_el * cos_az,
        self.radius * sin_el,
      )
  }

  /// Apply input and write fresh matrices into shared state.
  pub fn update(&mut self, input: &InputState, shared: &mut SharedState)
  {
    self.apply_input(input);
    shared.camera = self.compute_matrices();
  }

  pub fn apply_input(&mut self, input: &InputState)
  {
    self.apply_orbit(input);
    self.apply_zoom(input);
  }

  /// Compute CameraMatrices from current state.
  /// Origin rebasing happens here — everything sent to GPU is
  /// relative to the eye position, computed in f64.
  pub fn compute_matrices(&self) -> CameraMatrices
  {
    let eye = self.eye_world();
    let target = self.focus.position;

    // Camera-relative vectors — computed in f64, cast to f32
    let target_rel = (target - eye).as_vec3();
    let up = glam::Vec3::Z;

    let view = glam::Mat4::look_at_rh(
      glam::Vec3::ZERO, // eye is origin in camera space
      target_rel,
      up,
    );

    let znear = ((self.radius - self.focus.radius) * 0.01).max(100.0) as f32;
    let zfar = (self.radius * 100.0) as f32;

    let proj = glam::Mat4::perspective_rh(self.fovy as f32, self.aspect, znear, zfar);
    let view_proj = proj * view;

    // Sun direction — from sun toward scene origin, normalised, in f64
    let sun_dir = (eye - SUN_POSITION).normalize().as_vec3();

    // LOD fields — kept for compatibility, driven by altitude above surface
    let altitude = (self.radius - self.focus.radius).max(1.0);
    let log_zoom = (altitude as f32 / 5.0).log10();
    let lod_level = log_zoom.floor();
    let lod_fade = log_zoom - lod_level;

    CameraMatrices {
      view_proj: view_proj.to_cols_array_2d(),
      inv_view_proj: view_proj.inverse().to_cols_array_2d(),
      eye_world: [eye.x as f32, eye.y as f32, eye.z as f32],
      _pad: 0.0,
      fade_near: (self.radius as f32 * 0.1).max(1000.0),
      fade_far: (self.radius as f32 * 10.0).max(10000.0),
      lod_scale: 10.0_f32.powf(lod_level),
      lod_fade,
      target: [target.x as f32, target.y as f32, target.z as f32],
      _pad2: 0.0,
      radius: self.radius as f32,
      _pad3: 0.0,
      target_rel: [target_rel.x, target_rel.y, target_rel.z],
      _pad4: 0.0,
      sun_dir: [sun_dir.x, sun_dir.y, sun_dir.z],
      _pad5: 0.0,
      _pad6: [0.0, 0.0],
    }
  }
}

// ──────────────────────────────────────────────────────────────
//   Input handlers
// ──────────────────────────────────────────────────────────────

impl SolarSystemCamera
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

  fn apply_zoom(&mut self, input: &InputState)
  {
    if input.scroll == 0.0
    {
      return;
    }

    // Non-linear zoom — faster when far out, slower near surface
    let factor = (1.0 + ZOOM_SENSITIVITY).powf(-input.scroll as f64);
    let radius_min = self.focus.radius * RADIUS_MIN_FACTOR;
    let radius_max = self.focus.radius * RADIUS_MAX_FACTOR;

    self.radius = (self.radius * factor).clamp(radius_min, radius_max);
  }

  /// Switch focus to a different body (e.g. Earth → Moon)
  pub fn set_focus(&mut self, body: FocusBody)
  {
    let old_radius_factor = self.radius / self.focus.radius;
    self.focus = body;
    // Preserve approximate zoom level relative to new body's radius
    self.radius = (self.focus.radius * old_radius_factor)
      .clamp(self.focus.radius * RADIUS_MIN_FACTOR, self.focus.radius * RADIUS_MAX_FACTOR);
  }
}
