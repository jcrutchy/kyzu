use glam::DVec3;

// ──────────────────────────────────────────────────────────────
//   The 12 vertices of a unit icosahedron
//   Golden ratio φ = (1 + √5) / 2
// ──────────────────────────────────────────────────────────────

pub fn base_vertices() -> [DVec3; 12]
{
  let phi = (1.0 + 5.0_f64.sqrt()) / 2.0;
  let len = (1.0_f64 + phi * phi).sqrt();
  let a = 1.0 / len;
  let b = phi / len;

  [
    DVec3::new(-a, b, 0.0),  //  0
    DVec3::new(a, b, 0.0),   //  1
    DVec3::new(-a, -b, 0.0), //  2
    DVec3::new(a, -b, 0.0),  //  3
    DVec3::new(0.0, -a, b),  //  4
    DVec3::new(0.0, a, b),   //  5
    DVec3::new(0.0, -a, -b), //  6
    DVec3::new(0.0, a, -b),  //  7
    DVec3::new(b, 0.0, -a),  //  8
    DVec3::new(b, 0.0, a),   //  9
    DVec3::new(-b, 0.0, -a), // 10
    DVec3::new(-b, 0.0, a),  // 11
  ]
}

// ──────────────────────────────────────────────────────────────
//   The 20 faces — each is [v0, v1, v2] indices into base_vertices()
//   Winding order: counter-clockwise when viewed from outside
// ──────────────────────────────────────────────────────────────

pub const FACES: [[usize; 3]; 20] = [
  // Top cap (around vertex 0)
  [0, 11, 5],
  [0, 5, 1],
  [0, 1, 7],
  [0, 7, 10],
  [0, 10, 11],
  // Upper band
  [1, 5, 9],
  [5, 11, 4],
  [11, 10, 2],
  [10, 7, 6],
  [7, 1, 8],
  // Lower band
  [3, 9, 4],
  [3, 4, 2],
  [3, 2, 6],
  [3, 6, 8],
  [3, 8, 9],
  // Bottom cap (around vertex 3)
  [4, 9, 5],
  [2, 4, 11],
  [6, 2, 10],
  [8, 6, 7],
  [9, 8, 1],
];

// ──────────────────────────────────────────────────────────────
//   Subdivide once — splits each triangle into 4
//   New midpoint vertices are projected back onto the unit sphere
// ──────────────────────────────────────────────────────────────

pub fn subdivide(vertices: &mut Vec<DVec3>, faces: &[[usize; 3]]) -> Vec<[usize; 3]>
{
  use std::collections::HashMap;

  let mut new_faces = Vec::with_capacity(faces.len() * 4);
  let mut midpoint_cache: HashMap<(usize, usize), usize> = HashMap::new();

  let mut get_midpoint = |a: usize, b: usize, verts: &mut Vec<DVec3>| -> usize {
    let key = if a < b { (a, b) } else { (b, a) };
    if let Some(&idx) = midpoint_cache.get(&key)
    {
      return idx;
    }
    let mid = (verts[a] + verts[b]).normalize();
    let idx = verts.len();
    verts.push(mid);
    midpoint_cache.insert(key, idx);
    idx
  };

  for face in faces
  {
    let [a, b, c] = *face;
    let ab = get_midpoint(a, b, vertices);
    let bc = get_midpoint(b, c, vertices);
    let ca = get_midpoint(c, a, vertices);

    new_faces.push([a, ca, ab]); // was [a, ab, ca]
    new_faces.push([b, ab, bc]); // was [b, bc, ab]
    new_faces.push([c, bc, ca]); // was [c, ca, bc]
    new_faces.push([ab, ca, bc]); // was [ab, bc, ca]
  }

  new_faces
}

// ──────────────────────────────────────────────────────────────
//   Build a subdivided mesh at a given level
//   Returns (vertices, faces) on the unit sphere
// ──────────────────────────────────────────────────────────────

pub fn build(level: u32) -> (Vec<DVec3>, Vec<[usize; 3]>)
{
  let mut vertices: Vec<DVec3> = base_vertices().to_vec();
  let mut faces: Vec<[usize; 3]> = FACES.to_vec();

  for _ in 0..level
  {
    faces = subdivide(&mut vertices, &faces);
  }

  (vertices, faces)
}
