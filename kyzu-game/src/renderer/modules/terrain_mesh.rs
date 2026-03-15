use std::fs::File;
use std::path::Path;
use std::sync::Arc;

use kyzu_core::TerrainVertex;
use memmap2::Mmap;
use wgpu::util::DeviceExt;

use crate::renderer::module::RenderModule;
use crate::renderer::shared::{FrameTargets, SharedState};

// ──────────────────────────────────────────────────────────────
//   GPU vertex — eye-relative position + biome color
// ──────────────────────────────────────────────────────────────

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct GpuVertex
{
  position: [f32; 3],
  color: [f32; 3],
}

// ──────────────────────────────────────────────────────────────
//   Biome colors — must match biomes.json order
// ──────────────────────────────────────────────────────────────

fn biome_color(id: u8) -> [f32; 3]
{
  match id
  {
    0 => [0.00, 0.12, 0.31], // Deep Ocean
    1 => [0.00, 0.31, 0.55], // Shallow Ocean
    2 => [0.82, 0.76, 0.55], // Coast
    3 => [0.31, 0.51, 0.24], // Lowland
    4 => [0.39, 0.35, 0.24], // Highland
    5 => [0.63, 0.61, 0.59], // Mountain
    6 => [0.94, 0.96, 1.00], // Ice Cap
    _ => [1.00, 0.00, 1.00], // Error — magenta
  }
}

// ──────────────────────────────────────────────────────────────
//   Module
// ──────────────────────────────────────────────────────────────

pub struct TerrainMeshModule
{
  vertex_buffer: wgpu::Buffer,
  index_buffer: wgpu::Buffer,
  index_count: u32,
  pipeline: wgpu::RenderPipeline,
  terrain_verts: Vec<TerrainVertex>, // CPU-side for per-frame eye-relative recompute
  _mmap: Mmap,                       // keep alive for the lifetime of the module
}

impl TerrainMeshModule
{
  pub fn load(
    device: &Arc<wgpu::Device>,
    shared: &SharedState,
    bin_path: &Path,
  ) -> anyhow::Result<Self>
  {
    // ── Memory map the bin file ───────────────────────────────
    let file = File::open(bin_path)?;
    let mmap = unsafe { Mmap::map(&file)? };

    // ── Parse header ─────────────────────────────────────────
    let magic = u32::from_le_bytes(mmap[0..4].try_into().unwrap());
    assert_eq!(magic, 0x4B595A55, "Invalid terrain bin magic");

    let level = u32::from_le_bytes(mmap[4..8].try_into().unwrap());
    let vert_count = u64::from_le_bytes(mmap[8..16].try_into().unwrap()) as usize;
    let face_count = u64::from_le_bytes(mmap[16..24].try_into().unwrap()) as usize;

    log::info!("Loading terrain_l{}.bin: {} verts, {} faces", level, vert_count, face_count);

    // ── Vertex data starts at 256-byte boundary ───────────────
    let vert_offset = 256;
    let vert_size = std::mem::size_of::<TerrainVertex>();
    let vert_bytes = vert_count * vert_size;

    let terrain_verts: Vec<TerrainVertex> =
      bytemuck::cast_slice(&mmap[vert_offset..vert_offset + vert_bytes]).to_vec();

    // ── Index data after next 256-byte boundary ───────────────
    let vert_end = vert_offset + vert_bytes;
    let idx_offset = (vert_end + 255) & !255;
    let idx_bytes = face_count * 3 * std::mem::size_of::<u32>();

    let indices: &[u32] = bytemuck::cast_slice(&mmap[idx_offset..idx_offset + idx_bytes]);

    log::info!("TerrainVertex size = {}", std::mem::size_of::<TerrainVertex>());
    log::info!("vert_offset={} vert_bytes={}", vert_offset, vert_bytes);
    log::info!("vert_end={} idx_offset={}", vert_end, idx_offset);
    log::info!("idx_bytes={} mmap_len={}", idx_bytes, mmap.len());
    log::info!("idx_end={}", idx_offset + idx_bytes);

    // ── Initial GPU vertex buffer (placeholder zeros) ─────────
    let gpu_verts = vec![GpuVertex { position: [0.0; 3], color: [0.0; 3] }; vert_count];

    let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
      label: Some("Terrain Mesh VB"),
      contents: bytemuck::cast_slice(&gpu_verts),
      usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
    });

    let index_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
      label: Some("Terrain Mesh IB"),
      contents: bytemuck::cast_slice(indices),
      usage: wgpu::BufferUsages::INDEX,
    });

    let pipeline = create_pipeline(device, shared);

    Ok(Self {
      vertex_buffer,
      index_buffer,
      index_count: (face_count * 3) as u32,
      pipeline,
      terrain_verts,
      _mmap: mmap,
    })
  }
}

impl RenderModule for TerrainMeshModule
{
  fn init(_device: &Arc<wgpu::Device>, _queue: &wgpu::Queue, _shared: &SharedState) -> Self
  {
    panic!("Use TerrainMeshModule::load() instead of init()");
  }

  fn update(&mut self, queue: &wgpu::Queue, shared: &SharedState)
  {
    let planet_radius = 6_371_000.0_f64; // metres — TODO: read from world.json

    let eye = glam::DVec3::new(
      shared.camera.eye_world[0] as f64,
      shared.camera.eye_world[1] as f64,
      shared.camera.eye_world[2] as f64,
    );

    let gpu_verts: Vec<GpuVertex> = self
      .terrain_verts
      .iter()
      .map(|v| {
        // Reconstruct world position from unit sphere coords — full f64 precision
        let unit =
          glam::DVec3::new(v.position[0] as f64, v.position[1] as f64, v.position[2] as f64);
        let world_pos = unit * planet_radius;
        let rel = (world_pos - eye).as_vec3();
        GpuVertex { position: rel.into(), color: biome_color(v.biome_id) }
      })
      .collect();

    queue.write_buffer(&self.vertex_buffer, 0, bytemuck::cast_slice(&gpu_verts));
  }

  fn encode(&self, encoder: &mut wgpu::CommandEncoder, targets: &FrameTargets, shared: &SharedState)
  {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
      label: Some("Terrain Mesh Pass"),
      color_attachments: &[Some(wgpu::RenderPassColorAttachment {
        view: targets.surface_view,
        resolve_target: None,
        ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
        depth_slice: None,
      })],
      depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
        view: targets.depth_view,
        depth_ops: Some(wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store }),
        stencil_ops: None,
      }),
      occlusion_query_set: None,
      timestamp_writes: None,
    });

    pass.set_pipeline(&self.pipeline);
    pass.set_bind_group(0, &shared.camera_gpu.bind_group, &[]);
    pass.set_vertex_buffer(0, self.vertex_buffer.slice(..));
    pass.set_index_buffer(self.index_buffer.slice(..), wgpu::IndexFormat::Uint32);
    pass.draw_indexed(0..self.index_count, 0, 0..1);
  }

  fn as_any_mut(&mut self) -> &mut dyn std::any::Any
  {
    self
  }
}

// ──────────────────────────────────────────────────────────────
//   Pipeline
// ──────────────────────────────────────────────────────────────

fn create_pipeline(device: &wgpu::Device, shared: &SharedState) -> wgpu::RenderPipeline
{
  let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
    label: Some("Terrain Mesh Shader"),
    source: wgpu::ShaderSource::Wgsl(include_str!("../../shaders/terrain_mesh.wgsl").into()),
  });

  let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
    label: Some("Terrain Mesh Pipeline Layout"),
    bind_group_layouts: &[&shared.camera_gpu.layout],
    push_constant_ranges: &[],
  });

  device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
    label: Some("Terrain Mesh Pipeline"),
    layout: Some(&layout),
    vertex: wgpu::VertexState {
      module: &shader,
      entry_point: Some("vs_main"),
      buffers: &[wgpu::VertexBufferLayout {
        array_stride: std::mem::size_of::<GpuVertex>() as u64,
        step_mode: wgpu::VertexStepMode::Vertex,
        attributes: &wgpu::vertex_attr_array![
          0 => Float32x3, // position (eye-relative)
          1 => Float32x3, // color
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
      cull_mode: None,
      polygon_mode: wgpu::PolygonMode::Line,
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
