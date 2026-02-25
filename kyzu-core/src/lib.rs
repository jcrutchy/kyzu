use wasm_bindgen::prelude::*;
use web_sys::{window, HtmlCanvasElement};

#[wasm_bindgen]
pub async fn start(canvas_id: String) {
    // --- DOM lookup ---
    let window = match window() {
        Some(w) => w,
        None => {
            web_sys::console::log_1(&"Rust: no window()".into());
            return;
        }
    };

    let document = match window.document() {
        Some(d) => d,
        None => {
            web_sys::console::log_1(&"Rust: no document()".into());
            return;
        }
    };

    let canvas_el = match document.get_element_by_id(&canvas_id) {
        Some(c) => c,
        None => {
            web_sys::console::log_1(&format!("Rust: no canvas with id {}", canvas_id).into());
            return;
        }
    };

    let canvas: HtmlCanvasElement = match canvas_el.dyn_into::<HtmlCanvasElement>() {
        Ok(c) => c,
        Err(_) => {
            web_sys::console::log_1(&"Rust: element is not an HtmlCanvasElement".into());
            return;
        }
    };

    web_sys::console::log_1(&"Rust: start() called".into());

    // --- Instance + surface ---
    let instance = wgpu::Instance::default();

    let surface = match instance.create_surface(wgpu::SurfaceTarget::Canvas(canvas)) {
        Ok(s) => s,
        Err(e) => {
            web_sys::console::log_1(&format!("Rust: failed to create surface: {:?}", e).into());
            return;
        }
    };
    web_sys::console::log_1(&"Rust: surface created".into());

    // --- Adapter ---
    let adapter = match instance
        .request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: Some(&surface),
            force_fallback_adapter: false,
        })
        .await
    {
        Some(a) => a,
        None => {
            web_sys::console::log_1(&"Rust: request_adapter() returned None".into());
            return;
        }
    };
    web_sys::console::log_1(&"Rust: adapter acquired".into());

    // --- Device + queue (use adapter limits) ---
    let adapter_limits = adapter.limits();

    let (device, queue) = match adapter
        .request_device(
            &wgpu::DeviceDescriptor {
                label: Some("Kyzu Device"),
                required_features: wgpu::Features::empty(),
                required_limits: adapter_limits,
            },
            None,
        )
        .await
    {
        Ok(pair) => pair,
        Err(e) => {
            web_sys::console::log_1(&format!("Rust: request_device() failed: {:?}", e).into());
            return;
        }
    };
    web_sys::console::log_1(&"Rust: device + queue acquired".into());

    // --- Surface config ---
    let width = match window.inner_width() {
        Ok(v) => v.as_f64().unwrap_or(0.0) as u32,
        Err(_) => 0,
    };
    let height = match window.inner_height() {
        Ok(v) => v.as_f64().unwrap_or(0.0) as u32,
        Err(_) => 0,
    };
    web_sys::console::log_1(&format!("Rust: surface size = {}x{}", width, height).into());

    let surface_caps = surface.get_capabilities(&adapter);
    if surface_caps.formats.is_empty() {
        web_sys::console::log_1(&"Rust: no surface formats available".into());
        return;
    }
    let surface_format = surface_caps.formats[0];
    web_sys::console::log_1(&format!("Rust: surface format = {:?}", surface_format).into());

    let config = wgpu::SurfaceConfiguration {
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        format: surface_format,
        width,
        height,
        present_mode: wgpu::PresentMode::Fifo,
        alpha_mode: wgpu::CompositeAlphaMode::Auto,
        view_formats: vec![],
        desired_maximum_frame_latency: 2,
    };

    surface.configure(&device, &config);
    web_sys::console::log_1(&"Rust: surface configured".into());

    // --- Shader (WGSL) ---
    let shader_src = r#"
        @vertex
        fn vs_main(@builtin(vertex_index) idx : u32) -> @builtin(position) vec4<f32> {
            var positions = array<vec2<f32>, 3>(
                vec2<f32>(-0.5, -0.5),
                vec2<f32>( 0.5, -0.5),
                vec2<f32>( 0.0,  0.5),
            );
            let pos = positions[idx];
            return vec4<f32>(pos, 0.0, 1.0);
        }

        @fragment
        fn fs_main() -> @location(0) vec4<f32> {
            return vec4<f32>(0.2, 0.8, 0.4, 1.0);
        }
    "#;

    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("Kyzu Triangle Shader"),
        source: wgpu::ShaderSource::Wgsl(shader_src.into()),
    });
    web_sys::console::log_1(&"Rust: shader created".into());

    // --- Pipeline ---
    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("Kyzu Pipeline Layout"),
        bind_group_layouts: &[],
        push_constant_ranges: &[],
    });

    let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("Kyzu Triangle Pipeline"),
        layout: Some(&pipeline_layout),
        vertex: wgpu::VertexState {
            module: &shader,
            entry_point: "vs_main",
            buffers: &[],
            compilation_options: wgpu::PipelineCompilationOptions::default(),
        },
        fragment: Some(wgpu::FragmentState {
            module: &shader,
            entry_point: "fs_main",
            targets: &[Some(wgpu::ColorTargetState {
                format: surface_format,
                blend: Some(wgpu::BlendState::REPLACE),
                write_mask: wgpu::ColorWrites::ALL,
            })],
            compilation_options: wgpu::PipelineCompilationOptions::default(),
        }),
        primitive: wgpu::PrimitiveState {
            topology: wgpu::PrimitiveTopology::TriangleList,
            ..Default::default()
        },
        depth_stencil: None,
        multisample: wgpu::MultisampleState::default(),
        multiview: None,
    });
    web_sys::console::log_1(&"Rust: pipeline created".into());

    // --- One frame: acquire surface texture, draw, present ---
    let frame = match surface.get_current_texture() {
        Ok(frame) => frame,
        Err(e) => {
            web_sys::console::log_1(
                &format!("Rust: get_current_texture failed: {:?}", e).into(),
            );
            return;
        }
    };
    web_sys::console::log_1(&"Rust: got current texture".into());

    let view = frame
        .texture
        .create_view(&wgpu::TextureViewDescriptor::default());

    let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
        label: Some("Kyzu Command Encoder"),
    });

    {
        let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("Kyzu Render Pass"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color {
                        r: 0.05,
                        g: 0.05,
                        b: 0.08,
                        a: 1.0,
                    }),
                    store: wgpu::StoreOp::Store,
                },
            })],
            depth_stencil_attachment: None,
            occlusion_query_set: None,
            timestamp_writes: None,
        });

        rpass.set_pipeline(&pipeline);
        rpass.draw(0..3, 0..1);
    }
    web_sys::console::log_1(&"Rust: commands encoded".into());

    queue.submit(Some(encoder.finish()));
    frame.present();

    web_sys::console::log_1(&"Rust: triangle frame submitted".into());
}
