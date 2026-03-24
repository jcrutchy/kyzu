use std::any::Any;
use std::path::Path;

use glam::{DVec3, Mat4, Quat, Vec3};
use wgpu::util::DeviceExt;
use wgpu::{include_wgsl, BindGroup, Buffer, Queue};

use crate::bake::geometry::BakedVertex;
use crate::core::log::{LogLevel, Logger};
use crate::render::module::{FrameTargets, RenderModule};
use crate::render::shared::SharedState;

pub struct SolidModule
{
  pipeline: wgpu::RenderPipeline,
  vertex_buffer: Buffer,
  index_buffer: Buffer,
  index_count: u32,
  model_buffer: Buffer,
  model_bind_group: BindGroup,
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

    // 1. Load the mesh
    let bake_data = std::fs::read(mesh_path).expect("Failed to load baked mesh.");
    logger.emit(
      LogLevel::Info,
      &format!("Loading bake file: {} ({} bytes)", mesh_path.display(), bake_data.len()),
    );

    // Vertices
    let v_count = u32::from_le_bytes(bake_data[0..4].try_into().unwrap()) as usize;
    let vertex_size = std::mem::size_of::<BakedVertex>();
    let vertex_data_start = 4;
    let vertex_data_end = vertex_data_start + (v_count * vertex_size);

    logger.emit(
      LogLevel::Info,
      &format!("Mesh Stats: {} vertices ({} bytes each)", v_count, vertex_size),
    );

    let vertices: &[BakedVertex] =
      bytemuck::cast_slice(&bake_data[vertex_data_start..vertex_data_end]);

    // Indices
    let i_count_offset = vertex_data_end;

    // SAFETY CHECK: Is there enough data left for an index count?
    if i_count_offset + 4 > bake_data.len()
    {
      panic!(
        "Bake file truncated! Expected index count at {}, but file ends at {}",
        i_count_offset,
        bake_data.len()
      );
    }

    let i_count =
      u32::from_le_bytes(bake_data[i_count_offset..i_count_offset + 4].try_into().unwrap())
        as usize;
    let index_data_start = i_count_offset + 4;
    let index_data_end = index_data_start + (i_count * 4);

    logger.emit(
      LogLevel::Info,
      &format!("Mesh Stats: {} indices (offset: {})", i_count, i_count_offset),
    );

    // CRITICAL FIX: Ensure we aren't passing an empty slice to the GPU
    if i_count == 0
    {
      panic!("Bake file contains 0 indices! The subdivision or save logic in 'cook_body' might be broken.");
    }

    if index_data_end > bake_data.len()
    {
      panic!(
        "Bake file truncated! Expected index data up to {}, but file ends at {}",
        index_data_end,
        bake_data.len()
      );
    }

    let indices: &[u32] = bytemuck::cast_slice(&bake_data[index_data_start..index_data_end]);

    // 2. GPU Buffers (Geometry)
    let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
      label: Some("Solid Vertex Buffer"),
      contents: bytemuck::cast_slice(vertices),
      usage: wgpu::BufferUsages::VERTEX,
    });

    let index_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
      label: Some("Solid Index Buffer"),
      contents: bytemuck::cast_slice(indices),
      usage: wgpu::BufferUsages::INDEX,
    });

    // 3. Model Matrix Buffer (Group 1)
    let model_buffer = device.create_buffer(&wgpu::BufferDescriptor {
      label: Some("Solid Model Buffer"),
      size: 64, // 16 * f32
      usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
      mapped_at_creation: false,
    });

    let model_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
      label: Some("Solid Model BGL"),
      entries: &[wgpu::BindGroupLayoutEntry {
        binding: 0,
        visibility: wgpu::ShaderStages::VERTEX,
        ty: wgpu::BindingType::Buffer {
          ty: wgpu::BufferBindingType::Uniform,
          has_dynamic_offset: false,
          min_binding_size: None,
        },
        count: None,
      }],
    });

    let model_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
      label: Some("Solid Model BG"),
      layout: &model_layout,
      entries: &[wgpu::BindGroupEntry { binding: 0, resource: model_buffer.as_entire_binding() }],
    });

    // 4. Pipeline Layout
    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
      label: Some("Solid Pipeline Layout"),
      bind_group_layouts: &[&shared.camera_gpu.layout, &model_layout],
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
          attributes: &wgpu::vertex_attr_array![
            0 => Float32x3, // position
            1 => Float32x3, // normal
            2 => Float32x2, // uv
            3 => Float32,   // height
            4 => Uint32,    // hex_id
            5 => Float32x3, // barycentric
          ],
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

    Self {
      pipeline,
      vertex_buffer,
      index_buffer,
      index_count: i_count as u32,
      model_buffer,
      model_bind_group,
    }
  }
}

impl RenderModule for SolidModule
{
  fn update(&mut self, queue: &Queue, shared: &SharedState)
  {
    let planet_pos_world = DVec3::ZERO;
    let relative_pos = planet_pos_world - shared.eye_world;
    let scale = 6_371_000.0_f32;

    let model_mat = Mat4::from_scale_rotation_translation(
      Vec3::splat(scale),
      Quat::IDENTITY,
      relative_pos.as_vec3(),
    );

    queue.write_buffer(&self.model_buffer, 0, bytemuck::cast_slice(&model_mat.to_cols_array()));
  }

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
    render_pass.set_bind_group(1, &self.model_bind_group, &[]);
    render_pass.set_vertex_buffer(0, self.vertex_buffer.slice(..));
    render_pass.set_index_buffer(self.index_buffer.slice(..), wgpu::IndexFormat::Uint32);

    render_pass.draw_indexed(0..self.index_count, 0, 0..1);
  }

  fn as_any_mut(&mut self) -> &mut dyn Any
  {
    self
  }
}
