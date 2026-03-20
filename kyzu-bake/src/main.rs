use std::fs;
use std::io::Write;
use std::path::Path;

use bytemuck::cast_slice;
use glam::Vec3;
use kyzu_core::{KyzuHeader, TerrainVertex, ICOSA_INDICES, ICOSA_VERTICES};
use noise::{Fbm, NoiseFn, Perlin}; // New imports

fn main() -> anyhow::Result<()>
{
  let world_dir = "C:\\dev\\kyzu_data\\worlds";
  let file_path = "C:\\dev\\kyzu_data\\worlds\\terrain.bin";
  let subdivision_level = 4; // Bumped to 4 for better noise resolution

  if !Path::new(world_dir).exists()
  {
    fs::create_dir_all(world_dir)?;
  }

  // 1. Initial icosahedron
  let mut triangles: Vec<[Vec3; 3]> = ICOSA_INDICES
    .iter()
    .map(|&idx| {
      [
        ICOSA_VERTICES[idx[0] as usize],
        ICOSA_VERTICES[idx[1] as usize],
        ICOSA_VERTICES[idx[2] as usize],
      ]
    })
    .collect();

  // 2. Subdivide
  for _ in 0..subdivision_level
  {
    let mut next_gen = Vec::new();
    for tri in triangles
    {
      let ab = (tri[0] + tri[1]).normalize();
      let bc = (tri[1] + tri[2]).normalize();
      let ca = (tri[2] + tri[0]).normalize();

      next_gen.push([tri[0], ab, ca]);
      next_gen.push([tri[1], bc, ab]);
      next_gen.push([tri[2], ca, bc]);
      next_gen.push([ab, bc, ca]);
    }
    triangles = next_gen;
  }

  // 3. Apply Noise Displacement
  let fbm = Fbm::<Perlin>::new(42); // Seed 42
  let mut vertices = Vec::new();
  let bary_coords = [[1.0, 0.0], [0.0, 1.0], [0.0, 0.0]];

  for tri in triangles
  {
    for i in 0..3
    {
      let pos = tri[i];

      // Sample noise using the 3D position
      // fbm.get inputs are [f64; 3]
      let val = fbm.get([pos.x as f64, pos.y as f64, pos.z as f64]) as f32;

      // Displace the vertex.
      // We keep a base radius of 1.0 and add a 15% max displacement for mountains.
      let displacement = 1.0 + (val * 0.15);
      let final_pos = pos * displacement;

      vertices.push(TerrainVertex { pos: final_pos.to_array(), hex_id: 0, bary: bary_coords[i] });
    }
  }

  let header = KyzuHeader {
    magic: *b"KYZU",
    version: 1,
    subdivision_level: subdivision_level as u32,
    vertex_count: vertices.len() as u32,
    padding: [0; 1008],
  };

  let mut file = fs::File::create(file_path)?;
  file.write_all(cast_slice(&[header]))?;
  file.write_all(cast_slice(&vertices))?;

  println!(
    "Baked Level {} world with {} vertices and Noise displacement.",
    subdivision_level,
    vertices.len()
  );
  Ok(())
}
