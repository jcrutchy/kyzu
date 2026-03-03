use wgpu::util::DeviceExt;

use crate::renderer::module::RenderModule;
use crate::renderer::shared::{FrameTargets, SharedState};

//
// ──────────────────────────────────────────────────────────────
//   Constants
// ──────────────────────────────────────────────────────────────
//

const AXIS_LENGTH: f32 = 5.0;

const COL_X_POS: [f32; 3] = [1.0, 0.2, 0.2];
const COL_Y_POS: [f32; 3] = [0.2, 1.0, 0.2];
const COL_Z_POS: [f32; 3] = [0.2, 0.4, 1.0];
const COL_X_NEG: [f32; 3] = [0.3, 0.1, 0.1];
const COL_Y_NEG: [f32; 3] = [0.1, 0.3, 0.1];
const COL_Z_NEG: [f32; 3] = [0.1, 0.15, 0.3];

//
// ──────────────────────────────────────────────────────────────
//   Vertex layout: [x, y, z,  r, g, b]
// ──────────────────────────────────────────────────────────────
//

type Vertex = [f32; 6];

//
// ──────────────────────────────────────────────────────────────
//   Module
// ──────────────────────────────────────────────────────────────
//

pub struct AxesModule
{
  vertex_buffer: wgpu::Buffer,
  vertex_count: u32,
  pipeline: wgpu::RenderPipeline,
}

impl RenderModule for AxesModule
{
  fn init(device: &wgpu::Device, _queue: &wgpu::Queue, shared: &SharedState) -> Self
  {
    let vertices = build_vertices();
    let vertex_count = vertices.len() as u32;

    let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
      label: Some("Axes Vertex Buffer"),
      contents: bytemuck::cast_slice(&vertices),
      usage: wgpu::BufferUsages::VERTEX,
    });

    let pipeline = create_pipeline(device, shared);

    Self { vertex_buffer, vertex_count, pipeline }
  }

  fn update(&mut self, _queue: &wgpu::Queue, _shared: &SharedState)
  {
    // Axes are static — nothing to update each frame
  }

  fn encode(&self, encoder: &mut wgpu::CommandEncoder, targets: &FrameTargets, shared: &SharedState)
  {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
      label: Some("Axes Pass"),
      color_attachments: &[Some(wgpu::RenderPassColorAttachment {
        view: targets.color,
        resolve_target: None,
        ops: wgpu::Operations {
          load: wgpu::LoadOp::Load, // don't clear — draw on top of previous passes
          store: wgpu::StoreOp::Store,
        },
        depth_slice: None,
      })],
      depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
        view: targets.depth,
        depth_ops: Some(wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store }),
        stencil_ops: None,
      }),
      occlusion_query_set: None,
      timestamp_writes: None,
    });

    pass.set_pipeline(&self.pipeline);
    pass.set_bind_group(0, &shared.camera_gpu.bind_group, &[]);
    pass.set_vertex_buffer(0, self.vertex_buffer.slice(..));
    pass.draw(0..self.vertex_count, 0..1);
  }

  fn as_any_mut(&mut self) -> &mut dyn std::any::Any
  {
    self
  }
}

//
// ──────────────────────────────────────────────────────────────
//   Geometry
// ──────────────────────────────────────────────────────────────
//

fn make_vertex(pos: [f32; 3], col: [f32; 3]) -> Vertex
{
  [pos[0], pos[1], pos[2], col[0], col[1], col[2]]
}

fn build_vertices() -> Vec<Vertex>
{
  let o = [0.0_f32, 0.0, 0.0];
  vec![
    make_vertex(o, COL_X_POS),
    make_vertex([AXIS_LENGTH, 0.0, 0.0], COL_X_POS),
    make_vertex(o, COL_X_NEG),
    make_vertex([-AXIS_LENGTH, 0.0, 0.0], COL_X_NEG),
    make_vertex(o, COL_Y_POS),
    make_vertex([0.0, AXIS_LENGTH, 0.0], COL_Y_POS),
    make_vertex(o, COL_Y_NEG),
    make_vertex([0.0, -AXIS_LENGTH, 0.0], COL_Y_NEG),
    make_vertex(o, COL_Z_POS),
    make_vertex([0.0, 0.0, AXIS_LENGTH], COL_Z_POS),
    make_vertex(o, COL_Z_NEG),
    make_vertex([0.0, 0.0, -AXIS_LENGTH], COL_Z_NEG),
  ]
}

//
// ──────────────────────────────────────────────────────────────
//   Pipeline
// ──────────────────────────────────────────────────────────────
//

fn create_pipeline(device: &wgpu::Device, shared: &SharedState) -> wgpu::RenderPipeline
{
  let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
    label: Some("Axes Shader"),
    source: wgpu::ShaderSource::Wgsl(include_str!("../../shaders/axes.wgsl").into()),
  });

  let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
    label: Some("Axes Pipeline Layout"),
    bind_group_layouts: &[&shared.camera_gpu.layout],
    push_constant_ranges: &[],
  });

  device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
    label: Some("Axes Pipeline"),
    layout: Some(&layout),
    vertex: wgpu::VertexState {
      module: &shader,
      entry_point: Some("vs_main"),
      buffers: &[wgpu::VertexBufferLayout {
        array_stride: std::mem::size_of::<Vertex>() as u64,
        step_mode: wgpu::VertexStepMode::Vertex,
        attributes: &wgpu::vertex_attr_array![
          0 => Float32x3,  // position
          1 => Float32x3,  // colour
        ],
      }],
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
    primitive: wgpu::PrimitiveState {
      topology: wgpu::PrimitiveTopology::LineList,
      ..Default::default()
    },
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
