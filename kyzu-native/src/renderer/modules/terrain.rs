use glam::DVec3;
use wgpu::util::DeviceExt;

use crate::renderer::module::RenderModule;
use crate::renderer::shared::{FrameTargets, SharedState};

// ──────────────────────────────────────────────────────────────
//   Public terrain configuration (set by app, read each frame)
// ──────────────────────────────────────────────────────────────

pub struct TerrainConfig
{
  /// World-space size of a single chunk (units)
  pub chunk_size: f64,
  /// Number of quads along each axis per chunk
  pub chunk_resolution: u32,
  /// Grid of chunks: (cols, rows) centred on world origin
  pub grid_dims: (u32, u32),

  // Noise parameters — uploaded to GPU every frame
  pub noise_scale: f32,
  pub amplitude: f32,
  pub octaves: u32,
  pub persistence: f32,
  pub lacunarity: f32,
  pub seed_offset: f32,

  pub wireframe: bool,
}

impl Default for TerrainConfig
{
  fn default() -> Self
  {
    Self {
      chunk_size: 200.0,
      chunk_resolution: 64,
      grid_dims: (5, 5),
      noise_scale: 300.0,
      amplitude: 80.0,
      octaves: 6,
      persistence: 0.5,
      lacunarity: 2.0,
      seed_offset: 0.0,
      wireframe: false,
    }
  }
}

// ──────────────────────────────────────────────────────────────
//   GPU uniform — must match terrain.wgsl TerrainUniform layout
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
//   [pos_rel: xyz(f32), world_xy: xy(f32), bary: xyz(f32)]
// ──────────────────────────────────────────────────────────────

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Vertex
{
  pos_rel: [f32; 3],  // camera-relative flat XY position, Z=0
  world_xy: [f32; 2], // absolute world XY for noise sampling
  bary: [f32; 3],     // barycentric coordinate for wireframe
}

// ──────────────────────────────────────────────────────────────
//   Per-chunk GPU resources
// ──────────────────────────────────────────────────────────────

struct Chunk
{
  vertex_buffer: wgpu::Buffer,
  index_buffer: wgpu::Buffer,
  index_count: u32,
  /// World-space origin (bottom-left corner of chunk)
  world_origin: DVec3,
}

// ──────────────────────────────────────────────────────────────
//   Module
// ──────────────────────────────────────────────────────────────

pub struct TerrainModule
{
  chunks: Vec<Chunk>,
  terrain_uniform_buffer: wgpu::Buffer,
  terrain_bind_group: wgpu::BindGroup,
  pipeline: wgpu::RenderPipeline,
  pub config: TerrainConfig,
}

impl RenderModule for TerrainModule
{
  fn init(device: &wgpu::Device, _queue: &wgpu::Queue, shared: &SharedState) -> Self
  {
    let config = TerrainConfig::default();

    // Terrain uniform buffer + bind group
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

    // Build chunks
    let chunks = build_chunks(device, &config);

    Self { chunks, terrain_uniform_buffer, terrain_bind_group, pipeline, config }
  }

  fn update(&mut self, queue: &wgpu::Queue, shared: &SharedState)
  {
    // Upload terrain uniform
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

    // Rebuild chunks if grid config has changed
    // (For now we just re-upload vertex buffers with updated camera-relative positions.
    //  Chunk world_origin is fixed; only pos_rel changes as eye moves.)
    let eye = DVec3::new(
      shared.camera.eye_world[0] as f64,
      shared.camera.eye_world[1] as f64,
      shared.camera.eye_world[2] as f64,
    );

    for chunk in &mut self.chunks
    {
      update_chunk_vertices(queue, chunk, eye, &self.config);
    }
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
//   Chunk geometry builders
// ──────────────────────────────────────────────────────────────

/// Build all chunks for the initial configuration.
fn build_chunks(device: &wgpu::Device, config: &TerrainConfig) -> Vec<Chunk>
{
  let (cols, rows) = config.grid_dims;
  let size = config.chunk_size;

  // Centre the grid on world origin
  let total_w = cols as f64 * size;
  let total_h = rows as f64 * size;
  let offset_x = -total_w * 0.5;
  let offset_y = -total_h * 0.5;

  let mut chunks = Vec::with_capacity((cols * rows) as usize);

  for row in 0..rows
  {
    for col in 0..cols
    {
      let origin = DVec3::new(offset_x + col as f64 * size, offset_y + row as f64 * size, 0.0);

      // Use DVec3::ZERO as initial eye (will be updated first frame via update())
      let (vertices, indices) = build_chunk_geometry(origin, DVec3::ZERO, config);

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

      chunks.push(Chunk {
        vertex_buffer: vb,
        index_buffer: ib,
        index_count: indices.len() as u32,
        world_origin: origin,
      });
    }
  }

  chunks
}

/// Re-upload vertex data with updated camera-relative positions.
/// The index buffer never changes so we only touch the vertex buffer.
fn update_chunk_vertices(queue: &wgpu::Queue, chunk: &Chunk, eye: DVec3, config: &TerrainConfig)
{
  let (vertices, _) = build_chunk_geometry(chunk.world_origin, eye, config);
  queue.write_buffer(&chunk.vertex_buffer, 0, bytemuck::cast_slice(&vertices));
}

/// Build flat (Z=0) vertex grid and triangle index list for one chunk.
/// pos_rel is camera-relative; world_xy is absolute (used by noise in shader).
/// Barycentric coords are assigned per triangle so every vertex in a triangle
/// gets a unique barycentric axis — standard wireframe trick.
fn build_chunk_geometry(
  world_origin: DVec3,
  eye: DVec3,
  config: &TerrainConfig,
) -> (Vec<Vertex>, Vec<u32>)
{
  let res = config.chunk_resolution;
  let size = config.chunk_size;
  let step = size / res as f64;

  let vert_count = (res + 1) * (res + 1);
  let mut vertices: Vec<Vertex> = Vec::with_capacity(vert_count as usize);

  for row in 0..=(res)
  {
    for col in 0..=(res)
    {
      let wx = world_origin.x + col as f64 * step;
      let wy = world_origin.y + row as f64 * step;

      // Camera-relative XY flat position
      let rx = (wx - eye.x) as f32;
      let ry = (wy - eye.y) as f32;

      vertices.push(Vertex {
        pos_rel: [rx, ry, 0.0],
        world_xy: [wx as f32, wy as f32],
        bary: [0.0; 3], // filled per-triangle below
      });
    }
  }

  // Build indices and assign barycentric per-triangle.
  // Each quad = 2 triangles. We duplicate vertices per-triangle for bary coords.
  // To keep things simple and match the allocated buffer size, we instead embed
  // bary as a vertex attribute and assign it at build time using a separate pass.
  // Since vertices are shared, we use a trick: bary is set based on vertex position
  // within the quad so that within each triangle the three vertices differ.
  //
  // Standard approach: assign bary = (1,0,0), (0,1,0), (0,0,1) round-robin by
  // vertex index within triangle. This requires un-sharing vertices — we do that
  // below by building a flat (non-indexed) vertex list.

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

      // Triangle 1: tl, bl, tr
      let tri1 = [vertices[tl], vertices[bl], vertices[tr]];
      for (i, v) in tri1.iter().enumerate()
      {
        let mut vert = *v;
        vert.bary = bary_cycle[i];
        flat_verts.push(vert);
        indices.push(idx);
        idx += 1;
      }

      // Triangle 2: tr, bl, br
      let tri2 = [vertices[tr], vertices[bl], vertices[br]];
      for (i, v) in tri2.iter().enumerate()
      {
        let mut vert = *v;
        vert.bary = bary_cycle[i];
        flat_verts.push(vert);
        indices.push(idx);
        idx += 1;
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
