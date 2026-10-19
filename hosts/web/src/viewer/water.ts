// The water surface (scene.json water.mesh, ADR 0059) with the
// water_stylized shader. Mirrors build_water in ground_renderer.gd and
// godot/data/lib/shaders/water_stylized.gdshader: refraction of the scene
// behind the surface, a tint by the depth through the water, foam where
// the water is shallow, a fresnel on the top face, and an underwater look
// on the back faces of a box volume.
//
// Godot reads hint_screen_texture and hint_depth_texture. This host renders
// the opaque scene into a target with a depth texture each frame, with the
// water hidden, and gives both to the water material (Renderer3D).
// water_normal_tex defaults to a seamless noise normal map, as Godot's
// lib/textures/water_normal.tres (FastNoiseLite, 5 octaves, bump 8). The
// noise is not the same, the look is.
import * as THREE from "three";
import { type Dict, isDict } from "../value.ts";
import { colorOf } from "./color.ts";

type TextureLoad = (path: string, srgb: boolean) => THREE.Texture | null;

/** The defaults of water_stylized.gdshader. */
const DEFAULTS: Dict = {
  deep_color: [0.03, 0.1, 0.2, 1.0],
  shallow_color: [0.3, 0.62, 0.74, 0.85],
  foam_color: [0.97, 0.99, 1.0, 1.0],
  normal_tile_m: 6.0,
  ripple_strength: 0.85,
  flow_dir: [0.72, 0.32],
  flow_speed: 0.045,
  depth_fade_m: 0.45,
  refraction_strength: 0.05,
  fresnel_power: 3.5,
  foam_distance_m: 0.65,
  foam_softness: 0.4,
  foam_animation: 1.8,
  use_water_mask: false,
};

/** GroundRenderer.build_water: a plane at `level`, or a box of `box_depth` with its top face at `level`. */
export function buildWater(water: Dict, load: TextureLoad): THREE.Mesh | null {
  const cfg = isDict(water.mesh) ? water.mesh : null;
  if (!cfg) return null;
  if (String(cfg.shader ?? "") !== "water_stylized") {
    console.info(`[water] shader '${String(cfg.shader ?? "")}' is not in this host yet`);
    return null;
  }
  const size = Array.isArray(cfg.size) ? cfg.size.map(Number) : [80, 80];
  const w = size[0] ?? 80;
  const d = size[1] ?? w;
  const level = Number(cfg.level ?? 0);
  const boxDepth = Number(cfg.box_depth ?? 0);
  const geo = boxDepth > 0 ? new THREE.BoxGeometry(w, boxDepth, d) : new THREE.PlaneGeometry(w, d).rotateX(-Math.PI / 2);
  const params = { ...DEFAULTS, ...(isDict(cfg.shader_params) ? cfg.shader_params : {}) };
  const mesh = new THREE.Mesh(geo, waterMaterial(params, Math.max(w, d), load));
  mesh.position.y = boxDepth > 0 ? level - boxDepth / 2 : level;
  mesh.castShadow = false;
  mesh.name = "Water";
  return mesh;
}

function waterMaterial(p: Dict, planeSize: number, load: TextureLoad): THREE.MeshStandardMaterial {
  const vec4 = (v: unknown) => {
    const a = Array.isArray(v) ? v.map(Number) : [1, 1, 1, 1];
    const c = colorOf([a[0], a[1], a[2]]);
    return new THREE.Vector4(c.r, c.g, c.b, a[3] ?? 1);
  };
  const flow = Array.isArray(p.flow_dir) ? p.flow_dir.map(Number) : [0.72, 0.32];
  const mask = typeof p.water_mask === "string" ? load(p.water_mask, false) : null;
  const normalTex = typeof p.water_normal_tex === "string" ? load(p.water_normal_tex, false) : noiseNormalMap();
  const u: Record<string, THREE.IUniform> = {
    TIME: { value: 0 },
    deep_color: { value: vec4(p.deep_color) },
    shallow_color: { value: vec4(p.shallow_color) },
    foam_color: { value: vec4(p.foam_color) },
    water_normal_tex: { value: normalTex },
    normal_tile_m: { value: Number(p.normal_tile_m) },
    ripple_strength: { value: Number(p.ripple_strength) },
    flow_dir: { value: new THREE.Vector2(flow[0], flow[1]) },
    flow_speed: { value: Number(p.flow_speed) },
    depth_fade_m: { value: Number(p.depth_fade_m) },
    refraction_strength: { value: Number(p.refraction_strength) },
    fresnel_power: { value: Number(p.fresnel_power) },
    foam_distance_m: { value: Number(p.foam_distance_m) },
    foam_softness: { value: Number(p.foam_softness) },
    foam_animation: { value: Number(p.foam_animation) },
    water_mask: { value: mask },
    use_water_mask: { value: p.use_water_mask === true && mask !== null },
    plane_size: { value: planeSize },
    screen_tex: { value: null },
    depth_tex: { value: null },
    screenSize: { value: new THREE.Vector2(1, 1) },
    camNear: { value: 0.05 },
    camFar: { value: 4000 },
    camOrtho: { value: false },
  };
  const mat = new THREE.MeshStandardMaterial({ side: THREE.DoubleSide, roughness: 0.3, metalness: 0.1 });
  mat.userData.uniforms = u;
  mat.onBeforeCompile = (sh) => {
    Object.assign(sh.uniforms, u);
    sh.vertexShader = sh.vertexShader
      .replace("#include <common>", "#include <common>\nvarying vec3 vWorldPosW;\nvarying vec3 vWorldNormalW;")
      .replace(
        "#include <worldpos_vertex>",
        "#include <worldpos_vertex>\nvWorldPosW = (modelMatrix * vec4(transformed, 1.0)).xyz;\nvWorldNormalW = normalize(mat3(modelMatrix) * objectNormal);",
      );
    sh.fragmentShader = sh.fragmentShader
      .replace(
        "#include <common>",
        `#include <common>
#include <packing>
varying vec3 vWorldPosW; varying vec3 vWorldNormalW;
uniform float TIME; uniform vec4 deep_color; uniform vec4 shallow_color; uniform vec4 foam_color;
uniform sampler2D water_normal_tex; uniform float normal_tile_m; uniform float ripple_strength;
uniform vec2 flow_dir; uniform float flow_speed; uniform float depth_fade_m; uniform float refraction_strength;
uniform float fresnel_power; uniform float foam_distance_m; uniform float foam_softness; uniform float foam_animation;
uniform sampler2D water_mask; uniform bool use_water_mask; uniform float plane_size;
uniform sampler2D screen_tex; uniform sampler2D depth_tex; uniform vec2 screenSize; uniform float camNear; uniform float camFar; uniform bool camOrtho;
float hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise2d(vec2 p) {
  vec2 i = floor(p); vec2 f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x), mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}
vec3 sample_water_normal(vec2 world_xz, float t) {
  vec2 uv1 = world_xz / max(normal_tile_m, 0.001) + flow_dir * t;
  vec2 uv2 = world_xz / max(normal_tile_m * 0.5, 0.001) - flow_dir.yx * t * 0.6;
  return mix(texture2D(water_normal_tex, uv1).xyz, texture2D(water_normal_tex, uv2).xyz, 0.5);
}
float viewDepthAt(vec2 uv) {
  float d = texture2D(depth_tex, uv).r;
  return camOrtho ? -orthographicDepthToViewZ(d, camNear, camFar) : -perspectiveDepthToViewZ(d, camNear, camFar);
}`,
      )
      .replace(
        "#include <color_fragment>",
        `#include <color_fragment>
if (use_water_mask) {
  vec2 muv = vec2((vWorldPosW.x + plane_size * 0.5) / plane_size, (vWorldPosW.z + plane_size * 0.5) / plane_size);
  if (texture2D(water_mask, muv).r < 0.5) discard;
}
float wt = TIME * flow_speed;
vec3 wnorm01 = sample_water_normal(vWorldPosW.xz, wt);
vec3 wnorm = wnorm01 * 2.0 - 1.0;
vec2 screenUv = gl_FragCoord.xy / screenSize;
vec2 refr_uv = screenUv + wnorm.xy * refraction_strength;
vec3 refracted = texture2D(screen_tex, refr_uv).rgb;
float depth_through_m = max(viewDepthAt(refr_uv) - vViewPosition.z, 0.0);
float depth_t = 1.0 - exp(-depth_through_m / max(depth_fade_m, 0.001));
vec3 water_color = mix(shallow_color.rgb, deep_color.rgb, depth_t);
float water_alpha = mix(shallow_color.a, deep_color.a, depth_t);
vec3 final_rgb = mix(refracted, water_color, water_alpha);
float top_face = clamp(vWorldNormalW.y, 0.0, 1.0);
float foam_mask = (1.0 - smoothstep(foam_distance_m * (1.0 - foam_softness), foam_distance_m, depth_through_m)) * top_face;
float foam_ripple = noise2d(vWorldPosW.xz / max(normal_tile_m * 0.42, 0.001) + wt * foam_animation);
foam_mask *= smoothstep(0.35, 0.75, foam_ripple);
final_rgb = mix(final_rgb, foam_color.rgb, foam_mask);
float ndotv = max(dot(normalize(vViewPosition), vec3(0.0, 0.0, 1.0)), 0.0);
float fresnel = pow(1.0 - ndotv, fresnel_power);
vec3 above_view = texture2D(screen_tex, screenUv + wnorm.xy * refraction_strength * 0.6).rgb;
vec3 under_rgb = mix(above_view, deep_color.rgb, 0.85);
float waterMetal = gl_FrontFacing ? 0.10 + fresnel * 0.40 * top_face : 0.0;
float waterRough = gl_FrontFacing ? mix(0.30, 0.08, fresnel * top_face) : 0.85;
diffuseColor.rgb = gl_FrontFacing ? final_rgb : vec3(0.0);`,
      )
      .replace("#include <roughnessmap_fragment>", "#include <roughnessmap_fragment>\nroughnessFactor = waterRough;")
      .replace("#include <metalnessmap_fragment>", "#include <metalnessmap_fragment>\nmetalnessFactor = waterMetal;")
      .replace(
        "#include <normal_fragment_maps>",
        `#include <normal_fragment_maps>
if (gl_FrontFacing) {
  // NORMAL_MAP with NORMAL_MAP_DEPTH = ripple_strength, in the plane's tangent frame (x, z, up).
  vec3 mapN = wnorm;
  mapN.xy *= ripple_strength;
  vec3 nw = normalize(vec3(1.0, 0.0, 0.0) * mapN.x + vec3(0.0, 0.0, 1.0) * mapN.y + vec3(0.0, 1.0, 0.0) * mapN.z);
  if (vWorldNormalW.y > 0.5) normal = normalize((viewMatrix * vec4(nw, 0.0)).xyz);
}`,
      )
      .replace("#include <emissivemap_fragment>", "#include <emissivemap_fragment>\nif (!gl_FrontFacing) totalEmissiveRadiance = under_rgb;");
  };
  return mat;
}

let noiseTex: THREE.DataTexture | null = null;

/** A seamless fBm noise as a normal map: 256 × 256, 5 octaves, bump 8. */
function noiseNormalMap(): THREE.DataTexture {
  if (noiseTex) return noiseTex;
  const n = 256;
  const h = new Float32Array(n * n);
  // Tileable value noise: the lattice wraps at the period of each octave.
  const lattice = (period: number, seed: number) => {
    const g = new Float32Array(period * period);
    let s = seed;
    for (let i = 0; i < g.length; i++) {
      s = (s * 1664525 + 1013904223) >>> 0;
      g[i] = s / 4294967296;
    }
    return g;
  };
  let amp = 1;
  for (let o = 0, period = 8; o < 5; o++, period *= 2, amp *= 0.5) {
    const g = lattice(period, 7 + o * 101);
    for (let y = 0; y < n; y++) {
      for (let x = 0; x < n; x++) {
        const fx = (x / n) * period;
        const fy = (y / n) * period;
        const x0 = Math.floor(fx), y0 = Math.floor(fy);
        const tx = fx - x0, ty = fy - y0;
        const sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty);
        const at = (i: number, j: number) => g[((j % period) * period) + (i % period)];
        const v = (at(x0, y0) * (1 - sx) + at(x0 + 1, y0) * sx) * (1 - sy) + (at(x0, y0 + 1) * (1 - sx) + at(x0 + 1, y0 + 1) * sx) * sy;
        h[y * n + x] += v * amp;
      }
    }
  }
  const data = new Uint8Array(n * n * 4);
  const bump = 8;
  for (let y = 0; y < n; y++) {
    for (let x = 0; x < n; x++) {
      const dx = (h[y * n + ((x + 1) % n)] - h[y * n + ((x + n - 1) % n)]) * bump;
      const dy = (h[((y + 1) % n) * n + x] - h[((y + n - 1) % n) * n + x]) * bump;
      const v = new THREE.Vector3(-dx, -dy, 1).normalize();
      const i = (y * n + x) * 4;
      data[i] = (v.x * 0.5 + 0.5) * 255;
      data[i + 1] = (v.y * 0.5 + 0.5) * 255;
      data[i + 2] = (v.z * 0.5 + 0.5) * 255;
      data[i + 3] = 255;
    }
  }
  noiseTex = new THREE.DataTexture(data, n, n);
  noiseTex.wrapS = noiseTex.wrapT = THREE.RepeatWrapping;
  noiseTex.magFilter = THREE.LinearFilter;
  noiseTex.minFilter = THREE.LinearMipmapLinearFilter;
  noiseTex.generateMipmaps = true;
  noiseTex.needsUpdate = true;
  return noiseTex;
}
