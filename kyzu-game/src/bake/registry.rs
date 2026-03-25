use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BodyConfig
{
  pub name: String,
  #[serde(default)]
  pub parent: Option<String>,
  pub radius_km: f32,
  pub orbit_radius_km: f32,
  #[serde(default)]
  pub orbital_eccentricity: f32,
  #[serde(default)]
  pub orbital_inclination_deg: f32,
  #[serde(default)]
  pub start_angle_rad: f32,
  #[serde(default)]
  pub axial_tilt_deg: f32,
  pub rotation_period_hours: f32,
  pub color: [f32; 4],
  pub lod_max: u8,
  pub target_res_km: f32,
  pub is_star: bool,
  #[serde(default)]
  pub has_atmosphere: bool,
  #[serde(default)]
  pub use_real_data: bool,
  #[serde(default)]
  pub elevation_map_path: Option<String>,
  #[serde(default)]
  pub land_cover_map_path: Option<String>,
  #[serde(default)]
  pub climate_data_path: Option<String>,
  #[serde(default)]
  pub water_mask_path: Option<String>,
  #[serde(default)]
  pub calc_slopes: bool,
  #[serde(default)]
  pub calc_flow_directions: bool,
  #[serde(default)]
  pub generate_roughness: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BodyRegistry
{
  pub bodies: Vec<BodyConfig>,
}

pub fn load_bodies(path: &PathBuf) -> anyhow::Result<BodyRegistry>
{
  let content = fs::read_to_string(path)?;
  let registry: BodyRegistry = serde_json::from_str(&content)?;
  Ok(registry)
}
