use std::fs::File;
use std::sync::Arc;

use glam::{Mat4, Vec3};
use kyzu_core::{KyzuHeader, TerrainVertex};
use memmap2::Mmap;
use wgpu::util::DeviceExt;
use winit::{
  application::ApplicationHandler,
  event::{ElementState, MouseButton, MouseScrollDelta, WindowEvent},
  event_loop::{ActiveEventLoop, EventLoop},
  window::{Window, WindowId},
};

#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
struct EntityUniform
{
  model_mat: [[f32; 4]; 4],
  extra_data: [f32; 4],
}

struct Planet
{
  distance: f32,
  speed: f32,
  scale: f32,
  uniform_buffer: wgpu::Buffer,
  bind_group: wgpu::BindGroup,
}

struct State
{
  surface: wgpu::Surface<'static>,
  device: wgpu::Device,
  queue: wgpu::Queue,
  config: wgpu::SurfaceConfiguration,
  render_pipeline: wgpu::RenderPipeline,
  line_pipeline: wgpu::RenderPipeline,
  vertex_buffer: wgpu::Buffer,
  orbit_vertex_buffer: wgpu::Buffer,
  num_vertices: u32,
  camera_buffer: wgpu::Buffer,
  camera_bind_group: wgpu::BindGroup,
  depth_texture_view: wgpu::TextureView,
  planets: Vec<Planet>,
  window: Arc<Window>,
  start_time: std::time::Instant,
  camera_yaw: f32,
  camera_pitch: f32,
  camera_zoom: f32,
  is_dragging: bool,
  last_mouse_pos: (f64, f64),
}

impl State
{
  async fn new(window: Arc<Window>, mmap: &Mmap) -> Self
  {
    let size = window.inner_size();
    let instance = wgpu::Instance::default();
    let surface = instance.create_surface(window.clone()).unwrap();
    let adapter = instance
      .request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        compatible_surface: Some(&surface),
        ..Default::default()
      })
      .await
      .unwrap();

    let (device, queue) = adapter.request_device(&wgpu::DeviceDescriptor::default()).await.unwrap();
    let config = surface.get_default_config(&adapter, size.width, size.height).unwrap();
    surface.configure(&device, &config);

    let depth_texture_view = Self::create_depth_view(&device, &config);

    let camera_buffer = device.create_buffer(&wgpu::BufferDescriptor {
      label: None,
      size: 64,
      usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
      mapped_at_creation: false,
    });

    let camera_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
      entries: &[wgpu::BindGroupLayoutEntry {
        binding: 0,
        visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Buffer {
          ty: wgpu::BufferBindingType::Uniform,
          has_dynamic_offset: false,
          min_binding_size: None,
        },
        count: None,
      }],
      label: None,
    });

    let camera_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
      layout: &camera_layout,
      entries: &[wgpu::BindGroupEntry { binding: 0, resource: camera_buffer.as_entire_binding() }],
      label: None,
    });

    let entity_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
      entries: &[wgpu::BindGroupLayoutEntry {
        binding: 0,
        visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Buffer {
          ty: wgpu::BufferBindingType::Uniform,
          has_dynamic_offset: false,
          min_binding_size: None,
        },
        count: None,
      }],
      label: None,
    });

    let shader = device.create_shader_module(wgpu::include_wgsl!("terrain.wgsl"));
    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
      bind_group_layouts: &[&camera_layout, &entity_layout],
      ..Default::default()
    });

    let render_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
      label: Some("Planet Pipeline"),
      layout: Some(&pipeline_layout),
      vertex: wgpu::VertexState {
        module: &shader,
        entry_point: Some("vs_main"),
        buffers: &[TerrainVertex::desc()],
        compilation_options: Default::default(),
      },
      fragment: Some(wgpu::FragmentState {
        module: &shader,
        entry_point: Some("fs_main"),
        targets: &[Some(config.format.into())],
        compilation_options: Default::default(),
      }),
      primitive: wgpu::PrimitiveState { cull_mode: Some(wgpu::Face::Back), ..Default::default() },
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

    let line_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
      label: Some("Line Pipeline"),
      layout: Some(&pipeline_layout),
      vertex: wgpu::VertexState {
        module: &shader,
        entry_point: Some("vs_main"),
        buffers: &[TerrainVertex::desc()],
        compilation_options: Default::default(),
      },
      fragment: Some(wgpu::FragmentState {
        module: &shader,
        entry_point: Some("fs_main"),
        targets: &[Some(config.format.into())],
        compilation_options: Default::default(),
      }),
      primitive: wgpu::PrimitiveState {
        topology: wgpu::PrimitiveTopology::LineStrip,
        cull_mode: None,
        ..Default::default()
      },
      // FIX: The pipeline MUST match the RenderPass format, even if we don't write to it.
      depth_stencil: Some(wgpu::DepthStencilState {
        format: wgpu::TextureFormat::Depth32Float,
        depth_write_enabled: false,
        depth_compare: wgpu::CompareFunction::Always, // Draw regardless of what's behind it
        stencil: wgpu::StencilState::default(),
        bias: wgpu::DepthBiasState::default(),
      }),
      multisample: wgpu::MultisampleState::default(),
      multiview: None,
      cache: None,
    });

    let header = bytemuck::from_bytes::<KyzuHeader>(&mmap[0..1024]);
    let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
      label: None,
      contents: &mmap[1024..],
      usage: wgpu::BufferUsages::VERTEX,
    });

    let mut orbit_verts = Vec::new();
    for i in 0..65
    {
      let angle = (i as f32 / 64.0) * std::f32::consts::PI * 2.0;
      orbit_verts.push(TerrainVertex {
        pos: [angle.cos(), 0.0, angle.sin()],
        hex_id: 0,
        bary: [0.0, 0.0],
      });
    }

    let orbit_vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
      label: Some("Orbit Buffer"),
      contents: bytemuck::cast_slice(&orbit_verts),
      usage: wgpu::BufferUsages::VERTEX,
    });

    let mut planets = Vec::new();
    let configs = vec![(0.0, 0.0, 1.8), (18.0, 0.4, 0.7), (3.5, 2.5, 0.3), (40.0, 0.1, 1.3)];

    for (dist, speed, scale) in configs
    {
      let buf = device.create_buffer(&wgpu::BufferDescriptor {
        label: None,
        size: 80,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
      });
      let bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
        layout: &entity_layout,
        entries: &[wgpu::BindGroupEntry { binding: 0, resource: buf.as_entire_binding() }],
        label: None,
      });
      planets.push(Planet { distance: dist, speed, scale, uniform_buffer: buf, bind_group: bg });
    }

    Self {
      surface,
      device,
      queue,
      config,
      render_pipeline,
      line_pipeline,
      vertex_buffer,
      orbit_vertex_buffer,
      num_vertices: header.vertex_count,
      camera_buffer,
      camera_bind_group,
      depth_texture_view,
      planets,
      window,
      start_time: std::time::Instant::now(),
      camera_yaw: 0.0,
      camera_pitch: 0.5,
      camera_zoom: 100.0,
      is_dragging: false,
      last_mouse_pos: (0.0, 0.0),
    }
  }

  fn create_depth_view(
    device: &wgpu::Device,
    config: &wgpu::SurfaceConfiguration,
  ) -> wgpu::TextureView
  {
    let size =
      wgpu::Extent3d { width: config.width, height: config.height, depth_or_array_layers: 1 };
    let texture = device.create_texture(&wgpu::TextureDescriptor {
      label: None,
      size,
      mip_level_count: 1,
      sample_count: 1,
      dimension: wgpu::TextureDimension::D2,
      format: wgpu::TextureFormat::Depth32Float,
      usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
      view_formats: &[],
    });
    texture.create_view(&wgpu::TextureViewDescriptor::default())
  }

  fn resize(&mut self, new_size: winit::dpi::PhysicalSize<u32>)
  {
    if new_size.width > 0 && new_size.height > 0
    {
      self.config.width = new_size.width;
      self.config.height = new_size.height;
      self.surface.configure(&self.device, &self.config);
      self.depth_texture_view = Self::create_depth_view(&self.device, &self.config);
    }
  }

  fn update_uniform(&self, planet: &Planet, model: Mat4, mode: f32)
  {
    let data =
      EntityUniform { model_mat: model.to_cols_array_2d(), extra_data: [mode, 0.0, 0.0, 0.0] };
    self.queue.write_buffer(&planet.uniform_buffer, 0, bytemuck::bytes_of(&data));
  }

  fn render(&self) -> Result<(), wgpu::SurfaceError>
  {
    let time = self.start_time.elapsed().as_secs_f32();
    let eye = Vec3::new(
      self.camera_zoom * self.camera_pitch.cos() * self.camera_yaw.sin(),
      self.camera_zoom * self.camera_pitch.sin(),
      self.camera_zoom * self.camera_pitch.cos() * self.camera_yaw.cos(),
    );
    let proj = Mat4::perspective_rh(
      45.0f32.to_radians(),
      self.config.width as f32 / self.config.height as f32,
      0.1,
      2000.0,
    );
    let view = Mat4::look_at_rh(eye, Vec3::ZERO, Vec3::Y);
    self.queue.write_buffer(
      &self.camera_buffer,
      0,
      bytemuck::cast_slice(&(proj * view).to_cols_array()),
    );

    let output = self.surface.get_current_texture()?;
    let view = output.texture.create_view(&wgpu::TextureViewDescriptor::default());
    let mut encoder =
      self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor::default());

    {
      let mut rp = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
          view: &view,
          resolve_target: None,
          ops: wgpu::Operations {
            load: wgpu::LoadOp::Clear(wgpu::Color { r: 0.0, g: 0.0, b: 0.01, a: 1.0 }),
            store: wgpu::StoreOp::Store,
          },
          depth_slice: None,
        })],
        depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
          view: &self.depth_texture_view,
          depth_ops: Some(wgpu::Operations {
            load: wgpu::LoadOp::Clear(1.0),
            store: wgpu::StoreOp::Store,
          }),
          stencil_ops: None,
        }),
        ..Default::default()
      });

      let planet_dist = self.planets[1].distance;
      let planet_pos = Vec3::new(
        time.cos() * self.planets[1].speed * planet_dist,
        0.0,
        time.sin() * self.planets[1].speed * planet_dist,
      );

      rp.set_pipeline(&self.line_pipeline);
      rp.set_bind_group(0, &self.camera_bind_group, &[]);
      rp.set_vertex_buffer(0, self.orbit_vertex_buffer.slice(..));

      self.update_uniform(&self.planets[1], Mat4::from_scale(Vec3::splat(planet_dist)), 2.0);
      rp.set_bind_group(1, &self.planets[1].bind_group, &[]);
      rp.draw(0..65, 0..1);

      self.update_uniform(
        &self.planets[2],
        Mat4::from_translation(planet_pos)
          * Mat4::from_scale(Vec3::splat(self.planets[2].distance)),
        2.0,
      );
      rp.set_bind_group(1, &self.planets[2].bind_group, &[]);
      rp.draw(0..65, 0..1);

      self.update_uniform(
        &self.planets[3],
        Mat4::from_scale(Vec3::splat(self.planets[3].distance)),
        2.0,
      );
      rp.set_bind_group(1, &self.planets[3].bind_group, &[]);
      rp.draw(0..65, 0..1);

      rp.set_pipeline(&self.render_pipeline);
      rp.set_vertex_buffer(0, self.vertex_buffer.slice(..));

      self.update_uniform(
        &self.planets[0],
        Mat4::from_scale(Vec3::splat(self.planets[0].scale)),
        1.0,
      );
      rp.set_bind_group(1, &self.planets[0].bind_group, &[]);
      rp.draw(0..self.num_vertices, 0..1);

      self.update_uniform(
        &self.planets[1],
        Mat4::from_translation(planet_pos) * Mat4::from_scale(Vec3::splat(self.planets[1].scale)),
        0.0,
      );
      rp.set_bind_group(1, &self.planets[1].bind_group, &[]);
      rp.draw(0..self.num_vertices, 0..1);

      let m_speed = time * self.planets[2].speed;
      let m_pos = planet_pos
        + Vec3::new(
          m_speed.cos() * self.planets[2].distance,
          0.0,
          m_speed.sin() * self.planets[2].distance,
        );
      self.update_uniform(
        &self.planets[2],
        Mat4::from_translation(m_pos) * Mat4::from_scale(Vec3::splat(self.planets[2].scale)),
        0.0,
      );
      rp.set_bind_group(1, &self.planets[2].bind_group, &[]);
      rp.draw(0..self.num_vertices, 0..1);

      let o_dist = self.planets[3].distance;
      let o_pos = Vec3::new(
        (time * 0.5).cos() * self.planets[3].speed * o_dist,
        0.0,
        (time * 0.5).sin() * self.planets[3].speed * o_dist,
      );
      self.update_uniform(
        &self.planets[3],
        Mat4::from_translation(o_pos) * Mat4::from_scale(Vec3::splat(self.planets[3].scale)),
        0.0,
      );
      rp.set_bind_group(1, &self.planets[3].bind_group, &[]);
      rp.draw(0..self.num_vertices, 0..1);
    }

    self.queue.submit(std::iter::once(encoder.finish()));
    output.present();
    Ok(())
  }
}

struct App
{
  state: Option<State>,
  mmap: Arc<Mmap>,
}

impl ApplicationHandler for App
{
  fn resumed(&mut self, event_loop: &ActiveEventLoop)
  {
    if self.state.is_some()
    {
      return;
    }
    let window = Arc::new(
      event_loop
        .create_window(Window::default_attributes().with_title("Kyzu Solar System"))
        .unwrap(),
    );
    self.state = Some(pollster::block_on(State::new(window, &self.mmap)));
  }

  fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent)
  {
    let state = match &mut self.state
    {
      Some(s) => s,
      None => return,
    };
    match event
    {
      WindowEvent::CloseRequested => event_loop.exit(),
      WindowEvent::Resized(size) => state.resize(size),
      WindowEvent::MouseInput { button: MouseButton::Left, state: s, .. } =>
      {
        state.is_dragging = s == ElementState::Pressed
      }
      WindowEvent::CursorMoved { position: p, .. } =>
      {
        if state.is_dragging
        {
          state.camera_yaw -= (p.x - state.last_mouse_pos.0) as f32 * 0.005;
          state.camera_pitch =
            (state.camera_pitch + (p.y - state.last_mouse_pos.1) as f32 * 0.005).clamp(-1.5, 1.5);
        }
        state.last_mouse_pos = (p.x, p.y);
      }
      WindowEvent::MouseWheel { delta: d, .. } =>
      {
        let amt = match d
        {
          MouseScrollDelta::LineDelta(_, y) => y,
          MouseScrollDelta::PixelDelta(p) => p.y as f32 * 0.01,
        };
        state.camera_zoom = (state.camera_zoom - amt * 4.0).clamp(2.0, 1000.0);
      }
      WindowEvent::RedrawRequested =>
      {
        if let Err(e) = state.render()
        {
          eprintln!("{:?}", e)
        }
        state.window.request_redraw();
      }
      _ => (),
    }
  }
}

fn main()
{
  let file = File::open("C:\\dev\\kyzu_data\\worlds\\terrain.bin").expect("Bake world first");
  let mmap = Arc::new(unsafe { Mmap::map(&file).unwrap() });
  let event_loop = EventLoop::new().unwrap();
  let mut app = App { state: None, mmap };
  event_loop.run_app(&mut app).unwrap();
}
