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
    if body.use_real_data && body.elevation_map_path.is_some()
    {
      let filename = body.elevation_map_path.as_ref().unwrap();
      let tiff_path = self.source_assets.join(body.name.to_lowercase()).join(filename);
      tiff_reader = Some(EtopoTiff::open(&tiff_path, logger)?);
    }

    // 1. Initial Geometry
    let (mut vertices, indices) = geometry::get_base_icosahedron();
    let mut indices: Vec<u32> = indices.into_iter().map(|i| i as u32).collect();

    // 2. Subdivide (Indexed Mode - efficient for math)
    let mut subdivider = Subdivider::new(tiff_reader.as_mut());
    let lod_level = 3; // Start here, move to 7 or 8 once TIFF is cached

    logger.emit(LogLevel::Info, &format!("Subdividing to Level {}...", lod_level));

    for _ in 0..lod_level
    {
      let mut next_indices = Vec::with_capacity(indices.len() * 4);
      for chunk in indices.chunks(3)
      {
        let (v1, v2, v3) = (chunk[0], chunk[1], chunk[2]);

        let a = subdivider.get_midpoint(v1, v2, &mut vertices);
        let b = subdivider.get_midpoint(v2, v3, &mut vertices);
        let c = subdivider.get_midpoint(v3, v1, &mut vertices);

        next_indices.extend_from_slice(&[v1, a, c]);
        next_indices.extend_from_slice(&[v2, b, a]);
        next_indices.extend_from_slice(&[v3, c, b]);
        next_indices.extend_from_slice(&[a, b, c]);
      }
      indices = next_indices;
    }

    // 3. Unweld & Assign Barycentrics (Non-Indexed Mode)
    // This allows for the "Kyzu" wireframe look by giving each triangle unique vertices.
    logger.emit(LogLevel::Info, "Unwelding vertices for barycentric wireframes...");
    let mut flat_vertices = Vec::with_capacity(indices.len());

    for (i, &idx) in indices.iter().enumerate()
    {
      let mut v = vertices[idx as usize].clone();

      // Assign [1,0,0], [0,1,0], or [0,0,1] based on the corner of the triangle
      let corner = i % 3;
      v.barycentric = match corner
      {
        0 => [1.0, 0.0, 0.0],
        1 => [0.0, 1.0, 0.0],
        _ => [0.0, 0.0, 1.0],
      };

      flat_vertices.push(v);
    }

    // 4. Save to Disk
    let file_name = format!("{}.bake", body.name.to_lowercase());
    let output_path = self.output_root.join(file_name);

    // Note: We pass an empty slice for indices because the mesh is now non-indexed
    self.save_bake_to_disk(output_path.to_str().unwrap(), &flat_vertices, &[])?;

    logger.emit(
      LogLevel::Info,
      &format!("[DONE] Baked {} ({} triangles)", body.name, flat_vertices.len() / 3),
    );

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
