use std::sync::Arc;

use glam::DVec3;
use wgpu::util::DeviceExt;

use crate::renderer::module::RenderModule;
use crate::renderer::shared::{FrameTargets, SharedState, TextureLayout};

// ──────────────────────────────────────────────────────────────
//   Public CPU-side instance descriptor
// ──────────────────────────────────────────────────────────────

pub struct SphereInstance
{
  pub center: DVec3,  // world-space centre, metres
  pub radius: f64,    // metres
  pub texture: usize, // index into SphereModule::textures
}

// ──────────────────────────────────────────────────────────────
//   GPU instance layout
// ──────────────────────────────────────────────────────────────

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct GpuInstance
{
  center_rel: [f32; 3],
  radius: f32,
  tex_index: u32,
  _pad: [f32; 3],
}

// ──────────────────────────────────────────────────────────────
//   Vertex layout: [x, y, z,  nx, ny, nz,  u, v]
// ──────────────────────────────────────────────────────────────

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Vertex
{
  pos: [f32; 3],
  normal: [f32; 3],
  uv: [f32; 2],
}

// ──────────────────────────────────────────────────────────────
//   Loaded texture — one bind group per texture
// ──────────────────────────────────────────────────────────────

pub struct SphereTexture
{
  pub bind_group: wgpu::BindGroup,
}

impl SphereTexture
{
  pub fn from_bytes(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    tex_layout: &TextureLayout,
    bytes: &[u8],
    label: &str,
  ) -> anyhow::Result<Self>
  {
    let img = image::load_from_memory(bytes)?.to_rgba8();
    let (w, h) = img.dimensions();

    let texture = device.create_texture_with_data(
      queue,
      &wgpu::TextureDescriptor {
        label: Some(label),
        size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8UnormSrgb,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
      },
      wgpu::util::TextureDataOrder::LayerMajor,
      &img,
    );

    let view = texture.create_view(&wgpu::TextureViewDescriptor::default());

    let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
      label: Some("Sphere Sampler"),
      address_mode_u: wgpu::AddressMode::ClampToEdge,
      address_mode_v: wgpu::AddressMode::ClampToEdge,
      address_mode_w: wgpu::AddressMode::ClampToEdge,
      mag_filter: wgpu::FilterMode::Linear,
      min_filter: wgpu::FilterMode::Linear,
      mipmap_filter: wgpu::FilterMode::Linear,
      ..Default::default()
    });

    let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
      label: Some("Sphere Texture BG"),
      layout: &tex_layout.layout,
      entries: &[
        wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&view) },
        wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::Sampler(&sampler) },
      ],
    });

    Ok(Self { bind_group })
  }
}

// ──────────────────────────────────────────────────────────────
//   Module
// ──────────────────────────────────────────────────────────────

const MAX_INSTANCES: u32 = 64;
const SPHERE_SLICES: u32 = 64;
const SPHERE_STACKS: u32 = 32;

pub struct SphereModule
{
  vertex_buffer: wgpu::Buffer,
  index_buffer: wgpu::Buffer,
  index_count: u32,
  instance_buffer: wgpu::Buffer,
  instance_count: u32,
  pipeline: wgpu::RenderPipeline,

  pub instances: Vec<SphereInstance>,
  pub textures: Vec<SphereTexture>,
}

impl RenderModule for SphereModule
{
  fn init(device: &Arc<wgpu::Device>, _queue: &wgpu::Queue, shared: &SharedState) -> Self
  {
    let (vertices, indices) = build_uv_sphere(SPHERE_SLICES, SPHERE_STACKS);

    let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
      label: Some("Sphere VB"),
      contents: bytemuck::cast_slice(&vertices),
      usage: wgpu::BufferUsages::VERTEX,
    });

    let index_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
      label: Some("Sphere IB"),
      contents: bytemuck::cast_slice(&indices),
      usage: wgpu::BufferUsages::INDEX,
    });

    let instance_buffer = device.create_buffer(&wgpu::BufferDescriptor {
      label: Some("Sphere Instance Buffer"),
      size: MAX_INSTANCES as u64 * std::mem::size_of::<GpuInstance>() as u64,
      usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
      mapped_at_creation: false,
    });

    // Placeholder texture layout for pipeline creation
    let tex_layout = TextureLayout::create(device);
    let pipeline = create_pipeline(device, shared, &tex_layout);

    Self {
      vertex_buffer,
      index_buffer,
      index_count: indices.len() as u32,
      instance_buffer,
      instance_count: 0,
      pipeline,
      instances: Vec::new(),
      textures: Vec::new(),
    }
  }

  fn update(&mut self, queue: &wgpu::Queue, shared: &SharedState)
  {
    let eye = glam::DVec3::new(
      shared.camera.eye_world[0] as f64,
      shared.camera.eye_world[1] as f64,
      shared.camera.eye_world[2] as f64,
    );

    let count = self.instances.len().min(MAX_INSTANCES as usize);
    let gpu: Vec<GpuInstance> = self.instances[..count]
      .iter()
      .map(|s| {
        let rel = (s.center - eye).as_vec3();
        GpuInstance {
          center_rel: rel.into(),
          radius: s.radius as f32,
          tex_index: s.texture as u32,
          _pad: [0.0; 3],
        }
      })
      .collect();

    queue.write_buffer(&self.instance_buffer, 0, bytemuck::cast_slice(&gpu));
    self.instance_count = count as u32;
  }

  fn encode(&self, encoder: &mut wgpu::CommandEncoder, targets: &FrameTargets, shared: &SharedState)
  {
    if self.instance_count == 0 || self.textures.is_empty()
    {
      return;
    }

    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
      label: Some("Sphere Pass"),
      color_attachments: &[Some(wgpu::RenderPassColorAttachment {
        view: targets.surface_view,
        resolve_target: None,
        ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
        depth_slice: None,
      })],
      depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
        view: targets.depth_view,
        depth_ops: Some(wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store }),
        stencil_ops: None,
      }),
      occlusion_query_set: None,
      timestamp_writes: None,
    });

    pass.set_pipeline(&self.pipeline);
    pass.set_vertex_buffer(0, self.vertex_buffer.slice(..));
    pass.set_vertex_buffer(1, self.instance_buffer.slice(..));
    pass.set_index_buffer(self.index_buffer.slice(..), wgpu::IndexFormat::Uint32);

    // Draw each instance with its own texture bind group
    for (i, instance) in self.instances[..self.instance_count as usize].iter().enumerate()
    {
      let tex_idx = instance.texture.min(self.textures.len() - 1);
      pass.set_bind_group(0, &shared.camera_gpu.bind_group, &[]);
      pass.set_bind_group(1, &self.textures[tex_idx].bind_group, &[]);
      pass.draw_indexed(0..self.index_count, 0, i as u32..i as u32 + 1);
    }
  }

  fn as_any_mut(&mut self) -> &mut dyn std::any::Any
  {
    self
  }
}

// ──────────────────────────────────────────────────────────────
//   UV sphere geometry — includes UV coordinates
// ──────────────────────────────────────────────────────────────

fn build_uv_sphere(slices: u32, stacks: u32) -> (Vec<Vertex>, Vec<u32>)
{
  let mut vertices = Vec::new();
  let mut indices = Vec::new();

  for stack in 0..=stacks
  {
    let phi = std::f32::consts::PI * stack as f32 / stacks as f32;
    let sin_phi = phi.sin();
    let cos_phi = phi.cos();
    let v = stack as f32 / stacks as f32;

    for slice in 0..=slices
    {
      let theta = 2.0 * std::f32::consts::PI * slice as f32 / slices as f32;
      let sin_theta = theta.sin();
      let cos_theta = theta.cos();

      let x = sin_phi * cos_theta;
      let y = sin_phi * sin_theta;
      let z = cos_phi;
      let u = slice as f32 / slices as f32;

      vertices.push(Vertex { pos: [x, y, z], normal: [x, y, z], uv: [u, v] });
    }
  }

  for stack in 0..stacks
  {
    for slice in 0..slices
    {
      let row_a = stack * (slices + 1);
      let row_b = (stack + 1) * (slices + 1);
      let a = row_a + slice;
      let b = row_a + slice + 1;
      let c = row_b + slice;
      let d = row_b + slice + 1;

      indices.extend_from_slice(&[a, c, b]);
      indices.extend_from_slice(&[b, c, d]);
    }
  }

  (vertices, indices)
}

// ──────────────────────────────────────────────────────────────
//   Pipeline
// ──────────────────────────────────────────────────────────────

fn create_pipeline(
  device: &wgpu::Device,
  shared: &SharedState,
  tex_layout: &TextureLayout,
) -> wgpu::RenderPipeline
{
  let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
    label: Some("Sphere Shader"),
    source: wgpu::ShaderSource::Wgsl(include_str!("../../shaders/sphere.wgsl").into()),
  });

  let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
    label: Some("Sphere Pipeline Layout"),
    bind_group_layouts: &[&shared.camera_gpu.layout, &tex_layout.layout],
    push_constant_ranges: &[],
  });

  device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
    label: Some("Sphere Pipeline"),
    layout: Some(&layout),
    vertex: wgpu::VertexState {
      module: &shader,
      entry_point: Some("vs_main"),
      buffers: &[
        wgpu::VertexBufferLayout {
          array_stride: std::mem::size_of::<Vertex>() as u64,
          step_mode: wgpu::VertexStepMode::Vertex,
          attributes: &wgpu::vertex_attr_array![
            0 => Float32x3,  // position
            1 => Float32x3,  // normal
            2 => Float32x2,  // uv
          ],
        },
        wgpu::VertexBufferLayout {
          array_stride: std::mem::size_of::<GpuInstance>() as u64,
          step_mode: wgpu::VertexStepMode::Instance,
          attributes: &wgpu::vertex_attr_array![
            3 => Float32x3,  // center_rel
            4 => Float32,    // radius
            5 => Uint32,     // tex_index (unused in shader, draw loop handles it)
          ],
        },
      ],
      compilation_options: wgpu::PipelineCompilationOptions::default(),
    },
    fragment: Some(wgpu::FragmentState {
      module: &shader,
      entry_point: Some("fs_main"),
      targets: &[Some(wgpu::ColorTargetState {
        format: shared.surface_format,
        blend: Some(wgpu::BlendState::REPLACE),
        write_mask: wgpu::ColorWrites::ALL,
      })],
      compilation_options: wgpu::PipelineCompilationOptions::default(),
    }),
    primitive: wgpu::PrimitiveState { cull_mode: Some(wgpu::Face::Back), ..Default::default() },
    depth_stencil: Some(wgpu::DepthStencilState {
      format: shared.depth_format,
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
