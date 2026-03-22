use std::sync::Arc;

use winit::application::ApplicationHandler;
use winit::event::{ElementState, MouseButton, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop};
use winit::window::{Window, WindowId};

use crate::core::config;
use crate::core::log;
use crate::input::state::InputState;
use crate::render::kernel::Renderer;

pub struct App
{
  pub config: config::KyzuConfig,
  pub logger: log::Logger,
  pub input: InputState,
  pub renderer: Option<Renderer>,
  pub window: Option<Arc<Window>>,
}

impl ApplicationHandler for App
{
  fn resumed(&mut self, event_loop: &ActiveEventLoop)
  {
    if self.window.is_none()
    {
      let window_attributes = Window::default_attributes().with_title("Kyzu").with_inner_size(
        winit::dpi::LogicalSize::new(self.config.app.window_width, self.config.app.window_height),
      );

      // Wrap window in Arc for shared ownership
      let window =
        Arc::new(event_loop.create_window(window_attributes).expect("Failed to create window"));

      // Renderer gets its own clone of the Arc
      let renderer = pollster::block_on(Renderer::new(window.clone())).expect("Failed to init GPU");

      self.renderer = Some(renderer);
      self.window = Some(window);

      self.logger.emit(log::LogLevel::Info, "Window and Renderer initialized safely with Arc.");
    }
  }

  fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent)
  {
    match event
    {
      WindowEvent::CloseRequested =>
      {
        self.logger.emit(log::LogLevel::Info, "Exit requested.");
        event_loop.exit();
      }

      WindowEvent::Resized(new_size) =>
      {
        if let Some(r) = &mut self.renderer
        {
          r.resize(Some(new_size));
        }
      }

      WindowEvent::RedrawRequested =>
      {
        if let Some(renderer) = &mut self.renderer
        {
          if let Err(e) = renderer.render()
          {
            // Passing None uses internal window size query, avoiding borrow issues
            eprintln!("Render error: {}", e);
            renderer.resize(None);
          }
        }
      }

      WindowEvent::KeyboardInput { event, .. } => self.input.update_key(&event),

      WindowEvent::CursorMoved { position, .. } =>
      {
        let new_pos = glam::vec2(position.x as f32, position.y as f32);
        self.input.mouse_delta = new_pos - self.input.mouse_pos;
        self.input.mouse_pos = new_pos;
      }

      WindowEvent::MouseInput { state, button, .. } =>
      {
        let is_pressed = state == ElementState::Pressed;
        match button
        {
          MouseButton::Left => self.input.left_clicked = is_pressed,
          MouseButton::Right => self.input.right_clicked = is_pressed,
          _ => (),
        }
      }

      _ => (),
    }
  }

  fn about_to_wait(&mut self, _event_loop: &ActiveEventLoop)
  {
    if let Some(window) = &self.window
    {
      window.request_redraw();
    }
    self.input.tick();
  }
}

pub fn run() -> Result<(), crate::core::error::KyzuError>
{
  let cfg = config::load().map_err(|e| crate::core::error::KyzuError::ConfigLoad(e))?;
  let log_path = format!("{}{}", cfg.app.data_dir, cfg.app.log_filename);
  let logger = log::Logger::new(&log_path);

  let event_loop =
    EventLoop::new().map_err(|e| crate::core::error::KyzuError::Window(e.to_string()))?;

  let mut app = App { config: cfg, logger, input: InputState::new(), renderer: None, window: None };

  event_loop.run_app(&mut app).map_err(|e| crate::core::error::KyzuError::Window(e.to_string()))
}
