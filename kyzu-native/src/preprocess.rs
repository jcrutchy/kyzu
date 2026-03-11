#![allow(dead_code)]

mod config;
mod earth;
mod kzt;
mod tiff_reader;

use earth::heightmap::{LatLonBbox, ETOPO_30S_COLS, ETOPO_30S_PIXEL_DEG, ETOPO_30S_ROWS};
use kzt::{KztFile, TerrainType};
use tiff_reader::EtopoTiff;

fn main()
{
  std::env::set_var("RUST_LOG", "kyzu_native=info");
  env_logger::init();

  if let Err(e) = run()
  {
    eprintln!("\nERROR: {e:#}");
    std::process::exit(1);
  }
}

fn run() -> anyhow::Result<()>
{
  let config = config::load()?;

  let input_path = &config.data.etopo_30s;
  let output_path = input_path.with_extension("kzt");

  if output_path.exists()
  {
    log::info!("Output already exists: {}", output_path.display());
    log::info!("Delete it to re-generate. Exiting.");
    return Ok(());
  }

  let bbox = LatLonBbox {
    min_lat: config.startup.bbox.min_lat,
    max_lat: config.startup.bbox.max_lat,
    min_lon: config.startup.bbox.min_lon,
    max_lon: config.startup.bbox.max_lon,
  };

  log::info!("Opening {}", input_path.display());

  let tiff = EtopoTiff::open(input_path)?;
  log::info!("File: {}x{}, {} strips", tiff.width, tiff.height, tiff.strip_count());

  anyhow::ensure!(
    tiff.width == ETOPO_30S_COLS && tiff.height == ETOPO_30S_ROWS,
    "Unexpected dimensions {}x{} — expected {}x{}",
    tiff.width,
    tiff.height,
    ETOPO_30S_COLS,
    ETOPO_30S_ROWS
  );

  // ── Compute bbox pixel bounds ─────────────────────────────

  let col_start = ((bbox.min_lon + 180.0) / ETOPO_30S_PIXEL_DEG).floor() as usize;
  let col_end = ((bbox.max_lon + 180.0) / ETOPO_30S_PIXEL_DEG).ceil() as usize;
  let row_start = ((90.0 - bbox.max_lat) / ETOPO_30S_PIXEL_DEG).floor() as usize;
  let row_end = ((90.0 - bbox.min_lat) / ETOPO_30S_PIXEL_DEG).ceil() as usize;

  let out_w = (col_end - col_start).min(tiff.width);
  let out_h = (row_end - row_start).min(tiff.height);

  log::info!(
    "Extracting [{:.1}N {:.1}E -> {:.1}N {:.1}E] = {}x{} pixels",
    bbox.min_lat,
    bbox.min_lon,
    bbox.max_lat,
    bbox.max_lon,
    out_w,
    out_h
  );

  // ── Build KZT, reading strips ─────────────────────────────

  let mut kzt = KztFile::new(
    out_w as u32,
    out_h as u32,
    bbox.min_lat,
    bbox.max_lat,
    bbox.min_lon,
    bbox.max_lon,
    ETOPO_30S_PIXEL_DEG,
  );

  let mut type_counts = [0u32; 7];
  let mut out_row = 0usize;
  let last_progress = std::sync::atomic::AtomicI32::new(-1);

  for src_row in row_start..row_end
  {
    let row_data = tiff.read_row(src_row)?;

    for col in 0..out_w
    {
      let elev = row_data[col_start + col];
      let terrain = TerrainType::classify(elev);
      let idx = out_row * out_w + col;
      kzt.types[idx] = terrain as u8;
      kzt.elevations[idx] = elev;
      type_counts[terrain as usize] += 1;
    }

    let pct = (out_row * 10 / out_h) as i32;
    let prev = last_progress.load(std::sync::atomic::Ordering::Relaxed);
    if pct > prev
    {
      last_progress.store(pct, std::sync::atomic::Ordering::Relaxed);
      log::info!("  {}0%", pct);
    }

    out_row += 1;
  }

  // ── Report ────────────────────────────────────────────────

  let total = (out_w * out_h) as f32;
  let names =
    ["Deep ocean", "Shallow ocean", "Beach", "Lowland", "Highland", "Mountain", "Snow peak"];
  log::info!("Classification:");
  for (i, name) in names.iter().enumerate()
  {
    log::info!(
      "  {:<14} {:>8} cells ({:.1}%)",
      name,
      type_counts[i],
      type_counts[i] as f32 / total * 100.0
    );
  }

  log::info!("Writing {}...", output_path.display());
  kzt.write(&output_path)?;
  log::info!(
    "Done! Add to kyzu.json: \"kzt\": \"{}\"",
    output_path.display().to_string().replace('\\', "/")
  );

  Ok(())
}
