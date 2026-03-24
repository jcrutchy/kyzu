use bytemuck::{Pod, Zeroable};
use wgpu::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CameraMode
{
  Free,    // Deep Space: Fly-through
  Orbital, // World Body: Focused on a planet/sun
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct CameraMatrices
{
  pub view_proj: [[f32; 4]; 4],
  pub inv_view_proj: [[f32; 4]; 4],
  pub eye_rel: [f32; 3],
  pub _pad: f32,
}

impl Default for CameraMatrices
{
  fn default() -> Self
  {
    Self {
      view_proj: glam::Mat4::IDENTITY.to_cols_array_2d(),
      inv_view_proj: glam::Mat4::IDENTITY.to_cols_array_2d(),
      eye_rel: [0.0; 3],
      _pad: 0.0,
    }
  }
}

pub struct CameraGpu
{
  pub buffer: Buffer,
  pub bind_group: BindGroup,
  pub layout: BindGroupLayout,
}

impl CameraGpu
{
  pub fn create(device: &Device) -> Self
  {
    let buffer = device.create_buffer(&BufferDescriptor {
      label: Some("Camera Buffer"),
      size: std::mem::size_of::<CameraMatrices>() as u64,
      usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
      mapped_at_creation: false,
    });

    let layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
      label: Some("Camera BGL"),
      entries: &[BindGroupLayoutEntry {
        binding: 0,
        visibility: ShaderStages::VERTEX_FRAGMENT,
        ty: BindingType::Buffer {
          ty: BufferBindingType::Uniform,
          has_dynamic_offset: false,
          min_binding_size: None,
        },
        count: None,
      }],
    });

    let bind_group = device.create_bind_group(&BindGroupDescriptor {
      label: Some("Camera BG"),
      layout: &layout,
      entries: &[BindGroupEntry { binding: 0, resource: buffer.as_entire_binding() }],
    });

    Self { buffer, bind_group, layout }
  }

  pub fn upload(&self, queue: &Queue, matrices: &CameraMatrices)
  {
    queue.write_buffer(&self.buffer, 0, bytemuck::bytes_of(matrices));
  }
}

pub struct DepthTexture
{
  pub texture: Texture,
  pub view: TextureView,
}

pub struct SharedState
{
  pub mode: CameraMode,
  pub camera: CameraMatrices,
  pub camera_gpu: CameraGpu,
  pub surface_format: TextureFormat,
  pub depth_format: TextureFormat,
  pub depth_view: TextureView,
  pub screen_width: u32,
  pub screen_height: u32,
  pub target_body_pos: glam::DVec3,
  pub eye_world: glam::DVec3,
}

impl SharedState
{
  pub fn new(device: &Device, width: u32, height: u32) -> Self
  {
    let surface_format = TextureFormat::Bgra8UnormSrgb;
    let depth_format = TextureFormat::Depth32Float;

    let camera = CameraMatrices::default();
    let camera_gpu = CameraGpu::create(device);

    // Basic depth texture for 3D rendering
    let depth_texture = device.create_texture(&TextureDescriptor {
      label: Some("Depth Texture"),
      size: Extent3d { width, height, depth_or_array_layers: 1 },
      mip_level_count: 1,
      sample_count: 1,
      dimension: TextureDimension::D2,
      format: depth_format,
      usage: TextureUsages::RENDER_ATTACHMENT | TextureUsages::TEXTURE_BINDING,
      view_formats: &[],
    });

    let depth_view = depth_texture.create_view(&TextureViewDescriptor::default());

    Self {
      mode: CameraMode::Orbital,
      camera,
      camera_gpu,
      surface_format,
      depth_format,
      depth_view,
      screen_width: width,
      screen_height: height,
      target_body_pos: glam::DVec3::ZERO,
      eye_world: glam::DVec3::new(0.0, 0.0, 5.0), // Start 5m back in f64
    }
  }
}

pub struct FrameTargets<'a>
{
  pub surface_view: &'a TextureView,
  pub depth_view: &'a TextureView,
}
