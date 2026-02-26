use wgpu::util::DeviceExt;

pub struct CubeMesh
{
  pub vertex_buffer: wgpu::Buffer,
  pub index_buffer: wgpu::Buffer,
  pub index_count: u32,
}

impl CubeMesh
{
  pub fn create(device: &wgpu::Device) -> Self
  {
    // 8 unique corners, Z-up right-hand rule
    // Z- = bottom face, Z+ = top face
    let vertices: [[f32; 3]; 8] = [
      [-1.0, -1.0, -1.0], // 0 bottom
      [1.0, -1.0, -1.0],  // 1
      [1.0, 1.0, -1.0],   // 2
      [-1.0, 1.0, -1.0],  // 3
      [-1.0, -1.0, 1.0],  // 4 top
      [1.0, -1.0, 1.0],   // 5
      [1.0, 1.0, 1.0],    // 6
      [-1.0, 1.0, 1.0],   // 7
    ];

    #[rustfmt::skip]
    let indices: [u16; 36] = [
      0, 1, 2,  0, 2, 3,  // bottom  (Z-)
      4, 5, 6,  4, 6, 7,  // top     (Z+)
      0, 1, 5,  0, 5, 4,  // front   (Y-)
      2, 3, 7,  2, 7, 6,  // back    (Y+)
      1, 2, 6,  1, 6, 5,  // right   (X+)
      3, 0, 4,  3, 4, 7,  // left    (X-)
    ];

    let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
      label: Some("Cube Vertex Buffer"),
      contents: bytemuck::cast_slice(&vertices),
      usage: wgpu::BufferUsages::VERTEX,
    });

    let index_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
      label: Some("Cube Index Buffer"),
      contents: bytemuck::cast_slice(&indices),
      usage: wgpu::BufferUsages::INDEX,
    });

    Self { vertex_buffer, index_buffer, index_count: indices.len() as u32 }
  }
}
