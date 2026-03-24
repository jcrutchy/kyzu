struct Camera {
    view_proj: mat4x4<f32>,
    inv_view_proj: mat4x4<f32>,
    eye_rel: vec3<f32>,
};

@group(0) @binding(0) var<uniform> camera: Camera;
@group(1) @binding(0) var<uniform> model_mat: mat4x4<f32>;

struct VertexInput {
    @location(0) position: vec3<f32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) local_pos: vec3<f32>,
    @location(1) world_rel_pos: vec3<f32>,
};

@vertex
fn vs_main(model: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    
    let world_rel = model_mat * vec4<f32>(model.position, 1.0);
    
    out.clip_position = camera.view_proj * world_rel;
    out.local_pos = model.position;
    out.world_rel_pos = world_rel.xyz;

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // 1. Calculate a flat face normal using screen-space derivatives
    // This defines the "facets" clearly without needing wireframes
    let face_normal = normalize(cross(dpdx(in.world_rel_pos), dpdy(in.world_rel_pos)));
    
    // 2. Light it from the camera's perspective
    let light_dir = normalize(-in.world_rel_pos);
    let diff = max(dot(face_normal, light_dir), 0.0);
    
    // 3. Vibrant, high-saturation colors (No multipliers to wash it out)
    let base_color = normalize(in.local_pos) * 0.5 + 0.5;
    
    // 4. Strong shading (90% directional, 10% ambient) for visual depth
    let final_color = base_color * (diff * 0.9 + 0.1);

    return vec4<f32>(final_color, 1.0);
}
