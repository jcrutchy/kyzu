// ──────────────────────────────────────────────────────────────
//   Sphere shader — unlit, per-instance scale + translate
//
//   Vertex positions are on a unit sphere. The vertex shader
//   scales by radius and translates by center_rel (both already
//   camera-relative), then applies view_proj.
//
//   eye_world is NOT subtracted here — center_rel was already
//   computed as (world_center - eye) on the CPU.
// ──────────────────────────────────────────────────────────────

struct CameraUniform {
    view_proj : mat4x4<f32>,
    eye_world : vec3<f32>,
    _pad      : f32,
};

@group(0) @binding(0)
var<uniform> camera : CameraUniform;

struct VsIn {
    // Per-vertex (buffer 0)
    @location(0) position   : vec3<f32>,
    @location(1) normal     : vec3<f32>,
    // Per-instance (buffer 1)
    @location(2) center_rel : vec3<f32>,
    @location(3) radius     : f32,
};

struct VsOut {
    @builtin(position) pos    : vec4<f32>,
    @location(0)       normal : vec3<f32>,
};

@vertex
fn vs_main(in : VsIn) -> VsOut {
    // Scale unit sphere by radius, then place at camera-relative center
    let world_pos = in.position * in.radius + in.center_rel;

    var out : VsOut;
    out.pos    = camera.view_proj * vec4<f32>(world_pos, 1.0);
    out.normal = in.normal;
    return out;
}

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    // Simple directional shading so the sphere reads as 3D
    let light_dir = normalize(vec3<f32>(0.6, 0.4, 1.0));
    let n         = normalize(in.normal);
    let diffuse   = clamp(dot(n, light_dir), 0.0, 1.0);
    let ambient   = 0.15;
    let intensity = ambient + (1.0 - ambient) * diffuse;

    let color = vec3<f32>(0.3, 0.55, 0.9); // blue-grey
    return vec4<f32>(color * intensity, 1.0);
}
