use std::sync::Arc;

use wgpu::*;
use winit::window::Window;

use crate::input::InputState;
use crate::renderer::depth::DepthResources;
use crate::renderer::gui::GuiRenderer;
use crate::renderer::module::RenderModule;
use crate::renderer::modules::camera::SolarSystemCamera;
use crate::renderer::shared::{
  CameraGpu, CameraMatrices, FrameTargets, SharedState, TextureLayout,
};

pub struct Kernel
{
  pub device: Arc<Device>,
  pub queue: Queue,
  pub config: SurfaceConfiguration,
  pub _adapter_info: AdapterInfo,
  pub depth: DepthResources,
  pub shared: SharedState,
  pub modules: Vec<Box<dyn RenderModule>>,
  pub gui: GuiRenderer,
  pub camera: SolarSystemCamera,
  pub tex_layout: TextureLayout,
  pub surface: Surface<'static>,
}

impl Kernel
{
  pub async fn new(window: Arc<Window>) -> Self
  {
    let instance =
      Instance::new(&InstanceDescriptor { backends: Backends::VULKAN, ..Default::default() });

    let surface = instance.create_surface(window.clone()).expect("Failed to create surface");

    let adapter = instance
      .request_adapter(&RequestAdapterOptions {
        power_preference: PowerPreference::HighPerformance,
        compatible_surface: Some(&surface),
        force_fallback_adapter: false,
      })
      .await
      .expect("No adapter found");

    let adapter_info = adapter.get_info();
    println!("--------------------------------------------------");
    println!("ACTIVE GPU: {}", adapter_info.name);
    println!("BACKEND:    {:?}", adapter_info.backend);
    println!("TYPE:       {:?}", adapter_info.device_type);
    println!("--------------------------------------------------");

    let (device, queue) = adapter
      .request_device(&DeviceDescriptor {
        label: Some("Solar Device"),
        required_features: Features::POLYGON_MODE_LINE,
        required_limits: Limits::default(),
        memory_hints: MemoryHints::Performance,
        ..Default::default()
      })
      .await
      .expect("Failed to create device");
    let device = Arc::new(device);

    let config = configure_surface(&surface, &adapter, &device);
    let aspect = config.width as f32 / config.height as f32;

    let depth = DepthResources::create(&device, &config);
    let gui = GuiRenderer::new(&device, config.format, &window);
    let camera_gpu = CameraGpu::create(&device);
    let tex_layout = TextureLayout::create(&device);
    let camera = SolarSystemCamera::new(aspect);

    let shared = SharedState {
      camera: CameraMatrices::default(),
      camera_gpu,
      surface_format: config.format,
      depth_format: TextureFormat::Depth32Float,
      screen_width: config.width,
      screen_height: config.height,
    };

    Self {
      device,
      queue,
      surface,
      config,
      _adapter_info: adapter_info,
      depth,
      shared,
      modules: Vec::new(),
      gui,
      camera,
      tex_layout,
    }
  }

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

    let view = frame.texture.create_view(&TextureViewDescriptor::default());
    let depth_view = &self.depth.view;

    let targets = FrameTargets { surface_view: &view, depth_view };

    let mut encoder = self
      .device
      .create_command_encoder(&CommandEncoderDescriptor { label: Some("Frame Encoder") });

    // Clear pass
    {
      let _ = encoder.begin_render_pass(&RenderPassDescriptor {
        label: Some("Clear Pass"),
        color_attachments: &[Some(RenderPassColorAttachment {
          view: &view,
          resolve_target: None,
          ops: Operations {
            load: LoadOp::Clear(Color { r: 0.0, g: 0.0, b: 0.02, a: 1.0 }),
            store: StoreOp::Store,
          },
          depth_slice: None,
        })],
        depth_stencil_attachment: Some(RenderPassDepthStencilAttachment {
          view: depth_view,
          depth_ops: Some(Operations { load: LoadOp::Clear(1.0), store: StoreOp::Store }),
          stencil_ops: None,
        }),
        ..Default::default()
      });
    }

    // Module passes
    for module in &mut self.modules
    {
      module.update(&self.queue, &self.shared);
      module.encode(&mut encoder, &targets, &self.shared);
    }

    // GUI pass
    self.gui.render(&self.device, &self.queue, &mut encoder, window, &view, egui_output);

    self.queue.submit(std::iter::once(encoder.finish()));
    frame.present();
  }
}

fn configure_surface(surface: &Surface, adapter: &Adapter, device: &Device)
  -> SurfaceConfiguration
{
  let caps = surface.get_capabilities(adapter);
  let format = caps.formats.iter().find(|f| f.is_srgb()).copied().unwrap_or(caps.formats[0]);

  let config = SurfaceConfiguration {
    usage: TextureUsages::RENDER_ATTACHMENT,
    format,
    width: 800,
    height: 600,
    present_mode: PresentMode::Fifo,
    alpha_mode: caps.alpha_modes[0],
    view_formats: vec![],
    desired_maximum_frame_latency: 2,
  };

  surface.configure(device, &config);
  config
}
