use std::any::Any;

use wgpu::{CommandEncoder, Device, Queue, TextureFormat};
use winit::window::Window;

use crate::render::module::RenderModule;
use crate::render::shared::{FrameTargets, SharedState};

pub struct UiSystem
{
  pub context: egui::Context,
  pub state: egui_winit::State,
  pub renderer: egui_wgpu::Renderer,
}

impl UiSystem
{
  pub fn new(device: &Device, format: TextureFormat, window: &Window) -> Self
  {
    let context = egui::Context::default();

    let state = egui_winit::State::new(
      context.clone(),
      egui::viewport::ViewportId::ROOT,
      window,
      None,
      None,
      None,
    );

    let renderer = egui_wgpu::Renderer::new(device, format, egui_wgpu::RendererOptions::default());

    Self { context, state, renderer }
  }
}

impl RenderModule for UiSystem
{
  fn update(&mut self, _queue: &Queue, _shared: &SharedState) {}

  fn encode(&self, _encoder: &mut CommandEncoder, _targets: &FrameTargets, _shared: &SharedState) {}

  fn as_any_mut(&mut self) -> &mut dyn Any
  {
    self
  }
}
