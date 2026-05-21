// ground_5biome.gdshader — blend 5 tileable ground textures via a
// COLORED biome map. Implements ADR 0055 (multi-biome ground from
// the semantic map).
//
// The biome map is a top-down semantic PNG where per-pixel RGB
// encodes WHICH biome that spot belongs to (color-distance match).
// Reuses the same semantic map produced by compose_map.py — no
// separate authoring step.
//
// Per ADR 0052, shader is referenced from JSON via `ground.mesh.shader`.
//
// Per ADR 0055 v2, the biome_map uniform can be rebound per-level
// via `GroundRenderer.rebind_shader_params(level_id)` triggered from
// level_transition_coordinator.gd. See ADR for the snap-on-transition
// semantics (invariant #11).
//
// Uniforms:
//   biome_map         : Texture2D — the semantic map (1024x1024 PNG
//                       produced by compose_map.py). Per-pixel RGB
//                       encodes biome membership via color distance
//                       to the biome_color_* reference colors.
//   biome_color_*     : vec4 reference color per biome (5 slots:
//                       dirt / grass / water / path / forest)
//   albedo_*          : Texture2D — tileable albedo per biome
//   plane_size        : world-space size of the plane (set by
//                       GroundRenderer per ADR 0052)
//   uv_tile           : how many times to tile albedos across the
//                       plane (default 30)
//   blend_softness    : color-distance threshold for soft blending.
//                       Larger = softer transitions. Default 0.5.

shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_opaque;

// Biome map — the semantic top-down PNG. Sampled in world-space via
// the v_world_pos varying (see vertex() / fragment() below).
uniform sampler2D biome_map : source_color, filter_linear, repeat_disable;

// 5 biome reference colors (RGB matters; alpha unused).
uniform vec4 biome_color_dirt   = vec4(0.66, 0.55, 0.32, 1.0);
uniform vec4 biome_color_grass  = vec4(0.62, 0.85, 0.44, 1.0);
uniform vec4 biome_color_water  = vec4(0.19, 0.44, 0.75, 1.0);
uniform vec4 biome_color_path   = vec4(0.78, 0.66, 0.47, 1.0);
uniform vec4 biome_color_forest = vec4(0.16, 0.35, 0.16, 1.0);

// 5 tileable albedo textures. Default-bound to a 1px placeholder is
// not available in GLSL; authors MUST set all 5 albedo_* uniforms via
// shader_params or the ground renders black for unset slots. The
// `albedo_dirt` slot is the safe fallback — re-point unused biomes
// at the dirt albedo so the math still works.
uniform sampler2D albedo_dirt   : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_grass  : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_water  : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_path   : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D albedo_forest : source_color, filter_linear_mipmap, repeat_enable;

uniform float plane_size = 80.0;
uniform float uv_tile : hint_range(1.0, 200.0) = 30.0;
uniform float blend_softness : hint_range(0.05, 2.0) = 0.5;

// Per-biome material differentiation. Blended with the same weights
// as albedo so transitions feel natural — wet shore fades into dry
// dirt smoothly, not as a sharp specular line. Defaults chosen for
// physical plausibility: water gets a low roughness + slight
// dielectric metallic so sunlight reflects believably; paths are
// slightly less rough than open dirt (packed by foot traffic);
// grass + forest stay matte.
uniform float roughness_dirt   : hint_range(0.0, 1.0) = 0.92;
uniform float roughness_grass  : hint_range(0.0, 1.0) = 0.95;
uniform float roughness_water  : hint_range(0.0, 1.0) = 0.25;
uniform float roughness_path   : hint_range(0.0, 1.0) = 0.80;
uniform float roughness_forest : hint_range(0.0, 1.0) = 0.90;
uniform float metallic_dirt   : hint_range(0.0, 1.0) = 0.00;
uniform float metallic_grass  : hint_range(0.0, 1.0) = 0.00;
uniform float metallic_water  : hint_range(0.0, 1.0) = 0.05;
uniform float metallic_path   : hint_range(0.0, 1.0) = 0.00;
uniform float metallic_forest : hint_range(0.0, 1.0) = 0.00;

// Water-only animated UV scroll. Two crossed sin/cos waves at
// different rates so the surface never looks like a single repeating
// pattern. Set to 0 to disable ripples (e.g., frozen lakes).
uniform float water_scroll_speed : hint_range(0.0, 1.0) = 0.15;
uniform float water_scroll_amplitude : hint_range(0.0, 0.5) = 0.06;

// World-space position carried from vertex() to fragment(). REQUIRED
// because Godot 4's `VERTEX` in fragment() is view-space — using it
// directly would make the biome regions drift with the camera (the
// "trampled zone follows the player" bug class, empirical case
// 2026-05-18 in the 2-biome shader's history).
varying vec3 v_world_pos;

void vertex() {
    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    // === Biome lookup (world-space) ===
    // Plane center → biome (0.5, 0.5); plane corner → biome (1, 1).
    // Z is flipped because PlaneMesh's UV(0,0) is top-left when
    // viewed from above, but world Z grows southward. Mirrors the
    // 2-biome shader's mapping for consistency.
    vec2 biome_uv = vec2(
        (v_world_pos.x + plane_size * 0.5) / plane_size,
        1.0 - (v_world_pos.z + plane_size * 0.5) / plane_size
    );
    vec3 biome_pixel = texture(biome_map, biome_uv).rgb;

    // === Color-distance to each biome reference ===
    float d_dirt   = distance(biome_pixel, biome_color_dirt.rgb);
    float d_grass  = distance(biome_pixel, biome_color_grass.rgb);
    float d_water  = distance(biome_pixel, biome_color_water.rgb);
    float d_path   = distance(biome_pixel, biome_color_path.rgb);
    float d_forest = distance(biome_pixel, biome_color_forest.rgb);

    // === Tiled albedos ===
    vec2 tex_uv = UV * uv_tile;
    // Water gets an animated UV warp — two crossed scrolls at
    // different rates + spatial offset so adjacent samples shift
    // out of phase (no obvious global pulse). Other biomes use the
    // static UV. Both scrolls multiplied by `water_scroll_amplitude`
    // — set to 0 for frozen / still water.
    vec2 water_uv = tex_uv + vec2(
        sin(TIME * water_scroll_speed + v_world_pos.x * 0.18) * water_scroll_amplitude,
        cos(TIME * water_scroll_speed * 0.73 + v_world_pos.z * 0.18) * water_scroll_amplitude
    );
    vec3 a_dirt   = texture(albedo_dirt,   tex_uv).rgb;
    vec3 a_grass  = texture(albedo_grass,  tex_uv).rgb;
    vec3 a_water  = texture(albedo_water,  water_uv).rgb;
    vec3 a_path   = texture(albedo_path,   tex_uv).rgb;
    vec3 a_forest = texture(albedo_forest, tex_uv).rgb;

    // === Soft-min blend ===
    // Each biome's weight = max(0, blend_softness - distance)^2.
    // Weights sum to >0 even at biome boundaries; ambiguity gives
    // smooth crossfades. Closest biome dominates; the rest fade out
    // smoothly as distance increases.
    float w_dirt   = pow(max(0.001, blend_softness - d_dirt),   2.0);
    float w_grass  = pow(max(0.001, blend_softness - d_grass),  2.0);
    float w_water  = pow(max(0.001, blend_softness - d_water),  2.0);
    float w_path   = pow(max(0.001, blend_softness - d_path),   2.0);
    float w_forest = pow(max(0.001, blend_softness - d_forest), 2.0);
    float wsum = w_dirt + w_grass + w_water + w_path + w_forest;

    ALBEDO = (a_dirt   * w_dirt
            + a_grass  * w_grass
            + a_water  * w_water
            + a_path   * w_path
            + a_forest * w_forest) / wsum;

    // Per-biome material blend — same weights as albedo so the
    // specular response transitions smoothly along biome boundaries.
    ROUGHNESS = (roughness_dirt   * w_dirt
               + roughness_grass  * w_grass
               + roughness_water  * w_water
               + roughness_path   * w_path
               + roughness_forest * w_forest) / wsum;
    METALLIC  = (metallic_dirt    * w_dirt
               + metallic_grass   * w_grass
               + metallic_water   * w_water
               + metallic_path    * w_path
               + metallic_forest  * w_forest) / wsum;
}
