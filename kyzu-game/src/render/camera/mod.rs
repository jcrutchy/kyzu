use crate::render::shared::CameraMatrices;

pub trait CameraController
{
  fn update_matrices(&self, matrices: &mut CameraMatrices, aspect: f32);
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
  pub fn update(
    &mut self,
    shared: &mut crate::render::shared::SharedState,
    input: &crate::input::state::InputState,
    dt: f32,
  )
  {
    let aspect = shared.screen_width as f32 / shared.screen_height as f32;

    match shared.mode
    {
      crate::render::shared::CameraMode::Free =>
      {
        self.free_controller.handle_input(input, dt);
        self.free_controller.update_matrices(&mut shared.camera, aspect);
      }
      crate::render::shared::CameraMode::Orbital =>
      {
        self.orbital_controller.handle_input(input, dt);
        self.orbital_controller.update_matrices(&mut shared.camera, aspect);
      }
    }
  }
}
