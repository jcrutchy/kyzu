use glam::Mat4;
use wgpu::util::DeviceExt;

use crate::camera::Camera;

//
// ──────────────────────────────────────────────────────────────
//   Grid Uniform (GPU side)
// ──────────────────────────────────────────────────────────────
//

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct GridUniform
{
  pub view_proj: [[f32; 4]; 4],
  pub inv_view_proj: [[f32; 4]; 4],
  pub eye_pos: [f32; 3],
  pub _pad: f32,
}

impl GridUniform
{
  pub fn from_camera(camera: &Camera) -> Self
  {
    let view_proj = camera.build_view_proj();
    let inv_view_proj = view_proj.inverse();
    let eye = camera.eye_position();

    Self {
      view_proj: view_proj.to_cols_array_2d(),
      inv_view_proj: inv_view_proj.to_cols_array_2d(),
      eye_pos: eye.to_array(),
      _pad: 0.0,
    }
  }
}

//
// ──────────────────────────────────────────────────────────────
//   Grid resources
// ──────────────────────────────────────────────────────────────
//

pub struct GridMesh
{
  pub uniform_buffer: wgpu::Buffer,
  pub bind_group: wgpu::BindGroup,
  pub bind_group_layout: wgpu::BindGroupLayout,
}

impl GridMesh
{
  pub fn create(device: &wgpu::Device) -> Self
  {
    let uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
      label: Some("Grid Uniform Buffer"),
      size: std::mem::size_of::<GridUniform>() as u64,
      usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
      mapped_at_creation: false,
    });

    let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
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
      layout: &bind_group_layout,
      entries: &[wgpu::BindGroupEntry { binding: 0, resource: uniform_buffer.as_entire_binding() }],
    });

    Self { uniform_buffer, bind_group, bind_group_layout }
  }

  pub fn update(&self, queue: &wgpu::Queue, camera: &Camera)
  {
    let uniform = GridUniform::from_camera(camera);
    queue.write_buffer(&self.uniform_buffer, 0, bytemuck::bytes_of(&uniform));
  }
}

//
// ──────────────────────────────────────────────────────────────
//   Pipeline
// ──────────────────────────────────────────────────────────────
//

pub fn create_grid_pipeline(
  device: &wgpu::Device,
  config: &wgpu::SurfaceConfiguration,
  bind_group_layout: &wgpu::BindGroupLayout,
) -> wgpu::RenderPipeline
{
  let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
    label: Some("Grid Shader"),
    source: wgpu::ShaderSource::Wgsl(include_str!("../shaders/grid.wgsl").into()),
  });

  let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
    label: Some("Grid Pipeline Layout"),
    bind_group_layouts: &[bind_group_layout],
    push_constant_ranges: &[],
  });

  device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
    label: Some("Grid Pipeline"),
    layout: Some(&layout),
    vertex: wgpu::VertexState {
      module: &shader,
      entry_point: Some("vs_main"),
      buffers: &[], // no VBO — verts generated in shader
      compilation_options: wgpu::PipelineCompilationOptions::default(),
    },
    fragment: Some(wgpu::FragmentState {
      module: &shader,
      entry_point: Some("fs_main"),
      targets: &[Some(wgpu::ColorTargetState {
        format: config.format,
        blend: Some(wgpu::BlendState::ALPHA_BLENDING),
        write_mask: wgpu::ColorWrites::ALL,
      })],
      compilation_options: wgpu::PipelineCompilationOptions::default(),
    }),
    primitive: wgpu::PrimitiveState {
      topology: wgpu::PrimitiveTopology::TriangleList,
      strip_index_format: None,
      front_face: wgpu::FrontFace::Ccw,
      cull_mode: None, // full-screen tri — no culling
      unclipped_depth: false,
      polygon_mode: wgpu::PolygonMode::Fill,
      conservative: false,
    },
    depth_stencil: Some(wgpu::DepthStencilState {
      format: wgpu::TextureFormat::Depth32Float,
      depth_write_enabled: false, // grid is transparent — don't write depth
      depth_compare: wgpu::CompareFunction::LessEqual,
      stencil: wgpu::StencilState::default(),
      bias: wgpu::DepthBiasState::default(),
    }),
    multisample: wgpu::MultisampleState::default(),
    multiview: None,
    cache: None,
  })
}
