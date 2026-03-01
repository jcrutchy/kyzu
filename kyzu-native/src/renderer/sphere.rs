use glam::DVec3;
use wgpu::util::DeviceExt;

use crate::camera::Camera;

//
// ──────────────────────────────────────────────────────────────
//   Sphere instance (CPU side)
// ──────────────────────────────────────────────────────────────
//

pub struct SphereInstance
{
  pub center: DVec3,
  pub radius: f64,
}

//
// ──────────────────────────────────────────────────────────────
//   Instance data uploaded to GPU each frame
// ──────────────────────────────────────────────────────────────
//

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct GpuInstance
{
  center_rel: [f32; 3], // camera-relative world position
  radius: f32,
}

//
// ──────────────────────────────────────────────────────────────
//   SphereMesh — shared UV sphere geometry + instance buffer
// ──────────────────────────────────────────────────────────────
//

pub struct SphereMesh
{
  pub vertex_buffer: wgpu::Buffer,
  pub index_buffer: wgpu::Buffer,
  pub index_count: u32,
  pub instance_buffer: wgpu::Buffer,
  pub instance_count: u32,
  max_instances: u32,
}

impl SphereMesh
{
  pub fn create(device: &wgpu::Device, max_instances: u32) -> Self
  {
    let (vertices, indices) = build_uv_sphere(32, 16);

    let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
      label: Some("Sphere Vertex Buffer"),
      contents: bytemuck::cast_slice(&vertices),
      usage: wgpu::BufferUsages::VERTEX,
    });

    let index_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
      label: Some("Sphere Index Buffer"),
      contents: bytemuck::cast_slice(&indices),
      usage: wgpu::BufferUsages::INDEX,
    });

    let instance_buffer = device.create_buffer(&wgpu::BufferDescriptor {
      label: Some("Sphere Instance Buffer"),
      size: (max_instances as u64) * std::mem::size_of::<GpuInstance>() as u64,
      usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
      mapped_at_creation: false,
    });

    Self {
      vertex_buffer,
      index_buffer,
      index_count: indices.len() as u32,
      instance_buffer,
      instance_count: 0,
      max_instances,
    }
  }

  /// Rebase all instance centers relative to the camera eye and upload.
  pub fn update(&mut self, queue: &wgpu::Queue, instances: &[SphereInstance], camera: &Camera)
  {
    let eye = camera.eye_position();
    let count = instances.len().min(self.max_instances as usize);

    let gpu: Vec<GpuInstance> = instances[..count]
      .iter()
      .map(|s| {
        let rel = (s.center - eye).as_vec3();
        GpuInstance { center_rel: rel.into(), radius: s.radius as f32 }
      })
      .collect();

    queue.write_buffer(&self.instance_buffer, 0, bytemuck::cast_slice(&gpu));
    self.instance_count = count as u32;
  }
}

//
// ──────────────────────────────────────────────────────────────
//   UV sphere geometry builder
//
//   stacks = horizontal rings (latitude), slices = vertical (longitude)
//   Vertex layout: [x, y, z,  nx, ny, nz]  — normal = position on unit sphere
// ──────────────────────────────────────────────────────────────
//

type Vertex = [f32; 6];

fn build_uv_sphere(slices: u32, stacks: u32) -> (Vec<Vertex>, Vec<u32>)
{
  let mut vertices: Vec<Vertex> = Vec::new();
  let mut indices: Vec<u32> = Vec::new();

  for stack in 0..=stacks
  {
    let phi = std::f32::consts::PI * stack as f32 / stacks as f32; // 0 → π (top to bottom)
    let sin_phi = phi.sin();
    let cos_phi = phi.cos();

    for slice in 0..=slices
    {
      let theta = 2.0 * std::f32::consts::PI * slice as f32 / slices as f32;
      let sin_theta = theta.sin();
      let cos_theta = theta.cos();

      // Unit sphere position — also serves as the normal
      let x = sin_phi * cos_theta;
      let y = sin_phi * sin_theta;
      let z = cos_phi;

      vertices.push([x, y, z, x, y, z]);
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

      // Two triangles per quad
      indices.extend_from_slice(&[a, c, b]);
      indices.extend_from_slice(&[b, c, d]);
    }
  }

  (vertices, indices)
}

//
// ──────────────────────────────────────────────────────────────
//   Pipeline
// ──────────────────────────────────────────────────────────────
//

pub fn create_sphere_pipeline(
  device: &wgpu::Device,
  config: &wgpu::SurfaceConfiguration,
  camera_bgl: &wgpu::BindGroupLayout,
) -> wgpu::RenderPipeline
{
  let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
    label: Some("Sphere Shader"),
    source: wgpu::ShaderSource::Wgsl(include_str!("../shaders/sphere.wgsl").into()),
  });

  let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
    label: Some("Sphere Pipeline Layout"),
    bind_group_layouts: &[camera_bgl],
    push_constant_ranges: &[],
  });

  device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
    label: Some("Sphere Pipeline"),
    layout: Some(&layout),
    vertex: wgpu::VertexState {
      module: &shader,
      entry_point: Some("vs_main"),
      buffers: &[
        // Buffer 0 — per-vertex
        wgpu::VertexBufferLayout {
          array_stride: std::mem::size_of::<Vertex>() as u64,
          step_mode: wgpu::VertexStepMode::Vertex,
          attributes: &wgpu::vertex_attr_array![
            0 => Float32x3,  // position (unit sphere)
            1 => Float32x3,  // normal
          ],
        },
        // Buffer 1 — per-instance
        wgpu::VertexBufferLayout {
          array_stride: std::mem::size_of::<GpuInstance>() as u64,
          step_mode: wgpu::VertexStepMode::Instance,
          attributes: &wgpu::vertex_attr_array![
            2 => Float32x3,  // center_rel
            3 => Float32,    // radius
          ],
        },
      ],
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
    primitive: wgpu::PrimitiveState { cull_mode: Some(wgpu::Face::Back), ..Default::default() },
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
