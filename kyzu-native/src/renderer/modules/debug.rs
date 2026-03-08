use crate::renderer::module::RenderModule;
use crate::renderer::shared::{FrameTargets, SharedState};

//
// ──────────────────────────────────────────────────────────────
//   Debug visualisation for the camera target
//
//   Draws:
//     - White cross  at camera target
//     - Yellow cross at target projected onto Z=0 (XY plane)
//     - Grey line    connecting them (only when target.z != 0)
//
//   Reuses the axes shader and pipeline — same vertex layout.
// ──────────────────────────────────────────────────────────────
//

//
// ──────────────────────────────────────────────────────────────
//   Constants
// ──────────────────────────────────────────────────────────────
//

const COL_TARGET: [f32; 3] = [1.0, 1.0, 1.0];

//
// ──────────────────────────────────────────────────────────────
//   Vertex layout: [x, y, z,  r, g, b]  (matches axes shader)
// ──────────────────────────────────────────────────────────────
//

type Vertex = [f32; 6];

const MAX_VERTS: u64 = 14;

//
// ──────────────────────────────────────────────────────────────
//   Module
// ──────────────────────────────────────────────────────────────
//

pub struct DebugModule
{
  vertex_buffer: wgpu::Buffer,
  vertex_count: u32,
  pipeline: wgpu::RenderPipeline,
}

impl RenderModule for DebugModule
{
  fn init(device: &wgpu::Device, _queue: &wgpu::Queue, shared: &SharedState) -> Self
  {
    let vertex_buffer = device.create_buffer(&wgpu::BufferDescriptor {
      label: Some("Debug Vertex Buffer"),
      size: MAX_VERTS * std::mem::size_of::<Vertex>() as u64,
      usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
      mapped_at_creation: false,
    });

    let pipeline = create_pipeline(device, shared);

    Self { vertex_buffer, vertex_count: 0, pipeline }
  }

  fn update(&mut self, queue: &wgpu::Queue, shared: &SharedState)
  {
    let target_rel = shared.camera.target_rel;
    let arm = (shared.camera.radius * 0.02).max(0.1) as f32;

    let mut verts: Vec<Vertex> = Vec::with_capacity(6);
    push_cross(&mut verts, target_rel, COL_TARGET, arm);

    self.vertex_count = verts.len() as u32;
    queue.write_buffer(&self.vertex_buffer, 0, bytemuck::cast_slice(&verts));
  }

  fn encode(&self, encoder: &mut wgpu::CommandEncoder, targets: &FrameTargets, shared: &SharedState)
  {
    if self.vertex_count == 0
    {
      return;
    }

    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
      label: Some("Debug Pass"),
      color_attachments: &[Some(wgpu::RenderPassColorAttachment {
        view: targets.color,
        resolve_target: None,
        ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
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
//   Geometry helpers
// ──────────────────────────────────────────────────────────────
//

fn make_vertex(pos: [f32; 3], col: [f32; 3]) -> Vertex
{
  [pos[0], pos[1], pos[2], col[0], col[1], col[2]]
}

fn push_cross(verts: &mut Vec<Vertex>, centre: [f32; 3], col: [f32; 3], arm: f32)
{
  let [x, y, z] = centre;

  verts.push(make_vertex([x - arm, y, z], col));
  verts.push(make_vertex([x + arm, y, z], col));
  verts.push(make_vertex([x, y - arm, z], col));
  verts.push(make_vertex([x, y + arm, z], col));
  verts.push(make_vertex([x, y, z - arm], col));
  verts.push(make_vertex([x, y, z + arm], col));
}

//
// ──────────────────────────────────────────────────────────────
//   Pipeline — identical to axes, reuses axes.wgsl
// ──────────────────────────────────────────────────────────────
//

fn create_pipeline(device: &wgpu::Device, shared: &SharedState) -> wgpu::RenderPipeline
{
  let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
    label: Some("Debug Shader"),
    source: wgpu::ShaderSource::Wgsl(include_str!("../../shaders/debug.wgsl").into()),
  });

  let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
    label: Some("Debug Pipeline Layout"),
    bind_group_layouts: &[&shared.camera_gpu.layout],
    push_constant_ranges: &[],
  });

  device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
    label: Some("Debug Pipeline"),
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
