use std::sync::Arc;

use glam::DVec3;
use winit::{
  application::ApplicationHandler,
  event::{ElementState, WindowEvent},
  event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
  window::{Window, WindowId},
};

use crate::input::InputState;
use crate::renderer::kernel::Kernel;
use crate::renderer::modules::sphere::SphereInstance;

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
  kernel: Option<Kernel>,
  input: InputState,
}

impl KyzuApp
{
  fn new() -> Self
  {
    Self { window: None, kernel: None, input: InputState::new() }
  }

  fn init_window_and_kernel(&mut self, event_loop: &ActiveEventLoop)
  {
    if self.window.is_some()
    {
      return;
    }

    let attrs = Window::default_attributes().with_title("Kyzu");
    let window = Arc::new(event_loop.create_window(attrs).unwrap());

    let mut kernel = pollster::block_on(Kernel::new(window.clone()));

    // Set real aspect ratio from window before any frame is rendered
    let size = window.inner_size();
    kernel.camera.set_aspect(size.width as f32 / size.height as f32);

    // Register render modules in draw order
    kernel.add_module::<crate::renderer::modules::sphere::SphereModule>();
    kernel.add_module::<crate::renderer::modules::axes::AxesModule>();
    kernel.add_module::<crate::renderer::modules::debug::DebugModule>();
    kernel.add_module::<crate::renderer::modules::grid::GridModule>();

    // Populate sphere instances
    if let Some(module) = kernel
      .modules
      .iter_mut()
      .find_map(|m| m.as_any_mut().downcast_mut::<crate::renderer::modules::sphere::SphereModule>())
    {
      module.instances = vec![
        SphereInstance { center: DVec3::new(0.0, 9.371e7, 0.0), radius: 6.371e6 },
        SphereInstance { center: DVec3::new(9.371e7, 9.371e6, 9.371e3), radius: 6.371e6 },
      ];
    }

    self.window = Some(window);
    self.kernel = Some(kernel);
  }

  fn on_resize(&mut self, width: u32, height: u32)
  {
    if width == 0 || height == 0
    {
      return;
    }

    if let Some(kernel) = &mut self.kernel
    {
      kernel.resize(width, height);
    }

    if let Some(window) = &self.window
    {
      window.request_redraw();
    }
  }

  fn on_frame(&mut self)
  {
    let window = match &self.window
    {
      Some(w) => w.clone(),
      None => return,
    };

    if let Some(kernel) = &mut self.kernel
    {
      kernel.update_camera(&self.input);
    }

    // Take egui input before the immutable borrow in run_ui
    let raw_input = {
      let kernel = match &mut self.kernel
      {
        Some(k) => k,
        None => return,
      };
      kernel.gui.state.take_egui_input(&window)
    };

    let full_output = {
      let kernel = match &self.kernel
      {
        Some(k) => k,
        None => return,
      };
      kernel.gui.context.run(raw_input, |ctx| {
        self.run_ui(ctx);
      })
    };

    if let Some(kernel) = &mut self.kernel
    {
      kernel.render(&window, full_output);
    }

    window.request_redraw();
    self.input.end_frame();
  }

  fn run_ui(&self, ctx: &egui::Context)
  {
    let kernel = match &self.kernel
    {
      Some(k) => k,
      None => return,
    };

    let cam = &kernel.camera;

    egui::Window::new("📊 Kyzu Telemetry")
      .anchor(egui::Align2::LEFT_TOP, [10.0, 10.0])
      .resizable(false)
      .collapsible(true)
      .show(ctx, |ui| {
        ui.heading("Hardware");
        ui.label(format!("Device:  {}", kernel.adapter_info.name));
        ui.label(format!("Backend: {:?}", kernel.adapter_info.backend));

        ui.add_space(8.0);
        ui.separator();
        ui.add_space(8.0);

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

        ui.heading("Grid System");
        ui.label(format!("LOD Scale: {:.3}", kernel.shared.camera.lod_scale));
        ui.label(format!("LOD Fade:  {:.3}", kernel.shared.camera.lod_fade));
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
    self.init_window_and_kernel(event_loop);
  }

  fn window_event(&mut self, event_loop: &ActiveEventLoop, window_id: WindowId, event: WindowEvent)
  {
    let is_our_window = self.window.as_ref().map_or(false, |w| w.id() == window_id);
    if !is_our_window
    {
      return;
    }

    // Always track cursor position regardless of egui
    self.input.track_cursor(&event);

    // Pass event to egui
    if let Some(kernel) = &mut self.kernel
    {
      let _ = kernel.gui.state.on_window_event(self.window.as_ref().unwrap(), &event);
    }

    // Only block input if cursor is actually over an egui element
    let egui_wants_input =
      self.kernel.as_ref().map_or(false, |k| k.gui.context.is_pointer_over_area());

    if egui_wants_input
    {
      match &event
      {
        // Block presses and scroll when over egui, but never block releases
        // — otherwise button state gets stuck when releasing over a panel
        WindowEvent::MouseInput { state: ElementState::Pressed, .. }
        | WindowEvent::MouseWheel { .. } => return,
        _ =>
        {}
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
