use std::path::{Path, PathBuf};

use serde::Deserialize;

// ──────────────────────────────────────────────────────────────
//   Config structs
// ──────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct KyzuConfig
{
  pub data: DataConfig,
  pub startup: StartupConfig,
}

#[derive(Debug, Deserialize)]
pub struct DataConfig
{
  pub etopo_30s: PathBuf,
}

#[derive(Debug, Deserialize)]
pub struct StartupConfig
{
  pub bbox: BboxConfig,
  pub camera: CameraConfig,
}

#[derive(Debug, Deserialize, Clone, Copy)]
pub struct BboxConfig
{
  pub min_lat: f64,
  pub max_lat: f64,
  pub min_lon: f64,
  pub max_lon: f64,
}

#[derive(Debug, Deserialize, Clone, Copy)]
pub struct CameraConfig
{
  pub target_lat: f64,
  pub target_lon: f64,
  pub radius: f64,
}

// ──────────────────────────────────────────────────────────────
//   Loader
//
//   Looks for kyzu.json in these locations, in order:
//     1. Alongside the executable
//     2. Current working directory
//     3. Path explicitly provided (for tests)
// ──────────────────────────────────────────────────────────────

const CONFIG_FILENAME: &str = "kyzu.json";

pub fn load() -> anyhow::Result<KyzuConfig>
{
  let candidates = [
    // Next to the exe
    std::env::current_exe().ok().and_then(|p| p.parent().map(|d| d.join(CONFIG_FILENAME))),
    // Working directory
    Some(PathBuf::from(CONFIG_FILENAME)),
  ];

  for candidate in candidates.iter().flatten()
  {
    if candidate.exists()
    {
      log::info!("Loading config from {}", candidate.display());
      return load_from(candidate);
    }
  }

  anyhow::bail!("Could not find {}. Looked next to exe and in working directory.", CONFIG_FILENAME)
}

pub fn load_from(path: &Path) -> anyhow::Result<KyzuConfig>
{
  let text = std::fs::read_to_string(path)?;
  let config: KyzuConfig = serde_json::from_str(&text)?;
  validate(&config)?;
  Ok(config)
}

fn validate(config: &KyzuConfig) -> anyhow::Result<()>
{
  if !config.data.etopo_30s.exists()
  {
    anyhow::bail!("etopo_30s path does not exist: {}", config.data.etopo_30s.display());
  }

  let b = &config.startup.bbox;
  if b.min_lat >= b.max_lat
  {
    anyhow::bail!("bbox min_lat must be less than max_lat");
  }
  if b.min_lon >= b.max_lon
  {
    anyhow::bail!("bbox min_lon must be less than max_lon");
  }
  if b.min_lat < -90.0 || b.max_lat > 90.0
  {
    anyhow::bail!("bbox latitudes must be in [-90, 90]");
  }
  if b.min_lon < -180.0 || b.max_lon > 180.0
  {
    anyhow::bail!("bbox longitudes must be in [-180, 180]");
  }

  Ok(())
}
