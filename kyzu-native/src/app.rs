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

pub fn run()
{
  let event_loop = EventLoop::new().unwrap();
  let mut app = KyzuApp::new();

  event_loop.run_app(&mut app).unwrap();
}

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
    let camera = Camera::new(16.0 / 9.0);

    Self {
      window: None,
      renderer: None,
      camera: Arc::new(Mutex::new(camera)),
      input: InputState::new(),
    }
  }

  fn init_window_and_renderer(&mut self, event_loop: &ActiveEventLoop)
  {
    if self.window.is_some()
    {
      return;
    }

    let attrs = Window::default_attributes().with_title("Kyzu — Minimal Cube");
    let window = Arc::new(event_loop.create_window(attrs).unwrap());

    {
      let size = window.inner_size();
      let mut cam = self.camera.lock().unwrap();
      cam.set_aspect(size.width as f32 / size.height as f32);
    }

    let renderer = pollster::block_on(Renderer::new(window.clone(), self.camera.clone()));

    self.window = Some(window);
    self.renderer = Some(renderer);
  }

  fn handle_window_event(&mut self, elwt: &ActiveEventLoop, window_id: WindowId, event: WindowEvent)
  {
    let window = match &self.window
    {
      Some(w) if w.id() == window_id => w,
      _ => return,
    };

    self.input.handle_event(&event);

    match event
    {
      WindowEvent::CloseRequested =>
      {
        elwt.exit();
      }

      WindowEvent::Resized(size) =>
      {
        if size.width == 0 || size.height == 0
        {
          return;
        }

        if let Some(renderer) = &mut self.renderer
        {
          renderer.resize(size.width, size.height);
        }

        let mut cam = self.camera.lock().unwrap();
        cam.set_aspect(size.width as f32 / size.height as f32);

        if let Some(renderer) = &mut self.renderer
        {
          renderer.update_camera(&cam);
        }

        window.request_redraw();
      }

      _ =>
      {}
    }
  }

  fn frame(&mut self)
  {
    if let (Some(window), Some(renderer)) = (&self.window, &mut self.renderer)
    {
      renderer.render();
      window.request_redraw();
      self.input.end_frame();
    }
  }
}

impl ApplicationHandler for KyzuApp
{
  fn resumed(&mut self, event_loop: &ActiveEventLoop)
  {
    event_loop.set_control_flow(ControlFlow::Wait);
    self.init_window_and_renderer(event_loop);
  }

  fn window_event(&mut self, event_loop: &ActiveEventLoop, window_id: WindowId, event: WindowEvent)
  {
    self.handle_window_event(event_loop, window_id, event);
  }

  fn about_to_wait(&mut self, _event_loop: &ActiveEventLoop)
  {
    self.frame();
  }
}
