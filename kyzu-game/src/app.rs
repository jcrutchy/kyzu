use std::path::PathBuf;
use std::sync::Arc;

use winit::application::ApplicationHandler;
use winit::event::{ElementState, KeyEvent, WindowEvent};
use winit::event_loop::ActiveEventLoop;
use winit::window::{Window, WindowId};

use crate::core::config::KyzuConfig;
use crate::core::log::{LogLevel, Logger};
use crate::core::time::TimeState;
use crate::input::state::InputState;
use crate::render::kernel::Renderer;
use crate::render::modules::solid::SolidModule;

pub struct App
{
  pub config: KyzuConfig,
  pub logger: Logger,
  pub input: InputState,
  pub time: TimeState,
  pub window: Option<Arc<Window>>,
  pub renderer: Option<Renderer>,
}

impl App
{
  pub fn new(config: KyzuConfig, logger: Logger) -> Self
  {
    Self {
      config,
      logger,
      input: InputState::new(),
      time: TimeState::new(),
      window: None,
      renderer: None,
    }
  }
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

      let window =
        Arc::new(event_loop.create_window(window_attributes).expect("Failed to create window"));

      let mut renderer = pollster::block_on(Renderer::new(window.clone()))
        .expect("Failed to initialize GPU Renderer");

      // --- Framework Logic: Add modules based on config ---

      // Resolve the test mesh path: [data_dir] / [test_mesh]
      let test_mesh_path =
        PathBuf::from(&self.config.app.data_dir).join(&self.config.app.test_mesh);

      // Only load the SolidModule if the file actually exists (our "Test Mode" check)
      if test_mesh_path.exists()
      {
        let solid_mod =
          SolidModule::new(&renderer.device, &renderer.shared, &test_mesh_path, &mut self.logger);
        renderer.add_module(solid_mod);
        self.logger.emit(LogLevel::Info, "Test SolidModule loaded.");
      }

      // TODO: Later, we will loop through self.config.world and add PlanetModules here

      // --- Finalize Renderer Setup ---
      renderer.camera_system.update(&mut renderer.shared, &mut self.input, 0.016);
      renderer.shared.camera_gpu.upload(&renderer.queue, &renderer.shared.camera);

      self.renderer = Some(renderer);
      self.window = Some(window);
      if let Some(renderer) = &self.renderer
      {
        let mode_msg = format!("Initial Camera Mode: {:?}", renderer.shared.mode);
        self.logger.emit(LogLevel::Info, &mode_msg);
      }
      self.logger.emit(LogLevel::Info, "Kyzu Engine Initialized (Modular Architecture)");
    }
  }

  fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent)
  {
    self.input.process_event(&event);

    match event
    {
      WindowEvent::CloseRequested =>
      {
        self.logger.emit(LogLevel::Info, "Exit requested.");
        self.renderer = None;
        event_loop.exit();
      }

      WindowEvent::KeyboardInput {
        event: KeyEvent { logical_key: key, state: ElementState::Pressed, .. },
        ..
      } =>
      {
        use winit::keyboard::{Key, NamedKey};

        match key
        {
          // Handle Escape (Exit)
          Key::Named(NamedKey::Escape) =>
          {
            self.logger.emit(LogLevel::Info, "Exit requested via Escape.");
            self.renderer = None;
            event_loop.exit();
          }

          // Handle Tab (Camera Toggle)
          Key::Named(NamedKey::Tab) =>
          {
            if let Some(renderer) = &mut self.renderer
            {
              use crate::render::shared::CameraMode;
              renderer.shared.mode = match renderer.shared.mode
              {
                CameraMode::Free => CameraMode::Orbital,
                CameraMode::Orbital => CameraMode::Free,
              };
              self.logger.emit(LogLevel::Info, &format!("Camera Mode: {:?}", renderer.shared.mode));
            }
          }

          _ => (),
        }
      }

      WindowEvent::Resized(physical_size) =>
      {
        if let Some(renderer) = &mut self.renderer
        {
          renderer.resize(Some(physical_size));
        }
      }

      WindowEvent::RedrawRequested =>
      {
        self.time.update();
        let dt = self.time.delta_f32;

        if let Some(renderer) = &mut self.renderer
        {
          if let Err(e) = renderer.update(&mut self.input, dt)
          {
            eprintln!("Update error: {:?}", e);
          }

          if let Err(e) = renderer.render()
          {
            let err_str = format!("{:?}", e);
            if !err_str.contains("reconfigured")
            {
              eprintln!("Render error: {}", err_str);
            }
          }
        }

        self.input.tick();

        if let Some(window) = &self.window
        {
          window.request_redraw();
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
  }
}
