pub mod geometry;
pub mod registry;

use std::path::PathBuf;

use crate::bake::registry::{load_bodies, BodyRegistry};

pub struct Kitchen
{
  pub world_root: PathBuf,
  pub output_root: PathBuf,
  pub registry: BodyRegistry,
}

impl Kitchen
{
  pub fn init(world_path: &str, output_path: &str) -> anyhow::Result<Self>
  {
    let world_root = PathBuf::from(world_path);
    let output_root = PathBuf::from(output_path);

    // Ensure output exists
    if !output_root.exists()
    {
      fs::create_dir_all(&output_root)?;
    }

    let bodies_json = world_root.join("bodies.json");
    let registry = load_bodies(&bodies_json)?;

    Ok(Self { world_root, output_root, registry })
  }

  pub fn cook_all(&self)
  {
    for body in &self.registry.bodies
    {
      println!("Cooking: {}", body.name);
      // This is where we'll call the subdivider and exporter
    }
  }
}
