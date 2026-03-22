use winit::event::{ElementState, KeyEvent};
use winit::keyboard::{KeyCode, PhysicalKey};

pub struct InputState
{
  pub keys_down: [bool; 256], // Simple fixed-size array for KeyCodes
  pub mouse_pos: crate::core::math::RenderVec2,
  pub mouse_delta: crate::core::math::RenderVec2,
  pub left_clicked: bool,
  pub right_clicked: bool,
  pub scroll_delta: f32,
}

impl InputState
{
  pub fn new() -> Self
  {
    Self {
      keys_down: [false; 256],
      mouse_pos: glam::vec2(0.0, 0.0),
      mouse_delta: glam::vec2(0.0, 0.0),
      left_clicked: false,
      right_clicked: false,
      scroll_delta: 0.0,
    }
  }

  pub fn update_key(&mut self, event: &KeyEvent)
  {
    if let PhysicalKey::Code(code) = event.physical_key
    {
      let index = code as usize;
      if index < 256
      {
        self.keys_down[index] = event.state == ElementState::Pressed;
      }
    }
  }

  pub fn is_key_down(&self, code: KeyCode) -> bool
  {
    let index = code as usize;
    if index < 256
    {
      return self.keys_down[index];
    }
    false
  }

  // Called at the end of every frame to reset relative movements
  pub fn tick(&mut self)
  {
    self.mouse_delta = glam::vec2(0.0, 0.0);
    self.scroll_delta = 0.0;
  }
}
