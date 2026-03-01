use glam::{DVec3, Mat4, Vec3};

//
// ──────────────────────────────────────────────────────────────
//   Camera (spherical coordinates, Z-up right-hand rule)
//
//   Coordinate system:
//     X → right
//     Y → forward (into the scene)
//     Z → up (normal to XY ground plane)
//
//   The eye position is derived from spherical coordinates
//   centred on `target`:
//     azimuth   = horizontal angle in radians, measured from +Y axis
//     elevation = angle above the XY plane in radians
//     radius    = distance from target to eye
// ──────────────────────────────────────────────────────────────
//

pub struct Camera
{
  pub target: DVec3,
  pub radius: f64,
  pub azimuth: f64,
  pub elevation: f64,

  pub aspect: f32,
  pub fovy: f64,
}

//
// ──────────────────────────────────────────────────────────────
//   Constants
// ──────────────────────────────────────────────────────────────
//

const RADIUS_MIN: f64 = 0.0001; // Allow deep zoom-in
const RADIUS_MAX: f64 = 1_000_000_000_000.0; // Allow massive zoom-out
const ELEVATION_MIN: f64 = 0.01; // just above XY plane
const ELEVATION_MAX: f64 = std::f64::consts::FRAC_PI_2 - 0.01; // just below zenith

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
      target: DVec3::ZERO,
      radius: 20.0,
      azimuth: -std::f64::consts::FRAC_PI_4,  // 45° off +Y axis
      elevation: std::f64::consts::FRAC_PI_6, // 30° above ground plane
      aspect,
      fovy: std::f64::consts::FRAC_PI_4, // 45° vertical FOV
    }
  }

  pub fn set_aspect(&mut self, aspect: f32)
  {
    self.aspect = aspect;
  }

  /// World-space eye position (f64) derived from spherical coordinates.
  pub fn eye_position(&self) -> DVec3
  {
    eye_position(self)
  }

  /// View-projection matrix rebased to camera-relative origin.
  ///
  /// The view matrix treats eye as (0,0,0), so the GPU only sees
  /// f32-safe relative offsets regardless of absolute world coordinates.
  pub fn build_view_proj(&self) -> Mat4
  {
    build_projection_matrix(self) * build_view_matrix(self)
  }

  /// The inverse, needed by the grid shader for unprojection.
  pub fn build_inv_view_proj(&self) -> Mat4
  {
    self.build_view_proj().inverse()
  }

  /// Rotate around the target point.
  /// `delta_az` and `delta_el` are in radians.
  pub fn orbit(&mut self, delta_az: f64, delta_el: f64)
  {
    self.azimuth += delta_az;
    self.elevation = (self.elevation + delta_el).clamp(ELEVATION_MIN, ELEVATION_MAX);
  }

  /// Multiplicative zoom — feels linear in log space, matches Inventor feel.
  /// `factor` > 1 zooms out, < 1 zooms in.
  pub fn zoom(&mut self, factor: f64)
  {
    self.radius = (self.radius * factor).clamp(RADIUS_MIN, RADIUS_MAX);
  }

  /// Translate the target in the camera's screen-aligned plane.
  /// `dx` and `dy` are pre-scaled world-space units (f64).
  pub fn pan(&mut self, dx: f64, dy: f64)
  {
    // Compute eye once to share across right and up — avoids 3× trig calls
    let eye = eye_position(self);
    let right = compute_right(eye, self.target);
    let up = compute_up(eye, self.target, right);

    self.target += right * dx + up * dy;
  }
}

//
// ──────────────────────────────────────────────────────────────
//   Spherical → cartesian helpers
// ──────────────────────────────────────────────────────────────
//

fn eye_position(cam: &Camera) -> DVec3
{
  let cos_el = cam.elevation.cos();
  let sin_el = cam.elevation.sin();
  let cos_az = cam.azimuth.cos();
  let sin_az = cam.azimuth.sin();

  cam.target
    + DVec3::new(cam.radius * cos_el * sin_az, cam.radius * cos_el * cos_az, cam.radius * sin_el)
}

/// Right vector: perpendicular to forward, lying in the world XY plane.
fn compute_right(eye: DVec3, target: DVec3) -> DVec3
{
  let fwd = (target - eye).normalize();
  fwd.cross(DVec3::Z).normalize()
}

/// Up vector: perpendicular to both forward and right, pointing generally upward.
/// Uses right × fwd (right-hand rule) so it correctly tilts with the view.
fn compute_up(eye: DVec3, target: DVec3, right: DVec3) -> DVec3
{
  let fwd = (target - eye).normalize();
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
  // Rebase: eye becomes origin. Target direction is preserved in f32.
  let target_rel = (cam.target - eye).as_vec3();
  Mat4::look_at_rh(Vec3::ZERO, target_rel, Vec3::Z)
}

fn build_projection_matrix(cam: &Camera) -> Mat4
{
  let znear = ((cam.radius * 0.001) as f32).max(0.0001); // tightened near plane
  let zfar = ((cam.radius * 100.0) as f32).max(10000.0); // reduced far multiplier
  Mat4::perspective_rh(cam.fovy as f32, cam.aspect, znear, zfar)
}
