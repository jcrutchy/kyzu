use std::sync::Arc;

use winit::window::Window;

use crate::input::InputState;
use crate::renderer::depth::DepthResources;
use crate::renderer::gui::GuiRenderer;
use crate::renderer::module::RenderModule;
use crate::renderer::modules::camera::CameraModule;
use crate::renderer::shared::{CameraGpu, CameraMatrices, FrameTargets, SharedState};

//
// ──────────────────────────────────────────────────────────────
//   Kernel
// ──────────────────────────────────────────────────────────────
//

pub struct Kernel
{
  pub device: wgpu::Device,
  pub queue: wgpu::Queue,
  pub adapter_info: wgpu::AdapterInfo,
  depth: DepthResources,
  pub shared: SharedState,
  pub modules: Vec<Box<dyn RenderModule>>,
  pub gui: GuiRenderer,
  pub camera: CameraModule,
  pub config: wgpu::SurfaceConfiguration,
  // surface last — drops first, before device and window
  pub surface: wgpu::Surface<'static>,
}

//
// ──────────────────────────────────────────────────────────────
//   Public API
// ──────────────────────────────────────────────────────────────
//

impl Kernel
{
  pub async fn new(window: Arc<Window>) -> Self
  {
    let instance = wgpu::Instance::default();
    let surface = instance.create_surface(window.clone()).expect("Failed to create wgpu surface");

    let adapter = instance
      .request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        compatible_surface: Some(&surface),
        force_fallback_adapter: false,
      })
      .await
      .expect("No suitable GPU adapter found");

    let adapter_info = adapter.get_info();
    println!("--------------------------------------------------");
    println!("ACTIVE GPU: {}", adapter_info.name);
    println!("BACKEND:    {:?}", adapter_info.backend);
    println!("TYPE:       {:?}", adapter_info.device_type);
    println!("--------------------------------------------------");

    let (device, queue) = adapter
      .request_device(&wgpu::DeviceDescriptor {
        label: Some("Kyzu Device"),
        required_features: wgpu::Features::empty(),
        required_limits: wgpu::Limits::default(),
        memory_hints: wgpu::MemoryHints::Performance,
        ..Default::default()
      })
      .await
      .expect("Failed to create device");

    let config = configure_surface(&surface, &adapter, &device);
    let aspect = config.width as f32 / config.height as f32;
    let camera = CameraModule::new(aspect);
    let depth = DepthResources::create(&device, &config);
    let gui = GuiRenderer::new(&device, config.format, &window);

    let camera_gpu = CameraGpu::create(&device);

    let shared = SharedState {
      camera: CameraMatrices::default(),
      camera_gpu,
      surface_format: config.format,
      depth_format: wgpu::TextureFormat::Depth32Float,
      screen_width: config.width,
      screen_height: config.height,
    };

    Self {
      device,
      queue,
      surface,
      config,
      adapter_info,
      depth,
      shared,
      modules: Vec::new(),
      gui,
      camera,
    }
  }

  /// Register a render module. Modules are called in registration order.
  pub fn add_module<M: RenderModule + 'static>(&mut self)
  {
    let module = M::init(&self.device, &self.queue, &self.shared);
    self.modules.push(Box::new(module));
  }

  pub fn update_camera(&mut self, input: &InputState)
  {
    self.camera.update(input, &mut self.shared);
    self.shared.camera_gpu.upload(&self.queue, &self.shared.camera);
  }

  pub fn resize(&mut self, width: u32, height: u32)
  {
    if width == 0 || height == 0
    {
      return;
    }

    self.config.width = width;
    self.config.height = height;

    self.surface.configure(&self.device, &self.config);
    self.depth = DepthResources::create(&self.device, &self.config);

    self.shared.screen_width = width;
    self.shared.screen_height = height;

    self.camera.set_aspect(width as f32 / height as f32);
    let matrices = self.camera.compute_matrices();
    self.shared.camera_gpu.upload(&self.queue, &matrices);
    self.shared.camera = matrices;
  }

  pub fn render(&mut self, window: &Window, egui_output: egui::FullOutput)
  {
    let frame = match self.surface.get_current_texture()
    {
      Ok(f) => f,
      Err(_) =>
      {
        self.surface.configure(&self.device, &self.config);
        self.surface.get_current_texture().expect("Failed after reconfigure")
      }
    };

    let color_view = frame.texture.create_view(&wgpu::TextureViewDescriptor::default());

    let mut encoder = self
      .device
      .create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("Frame Encoder") });

    let targets = FrameTargets { color: &color_view, depth: &self.depth.view };

    // Clear pass — must run before any module encodes
    {
      let _pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("Clear Pass"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
          view: &color_view,
          resolve_target: None,
          ops: wgpu::Operations {
            load: wgpu::LoadOp::Clear(wgpu::Color { r: 0.02, g: 0.02, b: 0.03, a: 1.0 }),
            store: wgpu::StoreOp::Store,
          },
          depth_slice: None,
        })],
        depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
          view: &self.depth.view,
          depth_ops: Some(wgpu::Operations {
            load: wgpu::LoadOp::Clear(1.0),
            store: wgpu::StoreOp::Store,
          }),
          stencil_ops: None,
        }),
        occlusion_query_set: None,
        timestamp_writes: None,
      });

      // pass drops here, ending the clear pass before modules begin
    }

    // Update then encode each module in order
    for module in &mut self.modules
    {
      module.update(&self.queue, &self.shared);
    }

    for module in &self.modules
    {
      module.encode(&mut encoder, &targets, &self.shared);
    }

    // GUI always last — composited over all 3D content
    self.gui.render(&self.device, &self.queue, &mut encoder, window, &color_view, egui_output);

    self.queue.submit(Some(encoder.finish()));
    frame.present();
  }
}

//
// ──────────────────────────────────────────────────────────────
//   Surface configuration helper
// ──────────────────────────────────────────────────────────────
//

fn configure_surface(
  surface: &wgpu::Surface<'_>,
  adapter: &wgpu::Adapter,
  device: &wgpu::Device,
) -> wgpu::SurfaceConfiguration
{
  let caps = surface.get_capabilities(adapter);

  let format = caps
    .formats
    .iter()
    .copied()
    .find(|f| *f == wgpu::TextureFormat::Bgra8Unorm || *f == wgpu::TextureFormat::Rgba8Unorm)
    .unwrap_or(caps.formats[0]);

  let config = wgpu::SurfaceConfiguration {
    usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
    format,
    width: 800,
    height: 600,
    present_mode: wgpu::PresentMode::Fifo,
    alpha_mode: wgpu::CompositeAlphaMode::Auto,
    view_formats: vec![],
    desired_maximum_frame_latency: 2,
  };

  surface.configure(device, &config);
  config
}
