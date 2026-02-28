use egui_wgpu::{Renderer, RendererOptions, ScreenDescriptor}; // Added Options
use egui_winit::State;
use winit::window::Window;

pub struct GuiRenderer
{
  pub context: egui::Context,
  pub state: State,
  pub renderer: Renderer,
}

impl GuiRenderer
{
  pub fn new(device: &wgpu::Device, output_format: wgpu::TextureFormat, window: &Window) -> Self
  {
    let context = egui::Context::default();
    let state = State::new(
      context.clone(),
      egui::viewport::ViewportId::ROOT,
      window,
      Some(window.scale_factor() as f32),
      None,
      None,
    );

    // FIX: v0.33 uses a single Options struct instead of 5 arguments
    let renderer = Renderer::new(
      device,
      output_format,
      RendererOptions { depth_format: None, antialiasing: None, dithering: true },
    );

    Self { context, state, renderer }
  }

  pub fn render(
    &mut self,
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    encoder: &mut wgpu::CommandEncoder,
    window: &Window,
    view: &wgpu::TextureView,
    full_output: egui::FullOutput,
  )
  {
    let size = window.inner_size();
    let ppp = window.scale_factor() as f32;
    let screen_descriptor =
      ScreenDescriptor { size_in_pixels: [size.width, size.height], pixels_per_point: ppp };

    for (id, delta) in full_output.textures_delta.set
    {
      self.renderer.update_texture(device, queue, id, &delta);
    }

    let tris = self.context.tessellate(full_output.shapes, ppp);
    self.renderer.update_buffers(device, queue, encoder, &tris, &screen_descriptor);

    // FIX for the "escapes" error:
    // We use a scope and an explicit type to keep the compiler happy.
    {
      let mut pass: wgpu::RenderPass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("Egui Pass"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
          view,
          resolve_target: None,
          ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
          depth_slice: None,
        })],
        ..Default::default()
      });

      self.renderer.render(&mut pass, &tris, &screen_descriptor);
    } // 'pass' drops here, releasing the 'encoder' borrow

    for id in full_output.textures_delta.free
    {
      self.renderer.free_texture(&id);
    }
  }
}
