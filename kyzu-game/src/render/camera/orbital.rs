use glam::{DVec3, Mat4};
use winit::event::MouseButton;

use super::CameraController;
use crate::render::shared::CameraMatrices;

pub struct OrbitalController
{
  pub lat: f32,      // Latitude in degrees (-90 to 90)
  pub lon: f32,      // Longitude in degrees
  pub altitude: f64, // Distance from center
  pub target: DVec3, // The center of the world body
  pub fov: f32,
  pub z_near: f32,
  pub z_far: f32,
}

impl Default for OrbitalController
{
  fn default() -> Self
  {
    Self {
      lat: 30.0, // Look from "above"
      lon: 45.0, // Look from the side
      altitude: 10.0,
      target: glam::DVec3::ZERO,
      fov: 45.0,
      z_near: 0.1,
      z_far: 10000.0,
    }
  }
}

impl CameraController for OrbitalController
{
  fn update_matrices(&self, matrices: &mut CameraMatrices, aspect: f32)
  {
    let lat_rad = self.lat.to_radians() as f64;
    let lon_rad = self.lon.to_radians() as f64;

    let x = self.altitude * lat_rad.cos() * lon_rad.sin();
    let y = self.altitude * lat_rad.sin();
    let z = self.altitude * lat_rad.cos() * lon_rad.cos();

    let eye = DVec3::new(x, y, z) + self.target;

    // High precision Look-At
    let view = glam::DMat4::look_at_rh(eye, self.target, glam::DVec3::Y);
    let proj = Mat4::perspective_rh(self.fov.to_radians(), aspect, self.z_near, self.z_far);

    let view_proj = proj * view.as_mat4();

    matrices.view_proj = view_proj.to_cols_array_2d();
    matrices.inv_view_proj = view_proj.inverse().to_cols_array_2d();
    matrices.eye_world = eye.as_vec3().to_array();
  }
  fn get_eye_f64(&self) -> [f64; 3]
  {
    // Calculated inside update_matrices...
    // You might want to cache 'eye' in the struct or recalculate here.
    // For now, let's recalculate for simplicity:
    let lat_rad = self.lat.to_radians() as f64;
    let lon_rad = self.lon.to_radians() as f64;
    let x = self.altitude * lat_rad.cos() * lon_rad.sin();
    let y = self.altitude * lat_rad.sin();
    let z = self.altitude * lat_rad.cos() * lon_rad.cos();
    (DVec3::new(x, y, z) + self.target).to_array()
  }
}

impl OrbitalController
{
  pub fn handle_input(&mut self, input: &crate::input::state::InputState, _dt: f32)
  {
    // 1. Rotation (Right Mouse Button Drag)
    // In Google Earth, dragging right moves your "view" left (rotating the globe)
    if input.mouse_buttons_down.contains(&MouseButton::Right)
    {
      let sensitivity = 0.2;
      self.lon -= input.mouse_delta.x * sensitivity;
      self.lat += input.mouse_delta.y * sensitivity;

      // Clamp latitude to prevent flipping at the poles
      self.lat = self.lat.clamp(-89.0, 89.0);
    }

    // 2. Zoom (Mouse Wheel)
    // Scrolling "up" (positive) should bring you closer to the target
    if input.scroll_delta != 0.0
    {
      let zoom_speed = self.altitude * 0.1;
      self.altitude -= (input.scroll_delta as f64) * zoom_speed;

      // Prevent going inside the planet or too far away
      self.altitude = self.altitude.clamp(2.0, 5000.0);
    }
  }
}
