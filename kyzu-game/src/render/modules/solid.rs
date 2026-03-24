use std::any::Any;
use std::path::Path;

use wgpu::util::DeviceExt;
use wgpu::{include_wgsl, Queue};

use crate::bake::geometry::BakedVertex;
use crate::core::log::{LogLevel, Logger};
use crate::render::module::{FrameTargets, RenderModule};
use crate::render::shared::SharedState;

pub struct SolidModule
{
  pipeline: wgpu::RenderPipeline,
  vertex_buffer: wgpu::Buffer,
  index_buffer: wgpu::Buffer,
  index_count: u32,
}

impl SolidModule
{
  pub fn new(
    device: &wgpu::Device,
    shared: &SharedState,
    mesh_path: &Path,
    logger: &mut Logger,
  ) -> Self
  {
    let shader = device.create_shader_module(include_wgsl!("../shaders/solid.wgsl"));

    // 1. Load the small test icosahedron bake
    let bake_data = std::fs::read(mesh_path).expect("Failed to load baked mesh from path.");

    // 2. Extract counts (Header: 4 bytes v_count, 4 bytes i_count)
    let v_count = u32::from_le_bytes(bake_data[0..4].try_into().unwrap()) as usize;
    let vertex_size = std::mem::size_of::<BakedVertex>();

    let vertex_data_start = 8; // After the two u32 counts
    let vertex_data_end = vertex_data_start + (v_count * vertex_size);

    // 3. Extract indices (Uint32 format)
    let vertices: &[BakedVertex] =
      bytemuck::cast_slice(&bake_data[vertex_data_start..vertex_data_end]);
    let indices: &[u32] = bytemuck::cast_slice(&bake_data[vertex_data_end..]);
    let i_count = indices.len();

    let msg = format!("Loaded {} vertices from bake.", vertices.len());
    logger.emit(LogLevel::Debug, &msg);

    if let Some(v) = vertices.get(0)
    {
      logger.emit(LogLevel::Debug, &format!("First Vertex Position: {:?}", v.pos));
    }

    // 4. Create GPU Buffers
    let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
      label: Some("Solid Test Vertex Buffer"),
      contents: bytemuck::cast_slice(vertices),
      usage: wgpu::BufferUsages::VERTEX,
    });

    let index_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
      label: Some("Solid Test Index Buffer"),
      contents: bytemuck::cast_slice(indices),
      usage: wgpu::BufferUsages::INDEX,
    });

    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
      label: Some("Solid Pipeline Layout"),
      bind_group_layouts: &[&shared.camera_gpu.layout],
      push_constant_ranges: &[],
    });

    let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
      label: Some("Solid Render Pipeline"),
      layout: Some(&pipeline_layout),
      vertex: wgpu::VertexState {
        module: &shader,
        entry_point: Some("vs_main"),
        compilation_options: Default::default(),
        buffers: &[wgpu::VertexBufferLayout {
          array_stride: vertex_size as u64,
          step_mode: wgpu::VertexStepMode::Vertex,
          // We only pass location 0 (pos) to this specific shader
          attributes: &wgpu::vertex_attr_array![0 => Float32x3],
        }],
      },
      fragment: Some(wgpu::FragmentState {
        module: &shader,
        entry_point: Some("fs_main"),
        compilation_options: Default::default(),
        targets: &[Some(wgpu::ColorTargetState {
          format: wgpu::TextureFormat::Bgra8UnormSrgb,
          blend: Some(wgpu::BlendState::REPLACE),
          write_mask: wgpu::ColorWrites::ALL,
        })],
      }),
      primitive: wgpu::PrimitiveState {
        topology: wgpu::PrimitiveTopology::TriangleList,
        cull_mode: Some(wgpu::Face::Back),
        ..Default::default()
      },
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
    });

    Self { pipeline, vertex_buffer, index_buffer, index_count: i_count as u32 }
  }
}

impl RenderModule for SolidModule
{
  fn update(&mut self, _queue: &Queue, _shared: &SharedState) {}

  fn encode(&self, encoder: &mut wgpu::CommandEncoder, targets: &FrameTargets, shared: &SharedState)
  {
    let mut render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
      label: Some("Solid Render Pass"),
      color_attachments: &[Some(wgpu::RenderPassColorAttachment {
        view: targets.surface_view,
        resolve_target: None,
        ops: wgpu::Operations {
          load: wgpu::LoadOp::Clear(wgpu::Color { r: 0.01, g: 0.01, b: 0.02, a: 1.0 }),
          store: wgpu::StoreOp::Store,
        },
        depth_slice: None,
      })],
      depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
        view: targets.depth_view,
        depth_ops: Some(wgpu::Operations {
          load: wgpu::LoadOp::Clear(1.0),
          store: wgpu::StoreOp::Store,
        }),
        stencil_ops: None,
      }),
      ..Default::default()
    });

    render_pass.set_pipeline(&self.pipeline);
    render_pass.set_bind_group(0, &shared.camera_gpu.bind_group, &[]);
    render_pass.set_vertex_buffer(0, self.vertex_buffer.slice(..));

    // Critical: Using Uint32 to match the BakeManager output
    render_pass.set_index_buffer(self.index_buffer.slice(..), wgpu::IndexFormat::Uint32);

    render_pass.draw_indexed(0..self.index_count, 0, 0..1);
  }

  fn as_any_mut(&mut self) -> &mut dyn Any
  {
    self
  }
}
