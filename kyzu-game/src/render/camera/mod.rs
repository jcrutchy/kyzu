use crate::input::state::InputState;
use crate::render::shared::{CameraMode, SharedState};

pub trait CameraController
{
  fn update(&mut self, shared: &mut SharedState, input: &InputState, dt: f32);
}

pub mod free;
pub mod orbital;

pub struct CameraSystem
{
  pub free_controller: free::FreeController,
  pub orbital_controller: orbital::OrbitalController,
}

impl CameraSystem
{
  pub fn new() -> Self
  {
    Self {
      free_controller: free::FreeController::default(),
      orbital_controller: orbital::OrbitalController::default(),
    }
  }

  pub fn update(&mut self, shared: &mut SharedState, input: &InputState, dt: f32)
  {
    match shared.mode
    {
      CameraMode::Free => self.free_controller.update(shared, input, dt),
      CameraMode::Orbital => self.orbital_controller.update(shared, input, dt),
    }
  }
}
