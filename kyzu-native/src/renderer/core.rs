use std::sync::{Arc, Mutex};
use winit::window::Window;

use crate::camera::{Camera, CameraUniform};

use super::cube::CubeMesh;
use super::depth::DepthResources;

pub struct Renderer<'a> {
    surface: wgpu::Surface<'a>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,

    depth: DepthResources,
    camera_buffer: wgpu::Buffer,
    camera_bind_group: wgpu::BindGroup,

    pipeline: wgpu::RenderPipeline,
    cube: CubeMesh,
}

//
// ──────────────────────────────────────────────────────────────
//   Public API
// ──────────────────────────────────────────────────────────────
//

impl<'a> Renderer<'a> {
    pub async fn new(
        window: &'a Window,
        camera: &Arc<Mutex<Camera>>,
    ) -> Self {
        let instance = wgpu::Instance::default();
        let surface = instance.create_surface(window).unwrap();
    
        let adapter = request_adapter(&instance, &surface).await;
        let (device, queue) = request_device(&adapter).await;
    
        let config = configure_surface(window, &surface, &adapter, &device);
        let depth = DepthResources::create(&device, &config);
    
        let (camera_buffer, camera_bind_group, camera_bgl) =
            create_camera_resources(&device);
    
        // Upload initial camera uniform
        {
            let cam = camera.lock().unwrap();
            let uniform = CameraUniform::from_camera(&cam);
            queue.write_buffer(&camera_buffer, 0, bytemuck::bytes_of(&uniform));
        }
    
        let pipeline = create_pipeline(&device, &config, &camera_bgl);
        let cube = CubeMesh::create(&device);
    
        Self {
            surface,
            device,
            queue,
            config,
            depth,
            camera_buffer,
            camera_bind_group,
            pipeline,
            cube,
        }
    }

    pub fn update_camera(&mut self, camera: &Camera) {
        let uniform = CameraUniform::from_camera(camera);
        self.queue
            .write_buffer(&self.camera_buffer, 0, bytemuck::bytes_of(&uniform));
    }

    pub fn render(&mut self) {
        let frame = match self.surface.get_current_texture() {
            Ok(frame) => frame,
            Err(_) => {
                self.surface.configure(&self.device, &self.config);
                self.surface
                    .get_current_texture()
                    .expect("Failed to acquire frame")
            }
        };

        let view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());

        let mut encoder =
            self.device
                .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                    label: Some("Render Encoder"),
                });

        record_render_pass(
            &mut encoder,
            &view,
            &self.depth.view,
            &self.pipeline,
            &self.camera_bind_group,
            &self.cube,
        );

        self.queue.submit(Some(encoder.finish()));
        frame.present();
    }
}

//
// ──────────────────────────────────────────────────────────────
//   Initialization Helpers
// ──────────────────────────────────────────────────────────────
//

async fn request_adapter(
    instance: &wgpu::Instance,
    surface: &wgpu::Surface<'_>,
) -> wgpu::Adapter {
    instance
        .request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: Some(surface),
            force_fallback_adapter: false,
        })
        .await
        .expect("No suitable GPU adapters found")
}

async fn request_device(
    adapter: &wgpu::Adapter,
) -> (wgpu::Device, wgpu::Queue) {
    adapter
        .request_device(
            &wgpu::DeviceDescriptor {
                label: Some("Kyzu Device"),
                required_features: wgpu::Features::empty(),
                required_limits: wgpu::Limits::default(),
            },
            None,
        )
        .await
        .expect("Failed to create device")
}

fn configure_surface(
    window: &Window,
    surface: &wgpu::Surface<'_>,
    adapter: &wgpu::Adapter,
    device: &wgpu::Device,
) -> wgpu::SurfaceConfiguration {
    let size = window.inner_size();
    let caps = surface.get_capabilities(adapter);
    let format = caps.formats[0];

    let config = wgpu::SurfaceConfiguration {
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        format,
        width: size.width,
        height: size.height,
        present_mode: wgpu::PresentMode::Fifo,
        alpha_mode: wgpu::CompositeAlphaMode::Auto,
        view_formats: vec![],
        desired_maximum_frame_latency: 2,
    };

    surface.configure(device, &config);
    config
}

fn create_camera_resources(
    device: &wgpu::Device,
) -> (wgpu::Buffer, wgpu::BindGroup, wgpu::BindGroupLayout) {
    let camera_buffer = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("Camera Buffer"),
        size: std::mem::size_of::<CameraUniform>() as u64,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });

    let camera_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("Camera BGL"),
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

    let camera_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("Camera BG"),
        layout: &camera_bgl,
        entries: &[wgpu::BindGroupEntry {
            binding: 0,
            resource: camera_buffer.as_entire_binding(),
        }],
    });

    (camera_buffer, camera_bind_group, camera_bgl)
}

fn create_pipeline(
    device: &wgpu::Device,
    config: &wgpu::SurfaceConfiguration,
    camera_bgl: &wgpu::BindGroupLayout,
) -> wgpu::RenderPipeline {
    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("Cube Shader"),
        source: wgpu::ShaderSource::Wgsl(
            include_str!("../shaders/cube.wgsl").into(),
        ),
    });

    let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("Cube Pipeline Layout"),
        bind_group_layouts: &[camera_bgl],
        push_constant_ranges: &[],
    });

    device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("Cube Pipeline"),
        layout: Some(&layout),
        vertex: wgpu::VertexState {
            module: &shader,
            entry_point: "vs_main",
            buffers: &[wgpu::VertexBufferLayout {
                array_stride: std::mem::size_of::<[f32; 3]>() as u64,
                step_mode: wgpu::VertexStepMode::Vertex,
                attributes: &wgpu::vertex_attr_array![0 => Float32x3],
            }],
            compilation_options: wgpu::PipelineCompilationOptions::default(),
        },
        fragment: Some(wgpu::FragmentState {
            module: &shader,
            entry_point: "fs_main",
            targets: &[Some(wgpu::ColorTargetState {
                format: config.format,
                blend: Some(wgpu::BlendState::REPLACE),
                write_mask: wgpu::ColorWrites::ALL,
            })],
            compilation_options: wgpu::PipelineCompilationOptions::default(),
        }),
        primitive: wgpu::PrimitiveState::default(),
        depth_stencil: Some(wgpu::DepthStencilState {
            format: wgpu::TextureFormat::Depth32Float,
            depth_write_enabled: true,
            depth_compare: wgpu::CompareFunction::Less,
            stencil: wgpu::StencilState::default(),
            bias: wgpu::DepthBiasState::default(),
        }),
        multisample: wgpu::MultisampleState::default(),
        multiview: None,
    })
}

//
// ──────────────────────────────────────────────────────────────
//   Render Pass
// ──────────────────────────────────────────────────────────────
//

fn record_render_pass(
    encoder: &mut wgpu::CommandEncoder,
    color_view: &wgpu::TextureView,
    depth_view: &wgpu::TextureView,
    pipeline: &wgpu::RenderPipeline,
    camera_bg: &wgpu::BindGroup,
    cube: &CubeMesh,
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("Cube Render Pass"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view: color_view,
            resolve_target: None,
            ops: wgpu::Operations {
                load: wgpu::LoadOp::Clear(wgpu::Color {
                    r: 0.02,
                    g: 0.02,
                    b: 0.03,
                    a: 1.0,
                }),
                store: wgpu::StoreOp::Store,
            },
        })],
        depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
            view: depth_view,
            depth_ops: Some(wgpu::Operations {
                load: wgpu::LoadOp::Clear(1.0),
                store: wgpu::StoreOp::Store,
            }),
            stencil_ops: None,
        }),
        occlusion_query_set: None,
        timestamp_writes: None,
    });

    pass.set_pipeline(pipeline);
    pass.set_bind_group(0, camera_bg, &[]);
    pass.set_vertex_buffer(0, cube.vertex_buffer.slice(..));
    pass.set_index_buffer(cube.index_buffer.slice(..), wgpu::IndexFormat::Uint16);
    pass.draw_indexed(0..cube.index_count, 0, 0..1);
}
