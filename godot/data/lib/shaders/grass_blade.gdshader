// grass_blade.gdshader — instanced grass-blade cards (MultiMesh).
//
// Each blade is a small tapered quad standing in local +Y (base at y=0,
// tip at y=blade_height; UV.y carries the 0..1 height ratio). The vertex
// shader bends the blade by a TIME-driven wind wave whose phase varies by
// world position, so a field of blades ripples like a breeze — the sway
// lives entirely in the vertex shader (cheap), no per-blade physics.
//
// Opaque, double-sided (cull_disabled): no alpha → no transparency
// overdraw, which is the usual grass perf killer. Colour is a base→tip
// green gradient, no texture.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec3 base_color : source_color = vec3(0.16, 0.40, 0.11);
uniform vec3 tip_color  : source_color = vec3(0.50, 0.74, 0.32);
uniform float sway_strength = 0.18;   // metres the tip leans
uniform float sway_speed = 1.6;
uniform float sway_scale = 0.25;       // spatial frequency of the wind wave
uniform vec2 wind_dir = vec2(0.7, 0.7);

varying float v_h;

void vertex() {
    v_h = UV.y;                                  // 0 at base, 1 at tip
    // World position of this instance's base (MODEL_MATRIX includes the
    // per-instance MultiMesh transform) → per-blade phase so the field
    // ripples rather than swaying in unison.
    vec3 wp = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    float phase = dot(wp.xz, normalize(wind_dir)) * sway_scale;
    float bend = sin(TIME * sway_speed + phase) * sway_strength * v_h * v_h;
    // Lean along the wind direction; quadratic in height so the base stays
    // planted and the tip moves most.
    VERTEX.x += bend * wind_dir.x;
    VERTEX.z += bend * wind_dir.y;
}

void fragment() {
    ALBEDO = mix(base_color, tip_color, v_h);
    ROUGHNESS = 0.92;
    METALLIC = 0.0;
}
