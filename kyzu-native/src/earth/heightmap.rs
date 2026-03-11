use std::path::Path;

// ──────────────────────────────────────────────────────────────
//   ETOPO GeoTiff constants
//
//   30 arc-second grid:
//     - 43200 columns (360° × 120 pixels/°)
//     - 21600 rows    (180° × 120 pixels/°)
//     - i16 elevation in metres (negative = ocean/bathymetry)
//     - Origin: top-left = (90°N, 180°W)
//     - Pixel size: 1/120° ≈ 0.00833°
// ──────────────────────────────────────────────────────────────

pub const ETOPO_30S_COLS: usize = 43200;
pub const ETOPO_30S_ROWS: usize = 21600;
pub const ETOPO_30S_PIXEL_DEG: f64 = 1.0 / 120.0; // 30 arc-seconds in degrees

// ──────────────────────────────────────────────────────────────
//   Bounding box in geographic coordinates
// ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
pub struct LatLonBbox
{
  pub min_lat: f64, // degrees, -90 to 90
  pub max_lat: f64,
  pub min_lon: f64, // degrees, -180 to 180
  pub max_lon: f64,
}

impl LatLonBbox
{
  pub fn europe() -> Self
  {
    Self { min_lat: 35.0, max_lat: 72.0, min_lon: -25.0, max_lon: 45.0 }
  }

  pub fn australia() -> Self
  {
    Self { min_lat: -45.0, max_lat: -10.0, min_lon: 112.0, max_lon: 154.0 }
  }

  pub fn width_pixels(&self) -> usize
  {
    ((self.max_lon - self.min_lon) / ETOPO_30S_PIXEL_DEG).round() as usize
  }

  pub fn height_pixels(&self) -> usize
  {
    ((self.max_lat - self.min_lat) / ETOPO_30S_PIXEL_DEG).round() as usize
  }
}

// ──────────────────────────────────────────────────────────────
//   Heightmap — a flat f32 array in row-major order
//   Row 0 = northernmost row (max_lat)
//   Col 0 = westernmost col (min_lon)
// ──────────────────────────────────────────────────────────────

pub struct Heightmap
{
  pub data: Vec<f32>, // elevation in metres
  pub width: usize,   // columns (longitude axis)
  pub height: usize,  // rows (latitude axis)
  pub bbox: LatLonBbox,
}

impl Heightmap
{
  pub fn sample(&self, col: usize, row: usize) -> f32
  {
    self.data[row * self.width + col]
  }

  /// Bilinear sample at fractional pixel coordinates
  pub fn sample_bilinear(&self, col: f64, row: f64) -> f32
  {
    let c0 = (col.floor() as usize).min(self.width - 2);
    let r0 = (row.floor() as usize).min(self.height - 2);
    let cf = (col - col.floor()) as f32;
    let rf = (row - row.floor()) as f32;

    let h00 = self.sample(c0, r0);
    let h10 = self.sample(c0 + 1, r0);
    let h01 = self.sample(c0, r0 + 1);
    let h11 = self.sample(c0 + 1, r0 + 1);

    let h0 = h00 + (h10 - h00) * cf;
    let h1 = h01 + (h11 - h01) * cf;
    h0 + (h1 - h0) * rf
  }

  /// Sample elevation at a geographic coordinate within the bbox
  pub fn sample_latlon(&self, lat: f64, lon: f64) -> Option<f32>
  {
    if lat < self.bbox.min_lat
      || lat > self.bbox.max_lat
      || lon < self.bbox.min_lon
      || lon > self.bbox.max_lon
    {
      return None;
    }

    // Row 0 = max_lat (north), so row increases southward
    let col = (lon - self.bbox.min_lon) / ETOPO_30S_PIXEL_DEG;
    let row = (self.bbox.max_lat - lat) / ETOPO_30S_PIXEL_DEG;

    Some(self.sample_bilinear(col, row))
  }

  /// Elevation range — useful for normalising colour output
  pub fn elevation_range(&self) -> (f32, f32)
  {
    let min = self.data.iter().cloned().fold(f32::INFINITY, f32::min);
    let max = self.data.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
    (min, max)
  }
}
