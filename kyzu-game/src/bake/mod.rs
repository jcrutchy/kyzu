pub mod geometry;
pub mod registry;
pub mod subdivider;
pub mod tiff_reader;

use std::fs;
use std::path::PathBuf;

use crate::bake::registry::{load_bodies, BodyConfig};
use crate::bake::subdivider::Subdivider;
use crate::bake::tiff_reader::EtopoTiff;
use crate::core::config::KyzuConfig; // Ensure this matches your project structure
use crate::core::log::{LogLevel, Logger};

pub struct BakeManager
{
  /// Root data directory from AppConfig
  pub data_dir: PathBuf,
  /// Path to the specific world folder (e.g., .../worlds/sol_system/)
  pub world_root: PathBuf,
  /// Path to the baked output folder for the active world
  pub output_root: PathBuf,
  /// Path to global primitives (like the test icosahedron)
  pub primitives_root: PathBuf,
  /// Source assets path (remains relative to data_dir for now)
  pub source_assets: PathBuf,
}

impl BakeManager
{
  pub fn new(config: &KyzuConfig) -> Self
  {
    let data_dir = PathBuf::from(&config.app.data_dir);

    let world_root = data_dir.join(&config.app.worlds_subdir).join(&config.app.selected_world);

    let output_root = world_root.join(&config.world.baked_subdir);
    let source_assets = world_root.join(&config.world.assets_subdir);

    // Derive primitives folder from the test_mesh path in config
    let test_mesh_path = PathBuf::from(&config.app.test_mesh);
    let primitives_root =
      data_dir.join(test_mesh_path.parent().unwrap_or(&PathBuf::from("primitives")));

    Self { data_dir, world_root, output_root, primitives_root, source_assets }
  }

  pub fn start_bake(&self, logger: &mut Logger)
  {
    logger.emit(LogLevel::Info, "Starting system-wide bake...");
    let _ = fs::create_dir_all(&self.output_root);
    let _ = fs::create_dir_all(&self.primitives_root);

    if let Err(e) = self.cook_all(logger)
    {
      logger.emit(LogLevel::Error, &format!("Bake failed: {}", e));
    }
  }

  fn cook_all(&self, logger: &mut Logger) -> anyhow::Result<()>
  {
    // 1. Bake the reference icosahedron to the primitives directory
    let (v_raw, i_raw) = geometry::get_base_icosahedron();
    let base_indices: Vec<u32> = i_raw.into_iter().map(|i| i as u32).collect();

    let iso_path = self.primitives_root.join("icosahedron.bake");
    self.save_bake_to_disk(iso_path.to_str().unwrap(), &v_raw, &base_indices)?;
    logger.emit(LogLevel::Info, &format!("Baked Reference Icosahedron to {:?}", iso_path));

    // 2. Load the bodies registry relative to the world root
    let registry_path = self.world_root.join("bodies.json");
    let registry = load_bodies(&registry_path)?;

    for body in &registry.bodies
    {
      self.cook_body(body, logger)?;
    }
    Ok(())
  }

  fn cook_body(&self, body: &BodyConfig, logger: &mut Logger) -> anyhow::Result<()>
  {
    logger.emit(LogLevel::Info, &format!("Baking Body: {}", body.name));

    let mut tiff_reader = None;
    if body.use_real_data
    {
      if let Some(filename) = &body.elevation_map_path
      {
        let tiff_path = self.source_assets.join(body.name.to_lowercase()).join(filename);

        let reader_result = EtopoTiff::open(&tiff_path, logger);

        // If it "bailed", log it as a Critical error before returning
        match reader_result
        {
          Ok(reader) =>
          {
            tiff_reader = Some(reader);
          }
          Err(e) =>
          {
            let err_msg = format!("TIFF initialization failed for {}: {}", body.name, e);
            logger.emit(LogLevel::Critical, &err_msg);
            return Err(e); // Still return the error to stop the bake
          }
        }
      }
    }

    // 1. Base Geometry
    let (vertices_raw, indices_raw) = geometry::get_base_icosahedron();
    let mut vertices = vertices_raw;
    let mut indices: Vec<u32> = indices_raw.into_iter().map(|i| i as u32).collect();

    // 2. Probing & Initial Sampling
    if let Some(reader) = tiff_reader.as_mut()
    {
      logger.emit(LogLevel::Info, &format!("Probing TIFF: {:?}", reader.path));

      // Initial 12 vertices sampling
      for v in &mut vertices
      {
        let px =
          (v.uv[0] * (reader.width as f32 - 1.0)).clamp(0.0, reader.width as f32 - 1.0) as usize;
        let py =
          (v.uv[1] * (reader.height as f32 - 1.0)).clamp(0.0, reader.height as f32 - 1.0) as usize;
        v.height = reader.get_sample(px, py) as f32;
      }
    }

    // 3. Subdivide
    let mut subdivider = Subdivider::new(tiff_reader.as_mut());
    let lod_level = 3;
    logger.emit(LogLevel::Info, &format!("Baking: Subdividing to Level {}...", lod_level));

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
    logger.emit(LogLevel::Info, &format!("Bake Complete: {} vertices.", vertices.len()));

    // 4. Save to the world-specific baked folder
    let file_name = format!("{}.bake", body.name.to_lowercase());
    let output_path = self.output_root.join(file_name);

    self.save_bake_to_disk(output_path.to_str().unwrap(), &vertices, &indices)?;
    logger.emit(LogLevel::Info, &format!("[DONE] Baked {} to {:?}", body.name, output_path));

    Ok(())
  }

  fn save_bake_to_disk(
    &self,
    path: &str,
    vertices: &[geometry::BakedVertex],
    indices: &[u32],
  ) -> anyhow::Result<()>
  {
    use std::fs::File;
    use std::io::{BufWriter, Write};

    let file = File::create(path)?;
    let mut writer = BufWriter::new(file);

    // Header: Vertex Count
    writer.write_all(&(vertices.len() as u32).to_le_bytes())?;
    // Vertex Data
    writer.write_all(bytemuck::cast_slice(vertices))?;
    // Index Count
    writer.write_all(&(indices.len() as u32).to_le_bytes())?;
    // Index Data
    writer.write_all(bytemuck::cast_slice(indices))?;

    writer.flush()?;
    Ok(())
  }
}
