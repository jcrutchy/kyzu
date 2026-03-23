use std::any::Any;

use wgpu::{CommandEncoder, Queue};

pub use crate::render::shared::{FrameTargets, SharedState};

pub trait RenderModule: Send + Sync
{
  fn update(&mut self, queue: &Queue, shared: &SharedState);

  fn encode(&self, encoder: &mut CommandEncoder, targets: &FrameTargets, shared: &SharedState);

  fn as_any_mut(&mut self) -> &mut dyn Any;
}
