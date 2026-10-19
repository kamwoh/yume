// The library shaders (ADR 0089) in three.js. The GLSL follows the Godot
// files in godot/data/lib/shaders line for line:
//   sky_clouds             a sky dome: gradient, fBm clouds, mountains
//   ground_biome_displace  biome splat colors, crown and crease shading,
//                          grass detail and wind gusts
//   ground_ortho_displace  one painted albedo with crown and crease shading
// A ground shader patches MeshStandardMaterial, so the ground keeps the
// same lighting as every other mesh. Its vertex displacement is on the
// CPU (heightmap.ts sample_y, the twin of the shader's vertex()).
//
// A `source_color` color uniform is sRGB, so the host turns it to linear.
// A `source_color` sampler reads raw, as in the reference's gl_compatibility
// renderer (see shader_dag.ts). TIME is seconds since the page started.
//
// Not in this host yet: water_stylized (it reads the screen and depth
// textures) and toon.
import * as THREE from "three";
import type { Dict } from "../value.ts";
import { colorOf } from "./color.ts";

const NOISE = `
float hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise2d(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x), mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}`;

/** sky_clouds.gdshader: the default of each uniform. */
const SKY_DEFAULTS: Dict = {
  sky_top_color: [0.35, 0.55, 0.85],
  sky_horizon_color: [0.7, 0.82, 0.92],
  cloud_color: [0.95, 0.95, 0.92],
  cloud_shadow_color: [0.55, 0.6, 0.65],
  cloud_coverage: 0.45,
  cloud_softness: 0.4,
  cloud_speed: 0.012,
  cloud_scale: 5.0,
  mountain_enabled: 0.0,
  mountain_base_color: [0.4, 0.48, 0.62],
  mountain_peak_color: [0.7, 0.74, 0.8],
  mountain_height: 0.15,
  mountain_jaggedness: 8.0,
};
const SKY_COLORS = ["sky_top_color", "sky_horizon_color", "cloud_color", "cloud_shadow_color", "mountain_base_color", "mountain_peak_color"];

/** The sky_clouds material. The lighting director sets the four day/night colors each frame (setColor). */
export function skyCloudsMaterial(params: Dict): THREE.ShaderMaterial {
  const uniforms: Record<string, THREE.IUniform> = { TIME: { value: 0 } };
  for (const k of Object.keys(SKY_DEFAULTS)) {
    const v = k in params ? params[k] : SKY_DEFAULTS[k];
    uniforms[k] = { value: SKY_COLORS.includes(k) ? colorOf(v) : Number(v) };
  }
  return new THREE.ShaderMaterial({
    side: THREE.BackSide,
    depthWrite: false,
    fog: false,
    uniforms,
    vertexShader: `varying vec3 vDir;
void main() {
  vDir = normalize(position);
  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
}`,
    fragmentShader: `uniform float TIME;
uniform vec3 sky_top_color; uniform vec3 sky_horizon_color; uniform vec3 cloud_color; uniform vec3 cloud_shadow_color;
uniform float cloud_coverage; uniform float cloud_softness; uniform float cloud_speed; uniform float cloud_scale;
uniform float mountain_enabled; uniform vec3 mountain_base_color; uniform vec3 mountain_peak_color;
uniform float mountain_height; uniform float mountain_jaggedness;
varying vec3 vDir;
${NOISE}
float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.55;
  for (int i = 0; i < 5; i++) { v += a * noise2d(p); p *= 2.05; a *= 0.5; }
  return v;
}
void main() {
  vec3 dir = normalize(vDir);
  float t_v = smoothstep(0.0, 0.7, dir.y);
  vec3 base_sky = mix(sky_horizon_color, sky_top_color, t_v);
  float horizon_fade = smoothstep(-0.02, 0.20, dir.y);
  vec2 cloud_uv = dir.xz / max(dir.y, 0.05) * cloud_scale * 0.05;
  cloud_uv += vec2(TIME * cloud_speed, TIME * cloud_speed * 0.4);
  float n = fbm(cloud_uv);
  float lo = 1.0 - cloud_coverage - cloud_softness * 0.5;
  float hi = 1.0 - cloud_coverage + cloud_softness * 0.5;
  float cloud_mask = smoothstep(lo, hi, n) * horizon_fade;
  float shade = fbm(cloud_uv + vec2(0.13, 0.21));
  vec3 cloud_lit = mix(cloud_shadow_color, cloud_color, smoothstep(0.25, 0.65, shade));
  vec3 color = mix(base_sky, cloud_lit, cloud_mask);
  if (mountain_enabled > 0.5) {
    float angle = atan(dir.x, dir.z) / 6.28318 + 0.5;
    vec2 m1 = vec2(angle * mountain_jaggedness, 0.5);
    vec2 m2 = vec2(angle * mountain_jaggedness * 2.5, 1.5);
    float h = (fbm(m1) * 0.65 + fbm(m2) * 0.35) * mountain_height;
    float mtn_mask = 1.0 - smoothstep(h - 0.005, h + 0.005, dir.y);
    mtn_mask *= smoothstep(-0.03, 0.0, dir.y);
    float peak_factor = clamp(dir.y / max(h, 0.001), 0.0, 1.0);
    float texture_var = fbm(vec2(angle * mountain_jaggedness * 3.0, dir.y * 4.0 + 2.0));
    vec3 mtn_color = mix(mountain_base_color, mountain_peak_color, peak_factor * 0.6 + texture_var * 0.4);
    color = mix(color, mtn_color, mtn_mask);
  }
  gl_FragColor = vec4(color, 1.0);
  #include <colorspace_fragment>
}`,
  });
}

type TextureLoad = (path: string, srgb: boolean) => THREE.Texture | null;

/**
 * A ground shader on a MeshStandardMaterial. The patch computes the albedo
 * and the roughness per pixel. `load` gives the textures of the shader params.
 */
export function groundMaterial(shader: string, params: Dict, planeSize: number, load: TextureLoad): THREE.MeshStandardMaterial | null {
  if (shader !== "ground_biome_displace" && shader !== "ground_ortho_displace") return null;
  const num = (k: string, d: number) => (k in params ? Number(params[k]) : d);
  const mat = new THREE.MeshStandardMaterial({ roughness: 0.9, metalness: 0 });
  const u: Record<string, THREE.IUniform> = {
    TIME: { value: 0 },
    plane_size: { value: planeSize },
    height_scale: { value: num("height_scale", 3) },
  };
  let decl = "";
  let body = "";
  if (shader === "ground_ortho_displace") {
    // source_color, but read raw: the reference renderer (gl_compatibility) does so in a custom shader (shader_dag.ts).
    u.ortho_albedo = { value: load(String(params.ortho_albedo ?? ""), false) };
    u.crown_lift = { value: num("crown_lift", 0.06) };
    u.crease_darken = { value: num("crease_darken", 0.1) };
    u.albedo_attenuate = { value: num("albedo_attenuate", 0.55) };
    decl = `uniform sampler2D ortho_albedo; uniform float crown_lift; uniform float crease_darken; uniform float albedo_attenuate;`;
    body = `
  vec2 guv = vec2((vWorldPosG.x + plane_size * 0.5) / plane_size, (vWorldPosG.z + plane_size * 0.5) / plane_size);
  vec3 albedo = texture2D(ortho_albedo, clamp(guv, 0.0, 1.0)).rgb * albedo_attenuate;
  float height01 = clamp(0.5 + vWorldPosG.y / (height_scale + 0.001), 0.0, 1.0);
  float up01 = clamp(vNormalG.y, 0.0, 1.0);
  albedo *= mix(1.0, 1.0 + crown_lift, height01 * up01);
  albedo *= mix(1.0, 1.0 - crease_darken, (1.0 - up01));
  diffuseColor.rgb = albedo;
  float groundRough = 0.9;`;
  } else {
    const keys = asVecs(params.biome_key);
    const albs = asVecs(params.biome_albedo);
    const roughs = Array.isArray(params.biome_roughness) ? params.biome_roughness.map(Number) : [];
    const count = Math.min(Math.max(Math.trunc(num("biome_count", 1)), 1), 8);
    const pad = (a: THREE.Vector3[]) => Array.from({ length: 8 }, (_, i) => a[i] ?? new THREE.Vector3());
    u.biome_map = { value: load(String(params.biome_map ?? ""), false) };
    u.grass_detail = { value: load(String(params.grass_detail ?? ""), false) ?? whiteTexture() };
    u.biome_count = { value: count };
    u.biome_key = { value: pad(keys) };
    // biome_albedo has no source_color hint: the values are linear already.
    u.biome_albedo = { value: pad(albs) };
    u.biome_roughness = { value: Array.from({ length: 8 }, (_, i) => roughs[i] ?? 0) };
    u.blend_softness = { value: num("blend_softness", 0.12) };
    u.noise_amount = { value: num("noise_amount", 0.06) };
    u.grass_biome_index = { value: Math.trunc(num("grass_biome_index", -1)) };
    u.detail_tile = { value: num("detail_tile", 24) };
    u.detail_strength = { value: num("detail_strength", 0.3) };
    const wd = Array.isArray(params.wind_dir) ? params.wind_dir.map(Number) : [0.7, 0.7];
    u.wind_dir = { value: new THREE.Vector2(wd[0], wd[1]) };
    u.wind_speed = { value: num("wind_speed", 0.9) };
    u.wind_gust_freq = { value: num("wind_gust_freq", 0.08) };
    u.wind_gust_strength = { value: num("wind_gust_strength", 0.11) };
    u.wind_flow = { value: num("wind_flow", 0.035) };
    u.crown_lift = { value: num("crown_lift", 0.16) };
    u.crease_darken = { value: num("crease_darken", 0.22) };
    u.crown_warm = { value: colorOf(params.crown_warm ?? [1.08, 1.04, 0.84]) };
    decl = `uniform sampler2D biome_map; uniform sampler2D grass_detail; uniform int biome_count;
uniform vec3 biome_key[8]; uniform vec3 biome_albedo[8]; uniform float biome_roughness[8];
uniform float blend_softness; uniform float noise_amount; uniform int grass_biome_index;
uniform float detail_tile; uniform float detail_strength; uniform vec2 wind_dir; uniform float wind_speed;
uniform float wind_gust_freq; uniform float wind_gust_strength; uniform float wind_flow;
uniform float crown_lift; uniform float crease_darken; uniform vec3 crown_warm;
${NOISE}`;
    body = `
  vec2 guv = vec2((vWorldPosG.x + plane_size * 0.5) / plane_size, (vWorldPosG.z + plane_size * 0.5) / plane_size);
  vec3 splat = texture2D(biome_map, clamp(guv, 0.0, 1.0)).rgb;
  vec3 albedo = vec3(0.0);
  float rough = 0.0;
  float total = 0.0;
  float best_d = 1e9;
  int best_i = 0;
  float grass_w = 0.0;
  for (int i = 0; i < 8; i++) {
    if (i >= biome_count) break;
    float d = distance(splat, biome_key[i]);
    if (d < best_d) { best_d = d; best_i = i; }
    float w = 1.0 - smoothstep(0.0, blend_softness, d);
    albedo += biome_albedo[i] * w;
    rough += biome_roughness[i] * w;
    total += w;
    if (i == grass_biome_index) { grass_w = w; }
  }
  if (total < 0.001) {
    for (int i = 0; i < 8; i++) {
      if (i == best_i) { albedo = biome_albedo[i]; rough = biome_roughness[i]; }
    }
    grass_w = (best_i == grass_biome_index) ? 1.0 : 0.0;
  } else {
    albedo /= total;
    rough /= total;
    grass_w /= total;
  }
  float n = noise2d(vWorldPosG.xz * 1.5);
  albedo *= (1.0 - noise_amount * 0.5 + noise_amount * n);
  if (grass_biome_index >= 0 && grass_w > 0.001) {
    float height01 = clamp(0.5 + vWorldPosG.y / (height_scale + 0.001), 0.0, 1.0);
    float up01 = clamp(vNormalG.y, 0.0, 1.0);
    albedo *= mix(1.0, 1.0 + crown_lift, height01 * up01 * grass_w);
    albedo = mix(albedo, albedo * crown_warm, height01 * up01 * grass_w);
    albedo *= mix(1.0, 1.0 - crease_darken, (1.0 - height01) * grass_w);
    albedo *= mix(1.0, 1.0 - crease_darken * 0.7, (1.0 - up01) * grass_w);
    vec2 flow = wind_flow * vec2(sin(TIME * 0.3), cos(TIME * 0.23));
    vec2 duv = vWorldPosG.xz / plane_size * detail_tile + flow;
    mat2 rot = mat2(vec2(0.80, 0.60), vec2(-0.60, 0.80));
    float d1 = texture2D(grass_detail, duv).r;
    float d2 = texture2D(grass_detail, rot * duv * 2.37).r;
    float detail = d1 * 0.6 + d2 * 0.4;
    float dv = clamp((detail - 0.5) * 4.0, -1.0, 1.0);
    albedo *= 1.0 + dv * detail_strength * grass_w;
    float gust = sin(dot(vWorldPosG.xz, normalize(wind_dir)) * wind_gust_freq - TIME * wind_speed);
    albedo *= 1.0 + gust * wind_gust_strength * grass_w;
  }
  diffuseColor.rgb = albedo;
  float groundRough = clamp(rough, 0.0, 1.0);`;
  }
  mat.userData.uniforms = u;
  mat.onBeforeCompile = (sh) => {
    Object.assign(sh.uniforms, u);
    sh.vertexShader = sh.vertexShader
      .replace("#include <common>", "#include <common>\nvarying vec3 vWorldPosG;\nvarying vec3 vNormalG;")
      .replace(
        "#include <worldpos_vertex>",
        "#include <worldpos_vertex>\nvWorldPosG = (modelMatrix * vec4(transformed, 1.0)).xyz;\nvNormalG = normalize(mat3(modelMatrix) * objectNormal);",
      );
    sh.fragmentShader = sh.fragmentShader
      .replace("#include <common>", `#include <common>\nvarying vec3 vWorldPosG;\nvarying vec3 vNormalG;\nuniform float TIME; uniform float plane_size; uniform float height_scale;\n${decl}`)
      .replace("#include <color_fragment>", `#include <color_fragment>\n${body}`)
      .replace("#include <roughnessmap_fragment>", "#include <roughnessmap_fragment>\nroughnessFactor = groundRough;");
  };
  return mat;
}

/** A ground or sky material's TIME uniform, once each frame. */
export function setTime(mat: THREE.Material, t: number): void {
  const u = (mat as THREE.ShaderMaterial).uniforms ?? (mat.userData.uniforms as Record<string, THREE.IUniform> | undefined);
  if (u?.TIME) u.TIME.value = t;
}

function asVecs(v: unknown): THREE.Vector3[] {
  return Array.isArray(v) ? v.filter(Array.isArray).map((a) => new THREE.Vector3(Number(a[0]), Number(a[1]), Number(a[2]))) : [];
}

let white: THREE.DataTexture | null = null;
/** hint_default_white: a missing texture samples as white. */
function whiteTexture(): THREE.DataTexture {
  if (!white) {
    white = new THREE.DataTexture(new Uint8Array([255, 255, 255, 255]), 1, 1);
    white.needsUpdate = true;
  }
  return white;
}

