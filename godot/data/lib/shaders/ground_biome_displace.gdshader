// ground_biome_displace.gdshader — multi-biome ground for the
// text-to-world pipeline.
//
// The semantic map is a SPLATMAP (classification), NOT a texture.
// Each fragment samples the splatmap, finds which biome its color
// belongs to (nearest biome_key), and renders that biome's TUNED
// albedo + roughness — blended at boundaries, with subtle noise so
// it doesn't read as flat paint. Vertices displace by the heightmap
// (same as ground_simple_displace).
//
// Water is NOT a biome here — it's a separate transparent plane
// (ADR 0059). A water region in the splatmap still gets a biome
// slot (the riverbed floor color, e.g. wet mud) seen at the
// shoreline + under the transparent water.
//
// Color spaces (important):
//   biome_map is sampled WITHOUT source_color → raw sRGB-encoded
//   values 0..1. biome_key[] must be in the SAME space (semantic
//   hex / 255) so classification distances match. biome_albedo[]
//   is the DISPLAY color and ALBEDO expects LINEAR — so the caller
//   pre-converts the tuned colors sRGB→linear before passing them.
//
// Uniforms (set via scene.json ground.mesh.shader_params):
//   biome_map        : the semantic map PNG (splatmap)
//   heightmap        : grayscale elevation
//   biome_count      : how many biome slots are populated (1..8)
//   biome_key[i]     : splatmap key color (sRGB 0..1) for biome i
//   biome_albedo[i]  : tuned display color (LINEAR 0..1) for biome i
//   biome_roughness[i]
//   plane_size / height_scale / height_offset : terrain displacement
//   blend_softness   : color-distance width for edge blending
//   noise_amount     : subtle per-position albedo variation
//
// 2026-05-26 — Yume reuse principle: lib shader. Upgrade path:
// biome_albedo can later be replaced per-biome by a tiled albedo
// TEXTURE (option B) without changing the splatmap classification.

shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_opaque;

uniform sampler2D biome_map : filter_linear, repeat_disable;
uniform sampler2D heightmap : filter_linear, repeat_disable;
uniform float plane_size = 80.0;
uniform float height_scale = 3.0;
uniform float height_offset = -0.5;

const int MAX_BIOMES = 8;
uniform int biome_count = 1;
uniform vec3 biome_key[MAX_BIOMES];
uniform vec3 biome_albedo[MAX_BIOMES];
uniform float biome_roughness[MAX_BIOMES];
uniform float blend_softness : hint_range(0.01, 0.6) = 0.12;
uniform float noise_amount : hint_range(0.0, 0.5) = 0.06;

varying vec3 v_world_pos;

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash21(i + vec2(0.0, 0.0)), hash21(i + vec2(1.0, 0.0)), u.x),
        mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x),
        u.y
    );
}

void vertex() {
    // UV must MATCH the extraction's pixel_to_world (image_y → world_z,
    // NO flip): wz = (cy/H - 0.5)*plane → v = (wz+plane/2)/plane. A
    // 1.0-v flip here mirrors the ground vs the entities (2026-05-26).
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
}

void fragment() {
    // No V flip — matches pixel_to_world (see vertex()).
    vec2 uv = vec2(
        (v_world_pos.x + plane_size * 0.5) / plane_size,
        (v_world_pos.z + plane_size * 0.5) / plane_size
    );
    vec3 splat = texture(biome_map, uv).rgb;

    vec3 albedo = vec3(0.0);
    float rough = 0.0;
    float total = 0.0;
    float best_d = 1e9;
    int best_i = 0;

    for (int i = 0; i < biome_count; i++) {
        float d = distance(splat, biome_key[i]);
        if (d < best_d) { best_d = d; best_i = i; }
        float w = 1.0 - smoothstep(0.0, blend_softness, d);
        albedo += biome_albedo[i] * w;
        rough += biome_roughness[i] * w;
        total += w;
    }

    if (total < 0.001) {
        // No biome within blend range — hard-assign the nearest.
        albedo = biome_albedo[best_i];
        rough = biome_roughness[best_i];
    } else {
        albedo /= total;
        rough /= total;
    }

    // Subtle per-position variation so flat biomes don't read as paint.
    float n = vnoise(v_world_pos.xz * 1.5);
    albedo *= (1.0 - noise_amount * 0.5 + noise_amount * n);

    ALBEDO = albedo;
    ROUGHNESS = clamp(rough, 0.0, 1.0);
    METALLIC = 0.0;
}
