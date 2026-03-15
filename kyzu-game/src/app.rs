use std::path::Path;
use std::sync::mpsc;
use std::sync::Arc;
use std::thread;

use winit::{
  application::ApplicationHandler,
  event::{ElementState, KeyEvent, WindowEvent},
  event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
  keyboard::{KeyCode, PhysicalKey},
  window::{Window, WindowId},
};

use crate::input::InputState;
use crate::loading_screen::LoadingScreen;
use crate::renderer::kernel::Kernel;
use crate::renderer::modules::camera::FocusBody;
use crate::renderer::modules::sphere::{SphereInstance, SphereModule, SphereTexture};
use crate::renderer::modules::terrain_mesh::TerrainMeshModule;

// ──────────────────────────────────────────────────────────────
//   Real astronomical constants (metres)
// ──────────────────────────────────────────────────────────────

const EARTH_RADIUS: f64 = 6.371e6;
const MOON_RADIUS: f64 = 1.737e6;
const EARTH_MOON_DIST: f64 = 3.844e8;

// ──────────────────────────────────────────────────────────────
//   Texture data loaded on background thread
// ──────────────────────────────────────────────────────────────

struct TextureData
{
  earth_bytes: Vec<u8>,
  moon_bytes: Vec<u8>,
}

// ──────────────────────────────────────────────────────────────
//   Entry point
// ──────────────────────────────────────────────────────────────

pub fn run()
{
  let event_loop = EventLoop::new().unwrap();
  let mut app = SolarApp::new();
  event_loop.run_app(&mut app).unwrap();
}

// ──────────────────────────────────────────────────────────────
//   Application state
// ──────────────────────────────────────────────────────────────

struct SolarApp
{
  window: Option<Arc<Window>>,
  kernel: Option<Kernel>,
  input: InputState,
  loading_screen: Option<LoadingScreen>,
  texture_rx: Option<mpsc::Receiver<TextureData>>,
  textures_ready: bool,
}

impl SolarApp
{
  fn new() -> Self
  {
    // Spawn bake process immediately — runs during kernel init
    let loading_screen = LoadingScreen::new(r"C:\dev\kyzu\target\debug\kyzu-bake.exe").ok();

    // Kick off texture loading on background thread immediately
    let (tx, rx) = mpsc::channel::<TextureData>();
    thread::spawn(move || {
      let earth_bytes = std::fs::read(r"C:\dev\kyzu_data\world.200407.3x5400x2700.jpg")
        .expect("Earth texture not found");
      let moon_bytes =
        std::fs::read(r"C:\dev\kyzu_data\lroc_color_2k.jpg").expect("Moon texture not found");
      let _ = tx.send(TextureData { earth_bytes, moon_bytes });
    });

    Self {
      window: None,
      kernel: None,
      input: InputState::new(),
      loading_screen,
      texture_rx: Some(rx),
      textures_ready: false,
    }
  }

  fn init_window_and_kernel(&mut self, event_loop: &ActiveEventLoop)
  {
    if self.window.is_some()
    {
      return;
    }

    let attrs = Window::default_attributes().with_title("Solar Native");
    let window = Arc::new(event_loop.create_window(attrs).unwrap());

    let mut kernel = pollster::block_on(Kernel::new(window.clone()));

    let size = window.inner_size();
    kernel.camera.set_aspect(size.width as f32 / size.height as f32);
    /*
        // Register sphere module — no textures yet
        kernel.add_module::<SphereModule>();

        // Set up sphere instances with placeholder textures
        // Textures will be uploaded once the background thread finishes
        let sphere_module = kernel
          .modules
          .iter_mut()
          .find_map(|m| m.as_any_mut().downcast_mut::<SphereModule>())
          .unwrap();

        sphere_module.instances = vec![
          SphereInstance { center: glam::DVec3::ZERO, radius: EARTH_RADIUS, texture: 0 },
          SphereInstance {
            center:  glam::DVec3::new(0.0, EARTH_MOON_DIST, 0.0),
            radius:  MOON_RADIUS,
            texture: 1,
          },
        ];
    */
    // ── Load terrain mesh ─────────────────────────────────────────
    let terrain_path = Path::new(r"C:\dev\kyzu_data\worlds\test_continents\terrain_l4.bin");
    if terrain_path.exists()
    {
      match TerrainMeshModule::load(&kernel.device, &kernel.shared, terrain_path)
      {
        Ok(module) => kernel.modules.push(Box::new(module)),
        Err(e) => log::warn!("Failed to load terrain mesh: {}", e),
      }
    }

    self.window = Some(window);
    self.kernel = Some(kernel);
  }

  /// Called every frame — checks if texture thread has finished
  fn poll_textures(&mut self)
  {
    if self.textures_ready
    {
      return;
    }

    let ready = if let Some(rx) = &self.texture_rx { rx.try_recv().ok() } else { None };

    if let Some(data) = ready
    {
      self.texture_rx = None;

      /*if let Some(k) = &mut self.kernel
      {
        let sphere_module = k
          .modules
          .iter_mut()
          .find_map(|m| m.as_any_mut().downcast_mut::<SphereModule>())
          .unwrap();

        sphere_module.textures.clear();

        sphere_module.textures.push(
          SphereTexture::from_bytes(
            &k.device, &k.queue, &k.tex_layout,
            &data.earth_bytes, "Earth Texture",
          ).expect("Failed to decode Earth texture"),
        );

        sphere_module.textures.push(
          SphereTexture::from_bytes(
            &k.device, &k.queue, &k.tex_layout,
            &data.moon_bytes, "Moon Texture",
          ).expect("Failed to decode Moon texture"),
        );

        self.textures_ready = true;
        log::info!("Textures uploaded to GPU");
      }*/
    }
  }

  fn on_resize(&mut self, width: u32, height: u32)
  {
    if width == 0 || height == 0
    {
      return;
    }
    if let Some(k) = &mut self.kernel
    {
      k.resize(width, height);
    }
    if let Some(w) = &self.window
    {
      w.request_redraw();
    }
  }

  fn on_frame(&mut self)
  {
    let window = match &self.window
    {
      Some(w) => w.clone(),
      None => return,
    };

    // Check if textures have arrived from background thread
    self.poll_textures();

    // Update loading screen state
    if let Some(ls) = &self.loading_screen
    {
      if ls.is_finished()
      {
        self.loading_screen = None;
      }
    }

    if let Some(k) = &mut self.kernel
    {
      k.update_camera(&self.input);
    }

    let raw_input = {
      let k = match &mut self.kernel
      {
        Some(k) => k,
        None => return,
      };
      k.gui.state.take_egui_input(&window)
    };

    let full_output = {
      let ctx = self.kernel.as_ref().unwrap().gui.context.clone();
      let is_loading = self.loading_screen.is_some();
      ctx.run(raw_input, |ctx| {
        if is_loading
        {
          if let Some(ls) = &self.loading_screen
          {
            ls.render(ctx);
          }
        }
        else
        {
          self.run_ui(ctx);
        }
      })
    };

    if let Some(k) = &mut self.kernel
    {
      k.render(&window, full_output);
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

    egui::Window::new("📊 Solar Telemetry")
      .anchor(egui::Align2::LEFT_TOP, [10.0, 10.0])
      .resizable(false)
      .collapsible(true)
      .show(ctx, |ui| {
        ui.heading("Camera");
        ui.monospace(format!("Focus:     {}", cam.focus.name));
        ui.monospace(format!("Radius:    {:.3e} m", cam.radius));
        ui.monospace(format!("Altitude:  {:.3e} m", cam.radius - cam.focus.radius));
        ui.monospace(format!("Azimuth:   {:.1}°", cam.azimuth.to_degrees()));
        ui.monospace(format!("Elevation: {:.1}°", cam.elevation.to_degrees()));

        ui.add_space(8.0);
        ui.separator();
        ui.add_space(8.0);

        ui.heading("Controls");
        ui.label("Right-drag  — orbit");
        ui.label("Scroll      — zoom");
        ui.label("E           — focus Earth");
        ui.label("M           — focus Moon");
      });
  }
}

// ──────────────────────────────────────────────────────────────
//   winit event handler
// ──────────────────────────────────────────────────────────────

impl ApplicationHandler for SolarApp
{
  fn resumed(&mut self, event_loop: &ActiveEventLoop)
  {
    event_loop.set_control_flow(ControlFlow::Poll);
    self.init_window_and_kernel(event_loop);
  }

  fn window_event(&mut self, event_loop: &ActiveEventLoop, window_id: WindowId, event: WindowEvent)
  {
    let is_ours = self.window.as_ref().map_or(false, |w| w.id() == window_id);
    if !is_ours
    {
      return;
    }

    self.input.track_cursor(&event);

    if let Some(k) = &mut self.kernel
    {
      if k.gui.state.on_window_event(&self.window.as_ref().unwrap(), &event).consumed
      {
        return;
      }
    }

    match event
    {
      WindowEvent::CloseRequested => event_loop.exit(),

      WindowEvent::Resized(size) => self.on_resize(size.width, size.height),

      WindowEvent::KeyboardInput {
        event: KeyEvent { physical_key: PhysicalKey::Code(key), state: ElementState::Pressed, .. },
        ..
      } => match key
      {
        KeyCode::Escape => event_loop.exit(),

        KeyCode::KeyE =>
        {
          if let Some(k) = &mut self.kernel
          {
            k.camera.set_focus(FocusBody {
              name: "Earth",
              position: glam::DVec3::ZERO,
              radius: EARTH_RADIUS,
            });
          }
        }

        KeyCode::KeyM =>
        {
          if let Some(k) = &mut self.kernel
          {
            k.camera.set_focus(FocusBody {
              name: "Moon",
              position: glam::DVec3::new(0.0, EARTH_MOON_DIST, 0.0),
              radius: MOON_RADIUS,
            });
          }
        }

        _ =>
        {}
      },

      WindowEvent::MouseInput { .. } | WindowEvent::MouseWheel { .. } =>
      {
        self.input.handle_event(&event)
      }

      WindowEvent::RedrawRequested => self.on_frame(),

      _ =>
      {}
    }
  }
}
