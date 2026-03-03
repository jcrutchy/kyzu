use wgpu::*;

/// Pure CPU-side camera data computed each frame.
/// This is what the camera module produces, and what the kernel
/// uploads to the GPU uniform buffer.
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct CameraMatrices
{
  pub view_proj: [[f32; 4]; 4],
  pub inv_view_proj: [[f32; 4]; 4],
  pub eye_world: [f32; 3],
  pub _pad: f32,
  pub fade_near: f32,
  pub fade_far: f32,
  pub lod_scale: f32,
  pub lod_fade: f32,
  pub target: [f32; 3],
  pub _pad2: f32,
  pub radius: f32,
  pub _pad3: f32,
}

const _: () = assert!(std::mem::size_of::<CameraMatrices>() == 184);

/// GPU-side camera resources, owned by the kernel.
/// Modules access the camera via the bind group — they never
/// touch the buffer or the matrices directly.
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

/// Everything a render module needs to know about the current frame.
/// Passed by reference into every module's encode() and update() calls.
pub struct SharedState
{
  pub camera: CameraMatrices,
  pub camera_gpu: CameraGpu,
  pub surface_format: TextureFormat,
  pub depth_format: TextureFormat,
}

/// The GPU targets available for a given frame.
/// Passed into encode() so modules know where to draw.
pub struct FrameTargets<'a>
{
  pub color: &'a TextureView,
  pub depth: &'a TextureView,
}

impl Default for CameraMatrices
{
  fn default() -> Self
  {
    Self {
      view_proj: glam::Mat4::IDENTITY.to_cols_array_2d(),
      inv_view_proj: glam::Mat4::IDENTITY.to_cols_array_2d(),
      eye_world: [0.0; 3],
      _pad: 0.0,
      fade_near: 20.0,
      fade_far: 80.0,
      lod_scale: 1.0,
      lod_fade: 0.0,
      target: [0.0; 3],
      _pad2: 0.0,
      radius: 20.0,
      _pad3: 0.0,
    }
  }
}
