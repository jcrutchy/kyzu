// ──────────────────────────────────────────────────────────────
//   Minimal GeoTIFF reader for ETOPO elevation data
//
//   Supports:
//     - Classic TIFF (v42) and BigTIFF (v43)
//     - Little-endian and big-endian
//     - 16-bit signed int and 32-bit float samples
//     - Stripped layout AND tiled layout
//     - No compression (1) and Deflate/zlib (8)
//
//   Output is always Vec<i16> metres.
//   Silent — nothing written to stdout or stderr.
// ──────────────────────────────────────────────────────────────

use std::collections::HashMap;
use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::path::Path;

use flate2::read::ZlibDecoder;

use crate::core::log::{LogLevel, Logger};

const TAG_IMAGE_WIDTH: u16 = 256;
const TAG_IMAGE_LENGTH: u16 = 257;
const TAG_BITS_PER_SAMPLE: u16 = 258;
const TAG_COMPRESSION: u16 = 259;
const TAG_SAMPLE_FORMAT: u16 = 339;
const TAG_ROWS_PER_STRIP: u16 = 278;
const TAG_STRIP_OFFSETS: u16 = 273;
const TAG_STRIP_BYTE_COUNTS: u16 = 279;
const TAG_TILE_WIDTH: u16 = 322;
const TAG_TILE_LENGTH: u16 = 323;
const TAG_TILE_OFFSETS: u16 = 324;
const TAG_TILE_BYTE_COUNTS: u16 = 325;

// ── Byte order ────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq)]
enum Endian
{
  Little,
  Big,
}

impl Endian
{
  fn u16(self, b: [u8; 2]) -> u16
  {
    match self
    {
      Self::Little => u16::from_le_bytes(b),
      Self::Big => u16::from_be_bytes(b),
    }
  }
  fn u32(self, b: [u8; 4]) -> u32
  {
    match self
    {
      Self::Little => u32::from_le_bytes(b),
      Self::Big => u32::from_be_bytes(b),
    }
  }
  fn u64(self, b: [u8; 8]) -> u64
  {
    match self
    {
      Self::Little => u64::from_le_bytes(b),
      Self::Big => u64::from_be_bytes(b),
    }
  }
  fn i16(self, b: [u8; 2]) -> i16
  {
    match self
    {
      Self::Little => i16::from_le_bytes(b),
      Self::Big => i16::from_be_bytes(b),
    }
  }
  fn f32(self, b: [u8; 4]) -> f32
  {
    f32::from_bits(match self
    {
      Self::Little => u32::from_le_bytes(b),
      Self::Big => u32::from_be_bytes(b),
    })
  }
}

// ── Formats ───────────────────────────────────────────────────

#[derive(Clone, Copy, Debug)]
enum SampleFormat
{
  Int16,
  Float32,
}

#[derive(Clone, Copy, Debug)]
enum Compression
{
  None,
  Deflate,
}

// ── Layout ────────────────────────────────────────────────────

enum Layout
{
  Stripped
  {
    rows_per_strip: usize, offsets: Vec<u64>, byte_counts: Vec<u64>
  },
  Tiled
  {
    tile_width: usize, tile_height: usize, offsets: Vec<u64>, byte_counts: Vec<u64>
  },
}

struct TagValue
{
  #[allow(dead_code)]
  count: u64,
  values: Vec<u64>,
}

// ── Public struct ─────────────────────────────────────────────

pub struct EtopoTiff
{
  pub width: usize,
  pub height: usize,
  endian: Endian,
  sample_format: SampleFormat,
  compression: Compression,
  layout: Layout,
  pub path: std::path::PathBuf,
  pub row_cache: HashMap<usize, Vec<i16>>,
  reader: BufReader<File>,
}

impl EtopoTiff
{
  pub fn open(path: &Path, logger: &mut Logger) -> anyhow::Result<Self>
  {
    let file = File::open(path)?;
    let mut r = BufReader::new(file);

    // Header
    let mut hdr = [0u8; 4];
    r.read_exact(&mut hdr)?;
    let endian = match &hdr[0..2]
    {
      b"II" => Endian::Little,
      b"MM" => Endian::Big,
      _ => anyhow::bail!("Not a TIFF file"),
    };
    let version = endian.u16([hdr[2], hdr[3]]);
    let (bigtiff, ifd_offset) = match version
    {
      42 =>
      {
        let mut b = [0u8; 4];
        r.read_exact(&mut b)?;
        (false, endian.u32(b) as u64)
      }
      43 =>
      {
        let mut b = [0u8; 12];
        r.read_exact(&mut b)?;
        (true, endian.u64([b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11]]))
      }
      v => anyhow::bail!("Unsupported TIFF version {}", v),
    };

    // IFD
    r.seek(SeekFrom::Start(ifd_offset))?;
    let entry_count = if bigtiff
    {
      let mut b = [0u8; 8];
      r.read_exact(&mut b)?;
      endian.u64(b) as usize
    }
    else
    {
      let mut b = [0u8; 2];
      r.read_exact(&mut b)?;
      endian.u16(b) as usize
    };
    let mut tags: std::collections::HashMap<u16, TagValue> = Default::default();
    for _ in 0..entry_count
    {
      let (tag, val) = if bigtiff
      {
        read_entry_bigtiff(&mut r, endian)?
      }
      else
      {
        read_entry_classic(&mut r, endian)?
      };
      tags.insert(tag, val);
    }

    let mut tag_ids: Vec<u16> = tags.keys().copied().collect();
    tag_ids.sort();

    /*logger.emit(LogLevel::Info, &format!("TIFF tags present: {:?}", tag_ids));

    logger.emit(LogLevel::Info, "--- ALL TIFF TAGS FOUND ---");
    let mut tag_ids: Vec<u16> = tags.keys().copied().collect();
    tag_ids.sort();
    for id in tag_ids
    {
      if let Some(tag_val) = tags.get(&id)
      {
        let name = get_tag_name(id);
        let first_val = tag_val.values.first().copied().unwrap_or(0);
        logger.emit(LogLevel::Info, &format!("Tag {:3}: {:25} | Value: {}", id, name, first_val));
      }
    }
    logger.emit(LogLevel::Info, "---------------------------");*/

    // Required fields
    let width = get_u64(&tags, TAG_IMAGE_WIDTH)? as usize;
    let height = get_u64(&tags, TAG_IMAGE_LENGTH)? as usize;

    let bits = get_u64(&tags, TAG_BITS_PER_SAMPLE).unwrap_or(16);
    let fmt_code = get_u64(&tags, TAG_SAMPLE_FORMAT).unwrap_or(1);
    let sample_format = match (bits, fmt_code)
    {
      (16, 1) | (16, 2) => SampleFormat::Int16,
      (32, _) => SampleFormat::Float32,
      _ => anyhow::bail!("Unsupported: {} bits, format code {}", bits, fmt_code),
    };

    let comp_code = get_u64(&tags, TAG_COMPRESSION).unwrap_or(1);
    let compression = match comp_code
    {
      1 => Compression::None,
      8 => Compression::Deflate,
      c => anyhow::bail!("Unsupported compression: {}", c),
    };

    // Layout — tiled takes priority over stripped
    let layout = if tags.contains_key(&TAG_TILE_OFFSETS)
    {
      let tile_width = get_u64(&tags, TAG_TILE_WIDTH)? as usize;
      let tile_height = get_u64(&tags, TAG_TILE_LENGTH)? as usize;
      let offsets = get_values(&tags, TAG_TILE_OFFSETS)?;
      let byte_counts = get_values(&tags, TAG_TILE_BYTE_COUNTS)?;
      logger.emit(
        LogLevel::Info,
        &format!("Layout: tiled {}x{}, {} tiles", tile_width, tile_height, offsets.len()),
      );
      Layout::Tiled { tile_width, tile_height, offsets, byte_counts }
    }
    else
    {
      let rows_per_strip = get_u64(&tags, TAG_ROWS_PER_STRIP).unwrap_or(height as u64) as usize;
      let offsets = get_values(&tags, TAG_STRIP_OFFSETS)?;
      let byte_counts = get_values(&tags, TAG_STRIP_BYTE_COUNTS)?;
      logger.emit(
        LogLevel::Info,
        &format!("Layout: stripped, {} strips of {} rows", offsets.len(), rows_per_strip),
      );
      Layout::Stripped { rows_per_strip, offsets, byte_counts }
    };

    logger.emit(
      LogLevel::Info,
      &format!("TIFF: {}x{}, {:?}, {:?}", width, height, sample_format, compression),
    );

    logger.emit(LogLevel::Info, "--- TIFF DEBUG INFO ---");
    logger.emit(LogLevel::Info, &format!("Path: {:?}", path));
    logger.emit(LogLevel::Info, &format!("Dimensions: {} x {}", width, height));
    logger.emit(
      LogLevel::Info,
      &format!("Endian: {}", if matches!(endian, Endian::Little) { "Little" } else { "Big" }),
    );
    logger.emit(LogLevel::Info, &format!("Format: {:?}", sample_format));
    logger.emit(LogLevel::Info, &format!("Compression: {:?}", compression));
    match &layout
    {
      Layout::Stripped { rows_per_strip, offsets, .. } =>
      {
        logger.emit(
          LogLevel::Info,
          &format!("Layout: Stripped ({} rows/strip, {} strips)", rows_per_strip, offsets.len()),
        );
      }
      Layout::Tiled { tile_width, tile_height, offsets, .. } =>
      {
        logger.emit(
          LogLevel::Info,
          &format!("Layout: Tiled ({}x{}, {} tiles)", tile_width, tile_height, offsets.len()),
        );
      }
    }
    logger.emit(LogLevel::Info, "-----------------------");

    Ok(Self {
      width,
      height,
      endian,
      sample_format,
      compression,
      layout,
      path: path.to_path_buf(),
      row_cache: HashMap::new(),
      reader: r,
    })
  }

  pub fn get_sample(&mut self, x: usize, y: usize) -> i16
  {
    let x = x.min(self.width - 1);
    let y = y.min(self.height - 1);

    match &self.layout
    {
      Layout::Stripped { .. } =>
      {
        if !self.row_cache.contains_key(&y)
        {
          if let Ok(row_data) = self.read_row(y)
          {
            self.row_cache.insert(y, row_data);
          }
          else
          {
            return 0;
          }
        }
        self.row_cache[&y][x]
      }
      Layout::Tiled { tile_width, tile_height, offsets, byte_counts } =>
      {
        let tiles_across = (self.width + tile_width - 1) / tile_width;
        let tile_x = x / tile_width;
        let tile_y = y / tile_height;
        let tile_index = tile_y * tiles_across + tile_x;

        if !self.row_cache.contains_key(&tile_index)
        {
          let offset = offsets[tile_index];
          let count = byte_counts[tile_index];

          let mut compressed = vec![0u8; count as usize];
          if self.reader.seek(SeekFrom::Start(offset)).is_ok()
          {
            if self.reader.read_exact(&mut compressed).is_ok()
            {
              let samples = match self.compression
              {
                Compression::Deflate =>
                {
                  let mut decoder = ZlibDecoder::new(&compressed[..]);
                  let mut decompressed = Vec::new();
                  if decoder.read_to_end(&mut decompressed).is_ok()
                  {
                    self.decode_tile_bytes(&decompressed)
                  }
                  else
                  {
                    vec![0; tile_width * tile_height]
                  }
                }
                Compression::None => self.decode_tile_bytes(&compressed),
              };
              self.row_cache.insert(tile_index, samples);
            }
          }
        }

        // If cache miss failed to fill, return 0
        if !self.row_cache.contains_key(&tile_index)
        {
          return 0;
        }

        let local_x = x % tile_width;
        let local_y = y % tile_height;
        let pixel_idx = local_y * tile_width + local_x;
        self.row_cache[&tile_index][pixel_idx]
      }
    }
  }

  /*
  ### Developer Note: The "Predictor 3" Interleave
  **File:** `src/bake/tiff_reader.rs`
  **Context:** Decoding ETOPO 2022 Floating Point GeoTIFFs

  > **The Problem:** > When TIFF Tag 317 (Predictor) is set to **3**, the data is not stored as standard `f32` chunks. To maximize Deflate compression, the engine shuffles the 4 bytes of every float into **planar rows**.
  >
  > **The Layout (Planar):**
  > Instead of `[B1,B2,B3,B4]`, `[B1,B2,B3,B4]`, the row is stored as:
  > `[All Byte 4s (MSB)]` + `[All Byte 3s]` + `[All Byte 2s]` + `[All Byte 1s (LSB)]`
  >
  > **The Reconstruction Steps:**
  > 1. **Horizontal Differencing:** Reconstruct the absolute value of each byte plane by applying a `wrapping_add` across the entire row.
  > 2. **Interleaving:** Reach into the four different "planes" and pull one byte from each to reassemble a valid `f32` bit-pattern.
  > 3. **Endianness:** Regardless of the TIFF being "II" or "MM", the Predictor 3 planes are always stored from Most Significant (B4) to Least Significant (B1). We map them back to the order expected by our `Endian` helper.
  */

  fn decode_tile_bytes(&self, data: &[u8]) -> Vec<i16>
  {
    let (tile_w, tile_h) = match self.layout
    {
      Layout::Tiled { tile_width, tile_height, .. } => (tile_width, tile_height),
      _ => (self.width, 1),
    };

    let mut deshuffled = vec![0u8; data.len()];

    for row_idx in 0..tile_h
    {
      let row_start = row_idx * tile_w * 4;
      let row_end = row_start + (tile_w * 4);
      if row_end > data.len()
      {
        break;
      }

      // 1. Copy the row data into a temporary buffer so we can difference it
      let mut row_bytes = data[row_start..row_end].to_vec();

      // 2. Horizontal Differencing happens WITHIN the planes
      // Reconstruct each byte plane by adding the previous byte in that plane
      for i in 1..tile_w * 4
      {
        row_bytes[i] = row_bytes[i].wrapping_add(row_bytes[i - 1]);
      }

      // 3. Interleave the bytes back into f32 chunks
      // Planar: [B4...][B3...][B2...][B1...]
      for i in 0..tile_w
      {
        deshuffled[row_start + i * 4 + 0] = row_bytes[i + tile_w * 3]; // B1 (LSB)
        deshuffled[row_start + i * 4 + 1] = row_bytes[i + tile_w * 2]; // B2
        deshuffled[row_start + i * 4 + 2] = row_bytes[i + tile_w * 1]; // B3
        deshuffled[row_start + i * 4 + 3] = row_bytes[i + tile_w * 0]; // B4 (MSB)
      }
    }

    deshuffled
      .chunks_exact(4)
      .map(|b| {
        let f = self.endian.f32([b[0], b[1], b[2], b[3]]);
        if !f.is_finite() || f < -12000.0 || f > 10000.0
        {
          0
        }
        else
        {
          f.round() as i16
        }
      })
      .collect()
  }

  pub fn strip_count(&self) -> usize
  {
    match &self.layout
    {
      Layout::Stripped { offsets, .. } => offsets.len(),
      Layout::Tiled { offsets, .. } => offsets.len(),
    }
  }

  /// Read one row as i16 metres.
  pub fn read_row(&self, row: usize) -> anyhow::Result<Vec<i16>>
  {
    anyhow::ensure!(row < self.height, "Row {} out of bounds", row);
    match &self.layout
    {
      Layout::Stripped { rows_per_strip, offsets, byte_counts } =>
      {
        let strip_idx = row / rows_per_strip;
        let row_in_strip = row % rows_per_strip;
        let raw = self.decompress(offsets[strip_idx], byte_counts[strip_idx] as usize)?;
        self.decode_row(&raw, row_in_strip, self.width)
      }
      Layout::Tiled { tile_width, tile_height, offsets, byte_counts } =>
      {
        let tiles_across = (self.width + tile_width - 1) / tile_width;
        let tile_row = row / tile_height;
        let row_in_tile = row % tile_height;
        let mut out = Vec::with_capacity(self.width);

        for tile_col in 0..tiles_across
        {
          let tile_idx = tile_row * tiles_across + tile_col;
          let raw = self.decompress(offsets[tile_idx], byte_counts[tile_idx] as usize)?;

          // How many columns this tile covers (last tile may be partial)
          let col_start = tile_col * tile_width;
          let cols_in_tile = (*tile_width).min(self.width - col_start);

          // Decode the row within this tile
          // Tile is stored as tile_height rows of tile_width samples
          let row_samples = self.decode_row(&raw, row_in_tile, *tile_width)?;
          out.extend_from_slice(&row_samples[..cols_in_tile]);
        }

        Ok(out)
      }
    }
  }

  fn decode_row(&self, raw: &[u8], row_idx: usize, row_width: usize) -> anyhow::Result<Vec<i16>>
  {
    let samples: Vec<i16> = match self.sample_format
    {
      SampleFormat::Int16 =>
      {
        let start = row_idx * (row_width * 2);
        raw[start..start + (row_width * 2)]
          .chunks_exact(2)
          .map(|b| self.endian.i16([b[0], b[1]]))
          .collect()
      }
      SampleFormat::Float32 =>
      {
        let start = row_idx * (row_width * 4);
        raw[start..start + (row_width * 4)]
          .chunks_exact(4)
          .map(|b| self.endian.f32([b[0], b[1], b[2], b[3]]).round() as i16)
          .collect()
      }
    };
    // If we find that 32767, print the FIRST 4 BYTES of the raw row data
    if samples.iter().any(|&s| s == 32767)
    {
      //logger.emit(LogLevel::Critical, &format!("Row {} contains 32767. Raw data start: {:02X?}",row_idx,&raw[0..4.min(raw.len())]));
    }
    Ok(samples)
  }

  fn decompress(&self, offset: u64, byte_count: usize) -> anyhow::Result<Vec<u8>>
  {
    let mut file = File::open(&self.path)?;
    file.seek(SeekFrom::Start(offset))?;
    let mut buf = vec![0u8; byte_count];
    file.read_exact(&mut buf)?;

    match self.compression
    {
      Compression::None => Ok(buf),
      Compression::Deflate =>
      {
        use flate2::read::ZlibDecoder;
        let mut dec = ZlibDecoder::new(&buf[..]);
        let mut out = Vec::new();
        dec.read_to_end(&mut out)?;
        Ok(out)
      }
    }
  }
}

// ── IFD readers ───────────────────────────────────────────────

fn read_entry_classic<R: Read + Seek>(r: &mut R, e: Endian) -> anyhow::Result<(u16, TagValue)>
{
  let mut b = [0u8; 12];
  r.read_exact(&mut b)?;
  let tag = e.u16([b[0], b[1]]);
  let ftype = e.u16([b[2], b[3]]);
  let count = e.u32([b[4], b[5], b[6], b[7]]) as u64;
  let total = count * tiff_type_size(ftype) as u64;
  let values = if total <= 4
  {
    read_vals(&b[8..12], ftype, count, e)
  }
  else
  {
    let off = e.u32([b[8], b[9], b[10], b[11]]) as u64;
    let pos = r.stream_position()?;
    r.seek(SeekFrom::Start(off))?;
    let mut buf = vec![0u8; total as usize];
    r.read_exact(&mut buf)?;
    r.seek(SeekFrom::Start(pos))?;
    read_vals(&buf, ftype, count, e)
  };
  Ok((tag, TagValue { count, values }))
}

fn read_entry_bigtiff<R: Read + Seek>(r: &mut R, e: Endian) -> anyhow::Result<(u16, TagValue)>
{
  let mut b = [0u8; 20];
  r.read_exact(&mut b)?;
  let tag = e.u16([b[0], b[1]]);
  let ftype = e.u16([b[2], b[3]]);
  let count = e.u64([b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11]]);
  let total = count * tiff_type_size(ftype) as u64;
  let values = if total <= 8
  {
    read_vals(&b[12..20], ftype, count, e)
  }
  else
  {
    let off = e.u64([b[12], b[13], b[14], b[15], b[16], b[17], b[18], b[19]]);
    let pos = r.stream_position()?;
    r.seek(SeekFrom::Start(off))?;
    let mut buf = vec![0u8; total as usize];
    r.read_exact(&mut buf)?;
    r.seek(SeekFrom::Start(pos))?;
    read_vals(&buf, ftype, count, e)
  };
  Ok((tag, TagValue { count, values }))
}

fn tiff_type_size(t: u16) -> usize
{
  match t
  {
    1 | 2 | 6 | 7 => 1,
    3 | 8 => 2,
    4 | 9 | 11 => 4,
    5 | 10 | 12 => 8,
    16 | 17 | 18 => 8,
    _ => 4,
  }
}

fn read_vals(buf: &[u8], ftype: u16, count: u64, e: Endian) -> Vec<u64>
{
  let sz = tiff_type_size(ftype);
  (0..count as usize)
    .filter_map(|i| {
      let s = i * sz;
      if s + sz > buf.len()
      {
        return None;
      }
      Some(match (ftype, sz)
      {
        (3, 2) | (8, 2) => e.u16([buf[s], buf[s + 1]]) as u64,
        (4, 4) | (9, 4) | (11, 4) => e.u32([buf[s], buf[s + 1], buf[s + 2], buf[s + 3]]) as u64,
        (16, 8) | (17, 8) | (18, 8) => e.u64([
          buf[s],
          buf[s + 1],
          buf[s + 2],
          buf[s + 3],
          buf[s + 4],
          buf[s + 5],
          buf[s + 6],
          buf[s + 7],
        ]),
        (1, 1) | (2, 1) | (6, 1) | (7, 1) => buf[s] as u64,
        _ =>
        {
          let n = sz.min(4).min(buf.len() - s);
          let mut t = [0u8; 4];
          t[..n].copy_from_slice(&buf[s..s + n]);
          e.u32(t) as u64
        }
      })
    })
    .collect()
}

fn get_u64(tags: &std::collections::HashMap<u16, TagValue>, tag: u16) -> anyhow::Result<u64>
{
  tags
    .get(&tag)
    .ok_or_else(|| anyhow::anyhow!("Missing TIFF tag {}", tag))?
    .values
    .first()
    .copied()
    .ok_or_else(|| anyhow::anyhow!("Tag {} empty", tag))
}

fn get_values(tags: &std::collections::HashMap<u16, TagValue>, tag: u16)
  -> anyhow::Result<Vec<u64>>
{
  Ok(tags.get(&tag).ok_or_else(|| anyhow::anyhow!("Missing TIFF tag {}", tag))?.values.clone())
}

// Add this helper to turn IDs into names
#[allow(dead_code)]
fn get_tag_name(id: u16) -> &'static str
{
  match id
  {
    256 => "ImageWidth",
    257 => "ImageLength",
    258 => "BitsPerSample",
    259 => "Compression",
    262 => "PhotometricInterpretation",
    273 => "StripOffsets",
    274 => "Orientation",
    277 => "SamplesPerPixel",
    278 => "RowsPerStrip",
    279 => "StripByteCounts",
    284 => "PlanarConfiguration",
    317 => "Predictor", // <--- THIS IS THE ONE WE ARE LOOKING FOR
    322 => "TileWidth",
    323 => "TileLength",
    324 => "TileOffsets",
    325 => "TileByteCounts",
    339 => "SampleFormat",
    _ => "Unknown",
  }
}
