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

use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::path::Path;

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
  path: std::path::PathBuf,
}

impl EtopoTiff
{
  pub fn open(path: &Path) -> anyhow::Result<Self>
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

    // Log all tags found (helps diagnose new files)
    let mut tag_ids: Vec<u16> = tags.keys().copied().collect();
    tag_ids.sort();
    log::info!("TIFF tags present: {:?}", tag_ids);

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
      log::info!("Layout: tiled {}x{}, {} tiles", tile_width, tile_height, offsets.len());
      Layout::Tiled { tile_width, tile_height, offsets, byte_counts }
    }
    else
    {
      let rows_per_strip = get_u64(&tags, TAG_ROWS_PER_STRIP).unwrap_or(height as u64) as usize;
      let offsets = get_values(&tags, TAG_STRIP_OFFSETS)?;
      let byte_counts = get_values(&tags, TAG_STRIP_BYTE_COUNTS)?;
      log::info!("Layout: stripped, {} strips of {} rows", offsets.len(), rows_per_strip);
      Layout::Stripped { rows_per_strip, offsets, byte_counts }
    };

    log::info!("TIFF: {}x{}, {:?}, {:?}", width, height, sample_format, compression);

    Ok(Self { width, height, endian, sample_format, compression, layout, path: path.to_path_buf() })
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
    match self.sample_format
    {
      SampleFormat::Int16 =>
      {
        let row_bytes = row_width * 2;
        let start = row_idx * row_bytes;
        let end = start + row_bytes;
        anyhow::ensure!(end <= raw.len(), "Row exceeds data ({} > {})", end, raw.len());
        Ok(raw[start..end].chunks_exact(2).map(|b| self.endian.i16([b[0], b[1]])).collect())
      }
      SampleFormat::Float32 =>
      {
        let row_bytes = row_width * 4;
        let start = row_idx * row_bytes;
        let end = start + row_bytes;
        anyhow::ensure!(end <= raw.len(), "Row exceeds data ({} > {})", end, raw.len());
        Ok(
          raw[start..end]
            .chunks_exact(4)
            .map(|b| self.endian.f32([b[0], b[1], b[2], b[3]]).round() as i16)
            .collect(),
        )
      }
    }
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
