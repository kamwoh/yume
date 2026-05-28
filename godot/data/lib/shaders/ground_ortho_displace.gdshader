// ground_ortho_displace.gdshader — paint the ground with the hero's
// own orthographic top-down painting.
//
// The orthographic.png (hero-conditioned) carries the painterly grass /
// rocks / mossy patches / dirt paths / water reflections from the hero
// concept. Sampling it as the ground albedo recovers that richness on
// the floor in one step — no multi-biome classification, no flat
// procedural color, no splatmap. The 3D meshes (totems, ruins, trees)
// stand on top of the painted floor.
//
// The heightmap (also hero-conditioned, now with carved stream channels)
// still drives vertex displacement; this shader is the biome-shader's
// sibling, swapped in when scene_config.terrain.albedo_image is set.
//
// Color space: the orthographic PNG is sRGB-encoded. We declare the
// sampler with `source_color` so Godot auto-converts to LINEAR at sample
// time — matches the engine's lighting pipeline.
//
// Uniforms (set via scene.json ground.mesh.shader_params):
//   ortho_albedo : the orthographic painting (sRGB → auto-linear)
//   heightmap    : grayscale elevation
//   plane_size / height_scale / height_offset : terrain displacement
//   crown_lift / crease_darken : LIGHT extra slope shading on top of
//     the painting's own baked GI (kept low to avoid double-shading).

shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_opaque;

uniform sampler2D ortho_albedo : source_color, filter_linear, repeat_disable;
uniform sampler2D heightmap : filter_linear, repeat_disable;
uniform float plane_size = 80.0;
uniform float height_scale = 3.0;
uniform float height_offset = -0.5;

// The orthographic ALREADY has cast shadows + atmospheric tint baked in,
// so we only add a SUBTLE slope-based form-shading so the 3D hills read
// as 3D. Keep these low — going higher = double-shading + muddy look.
uniform float crown_lift : hint_range(0.0, 0.25) = 0.06;
uniform float crease_darken : hint_range(0.0, 0.35) = 0.10;

// The hero-conditioned orthographic has baked SUN + GI (it was generated
// as a warm-sunlit painting). Using it as ALBEDO under the engine's
// directional sun + ambient + saturation adjustments double-lights it
// (washed yellow-cream output). We pre-darken the albedo so the engine's
// own lighting brings it back to the hero brightness. Tune per scene.
uniform float albedo_attenuate : hint_range(0.2, 1.0) = 0.55;

varying vec3 v_world_pos;
varying vec3 v_world_normal;

void vertex() {
    // UV convention must match the biome shader + extraction's
    // pixel_to_world (image_y → world_z, NO V flip).
    vec2 hm_uv = vec2(
        (VERTEX.x + plane_size * 0.5) / plane_size,
        (VERTEX.z + plane_size * 0.5) / plane_size
    );
    float h = texture(heightmap, hm_uv).r + height_offset;
    VERTEX.y += h * height_scale;

    float e = 1.0 / 256.0;
    float hxp = texture(heightmap, hm_uv + vec2(e, 0.0)).r + height_offset;
    float hxn = texture(heightmap, hm_uv - vec2(e, 0.0)).r + height_offset;
    float hzp = texture(heightmap, hm_uv + vec2(0.0, e)).r + height_offset;
    float hzn = texture(heightmap, hm_uv - vec2(0.0, e)).r + height_offset;
    float ds = 2.0 * e * plane_size;
    vec3 sx = vec3(ds, (hxp - hxn) * height_scale, 0.0);
    vec3 sz = vec3(0.0, (hzp - hzn) * height_scale, ds);
    NORMAL = normalize(cross(sz, sx));

    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    v_world_normal = NORMAL;
}

void fragment() {
    vec2 uv = vec2(
        (v_world_pos.x + plane_size * 0.5) / plane_size,
        (v_world_pos.z + plane_size * 0.5) / plane_size
    );
    vec3 albedo = texture(ortho_albedo, uv).rgb * albedo_attenuate;

    // Light 3D form-shading on top of the painted floor. Crowns of hills
    // lift slightly; steep slopes/dips darken. The ortho already does
    // most of the lighting, so this stays subtle.
    float height01 = clamp(0.5 + v_world_pos.y / (height_scale + 0.001), 0.0, 1.0);
    float up01 = clamp(v_world_normal.y, 0.0, 1.0);
    albedo *= mix(1.0, 1.0 + crown_lift, height01 * up01);
    albedo *= mix(1.0, 1.0 - crease_darken, (1.0 - up01));

    ALBEDO = albedo;
    ROUGHNESS = 0.9;
    METALLIC = 0.0;
}
