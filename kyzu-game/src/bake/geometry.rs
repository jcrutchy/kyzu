use std::f32::consts::PI;

use bytemuck::{Pod, Zeroable};
use glam::Vec3;

#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
pub struct BakedVertex
{
  /// Position in Unit Sphere Space (normalized vector from center).
  /// To get World Space coordinates, multiply this by the planet's radius.
  pub pos: [f32; 3],
  /// Normalized surface normal.
  pub normal: [f32; 3],
  /// UV coordinates for texture mapping (0.0 to 1.0).
  pub uv: [f32; 2],
  pub height: f32, // Elevation in metres (from ETOPO)
  pub hex_id: u32, // The ID of the hex cell this vertex belongs to
  pub barycentric: [f32; 3],
}

pub struct SphericalMapper;

impl SphericalMapper
{
  /// Maps a unit vector to (u, v) [0, 1] for sampling TIFFs/Images
  /// Assumes +Y is the North Pole
  pub fn vector_to_uv(v: Vec3) -> [f32; 2]
  {
    // Latitude: -PI/2 to PI/2 (Y is vertical)
    let lat = v.y.asin();
    // Longitude: -PI to PI
    let lon = v.z.atan2(v.x);

    // Normalize to [0, 1] for TIFF sampling
    // U = 0.5 at Lon 0, V = 0 at North Pole (+Y), V = 1 at South Pole (-Y)
    let u = (lon + PI) / (2.0 * PI);
    let v_coord = (PI / 2.0 - lat) / PI;

    [u, v_coord]
  }
}

pub fn get_base_icosahedron() -> (Vec<BakedVertex>, Vec<u16>)
{
  let phi = (1.0 + 5.0f32.sqrt()) / 2.0;

  // Seed vertices (normalized to radius 1.0)
  let raw_verts: [Vec3; 12] = [
    Vec3::new(-1.0, phi, 0.0).normalize(),
    Vec3::new(1.0, phi, 0.0).normalize(),
    Vec3::new(-1.0, -phi, 0.0).normalize(),
    Vec3::new(1.0, -phi, 0.0).normalize(),
    Vec3::new(0.0, -1.0, phi).normalize(),
    Vec3::new(0.0, 1.0, phi).normalize(),
    Vec3::new(0.0, -1.0, -phi).normalize(),
    Vec3::new(0.0, 1.0, -phi).normalize(),
    Vec3::new(phi, 0.0, -1.0).normalize(),
    Vec3::new(phi, 0.0, 1.0).normalize(),
    Vec3::new(-phi, 0.0, -1.0).normalize(),
    Vec3::new(-phi, 0.0, 1.0).normalize(),
  ];

  let mut vertices = Vec::with_capacity(12);
  for v in raw_verts
  {
    let uv = SphericalMapper::vector_to_uv(v);

    vertices.push(BakedVertex {
      pos: v.to_array(),
      normal: v.to_array(),
      uv,
      height: 0.0, // This will be sampled from the TIFF later
      hex_id: 0,
      barycentric: [0.0, 0.0, 0.0],
    });
  }

  let indices = vec![
    0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1,
    8, 3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
  ];

  (vertices, indices)
}
