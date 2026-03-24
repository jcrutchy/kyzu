use crate::input::state::InputState;
use crate::render::shared::{CameraMode, SharedState};

pub trait CameraController
{
  fn update(&mut self, shared: &mut SharedState, input: &mut InputState, dt: f32);
}

pub mod free;
pub mod orbital;

pub struct CameraSystem
{
  pub free_controller: free::FreeController,
  pub orbital_controller: orbital::OrbitalController,
  last_mode: CameraMode, // Track the mode to detect transitions
}

impl CameraSystem
{
  pub fn new() -> Self
  {
    Self {
      free_controller: free::FreeController::default(),
      orbital_controller: orbital::OrbitalController::default(),
      last_mode: CameraMode::Orbital, // Default starting mode
    }
  }

  pub fn update(&mut self, shared: &mut SharedState, input: &mut InputState, dt: f32)
  {
    if shared.mode != self.last_mode
    {
      // 1. Reset the mouse delta IMMEDIATELY on transition
      input.consume_mouse_delta();

      match shared.mode
      {
        CameraMode::Free =>
        {
          self.free_controller.position = shared.eye_world;

          // Calculate the look vector from eye to planet center
          let forward = (self.orbital_controller.target - shared.eye_world).normalize();

          // Convert Vector to Euler Angles (Pitch/Yaw)
          // Pitch: Angle with the XZ plane
          self.free_controller.pitch = forward.y.asin() as f32;
          // Yaw: Angle on the XZ plane. In most RH systems, -Z is forward.
          self.free_controller.yaw = f32::atan2(forward.x as f32, -forward.z as f32);

          // Match the speed to the scale of the view
          self.free_controller.speed = (shared.eye_world.length() * 0.2) as f32;
        }
        CameraMode::Orbital =>
        {
          let rel = shared.eye_world - self.orbital_controller.target;
          let dist = rel.length();
          self.orbital_controller.altitude = dist;
          self.orbital_controller.lat = (rel.y / dist).asin().to_degrees();
          self.orbital_controller.lon = (rel.x).atan2(rel.z).to_degrees();
        }
      }
      self.last_mode = shared.mode;
    }

    match shared.mode
    {
      CameraMode::Free => self.free_controller.update(shared, input, dt),
      CameraMode::Orbital => self.orbital_controller.update(shared, input, dt),
    }
  }
}
