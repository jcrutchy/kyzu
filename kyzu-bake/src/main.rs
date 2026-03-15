mod bake;
mod heightmap;
mod icosahedron;
mod progress;

use std::path::Path;

use kyzu_core::{WorldConfig, WorldPreset};

fn main()
{
  progress::info("kyzu-bake starting");

  let config = WorldConfig {
    name: "Test World".to_string(),
    seed: 12345,
    preset: WorldPreset::Continents,
    grid_resolution_km: 150.0,
    planet_radius_km: 6371.0,
    subdivision_level: 8,
    baked_lod_levels: vec![4, 6, 8, 10], // add level 10
    bake_version: 1,
  };

  let output_dir = Path::new(r"C:\dev\kyzu_data\worlds\test_continents");

  if let Err(e) = bake::bake(&config, output_dir)
  {
    progress::error(&format!("Bake failed: {}", e));
    std::process::exit(1);
  }

  let world_dir = Path::new(r"C:\dev\kyzu_data\worlds\test_continents");
  verify_bin(&world_dir.join("terrain_l4.bin"));
  verify_bin(&world_dir.join("terrain_l6.bin"));
  verify_bin(&world_dir.join("terrain_l8.bin"));
}

fn verify_bin(path: &Path)
{
  let bytes = std::fs::read(path).unwrap();
  let magic = u32::from_le_bytes(bytes[0..4].try_into().unwrap());
  let level = u32::from_le_bytes(bytes[4..8].try_into().unwrap());
  let verts = u64::from_le_bytes(bytes[8..16].try_into().unwrap());
  let faces = u64::from_le_bytes(bytes[16..24].try_into().unwrap());
  println!(
    "[INFO] {:?} magic={:#010x} level={} verts={} faces={}",
    path.file_name().unwrap(),
    magic,
    level,
    verts,
    faces
  );
}
