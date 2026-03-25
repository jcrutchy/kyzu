use std::path::Path;

use crate::core::log::{LogLevel, Logger};
use crate::world::body::BodyManifest;

/// Scans the baked output directory for `*.manifest` files, deserialises
/// each one, and returns them as a Vec.
///
/// Called once at startup. The Vec is passed into App::new() and then into
/// SharedState::new() where the BodyRegistry is populated.
///
/// Errors on individual manifests are logged and skipped — a single corrupt
/// file won't prevent the rest of the system from loading.
pub fn load_all_manifests(
  baked_dir: &Path,
  logger: &mut Logger,
) -> anyhow::Result<Vec<BodyManifest>>
{
  let mut manifests = Vec::new();

  let entries = std::fs::read_dir(baked_dir)
    .map_err(|e| anyhow::anyhow!("Cannot read baked dir {:?}: {}", baked_dir, e))?;

  for entry in entries
  {
    let entry = entry?;
    let path = entry.path();

    if path.extension().and_then(|e| e.to_str()) != Some("manifest")
    {
      continue;
    }

    match load_single_manifest(&path)
    {
      Ok(manifest) =>
      {
        logger.emit(
          LogLevel::Info,
          &format!("Loaded manifest: {} ({:?})", manifest.name, manifest.kind),
        );
        manifests.push(manifest);
      }
      Err(e) =>
      {
        logger.emit(LogLevel::Error, &format!("Failed to load manifest {:?}: {}", path, e));
      }
    }
  }

  logger.emit(LogLevel::Info, &format!("BodyRegistry: {} bodies available", manifests.len()));

  Ok(manifests)
}

fn load_single_manifest(path: &Path) -> anyhow::Result<BodyManifest>
{
  let bytes = std::fs::read(path).map_err(|e| anyhow::anyhow!("Read error: {}", e))?;

  let manifest: BodyManifest =
    bincode::deserialize(&bytes).map_err(|e| anyhow::anyhow!("Deserialise error: {}", e))?;

  Ok(manifest)
}
