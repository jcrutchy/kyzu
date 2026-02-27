use crate::camera::Camera;

//
// ──────────────────────────────────────────────────────────────
//   Grid Uniform (GPU side)
//
//   WGSL alignment rules differ from Rust:
//     vec3<f32> occupies 16 bytes (not 12) due to vec3 alignment.
//   The Rust struct must manually pad to match. See grid.wgsl.
//
//   Layout:
//     view_proj     : mat4x4<f32>  →  64 bytes  (offset   0)
//     inv_view_proj : mat4x4<f32>  →  64 bytes  (offset  64)
//     eye_pos       : vec3<f32>    →  12 bytes  (offset 128)
//     _pad0         : f32          →   4 bytes  (offset 140) ← pads eye_pos to 16
//     fade_near     : f32          →   4 bytes  (offset 144)
//     fade_far      : f32          →   4 bytes  (offset 148)
//     _pad1         : vec2<f32>    →   8 bytes  (offset 152) ← pads to 16-byte boundary
//   Total: 160 bytes
// ──────────────────────────────────────────────────────────────
//

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct GridUniform
{
  pub view_proj: [[f32; 4]; 4],     //  64 bytes  (offset   0)
  pub inv_view_proj: [[f32; 4]; 4], //  64 bytes  (offset  64)
  pub eye_pos: [f32; 3],            //  12 bytes  (offset 128)
  pub _pad0: f32,                   //   4 bytes  (offset 140) — pads eye_pos to WGSL vec3 size
  pub fade_near: f32,               //   4 bytes  (offset 144)
  pub fade_far: f32,                //   4 bytes  (offset 148)
  pub _pad1: [f32; 2],              //   8 bytes  (offset 152) — pads struct to 160
}

// Catch CPU/GPU layout mismatches at compile time.
// If this fails, recheck WGSL struct alignment in grid.wgsl.
const _: () = assert!(std::mem::size_of::<GridUniform>() == 160);

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
      _pad0: 0.0,
      fade_near: camera.radius * 2.5,
      fade_far: camera.radius * 25.0,
      _pad1: [0.0; 2],
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
      buffers: &[], // no VBO — full-screen triangle generated in shader
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
      cull_mode: None, // full-screen triangle — culling makes no sense
      ..Default::default()
    },
    depth_stencil: Some(wgpu::DepthStencilState {
      format: wgpu::TextureFormat::Depth32Float,
      depth_write_enabled: false, // transparent — must not occlude geometry behind it
      depth_compare: wgpu::CompareFunction::LessEqual, // full-screen tri is at far plane
      stencil: wgpu::StencilState::default(),
      bias: wgpu::DepthBiasState::default(),
    }),
    multisample: wgpu::MultisampleState::default(),
    multiview: None,
    cache: None,
  })
}
