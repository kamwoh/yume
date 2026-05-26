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

// Optional region mask (ADR 0059 refinement 2026-05-26). When set, the
// water only renders where the mask is white — i.e. ONLY the river /
// pond region of the semantic map. Without it, the plane covers the
// whole map (and would flood any terrain below water level). plane_size
// must match the ground so the world→UV math lines up.
uniform sampler2D water_mask : filter_linear, repeat_disable;
uniform bool use_water_mask = false;
uniform float plane_size = 80.0;

varying vec3 v_world_pos;

void vertex() {
    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

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
    // Region mask: discard fragments outside the river/pond region so
    // water exists ONLY where the map says water — not as a full plane
    // that would flood low city terrain. Same world→UV math as the
    // ground shader (image_y → world_z, no flip).
    if (use_water_mask) {
        // No V flip — matches pixel_to_world + the ground shader
        // (image_y → world_z, no flip). 2026-05-26.
        vec2 muv = vec2(
            (v_world_pos.x + plane_size * 0.5) / plane_size,
            (v_world_pos.z + plane_size * 0.5) / plane_size
        );
        if (texture(water_mask, muv).r < 0.5) {
            discard;
        }
    }

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
