use std::any::Any;

use crate::renderer::shared::{FrameTargets, SharedState};

pub trait RenderModule
{
  /// Called once at startup after the kernel is initialised.
  /// Use this to create pipelines, buffers, and bind groups.
  fn init(device: &wgpu::Device, queue: &wgpu::Queue, shared: &SharedState) -> Self
  where
    Self: Sized;

  /// Called every frame before encode().
  /// Use this to upload new data to the GPU — uniform buffers,
  /// instance buffers, etc. No draw calls here.
  fn update(&mut self, queue: &wgpu::Queue, shared: &SharedState);

  /// Called every frame during the render pass.
  /// Use this to record draw calls into the encoder.
  fn encode(
    &self,
    encoder: &mut wgpu::CommandEncoder,
    targets: &FrameTargets,
    shared: &SharedState,
  );

  // Required for downcasting — lets app.rs retrieve typed module references
  fn as_any_mut(&mut self) -> &mut dyn Any;
}
