// ──────────────────────────────────────────────────────────────
//   Minimal GeoTIFF reader for ETOPO elevation data
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

    let mut tags: HashMap<u16, TagValue> = HashMap::new();
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

    let layout = if tags.contains_key(&TAG_TILE_OFFSETS)
    {
      let tile_width = get_u64(&tags, TAG_TILE_WIDTH)? as usize;
      let tile_height = get_u64(&tags, TAG_TILE_LENGTH)? as usize;
      let offsets = get_values(&tags, TAG_TILE_OFFSETS)?;
      let byte_counts = get_values(&tags, TAG_TILE_BYTE_COUNTS)?;
      Layout::Tiled { tile_width, tile_height, offsets, byte_counts }
    }
    else
    {
      let rows_per_strip = get_u64(&tags, TAG_ROWS_PER_STRIP).unwrap_or(height as u64) as usize;
      let offsets = get_values(&tags, TAG_STRIP_OFFSETS)?;
      let byte_counts = get_values(&tags, TAG_STRIP_BYTE_COUNTS)?;
      Layout::Stripped { rows_per_strip, offsets, byte_counts }
    };

    logger.emit(
      LogLevel::Info,
      &format!("TIFF: {}x{}, {:?}, {:?}", width, height, sample_format, compression),
    );

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

    let (tile_index, tile_info) = match &self.layout
    {
      Layout::Stripped { .. } => (y, None),
      Layout::Tiled { tile_width, tile_height, offsets, byte_counts } =>
      {
        let tiles_across = (self.width + tile_width - 1) / tile_width;
        let tile_x = x / tile_width;
        let tile_y = y / tile_height;
        let idx = tile_y * tiles_across + tile_x;
        (idx, Some((*tile_width, *tile_height, offsets[idx], byte_counts[idx])))
      }
    };

    if !self.row_cache.contains_key(&tile_index)
    {
      if let Some((tw, th, offset, count)) = tile_info
      {
        // Tiled Logic
        match self.decompress_internal(offset, count as usize)
        {
          Ok(compressed) =>
          {
            let samples = self.decode_tile_bytes(&compressed);
            // Ensure the samples vector is actually the size we expect
            if samples.len() >= tw * th
            {
              self.row_cache.insert(tile_index, samples);
            }
            else
            {
              // Insert a dummy to prevent re-trying a broken tile
              self.row_cache.insert(tile_index, vec![0; tw * th]);
            }
          }
          Err(_) =>
          {
            self.row_cache.insert(tile_index, vec![0; tw * th]);
          }
        }
      }
      else
      {
        // Stripped Logic
        if let Ok(row_data) = self.read_row_internal(tile_index)
        {
          self.row_cache.insert(tile_index, row_data);
        }
        else
        {
          self.row_cache.insert(tile_index, vec![0; self.width]);
        }
      }
    }

    // Safe to unwrap because we just ensured it exists
    let data = &self.row_cache[&tile_index];

    if let Some((tw, _, _, _)) = tile_info
    {
      let local_x = x % tw;
      let local_y = y % (data.len() / tw);
      let idx = local_y * tw + local_x;
      if idx < data.len()
      {
        data[idx]
      }
      else
      {
        0
      }
    }
    else
    {
      if x < data.len()
      {
        data[x]
      }
      else
      {
        0
      }
    }
  }

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

      let mut row_bytes = data[row_start..row_end].to_vec();
      for i in 1..tile_w * 4
      {
        row_bytes[i] = row_bytes[i].wrapping_add(row_bytes[i - 1]);
      }

      for i in 0..tile_w
      {
        deshuffled[row_start + i * 4 + 0] = row_bytes[i + tile_w * 3]; // B1
        deshuffled[row_start + i * 4 + 1] = row_bytes[i + tile_w * 2]; // B2
        deshuffled[row_start + i * 4 + 2] = row_bytes[i + tile_w * 1]; // B3
        deshuffled[row_start + i * 4 + 3] = row_bytes[i + tile_w * 0]; // B4
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

  /// Internal read_row that uses the existing reader
  fn read_row_internal(&mut self, row: usize) -> anyhow::Result<Vec<i16>>
  {
    match &self.layout
    {
      Layout::Stripped { rows_per_strip, offsets, byte_counts } =>
      {
        let strip_idx = row / rows_per_strip;
        let row_in_strip = row % rows_per_strip;
        let raw = self.decompress_internal(offsets[strip_idx], byte_counts[strip_idx] as usize)?;
        self.decode_row_logic(&raw, row_in_strip, self.width)
      }
      Layout::Tiled { .. } => anyhow::bail!("Use get_sample for tiled layouts"),
    }
  }

  fn decode_row_logic(
    &self,
    raw: &[u8],
    row_idx: usize,
    row_width: usize,
  ) -> anyhow::Result<Vec<i16>>
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
    Ok(samples)
  }

  fn decompress_internal(&mut self, offset: u64, byte_count: usize) -> anyhow::Result<Vec<u8>>
  {
    self.reader.seek(SeekFrom::Start(offset))?;
    let mut buf = vec![0u8; byte_count];
    self.reader.read_exact(&mut buf)?;

    match self.compression
    {
      Compression::None => Ok(buf),
      Compression::Deflate =>
      {
        let mut dec = ZlibDecoder::new(&buf[..]);
        let mut out = Vec::new();
        dec.read_to_end(&mut out)?;
        Ok(out)
      }
    }
  }
}

// ── IFD helpers ───────────────────────────────────────────────

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
        _ =>
        {
          let mut t = [0u8; 4];
          let n = sz.min(4).min(buf.len() - s);
          t[..n].copy_from_slice(&buf[s..s + n]);
          e.u32(t) as u64
        }
      })
    })
    .collect()
}

fn get_u64(tags: &HashMap<u16, TagValue>, tag: u16) -> anyhow::Result<u64>
{
  tags
    .get(&tag)
    .ok_or_else(|| anyhow::anyhow!("Missing tag {}", tag))?
    .values
    .first()
    .copied()
    .ok_or_else(|| anyhow::anyhow!("Tag {} empty", tag))
}

fn get_values(tags: &HashMap<u16, TagValue>, tag: u16) -> anyhow::Result<Vec<u64>>
{
  Ok(tags.get(&tag).ok_or_else(|| anyhow::anyhow!("Missing tag {}", tag))?.values.clone())
}
