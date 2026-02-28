use std::sync::Arc;

use winit::window::Window;

use super::axes::{create_axes_pipeline, AxesMesh};
use super::cube::CubeMesh;
use super::debug::DebugMesh;
use super::depth::DepthResources;
use super::grid::{create_grid_pipeline, GridMesh};
use crate::camera::{Camera, CameraUniform};
use crate::renderer::gui::GuiRenderer;

//
// ──────────────────────────────────────────────────────────────
//   Renderer
// ──────────────────────────────────────────────────────────────
//

pub struct Renderer
{
  pub gui: GuiRenderer,
  pub adapter_info: wgpu::AdapterInfo,
  pub grid_lod_scale: f32,
  pub grid_lod_fade: f32,

  surface: wgpu::Surface<'static>,
  device: wgpu::Device,
  queue: wgpu::Queue,
  config: wgpu::SurfaceConfiguration,

  depth: DepthResources,
  camera_buffer: wgpu::Buffer,
  camera_bind_group: wgpu::BindGroup,

  // Stored so future pipelines that share the camera uniform can be created
  // without needing a full Renderer rebuild. Not currently read after init.
  #[allow(dead_code)]
  camera_bgl: wgpu::BindGroupLayout,

  pipeline: wgpu::RenderPipeline,
  cube: CubeMesh,

  grid: GridMesh,
  grid_pipeline: wgpu::RenderPipeline,

  axes: AxesMesh,
  axes_pipeline: wgpu::RenderPipeline,

  debug: DebugMesh,
}

//
// ──────────────────────────────────────────────────────────────
//   Public API
// ──────────────────────────────────────────────────────────────
//

impl Renderer
{
  pub async fn new(window: Arc<Window>, camera: &Camera) -> Self
  {
    let instance = wgpu::Instance::default();
    let surface = instance.create_surface(&window).expect("Failed to create wgpu surface");

    let adapter = request_adapter(&instance, &surface).await;

    let adapter_info = adapter.get_info();
    println!("--------------------------------------------------");
    println!("ACTIVE GPU: {}", adapter_info.name);
    println!("BACKEND:    {:?}", adapter_info.backend);
    println!("TYPE:       {:?}", adapter_info.device_type);
    println!("--------------------------------------------------");

    let (device, queue) = request_device(&adapter).await;

    let config = configure_surface(&surface, &adapter, &device);
    let depth = DepthResources::create(&device, &config);

    let gui = GuiRenderer::new(&device, config.format, &window);

    let (camera_buffer, camera_bind_group, camera_bgl) = create_camera_resources(&device);

    let uniform = CameraUniform::from_camera(camera);
    queue.write_buffer(&camera_buffer, 0, bytemuck::bytes_of(&uniform));

    let pipeline = create_cube_pipeline(&device, &config, &camera_bgl);
    let cube = CubeMesh::create(&device);

    let grid = GridMesh::create(&device);
    let grid_pipeline = create_grid_pipeline(&device, &config, &grid.bind_group_layout);
    grid.update(&queue, camera);

    let axes = AxesMesh::create(&device);
    let axes_pipeline = create_axes_pipeline(&device, &config, &camera_bgl);

    let mut debug = DebugMesh::create(&device);
    debug.update(&queue, camera);

    Self {
      gui,
      adapter_info,
      grid_lod_scale: 1.0,
      grid_lod_fade: 1.0,
      surface,
      device,
      queue,
      config,
      depth,
      camera_buffer,
      camera_bind_group,
      camera_bgl,
      pipeline,
      cube,
      grid,
      grid_pipeline,
      axes,
      axes_pipeline,
      debug,
    }
  }

  pub fn update_camera(&mut self, camera: &Camera)
  {
    let uniform = CameraUniform::from_camera(camera);
    self.queue.write_buffer(&self.camera_buffer, 0, bytemuck::bytes_of(&uniform));
    self.grid.update(&self.queue, camera);
    self.debug.update(&self.queue, camera);
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
  }

  // 1. Change the signature to accept 'full_output' from app.rs
  pub fn render(&mut self, window: &winit::window::Window, full_output: egui::FullOutput)
  {
    let frame = match self.surface.get_current_texture()
    {
      Ok(frame) => frame,
      Err(_) =>
      {
        self.surface.configure(&self.device, &self.config);
        self.surface.get_current_texture().expect("Failed after reconfigure")
      }
    };

    let view = frame.texture.create_view(&wgpu::TextureViewDescriptor::default());

    let mut encoder = self
      .device
      .create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("Render Encoder") });

    // Step A: Record your 3D scene (Grid, Cube, Axes)
    record_render_pass(
      &mut encoder,
      &view,
      &self.depth.view,
      &self.pipeline,
      &self.camera_bind_group,
      &self.cube,
      &self.grid_pipeline,
      &self.grid,
      &self.axes_pipeline,
      &self.axes,
      &self.debug,
    );

    // Step B: Record the GUI on top of the 3D scene
    // We call the 'render' method in your new gui.rs (which we'll define next)
    self.gui.render(&self.device, &self.queue, &mut encoder, window, &view, full_output);

    self.queue.submit(Some(encoder.finish()));
    frame.present();
  }
}

//
// ──────────────────────────────────────────────────────────────
//   Initialisation helpers
// ──────────────────────────────────────────────────────────────
//

async fn request_adapter(instance: &wgpu::Instance, surface: &wgpu::Surface<'_>) -> wgpu::Adapter
{
  instance
    .request_adapter(&wgpu::RequestAdapterOptions {
      power_preference: wgpu::PowerPreference::HighPerformance,
      compatible_surface: Some(surface),
      force_fallback_adapter: false,
    })
    .await
    .expect("No suitable GPU adapter found")
}

async fn request_device(adapter: &wgpu::Adapter) -> (wgpu::Device, wgpu::Queue)
{
  adapter
    .request_device(&wgpu::DeviceDescriptor {
      label: Some("Kyzu Device"),
      required_features: wgpu::Features::empty(),
      required_limits: wgpu::Limits::default(),
      memory_hints: wgpu::MemoryHints::Performance,
      ..Default::default()
    })
    .await
    .expect("Failed to create device")
}

fn configure_surface(
  surface: &wgpu::Surface<'_>,
  adapter: &wgpu::Adapter,
  device: &wgpu::Device,
) -> wgpu::SurfaceConfiguration
{
  let caps = surface.get_capabilities(adapter);
  let format = caps.formats[0];

  // Start at a sensible size — on_resize will correct this to the real window size
  // before any frame is rendered. Starting at 1×1 risks a validation error if a
  // frame is somehow submitted before the first resize event.
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

fn create_camera_resources(
  device: &wgpu::Device,
) -> (wgpu::Buffer, wgpu::BindGroup, wgpu::BindGroupLayout)
{
  let camera_buffer = device.create_buffer(&wgpu::BufferDescriptor {
    label: Some("Camera Buffer"),
    size: std::mem::size_of::<CameraUniform>() as u64,
    usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
    mapped_at_creation: false,
  });

  let camera_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
    label: Some("Camera BGL"),
    entries: &[wgpu::BindGroupLayoutEntry {
      binding: 0,
      visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
      ty: wgpu::BindingType::Buffer {
        ty: wgpu::BufferBindingType::Uniform,
        has_dynamic_offset: false,
        min_binding_size: None,
      },
      count: None,
    }],
  });

  let camera_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
    label: Some("Camera BG"),
    layout: &camera_bgl,
    entries: &[wgpu::BindGroupEntry { binding: 0, resource: camera_buffer.as_entire_binding() }],
  });

  (camera_buffer, camera_bind_group, camera_bgl)
}

fn create_cube_pipeline(
  device: &wgpu::Device,
  config: &wgpu::SurfaceConfiguration,
  camera_bgl: &wgpu::BindGroupLayout,
) -> wgpu::RenderPipeline
{
  let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
    label: Some("Cube Shader"),
    source: wgpu::ShaderSource::Wgsl(include_str!("../shaders/cube.wgsl").into()),
  });

  let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
    label: Some("Cube Pipeline Layout"),
    bind_group_layouts: &[camera_bgl],
    push_constant_ranges: &[],
  });

  device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
    label: Some("Cube Pipeline"),
    layout: Some(&layout),
    vertex: wgpu::VertexState {
      module: &shader,
      entry_point: Some("vs_main"),
      buffers: &[wgpu::VertexBufferLayout {
        array_stride: std::mem::size_of::<[f32; 3]>() as u64,
        step_mode: wgpu::VertexStepMode::Vertex,
        attributes: &wgpu::vertex_attr_array![0 => Float32x3],
      }],
      compilation_options: wgpu::PipelineCompilationOptions::default(),
    },
    fragment: Some(wgpu::FragmentState {
      module: &shader,
      entry_point: Some("fs_main"),
      targets: &[Some(wgpu::ColorTargetState {
        format: config.format,
        blend: Some(wgpu::BlendState::REPLACE),
        write_mask: wgpu::ColorWrites::ALL,
      })],
      compilation_options: wgpu::PipelineCompilationOptions::default(),
    }),
    primitive: wgpu::PrimitiveState::default(),
    depth_stencil: Some(wgpu::DepthStencilState {
      format: wgpu::TextureFormat::Depth32Float,
      depth_write_enabled: true,
      depth_compare: wgpu::CompareFunction::Less,
      stencil: wgpu::StencilState::default(),
      bias: wgpu::DepthBiasState::default(),
    }),
    multisample: wgpu::MultisampleState::default(),
    multiview: None,
    cache: None,
  })
}

//
// ──────────────────────────────────────────────────────────────
//   Render pass — draw order matters:
//     1. Opaque geometry  (cube)      — writes depth
//     2. Opaque lines     (axes, debug) — depth tested, writes depth
//     3. Transparent      (grid)      — depth tested, no depth write
// ──────────────────────────────────────────────────────────────
//

fn record_render_pass(
  encoder: &mut wgpu::CommandEncoder,
  color_view: &wgpu::TextureView,
  depth_view: &wgpu::TextureView,
  pipeline: &wgpu::RenderPipeline,
  camera_bg: &wgpu::BindGroup,
  cube: &CubeMesh,
  grid_pipeline: &wgpu::RenderPipeline,
  grid: &GridMesh,
  axes_pipeline: &wgpu::RenderPipeline,
  axes: &AxesMesh,
  debug: &DebugMesh,
)
{
  let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
    label: Some("Render Pass"),
    color_attachments: &[Some(wgpu::RenderPassColorAttachment {
      view: color_view,
      resolve_target: None,
      ops: wgpu::Operations {
        load: wgpu::LoadOp::Clear(wgpu::Color { r: 0.02, g: 0.02, b: 0.03, a: 1.0 }),
        store: wgpu::StoreOp::Store,
      },
      depth_slice: None,
    })],
    depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
      view: depth_view,
      depth_ops: Some(wgpu::Operations {
        load: wgpu::LoadOp::Clear(1.0),
        store: wgpu::StoreOp::Store,
      }),
      stencil_ops: None,
    }),
    occlusion_query_set: None,
    timestamp_writes: None,
  });

  // 1. Opaque geometry
  pass.set_pipeline(pipeline);
  pass.set_bind_group(0, camera_bg, &[]);
  pass.set_vertex_buffer(0, cube.vertex_buffer.slice(..));
  pass.set_index_buffer(cube.index_buffer.slice(..), wgpu::IndexFormat::Uint16);
  pass.draw_indexed(0..cube.index_count, 0, 0..1);

  // 2. Opaque lines — axes and debug share the same pipeline and vertex layout
  pass.set_pipeline(axes_pipeline);
  pass.set_bind_group(0, camera_bg, &[]);
  pass.set_vertex_buffer(0, axes.vertex_buffer.slice(..));
  pass.draw(0..axes.vertex_count, 0..1);

  if debug.vertex_count > 0
  {
    pass.set_vertex_buffer(0, debug.vertex_buffer.slice(..));
    pass.draw(0..debug.vertex_count, 0..1);
  }

  // 3. Transparent grid — drawn last so it blends over everything
  pass.set_pipeline(grid_pipeline);
  pass.set_bind_group(0, &grid.bind_group, &[]);
  pass.draw(0..3, 0..1);
}
