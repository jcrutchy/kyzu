use glam::{Mat4, Vec3};

//
// ──────────────────────────────────────────────────────────────
//   Camera Uniform (GPU side)
// ──────────────────────────────────────────────────────────────
//

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct CameraUniform
{
  pub view_proj: [[f32; 4]; 4],
}

impl CameraUniform
{
  pub fn from_camera(camera: &Camera) -> Self
  {
    let view_proj = camera.build_view_proj();
    Self { view_proj: view_proj.to_cols_array_2d() }
  }
}

//
// ──────────────────────────────────────────────────────────────
//   Fixed Camera (right‑handed, Z‑up, XY = ground)
// ──────────────────────────────────────────────────────────────
//

pub struct Camera
{
  pub eye: Vec3,
  pub target: Vec3,
  pub up: Vec3,

  pub aspect: f32,
  pub fovy: f32,
  pub znear: f32,
  pub zfar: f32,
}

impl Camera
{
  /// Create a simple fixed CAD‑style camera.
  ///
  /// Coordinate system:
  ///   X → right
  ///   Y → forward (in‑plane)
  ///   Z → up (normal to XY ground)
  pub fn new(aspect: f32) -> Self
  {
    Self {
      eye: default_eye(),
      target: Vec3::ZERO,
      up: Vec3::Z,
      aspect,
      fovy: std::f32::consts::FRAC_PI_4,
      znear: 0.1,
      zfar: 10_000.0,
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
}

//
// ──────────────────────────────────────────────────────────────
//   Helper functions (flat, readable, no nesting)
// ──────────────────────────────────────────────────────────────
//

fn default_eye() -> Vec3
{
  Vec3::new(8.0, -12.0, 6.0)
}

fn build_view_matrix(cam: &Camera) -> Mat4
{
  Mat4::look_at_rh(cam.eye, cam.target, cam.up)
}

fn build_projection_matrix(cam: &Camera) -> Mat4
{
  Mat4::perspective_rh(cam.fovy, cam.aspect, cam.znear, cam.zfar)
}
