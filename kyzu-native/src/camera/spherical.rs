use glam::{Mat4, Vec3};

//
// ──────────────────────────────────────────────────────────────
//   Camera (spherical coordinates, Z-up right-hand rule)
//
//   Coordinate system:
//     X → right
//     Y → forward (in-plane)
//     Z → up (normal to XY ground)
//
//   The eye position is derived from spherical coordinates
//   centred on `target`:
//     azimuth   = horizontal angle (radians, from +Y axis)
//     elevation = angle above the XY plane (radians)
//     radius    = distance from target to eye
// ──────────────────────────────────────────────────────────────
//

pub struct Camera
{
  pub target: Vec3,
  pub radius: f32,
  pub azimuth: f32,
  pub elevation: f32,

  pub aspect: f32,
  pub fovy: f32,
  pub znear: f32,
  pub zfar: f32,
}

//
// ──────────────────────────────────────────────────────────────
//   Constants
// ──────────────────────────────────────────────────────────────
//

const RADIUS_MIN: f32 = 0.5;
const RADIUS_MAX: f32 = 100_000.0;
const ELEVATION_MIN: f32 = 0.01; // just above XY plane
const ELEVATION_MAX: f32 = std::f32::consts::FRAC_PI_2 - 0.01; // just below zenith

//
// ──────────────────────────────────────────────────────────────
//   Public API
// ──────────────────────────────────────────────────────────────
//

impl Camera
{
  pub fn new(aspect: f32) -> Self
  {
    Self {
      target: Vec3::ZERO,
      radius: 20.0,
      azimuth: -std::f32::consts::FRAC_PI_4,  // 45° off +Y
      elevation: std::f32::consts::FRAC_PI_6, // 30° above ground

      aspect,
      fovy: std::f32::consts::FRAC_PI_4, // 45° vertical FOV
      znear: 0.1,
      zfar: 100_000.0,
    }
  }

  pub fn set_aspect(&mut self, aspect: f32)
  {
    self.aspect = aspect;
  }

  pub fn build_view_proj(&self) -> Mat4
  {
    let view = build_view_matrix(self);
    let proj = build_projection_matrix(self);
    proj * view
  }

  /// Rotate around the target point.
  /// `delta_az` and `delta_el` are in radians.
  pub fn orbit(&mut self, delta_az: f32, delta_el: f32)
  {
    self.azimuth += delta_az;
    self.elevation = (self.elevation + delta_el).clamp(ELEVATION_MIN, ELEVATION_MAX);
  }

  /// Multiplicative zoom — feels linear in log space, matches Inventor.
  /// `factor` > 1 zooms out, < 1 zooms in.
  pub fn zoom(&mut self, factor: f32)
  {
    self.radius = (self.radius * factor).clamp(RADIUS_MIN, RADIUS_MAX);
  }

  /// Translate the target in the camera's local XY plane (screen pan).
  /// `dx` and `dy` are in world-space units.
  pub fn pan(&mut self, dx: f32, dy: f32)
  {
    let right = camera_right(self);
    let up = camera_up(self);
    self.target += right * dx + up * dy;
  }

  /// World-space eye position derived from spherical coordinates.
  pub fn eye_position(&self) -> Vec3
  {
    eye_position(self)
  }
}

//
// ──────────────────────────────────────────────────────────────
//   Spherical → cartesian helpers
// ──────────────────────────────────────────────────────────────
//

fn eye_position(cam: &Camera) -> Vec3
{
  let cos_el = cam.elevation.cos();
  let sin_el = cam.elevation.sin();
  let cos_az = cam.azimuth.cos();
  let sin_az = cam.azimuth.sin();

  let offset =
    Vec3::new(cam.radius * cos_el * sin_az, cam.radius * cos_el * cos_az, cam.radius * sin_el);

  cam.target + offset
}

/// Right vector in world space (perpendicular to view dir, in XY plane).
fn camera_right(cam: &Camera) -> Vec3
{
  let eye = eye_position(cam);
  let fwd = (cam.target - eye).normalize();
  fwd.cross(Vec3::Z).normalize()
}

/// Up vector in world space for the current view orientation.
fn camera_up(cam: &Camera) -> Vec3
{
  let eye = eye_position(cam);
  let fwd = (cam.target - eye).normalize();
  let right = fwd.cross(Vec3::Z).normalize();
  right.cross(fwd).normalize()
}

//
// ──────────────────────────────────────────────────────────────
//   Matrix builders
// ──────────────────────────────────────────────────────────────
//

fn build_view_matrix(cam: &Camera) -> Mat4
{
  let eye = eye_position(cam);
  Mat4::look_at_rh(eye, cam.target, Vec3::Z)
}

fn build_projection_matrix(cam: &Camera) -> Mat4
{
  Mat4::perspective_rh(cam.fovy, cam.aspect, cam.znear, cam.zfar)
}
