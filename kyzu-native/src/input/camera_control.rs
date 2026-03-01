use crate::camera::Camera;
use crate::input::InputState;

//
// ──────────────────────────────────────────────────────────────
//   Sensitivity constants
// ──────────────────────────────────────────────────────────────
//

const ORBIT_SENSITIVITY: f64 = 0.005; // radians per pixel
const PAN_SENSITIVITY: f64 = 0.002; // world units per pixel (scaled by radius)

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
  if !input.right_held || (input.mouse_dx == 0.0 && input.mouse_dy == 0.0)
  {
    return;
  }
  camera
    .orbit(input.mouse_dx as f64 * ORBIT_SENSITIVITY, input.mouse_dy as f64 * ORBIT_SENSITIVITY);
}

fn apply_pan(input: &InputState, camera: &mut Camera)
{
  if !input.middle_held || (input.mouse_dx == 0.0 && input.mouse_dy == 0.0)
  {
    return;
  }

  let scale = camera.radius * PAN_SENSITIVITY;
  let dx = -input.mouse_dx as f64 * scale;
  let dy = input.mouse_dy as f64 * scale;

  camera.pan(dx, dy);
}

fn apply_zoom(input: &InputState, camera: &mut Camera)
{
  if input.scroll == 0.0
  {
    return;
  }

  // Scroll up (positive) zooms in, scroll down zooms out
  let factor = (1.1_f64).powf(-input.scroll as f64);

  camera.zoom(factor);
}
