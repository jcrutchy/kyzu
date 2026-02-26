use wgpu::util::DeviceExt;

//
// ──────────────────────────────────────────────────────────────
//   Constants
// ──────────────────────────────────────────────────────────────
//

const AXIS_LENGTH: f32 = 5.0;

// Positive arm colours
const COL_X_POS: [f32; 3] = [1.0, 0.2, 0.2];
const COL_Y_POS: [f32; 3] = [0.2, 1.0, 0.2];
const COL_Z_POS: [f32; 3] = [0.2, 0.4, 1.0];

// Negative arm colours (dimmed)
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
//   AxesMesh
// ──────────────────────────────────────────────────────────────
//

pub struct AxesMesh
{
  pub vertex_buffer: wgpu::Buffer,
  pub vertex_count: u32,
}

impl AxesMesh
{
  pub fn create(device: &wgpu::Device) -> Self
  {
    let vertices = build_vertices();

    let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
      label: Some("Axes Vertex Buffer"),
      contents: bytemuck::cast_slice(&vertices),
      usage: wgpu::BufferUsages::VERTEX,
    });

    Self { vertex_buffer, vertex_count: vertices.len() as u32 }
  }
}

//
// ──────────────────────────────────────────────────────────────
//   Geometry builder
// ──────────────────────────────────────────────────────────────
//

fn make_vertex(pos: [f32; 3], col: [f32; 3]) -> Vertex
{
  [pos[0], pos[1], pos[2], col[0], col[1], col[2]]
}

fn build_vertices() -> Vec<Vertex>
{
  let origin = [0.0_f32, 0.0, 0.0];

  vec![
    // +X / -X
    make_vertex(origin, COL_X_POS),
    make_vertex([AXIS_LENGTH, 0.0, 0.0], COL_X_POS),
    make_vertex(origin, COL_X_NEG),
    make_vertex([-AXIS_LENGTH, 0.0, 0.0], COL_X_NEG),
    // +Y / -Y
    make_vertex(origin, COL_Y_POS),
    make_vertex([0.0, AXIS_LENGTH, 0.0], COL_Y_POS),
    make_vertex(origin, COL_Y_NEG),
    make_vertex([0.0, -AXIS_LENGTH, 0.0], COL_Y_NEG),
    // +Z / -Z
    make_vertex(origin, COL_Z_POS),
    make_vertex([0.0, 0.0, AXIS_LENGTH], COL_Z_POS),
    make_vertex(origin, COL_Z_NEG),
    make_vertex([0.0, 0.0, -AXIS_LENGTH], COL_Z_NEG),
  ]
}

//
// ──────────────────────────────────────────────────────────────
//   Pipeline
// ──────────────────────────────────────────────────────────────
//

pub fn create_axes_pipeline(
  device: &wgpu::Device,
  config: &wgpu::SurfaceConfiguration,
  camera_bgl: &wgpu::BindGroupLayout,
) -> wgpu::RenderPipeline
{
  let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
    label: Some("Axes Shader"),
    source: wgpu::ShaderSource::Wgsl(include_str!("../shaders/axes.wgsl").into()),
  });

  let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
    label: Some("Axes Pipeline Layout"),
    bind_group_layouts: &[camera_bgl],
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
        format: config.format,
        blend: Some(wgpu::BlendState::REPLACE),
        write_mask: wgpu::ColorWrites::ALL,
      })],
      compilation_options: wgpu::PipelineCompilationOptions::default(),
    }),
    primitive: wgpu::PrimitiveState {
      topology: wgpu::PrimitiveTopology::LineList,
      strip_index_format: None,
      front_face: wgpu::FrontFace::Ccw,
      cull_mode: None,
      unclipped_depth: false,
      polygon_mode: wgpu::PolygonMode::Fill,
      conservative: false,
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
  })
}
