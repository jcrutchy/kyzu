use crate::camera::Camera;
use crate::input::InputState;

//
// ──────────────────────────────────────────────────────────────
//   Sensitivity constants
// ──────────────────────────────────────────────────────────────
//

const ORBIT_SENSITIVITY: f32 = 0.005; // radians per pixel
const PAN_SENSITIVITY: f32 = 0.002; // world units per pixel (scaled by radius)
const ZOOM_FACTOR: f32 = 0.1; // 10% radius change per scroll line

//
// ──────────────────────────────────────────────────────────────
//   Public API
// ──────────────────────────────────────────────────────────────
//

pub fn apply_input_to_camera(input: &InputState, camera: &mut Camera)
{
  apply_orbit(input, camera);
  apply_pan(input, camera);
  apply_zoom(input, camera);
}

//
// ──────────────────────────────────────────────────────────────
//   Input handlers
// ──────────────────────────────────────────────────────────────
//

fn apply_orbit(input: &InputState, camera: &mut Camera)
{
  if !input.right_held
  {
    return;
  }

  if input.mouse_dx == 0.0 && input.mouse_dy == 0.0
  {
    return;
  }

  let delta_az = -input.mouse_dx * ORBIT_SENSITIVITY;
  let delta_el = input.mouse_dy * ORBIT_SENSITIVITY;

  camera.orbit(delta_az, delta_el);
}

fn apply_pan(input: &InputState, camera: &mut Camera)
{
  if !input.middle_held
  {
    return;
  }

  if input.mouse_dx == 0.0 && input.mouse_dy == 0.0
  {
    return;
  }

  // Scale pan speed by radius so it feels consistent at all zoom levels
  let scale = camera.radius * PAN_SENSITIVITY;
  let dx = -input.mouse_dx * scale;
  let dy = input.mouse_dy * scale;

  camera.pan(dx, dy);
}

fn apply_zoom(input: &InputState, camera: &mut Camera)
{
  if input.scroll == 0.0
  {
    return;
  }

  // Scroll up (positive) zooms in, scroll down zooms out
  let factor = 1.0 - input.scroll * ZOOM_FACTOR;

  camera.zoom(factor);
}
