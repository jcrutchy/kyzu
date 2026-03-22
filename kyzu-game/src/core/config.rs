use std::fs;

use serde::{Deserialize, Serialize};

// The only hardcoded bootstrap path allowed in the source
const BOOTSTRAP_PATH: &str = "C:\\dev\\kyzu_data\\engine_config.json";

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct AppConfig
{
  pub data_dir: String,
  pub log_filename: String,
  pub window_width: u32,
  pub window_height: u32,
  pub vsync_enabled: bool,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct WorldConfig
{
  pub seed: u64,
  pub chunk_size: u32,
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
  let file_content = fs::read_to_string(BOOTSTRAP_PATH);

  if let Err(e) = file_content
  {
    return Err(format!("Could not read bootstrap config at {}: {}", BOOTSTRAP_PATH, e));
  }

  let config: Result<KyzuConfig, serde_json::Error> = serde_json::from_str(&file_content.unwrap());

  if let Err(e) = config
  {
    return Err(format!("JSON parsing error in {}: {}", BOOTSTRAP_PATH, e));
  }

  Ok(config.unwrap())
}
