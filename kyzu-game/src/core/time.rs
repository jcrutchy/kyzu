use std::time::{Duration, Instant};

pub struct TimeState
{
  pub last_frame: Instant,
  pub delta: Duration,
  pub delta_f32: f32,
  pub total_time: Duration,
  pub frame_count: u64,
  pub fps: f32,

  // For FPS averaging
  last_fps_update: Instant,
  frames_since_last_update: u32,
}

impl TimeState
{
  pub fn new() -> Self
  {
    let now = Instant::now();
    Self {
      last_frame: now,
      delta: Duration::from_secs(0),
      delta_f32: 0.0,
      total_time: Duration::from_secs(0),
      frame_count: 0,
      fps: 0.0,
      last_fps_update: now,
      frames_since_last_update: 0,
    }
  }

  /// Update the clock. Call this at the start of every frame.
  pub fn update(&mut self)
  {
    let now = Instant::now();
    self.delta = now.duration_since(self.last_frame);
    self.last_frame = now;

    // Convenience float for math: 0.016 for 60fps
    self.delta_f32 = self.delta.as_secs_f32();
    self.total_time += self.delta;
    self.frame_count += 1;

    // FPS Calculation (Update once per second)
    self.frames_since_last_update += 1;
    let elapsed = now.duration_since(self.last_fps_update);
    if elapsed >= Duration::from_secs(1)
    {
      self.fps = self.frames_since_last_update as f32 / elapsed.as_secs_f32();
      self.frames_since_last_update = 0;
      self.last_fps_update = now;
    }
  }
}
