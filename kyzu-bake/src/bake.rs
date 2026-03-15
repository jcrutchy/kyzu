use std::fs;
use std::io::{BufWriter, Write};
use std::path::Path;

use glam::DVec3;
use kyzu_core::{BiomeEntry, HexLogic, TerrainVertex, WorldConfig};

use crate::heightmap::HeightSampler;
use crate::icosahedron;

// ──────────────────────────────────────────────────────────────
//   Elevation encoding — metres + 11000 offset, stored as i16
// ──────────────────────────────────────────────────────────────

const ELEVATION_OFFSET: f64 = 11000.0;

fn encode_elevation(metres: f64) -> i16
{
  (metres + ELEVATION_OFFSET).clamp(i16::MIN as f64, i16::MAX as f64) as i16
}

// ──────────────────────────────────────────────────────────────
//   Biome assignment from elevation
// ──────────────────────────────────────────────────────────────

fn elevation_to_biome(metres: f64) -> u8
{
  if metres <= -200.0
  {
    0
  }
  // Deep Ocean
  else if metres <= 0.0
  {
    1
  }
  // Shallow Ocean
  else if metres <= 50.0
  {
    2
  }
  // Coast
  else if metres <= 500.0
  {
    3
  }
  // Lowland
  else if metres <= 2000.0
  {
    4
  }
  // Highland
  else if metres <= 4000.0
  {
    5
  }
  // Mountain
  else
  {
    6
  } // Ice Cap
}

// ──────────────────────────────────────────────────────────────
//   Default biome table
// ──────────────────────────────────────────────────────────────

pub fn default_biomes() -> Vec<BiomeEntry>
{
  vec![
    BiomeEntry { id: 0, name: "Deep Ocean".into(), color: [0, 30, 80] },
    BiomeEntry { id: 1, name: "Shallow Ocean".into(), color: [0, 80, 140] },
    BiomeEntry { id: 2, name: "Coast".into(), color: [210, 195, 140] },
    BiomeEntry { id: 3, name: "Lowland".into(), color: [80, 130, 60] },
    BiomeEntry { id: 4, name: "Highland".into(), color: [100, 90, 60] },
    BiomeEntry { id: 5, name: "Mountain".into(), color: [160, 155, 150] },
    BiomeEntry { id: 6, name: "Ice Cap".into(), color: [240, 245, 255] },
  ]
}

pub fn alien_biomes() -> Vec<BiomeEntry>
{
  vec![
    BiomeEntry { id: 0, name: "Void Sea".into(), color: [20, 0, 40] },
    BiomeEntry { id: 1, name: "Shallow Void".into(), color: [60, 0, 80] },
    BiomeEntry { id: 2, name: "Dust Shore".into(), color: [180, 100, 40] },
    BiomeEntry { id: 3, name: "Fungal Plain".into(), color: [40, 160, 80] },
    BiomeEntry { id: 4, name: "Crust Ridge".into(), color: [160, 80, 20] },
    BiomeEntry { id: 5, name: "Spike Peak".into(), color: [220, 60, 200] },
    BiomeEntry { id: 6, name: "Crystal Cap".into(), color: [180, 240, 255] },
  ]
}

// ──────────────────────────────────────────────────────────────
//   Hex ID assignment
//   In a subdivided icosahedron, each interior vertex with 6
//   surrounding triangles is a hex center. The 12 base vertices
//   (indices 0-11) are pentagon centers.
//   We assign hex_id = index of the nearest base vertex neighbor
//   for each triangle vertex, using the centroid approach.
// ──────────────────────────────────────────────────────────────

fn assign_hex_ids(vertices: &[DVec3], _faces: &[[usize; 3]]) -> Vec<u32>
{
  // For each vertex, find which of the 12 base icosahedron
  // vertices it is closest to — that's its hex region.
  // This gives us coarse hex assignment at any subdivision level.
  //
  // For game-scale hex assignment (one hex per ~150km cell)
  // we use the vertex's own index as its hex_id since at the
  // target subdivision level each vertex IS a hex center.

  // Simple approach: vertex index IS the hex_id.
  // The renderer uses this to group triangles into hex cells.
  // Each face's three vertices may have different hex_ids —
  // the face belongs to whichever hex_id its centroid is closest to.

  let mut hex_ids = vec![0u32; vertices.len()];
  for (i, _) in vertices.iter().enumerate()
  {
    hex_ids[i] = i as u32;
  }
  hex_ids
}

// ──────────────────────────────────────────────────────────────
//   Pad writer to 256-byte boundary
// ──────────────────────────────────────────────────────────────

fn pad_to_256<W: Write>(writer: &mut W, bytes_written: usize) -> std::io::Result<usize>
{
  let remainder = bytes_written % 256;
  if remainder != 0
  {
    let padding = 256 - remainder;
    let zeroes = vec![0u8; padding];
    writer.write_all(&zeroes)?;
    return Ok(padding);
  }
  Ok(0)
}

// ──────────────────────────────────────────────────────────────
//   Main bake entry point
// ──────────────────────────────────────────────────────────────

pub fn bake(config: &WorldConfig, output_dir: &Path) -> anyhow::Result<()>
{
  fs::create_dir_all(output_dir)?;

  let sampler = HeightSampler::new(config.seed as u32, config.preset.clone());

  let biomes = match config.preset
  {
    kyzu_core::WorldPreset::Alien => alien_biomes(),
    _ => default_biomes(),
  };

  // ── Write biomes.json ────────────────────────────────────────
  {
    let path = output_dir.join("biomes.json");
    let json = serde_json::to_string_pretty(&biomes)?;
    fs::write(&path, json)?;
    println!("[DONE] Wrote biomes.json ({} biomes)", biomes.len());
  }

  // ── Write world.json ─────────────────────────────────────────
  {
    let path = output_dir.join("world.json");
    let json = serde_json::to_string_pretty(config)?;
    fs::write(&path, json)?;
    println!("[DONE] Wrote world.json");
  }

  // ── Bake each LOD level ──────────────────────────────────────
  for &level in &config.baked_lod_levels
  {
    bake_level(config, &sampler, output_dir, level)?;
  }

  println!("[DONE] Bake complete");
  Ok(())
}

fn bake_level(
  config: &WorldConfig,
  sampler: &HeightSampler,
  output_dir: &Path,
  level: u32,
) -> anyhow::Result<()>
{
  println!("[WAIT] Baking LOD level {}...", level);

  let (vertices, faces) = icosahedron::build(level);
  let hex_ids = assign_hex_ids(&vertices, &faces);
  let planet_r = config.planet_radius_km * 1000.0; // metres

  println!("[INFO] Level {}: {} vertices, {} faces", level, vertices.len(), faces.len());

  // ── Build terrain vertices ────────────────────────────────────
  let terrain_verts: Vec<TerrainVertex> = vertices
    .iter()
    .enumerate()
    .map(|(i, &unit_pos)| {
      let elevation = sampler.sample(unit_pos);
      let world_pos = unit_pos * planet_r;
      TerrainVertex {
        position: [world_pos.x as f32, world_pos.y as f32, world_pos.z as f32],
        hex_id: hex_ids[i],
        elevation: encode_elevation(elevation),
        biome_id: elevation_to_biome(elevation),
        _pad: 0,
      }
    })
    .collect();

  // ── Build hex logic array ─────────────────────────────────────
  // One HexLogic entry per vertex (vertex IS the hex center)
  let hex_logic: Vec<HexLogic> = terrain_verts
    .iter()
    .map(|v| {
      let _elev_m = v.elevation as f64 - ELEVATION_OFFSET;
      HexLogic {
        biome_id: v.biome_id,
        move_cost: elevation_to_move_cost(v.biome_id),
        elevation: v.elevation,
        _pad: 0,
      }
    })
    .collect();

  // ── Write terrain_lN.bin ──────────────────────────────────────
  {
    let path = output_dir.join(format!("terrain_l{}.bin", level));
    let file = fs::File::create(&path)?;
    let mut writer = BufWriter::new(file);
    let mut bytes = 0usize;

    // Header magic + metadata
    writer.write_all(&0x4B595A55u32.to_le_bytes())?;
    bytes += 4;
    writer.write_all(&level.to_le_bytes())?;
    bytes += 4;
    writer.write_all(&(terrain_verts.len() as u64).to_le_bytes())?;
    bytes += 8;
    writer.write_all(&(faces.len() as u64).to_le_bytes())?;
    bytes += 8;

    bytes += pad_to_256(&mut writer, bytes)?;

    // Vertex data
    for v in &terrain_verts
    {
      writer.write_all(bytemuck::bytes_of(v))?;
      bytes += std::mem::size_of::<TerrainVertex>();
    }

    bytes += pad_to_256(&mut writer, bytes)?;

    // Face index data
    for face in &faces
    {
      for &idx in face.iter()
      {
        writer.write_all(&(idx as u32).to_le_bytes())?;
        bytes += 4;
      }
    }

    pad_to_256(&mut writer, bytes)?;
    writer.flush()?;

    println!("[DONE] Wrote terrain_l{}.bin ({} bytes)", level, bytes);
  }

  // ── Write hex_lN.bin ──────────────────────────────────────────
  {
    let path = output_dir.join(format!("hex_l{}.bin", level));
    let file = fs::File::create(&path)?;
    let mut writer = BufWriter::new(file);
    let mut bytes = 0usize;

    writer.write_all(&0x4B595A55u32.to_le_bytes())?;
    bytes += 4;
    writer.write_all(&level.to_le_bytes())?;
    bytes += 4;
    writer.write_all(&(hex_logic.len() as u64).to_le_bytes())?;
    bytes += 8;

    bytes += pad_to_256(&mut writer, bytes)?;

    for h in &hex_logic
    {
      writer.write_all(bytemuck::bytes_of(h))?;
      bytes += std::mem::size_of::<HexLogic>();
    }

    pad_to_256(&mut writer, bytes)?;
    writer.flush()?;

    println!("[DONE] Wrote hex_l{}.bin ({} bytes)", level, bytes);
  }

  Ok(())
}

// ──────────────────────────────────────────────────────────────
//   Movement cost from biome
// ──────────────────────────────────────────────────────────────

fn elevation_to_move_cost(biome_id: u8) -> u8
{
  match biome_id
  {
    0 => 255, // Deep Ocean   — impassable
    1 => 200, // Shallow Ocean — naval only
    2 => 80,  // Coast        — easy
    3 => 60,  // Lowland      — easy
    4 => 120, // Highland     — moderate
    5 => 180, // Mountain     — hard
    6 => 220, // Ice Cap      — very hard
    _ => 100,
  }
}
