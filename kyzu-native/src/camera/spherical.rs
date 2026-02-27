use glam::{Mat4, Vec3};

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
  pub target: Vec3,
  pub radius: f32,
  pub azimuth: f32,
  pub elevation: f32,

  pub aspect: f32,
  pub fovy: f32,
}

//
// ──────────────────────────────────────────────────────────────
//   Constants
// ──────────────────────────────────────────────────────────────
//

const RADIUS_MIN: f32 = 0.0001; // Allow deep zoom-in
const RADIUS_MAX: f32 = 100_000_000.0; // Allow massive zoom-out
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
      azimuth: -std::f32::consts::FRAC_PI_4,  // 45° off +Y axis
      elevation: std::f32::consts::FRAC_PI_6, // 30° above ground plane

      aspect,
      fovy: std::f32::consts::FRAC_PI_4, // 45° vertical FOV
    }
  }

  pub fn set_aspect(&mut self, aspect: f32)
  {
    self.aspect = aspect;
  }

  pub fn build_view_proj(&self) -> Mat4
  {
    build_projection_matrix(self) * build_view_matrix(self)
  }

  /// Rotate around the target point.
  /// `delta_az` and `delta_el` are in radians.
  pub fn orbit(&mut self, delta_az: f32, delta_el: f32)
  {
    self.azimuth += delta_az;
    self.elevation = (self.elevation + delta_el).clamp(ELEVATION_MIN, ELEVATION_MAX);
  }

  /// Multiplicative zoom — feels linear in log space, matches Inventor feel.
  /// `factor` > 1 zooms out, < 1 zooms in.
  pub fn zoom(&mut self, factor: f32)
  {
    self.radius = (self.radius * factor).clamp(RADIUS_MIN, RADIUS_MAX);
  }

  /// Translate the target in the camera's screen-aligned plane.
  /// `dx` and `dy` are pre-scaled world-space units.
  pub fn pan(&mut self, dx: f32, dy: f32)
  {
    // Compute eye once to share across right and up — avoids 3× trig calls
    let eye = eye_position(self);
    let right = compute_right(eye, self.target);
    let up = compute_up(eye, self.target, right);

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

  cam.target
    + Vec3::new(cam.radius * cos_el * sin_az, cam.radius * cos_el * cos_az, cam.radius * sin_el)
}

/// Right vector: perpendicular to forward, lying in the world XY plane.
fn compute_right(eye: Vec3, target: Vec3) -> Vec3
{
  let fwd = (target - eye).normalize();
  fwd.cross(Vec3::Z).normalize()
}

/// Up vector: perpendicular to both forward and right, pointing generally upward.
/// Uses right × fwd (right-hand rule) so it correctly tilts with the view.
fn compute_up(eye: Vec3, target: Vec3, right: Vec3) -> Vec3
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
  Mat4::look_at_rh(eye_position(cam), cam.target, Vec3::Z)
}

fn build_projection_matrix(cam: &Camera) -> Mat4
{
  let znear = (cam.radius * 0.01).max(0.0001); // Scale near plane with zoom
  let zfar = (cam.radius * 100.0).max(10000.0); // Scale far plane with zoom
  Mat4::perspective_rh(cam.fovy, cam.aspect, znear, zfar)
}
