struct Camera {
    view_proj: mat4x4<f32>,
    inv_view_proj: mat4x4<f32>,
    eye_rel: vec3<f32>,
};

@group(0) @binding(0) var<uniform> camera: Camera;
@group(1) @binding(0) var<uniform> model_mat: mat4x4<f32>;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) height: f32,
    @location(4) hex_id: u32,
    @location(5) barycentric: vec3<f32>,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) local_pos: vec3<f32>,
    @location(1) world_rel_pos: vec3<f32>,
    @location(2) barycentric: vec3<f32>,
    @location(3) height: f32,
};

@vertex
fn vs_main(model: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    
    // 1. Apply Elevation Displacement
    // 0.00001 is a safe starting scale for ETOPO meters on a unit-scale planet
    let displacement = 1.0 + (model.height * 0.00001);
    let displaced_local = model.position * displacement;
    
    // 2. Transform to World Space
    let world_rel = model_mat * vec4<f32>(displaced_local, 1.0);
    
    out.clip_position = camera.view_proj * world_rel;
    out.local_pos = model.position;
    out.world_rel_pos = world_rel.xyz;
    out.barycentric = model.barycentric;
    out.height = model.height;

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    // 1. Calculate Face Normal for faceted shading
    let face_normal = normalize(cross(dpdx(in.world_rel_pos), dpdy(in.world_rel_pos)));
    
    // 2. Simple Elevation-based Coloring
    var base_color = vec3<f32>(0.2, 0.5, 0.2); // Default Green
    if (in.height < 0.0) {
        base_color = vec3<f32>(0.05, 0.15, 0.5); // Deep Blue
    } else if (in.height > 3000.0) {
        base_color = vec3<f32>(0.9, 0.9, 1.0); // Snow Peaks
    }

    // 3. Lighting (Directional + Ambient)
    let light_dir = normalize(vec3<f32>(1.0, 1.0, 1.0));
    let diff = max(dot(face_normal, light_dir), 0.15);
    let lit_color = base_color * diff;

    // 4. Barycentric Wireframe Overlay
    // Use fwidth to keep line thickness consistent regardless of distance
    let edge_dist = min(in.barycentric.x, min(in.barycentric.y, in.barycentric.z));
    let delta = fwidth(edge_dist);
    let wireframe_strength = smoothstep(0.0, delta * 1.5, edge_dist);

    // Dark grid color for the lines
    let grid_color = vec3<f32>(0.02, 0.02, 0.05);
    let final_rgb = mix(grid_color, lit_color, wireframe_strength);

    return vec4<f32>(final_rgb, 1.0);
}
