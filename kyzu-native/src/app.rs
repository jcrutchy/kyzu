use std::sync::{Arc, Mutex};

use winit::{
  application::ApplicationHandler,
  event::WindowEvent,
  event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
  window::{Window, WindowId},
};

use crate::camera::Camera;
use crate::input::InputState;
use crate::renderer::Renderer;

//
// ──────────────────────────────────────────────────────────────
//   Entry point
// ──────────────────────────────────────────────────────────────
//

pub fn run()
{
  let event_loop = EventLoop::new().unwrap();
  let mut app = KyzuApp::new();

  event_loop.run_app(&mut app).unwrap();
}

//
// ──────────────────────────────────────────────────────────────
//   Application state
// ──────────────────────────────────────────────────────────────
//

struct KyzuApp
{
  window: Option<Arc<Window>>,
  renderer: Option<Renderer>,
  camera: Arc<Mutex<Camera>>,
  input: InputState,
}

impl KyzuApp
{
  fn new() -> Self
  {
    Self {
      window: None,
      renderer: None,
      camera: Arc::new(Mutex::new(Camera::new(16.0 / 9.0))),
      input: InputState::new(),
    }
  }

  fn init_window_and_renderer(&mut self, event_loop: &ActiveEventLoop)
  {
    if self.window.is_some()
    {
      return;
    }

    let attrs = Window::default_attributes().with_title("Kyzu");
    let window = Arc::new(event_loop.create_window(attrs).unwrap());

    {
      let size = window.inner_size();
      let mut cam = self.camera.lock().unwrap();
      cam.set_aspect(size.width as f32 / size.height as f32);
    }

    let cam = self.camera.lock().unwrap();
    let renderer = pollster::block_on(Renderer::new(window.clone(), &cam));

    self.window = Some(window);
    self.renderer = Some(renderer);
  }

  fn on_resize(&mut self, width: u32, height: u32)
  {
    if width == 0 || height == 0
    {
      return;
    }

    let renderer = match &mut self.renderer
    {
      Some(r) => r,
      None => return,
    };

    renderer.resize(width, height);

    let mut cam = self.camera.lock().unwrap();
    cam.set_aspect(width as f32 / height as f32);
    renderer.update_camera(&cam);

    if let Some(window) = &self.window
    {
      window.request_redraw();
    }
  }

  fn on_frame(&mut self)
  {
    let window = match &self.window
    {
      Some(w) => w,
      None => return,
    };

    let renderer = match &mut self.renderer
    {
      Some(r) => r,
      None => return,
    };

    renderer.render();
    window.request_redraw();
    self.input.end_frame();
  }
}

//
// ──────────────────────────────────────────────────────────────
//   winit ApplicationHandler impl
// ──────────────────────────────────────────────────────────────
//

impl ApplicationHandler for KyzuApp
{
  fn resumed(&mut self, event_loop: &ActiveEventLoop)
  {
    event_loop.set_control_flow(ControlFlow::Wait);
    self.init_window_and_renderer(event_loop);
  }

  fn window_event(&mut self, event_loop: &ActiveEventLoop, window_id: WindowId, event: WindowEvent)
  {
    let is_our_window = self.window.as_ref().map_or(false, |w| w.id() == window_id);

    if !is_our_window
    {
      return;
    }

    self.input.handle_event(&event);

    match event
    {
      WindowEvent::CloseRequested =>
      {
        event_loop.exit();
      }

      WindowEvent::Resized(size) =>
      {
        self.on_resize(size.width, size.height);
      }

      _ =>
      {}
    }
  }

  fn about_to_wait(&mut self, _event_loop: &ActiveEventLoop)
  {
    self.on_frame();
  }
}
