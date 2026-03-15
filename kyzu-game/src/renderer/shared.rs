use std::sync::Arc;

use wgpu::*;

/// Pure CPU-side camera data computed each frame.
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct CameraMatrices
{
  pub view_proj: [[f32; 4]; 4],     // 64
  pub inv_view_proj: [[f32; 4]; 4], // 64
  pub eye_world: [f32; 3],          // 12
  pub _pad: f32,                    //  4
  pub fade_near: f32,               //  4
  pub fade_far: f32,                //  4
  pub lod_scale: f32,               //  4
  pub lod_fade: f32,                //  4
  pub target: [f32; 3],             // 12
  pub _pad2: f32,                   //  4
  pub radius: f32,                  //  4
  pub _pad3: f32,                   //  4
  pub target_rel: [f32; 3],         // 12
  pub _pad4: f32,                   //  4
  pub sun_dir: [f32; 3],            // 12  ← direction FROM sun TO origin, normalised
  pub _pad5: f32,                   //  4
  pub _pad6: [f32; 2],              //  8
}

const _: () = assert!(std::mem::size_of::<CameraMatrices>() == 224);

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
      target_rel: [0.0; 3],
      _pad4: 0.0,
      sun_dir: [1.0, 0.0, 0.0],
      _pad5: 0.0,
      _pad6: [0.0; 2],
    }
  }
}

/// GPU-side camera resources, owned by the kernel.
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

/// Everything a render module needs about the current frame.
pub struct SharedState
{
  pub camera: CameraMatrices,
  pub camera_gpu: CameraGpu,
  pub surface_format: TextureFormat,
  pub depth_format: TextureFormat,
  pub screen_width: u32,
  pub screen_height: u32,
}

/// GPU targets for a given frame.
pub struct FrameTargets<'a>
{
  pub surface_view: &'a TextureView,
  pub depth_view: &'a TextureView,
}

/// Texture bind group layout shared between all textured modules.
/// Created once by the kernel, passed into module init.
pub struct TextureLayout
{
  pub layout: Arc<BindGroupLayout>,
}

impl TextureLayout
{
  pub fn create(device: &Device) -> Self
  {
    let layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
      label: Some("Texture BGL"),
      entries: &[
        // binding 0 — texture
        BindGroupLayoutEntry {
          binding: 0,
          visibility: ShaderStages::FRAGMENT,
          ty: BindingType::Texture {
            sample_type: TextureSampleType::Float { filterable: true },
            view_dimension: TextureViewDimension::D2,
            multisampled: false,
          },
          count: None,
        },
        // binding 1 — sampler
        BindGroupLayoutEntry {
          binding: 1,
          visibility: ShaderStages::FRAGMENT,
          ty: BindingType::Sampler(SamplerBindingType::Filtering),
          count: None,
        },
      ],
    });

    Self { layout: Arc::new(layout) }
  }
}
