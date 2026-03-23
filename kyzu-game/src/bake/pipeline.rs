use std::fs;
use std::io::Write;
use crate::bake::geometry;
use crate::bake::EngineConfig;

pub fn run_core_bake(config: EngineConfig) -> std::io::Result<()> 
{
  // Ensure directories exist
  fs::create_dir_all(&config.asset_path)?;
  fs::create_dir_all(&config.data_path)?;

  // 1. Generate the base icosahedron
  let (vertices, indices) = geometry::generate_icosahedron();

  // 2. Prepare the file path (universal asset)
  let mut path = std::path::PathBuf::from(config.asset_path);
  path.push("icosahedron.bake");

  // 3. Write binary data
  let mut file = fs::File::create(path)?;
  
  // Header: vertex count, index count
  file.write_all(bytemuck::bytes_of(&(vertices.len() as u32)))?;
  file.write_all(bytemuck::bytes_of(&(indices.len() as u32)))?;
  
  // Data
  file.write_all(bytemuck::cast_slice(&vertices))?;
  file.write_all(bytemuck::cast_slice(&indices))?;

  println!("Bake Pipeline: Icosahedron saved to assets/");
  Ok(())
}
