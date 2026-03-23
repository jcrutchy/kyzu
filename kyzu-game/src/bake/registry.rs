use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BodyConfig
{
  pub name: String,
  pub parent: Option<String>,
  pub radius_km: f32,
  pub orbit_radius_km: f32,
  pub orbital_eccentricity: f32,
  pub orbital_inclination_deg: f32,
  pub start_angle_rad: f32,
  pub axial_tilt_deg: f32,
  pub rotation_period_hours: f32,
  pub color: [f32; 4],
  pub lod_max: u8,
  pub target_res_km: f32,
  pub is_star: bool,
  pub has_atmosphere: bool,
  pub use_real_data: bool,
  pub elevation_map_path: Option<String>,
  pub land_cover_map_path: Option<String>,
  pub climate_data_path: Option<String>,
  pub water_mask_path: Option<String>,
  pub calc_slopes: bool,
  pub calc_flow_directions: bool,
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
