use glam::DVec3;

// ──────────────────────────────────────────────────────────────
//   WGS84 ellipsoid constants
// ──────────────────────────────────────────────────────────────

pub const WGS84_A: f64 = 6_378_137.0; // semi-major axis, metres
pub const WGS84_B: f64 = 6_356_752.314_245; // semi-minor axis, metres
pub const WGS84_E2: f64 = 1.0 - (WGS84_B * WGS84_B) / (WGS84_A * WGS84_A); // first eccentricity²
pub const WGS84_F: f64 = 1.0 / 298.257_223_563; // flattening

// ──────────────────────────────────────────────────────────────
//   Geodetic ↔ ECEF
//
//   ECEF: Earth-Centered Earth-Fixed
//   X axis: through (0°N, 0°E) — prime meridian / equator
//   Y axis: through (0°N, 90°E)
//   Z axis: through north pole
// ──────────────────────────────────────────────────────────────

/// Convert geodetic (lat, lon, altitude) to ECEF XYZ.
/// lat_rad, lon_rad in radians. alt_m in metres above ellipsoid.
pub fn geodetic_to_ecef(lat_rad: f64, lon_rad: f64, alt_m: f64) -> DVec3
{
  let sin_lat = lat_rad.sin();
  let cos_lat = lat_rad.cos();
  let sin_lon = lon_rad.sin();
  let cos_lon = lon_rad.cos();

  // Prime vertical radius of curvature
  let n = WGS84_A / (1.0 - WGS84_E2 * sin_lat * sin_lat).sqrt();

  DVec3::new(
    (n + alt_m) * cos_lat * cos_lon,
    (n + alt_m) * cos_lat * sin_lon,
    (n * (1.0 - WGS84_E2) + alt_m) * sin_lat,
  )
}

/// Convenience: degrees input
pub fn geodetic_to_ecef_deg(lat_deg: f64, lon_deg: f64, alt_m: f64) -> DVec3
{
  geodetic_to_ecef(lat_deg.to_radians(), lon_deg.to_radians(), alt_m)
}

// ──────────────────────────────────────────────────────────────
//   ECEF → ENU (East-North-Up)
//
//   ENU is a local tangent plane coordinate system.
//   Origin is a reference point on the ellipsoid surface.
//   X = East, Y = North, Z = Up (away from ellipsoid)
//
//   Used at gameplay zoom level where the earth appears flat.
//   Valid within ~500km of origin with <0.1% error.
// ──────────────────────────────────────────────────────────────

pub struct EnuOrigin
{
  pub ecef: DVec3, // ECEF position of origin
  pub lat_rad: f64,
  pub lon_rad: f64,
}

impl EnuOrigin
{
  pub fn from_latlon_deg(lat_deg: f64, lon_deg: f64) -> Self
  {
    let lat_rad = lat_deg.to_radians();
    let lon_rad = lon_deg.to_radians();
    Self { ecef: geodetic_to_ecef(lat_rad, lon_rad, 0.0), lat_rad, lon_rad }
  }

  /// Convert an ECEF point to ENU coordinates relative to this origin.
  pub fn ecef_to_enu(&self, point: DVec3) -> DVec3
  {
    let d = point - self.ecef;
    let sin_lat = self.lat_rad.sin();
    let cos_lat = self.lat_rad.cos();
    let sin_lon = self.lon_rad.sin();
    let cos_lon = self.lon_rad.cos();

    DVec3::new(
      -sin_lon * d.x + cos_lon * d.y,
      -sin_lat * cos_lon * d.x - sin_lat * sin_lon * d.y + cos_lat * d.z,
      cos_lat * cos_lon * d.x + cos_lat * sin_lon * d.y + sin_lat * d.z,
    )
  }

  /// Convert an ENU point back to ECEF.
  pub fn enu_to_ecef(&self, enu: DVec3) -> DVec3
  {
    let sin_lat = self.lat_rad.sin();
    let cos_lat = self.lat_rad.cos();
    let sin_lon = self.lon_rad.sin();
    let cos_lon = self.lon_rad.cos();

    self.ecef
      + DVec3::new(
        -sin_lon * enu.x - sin_lat * cos_lon * enu.y + cos_lat * cos_lon * enu.z,
        cos_lon * enu.x - sin_lat * sin_lon * enu.y + cos_lat * sin_lon * enu.z,
        cos_lat * enu.y + sin_lat * enu.z,
      )
  }

  /// Convert geodetic lat/lon/alt to ENU relative to this origin.
  /// Convenience wrapper used frequently during terrain generation.
  pub fn geodetic_to_enu_deg(&self, lat_deg: f64, lon_deg: f64, alt_m: f64) -> DVec3
  {
    let ecef = geodetic_to_ecef_deg(lat_deg, lon_deg, alt_m);
    self.ecef_to_enu(ecef)
  }
}

// ──────────────────────────────────────────────────────────────
//   Approximate metres-per-degree at a given latitude
//   Useful for sizing hex tiles in world space
// ──────────────────────────────────────────────────────────────

/// Metres per degree of longitude at a given latitude.
pub fn metres_per_lon_deg(lat_rad: f64) -> f64
{
  let n = WGS84_A / (1.0 - WGS84_E2 * lat_rad.sin().powi(2)).sqrt();
  n * lat_rad.cos() * std::f64::consts::PI / 180.0
}

/// Metres per degree of latitude (nearly constant, ~111km).
pub fn metres_per_lat_deg(lat_rad: f64) -> f64
{
  let sin_lat = lat_rad.sin();
  let denom = (1.0 - WGS84_E2 * sin_lat * sin_lat).sqrt();
  WGS84_A * (1.0 - WGS84_E2) / (denom * denom * denom) * std::f64::consts::PI / 180.0
}

// ──────────────────────────────────────────────────────────────
//   Tests
// ──────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests
{
  use super::*;

  #[test]
  fn ecef_roundtrip_origin()
  {
    // (0°N, 0°E, 0m) should be (WGS84_A, 0, 0) in ECEF
    let ecef = geodetic_to_ecef_deg(0.0, 0.0, 0.0);
    assert!((ecef.x - WGS84_A).abs() < 0.01, "x={}", ecef.x);
    assert!(ecef.y.abs() < 0.01, "y={}", ecef.y);
    assert!(ecef.z.abs() < 0.01, "z={}", ecef.z);
  }

  #[test]
  fn ecef_north_pole()
  {
    let ecef = geodetic_to_ecef_deg(90.0, 0.0, 0.0);
    assert!(ecef.x.abs() < 0.01);
    assert!(ecef.y.abs() < 0.01);
    assert!((ecef.z - WGS84_B).abs() < 0.01, "z={}", ecef.z);
  }

  #[test]
  fn enu_roundtrip()
  {
    let origin = EnuOrigin::from_latlon_deg(-33.8688, 151.2093); // Sydney
    let point = geodetic_to_ecef_deg(-33.8688, 151.2093, 100.0); // 100m up
    let enu = origin.ecef_to_enu(point);
    // Should be ~(0, 0, 100) in ENU
    assert!(enu.x.abs() < 0.1, "east={}", enu.x);
    assert!(enu.y.abs() < 0.1, "north={}", enu.y);
    assert!((enu.z - 100.0).abs() < 0.1, "up={}", enu.z);
  }
}
