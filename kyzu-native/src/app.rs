use std::sync::Arc;

use winit::{
  application::ApplicationHandler,
  event::{ElementState, WindowEvent},
  event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
  window::{Window, WindowId},
};

use crate::config::KyzuConfig;
use crate::input::InputState;
use crate::renderer::kernel::Kernel;
use crate::renderer::modules::earth_terrain::EarthTerrainModule;

//
// ──────────────────────────────────────────────────────────────
//   Entry point
// ──────────────────────────────────────────────────────────────
//

pub fn run()
{
  let config = crate::config::load().unwrap_or_else(|e| {
    eprintln!("Failed to load kyzu.json: {e}");
    std::process::exit(1);
  });

  let event_loop = EventLoop::new().unwrap();
  let mut app = KyzuApp::new(config);
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
  config: KyzuConfig,
}

impl KyzuApp
{
  fn new(config: KyzuConfig) -> Self
  {
    Self { window: None, kernel: None, input: InputState::new(), config }
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

    // Initialise camera from config
    // ENU origin is bbox centre, so camera target starts at ENU zero
    kernel.camera.target = glam::DVec3::ZERO;
    kernel.camera.radius = self.config.startup.camera.radius;
    // Look down at a reasonable angle for a top-down map view
    kernel.camera.elevation = std::f64::consts::FRAC_PI_4; // 45°
    kernel.camera.azimuth = -std::f64::consts::FRAC_PI_4;

    // Load earth terrain — this is the slow step (heightmap decode)
    // TODO: move to a background thread with a loading screen
    log::info!("Loading terrain...");
    match EarthTerrainModule::from_config(&kernel.device, &kernel.shared, &self.config)
    {
      Ok(earth) =>
      {
        kernel.modules.push(Box::new(earth));
        log::info!("Terrain loaded.");
      }
      Err(e) =>
      {
        eprintln!("Failed to load terrain: {e}");
        std::process::exit(1);
      }
    }

    // Debug cross at camera target
    kernel.add_module::<crate::renderer::modules::debug::DebugModule>();

    // Sync camera matrices after setting radius/target
    kernel.update_camera(&self.input);

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

    let raw_input = {
      let kernel = match &mut self.kernel
      {
        Some(k) => k,
        None => return,
      };
      kernel.gui.state.take_egui_input(&window)
    };

    let full_output = {
      let ctx = self.kernel.as_ref().unwrap().gui.context.clone();
      ctx.run(raw_input, |ctx| self.run_ui(ctx))
    };

    if let Some(kernel) = &mut self.kernel
    {
      kernel.render(&window, full_output);
    }

    window.request_redraw();
    self.input.end_frame();
  }

  fn run_ui(&mut self, ctx: &egui::Context)
  {
    let kernel = match &self.kernel
    {
      Some(k) => k,
      None => return,
    };

    let cam = &kernel.camera;

    egui::Window::new("📊 Kyzu")
      .anchor(egui::Align2::LEFT_TOP, [10.0, 10.0])
      .resizable(false)
      .collapsible(true)
      .show(ctx, |ui| {
        ui.heading("GPU");
        ui.label(format!("Device:  {}", kernel.adapter_info.name));
        ui.label(format!("Backend: {:?}", kernel.adapter_info.backend));

        ui.add_space(8.0);
        ui.separator();
        ui.add_space(8.0);

        ui.heading("Camera");
        ui.monospace(format!("Radius:    {:.3e} m", cam.radius));
        ui.monospace(format!(
          "Target:    {:.1}, {:.1}, {:.1}",
          cam.target.x, cam.target.y, cam.target.z
        ));
        ui.monospace(format!("Azimuth:   {:.1}°", cam.azimuth.to_degrees()));
        ui.monospace(format!("Elevation: {:.1}°", cam.elevation.to_degrees()));

        // Show approximate lat/lon if we have an ENU origin
        if let Some(earth) = kernel.modules.iter().find_map(|m| {
          // Can't downcast immutably in a clean way here,
          // so we just skip for now — lat/lon display is a nice-to-have
          None::<&EarthTerrainModule>
        })
        {
          ui.add_space(4.0);
        }
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
