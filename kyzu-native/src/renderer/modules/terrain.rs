use std::sync::Arc;

use glam::DVec3;
use wgpu::util::DeviceExt;

use crate::renderer::module::RenderModule;
use crate::renderer::shared::{FrameTargets, SharedState};

// ──────────────────────────────────────────────────────────────
//   Public terrain configuration
// ──────────────────────────────────────────────────────────────

pub struct TerrainConfig
{
  // Noise parameters — user-editable via egui
  pub noise_scale: f32,
  pub amplitude: f32,
  pub octaves: u32,
  pub persistence: f32,
  pub lacunarity: f32,
  pub seed_offset: f32,
  pub wireframe: bool,
  pub grid_dims: (u32, u32),
}

impl Default for TerrainConfig
{
  fn default() -> Self
  {
    Self {
      noise_scale: 300.0,
      amplitude: 80.0,
      octaves: 6,
      persistence: 0.5,
      lacunarity: 2.0,
      seed_offset: 0.0,
      wireframe: false,
      grid_dims: (7, 7),
    }
  }
}

// ──────────────────────────────────────────────────────────────
//   LOD tier
//
//   chunk_size snaps to powers of two, driven by camera radius.
//   LOD transitions always land on clean doublings, and every
//   chunk_size is an exact multiple of all smaller chunk_sizes.
//   Because chunk origins are always multiples of chunk_size in
//   world space, a rebuilt grid samples the same world_xy coords
//   as the previous tier — no terrain pop on LOD change.
//
//   fade_far = max(radius * 15, 80) — matches CameraModule.
//   chunk_size = largest power-of-two ≤ fade_far / CHUNKS_PER_SIDE.
// ──────────────────────────────────────────────────────────────

/// How many chunk-widths we want visible per side of centre.
const CHUNKS_PER_SIDE: f64 = 3.0;

fn chunk_size_for_radius(radius: f64) -> f64
{
  let fade_far = (radius * 15.0).max(80.0);
  let ideal = fade_far / CHUNKS_PER_SIDE;
  let exp = ideal.log2().floor() as i32;
  (2.0_f64).powi(exp).max(1.0)
}

/// Snap a world coordinate down to the nearest multiple of chunk_size.
/// All chunk origins use this so they land on consistent world positions
/// across LOD tiers (power-of-two sizes guarantee alignment).
fn snap_to_grid(v: f64, chunk_size: f64) -> f64
{
  (v / chunk_size).floor() * chunk_size
}

// ──────────────────────────────────────────────────────────────
//   GPU uniform
// ──────────────────────────────────────────────────────────────

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct TerrainUniform
{
  noise_scale: f32,
  amplitude: f32,
  octaves: u32,
  persistence: f32,
  lacunarity: f32,
  seed_offset: f32,
  wireframe: u32,
  _pad: f32,
}

const _: () = assert!(std::mem::size_of::<TerrainUniform>() == 32);

// ──────────────────────────────────────────────────────────────
//   Vertex layout
// ──────────────────────────────────────────────────────────────

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Vertex
{
  pos_rel: [f32; 3],  // camera-relative XY, Z=0 (shader displaces Z)
  world_xy: [f32; 2], // absolute world XY for noise sampling
  bary: [f32; 3],     // barycentric coordinate for wireframe
}

// ──────────────────────────────────────────────────────────────
//   Chunk
//
//   Each chunk owns its GPU buffers and tracks its current
//   position in chunk-grid space (integer coords, not world units).
//   When streaming, a chunk's grid_coord is reassigned to the new
//   leading-edge position and its vertex buffer is re-uploaded.
//   No GPU allocations happen after init.
// ──────────────────────────────────────────────────────────────

struct Chunk
{
  vertex_buffer: wgpu::Buffer,
  index_buffer: wgpu::Buffer,
  index_count: u32,
  grid_coord: (i64, i64),
  /// World-space size of this chunk — stored per-chunk so it stays
  /// valid across LOD rebuilds without needing the module's chunk_size.
  chunk_size: f64,
}

impl Chunk
{
  fn world_origin(&self) -> DVec3
  {
    // Origins are always world-snapped multiples of chunk_size —
    // computed here rather than stored so they're always consistent.
    DVec3::new(
      snap_to_grid(self.grid_coord.0 as f64 * self.chunk_size, self.chunk_size),
      snap_to_grid(self.grid_coord.1 as f64 * self.chunk_size, self.chunk_size),
      0.0,
    )
  }
}

// ──────────────────────────────────────────────────────────────
//   Module
// ──────────────────────────────────────────────────────────────

pub struct TerrainModule
{
  device: Arc<wgpu::Device>,
  chunks: Vec<Chunk>,
  terrain_uniform_buffer: wgpu::Buffer,
  terrain_bind_group: wgpu::BindGroup,
  pipeline: wgpu::RenderPipeline,
  pub config: TerrainConfig,
  /// Chunk-grid coord the grid was last centred on.
  last_center: (i64, i64),
  /// The chunk_size used when the current chunk pool was allocated.
  /// When radius drifts far enough from this, we rebuild.
  active_chunk_size: f64,
  /// Camera radius at last frame — used to detect LOD tier changes.
  last_radius: f64,
}

impl RenderModule for TerrainModule
{
  fn init(device: &Arc<wgpu::Device>, _queue: &wgpu::Queue, shared: &SharedState) -> Self
  {
    let device_arc = Arc::clone(device);
    let config = TerrainConfig::default();
    let initial_radius = shared.camera.radius as f64;
    let chunk_size = chunk_size_for_radius(initial_radius);

    let terrain_uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
      label: Some("Terrain Uniform Buffer"),
      size: std::mem::size_of::<TerrainUniform>() as u64,
      usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
      mapped_at_creation: false,
    });

    let terrain_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
      label: Some("Terrain BGL"),
      entries: &[wgpu::BindGroupLayoutEntry {
        binding: 0,
        visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
        ty: wgpu::BindingType::Buffer {
          ty: wgpu::BufferBindingType::Uniform,
          has_dynamic_offset: false,
          min_binding_size: None,
        },
        count: None,
      }],
    });

    let terrain_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
      label: Some("Terrain BG"),
      layout: &terrain_bgl,
      entries: &[wgpu::BindGroupEntry {
        binding: 0,
        resource: terrain_uniform_buffer.as_entire_binding(),
      }],
    });

    let pipeline = create_pipeline(device, shared, &terrain_bgl);

    let center = (0i64, 0i64);
    let chunks = allocate_chunks(device, &config, center, chunk_size);

    Self {
      device: device_arc,
      chunks,
      terrain_uniform_buffer,
      terrain_bind_group,
      pipeline,
      config,
      last_center: center,
      active_chunk_size: chunk_size,
      last_radius: initial_radius,
    }
  }

  fn update(&mut self, queue: &wgpu::Queue, shared: &SharedState)
  {
    let radius = shared.camera.radius as f64;
    let desired_chunk_size = chunk_size_for_radius(radius);

    // noise_scale is always sent as-is — no scaling. The shader samples
    // the same world_xy regardless of zoom so terrain is always consistent.
    let uniform = TerrainUniform {
      noise_scale: self.config.noise_scale,
      amplitude: self.config.amplitude,
      octaves: self.config.octaves.clamp(1, 8),
      persistence: self.config.persistence,
      lacunarity: self.config.lacunarity,
      seed_offset: self.config.seed_offset,
      wireframe: self.config.wireframe as u32,
      _pad: 0.0,
    };
    queue.write_buffer(&self.terrain_uniform_buffer, 0, bytemuck::bytes_of(&uniform));

    let eye = DVec3::new(
      shared.camera.eye_world[0] as f64,
      shared.camera.eye_world[1] as f64,
      shared.camera.eye_world[2] as f64,
    );

    let target = DVec3::new(shared.camera.target[0] as f64, shared.camera.target[1] as f64, 0.0);

    let ratio = desired_chunk_size / self.active_chunk_size;
    if ratio >= 2.0 || ratio <= 0.5
    {
      let center = world_to_chunk_coord(target.x, target.y, desired_chunk_size);
      self.chunks = allocate_chunks(&self.device, &self.config, center, desired_chunk_size);
      self.active_chunk_size = desired_chunk_size;
      self.last_center = center;
      for i in 0..self.chunks.len()
      {
        let origin = self.chunks[i].world_origin();
        upload_chunk_vertices(queue, &self.chunks[i], origin, eye, &self.config);
      }
      self.last_radius = radius;
      return;
    }

    // Same LOD tier — stream and refresh positions
    let camera_chunk = world_to_chunk_coord(target.x, target.y, self.active_chunk_size);

    if camera_chunk != self.last_center
    {
      self.stream_chunks(queue, camera_chunk, eye);
      self.last_center = camera_chunk;
    }
    else
    {
      for i in 0..self.chunks.len()
      {
        let origin = self.chunks[i].world_origin();
        upload_chunk_vertices(queue, &self.chunks[i], origin, eye, &self.config);
      }
    }

    self.last_radius = radius;
  }

  fn encode(&self, encoder: &mut wgpu::CommandEncoder, targets: &FrameTargets, shared: &SharedState)
  {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
      label: Some("Terrain Pass"),
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
    pass.set_bind_group(1, &self.terrain_bind_group, &[]);

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
//   Streaming
// ──────────────────────────────────────────────────────────────

impl TerrainModule
{
  fn stream_chunks(&mut self, queue: &wgpu::Queue, new_center: (i64, i64), eye: DVec3)
  {
    let (cols, rows) = self.config.grid_dims;
    let desired = grid_coords(new_center, cols, rows);

    let mut needs_fill: Vec<(i64, i64)> = desired
      .iter()
      .filter(|&&coord| !self.chunks.iter().any(|c| c.grid_coord == coord))
      .copied()
      .collect();

    for chunk in &mut self.chunks
    {
      if desired.contains(&chunk.grid_coord)
      {
        let origin = chunk.world_origin();
        upload_chunk_vertices(queue, chunk, origin, eye, &self.config);
      }
      else if let Some(new_coord) = needs_fill.pop()
      {
        chunk.grid_coord = new_coord;
        let origin = chunk.world_origin();
        upload_chunk_vertices(queue, chunk, origin, eye, &self.config);
      }
    }
  }
}

// ──────────────────────────────────────────────────────────────
//   Coordinate helpers
// ──────────────────────────────────────────────────────────────

/// Which chunk-grid cell does this world position fall in?
fn world_to_chunk_coord(wx: f64, wy: f64, chunk_size: f64) -> (i64, i64)
{
  ((wx / chunk_size).floor() as i64, (wy / chunk_size).floor() as i64)
}

/// All grid coords in a (cols × rows) window centred on `center`.
fn grid_coords(center: (i64, i64), cols: u32, rows: u32) -> Vec<(i64, i64)>
{
  let half_col = (cols / 2) as i64;
  let half_row = (rows / 2) as i64;
  let mut coords = Vec::with_capacity((cols * rows) as usize);
  for row in -half_row..=half_row
  {
    for col in -half_col..=half_col
    {
      coords.push((center.0 + col, center.1 + row));
    }
  }
  coords
}

// ──────────────────────────────────────────────────────────────
//   Chunk allocation (init only — no GPU allocs after this)
// ──────────────────────────────────────────────────────────────

fn allocate_chunks(
  device: &wgpu::Device,
  config: &TerrainConfig,
  center: (i64, i64),
  chunk_size: f64,
) -> Vec<Chunk>
{
  let (cols, rows) = config.grid_dims;
  grid_coords(center, cols, rows)
    .into_iter()
    .map(|coord| {
      // Snap origin to world-space multiples of chunk_size.
      // This is the key invariant: origins are always consistent
      // across LOD tiers because chunk_sizes are powers of two.
      let origin = DVec3::new(
        snap_to_grid(coord.0 as f64 * chunk_size, chunk_size),
        snap_to_grid(coord.1 as f64 * chunk_size, chunk_size),
        0.0,
      );
      let (vertices, indices) = build_chunk_geometry(origin, DVec3::ZERO, config, chunk_size);

      let vb = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("Terrain Chunk VB"),
        contents: bytemuck::cast_slice(&vertices),
        usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
      });

      let ib = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("Terrain Chunk IB"),
        contents: bytemuck::cast_slice(&indices),
        usage: wgpu::BufferUsages::INDEX,
      });

      Chunk {
        vertex_buffer: vb,
        index_buffer: ib,
        index_count: indices.len() as u32,
        grid_coord: coord,
        chunk_size,
      }
    })
    .collect()
}

// ──────────────────────────────────────────────────────────────
//   Vertex upload
// ──────────────────────────────────────────────────────────────

fn upload_chunk_vertices(
  queue: &wgpu::Queue,
  chunk: &Chunk,
  world_origin: DVec3,
  eye: DVec3,
  _config: &TerrainConfig,
)
{
  let (vertices, _) = build_chunk_geometry(world_origin, eye, _config, chunk.chunk_size);
  queue.write_buffer(&chunk.vertex_buffer, 0, bytemuck::cast_slice(&vertices));
}

// ──────────────────────────────────────────────────────────────
//   Chunk geometry
// ──────────────────────────────────────────────────────────────

fn build_chunk_geometry(
  world_origin: DVec3,
  eye: DVec3,
  _config: &TerrainConfig,
  chunk_size: f64,
) -> (Vec<Vertex>, Vec<u32>)
{
  let target_spacing = 4.0_f64; // world units per quad
  let res = ((chunk_size / target_spacing) as u32).clamp(8, 128);
  let step = chunk_size / res as f64;

  // Build world XY grid (shared positions)
  let mut grid: Vec<[f64; 2]> = Vec::with_capacity(((res + 1) * (res + 1)) as usize);
  for row in 0..=(res)
  {
    for col in 0..=(res)
    {
      grid.push([world_origin.x + col as f64 * step, world_origin.y + row as f64 * step]);
    }
  }

  // Unshared flat vertex list — one unique vertex per triangle corner
  // so each triangle gets its own barycentric assignment.
  let tri_count = res * res * 2;
  let mut flat_verts: Vec<Vertex> = Vec::with_capacity((tri_count * 3) as usize);
  let mut indices: Vec<u32> = Vec::with_capacity((tri_count * 3) as usize);
  let bary_cycle: [[f32; 3]; 3] = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]];
  let mut idx = 0u32;

  for row in 0..res
  {
    for col in 0..res
    {
      let tl = (row * (res + 1) + col) as usize;
      let tr = tl + 1;
      let bl = ((row + 1) * (res + 1) + col) as usize;
      let br = bl + 1;

      for tri_verts in [[tl, bl, tr], [tr, bl, br]]
      {
        for (i, &gi) in tri_verts.iter().enumerate()
        {
          let [wx, wy] = grid[gi];
          flat_verts.push(Vertex {
            pos_rel: [(wx - eye.x) as f32, (wy - eye.y) as f32, 0.0],
            world_xy: [wx as f32, wy as f32],
            bary: bary_cycle[i],
          });
          indices.push(idx);
          idx += 1;
        }
      }
    }
  }

  (flat_verts, indices)
}

// ──────────────────────────────────────────────────────────────
//   Pipeline
// ──────────────────────────────────────────────────────────────

fn create_pipeline(
  device: &wgpu::Device,
  shared: &SharedState,
  terrain_bgl: &wgpu::BindGroupLayout,
) -> wgpu::RenderPipeline
{
  let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
    label: Some("Terrain Shader"),
    source: wgpu::ShaderSource::Wgsl(include_str!("../../shaders/terrain.wgsl").into()),
  });

  let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
    label: Some("Terrain Pipeline Layout"),
    bind_group_layouts: &[&shared.camera_gpu.layout, terrain_bgl],
    push_constant_ranges: &[],
  });

  device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
    label: Some("Terrain Pipeline"),
    layout: Some(&layout),
    vertex: wgpu::VertexState {
      module: &shader,
      entry_point: Some("vs_main"),
      buffers: &[wgpu::VertexBufferLayout {
        array_stride: std::mem::size_of::<Vertex>() as u64,
        step_mode: wgpu::VertexStepMode::Vertex,
        attributes: &wgpu::vertex_attr_array![
          0 => Float32x3,  // pos_rel
          1 => Float32x2,  // world_xy
          2 => Float32x3,  // bary
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
      cull_mode: None,
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
