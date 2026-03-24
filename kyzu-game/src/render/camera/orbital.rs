use glam::DVec3;

use super::CameraController;

pub struct OrbitalController
{
  pub lat: f64,            // Latitude in degrees (-90 to 90)
  pub lon: f64,            // Longitude in degrees
  pub altitude: f64,       // Distance from center
  pub target: glam::DVec3, // The center of the world body
  pub fov: f32,
  pub z_near: f32,
  pub z_far: f32,
  pub sensitivity: f32,
}

impl Default for OrbitalController
{
  fn default() -> Self
  {
    Self {
      lat: 0.0,
      lon: 0.0,
      altitude: 10.0,
      target: glam::DVec3::ZERO,
      fov: 45.0,
      z_near: 0.1,
      z_far: 10000.0,
      sensitivity: 0.005,
    }
  }
}

impl CameraController for OrbitalController
{
  fn update(
    &mut self,
    shared: &mut crate::render::shared::SharedState,
    input: &crate::input::state::InputState,
    _dt: f32,
  )
  {
    // 1. Handle Input (Logic stays the same)
    if input.mouse_buttons_down.contains(&winit::event::MouseButton::Right)
    {
      self.lon -= (input.mouse_delta.x * 0.2) as f64;
      self.lat += (input.mouse_delta.y * 0.2) as f64;
      self.lat = self.lat.clamp(-89.0, 89.0);
    }
    if input.scroll_delta != 0.0
    {
      self.altitude -= (input.scroll_delta as f64) * self.altitude * 0.1;
      self.altitude = self.altitude.clamp(2.0, 100000.0); // Allow space scale!
    }

    // 2. High Precision Math (f64)
    let lat_rad = self.lat.to_radians();
    let lon_rad = self.lon.to_radians();
    let offset = DVec3::new(
      self.altitude * lat_rad.cos() * lon_rad.sin(),
      self.altitude * lat_rad.sin(),
      self.altitude * lat_rad.cos() * lon_rad.cos(),
    );

    // Update the CPU "Source of Truth"
    shared.eye_world = self.target + offset;

    // 3. Floating Origin Math
    // Relative target is simply negative offset if looking at (0,0,0)
    let relative_target = -offset;

    let view_rel = glam::DMat4::look_at_rh(DVec3::ZERO, relative_target, DVec3::Y);
    let aspect = shared.screen_width as f32 / shared.screen_height as f32;
    let proj = glam::Mat4::perspective_rh(self.fov.to_radians(), aspect, self.z_near, self.z_far);

    // 4. Update SharedState Matrices
    let view_proj = proj * view_rel.as_mat4();
    shared.camera.view_proj = view_proj.to_cols_array_2d();
    shared.camera.inv_view_proj = view_proj.inverse().to_cols_array_2d();
    shared.camera.eye_rel = [0.0, 0.0, 0.0]; // Camera is the origin!
  }
}
