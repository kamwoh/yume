// water_stylized.gdshader — stylized animated water for Yume.
//
// Designed for a BOX mesh (3D water volume), not a flat plane:
//   - Top face = water surface (player above water sees this)
//   - Side/bottom faces = water "walls" + ceiling (player inside the
//     box, i.e. below water_level, sees the world THROUGH these faces
//     with refraction + depth-fade tint → underwater effect for free)
//
// `render_mode cull_disabled` so both sides of every face render. When
// the camera is INSIDE the box, the underside of the top face renders
// as a refracted, tinted view of the world above water — that's the
// natural "underwater" look. No separate post-process needed.
//
// Noise is sampled in WORLD XZ (not mesh UV) so the top face and the
// side faces share one coherent ripple pattern at consistent physical
// scale regardless of box dimensions. This is the manual equivalent of
// Godot StandardMaterial3D's triplanar UV mode.
//
// Stages:
//   1. Discard fragments outside water_mask (river/pond region only).
//   2. Procedural noise normal (two scrolling layers) → specular ripples.
//   3. Refraction: sample SCREEN_TEXTURE with offset by wave normal.
//   4. Depth-through-water: scene depth - this surface depth = how far
//      the camera ray travels through water.
//   5. Depth-based color (Beer's-law fade from shallow to deep).
//   6. Composite refracted scene + water tint by water alpha.
//   7. Shoreline foam at small depth_through values, noise-modulated.
//   8. Fresnel sparkle at glancing angles.
//
// 2026-05-28.

shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, specular_schlick_ggx;

uniform vec4 deep_color : source_color = vec4(0.03, 0.10, 0.20, 1.0);
uniform vec4 shallow_color : source_color = vec4(0.30, 0.62, 0.74, 0.85);
uniform vec4 foam_color : source_color = vec4(0.97, 0.99, 1.0, 1.0);

// Seamless multi-octave noise normal map (FastNoiseLite — see
// res://data/lib/textures/water_normal.tres). Two scrolled samples at
// different scales blended → no visible tiling.
uniform sampler2D water_normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_tile_m : hint_range(0.5, 30.0) = 6.0;
uniform float ripple_strength : hint_range(0.0, 1.5) = 0.85;
uniform vec2 flow_dir = vec2(0.72, 0.32);
uniform float flow_speed : hint_range(0.0, 0.5) = 0.045;

// Tightened for a more 3D look: stronger refraction (more "see through
// water with distortion") + faster depth-fade saturation (clearer
// shallow→deep gradient suggests volume).
uniform float depth_fade_m : hint_range(0.05, 8.0) = 0.45;
uniform float refraction_strength : hint_range(0.0, 0.15) = 0.05;
uniform float fresnel_power : hint_range(0.5, 8.0) = 3.5;

uniform float foam_distance_m : hint_range(0.0, 3.0) = 0.65;
uniform float foam_softness : hint_range(0.01, 1.0) = 0.40;
uniform float foam_animation : hint_range(0.0, 4.0) = 1.8;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex  : hint_depth_texture,  filter_nearest;

uniform sampler2D water_mask : filter_linear, repeat_disable;
uniform bool use_water_mask = false;
uniform float plane_size = 80.0;

varying vec3 v_world_pos;
varying vec3 v_world_normal;

void vertex() {
    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    // World-space normal so the fragment can tell top face from sides
    // (used for refraction direction + fresnel reference axis).
    v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

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

// Sample the seamless multi-octave noise normal map TWICE — at two
// scales, scrolling in different directions — and blend. Two layers
// give an FBM-like richness that hides any tiling of the base texture.
// Output is 0..1-encoded (NORMAL_MAP convention).
vec3 sample_water_normal(vec2 world_xz, float t) {
    vec2 uv1 = world_xz / max(normal_tile_m, 0.001) + flow_dir * t;
    vec2 uv2 = world_xz / max(normal_tile_m * 0.5, 0.001)
               - flow_dir.yx * t * 0.6;
    vec3 n1 = texture(water_normal_tex, uv1).xyz;
    vec3 n2 = texture(water_normal_tex, uv2).xyz;
    // Average the two layers (close enough in 0..1 normal-map space).
    return mix(n1, n2, 0.5);
}

void fragment() {
    // World-XZ mask discard. Works on any face of the box (top face
    // outside the river region disappears; sides + bottom outside the
    // mask region likewise — the visible water silhouette in world is
    // exactly the mask region, no matter which face you look at).
    if (use_water_mask) {
        vec2 muv = vec2(
            (v_world_pos.x + plane_size * 0.5) / plane_size,
            (v_world_pos.z + plane_size * 0.5) / plane_size
        );
        if (texture(water_mask, muv).r < 0.5) {
            discard;
        }
    }

    float t = TIME * flow_speed;
    vec3 wnorm01 = sample_water_normal(v_world_pos.xz, t);
    NORMAL_MAP = wnorm01;
    NORMAL_MAP_DEPTH = ripple_strength;
    vec3 wnorm = wnorm01 * 2.0 - 1.0;

    // UNDERWATER PATH: when the camera is INSIDE the box (below
    // water_level), it sees the back side of the box's faces. Godot's
    // FRONT_FACING is `false` for back-faces. Use that to switch to a
    // dedicated underwater look: heavy deep_color tint + slight
    // refraction of the world above, no foam, no specular sparkle.
    // This is what gives "I'm submerged" — pure shader, no overlay.
    // UNDERWATER vs ABOVE-WATER branch via Godot's FRONT_FACING
    // built-in. Godot fragment shaders can't `return`, so we build
    // both paths and pick at the end.
    vec2 refr_uv = SCREEN_UV + wnorm.xy * refraction_strength;
    vec3 refracted = textureLod(screen_tex, refr_uv, 0.0).rgb;

    // Depth-through-water: how far the camera ray travels through water
    // before hitting the geometry behind. Bigger = deeper-looking.
    float scene_depth_raw = textureLod(depth_tex, refr_uv, 0.0).r;
    vec3 ndc_scene = vec3(refr_uv * 2.0 - 1.0, scene_depth_raw);
    vec4 view_scene = INV_PROJECTION_MATRIX * vec4(ndc_scene, 1.0);
    view_scene.xyz /= view_scene.w;
    float scene_view_z = -view_scene.z;
    float surface_view_z = -VERTEX.z;
    float depth_through_m = max(scene_view_z - surface_view_z, 0.0);

    // Depth-based water tint (Beer's-law-ish).
    float depth_t = 1.0 - exp(-depth_through_m / max(depth_fade_m, 0.001));
    vec3 water_color = mix(shallow_color.rgb, deep_color.rgb, depth_t);
    float water_alpha = mix(shallow_color.a, deep_color.a, depth_t);
    vec3 final_rgb = mix(refracted, water_color, water_alpha);

    // Shoreline foam — only on near-horizontal surfaces (top face).
    // Side faces don't need foam (they're the underwater walls).
    float top_face = clamp(v_world_normal.y, 0.0, 1.0);  // 1 on top, 0 on sides
    float foam_mask = (1.0 - smoothstep(
        foam_distance_m * (1.0 - foam_softness),
        foam_distance_m,
        depth_through_m)) * top_face;
    float foam_ripple = noise2d(v_world_pos.xz / max(normal_tile_m * 0.42, 0.001)
                                + t * foam_animation);
    foam_mask *= smoothstep(0.35, 0.75, foam_ripple);
    final_rgb = mix(final_rgb, foam_color.rgb, foam_mask);

    // Fresnel against the world-up axis (foam-bearing surface) so the
    // sparkle is on the water surface as seen from above. Inside the
    // box looking at side faces, fresnel is just a soft tint.
    vec3 view_dir = normalize(-VERTEX);
    float ndotv = max(dot(view_dir, vec3(0.0, 0.0, 1.0)), 0.0);
    float fresnel = pow(1.0 - ndotv, fresnel_power);

    // UNDERWATER look: refract the world above with a wider offset
    // (gentler distortion), tint heavily toward deep_color so it reads
    // as murky underwater. Use EMISSION too so the colour doesn't get
    // washed by ambient light / atmosphere.
    vec2 under_uv = SCREEN_UV + wnorm.xy * refraction_strength * 0.6;
    vec3 above_view = textureLod(screen_tex, under_uv, 0.0).rgb;
    vec3 under_rgb = mix(above_view, deep_color.rgb, 0.85);

    if (FRONT_FACING) {
        ALBEDO    = final_rgb;
        ALPHA     = 1.0;
        METALLIC  = 0.10 + fresnel * 0.40 * top_face;
        ROUGHNESS = mix(0.30, 0.08, fresnel * top_face);
        SPECULAR  = 0.50 + fresnel * 0.40 * top_face;
    } else {
        // The camera is BELOW water_level, looking at a back-face of
        // the box. This IS the underwater view — no need for an
        // overlay or post-process.
        ALBEDO    = vec3(0.0);
        EMISSION  = under_rgb;       // bypass lighting/ambient washing
        ALPHA     = 1.0;
        NORMAL_MAP = vec3(0.5, 0.5, 1.0);
        METALLIC  = 0.0;
        ROUGHNESS = 0.85;
        SPECULAR  = 0.10;
    }
}
