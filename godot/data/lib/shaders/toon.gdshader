// toon.gdshader — stylized cel/toon shading (ADR 0052 visual.shader).
//
// Bands the directional diffuse into N steps + adds a fresnel rim light,
// while KEEPING the surface's real albedo (texture × color). Works in
// gl_compatibility. The renderer copies the source material's albedo
// into albedo_texture / albedo_color, so this re-styles any mesh —
// code-draw prims AND imported .glb (e.g. Infinigen) — without losing
// its texture.
//
// Uniforms (set via visual.shader_params, or auto-filled from the source
// material's albedo by EntityMesh3D._paint_shader_recursive):
//   albedo_color    : RGBA tint (multiplies the texture)
//   albedo_texture  : base color map (white default = flat color)
//   bands           : 2..6 diffuse light steps (lower = more graphic)
//   rim_color       : fresnel edge-light color
//   rim_power       : 0.5..8 — higher = tighter rim
//   rim_strength    : 0..1 — rim intensity
shader_type spatial;
render_mode cull_back, specular_disabled;

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white;
uniform int bands : hint_range(2, 6) = 3;
uniform vec4 rim_color : source_color = vec4(1.0);
uniform float rim_power : hint_range(0.5, 8.0) = 3.0;
uniform float rim_strength : hint_range(0.0, 1.0) = 0.35;
// Shadow fill: a custom light() does NOT receive the Environment ambient in
// gl_compatibility, so the shadow band would crush to black. This is the
// stylized shadow COLOR (cool tint), supplied by the shader itself.
uniform vec4 fill_color : source_color = vec4(0.5, 0.55, 0.65, 1.0);
uniform float fill_strength : hint_range(0.0, 1.5) = 0.7;

void fragment() {
	ALBEDO = albedo_color.rgb * texture(albedo_texture, UV).rgb;
	// Self-supplied ambient/shadow fill (the "shadow tone" of a cel look).
	AMBIENT_LIGHT = ALBEDO * fill_color.rgb * fill_strength;
	// Fresnel rim — bright at grazing angles, the stylized edge glow.
	float fres = 1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	EMISSION = rim_color.rgb * pow(fres, rim_power) * rim_strength;
}

void light() {
	// Quantize the lambert term into hard bands — the cel look. Adds ON TOP
	// of the fill, so lit faces brighten in steps and shadows keep fill_color.
	float ndl = clamp(dot(normalize(NORMAL), normalize(LIGHT)), 0.0, 1.0);
	float stepped = floor(ndl * float(bands) + 0.5) / float(bands);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION * stepped;
}
