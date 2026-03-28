use std::any::Any;
use std::path::Path;

use bytemuck::{Pod, Zeroable};
use glam::{DVec3, Mat4, Quat, Vec3, Vec4};
use wgpu::util::DeviceExt;
use wgpu::{include_wgsl, BindGroup, BindGroupLayout, Buffer, Queue};

use crate::bake::geometry::BakedVertex;
use crate::core::log::{LogLevel, Logger};
use crate::render::module::{FrameTargets, RenderModule};
use crate::render::shared::SharedState;
use crate::world::body::BodyKind;
use crate::world::registry::BodyState;

// ─────────────────────────────────────────────────────────────────────────────
//  Scale constant
//
//  Bodies are stored internally in metres (f64). For rendering we work in
//  units of 1 000 km so f32 precision is adequate across the visible scene.
//    Earth radius  =    6.371 units
//    Sun radius    =  695.7   units
//    1 AU          =  149 598 units
// ─────────────────────────────────────────────────────────────────────────────

const RENDER_SCALE: f64 = 1_000_000.0; // 1 render unit = 1 000 km

// ─────────────────────────────────────────────────────────────────────────────
//  BodyUniforms — must match body.wgsl layout exactly
// ─────────────────────────────────────────────────────────────────────────────

#[repr(C)]
#[derive(Copy, Clone, Pod, Zeroable)]
struct BodyUniforms
{
  model_mat: [[f32; 4]; 4],
  base_color: [f32; 4],
  light_dir: [f32; 3],
  is_star: u32,
}

// ─────────────────────────────────────────────────────────────────────────────
//  GpuBody — per-body GPU resources
// ─────────────────────────────────────────────────────────────────────────────

struct GpuBody
{
  vertex_buffer: Buffer,
  vertex_count: u32,
  uniforms_buffer: Buffer,
  bind_group: BindGroup,
}

// ─────────────────────────────────────────────────────────────────────────────
//  BodyRenderer
// ─────────────────────────────────────────────────────────────────────────────

pub struct BodyRenderer
{
  pipeline: wgpu::RenderPipeline,
  #[allow(dead_code)]
  body_bgl: BindGroupLayout,
  gpu_bodies: Vec<Option<GpuBody>>,
  sun_pos_render: Vec3,
}

impl BodyRenderer
{
  pub fn new(
    device: &wgpu::Device,
    shared: &SharedState,
    mesh_path: &Path,
    logger: &mut Logger,
  ) -> Self
  {
    let shader = device.create_shader_module(include_wgsl!("../shaders/body.wgsl"));

    // ── Load shared icosphere mesh ────────────────────────────────────────
    let mesh_data = std::fs::read(mesh_path).expect("Failed to load icosphere mesh");
    logger.emit(
      LogLevel::Info,
      &format!("BodyRenderer: loaded mesh {} ({} bytes)", mesh_path.display(), mesh_data.len()),
    );

    let vertex_size = std::mem::size_of::<BakedVertex>();
    let v_count = u32::from_le_bytes(mesh_data[0..4].try_into().unwrap()) as usize;
    let vertex_data_end = 4 + v_count * vertex_size;
    let vertices: &[BakedVertex] = bytemuck::cast_slice(&mesh_data[4..vertex_data_end]);

    // ── Bind group layout (group 1) ───────────────────────────────────────
    let body_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
      label: Some("Body BGL"),
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

    // ── Pipeline ─────────────────────────────────────────────────────────
    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
      label: Some("Body Pipeline Layout"),
      bind_group_layouts: &[&shared.camera_gpu.layout, &body_bgl],
      push_constant_ranges: &[],
    });

    let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
      label: Some("Body Render Pipeline"),
      layout: Some(&pipeline_layout),
      vertex: wgpu::VertexState {
        module: &shader,
        entry_point: Some("vs_main"),
        compilation_options: Default::default(),
        buffers: &[wgpu::VertexBufferLayout {
          array_stride: vertex_size as u64,
          step_mode: wgpu::VertexStepMode::Vertex,
          attributes: &wgpu::vertex_attr_array![
              0 => Float32x3, // position
              1 => Float32x3, // normal
              2 => Float32x2, // uv
              3 => Float32,   // height
              4 => Uint32,    // hex_id
              5 => Float32x3, // barycentric
          ],
        }],
      },
      fragment: Some(wgpu::FragmentState {
        module: &shader,
        entry_point: Some("fs_main"),
        compilation_options: Default::default(),
        targets: &[Some(wgpu::ColorTargetState {
          format: wgpu::TextureFormat::Bgra8UnormSrgb,
          blend: Some(wgpu::BlendState::REPLACE),
          write_mask: wgpu::ColorWrites::ALL,
        })],
      }),
      primitive: wgpu::PrimitiveState {
        topology: wgpu::PrimitiveTopology::TriangleList,
        cull_mode: Some(wgpu::Face::Back),
        ..Default::default()
      },
      depth_stencil: Some(wgpu::DepthStencilState {
        format: wgpu::TextureFormat::Depth32Float,
        depth_write_enabled: true,
        depth_compare: wgpu::CompareFunction::Less,
        stencil: wgpu::StencilState::default(),
        bias: wgpu::DepthBiasState::default(),
      }),
      multisample: wgpu::MultisampleState::default(),
      multiview: None,
      cache: None,
    });

    // ── Per-body GPU resources ────────────────────────────────────────────
    let mut gpu_bodies: Vec<Option<GpuBody>> = Vec::new();

    for body_state in &shared.body_registry.bodies
    {
      let name = &body_state.manifest.name;

      let body_vb = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some(&format!("Body VB ({})", name)),
        contents: bytemuck::cast_slice(vertices),
        usage: wgpu::BufferUsages::VERTEX,
      });

      let placeholder = BodyUniforms {
        model_mat: Mat4::IDENTITY.to_cols_array_2d(),
        base_color: [1.0, 1.0, 1.0, 1.0],
        light_dir: [0.0, 1.0, 0.0],
        is_star: 0,
      };

      let uniforms_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some(&format!("Body Uniforms ({})", name)),
        contents: bytemuck::bytes_of(&placeholder),
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
      });

      let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some(&format!("Body BG ({})", name)),
        layout: &body_bgl,
        entries: &[wgpu::BindGroupEntry {
          binding: 0,
          resource: uniforms_buffer.as_entire_binding(),
        }],
      });

      gpu_bodies.push(Some(GpuBody {
        vertex_buffer: body_vb,
        vertex_count: v_count as u32,
        uniforms_buffer,
        bind_group,
      }));
    }

    Self { pipeline, body_bgl, gpu_bodies, sun_pos_render: Vec3::ZERO }
  }

  /// Convert world-space DVec3 (metres) to render-scale Vec3.
  fn to_render_scale(pos: DVec3) -> Vec3
  {
    Vec3::new(
      (pos.x / RENDER_SCALE) as f32,
      (pos.y / RENDER_SCALE) as f32,
      (pos.z / RENDER_SCALE) as f32,
    )
  }

  /// Build the model matrix for a body, relative to the camera eye position.
  /// All arithmetic done in f64 before the final cast to f32.
  fn build_model_matrix(body: &BodyState, eye_world: DVec3) -> Mat4
  {
    let relative = body.world_pos - eye_world;
    let pos_render = Vec3::new(
      (relative.x / RENDER_SCALE) as f32,
      (relative.y / RENDER_SCALE) as f32,
      (relative.z / RENDER_SCALE) as f32,
    );
    let scale = (body.manifest.radius_m / RENDER_SCALE) as f32;

    Mat4::from_scale_rotation_translation(Vec3::splat(scale), Quat::IDENTITY, pos_render)
  }

  /// Derive a base colour from BodyKind.
  fn base_color(kind: &BodyKind) -> Vec4
  {
    match kind
    {
      BodyKind::Terrestrial => Vec4::new(0.2, 0.5, 0.8, 1.0),
      BodyKind::Rocky { .. } => Vec4::new(0.6, 0.5, 0.4, 1.0),
      BodyKind::GasGiant { band_color_a, .. } =>
      {
        Vec4::new(band_color_a[0], band_color_a[1], band_color_a[2], 1.0)
      }
      BodyKind::SmallBody { base_color } =>
      {
        Vec4::new(base_color[0], base_color[1], base_color[2], 1.0)
      }
      BodyKind::Star { light_color, .. } =>
      {
        Vec4::new(light_color[0], light_color[1], light_color[2], 1.0)
      }
      BodyKind::Manmade => Vec4::new(0.7, 0.7, 0.8, 1.0),
    }
  }

  fn is_star(kind: &BodyKind) -> u32
  {
    match kind
    {
      BodyKind::Star { .. } => 1,
      _ => 0,
    }
  }
}

impl RenderModule for BodyRenderer
{
  fn update(&mut self, queue: &Queue, shared: &SharedState)
  {
    // TEMP DEBUG — remove once rendering is confirmed working
    static DEBUG_ONCE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

    if !DEBUG_ONCE.load(std::sync::atomic::Ordering::Relaxed)
    {
      DEBUG_ONCE.store(true, std::sync::atomic::Ordering::Relaxed);

      // Log eye_world in metres
      let eye = shared.eye_world;
      eprintln!("DEBUG eye_world (m): {:.0}, {:.0}, {:.0}", eye.x, eye.y, eye.z);

      // Log Sun's model matrix translation and scale
      for body_state in &shared.body_registry.bodies
      {
        if let crate::world::body::BodyKind::Star { .. } = body_state.manifest.kind
        {
          let mat = Self::build_model_matrix(body_state, shared.eye_world);
          let translation = mat.w_axis;
          let scale = body_state.manifest.radius_m / RENDER_SCALE;
          eprintln!(
            "DEBUG Sun model translation (render units): {:.4}, {:.4}, {:.4}",
            translation.x, translation.y, translation.z
          );
          eprintln!("DEBUG Sun scale (render units): {:.4}", scale);
          break;
        }
      }

      // Log the view_proj diagonal to check it's not degenerate
      let vp = shared.camera.view_proj;
      eprintln!("DEBUG view_proj[0][0]: {:.6}", vp[0][0]);
      eprintln!("DEBUG view_proj[3][3]: {:.6}", vp[3][3]);
    }

    // Cache the Sun's render-scale position for light direction calcs.
    self.sun_pos_render = Vec3::ZERO;
    for body_state in &shared.body_registry.bodies
    {
      if let BodyKind::Star { .. } = body_state.manifest.kind
      {
        self.sun_pos_render = Self::to_render_scale(body_state.world_pos);
        break;
      }
    }

    for (index, body_state) in shared.body_registry.bodies.iter().enumerate()
    {
      let gpu_body = match self.gpu_bodies.get(index)
      {
        Some(Some(b)) => b,
        _ => continue,
      };

      let model_mat = Self::build_model_matrix(body_state, shared.eye_world);
      let base_color = Self::base_color(&body_state.manifest.kind);
      let is_star = Self::is_star(&body_state.manifest.kind);

      // Vector from this body toward the Sun in render-scale space.
      // When all bodies are at origin this falls back to Vec3::Y so the
      // lighting is at least consistent rather than black.
      let body_pos = Self::to_render_scale(body_state.world_pos);
      let to_sun = self.sun_pos_render - body_pos;
      let light_dir = if to_sun.length_squared() > 0.0 { to_sun.normalize() } else { Vec3::Y };

      let uniforms = BodyUniforms {
        model_mat: model_mat.to_cols_array_2d(),
        base_color: base_color.into(),
        light_dir: light_dir.into(),
        is_star,
      };

      queue.write_buffer(&gpu_body.uniforms_buffer, 0, bytemuck::bytes_of(&uniforms));
    }
  }

  fn encode(&self, encoder: &mut wgpu::CommandEncoder, targets: &FrameTargets, shared: &SharedState)
  {
    let mut render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
      label: Some("Body Render Pass"),
      color_attachments: &[Some(wgpu::RenderPassColorAttachment {
        view: targets.surface_view,
        resolve_target: None,
        ops: wgpu::Operations {
          load: wgpu::LoadOp::Clear(wgpu::Color { r: 0.0, g: 0.0, b: 0.0, a: 1.0 }),
          store: wgpu::StoreOp::Store,
        },
        depth_slice: None,
      })],
      depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
        view: targets.depth_view,
        depth_ops: Some(wgpu::Operations {
          load: wgpu::LoadOp::Clear(1.0),
          store: wgpu::StoreOp::Store,
        }),
        stencil_ops: None,
      }),
      ..Default::default()
    });

    render_pass.set_pipeline(&self.pipeline);
    render_pass.set_bind_group(0, &shared.camera_gpu.bind_group, &[]);

    for (index, _body_state) in shared.body_registry.bodies.iter().enumerate()
    {
      let gpu_body = match self.gpu_bodies.get(index)
      {
        Some(Some(b)) => b,
        _ => continue,
      };

      if gpu_body.vertex_count == 0
      {
        continue;
      }

      render_pass.set_bind_group(1, &gpu_body.bind_group, &[]);
      render_pass.set_vertex_buffer(0, gpu_body.vertex_buffer.slice(..));
      render_pass.draw(0..gpu_body.vertex_count, 0..1);
    }
  }

  fn as_any_mut(&mut self) -> &mut dyn Any
  {
    self
  }
}
