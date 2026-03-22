use std::sync::Arc;

use winit::dpi::PhysicalSize;
use winit::window::Window;

pub struct Renderer
{
  pub device: wgpu::Device,
  pub queue: wgpu::Queue,
  pub config: wgpu::SurfaceConfiguration,
  pub size: PhysicalSize<u32>,
  pub window: Arc<Window>, // Renderer now keeps its own reference to the window
  pub surface: wgpu::Surface<'static>,
}

impl Renderer
{
  pub async fn new(window: Arc<Window>) -> Result<Self, crate::core::error::KyzuError>
  {
    let size = window.inner_size();
    let instance = wgpu::Instance::default();

    let surface = instance
      .create_surface(window.clone())
      .map_err(|e| crate::core::error::KyzuError::Gpu(e.to_string()))?;

    // FIX: Using map_err because request_adapter is returning a Result
    let adapter = instance
      .request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        compatible_surface: Some(&surface),
        force_fallback_adapter: false,
      })
      .await
      .map_err(|_| crate::core::error::KyzuError::Gpu("No suitable GPU found".into()))?;

    let (device, queue) = adapter
      .request_device(&wgpu::DeviceDescriptor {
        label: Some("Kyzu Primary Device"),
        required_features: wgpu::Features::empty(),
        required_limits: wgpu::Limits::default(),
        memory_hints: wgpu::MemoryHints::default(),
        experimental_features: wgpu::ExperimentalFeatures::default(),
        trace: wgpu::Trace::default(),
      })
      .await
      .map_err(|e| crate::core::error::KyzuError::Gpu(e.to_string()))?;

    let caps = surface.get_capabilities(&adapter);
    let format = caps.formats[0];

    let config = wgpu::SurfaceConfiguration {
      usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
      format,
      width: size.width,
      height: size.height,
      present_mode: wgpu::PresentMode::Fifo,
      alpha_mode: caps.alpha_modes[0],
      view_formats: vec![],
      desired_maximum_frame_latency: 2,
    };

    surface.configure(&device, &config);

    Ok(Self { device, queue, config, size, surface, window })
  }

  /// Resizes the surface. If new_size is None, it queries the window for its current size.
  pub fn resize(&mut self, new_size: Option<PhysicalSize<u32>>)
  {
    let size = new_size.unwrap_or(self.window.inner_size());

    if size.width > 0 && size.height > 0
    {
      self.size = size;
      self.config.width = size.width;
      self.config.height = size.height;
      self.surface.configure(&self.device, &self.config);
    }
  }

  pub fn render(&mut self) -> Result<(), String>
  {
    let surface_texture = self.surface.get_current_texture();

    let output = match surface_texture
    {
      wgpu::CurrentSurfaceTexture::Success(frame) => frame,
      _ => return Err("Surface texture acquisition failed or outdated".into()),
    };

    let view = output.texture.create_view(&wgpu::TextureViewDescriptor::default());
    let mut encoder = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
      label: Some("Primary Render Encoder"),
    });

    {
      let _render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("Main Clear Pass"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
          view: &view,
          resolve_target: None,
          ops: wgpu::Operations {
            load: wgpu::LoadOp::Clear(wgpu::Color { r: 0.01, g: 0.02, b: 0.05, a: 1.0 }),
            store: wgpu::StoreOp::Store,
          },
          depth_slice: None,
        })],
        depth_stencil_attachment: None,
        timestamp_writes: None,
        occlusion_query_set: None,
        multiview_mask: None,
      });
    }

    self.queue.submit(std::iter::once(encoder.finish()));
    output.present();

    Ok(())
  }
}
