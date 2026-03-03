use crate::renderer::module::RenderModule;
use crate::renderer::shared::{FrameTargets, SharedState};

//
// ──────────────────────────────────────────────────────────────
//   Grid Uniform (GPU side)
// ──────────────────────────────────────────────────────────────
//

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct GridUniform
{
  view_proj: [[f32; 4]; 4],     // 64 bytes (Offset 0)
  inv_view_proj: [[f32; 4]; 4], // 64 bytes (Offset 64)
  eye_pos: [f32; 3],            // 12 bytes (Offset 128)
  fade_near: f32,               //  4 bytes (Offset 140)
  fade_far: f32,                //  4 bytes (Offset 144)
  lod_scale: f32,               //  4 bytes (Offset 148)
  lod_fade: f32,                //  4 bytes (Offset 152)
  _pad: f32,                    //  4 bytes (Offset 156)
}

const _: () = assert!(std::mem::size_of::<GridUniform>() == 160);

//
// ──────────────────────────────────────────────────────────────
//   Module
// ──────────────────────────────────────────────────────────────
//

pub struct GridModule
{
  uniform_buffer: wgpu::Buffer,
  bind_group: wgpu::BindGroup,
  pipeline: wgpu::RenderPipeline,
}

impl RenderModule for GridModule
{
  fn init(device: &wgpu::Device, _queue: &wgpu::Queue, shared: &SharedState) -> Self
  {
    let uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
      label: Some("Grid Uniform Buffer"),
      size: std::mem::size_of::<GridUniform>() as u64,
      usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
      mapped_at_creation: false,
    });

    let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
      label: Some("Grid BGL"),
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

    let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
      label: Some("Grid BG"),
      layout: &bgl,
      entries: &[wgpu::BindGroupEntry { binding: 0, resource: uniform_buffer.as_entire_binding() }],
    });

    let pipeline = create_pipeline(device, shared, &bgl);

    Self { uniform_buffer, bind_group, pipeline }
  }

  fn update(&mut self, queue: &wgpu::Queue, shared: &SharedState)
  {
    let uniform = build_uniform(shared);
    queue.write_buffer(&self.uniform_buffer, 0, bytemuck::bytes_of(&uniform));
  }

  fn encode(
    &self,
    encoder: &mut wgpu::CommandEncoder,
    targets: &FrameTargets,
    _shared: &SharedState,
  )
  {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
      label: Some("Grid Pass"),
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
    pass.set_bind_group(0, &self.bind_group, &[]);
    pass.draw(0..3, 0..1); // full-screen triangle, no VBO
  }

  fn as_any_mut(&mut self) -> &mut dyn std::any::Any
  {
    self
  }
}

//
// ──────────────────────────────────────────────────────────────
//   Uniform builder
//
//   This function used to live on GridUniform as from_camera(),
//   taking a &Camera. Now it takes &SharedState and reads the
//   matrices that the camera module already computed. The LOD
//   logic moves here since it only concerns this module.
// ──────────────────────────────────────────────────────────────
//

fn build_uniform(shared: &SharedState) -> GridUniform
{
  let cam = &shared.camera;

  GridUniform {
    view_proj: cam.view_proj,
    inv_view_proj: cam.inv_view_proj,
    eye_pos: cam.eye_world,
    fade_near: cam.fade_near,
    fade_far: cam.fade_far,
    lod_scale: cam.lod_scale,
    lod_fade: cam.lod_fade,
    _pad: 0.0,
  }
}

//
// ──────────────────────────────────────────────────────────────
//   Pipeline
// ──────────────────────────────────────────────────────────────
//

fn create_pipeline(
  device: &wgpu::Device,
  shared: &SharedState,
  bgl: &wgpu::BindGroupLayout,
) -> wgpu::RenderPipeline
{
  let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
    label: Some("Grid Shader"),
    source: wgpu::ShaderSource::Wgsl(include_str!("../../shaders/grid.wgsl").into()),
  });

  let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
    label: Some("Grid Pipeline Layout"),
    bind_group_layouts: &[bgl],
    push_constant_ranges: &[],
  });

  device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
    label: Some("Grid Pipeline"),
    layout: Some(&layout),
    vertex: wgpu::VertexState {
      module: &shader,
      entry_point: Some("vs_main"),
      buffers: &[],
      compilation_options: wgpu::PipelineCompilationOptions::default(),
    },
    fragment: Some(wgpu::FragmentState {
      module: &shader,
      entry_point: Some("fs_main"),
      targets: &[Some(wgpu::ColorTargetState {
        format: shared.surface_format,
        blend: Some(wgpu::BlendState::ALPHA_BLENDING),
        write_mask: wgpu::ColorWrites::ALL,
      })],
      compilation_options: wgpu::PipelineCompilationOptions::default(),
    }),
    primitive: wgpu::PrimitiveState {
      topology: wgpu::PrimitiveTopology::TriangleList,
      cull_mode: None,
      ..Default::default()
    },
    depth_stencil: Some(wgpu::DepthStencilState {
      format: shared.depth_format,
      depth_write_enabled: false,
      depth_compare: wgpu::CompareFunction::LessEqual,
      stencil: wgpu::StencilState::default(),
      bias: wgpu::DepthBiasState::default(),
    }),
    multisample: wgpu::MultisampleState::default(),
    multiview: None,
    cache: None,
  })
}
