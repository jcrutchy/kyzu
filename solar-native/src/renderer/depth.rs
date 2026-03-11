use wgpu::*;

pub struct DepthResources
{
  pub view: TextureView,
}

impl DepthResources
{
  pub fn create(device: &Device, config: &SurfaceConfiguration) -> Self
  {
    let texture = device.create_texture(&TextureDescriptor {
      label: Some("Depth Texture"),
      size: Extent3d { width: config.width, height: config.height, depth_or_array_layers: 1 },
      mip_level_count: 1,
      sample_count: 1,
      dimension: TextureDimension::D2,
      format: TextureFormat::Depth32Float,
      usage: TextureUsages::RENDER_ATTACHMENT,
      view_formats: &[],
    });

    let view = texture.create_view(&TextureViewDescriptor::default());

    Self { view }
  }
}
