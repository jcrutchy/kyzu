use std::sync::Arc;

use winit::window::Window;

use crate::render::camera::CameraSystem;
use crate::render::module::{FrameTargets, RenderModule};
use crate::render::shared::SharedState;

pub struct Renderer
{
  pub instance: wgpu::Instance,
  pub adapter: wgpu::Adapter,
  pub device: wgpu::Device,
  pub queue: wgpu::Queue,
  pub config: wgpu::SurfaceConfiguration,
  pub shared: SharedState,
  pub modules: Vec<Box<dyn RenderModule>>,
  pub camera_system: CameraSystem,
  pub surface: wgpu::Surface<'static>,
}

impl Renderer
{
  pub async fn new(window: Arc<Window>) -> anyhow::Result<Self>
  {
    let size = window.inner_size();
    let instance = wgpu::Instance::default();
    let surface = instance.create_surface(window.clone())?;

    let adapter = instance
      .request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        compatible_surface: Some(&surface),
        force_fallback_adapter: false,
      })
      .await
      .map_err(|e| anyhow::anyhow!("No suitable GPU adapter found: {:?}", e))?;

    let (device, queue) = adapter
      .request_device(&wgpu::DeviceDescriptor {
        label: Some("Kyzu Device"),
        required_features: wgpu::Features::empty(),
        required_limits: wgpu::Limits::default(),
        experimental_features: Default::default(),
        trace: wgpu::Trace::default(),
        memory_hints: wgpu::MemoryHints::Performance,
      })
      .await?;

    let swapchain_capabilities = surface.get_capabilities(&adapter);
    let swapchain_format = swapchain_capabilities.formats[0];

    let config = wgpu::SurfaceConfiguration {
      usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
      format: swapchain_format,
      width: size.width,
      height: size.height,
      present_mode: wgpu::PresentMode::Fifo,
      alpha_mode: swapchain_capabilities.alpha_modes[0],
      view_formats: vec![],
      desired_maximum_frame_latency: 2,
    };

    surface.configure(&device, &config);

    let shared = SharedState::new(&device, config.width, config.height);

    let camera_system = crate::render::camera::CameraSystem::new();

    Ok(Self {
      instance,
      surface,
      adapter,
      device,
      queue,
      config,
      shared,
      modules: Vec::new(),
      camera_system,
    })
  }

  pub fn update(&mut self, input: &crate::input::state::InputState, dt: f32) -> anyhow::Result<()>
  {
    self.camera_system.update(&mut self.shared, input, dt);
    self.shared.camera_gpu.upload(&self.queue, &self.shared.camera);

    for module in &mut self.modules
    {
      module.update(&self.queue, &self.shared);
    }

    Ok(())
  }

  pub fn add_module(&mut self, module: impl RenderModule + 'static)
  {
    self.modules.push(Box::new(module));
  }

  pub fn resize(&mut self, new_size: Option<winit::dpi::PhysicalSize<u32>>)
  {
    if let Some(size) = new_size
    {
      if size.width > 0 && size.height > 0
      {
        self.config.width = size.width;
        self.config.height = size.height;
        self.surface.configure(&self.device, &self.config);
        // Update shared depth texture etc here
      }
    }
  }

  pub fn render(&mut self) -> anyhow::Result<()>
  {
    let frame = match self.surface.get_current_texture()
    {
      Ok(frame) => frame,
      Err(wgpu::SurfaceError::Outdated) | Err(wgpu::SurfaceError::Lost) =>
      {
        self.resize(None);
        return Ok(());
      }
      Err(wgpu::SurfaceError::Timeout) => return Err(anyhow::anyhow!("Surface timeout")),
      Err(e) => return Err(anyhow::anyhow!("Surface error: {:?}", e)),
    };

    let view = frame.texture.create_view(&wgpu::TextureViewDescriptor::default());
    let mut encoder = self
      .device
      .create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("Render Encoder") });

    let targets = FrameTargets { surface_view: &view, depth_view: &self.shared.depth_view };

    for module in &self.modules
    {
      module.encode(&mut encoder, &targets, &self.shared);
    }

    self.queue.submit(std::iter::once(encoder.finish()));
    frame.present();

    Ok(())
  }
}
