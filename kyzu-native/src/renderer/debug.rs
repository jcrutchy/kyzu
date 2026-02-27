use crate::camera::Camera;

//
// ──────────────────────────────────────────────────────────────
//   Debug visualisation for the camera target
//
//   Draws:
//     - White cross  at camera target (world space)
//     - Yellow cross at target projected onto Z=0 (XY plane)
//     - Grey line    connecting them (only when target.z != 0)
//
//   Reuses the axes shader and pipeline — same vertex layout [pos: vec3, col: vec3].
//   Buffer is pre-allocated at startup and written each frame via write_buffer.
// ──────────────────────────────────────────────────────────────
//

//
// ──────────────────────────────────────────────────────────────
//   Constants
// ──────────────────────────────────────────────────────────────
//

const MARKER_ARM: f32 = 0.3;
const COL_TARGET: [f32; 3] = [1.0, 1.0, 1.0]; // white  — camera target
const COL_PROJ: [f32; 3] = [1.0, 1.0, 0.2]; // yellow — XY plane projection
const COL_CONNECT: [f32; 3] = [0.5, 0.5, 0.5]; // grey   — vertical connecting line

// Minimum Z offset before projection cross and connecting line are drawn
const Z_THRESHOLD: f32 = 0.001;

//
// ──────────────────────────────────────────────────────────────
//   Vertex layout: [x, y, z,  r, g, b]  (matches axes shader)
// ──────────────────────────────────────────────────────────────
//

type Vertex = [f32; 6];

// Two 3-axis crosses = 12 verts, plus 2 for the connecting line = 14 maximum
const MAX_VERTS: u64 = 14;

//
// ──────────────────────────────────────────────────────────────
//   DebugMesh
// ──────────────────────────────────────────────────────────────
//

pub struct DebugMesh
{
  pub vertex_buffer: wgpu::Buffer,
  pub vertex_count: u32,
}

impl DebugMesh
{
  pub fn create(device: &wgpu::Device) -> Self
  {
    let vertex_buffer = device.create_buffer(&wgpu::BufferDescriptor {
      label: Some("Debug Vertex Buffer"),
      size: MAX_VERTS * std::mem::size_of::<Vertex>() as u64,
      usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
      mapped_at_creation: false,
    });

    Self { vertex_buffer, vertex_count: 0 }
  }

  pub fn update(&mut self, queue: &wgpu::Queue, camera: &Camera)
  {
    let target = camera.target;
    let proj = glam::Vec3::new(target.x, target.y, 0.0);

    let mut verts: Vec<Vertex> = Vec::with_capacity(MAX_VERTS as usize);

    // White cross at camera target (always drawn)
    push_cross(&mut verts, target.into(), COL_TARGET);

    // Yellow cross and grey connecting line only when target is off the XY plane
    if target.z.abs() > Z_THRESHOLD
    {
      push_cross(&mut verts, proj.into(), COL_PROJ);
      verts.push(make_vertex(target.into(), COL_CONNECT));
      verts.push(make_vertex(proj.into(), COL_CONNECT));
    }

    self.vertex_count = verts.len() as u32;

    queue.write_buffer(&self.vertex_buffer, 0, bytemuck::cast_slice(&verts));
  }
}

//
// ──────────────────────────────────────────────────────────────
//   Geometry helpers
// ──────────────────────────────────────────────────────────────
//

fn make_vertex(pos: [f32; 3], col: [f32; 3]) -> Vertex
{
  [pos[0], pos[1], pos[2], col[0], col[1], col[2]]
}

fn push_cross(verts: &mut Vec<Vertex>, centre: [f32; 3], col: [f32; 3])
{
  let [x, y, z] = centre;

  verts.push(make_vertex([x - MARKER_ARM, y, z], col));
  verts.push(make_vertex([x + MARKER_ARM, y, z], col));

  verts.push(make_vertex([x, y - MARKER_ARM, z], col));
  verts.push(make_vertex([x, y + MARKER_ARM, z], col));

  verts.push(make_vertex([x, y, z - MARKER_ARM], col));
  verts.push(make_vertex([x, y, z + MARKER_ARM], col));
}
