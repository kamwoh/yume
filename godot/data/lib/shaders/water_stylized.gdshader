// water_stylized.gdshader — stylized animated water for Yume.
//
// Lit transparent surface with TWO layers of value-noise scrolled in
// different directions to fake animated ripples. No external textures
// needed; everything is procedural. Cheap (one shader, no normal map
// lookup).
//
// Uniforms (set via visual.shader_params on the entity):
//   base_color       : RGBA — deep water color
//   highlight_color  : RGBA — bright crest color (mixed in at wave peaks)
//   wave_speed       : 0..1 — overall scroll rate
//   ripple_density   : 1..20 — how many ripples per UV unit
//   wave_dir1        : XY direction vector for layer 1
//   wave_dir2        : XY direction vector for layer 2
//   metallic_uniform : 0..1 — water shimmers when slightly metallic
//
// Authored for aldenmere's river prop. Reusable for ponds, puddles,
// and any animated liquid surface.

shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_opaque, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(0.15, 0.35, 0.45, 0.75);
uniform vec4 highlight_color : source_color = vec4(0.70, 0.85, 0.92, 0.85);
uniform float wave_speed : hint_range(0.0, 1.0) = 0.08;
uniform float ripple_density : hint_range(1.0, 20.0) = 6.0;
uniform vec2 wave_dir1 = vec2(1.0, 0.4);
uniform vec2 wave_dir2 = vec2(-0.4, 1.0);
uniform float metallic_uniform : hint_range(0.0, 1.0) = 0.30;
uniform float roughness_min : hint_range(0.0, 1.0) = 0.05;
uniform float roughness_max : hint_range(0.0, 1.0) = 0.25;

// Value-noise — fast 2D noise without textures.
float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise2d(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash21(i + vec2(0.0, 0.0)), hash21(i + vec2(1.0, 0.0)), u.x),
        mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x),
        u.y
    );
}

void fragment() {
    vec2 uv1 = UV * ripple_density + TIME * wave_speed * wave_dir1;
    vec2 uv2 = UV * ripple_density * 1.7 - TIME * wave_speed * 0.7 * wave_dir2;
    float wave = (noise2d(uv1) + noise2d(uv2)) * 0.5;

    // Mix base + highlight by wave intensity. Smoothstep gives sharper
    // crests instead of muddy averaging.
    float t = smoothstep(0.35, 0.75, wave);
    ALBEDO = mix(base_color.rgb, highlight_color.rgb, t);
    ALPHA = mix(base_color.a, highlight_color.a, t);

    // Brighter crests = smoother (more reflective).
    METALLIC = metallic_uniform;
    ROUGHNESS = mix(roughness_max, roughness_min, t);
}
