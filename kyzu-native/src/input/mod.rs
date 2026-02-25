use winit::event::{ElementState, MouseButton, MouseScrollDelta, WindowEvent};
use winit::keyboard::{Key, NamedKey};

pub struct InputState
{
  pub mouse_x: f32,
  pub mouse_y: f32,
  pub mouse_dx: f32,
  pub mouse_dy: f32,

  pub left_held: bool,
  pub middle_held: bool,
  pub right_held: bool,

  pub scroll: f32,

  pub shift_held: bool,
}

impl InputState
{
  pub fn new() -> Self
  {
    Self {
      mouse_x: 0.0,
      mouse_y: 0.0,
      mouse_dx: 0.0,
      mouse_dy: 0.0,

      left_held: false,
      middle_held: false,
      right_held: false,

      scroll: 0.0,

      shift_held: false,
    }
  }

  pub fn handle_event(&mut self, event: &WindowEvent)
  {
    match event
    {
      WindowEvent::CursorMoved { position, .. } =>
      {
        let x = position.x as f32;
        let y = position.y as f32;

        self.mouse_dx = x - self.mouse_x;
        self.mouse_dy = y - self.mouse_y;

        self.mouse_x = x;
        self.mouse_y = y;
      }

      WindowEvent::MouseInput { state, button, .. } =>
      {
        let pressed = *state == ElementState::Pressed;

        match button
        {
          MouseButton::Left => self.left_held = pressed,
          MouseButton::Middle => self.middle_held = pressed,
          MouseButton::Right => self.right_held = pressed,
          _ =>
          {}
        }
      }

      WindowEvent::MouseWheel { delta, .. } => match delta
      {
        MouseScrollDelta::LineDelta(_, y) => self.scroll += *y,
        MouseScrollDelta::PixelDelta(p) => self.scroll += p.y as f32,
      },

      WindowEvent::KeyboardInput { event, .. } => match &event.logical_key
      {
        Key::Named(NamedKey::Shift) =>
        {
          self.shift_held = event.state == ElementState::Pressed;
        }

        _ =>
        {}
      },

      _ =>
      {}
    }
  }

  pub fn end_frame(&mut self)
  {
    self.mouse_dx = 0.0;
    self.mouse_dy = 0.0;
    self.scroll = 0.0;
  }
}
