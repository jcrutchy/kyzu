// ─────────────────────────────────────────────────────────────────────────────
//  Kyzu — body.wgsl
//
//  Renders a single solar system body as a smooth-shaded sphere.
//  Group 0: camera  (shared across all draw calls this frame)
//  Group 1: body    (per-body — model matrix, base colour, light direction)
// ─────────────────────────────────────────────────────────────────────────────

struct Camera
{
    view_proj:     mat4x4<f32>,
    inv_view_proj: mat4x4<f32>,
    eye_rel:       vec3<f32>,
    _pad:          f32,
};

struct BodyUniforms
{
    model_mat:  mat4x4<f32>,
    base_color: vec4<f32>,
    // Direction FROM this body TOWARD the sun, in world-relative space.
    // Unused when is_star == 1.
    light_dir:  vec3<f32>,
    is_star:    u32,
};

@group(0) @binding(0) var<uniform> camera: Camera;
@group(1) @binding(0) var<uniform> body:   BodyUniforms;

struct VertexInput
{
    @location(0) position:    vec3<f32>,
    @location(1) normal:      vec3<f32>,
    @location(2) uv:          vec2<f32>,
    @location(3) height:      f32,
    @location(4) hex_id:      u32,
    @location(5) barycentric: vec3<f32>,
};

struct VertexOutput
{
    @builtin(position) clip_pos:   vec4<f32>,
    @location(0)       world_norm: vec3<f32>,
};

@vertex
fn vs_main(v: VertexInput) -> VertexOutput
{
    var out: VertexOutput;

    let world_pos = body.model_mat * vec4<f32>(v.position, 1.0);
    out.clip_pos  = camera.view_proj * world_pos;

    // Rotate normal by the upper-left 3x3 of model_mat.
    // Safe because we only use uniform scale + rotation (no shear).
    let m         = body.model_mat;
    let norm_mat  = mat3x3<f32>(m[0].xyz, m[1].xyz, m[2].xyz);
    out.world_norm = normalize(norm_mat * v.normal);

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32>
{
    let base = body.base_color.rgb;

    // Stars are self-luminous — return flat colour, no lighting.
    if body.is_star == 1u
    {
        return vec4<f32>(base, 1.0);
    }

    // Diffuse + ambient
    let ambient  = 0.08;
    let n        = normalize(in.world_norm);
    let l        = normalize(body.light_dir);
    let diffuse  = max(dot(n, l), 0.0);
    let light    = ambient + (1.0 - ambient) * diffuse;

    return vec4<f32>(base * light, 1.0);
}
