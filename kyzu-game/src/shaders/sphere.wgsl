struct CameraUniform {
    view_proj     : mat4x4<f32>,
    inv_view_proj : mat4x4<f32>,
    eye_world     : vec3<f32>,
    _pad          : f32,
    fade_near     : f32,
    fade_far      : f32,
    lod_scale     : f32,
    lod_fade      : f32,
    cam_target    : vec3<f32>,  // renamed from target
    _pad2         : f32,
    radius        : f32,
    _pad3         : f32,
    target_rel    : vec3<f32>,
    _pad4         : f32,
    sun_dir       : vec3<f32>,
    _pad5         : f32,
};

@group(0) @binding(0) var<uniform> camera : CameraUniform;
@group(1) @binding(0) var t_surface : texture_2d<f32>;
@group(1) @binding(1) var s_surface : sampler;

struct VsIn {
    @location(0) position   : vec3<f32>,
    @location(1) normal     : vec3<f32>,
    @location(2) uv         : vec2<f32>,
    @location(3) center_rel : vec3<f32>,
    @location(4) radius     : f32,
};

struct VsOut {
    @builtin(position) clip_pos : vec4<f32>,
    @location(0)       normal   : vec3<f32>,
    @location(1)       uv       : vec2<f32>,
};

@vertex
fn vs_main(in: VsIn) -> VsOut {
    let world_pos = in.position * in.radius + in.center_rel;

    var out: VsOut;
    out.clip_pos = camera.view_proj * vec4<f32>(world_pos, 1.0);
    out.normal   = in.normal;
    out.uv       = in.uv;
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let tex_color = textureSample(t_surface, s_surface, in.uv);

    let n       = normalize(in.normal);
    let diffuse = clamp(dot(n, -camera.sun_dir), 0.0, 1.0);
    let ambient = 0.05;
    let light   = ambient + (1.0 - ambient) * diffuse;

    return vec4<f32>(tex_color.rgb * light, 1.0);
}
