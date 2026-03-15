use glam::DVec3;
use kyzu_core::WorldPreset;
use noise::{NoiseFn, Simplex};

// ──────────────────────────────────────────────────────────────
//   Generate a height value for a point on the unit sphere
//   Returns elevation in metres
// ──────────────────────────────────────────────────────────────

pub struct HeightSampler
{
  noise: Simplex,
  preset: WorldPreset,
}

impl HeightSampler
{
  pub fn new(seed: u32, preset: WorldPreset) -> Self
  {
    Self { noise: Simplex::new(seed), preset }
  }

  pub fn sample(&self, pos: DVec3) -> f64
  {
    match self.preset
    {
      WorldPreset::Continents => self.continents(pos),
      WorldPreset::Archipelago => self.archipelago(pos),
      WorldPreset::Alien => self.alien(pos),
    }
  }

  // ── Continents ───────────────────────────────────────────────
  // Large landmasses via low-frequency base + FBM detail

  fn continents(&self, pos: DVec3) -> f64
  {
    let p = pos.to_array();

    // Low-frequency continental shelf
    let base = self.fbm(&p, 4, 0.6, 1.8, 1.0);

    // Higher-frequency detail on top
    let detail = self.fbm(&p, 6, 0.5, 2.0, 3.0);

    // Combine: base drives land/sea threshold, detail adds texture
    let combined = base * 0.7 + detail * 0.3;

    // Map to elevation in metres (-8000m ocean to +6000m mountains)
    self.to_elevation(combined, -8000.0, 6000.0)
  }

  // ── Archipelago ──────────────────────────────────────────────
  // Mostly ocean with scattered islands — higher frequency, lower amplitude base

  fn archipelago(&self, pos: DVec3) -> f64
  {
    let p = pos.to_array();

    let base = self.fbm(&p, 3, 0.5, 2.2, 2.0);
    let detail = self.fbm(&p, 5, 0.5, 2.0, 5.0);

    // Bias strongly toward ocean
    let combined = base * 0.6 + detail * 0.4 - 0.3;

    self.to_elevation(combined, -7000.0, 4000.0)
  }

  // ── Alien ─────────────────────────────────────────────────────
  // Weird terrain — high variance, unusual frequency ratios

  fn alien(&self, pos: DVec3) -> f64
  {
    let p = pos.to_array();

    let base = self.fbm(&p, 5, 0.65, 2.5, 1.5);
    let detail = self.fbm(&p, 4, 0.45, 3.1, 6.0);
    let ridge = self.ridged(&p, 3, 1.3);

    let combined = base * 0.4 + detail * 0.3 + ridge * 0.3;

    // Wider elevation range for dramatic alien terrain
    self.to_elevation(combined, -12000.0, 18000.0)
  }

  // ── FBM (Fractional Brownian Motion) ─────────────────────────

  fn fbm(&self, p: &[f64; 3], octaves: u32, persistence: f64, lacunarity: f64, scale: f64) -> f64
  {
    let mut value = 0.0;
    let mut amplitude = 1.0;
    let mut frequency = scale;
    let mut max_value = 0.0;

    for _ in 0..octaves
    {
      value += self.noise.get([p[0] * frequency, p[1] * frequency, p[2] * frequency]) * amplitude;
      max_value += amplitude;
      amplitude *= persistence;
      frequency *= lacunarity;
    }

    value / max_value // normalise to roughly -1..1
  }

  // ── Ridged noise — creates sharp mountain ridges ──────────────

  fn ridged(&self, p: &[f64; 3], octaves: u32, scale: f64) -> f64
  {
    let mut value = 0.0;
    let mut amplitude = 1.0;
    let mut frequency = scale;
    let mut max_value = 0.0;

    for _ in 0..octaves
    {
      let n = self.noise.get([p[0] * frequency, p[1] * frequency, p[2] * frequency]);
      value += (1.0 - n.abs()) * amplitude;
      max_value += amplitude;
      amplitude *= 0.5;
      frequency *= 2.0;
    }

    value / max_value
  }

  // ── Map noise [-1..1] to elevation in metres ─────────────────

  fn to_elevation(&self, noise_val: f64, min_m: f64, max_m: f64) -> f64
  {
    let t = (noise_val.clamp(-1.0, 1.0) + 1.0) / 2.0; // 0..1
    min_m + t * (max_m - min_m)
  }
}
