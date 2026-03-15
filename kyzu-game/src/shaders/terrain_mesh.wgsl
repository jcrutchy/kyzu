struct CameraUniform {
    view_proj     : mat4x4<f32>,
    inv_view_proj : mat4x4<f32>,
    eye_world     : vec3<f32>,
    _pad          : f32,
    fade_near     : f32,
    fade_far      : f32,
    lod_scale     : f32,
    lod_fade      : f32,
    cam_target    : vec3<f32>,
    _pad2         : f32,
    radius        : f32,
    _pad3         : f32,
    target_rel    : vec3<f32>,
    _pad4         : f32,
    sun_dir       : vec3<f32>,
    _pad5         : f32,
};

@group(0) @binding(0) var<uniform> camera : CameraUniform;

struct VsIn {
    @location(0) position : vec3<f32>, // eye-relative, metres
    @location(1) color    : vec3<f32>,
};

struct VsOut {
    @builtin(position) clip_pos : vec4<f32>,
    @location(0)       color    : vec3<f32>,
    @location(1)       normal   : vec3<f32>,
};

@vertex
fn vs_main(in: VsIn) -> VsOut
{
    // Position is already eye-relative (computed in f64 on CPU)
    // Normal is derived from world position = eye + rel
    let world_pos = in.position + camera.eye_world;
    let normal    = normalize(world_pos);

    var out: VsOut;
    out.clip_pos = camera.view_proj * vec4<f32>(in.position, 1.0);
    out.color    = in.color;
    out.normal   = normal;
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32>
{
    let n       = normalize(in.normal);
    let diffuse = clamp(dot(n, -camera.sun_dir), 0.0, 1.0);
    let ambient = 0.15;
    let light   = ambient + (1.0 - ambient) * diffuse;

    return vec4<f32>(in.color * light, 1.0);
}
