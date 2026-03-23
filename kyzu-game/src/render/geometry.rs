use bytemuck::{Pod, Zeroable};

#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
pub struct Vertex
{
  pub position: [f32; 3],
  pub uv: [f32; 2],
}

impl Vertex
{
  pub fn desc() -> wgpu::VertexBufferLayout<'static>
  {
    wgpu::VertexBufferLayout {
      array_stride: std::mem::size_of::<Vertex>() as wgpu::BufferAddress,
      step_mode: wgpu::VertexStepMode::Vertex,
      attributes: &[
        wgpu::VertexAttribute {
          offset: 0,
          shader_location: 0,
          format: wgpu::VertexFormat::Float32x3,
        },
        wgpu::VertexAttribute {
          offset: std::mem::size_of::<[f32; 3]>() as wgpu::BufferAddress,
          shader_location: 1,
          format: wgpu::VertexFormat::Float32x2,
        },
      ],
    }
  }
}

// The Golden Ratio
const PHI: f32 = 1.61803398875;

pub const ICO_VERTICES: &[Vertex] = &[
  // 12 vertices of an icosahedron
  Vertex { position: [-1.0, PHI, 0.0], uv: [0.0, 0.0] }, // 0
  Vertex { position: [1.0, PHI, 0.0], uv: [1.0, 0.0] },  // 1
  Vertex { position: [-1.0, -PHI, 0.0], uv: [0.0, 1.0] }, // 2
  Vertex { position: [1.0, -PHI, 0.0], uv: [1.0, 1.0] }, // 3
  Vertex { position: [0.0, -1.0, PHI], uv: [0.5, 0.0] }, // 4
  Vertex { position: [0.0, 1.0, PHI], uv: [0.5, 1.0] },  // 5
  Vertex { position: [0.0, -1.0, -PHI], uv: [0.0, 0.5] }, // 6
  Vertex { position: [0.0, 1.0, -PHI], uv: [1.0, 0.5] }, // 7
  Vertex { position: [PHI, 0.0, -1.0], uv: [0.25, 0.25] }, // 8
  Vertex { position: [PHI, 0.0, 1.0], uv: [0.75, 0.25] }, // 9
  Vertex { position: [-PHI, 0.0, -1.0], uv: [0.25, 0.75] }, // 10
  Vertex { position: [-PHI, 0.0, 1.0], uv: [0.75, 0.75] }, // 11
];

pub const ICO_INDICES: &[u16] = &[
  0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
  3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
];
