use crate::input::state::InputState;
use crate::render::shared::{CameraMode, SharedState};

pub trait CameraController
{
  fn update(&mut self, shared: &mut SharedState, input: &mut InputState, dt: f32);
}

pub mod free;
pub mod orbital;

pub struct CameraSystem
{
  pub free_controller: free::FreeController,
  pub orbital_controller: orbital::OrbitalController,
  last_mode: CameraMode, // Track the mode to detect transitions
}

impl CameraSystem
{
  pub fn new() -> Self
  {
    Self {
      free_controller: free::FreeController::default(),
      orbital_controller: orbital::OrbitalController::default(),
      last_mode: CameraMode::Orbital, // Default starting mode
    }
  }

  pub fn update(&mut self, shared: &mut SharedState, input: &mut InputState, dt: f32)
  {
    if shared.mode != self.last_mode
    {
      // 1. Reset the mouse delta IMMEDIATELY on transition
      input.consume_mouse_delta();

      match shared.mode
      {
        CameraMode::Free =>
        {
          self.free_controller.position = shared.eye_world;

          let to_target = (self.orbital_controller.target - shared.eye_world).normalize();

          // Derive pitch and yaw that are consistent with from_euler(YXZ, yaw, pitch, 0) * -Z == to_target
          // pitch = asin(to_target.y)  [elevation above XZ plane]
          // yaw: after pitching, the remaining rotation is in XZ — use atan2 on the XZ projection
          let pitch = (to_target.y as f32).asin();
          let yaw = {
            let xz_len = (to_target.x * to_target.x + to_target.z * to_target.z).sqrt() as f32;
            if xz_len < 1e-6
            {
              // Looking straight up or down — yaw is degenerate, keep current
              self.free_controller.yaw
            }
            else
            {
              // from_euler(YXZ, yaw, 0, 0) * -Z = (-sin(yaw), 0, -cos(yaw))
              // so: sin(yaw) = -to_target.x / xz_len, cos(yaw) = -to_target.z / xz_len
              f32::atan2(-to_target.x as f32, -to_target.z as f32)
            }
          };

          self.free_controller.pitch = pitch;
          self.free_controller.yaw = yaw;
          self.free_controller.speed = (self.orbital_controller.altitude * 0.5) as f32;

          // Verify the round-trip in debug
          let rotation = glam::Quat::from_euler(glam::EulerRot::YXZ, yaw, pitch, 0.0);
          let reconstructed_forward = rotation * -glam::Vec3::Z;
          eprintln!("[CAM TRANSITION -> Free]");
          eprintln!("  to_target          : {:?}", to_target);
          eprintln!("  yaw={:.1}deg  pitch={:.1}deg", yaw.to_degrees(), pitch.to_degrees());
          eprintln!("  reconstructed fwd  : {:?}", reconstructed_forward);
          eprintln!("  dot(to_target, fwd): {:.6}", to_target.as_vec3().dot(reconstructed_forward));
          // should be ~1.0
        }
        CameraMode::Orbital =>
        {
          let rel = shared.eye_world - self.orbital_controller.target;
          let dist = rel.length();
          self.orbital_controller.altitude = dist;
          self.orbital_controller.lat = (rel.y / dist).asin().to_degrees();
          self.orbital_controller.lon = (rel.x).atan2(rel.z).to_degrees();
        }
      }
      self.last_mode = shared.mode;
    }

    match shared.mode
    {
      CameraMode::Free => self.free_controller.update(shared, input, dt),
      CameraMode::Orbital => self.orbital_controller.update(shared, input, dt),
    }
  }
}
