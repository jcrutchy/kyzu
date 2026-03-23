use std::collections::HashMap;

use glam::Vec3;

use crate::bake::geometry::{BakedVertex, SphericalMapper};
use crate::bake::tiff_reader::EtopoTiff;

pub struct Subdivider<'a>
{
  pub tiff: Option<&'a mut EtopoTiff>,
  pub midpoint_cache: HashMap<(u32, u32), u32>,
}

impl<'a> Subdivider<'a>
{
  pub fn new(tiff: Option<&'a mut EtopoTiff>) -> Self
  {
    Self { tiff, midpoint_cache: HashMap::new() }
  }

  /// Finds or creates a midpoint between two vertices and samples elevation from the TIFF
  pub fn get_midpoint(&mut self, v1_idx: u32, v2_idx: u32, vertices: &mut Vec<BakedVertex>) -> u32
  {
    // Ensure the key is consistent regardless of order (v1,v2 vs v2,v1)
    let key = if v1_idx < v2_idx { (v1_idx, v2_idx) } else { (v2_idx, v1_idx) };

    if let Some(&index) = self.midpoint_cache.get(&key)
    {
      return index;
    }

    // 1. Calculate 3D position on a unit sphere
    let p1 = Vec3::from_array(vertices[v1_idx as usize].pos);
    let p2 = Vec3::from_array(vertices[v2_idx as usize].pos);
    let new_pos = (p1 + p2).normalize();

    // 2. Map 3D vector to UV [0.0 - 1.0]
    let uv = SphericalMapper::vector_to_uv(new_pos);
    let mut height = 0.0;

    // 3. Sample from TIFF using the reader's cache
    if let Some(reader) = &mut self.tiff
    {
      // Convert UV to Pixel Coordinates with Clamping
      let px = (uv[0] * (reader.width as f32 - 1.0)).clamp(0.0, reader.width as f32 - 1.0) as usize;
      let py =
        (uv[1] * (reader.height as f32 - 1.0)).clamp(0.0, reader.height as f32 - 1.0) as usize;

      // Use the cached sampler
      // Note: We treat -32768 (NOAA NoData) as 0.0m (Sea Level)
      let raw_sample = reader.get_sample(px, py);
      height = if raw_sample == -32768 { 0.0 } else { raw_sample as f32 };
    }

    // 4. Create and store the new vertex
    let new_idx = vertices.len() as u32;
    vertices.push(BakedVertex {
      pos: new_pos.to_array(),
      normal: new_pos.to_array(),
      uv,
      height,
      hex_id: 0,
    });

    self.midpoint_cache.insert(key, new_idx);
    new_idx
  }
}
