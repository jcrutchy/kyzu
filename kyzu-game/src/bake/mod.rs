pub mod geometry;
pub mod registry;
pub mod subdivider;
pub mod tiff_reader;

use std::path::PathBuf;

use crate::bake::registry::{load_bodies, BodyConfig};
use crate::bake::subdivider::Subdivider;
use crate::bake::tiff_reader::EtopoTiff;

pub struct BakeManager
{
  pub world_root: PathBuf,
  pub source_assets: PathBuf,
  pub output_root: PathBuf,
}

impl BakeManager
{
  pub fn new() -> Self
  {
    Self {
      world_root: PathBuf::from("C:/dev/kyzu_data/worlds/sol_system/"),
      source_assets: PathBuf::from("C:/dev/kyzu_data/source_assets/earth/"),
      output_root: PathBuf::from("assets/baked/"),
    }
  }

  pub fn start_bake(&self)
  {
    if let Err(e) = self.cook_all()
    {
      eprintln!("[BAKE ERROR] {}", e);
    }
  }

  fn cook_all(&self) -> anyhow::Result<()>
  {
    let registry = load_bodies(&self.world_root.join("bodies.json"))?;
    for body in &registry.bodies
    {
      self.cook_body(body)?;
    }
    Ok(())
  }

  fn cook_body(&self, body: &BodyConfig) -> anyhow::Result<()>
  {
    println!("--- Baking Body: {} ---", body.name);

    let mut tiff_reader = None;
    if body.use_real_data
    {
      if let Some(filename) = &body.elevation_map_path
      {
        let tiff_path = self.source_assets.join(filename);
        tiff_reader = Some(EtopoTiff::open(&tiff_path)?);
      }
    }

    // 1. Start with the base icosahedron
    let (vertices_raw, indices_raw) = geometry::get_base_icosahedron();
    let mut vertices = vertices_raw;
    let mut indices: Vec<u32> = indices_raw.into_iter().map(|i| i as u32).collect();

    // 2. Direct Reader Access (Probing & Base Vertex Sampling)
    // We do this in a single block so the borrow is released before the subdivider starts.
    if let Some(reader) = tiff_reader.as_mut()
    {
      println!("--- PROBING TIFF DATA ---");
      let test_points = [
        ("Australia (Alice Springs)", [0.87, 0.65]),
        ("Himalayas (Everest-ish)", [0.74, 0.32]),
        ("Ocean (Pacific)", [0.10, 0.50]),
      ];
      // In src/bake/mod.rs Probing block
      for (name, uv) in test_points
      {
        let px = (uv[0] * (reader.width as f32 - 1.0)) as usize;
        let py = (uv[1] * (reader.height as f32 - 1.0)) as usize;

        // Convert UV back to Lon/Lat for debugging
        let lon = uv[0] * 360.0 - 180.0;
        let lat = 90.0 - uv[1] * 180.0;

        let val = reader.get_sample(px, py);
        println!(
          "{}: UV {:?} (Lon: {:.2}, Lat: {:.2}) -> Pixel [{}, {}] -> Value: {}m",
          name, uv, lon, lat, px, py, val
        );
      }

      // Correctly sample the height for the initial 12 vertices
      for v in &mut vertices
      {
        let px =
          (v.uv[0] * (reader.width as f32 - 1.0)).clamp(0.0, reader.width as f32 - 1.0) as usize;
        let py =
          (v.uv[1] * (reader.height as f32 - 1.0)).clamp(0.0, reader.height as f32 - 1.0) as usize;
        v.height = reader.get_sample(px, py) as f32;
      }
      println!("-------------------------");
    }

    // 3. Subdivide
    // The subdivider now takes the ONLY mutable borrow of tiff_reader
    let mut subdivider = Subdivider::new(tiff_reader.as_mut());

    let lod_level = 3;
    println!("Baking: Subdividing to Level {}...", lod_level);

    for _ in 0..lod_level
    {
      let mut new_indices = Vec::new();
      for chunk in indices.chunks(3)
      {
        let v1 = chunk[0];
        let v2 = chunk[1];
        let v3 = chunk[2];

        let a = subdivider.get_midpoint(v1, v2, &mut vertices);
        let b = subdivider.get_midpoint(v2, v3, &mut vertices);
        let c = subdivider.get_midpoint(v3, v1, &mut vertices);

        new_indices.extend_from_slice(&[v1, a, c]);
        new_indices.extend_from_slice(&[v2, b, a]);
        new_indices.extend_from_slice(&[v3, c, b]);
        new_indices.extend_from_slice(&[a, b, c]);
      }
      indices = new_indices;
    }

    // 4. Stats & Verification
    let land_count = vertices.iter().filter(|v| v.height > 0.0).count();
    let mut max_h = -10000.0;
    let mut suspicious_uv = [0.0, 0.0];

    for v in &vertices
    {
      if v.height > max_h
      {
        max_h = v.height;
        suspicious_uv = v.uv;
      }
    }

    println!("Bake Complete: {} vertices ({} land hits).", vertices.len(), land_count);
    println!("Max height: {}m found at UV: [{}, {}]", max_h, suspicious_uv[0], suspicious_uv[1]);

    Ok(())
  }
}
