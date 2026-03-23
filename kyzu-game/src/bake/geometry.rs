use bytemuck::{Pod, Zeroable};

#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
pub struct BakedVertex
{
  pub pos: [f32; 3],
  pub normal: [f32; 3],
  pub uv: [f32; 2],
}

pub fn generate_icosahedron() -> (Vec<BakedVertex>, Vec<u16>)
{
  let phi = (1.0 + 5.0f32.sqrt()) / 2.0;
  let raw_verts: [[f32; 3]; 12] = [
    [-1.0, phi, 0.0],
    [1.0, phi, 0.0],
    [-1.0, -phi, 0.0],
    [1.0, -phi, 0.0],
    [0.0, -1.0, phi],
    [0.0, 1.0, phi],
    [0.0, -1.0, -phi],
    [0.0, 1.0, -phi],
    [phi, 0.0, -1.0],
    [phi, 0.0, 1.0],
    [-phi, 0.0, -1.0],
    [-phi, 0.0, 1.0],
  ];

  let mut vertices = Vec::new();
  for v in raw_verts
  {
    let normal = glam::Vec3::from(v).normalize();
    vertices.push(BakedVertex { pos: v, normal: normal.to_array(), uv: [0.0, 0.0] });
  }

  let indices = vec![
    0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1,
    8, 3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
  ];

  (vertices, indices)
}
