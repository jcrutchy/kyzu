use serde::{Deserialize, Serialize};

// ──────────────────────────────────────────────────────────────
//   Biome definition — one entry in biomes.json
// ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BiomeEntry
{
  pub id: u8,
  pub name: String,
  pub color: [u8; 3], // RGB
}

// ──────────────────────────────────────────────────────────────
//   World configuration — world.json
// ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorldConfig
{
  pub name: String,
  pub seed: u64,
  pub preset: WorldPreset,
  pub grid_resolution_km: f64,
  pub planet_radius_km: f64,
  pub subdivision_level: u32,
  pub baked_lod_levels: Vec<u32>,
  pub bake_version: u32,
}

// ──────────────────────────────────────────────────────────────
//   Generation presets
// ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum WorldPreset
{
  Continents,
  Archipelago,
  Alien,
}

// ──────────────────────────────────────────────────────────────
//   Binary file structs — shared between bake and game
//   repr(C) guarantees stable layout for memmap
// ──────────────────────────────────────────────────────────────

#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::Pod, bytemuck::Zeroable)]
pub struct TerrainVertex
{
  pub position: [f32; 3], // unit sphere position * planet radius
  pub hex_id: u32,        // index of parent hex center vertex
  pub elevation: i16,     // metres + 11000 offset (range -11000..+54535)
  pub biome_id: u8,       // index into biomes.json table
  pub _pad: u8,           // alignment
}

#[repr(C)]
#[derive(Clone, Copy, Debug, bytemuck::Pod, bytemuck::Zeroable)]
pub struct HexLogic
{
  pub biome_id: u8,
  pub move_cost: u8,  // 0-255, scaled movement cost
  pub elevation: i16, // metres + 11000 offset
  pub _pad: u32,
}
