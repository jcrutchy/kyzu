use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

// The only hardcoded bootstrap path allowed in the source
const BOOTSTRAP_PATH: &str = "C:\\dev\\kyzu_data\\engine_config.json";

// Default game.json written on first run when no save exists yet
const DEFAULT_GAME_JSON: &str = r#"{
  "save_name": "New Game",
  "world": "sol_system",
  "game_time_seconds": 0.0,
  "autosave_interval_seconds": 300,
  "player_start_body": "earth"
}"#;

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
  pub saves_subdir: String,
  pub active_save: String,
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
pub struct SaveConfig
{
  pub save_name: String,
  pub world: String,
  pub game_time_seconds: f64,
  pub autosave_interval_seconds: u32,
  pub player_start_body: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct KyzuConfig
{
  pub app: AppConfig,
  pub world: WorldConfig,
  pub save: SaveConfig,
  // Derived paths — not deserialised, computed after loading
  #[serde(skip)]
  pub save_dir: PathBuf,
}

pub fn load() -> Result<KyzuConfig, String>
{
  // 1. Load bootstrap app config
  let bootstrap_content =
    fs::read_to_string(BOOTSTRAP_PATH).map_err(|e| format!("Could not read bootstrap: {}", e))?;

  let full_json: serde_json::Value =
    serde_json::from_str(&bootstrap_content).map_err(|e| format!("JSON error: {}", e))?;

  let app: AppConfig = serde_json::from_value(full_json["app"].clone())
    .map_err(|e| format!("AppConfig missing field: {}", e))?;

  // 2. Load world.json
  let world_path = PathBuf::from(&app.data_dir)
    .join(&app.worlds_subdir)
    .join(&app.selected_world)
    .join(&app.world_filename);

  let world_content = fs::read_to_string(&world_path)
    .map_err(|e| format!("Could not read world.json at {:?}: {}", world_path, e))?;

  let world: WorldConfig =
    serde_json::from_str(&world_content).map_err(|e| format!("World JSON error: {}", e))?;

  // 3. Resolve save directory and load (or create) game.json
  let save_dir = PathBuf::from(&app.data_dir).join(&app.saves_subdir).join(&app.active_save);

  let save = load_or_create_save(&save_dir, &app.selected_world)?;

  Ok(KyzuConfig { app, world, save, save_dir })
}

fn load_or_create_save(save_dir: &PathBuf, world_name: &str) -> Result<SaveConfig, String>
{
  let game_json_path = save_dir.join("game.json");

  if game_json_path.exists()
  {
    // Load existing save
    let content = fs::read_to_string(&game_json_path)
      .map_err(|e| format!("Could not read game.json at {:?}: {}", game_json_path, e))?;

    let save: SaveConfig =
      serde_json::from_str(&content).map_err(|e| format!("game.json parse error: {}", e))?;

    return Ok(save);
  }

  // No save found — create the directory structure and write defaults
  fs::create_dir_all(save_dir)
    .map_err(|e| format!("Could not create save dir {:?}: {}", save_dir, e))?;

  // Create the chunk override directory so the chunk reader can always
  // assume it exists without checking
  let chunks_dir = save_dir.join("chunks");
  fs::create_dir_all(&chunks_dir)
    .map_err(|e| format!("Could not create chunks dir {:?}: {}", chunks_dir, e))?;

  // Write default game.json, stamping the correct world name
  let default_content = DEFAULT_GAME_JSON.replace("sol_system", world_name);
  fs::write(&game_json_path, &default_content)
    .map_err(|e| format!("Could not write game.json: {}", e))?;

  let save: SaveConfig = serde_json::from_str(&default_content)
    .map_err(|e| format!("Default game.json parse error: {}", e))?;

  Ok(save)
}
