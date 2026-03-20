use bytemuck::{Pod, Zeroable};
use glam::Vec3;

pub const ICOSA_VERTICES: [Vec3; 12] = [
  Vec3::new(-0.5257311, 0.8506508, 0.0),
  Vec3::new(0.5257311, 0.8506508, 0.0),
  Vec3::new(-0.5257311, -0.8506508, 0.0),
  Vec3::new(0.5257311, -0.8506508, 0.0),
  Vec3::new(0.0, -0.5257311, 0.8506508),
  Vec3::new(0.0, 0.5257311, 0.8506508),
  Vec3::new(0.0, -0.5257311, -0.8506508),
  Vec3::new(0.0, 0.5257311, -0.8506508),
  Vec3::new(0.8506508, 0.0, -0.5257311),
  Vec3::new(0.8506508, 0.0, 0.5257311),
  Vec3::new(-0.8506508, 0.0, -0.5257311),
  Vec3::new(-0.8506508, 0.0, 0.5257311),
];

pub const ICOSA_INDICES: [[u32; 3]; 20] = [
  [0, 11, 5],
  [0, 5, 1],
  [0, 1, 7],
  [0, 7, 10],
  [0, 10, 11],
  [1, 5, 9],
  [5, 11, 4],
  [11, 10, 2],
  [10, 7, 6],
  [7, 1, 8],
  [3, 9, 4],
  [3, 4, 2],
  [3, 2, 6],
  [3, 6, 8],
  [3, 8, 9],
  [4, 9, 5],
  [2, 4, 11],
  [6, 2, 10],
  [8, 6, 7],
  [9, 8, 1],
];

#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
pub struct TerrainVertex
{
  pub pos: [f32; 3],
  pub hex_id: u32,
  pub bary: [f32; 2],
}

impl TerrainVertex
{
  pub fn desc() -> wgpu::VertexBufferLayout<'static>
  {
    wgpu::VertexBufferLayout {
      array_stride: std::mem::size_of::<TerrainVertex>() as wgpu::BufferAddress,
      step_mode: wgpu::VertexStepMode::Vertex,
      attributes: &[
        wgpu::VertexAttribute {
          offset: 0,
          shader_location: 0,
          format: wgpu::VertexFormat::Float32x3,
        },
        wgpu::VertexAttribute {
          offset: 12,
          shader_location: 1,
          format: wgpu::VertexFormat::Uint32,
        },
        wgpu::VertexAttribute {
          offset: 16,
          shader_location: 2,
          format: wgpu::VertexFormat::Float32x2,
        },
      ],
    }
  }
}

#[repr(C)]
#[derive(Copy, Clone, Debug)]
pub struct KyzuHeader
{
  pub magic: [u8; 4],
  pub version: u32,
  pub subdivision_level: u32,
  pub vertex_count: u32,
  pub padding: [u8; 1008],
}

unsafe impl Zeroable for KyzuHeader {}
unsafe impl Pod for KyzuHeader {}
