// ──────────────────────────────────────────────────────────────
//   KZT — Kyzu Terrain Format
//
//   A compact, game-ready terrain file derived from ETOPO.
//   Generated once by the preprocessor, loaded at runtime.
//
//   File layout:
//     [Header: 64 bytes, little-endian]
//       magic:      [u8; 4]   "KZT\0"
//       version:    u16
//       _pad:       u16
//       width:      u32
//       height:     u32
//       min_lat:    f64
//       max_lat:    f64
//       min_lon:    f64
//       max_lon:    f64
//       pixel_deg:  f64
//       _pad:       [u8; 16]
//     [TerrainType array: width * height bytes (u8)]
//     [Elevation array:   width * height * 2 bytes (i16 LE)]
//
//   Total for Australia at 30": ~63MB vs 1.5GB source GeoTiff.
// ──────────────────────────────────────────────────────────────

use std::io::{Read, Write};
use std::path::Path;

// ──────────────────────────────────────────────────────────────
//   Terrain classification
// ──────────────────────────────────────────────────────────────

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TerrainType
{
  DeepOcean = 0,    // elev < -200m      dark blue
  ShallowOcean = 1, // -200m to 0m       light blue
  Beach = 2,        // 0m to 30m         sand
  Lowland = 3,      // 30m to 200m       green
  Highland = 4,     // 200m to 1500m     olive/brown-green
  Mountain = 5,     // 1500m to 3000m    grey
  SnowPeak = 6,     // > 3000m           white
}

impl TerrainType
{
  pub fn classify(elevation_m: i16) -> Self
  {
    if elevation_m < -200
    {
      Self::DeepOcean
    }
    else if elevation_m < 0
    {
      Self::ShallowOcean
    }
    else if elevation_m < 30
    {
      Self::Beach
    }
    else if elevation_m < 200
    {
      Self::Lowland
    }
    else if elevation_m < 1500
    {
      Self::Highland
    }
    else if elevation_m < 3000
    {
      Self::Mountain
    }
    else
    {
      Self::SnowPeak
    }
  }

  pub fn from_u8(v: u8) -> Option<Self>
  {
    match v
    {
      0 => Some(Self::DeepOcean),
      1 => Some(Self::ShallowOcean),
      2 => Some(Self::Beach),
      3 => Some(Self::Lowland),
      4 => Some(Self::Highland),
      5 => Some(Self::Mountain),
      6 => Some(Self::SnowPeak),
      _ => None,
    }
  }

  pub fn base_color(self) -> [f32; 3]
  {
    match self
    {
      Self::DeepOcean => [0.03, 0.10, 0.28],
      Self::ShallowOcean => [0.10, 0.28, 0.52],
      Self::Beach => [0.82, 0.78, 0.58],
      Self::Lowland => [0.42, 0.62, 0.28],
      Self::Highland => [0.40, 0.52, 0.30],
      Self::Mountain => [0.52, 0.48, 0.42],
      Self::SnowPeak => [0.93, 0.95, 0.98],
    }
  }

  pub fn is_ocean(self) -> bool
  {
    matches!(self, Self::DeepOcean | Self::ShallowOcean)
  }

  pub fn is_land(self) -> bool
  {
    !self.is_ocean()
  }
}

// ──────────────────────────────────────────────────────────────
//   KztFile — in-memory representation
// ──────────────────────────────────────────────────────────────

const MAGIC: [u8; 4] = *b"KZT\0";
const VERSION: u16 = 1;
const HEADER_SIZE: usize = 64;

pub struct KztFile
{
  pub width: u32,
  pub height: u32,
  pub min_lat: f64,
  pub max_lat: f64,
  pub min_lon: f64,
  pub max_lon: f64,
  pub pixel_deg: f64,

  /// Terrain type per cell, row-major, row 0 = max_lat (north)
  pub types: Vec<u8>,
  /// Elevation in metres per cell, same layout
  pub elevations: Vec<i16>,
}

impl KztFile
{
  pub fn new(
    width: u32,
    height: u32,
    min_lat: f64,
    max_lat: f64,
    min_lon: f64,
    max_lon: f64,
    pixel_deg: f64,
  ) -> Self
  {
    let n = (width * height) as usize;
    Self {
      width,
      height,
      min_lat,
      max_lat,
      min_lon,
      max_lon,
      pixel_deg,
      types: vec![0u8; n],
      elevations: vec![0i16; n],
    }
  }

  pub fn idx(&self, col: u32, row: u32) -> usize
  {
    (row * self.width + col) as usize
  }

  pub fn terrain_type(&self, col: u32, row: u32) -> TerrainType
  {
    TerrainType::from_u8(self.types[self.idx(col, row)]).unwrap_or(TerrainType::DeepOcean)
  }

  pub fn elevation(&self, col: u32, row: u32) -> i16
  {
    self.elevations[self.idx(col, row)]
  }

  /// Geographic coordinate for a pixel centre
  pub fn pixel_latlon(&self, col: u32, row: u32) -> (f64, f64)
  {
    let lon = self.min_lon + col as f64 * self.pixel_deg + self.pixel_deg * 0.5;
    let lat = self.max_lat - row as f64 * self.pixel_deg - self.pixel_deg * 0.5;
    (lat, lon)
  }

  // ──────────────────────────────────────────────────────────
  //   I/O — manual field serialization, no unsafe needed
  // ──────────────────────────────────────────────────────────

  pub fn write(&self, path: &Path) -> anyhow::Result<()>
  {
    use std::fs::File;
    use std::io::BufWriter;

    let file = File::create(path)?;
    let mut w = BufWriter::new(file);

    // Build header as a plain byte array — no unsafe, no packed structs
    let mut header = [0u8; HEADER_SIZE];
    header[0..4].copy_from_slice(&MAGIC);
    header[4..6].copy_from_slice(&VERSION.to_le_bytes());
    // [6..8] pad — zero
    header[8..12].copy_from_slice(&self.width.to_le_bytes());
    header[12..16].copy_from_slice(&self.height.to_le_bytes());
    header[16..24].copy_from_slice(&self.min_lat.to_le_bytes());
    header[24..32].copy_from_slice(&self.max_lat.to_le_bytes());
    header[32..40].copy_from_slice(&self.min_lon.to_le_bytes());
    header[40..48].copy_from_slice(&self.max_lon.to_le_bytes());
    header[48..56].copy_from_slice(&self.pixel_deg.to_le_bytes());
    // [56..64] pad — zero

    w.write_all(&header)?;
    w.write_all(&self.types)?;

    for &e in &self.elevations
    {
      w.write_all(&e.to_le_bytes())?;
    }

    let total_mb =
      (HEADER_SIZE + self.types.len() + self.elevations.len() * 2) as f64 / 1_048_576.0;
    log::info!("Wrote {} ({:.1} MB)", path.display(), total_mb);

    Ok(())
  }

  pub fn read(path: &Path) -> anyhow::Result<Self>
  {
    use std::fs::File;
    use std::io::BufReader;

    let file = File::open(path)?;
    let mut r = BufReader::new(file);

    // Read header as plain bytes
    let mut header = [0u8; HEADER_SIZE];
    r.read_exact(&mut header)?;

    anyhow::ensure!(&header[0..4] == &MAGIC, "Not a KZT file");

    let version = u16::from_le_bytes([header[4], header[5]]);
    anyhow::ensure!(version == VERSION, "Unsupported KZT version {}", version);

    let width = u32::from_le_bytes(header[8..12].try_into()?);
    let height = u32::from_le_bytes(header[12..16].try_into()?);
    let min_lat = f64::from_le_bytes(header[16..24].try_into()?);
    let max_lat = f64::from_le_bytes(header[24..32].try_into()?);
    let min_lon = f64::from_le_bytes(header[32..40].try_into()?);
    let max_lon = f64::from_le_bytes(header[40..48].try_into()?);
    let pixel_deg = f64::from_le_bytes(header[48..56].try_into()?);

    let n = (width * height) as usize;

    let mut types = vec![0u8; n];
    r.read_exact(&mut types)?;

    let mut elev_bytes = vec![0u8; n * 2];
    r.read_exact(&mut elev_bytes)?;
    let elevations: Vec<i16> =
      elev_bytes.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect();

    log::info!(
      "Loaded KZT: {}×{} [{:.1}°N {:.1}°E → {:.1}°N {:.1}°E]",
      width,
      height,
      min_lat,
      min_lon,
      max_lat,
      max_lon,
    );

    Ok(Self { width, height, min_lat, max_lat, min_lon, max_lon, pixel_deg, types, elevations })
  }
}
