use std::fs;

use serde::{Deserialize, Serialize};

// The only hardcoded bootstrap path allowed in the source
const BOOTSTRAP_PATH: &str = "C:\\dev\\kyzu_data\\engine_config.json";

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct AppConfig
{
  pub data_dir: String,
  pub worlds_subdir: String,
  pub selected_world: String,
  pub world_filename: String,
  pub log_filename: String,
  pub window_width: u32,
  pub window_height: u32,
  pub vsync_enabled: bool,
  pub test_mesh: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct WorldConfig
{
  pub name: String,
  pub bodies_registry: String,
  pub assets_subdir: String,
  pub baked_subdir: String,
  pub seed: u64,
  pub sea_level: f64,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct KyzuConfig
{
  pub app: AppConfig,
  pub world: WorldConfig,
}

pub fn load() -> Result<KyzuConfig, String>
{
  // 1. Load Bootstrap App Config
  let bootstrap_content =
    fs::read_to_string(BOOTSTRAP_PATH).map_err(|e| format!("Could not read bootstrap: {}", e))?;

  // We use a temporary struct or untyped JSON to get the App portion first
  let full_json: serde_json::Value =
    serde_json::from_str(&bootstrap_content).map_err(|e| format!("JSON Error: {}", e))?;

  let app: AppConfig = serde_json::from_value(full_json["app"].clone())
    .map_err(|e| format!("AppConfig missing: {}", e))?;

  // 2. Construct the path to the world.json
  // Logic: [data_dir] / [worlds_subdir] / [selected_world] / world.json
  let world_path = std::path::PathBuf::from(&app.data_dir)
    .join(&app.worlds_subdir)
    .join(&app.selected_world)
    .join(&app.world_filename);

  // 3. Load the World Manifest
  let world_content = fs::read_to_string(&world_path)
    .map_err(|e| format!("Could not read world.json at {:?}: {}", world_path, e))?;

  let world: WorldConfig =
    serde_json::from_str(&world_content).map_err(|e| format!("World JSON Error: {}", e))?;

  Ok(KyzuConfig { app, world })
}
