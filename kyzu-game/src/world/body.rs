use glam::DVec3;
use serde::{Deserialize, Serialize};

// ─────────────────────────────────────────────────────────────────────────────
//  BodyKind
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum BodyKind
{
  /// Full Earth-class body: real heightmap, texture atlas, biome colours,
  /// feature layer at highest LOD.
  Terrestrial,

  /// Rocky planet driven by a baked colour ramp (e.g. Mars, Venus, Moon).
  Rocky
  {
    ramp_index: u8
  },

  /// Gas giant — banded shader, no hex surface detail.
  GasGiant
  {
    /// Primary band colour (equatorial).
    band_color_a: [f32; 3],
    /// Secondary band colour (belt/zone alternation).
    band_color_b: [f32; 3],
  },

  /// Asteroid or small moon — flat colour, diffuse sun lighting only.
  SmallBody
  {
    base_color: [f32; 3]
  },

  /// Scene light source. The renderer uses the first Star it finds as the sun.
  Star
  {
    light_color: [f32; 3], luminosity: f32
  },

  /// Space station, platform, or constructed structure.
  /// Uses an arbitrary triangle mesh; no hex grid or heightmap.
  Manmade,
}

// ─────────────────────────────────────────────────────────────────────────────
//  OrbitalElements
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrbitalElements
{
  /// Semi-major axis in metres.
  pub semi_major_axis_m: f64,
  pub eccentricity: f64,
  /// Inclination relative to the ecliptic, in radians.
  pub inclination_rad: f64,
  /// Right ascension of the ascending node, in radians.
  pub raan_rad: f64,
  /// Argument of periapsis, in radians.
  pub arg_of_periapsis_rad: f64,
  /// Mean anomaly at the reference epoch, in radians.
  pub mean_anomaly_at_epoch_rad: f64,
  /// Name of the parent body this one orbits. None = root of the system.
  pub parent_name: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
//  BodyManifest
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BodyManifest
{
  /// Unique name — matches the baked asset directory name (lowercase).
  pub name: String,

  pub kind: BodyKind,

  /// Radius in metres.
  pub radius_m: f64,

  /// Highest available LOD level in the asset bundle.
  pub lod_max: u8,

  /// World-space position at epoch (metres from system origin).
  /// Stored as ZERO here — OrbitalSimulator places the body correctly on
  /// the first tick using orbital_elements.
  pub position_at_epoch: DVec3,

  /// Keplerian orbital elements. None for fixed bodies (Sun, stations).
  pub orbital_elements: Option<OrbitalElements>,

  /// Axial tilt in radians.
  pub axial_tilt_rad: f64,

  /// Sidereal rotation period in seconds.
  pub rotation_period_s: f64,
}

// ─────────────────────────────────────────────────────────────────────────────
//  BodyConfig → BodyManifest conversion
//
//  Called at the end of each body's bake to write body_manifest.bin.
//  Derives BodyKind from the flat BodyConfig fields using the rules below.
// ─────────────────────────────────────────────────────────────────────────────

use crate::bake::registry::BodyConfig;

impl BodyManifest
{
  pub fn from_config(config: &BodyConfig) -> Self
  {
    let kind = derive_kind(config);

    // Orbital elements — only for bodies that actually orbit something.
    // The Sun (orbit_radius_km == 0) gets None.
    let orbital_elements = if config.orbit_radius_km > 0.0
    {
      Some(OrbitalElements {
        semi_major_axis_m: config.orbit_radius_km as f64 * 1000.0,
        eccentricity: config.orbital_eccentricity as f64,
        inclination_rad: (config.orbital_inclination_deg as f64).to_radians(),
        // RAAN and arg_of_periapsis default to zero until we source
        // proper ephemeris data.
        raan_rad: 0.0,
        arg_of_periapsis_rad: 0.0,
        mean_anomaly_at_epoch_rad: config.start_angle_rad as f64,
        parent_name: config.parent.clone(),
      })
    }
    else
    {
      None
    };

    Self {
      name: config.name.to_lowercase(),
      kind,
      radius_m: config.radius_km as f64 * 1000.0,
      lod_max: config.lod_max,
      position_at_epoch: DVec3::ZERO,
      orbital_elements,
      axial_tilt_rad: (config.axial_tilt_deg as f64).to_radians(),
      rotation_period_s: config.rotation_period_hours as f64 * 3600.0,
    }
  }
}

/// Derive BodyKind from flat BodyConfig fields.
///
/// Rules (in priority order):
///   is_star                → Star
///   use_real_data          → Terrestrial
///   radius_km >= 24_000    → GasGiant  (Jupiter ~71k, Saturn ~58k, Uranus ~25k, Neptune ~24k)
///   radius_km >= 1_500     → Rocky     (Mars ~3.4k, Venus ~6k, Moon ~1.7k, Pluto ~1.2k)
///   radius_km <  1_500     → SmallBody (Ceres ~473, Vesta ~263, Charon ~606)
fn derive_kind(c: &BodyConfig) -> BodyKind
{
  if c.is_star
  {
    return BodyKind::Star { light_color: [c.color[0], c.color[1], c.color[2]], luminosity: 1.0 };
  }

  if c.use_real_data
  {
    return BodyKind::Terrestrial;
  }

  if c.radius_km >= 24_000.0
  {
    return BodyKind::GasGiant {
      band_color_a: [c.color[0], c.color[1], c.color[2]],
      // Darker secondary band derived from the primary colour.
      band_color_b: [
        (c.color[0] * 0.7).min(1.0),
        (c.color[1] * 0.7).min(1.0),
        (c.color[2] * 0.7).min(1.0),
      ],
    };
  }

  if c.radius_km >= 1_500.0
  {
    return BodyKind::Rocky { ramp_index: 0 };
  }

  BodyKind::SmallBody { base_color: [c.color[0], c.color[1], c.color[2]] }
}
