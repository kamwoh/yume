// sky_clouds.gdshader — stylized procedural sky with animated clouds.
//
// Godot 4 sky-shader: shader_type sky. Runs once per pixel of the
// skybox per frame. EYEDIR is the view ray pointing OUT from the
// camera; we sample noise based on that direction to draw clouds
// only in the upper hemisphere.
//
// No external textures — pure procedural fBM noise. TIME advances
// the cloud UVs so they drift slowly.
//
// Uniforms (set via scene.json::lighting.sky.shader_params):
//   sky_top_color       : RGB — color at zenith
//   sky_horizon_color   : RGB — color at horizon
//   cloud_color         : RGB — lit cloud surface
//   cloud_shadow_color  : RGB — shadowed cloud underside
//   cloud_coverage      : 0..1 — fraction of sky covered (0 clear, 1 overcast)
//   cloud_softness      : 0..1 — soft vs crisp cloud edges
//   cloud_speed         : 0..0.1 — UV drift per second
//   cloud_scale         : 1..20 — frequency of cloud puffs

shader_type sky;
render_mode use_half_res_pass;

uniform vec3 sky_top_color : source_color = vec3(0.35, 0.55, 0.85);
uniform vec3 sky_horizon_color : source_color = vec3(0.70, 0.82, 0.92);
uniform vec3 cloud_color : source_color = vec3(0.95, 0.95, 0.92);
uniform vec3 cloud_shadow_color : source_color = vec3(0.55, 0.60, 0.65);
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.45;
uniform float cloud_softness : hint_range(0.0, 1.0) = 0.40;
uniform float cloud_speed : hint_range(0.0, 0.1) = 0.012;
uniform float cloud_scale : hint_range(1.0, 20.0) = 5.0;

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

// Fractal Brownian motion — sum of noise octaves, gives soft-clumpy
// cloud shapes vs single-octave's plain-noise look.
float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.55;
    for (int i = 0; i < 5; i++) {
        v += a * noise2d(p);
        p *= 2.05;
        a *= 0.5;
    }
    return v;
}

void sky() {
    vec3 dir = normalize(EYEDIR);

    // Base sky gradient: horizon → zenith, smoothed
    float t_v = smoothstep(0.0, 0.7, dir.y);
    vec3 base_sky = mix(sky_horizon_color, sky_top_color, t_v);

    // Cloud rendering: only above horizon. Project view ray onto a
    // notional "cloud plane" — divide horizontal direction by vertical
    // gives a flat-plane projection. As dir.y → 0 (horizon), UVs go
    // to infinity which naturally compresses clouds at the horizon
    // (like real perspective). horizon_fade kills clouds in the lower
    // hemisphere.
    float horizon_fade = smoothstep(-0.02, 0.20, dir.y);
    vec2 cloud_uv = dir.xz / max(dir.y, 0.05) * cloud_scale * 0.05;
    cloud_uv += vec2(TIME * cloud_speed, TIME * cloud_speed * 0.4);

    float n = fbm(cloud_uv);
    // Threshold the noise so only the higher peaks become clouds
    float lo = 1.0 - cloud_coverage - cloud_softness * 0.5;
    float hi = 1.0 - cloud_coverage + cloud_softness * 0.5;
    float cloud_mask = smoothstep(lo, hi, n) * horizon_fade;

    // Cloud self-shading: sample noise gradient + use as a lighting
    // hint. Inverted-noise areas read as the underside.
    float shade = fbm(cloud_uv + vec2(0.13, 0.21));
    vec3 cloud_lit = mix(cloud_shadow_color, cloud_color,
                         smoothstep(0.25, 0.65, shade));

    COLOR = mix(base_sky, cloud_lit, cloud_mask);
}
