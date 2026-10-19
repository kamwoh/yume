// Grass blades and flowers on the ground (scene.json ground.grass_blades
// and ground.flowers). Mirrors grass_renderer.gd: points scatter in a disc,
// keep only those on the grass biome of the splat map, and sit on the
// displaced ground (sample_y). One instanced mesh draws each layer.
//
// The scatter uses its own seeded generator (presentation only, not the
// sim's). Godot's RandomNumberGenerator is a different algorithm, so the
// points are not the same ones as in the reference. Their density is.
import * as THREE from "three";
import type { GroundHeight } from "../heightmap.ts";
import { SpecRandom } from "../random.ts";
import { type Dict, isDict } from "../value.ts";
import { colorOf } from "./color.ts";

/** A decoded image: RGBA bytes, row by row from the top. */
export type Rgba = { width: number; height: number; data: Uint8ClampedArray };

/** GrassRenderer.build: the blade and flower layers of a ground block, or [] when it has no grass biome. */
export function buildGrass(ground: Dict, biome: Rgba | null, height: GroundHeight | null): THREE.Object3D[] {
  const mesh = isDict(ground.mesh) ? ground.mesh : {};
  const sp = isDict(mesh.shader_params) ? mesh.shader_params : {};
  const size = Array.isArray(mesh.size) ? mesh.size.map(Number) : [80, 80];
  const plane = Number(sp.plane_size ?? Math.max(size[0] ?? 80, size[1] ?? size[0] ?? 80));
  const grassIdx = Math.trunc(Number(sp.grass_biome_index ?? -1));
  if (grassIdx < 0) return [];
  const keys = Array.isArray(sp.biome_key) ? sp.biome_key : [];
  const k = keys[grassIdx];
  const key = Array.isArray(k) && k.length >= 3 ? k.map(Number) : [0.627, 0.847, 0.282];
  const out: THREE.Object3D[] = [];
  const blades = ground.grass_blades;
  if (isDict(blades) && blades.enabled === true) out.push(buildBlades(blades, plane, biome, key, height));
  const flowers = ground.flowers;
  if (isDict(flowers) && flowers.enabled === true) out.push(buildFlowers(flowers, plane, biome, key, height));
  return out;
}

/** GrassRenderer._scatter_points: at most `count` points from 3 × count tries. */
function scatter(count: number, radius: number, biome: Rgba | null, plane: number, key: number[], rng: SpecRandom, height: GroundHeight | null): THREE.Vector3[] {
  const pts: THREE.Vector3[] = [];
  for (let i = 0; i < count * 3 && pts.length < count; i++) {
    const ang = rng.randf() * Math.PI * 2;
    const r = Math.sqrt(rng.randf()) * radius;
    const x = Math.cos(ang) * r;
    const z = Math.sin(ang) * r;
    if (biome && !isGrass(x, z, biome, plane, key)) continue;
    pts.push(new THREE.Vector3(x, height ? height.sampleY(x, z) : 0, z));
  }
  return pts;
}

/** GrassRenderer._is_grass: the splat pixel is within 0.25 of the grass key (no V flip). */
function isGrass(x: number, z: number, img: Rgba, plane: number, key: number[]): boolean {
  const u = Math.min(Math.max((x + plane * 0.5) / plane, 0), 1);
  const v = Math.min(Math.max((z + plane * 0.5) / plane, 0), 1);
  const i = (Math.trunc(v * (img.height - 1)) * img.width + Math.trunc(u * (img.width - 1))) * 4;
  return Math.hypot(img.data[i] / 255 - key[0], img.data[i + 1] / 255 - key[1], img.data[i + 2] / 255 - key[2]) < 0.25;
}

function buildBlades(cfg: Dict, plane: number, biome: Rgba | null, key: number[], height: GroundHeight | null): THREE.Object3D {
  const rng = new SpecRandom(Math.trunc(Number(cfg.seed ?? 7)));
  const w = Number(cfg.blade_w ?? 0.09);
  const h = Number(cfg.blade_h ?? 0.55);
  const jitter = Number(cfg.scale_jitter ?? 0.4);
  const pts = scatter(Math.trunc(Number(cfg.count ?? 25000)), Number(cfg.radius ?? plane * 0.45), biome, plane, key, rng, height);
  // GrassRenderer._blade_mesh: a tapered card standing in +Y. uv.y is the height ratio.
  const geo = new THREE.BufferGeometry();
  const v = [[-w * 0.5, 0, 0], [w * 0.5, 0, 0], [-w * 0.35, h * 0.55, 0], [w * 0.35, h * 0.55, 0], [0, h, 0]];
  const uv = [[0, 0], [1, 0], [0, 0.55], [1, 0.55], [0.5, 1]];
  const tris = [0, 2, 1, 1, 2, 3, 2, 4, 3];
  geo.setAttribute("position", new THREE.Float32BufferAttribute(tris.flatMap((i) => v[i]), 3));
  geo.setAttribute("uv", new THREE.Float32BufferAttribute(tris.flatMap((i) => uv[i]), 2));
  geo.setAttribute("normal", new THREE.Float32BufferAttribute(tris.flatMap(() => [0, 0, 1]), 3));
  const mat = bladeMaterial();
  const im = new THREE.InstancedMesh(geo, mat, Math.max(pts.length, 1));
  im.count = pts.length;
  const m = new THREE.Matrix4();
  pts.forEach((p, i) => {
    const s = 1 + (rng.randf() * 2 - 1) * jitter;
    const sy = s * (1 + (rng.randf() * 2 - 1) * jitter);
    m.compose(p, new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 1, 0), rng.randf() * Math.PI * 2), new THREE.Vector3(s, sy, s));
    im.setMatrixAt(i, m);
  });
  im.name = "GrassBlades";
  im.receiveShadow = true;
  return im;
}

/** grass_blade.gdshader: base to tip color, and a wind sway that grows with the square of the height. */
function bladeMaterial(): THREE.MeshStandardMaterial {
  const mat = new THREE.MeshStandardMaterial({ roughness: 0.92, metalness: 0, side: THREE.DoubleSide });
  const u = {
    TIME: { value: 0 },
    base_color: { value: colorOf([0.16, 0.4, 0.11]) },
    tip_color: { value: colorOf([0.5, 0.74, 0.32]) },
    sway_strength: { value: 0.18 },
    sway_speed: { value: 1.6 },
    sway_scale: { value: 0.25 },
    wind_dir: { value: new THREE.Vector2(0.7, 0.7) },
  };
  mat.userData.uniforms = u;
  mat.onBeforeCompile = (sh) => {
    Object.assign(sh.uniforms, u);
    sh.vertexShader = sh.vertexShader
      .replace("#include <common>", "#include <common>\nuniform float TIME; uniform float sway_strength; uniform float sway_speed; uniform float sway_scale; uniform vec2 wind_dir;\nvarying float vH;")
      .replace(
        "#include <begin_vertex>",
        `#include <begin_vertex>
vH = uv.y;
vec3 wpBase = (modelMatrix * instanceMatrix * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
float phase = dot(wpBase.xz, normalize(wind_dir)) * sway_scale;
float bend = sin(TIME * sway_speed + phase) * sway_strength * vH * vH;
transformed.x += bend * wind_dir.x;
transformed.z += bend * wind_dir.y;`,
      );
    sh.fragmentShader = sh.fragmentShader
      .replace("#include <common>", "#include <common>\nuniform vec3 base_color; uniform vec3 tip_color;\nvarying float vH;")
      .replace("#include <color_fragment>", "#include <color_fragment>\ndiffuseColor.rgb = mix(base_color, tip_color, vH);");
  };
  return mat;
}

function buildFlowers(cfg: Dict, plane: number, biome: Rgba | null, key: number[], height: GroundHeight | null): THREE.Object3D {
  const rng = new SpecRandom(Math.trunc(Number(cfg.seed ?? 13)));
  const size = Number(cfg.size ?? 0.14);
  const colors = (Array.isArray(cfg.colors) && cfg.colors.length > 0 ? cfg.colors : ["#f2e25c", "#f6f4ec", "#f0a8c4"]).map((c) => colorOf(c));
  const pts = scatter(Math.trunc(Number(cfg.count ?? 1800)), Number(cfg.radius ?? plane * 0.45), biome, plane, key, rng, height);
  // GrassRenderer._flower_mesh: two upright quads in a cross, base at y 0.
  const w = size;
  const h = size * 1.1;
  const quads = [
    [[-w / 2, 0, 0], [w / 2, 0, 0], [w / 2, h, 0], [-w / 2, h, 0]],
    [[0, 0, -w / 2], [0, 0, w / 2], [0, h, w / 2], [0, h, -w / 2]],
  ];
  const pos = quads.flatMap((q) => [0, 1, 2, 0, 2, 3].flatMap((i) => q[i]));
  const geo = new THREE.BufferGeometry();
  geo.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3));
  geo.setAttribute("normal", new THREE.Float32BufferAttribute(pos.map((_, i) => (i % 3 === 1 ? 1 : 0)), 3));
  // A touch of emission so the specks show against shadowed grass (emission 0.18).
  const mat = new THREE.MeshStandardMaterial({ roughness: 0.85, side: THREE.DoubleSide, emissive: 0xffffff, emissiveIntensity: 0.18 });
  const im = new THREE.InstancedMesh(geo, mat, Math.max(pts.length, 1));
  im.count = pts.length;
  const m = new THREE.Matrix4();
  pts.forEach((p, i) => {
    const s = 1 + (rng.randf() * 2 - 1) * 0.3;
    m.compose(p, new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 1, 0), rng.randf() * Math.PI * 2), new THREE.Vector3(s, s, s));
    im.setMatrixAt(i, m);
    im.setColorAt(i, colors[Math.floor(rng.randf() * colors.length) % colors.length]);
  });
  im.name = "Flowers";
  return im;
}
