use std::sync::{Arc, Mutex};

use winit::{
  application::ApplicationHandler,
  event::WindowEvent,
  event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
  window::{Window, WindowId},
};

use crate::camera::Camera;
use crate::input::{apply_input_to_camera, InputState};
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

    // Set the real aspect ratio from the window before creating the renderer,
    // then drop and re-acquire the lock so the borrow is immutable for Renderer::new.
    // The renderer init is synchronous (pollster), so no deadlock risk.
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
      Some(w) => w.clone(), // Clone the Arc — cheap, releases the borrow
      None => return,
    };

    {
      let mut cam = self.camera.lock().unwrap();
      if let Some(renderer) = &mut self.renderer
      {
        apply_input_to_camera(&self.input, &mut cam);
        renderer.update_camera(&cam);
      }
    }

    // Take egui input before the immutable self borrow in run_ui
    let raw_input = {
      let renderer = match &mut self.renderer
      {
        Some(r) => r,
        None => return,
      };
      renderer.gui.state.take_egui_input(&window)
    }; // mutable borrow of renderer ends here

    // Now run_ui only needs &self (no conflict)
    let full_output = {
      let renderer = match &self.renderer
      {
        Some(r) => r,
        None => return,
      };
      renderer.gui.context.run(raw_input, |ctx| {
        self.run_ui(ctx); // fine — self is immutably borrowed here
      })
    };

    if let Some(renderer) = &mut self.renderer
    {
      renderer.render(&window, full_output);
    }

    window.request_redraw();
    self.input.end_frame();
  }

  /// Defines the on-screen debug panels.
  /// This is called once per frame inside the on_frame loop.
  fn run_ui(&self, ctx: &egui::Context)
  {
    // 1. Acquire data
    let cam = self.camera.lock().unwrap();
    let renderer = match &self.renderer
    {
      Some(r) => r,
      None => return, // Early return if renderer isn't ready
    };

    // 2. Define the Telemetry Window
    egui::Window::new("📊 Kyzu Telemetry")
      .anchor(egui::Align2::LEFT_TOP, [10.0, 10.0])
      .resizable(false)
      .collapsible(true)
      .show(ctx, |ui| {
        // Adaptor Info
        ui.heading("Hardware");
        ui.label(format!("Device:  {}", renderer.adapter_info.name));
        ui.label(format!("Backend: {:?}", renderer.adapter_info.backend));

        ui.add_space(8.0);
        ui.separator();
        ui.add_space(8.0);

        // Camera Transforms
        ui.heading("Camera");
        ui.monospace(format!("Radius:    {:.4}", cam.radius));
        ui.monospace(format!(
          "Target:    {:.2}, {:.2}, {:.2}",
          cam.target.x, cam.target.y, cam.target.z
        ));
        ui.monospace(format!("Azimuth:   {:.1}°", cam.azimuth.to_degrees()));
        ui.monospace(format!("Elevation: {:.1}°", cam.elevation.to_degrees()));

        ui.add_space(8.0);
        ui.separator();
        ui.add_space(8.0);

        // Grid/LOD Info
        ui.heading("Grid System");
        ui.label(format!("LOD Scale: {:.1}", renderer.grid_lod_scale));
        ui.label(format!("LOD Fade:  {:.3}", renderer.grid_lod_fade));
      });
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

    if let Some(renderer) = &mut self.renderer
    {
      let response = renderer.gui.state.on_window_event(self.window.as_ref().unwrap(), &event);

      if response.consumed
      {
        return;
      }
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
