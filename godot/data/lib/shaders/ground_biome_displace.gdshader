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

// --- Grass detail texture + cheap wind (fragment-only, no geometry) ---
// Applied ONLY where the grass biome is weighted (grass_biome_index), so
// non-grass scenes / non-grass ground is untouched. The "wind" is a
// TIME-driven gust band drifting across the field + a slow detail-UV
// flow — a handful of ALU ops per pixel, scales with screen pixels not
// blade count. NO per-blade simulation. grass_detail is a tiling
// grayscale breakup map multiplied into the grass albedo.
uniform sampler2D grass_detail : filter_linear, repeat_enable, hint_default_white;
uniform int grass_biome_index = -1;                       // -1 = no grass
uniform float detail_tile = 24.0;                          // tiles across plane
uniform float detail_strength : hint_range(0.0, 1.0) = 0.30;
uniform vec2 wind_dir = vec2(0.7, 0.7);
uniform float wind_speed = 0.9;
uniform float wind_gust_freq = 0.08;                       // gust-band spacing
uniform float wind_gust_strength : hint_range(0.0, 0.3) = 0.11;
uniform float wind_flow = 0.035;                           // detail-UV drift

// Painterly grass shading — sunlit crowns brighter + warmer, dips/creases
// darker + cooler (the hero-reference "velvet lawn" look comes from this
// form-shading, not from blades).
uniform float crown_lift : hint_range(0.0, 0.4) = 0.16;    // hilltop brighten
uniform float crease_darken : hint_range(0.0, 0.5) = 0.22; // slope/dip darken
uniform vec3 crown_warm : source_color = vec3(1.08, 1.04, 0.84);

varying vec3 v_world_pos;
varying vec3 v_world_normal;

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
    // The ground plane is axis-aligned + unrotated, so the analytic NORMAL
    // is already world-space. Pass it for slope-based fragment shading
    // (fragment NORMAL is VIEW-space and can't tell us world-up).
    v_world_normal = NORMAL;
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
    float grass_w = 0.0;   // accumulated weight of the grass biome slot

    for (int i = 0; i < biome_count; i++) {
        float d = distance(splat, biome_key[i]);
        if (d < best_d) { best_d = d; best_i = i; }
        float w = 1.0 - smoothstep(0.0, blend_softness, d);
        albedo += biome_albedo[i] * w;
        rough += biome_roughness[i] * w;
        total += w;
        if (i == grass_biome_index) { grass_w = w; }
    }

    if (total < 0.001) {
        // No biome within blend range — hard-assign the nearest.
        albedo = biome_albedo[best_i];
        rough = biome_roughness[best_i];
        grass_w = (best_i == grass_biome_index) ? 1.0 : 0.0;
    } else {
        albedo /= total;
        rough /= total;
        grass_w /= total;
    }

    // Subtle per-position variation so flat biomes don't read as paint.
    float n = vnoise(v_world_pos.xz * 1.5);
    albedo *= (1.0 - noise_amount * 0.5 + noise_amount * n);

    // Painterly form-shading on grass: sunlit crowns lift + warm, dips and
    // slopes darken. This (not blades) is where the hero reference's lush
    // 3D grass feel comes from. height01 ≈ where this point sits in the
    // terrain's displacement range; up01 = how flat/up-facing it is.
    if (grass_biome_index >= 0 && grass_w > 0.001) {
        float height01 = clamp(0.5 + v_world_pos.y / (height_scale + 0.001), 0.0, 1.0);
        float up01 = clamp(v_world_normal.y, 0.0, 1.0);
        // Crowns (high + flat) brighten toward warm; dips/steep darken.
        albedo *= mix(1.0, 1.0 + crown_lift, height01 * up01 * grass_w);
        albedo = mix(albedo, albedo * crown_warm, height01 * up01 * grass_w);
        albedo *= mix(1.0, 1.0 - crease_darken, (1.0 - height01) * grass_w);
        albedo *= mix(1.0, 1.0 - crease_darken * 0.7, (1.0 - up01) * grass_w);
    }

    // Grass detail + wind — only where grass is weighted (free elsewhere).
    if (grass_biome_index >= 0 && grass_w > 0.001) {
        vec2 flow = wind_flow * vec2(sin(TIME * 0.3), cos(TIME * 0.23));
        vec2 duv = v_world_pos.xz / plane_size * detail_tile + flow;
        // TWO octaves (second scaled + rotated) so the detail map's single
        // repeat doesn't show as a tiling grid of squares across the field.
        mat2 rot = mat2(vec2(0.80, 0.60), vec2(-0.60, 0.80));
        float d1 = texture(grass_detail, duv).r;
        float d2 = texture(grass_detail, rot * duv * 2.37).r;
        float detail = d1 * 0.6 + d2 * 0.4;                 // 0..1, no grid
        // The detail map is low-contrast grey, so amplify around its mid
        // before applying — otherwise the grass reads as flat paint.
        float dv = clamp((detail - 0.5) * 4.0, -1.0, 1.0);
        albedo *= 1.0 + dv * detail_strength * grass_w;

        // Gust band: a sinusoidal brightness wave sweeping along wind_dir.
        // This drifting light/dark band is the main "wind over grass" cue.
        float gust = sin(dot(v_world_pos.xz, normalize(wind_dir)) * wind_gust_freq
                         - TIME * wind_speed);
        albedo *= 1.0 + gust * wind_gust_strength * grass_w;
    }

    ALBEDO = albedo;
    ROUGHNESS = clamp(rough, 0.0, 1.0);
    METALLIC = 0.0;
}
