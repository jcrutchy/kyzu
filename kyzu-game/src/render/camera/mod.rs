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

          let to_target = (self.orbital_controller.target - shared.eye_world).normalize();

          let pitch = (to_target.y as f32).asin();
          let yaw = {
            let xz_len = (to_target.x * to_target.x + to_target.z * to_target.z).sqrt() as f32;
            if xz_len < 1e-6
            {
              self.free_controller.yaw
            }
            else
            {
              f32::atan2(-to_target.x as f32, -to_target.z as f32)
            }
          };

          self.free_controller.pitch = pitch;
          self.free_controller.yaw = yaw;
          self.free_controller.speed_gear = 0;
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
