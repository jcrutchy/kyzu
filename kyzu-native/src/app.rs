use std::sync::{Arc, Mutex};
use winit::{
    event::*,
    event_loop::{EventLoop, EventLoopWindowTarget},
    window::WindowBuilder,
};

use crate::camera::Camera;
use crate::renderer::Renderer;

//
// ──────────────────────────────────────────────────────────────
//   Entry point
// ──────────────────────────────────────────────────────────────
//

pub fn run() {
    let event_loop = EventLoop::new().unwrap();
    let window = create_window(&event_loop);

    let camera = Arc::new(Mutex::new(create_camera(&window)));
    let mut renderer = create_renderer(&window, &camera);

    let window_ref = window.clone();
    let camera_ref = camera.clone();

    let _ = event_loop.run(move |event, elwt| {
        handle_event(&window_ref, &mut renderer, &camera_ref, event, elwt);
    });
}

//
// ──────────────────────────────────────────────────────────────
//   Setup helpers
// ──────────────────────────────────────────────────────────────
//

fn create_window(event_loop: &EventLoop<()>) -> Arc<winit::window::Window> {
    Arc::new(
        WindowBuilder::new()
            .with_title("Kyzu — Minimal Cube")
            .build(event_loop)
            .unwrap(),
    )
}

fn create_camera(window: &winit::window::Window) -> Camera {
    let size = window.inner_size();
    Camera::new(size.width as f32 / size.height as f32)
}

fn create_renderer<'a>(
    window: &'a Arc<winit::window::Window>,
    camera: &'a Arc<Mutex<Camera>>,
) -> Renderer<'a> {
    pollster::block_on(Renderer::new(window, camera))
}

//
// ──────────────────────────────────────────────────────────────
//   Event dispatcher
// ──────────────────────────────────────────────────────────────
//

fn handle_event(
    window: &Arc<winit::window::Window>,
    renderer: &mut Renderer,
    camera: &Arc<Mutex<Camera>>,
    event: Event<()>,
    elwt: &EventLoopWindowTarget<()>,
) {
    match event {
        Event::WindowEvent { event, .. } => {
            handle_window_event(window, renderer, camera, event, elwt);
        }

        Event::AboutToWait => {
            renderer.render();
            window.request_redraw();
        }

        _ => {}
    }
}

//
// ──────────────────────────────────────────────────────────────
//   Window event handler
// ──────────────────────────────────────────────────────────────
//

fn handle_window_event(
    _window: &Arc<winit::window::Window>,
    renderer: &mut Renderer,
    camera: &Arc<Mutex<Camera>>,
    event: WindowEvent,
    elwt: &EventLoopWindowTarget<()>,
) {
    match event {
        WindowEvent::CloseRequested => {
            elwt.exit();
        }

        WindowEvent::Resized(size) => {
            if size.width == 0 || size.height == 0 {
                return;
            }

            let mut cam = camera.lock().unwrap();
            cam.set_aspect(size.width as f32 / size.height as f32);
            renderer.update_camera(&cam);
        }

        WindowEvent::ScaleFactorChanged { .. } => {}

        _ => {}
    }
}
