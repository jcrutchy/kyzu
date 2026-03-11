use std::sync::Arc;

use glam::{DVec3, Vec3};
use wgpu::util::DeviceExt;

use crate::config::KyzuConfig;
use crate::earth::coords::EnuOrigin;
use crate::earth::heightmap::{Heightmap, LatLonBbox};
use crate::renderer::module::RenderModule;
use crate::renderer::shared::{FrameTargets, SharedState};

// ──────────────────────────────────────────────────────────────
//   Vertex layout
//
//   World-space ENU position + normal + elevation.
//   Eye is subtracted in the shader — chunks never re-upload.
// ──────────────────────────────────────────────────────────────

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Vertex
{
  world_pos: [f32; 3],
  normal: [f32; 3],
  elevation: f32,
}

// ──────────────────────────────────────────────────────────────
//   Chunk — owns GPU buffers and its AABB for frustum culling
// ──────────────────────────────────────────────────────────────

struct Chunk
{
  vertex_buffer: wgpu::Buffer,
  index_buffer: wgpu::Buffer,
  index_count: u32,

  // AABB in world-space ENU for frustum culling (future use)
  // Stored as centre + half-extents
  aabb_centre: Vec3,
  aabb_half: Vec3,
}

// ──────────────────────────────────────────────────────────────
//   Module
// ──────────────────────────────────────────────────────────────

pub struct EarthTerrainModule
{
  chunks: Vec<Chunk>,
  pipeline: wgpu::RenderPipeline,
  /// ENU origin — the flat-patch reference point (bbox centre)
  pub enu_origin: EnuOrigin,
}

impl EarthTerrainModule
{
  /// Called from app.rs after the kernel is ready.
  /// Loads the heightmap and builds all chunk meshes.
  pub fn from_config(
    device: &wgpu::Device,
    shared: &SharedState,
    config: &KyzuConfig,
  ) -> anyhow::Result<Self>
  {
    let bbox = LatLonBbox {
      min_lat: config.startup.bbox.min_lat,
      max_lat: config.startup.bbox.max_lat,
      min_lon: config.startup.bbox.min_lon,
      max_lon: config.startup.bbox.max_lon,
    };

    log::info!("Loading ETOPO heightmap...");
    let heightmap = crate::earth::heightmap::load_bbox(&config.data.etopo_30s, bbox)?;
    log::info!("Heightmap loaded: {}×{} pixels", heightmap.width, heightmap.height);

    let (elev_min, elev_max) = heightmap.elevation_range();
    log::info!("Elevation range: {:.0}m to {:.0}m", elev_min, elev_max);

    // ENU origin at bbox centre
    let centre_lat = (bbox.min_lat + bbox.max_lat) * 0.5;
    let centre_lon = (bbox.min_lon + bbox.max_lon) * 0.5;
    let enu_origin = EnuOrigin::from_latlon_deg(centre_lat, centre_lon);

    let pipeline = create_pipeline(device, shared);
    let chunks = build_chunks(device, &heightmap, &enu_origin);

    log::info!("Built {} terrain chunks", chunks.len());

    Ok(Self { chunks, pipeline, enu_origin })
  }
}

// ──────────────────────────────────────────────────────────────
//   RenderModule impl
//
//   update() is a no-op — chunks are static after init.
//   encode() draws all chunks (frustum culling to be added).
// ──────────────────────────────────────────────────────────────

impl RenderModule for EarthTerrainModule
{
  fn init(_device: &Arc<wgpu::Device>, _queue: &wgpu::Queue, _shared: &SharedState) -> Self
  {
    // EarthTerrainModule is constructed via from_config, not this path.
    // This is only here to satisfy the trait. In practice we register
    // it manually in app.rs using kernel.modules.push(Box::new(...)).
    panic!("EarthTerrainModule must be created via from_config()");
  }

  fn update(&mut self, _queue: &wgpu::Queue, _shared: &SharedState)
  {
    // Nothing — terrain is static. No per-frame uploads.
  }

  fn encode(&self, encoder: &mut wgpu::CommandEncoder, targets: &FrameTargets, shared: &SharedState)
  {
    if self.chunks.is_empty()
    {
      return;
    }

    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
      label: Some("Earth Terrain Pass"),
      color_attachments: &[Some(wgpu::RenderPassColorAttachment {
        view: targets.color,
        resolve_target: None,
        ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
        depth_slice: None,
      })],
      depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
        view: targets.depth,
        depth_ops: Some(wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store }),
        stencil_ops: None,
      }),
      occlusion_query_set: None,
      timestamp_writes: None,
    });

    pass.set_pipeline(&self.pipeline);
    pass.set_bind_group(0, &shared.camera_gpu.bind_group, &[]);

    for chunk in &self.chunks
    {
      pass.set_vertex_buffer(0, chunk.vertex_buffer.slice(..));
      pass.set_index_buffer(chunk.index_buffer.slice(..), wgpu::IndexFormat::Uint32);
      pass.draw_indexed(0..chunk.index_count, 0, 0..1);
    }
  }

  fn as_any_mut(&mut self) -> &mut dyn std::any::Any
  {
    self
  }
}

// ──────────────────────────────────────────────────────────────
//   Chunk building
//
//   The heightmap is divided into tiles of CHUNK_PIXELS×CHUNK_PIXELS.
//   Each tile becomes one GPU mesh.
//   Resolution is downsampled — one vertex per SAMPLE_STRIDE pixels.
// ──────────────────────────────────────────────────────────────

/// Pixels per chunk side. At 30" res, 120px ≈ 1° ≈ ~100km.
/// 240 pixels ≈ 2° ≈ ~200km per chunk side — manageable chunk count.
const CHUNK_PIXELS: usize = 240;

/// Sample every Nth heightmap pixel for mesh vertices.
/// 4 = one vertex per ~4 pixels ≈ one vertex per ~3.6km at 30" res.
/// Gives good shape without excessive vertex count.
const SAMPLE_STRIDE: usize = 4;

fn build_chunks(device: &wgpu::Device, heightmap: &Heightmap, enu_origin: &EnuOrigin)
  -> Vec<Chunk>
{
  let bbox = heightmap.bbox;
  let mut chunks = Vec::new();

  let cols_in_chunks = (heightmap.width + CHUNK_PIXELS - 1) / CHUNK_PIXELS;
  let rows_in_chunks = (heightmap.height + CHUNK_PIXELS - 1) / CHUNK_PIXELS;

  for chunk_row in 0..rows_in_chunks
  {
    for chunk_col in 0..cols_in_chunks
    {
      let px_col_start = chunk_col * CHUNK_PIXELS;
      let px_row_start = chunk_row * CHUNK_PIXELS;
      let px_col_end = (px_col_start + CHUNK_PIXELS).min(heightmap.width);
      let px_row_end = (px_row_start + CHUNK_PIXELS).min(heightmap.height);

      if let Some(chunk) = build_chunk_mesh(
        device,
        heightmap,
        enu_origin,
        &bbox,
        px_col_start,
        px_row_start,
        px_col_end,
        px_row_end,
      )
      {
        chunks.push(chunk);
      }
    }
  }

  chunks
}

fn build_chunk_mesh(
  device: &wgpu::Device,
  heightmap: &Heightmap,
  enu_origin: &EnuOrigin,
  bbox: &LatLonBbox,
  px_col_start: usize,
  px_row_start: usize,
  px_col_end: usize,
  px_row_end: usize,
) -> Option<Chunk>
{
  use crate::earth::heightmap::ETOPO_30S_PIXEL_DEG;

  // Collect sampled vertices
  let col_range: Vec<usize> = (px_col_start..px_col_end).step_by(SAMPLE_STRIDE).collect();
  let row_range: Vec<usize> = (px_row_start..px_row_end).step_by(SAMPLE_STRIDE).collect();

  if col_range.len() < 2 || row_range.len() < 2
  {
    return None;
  }

  let ncols = col_range.len();
  let nrows = row_range.len();

  // Build world-space positions first, then compute normals
  let mut positions: Vec<DVec3> = Vec::with_capacity(ncols * nrows);
  let mut elevations: Vec<f32> = Vec::with_capacity(ncols * nrows);

  for &px_row in &row_range
  {
    for &px_col in &col_range
    {
      // Pixel → lat/lon
      // Row 0 = max_lat (north), col 0 = min_lon (west)
      let lon = bbox.min_lon + px_col as f64 * ETOPO_30S_PIXEL_DEG;
      let lat = bbox.max_lat - px_row as f64 * ETOPO_30S_PIXEL_DEG;
      let elev = heightmap.sample(px_col, px_row) as f64;

      let world = enu_origin.geodetic_to_enu_deg(lat, lon, elev);
      positions.push(world);
      elevations.push(elev as f32);
    }
  }

  // Compute normals via finite difference on the position grid
  let mut vertices: Vec<Vertex> = Vec::with_capacity(ncols * nrows);
  for row in 0..nrows
  {
    for col in 0..ncols
    {
      let idx = row * ncols + col;
      let pos = positions[idx];

      // Neighbours with edge clamping
      let left = positions[row * ncols + col.saturating_sub(1)];
      let right = positions[row * ncols + (col + 1).min(ncols - 1)];
      let up = positions[row.saturating_sub(1) * ncols + col];
      let down = positions[(row + 1).min(nrows - 1) * ncols + col];

      let dx = (right - left).as_vec3();
      let dy = (down - up).as_vec3();
      // Cross product — note dy points south so we negate to get up-facing normal
      let normal = (-dy).cross(dx).normalize_or_zero();

      vertices.push(Vertex {
        world_pos: pos.as_vec3().into(),
        normal: normal.into(),
        elevation: elevations[idx],
      });
    }
  }

  // Build index buffer — two triangles per quad
  let mut indices: Vec<u32> = Vec::with_capacity((ncols - 1) * (nrows - 1) * 6);
  for row in 0..nrows - 1
  {
    for col in 0..ncols - 1
    {
      let tl = (row * ncols + col) as u32;
      let tr = tl + 1;
      let bl = ((row + 1) * ncols + col) as u32;
      let br = bl + 1;

      // Two triangles, consistent winding
      indices.extend_from_slice(&[tl, bl, tr]);
      indices.extend_from_slice(&[tr, bl, br]);
    }
  }

  // Compute AABB for frustum culling
  let (aabb_centre, aabb_half) = compute_aabb(&positions);

  let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
    label: Some("Earth Chunk VB"),
    contents: bytemuck::cast_slice(&vertices),
    usage: wgpu::BufferUsages::VERTEX,
  });

  let index_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
    label: Some("Earth Chunk IB"),
    contents: bytemuck::cast_slice(&indices),
    usage: wgpu::BufferUsages::INDEX,
  });

  Some(Chunk {
    vertex_buffer,
    index_buffer,
    index_count: indices.len() as u32,
    aabb_centre,
    aabb_half,
  })
}

fn compute_aabb(positions: &[DVec3]) -> (Vec3, Vec3)
{
  let mut min = DVec3::splat(f64::INFINITY);
  let mut max = DVec3::splat(f64::NEG_INFINITY);
  for &p in positions
  {
    min = min.min(p);
    max = max.max(p);
  }
  let centre = ((min + max) * 0.5).as_vec3();
  let half = ((max - min) * 0.5).as_vec3();
  (centre, half)
}

// ──────────────────────────────────────────────────────────────
//   Pipeline
// ──────────────────────────────────────────────────────────────

fn create_pipeline(device: &wgpu::Device, shared: &SharedState) -> wgpu::RenderPipeline
{
  let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
    label: Some("Earth Terrain Shader"),
    source: wgpu::ShaderSource::Wgsl(include_str!("../../shaders/earth_terrain.wgsl").into()),
  });

  let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
    label: Some("Earth Terrain Layout"),
    bind_group_layouts: &[&shared.camera_gpu.layout],
    push_constant_ranges: &[],
  });

  device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
    label: Some("Earth Terrain Pipeline"),
    layout: Some(&layout),
    vertex: wgpu::VertexState {
      module: &shader,
      entry_point: Some("vs_main"),
      buffers: &[wgpu::VertexBufferLayout {
        array_stride: std::mem::size_of::<Vertex>() as u64,
        step_mode: wgpu::VertexStepMode::Vertex,
        attributes: &wgpu::vertex_attr_array![
            0 => Float32x3,  // world_pos
            1 => Float32x3,  // normal
            2 => Float32,    // elevation
        ],
      }],
      compilation_options: wgpu::PipelineCompilationOptions::default(),
    },
    fragment: Some(wgpu::FragmentState {
      module: &shader,
      entry_point: Some("fs_main"),
      targets: &[Some(wgpu::ColorTargetState {
        format: shared.surface_format,
        blend: Some(wgpu::BlendState::REPLACE),
        write_mask: wgpu::ColorWrites::ALL,
      })],
      compilation_options: wgpu::PipelineCompilationOptions::default(),
    }),
    primitive: wgpu::PrimitiveState {
      topology: wgpu::PrimitiveTopology::TriangleList,
      cull_mode: Some(wgpu::Face::Back),
      ..Default::default()
    },
    depth_stencil: Some(wgpu::DepthStencilState {
      format: shared.depth_format,
      depth_write_enabled: true,
      depth_compare: wgpu::CompareFunction::Less,
      stencil: wgpu::StencilState::default(),
      bias: wgpu::DepthBiasState::default(),
    }),
    multisample: wgpu::MultisampleState::default(),
    multiview: None,
    cache: None,
  })
}
