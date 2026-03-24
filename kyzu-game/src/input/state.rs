use std::collections::HashSet;

use glam::Vec2;
use winit::event::{ElementState, MouseButton, MouseScrollDelta, WindowEvent};
use winit::keyboard::{KeyCode, PhysicalKey};

pub struct InputState
{
  // We use a HashSet for keys so we don't have to worry about array bounds
  pub keys_down: HashSet<KeyCode>,
  pub mouse_pos: Vec2,
  pub mouse_delta: Vec2,
  pub mouse_buttons_down: HashSet<MouseButton>,
  pub scroll_delta: f32,
}

impl InputState
{
  pub fn new() -> Self
  {
    Self {
      keys_down: HashSet::new(),
      mouse_pos: Vec2::ZERO,
      mouse_delta: Vec2::ZERO,
      mouse_buttons_down: HashSet::new(),
      scroll_delta: 0.0,
    }
  }

  pub fn consume_mouse_delta(&mut self) -> glam::Vec2
  {
    let delta = self.mouse_delta;
    self.mouse_delta = glam::Vec2::ZERO;
    delta
  }

  /// The core Phase 1.4 logic: Update state from winit events
  pub fn process_event(&mut self, event: &WindowEvent)
  {
    match event
    {
      WindowEvent::KeyboardInput { event: key_event, .. } =>
      {
        if let PhysicalKey::Code(code) = key_event.physical_key
        {
          if key_event.state == ElementState::Pressed
          {
            self.keys_down.insert(code);
          }
          else
          {
            self.keys_down.remove(&code);
          }
        }
      }
      WindowEvent::CursorMoved { position, .. } =>
      {
        let new_pos = Vec2::new(position.x as f32, position.y as f32);
        self.mouse_delta = new_pos - self.mouse_pos;
        self.mouse_pos = new_pos;
      }
      WindowEvent::MouseInput { state, button, .. } =>
      {
        if *state == ElementState::Pressed
        {
          self.mouse_buttons_down.insert(*button);
        }
        else
        {
          self.mouse_buttons_down.remove(button);
        }
      }
      WindowEvent::MouseWheel { delta, .. } => match delta
      {
        MouseScrollDelta::LineDelta(_, y) => self.scroll_delta += y,
        MouseScrollDelta::PixelDelta(pos) => self.scroll_delta += pos.y as f32 * 0.1,
      },
      _ =>
      {}
    }
  }

  /// PILFERED IDEA: Reset relative values at the end of the frame
  pub fn tick(&mut self)
  {
    self.mouse_delta = Vec2::ZERO;
    self.scroll_delta = 0.0;
  }

  pub fn is_key_down(&self, code: KeyCode) -> bool
  {
    self.keys_down.contains(&code)
  }
}
