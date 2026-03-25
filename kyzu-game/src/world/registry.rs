use glam::DVec3;

use crate::world::body::BodyManifest;

// ─────────────────────────────────────────────────────────────────────────────
//  StreamingStatus
//
//  Tracks what the BodyStreamManager has loaded for this body so the renderer
//  knows what it can safely draw this frame.
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum StreamingStatus
{
  /// Manifest loaded, no GPU resources yet. Body not visible this frame.
  Pending,
  /// Mesh at this LOD level is on the GPU and ready to draw.
  Ready
  {
    current_lod: u8
  },
  /// A finer LOD is being streamed in the background; draw current_lod
  /// until the upgrade arrives.
  Upgrading
  {
    current_lod: u8, target_lod: u8
  },
}

// ─────────────────────────────────────────────────────────────────────────────
//  CameraFocus
//
//  Controls the floating-origin anchor for the free camera.
//  Body(usize) holds an index into BodyRegistry::bodies.
//
//  The focal body is sticky — it only changes when the player explicitly
//  focuses a new body, or when spawn_body() is called with focus: true.
//  During time skip the camera tracks the focal body's orbital motion,
//  so the skip feels like a timelapse rather than a jump cut.
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum CameraFocus
{
  /// Floating origin is anchored to this body's world_pos.
  Body(usize),
  /// No body anchor — floating origin follows the camera position directly.
  /// Used in deep space with no nearby body of interest.
  Freepoint,
}

// ─────────────────────────────────────────────────────────────────────────────
//  BodyState
//
//  Runtime state for one body — updated every frame by the orbital sim
//  and the streaming system. Kept separate from BodyManifest so the manifest
//  can be immutable once loaded.
// ─────────────────────────────────────────────────────────────────────────────

pub struct BodyState
{
  /// Immutable description loaded from disk.
  pub manifest: BodyManifest,

  /// Current world-space position in metres (f64 precision).
  /// For orbiting bodies: updated every frame by OrbitalSimulator.
  /// For fixed bodies: always equal to manifest.position_at_epoch.
  pub world_pos: DVec3,

  /// Current rotation angle around the axial tilt axis, in radians.
  /// Incremented every frame by (2π / rotation_period_s) * dt.
  pub rotation_angle: f64,

  /// What the streaming system currently has resident on the GPU.
  pub streaming: StreamingStatus,
}

impl BodyState
{
  pub fn new(manifest: BodyManifest) -> Self
  {
    let world_pos = manifest.position_at_epoch;
    Self { manifest, world_pos, rotation_angle: 0.0, streaming: StreamingStatus::Pending }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  BodyRegistry
//
//  The single source of truth for all bodies in the active world.
//  Lives in SharedState so every system (renderer, orbital sim, camera,
//  streaming) reads from the same place.
//
//  Indexing is stable within a session — bodies are never removed, only
//  added. spawn_body() pushes to the end; existing indices never change.
// ─────────────────────────────────────────────────────────────────────────────

pub struct BodyRegistry
{
  pub bodies: Vec<BodyState>,

  /// Which body the free camera is anchored to, or Freepoint.
  pub camera_focus: CameraFocus,
}

impl BodyRegistry
{
  pub fn new() -> Self
  {
    Self { bodies: Vec::new(), camera_focus: CameraFocus::Freepoint }
  }

  /// Add a new body. Returns its stable index.
  /// If focus is true, shifts camera_focus to this body immediately.
  pub fn spawn(&mut self, manifest: BodyManifest, focus: bool) -> usize
  {
    let index = self.bodies.len();
    self.bodies.push(BodyState::new(manifest));
    if focus
    {
      self.camera_focus = CameraFocus::Body(index);
    }
    index
  }

  /// The body the camera is currently anchored to, if any.
  pub fn focal_body(&self) -> Option<&BodyState>
  {
    match self.camera_focus
    {
      CameraFocus::Body(idx) => self.bodies.get(idx),
      CameraFocus::Freepoint => None,
    }
  }

  /// World-space offset to subtract when building camera-relative transforms.
  /// If anchored to a body, returns that body's world_pos.
  /// If Freepoint, returns DVec3::ZERO (caller should use eye_world instead).
  pub fn floating_origin(&self) -> DVec3
  {
    self.focal_body().map(|b| b.world_pos).unwrap_or(DVec3::ZERO)
  }

  /// Find the nearest body to a given world-space position.
  /// Returns None only if the registry is empty.
  pub fn nearest_to(&self, pos: DVec3) -> Option<(usize, f64)>
  {
    self
      .bodies
      .iter()
      .enumerate()
      .map(|(i, b)| (i, (b.world_pos - pos).length()))
      .min_by(|a, b| a.1.partial_cmp(&b.1).unwrap())
  }
}
