// ground_multi_biome.gdshader — blend two tileable ground textures
// via a WORLD-SCALE splatmap.
//
// Why two UV scales:
//   - The textures (albedo_a, albedo_b, normal_map) TILE — UV mult
//     by uv1_scale = ~60, so the same 1m feature repeats across the
//     400m plane.
//   - The splatmap does NOT tile. It maps the WHOLE plane to UV
//     [0,1], so each pixel of the splatmap corresponds to a specific
//     world position. This lets authors place "trampled camp" at
//     world origin without it repeating every 6m.
//
// Per ADR 0052, shader is referenced from JSON via visual.shader.
// Specific to ground because GroundRenderer (not the entity renderer)
// applies it — see ground_renderer.gd.
//
// Uniforms:
//   albedo_a       : Texture2D — primary ground (e.g. leaf-litter)
//   albedo_b       : Texture2D — secondary ground (e.g. trampled dirt)
//   normal_map     : Texture2D — shared normal map (tiles with both)
//   splat_mask     : Texture2D — world-scale RG: R=blend(a→b)
//   plane_size     : world-space size of the plane (default 400.0)
//   uv_tile        : how many times to tile albedo_a/b/normal across
//                    the plane (default 60). Same value used in the
//                    one-texture flow.

shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_opaque;

uniform sampler2D albedo_a : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_b : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D splat_mask : filter_linear, repeat_disable;
uniform float plane_size = 400.0;
uniform float uv_tile : hint_range(1.0, 200.0) = 60.0;
uniform float roughness_uniform : hint_range(0.0, 1.0) = 0.92;
uniform float metallic_uniform : hint_range(0.0, 1.0) = 0.0;

// Varying carries world-space vertex position from vertex → fragment.
// REQUIRED because Godot 4's default behavior transforms VERTEX into
// VIEW space before the fragment stage. Without this, splatmap UVs
// drift with the camera (visible as "the trampled zone follows the
// player"). Bug found 2026-05-18 — see post-mortem in this file's
// history.
varying vec3 v_world_pos;

void vertex() {
    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    // Tiled UVs for albedo + normal (close-up surface detail)
    vec2 tex_uv = UV * uv_tile;

    // WORLD-SPACE UVs for the splatmap. v_world_pos comes from the
    // vertex shader (above). Mapping: a `plane_size`-wide plane
    // centered at world origin → UV [0,1]. Z is flipped because
    // PlaneMesh's UV(0,0) is top-left when viewed from above, but
    // world Z grows southward.
    vec2 splat_uv = vec2(
        (v_world_pos.x + plane_size * 0.5) / plane_size,
        1.0 - (v_world_pos.z + plane_size * 0.5) / plane_size
    );

    // Sample
    vec3 col_a = texture(albedo_a, tex_uv).rgb;
    vec3 col_b = texture(albedo_b, tex_uv).rgb;
    float blend = texture(splat_mask, splat_uv).r;

    // Smoothstep on the mask gives crisper transitions than raw lerp
    float t = smoothstep(0.1, 0.7, blend);
    ALBEDO = mix(col_a, col_b, t);

    NORMAL_MAP = texture(normal_map, tex_uv).xyz;
    ROUGHNESS = roughness_uniform;
    METALLIC = metallic_uniform;
}
