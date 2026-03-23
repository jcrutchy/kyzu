use glam::{Mat4, Vec3, Quat};
use crate::render::shared::CameraMatrices;
use super::CameraController;

pub struct OrbitalController 
{
  pub lat: f32,       // Latitude in degrees (-90 to 90)
  pub lon: f32,       // Longitude in degrees
  pub altitude: f32,  // Distance from center
  pub target: Vec3,   // The center of the world body
  pub fov: f32,
  pub z_near: f32,
  pub z_far: f32,
}

impl Default for OrbitalController 
{
  fn default() -> Self 
  {
    Self {
      lat: 0.0,
      lon: 0.0,
      altitude: 10.0,
      target: Vec3::ZERO,
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
    let lat_rad = self.lat.to_radians();
    let lon_rad = self.lon.to_radians();

    // Convert Spherical to Cartesian (Right-Handed)
    let x = self.altitude * lat_rad.cos() * lon_rad.sin();
    let y = self.altitude * lat_rad.sin();
    let z = self.altitude * lat_rad.cos() * lon_rad.cos();

    let eye = Vec3::new(x, y, z) + self.target;
    
    // Create view matrix looking at the target
    let view = Mat4::look_at_rh(eye, self.target, Vec3::Y);
    let proj = Mat4::perspective_rh(self.fov.to_radians(), aspect, self.z_near, self.z_far);
    
    let view_proj = proj * view;
    
    matrices.view_proj = view_proj.to_cols_array_2d();
    matrices.inv_view_proj = view_proj.inverse().to_cols_array_2d();
    matrices.eye_world = eye.to_array();
  }
}
