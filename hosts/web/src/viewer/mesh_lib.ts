// The code-built mesh library (meshes.json) in three.js. Mirrors mesh_lib.gd:
// the primitive ops, `pos` and `rotation_deg` (Euler order YXZ, as Godot's
// Basis.from_euler), `$param` values, named materials, `cast_shadow` and the
// `pivot` joint of an addressable part.
//
// The CSG ops lathe, extrude and sweep build their own geometry, as a CSG
// group of one part does in the reference. A group with a `csg` subtract
// or intersect is not in this host yet: its parts draw unchanged, with one
// console note.
import * as THREE from "three";
import { type Dict, Vec2, Vec3, isDict, toFloat } from "../value.ts";
import { colorOf } from "./color.ts";

const DEG = Math.PI / 180;
const warned = new Set<string>();

function note(msg: string): void {
  if (warned.has(msg)) return;
  warned.add(msg);
  console.info(`[mesh_lib] ${msg}`);
}

export class MeshLib {
  private meshes: Dict;
  private materials: Dict;
  private materialCache = new Map<string, THREE.MeshStandardMaterial>();

  constructor(lib: Dict) {
    this.meshes = isDict(lib.meshes) ? lib.meshes : {};
    this.materials = isDict(lib.materials) ? lib.materials : {};
  }

  has(name: string): boolean {
    return isDict(this.meshes[name]);
  }

  get(name: string): Dict {
    return this.meshes[name] as Dict;
  }

  /** MeshLib.merge_params: the mesh params, then the instance params on top. */
  static mergeParams(meshDef: Dict, instanceParams: unknown): Dict {
    return { ...(isDict(meshDef.params) ? meshDef.params : {}), ...(isDict(instanceParams) ? instanceParams : {}) };
  }

  /** MeshLib.build_primitives_into: one child node for each primitive. */
  buildInto(parent: THREE.Object3D, primitives: unknown[], params: Dict, castShadowDefault = true): void {
    for (const p of primitives) {
      if (!isDict(p)) continue;
      const geo = this.geometry(p, params);
      if (!geo) continue;
      const mesh = new THREE.Mesh(geo, this.material(p, params));
      const cast = "cast_shadow" in p ? Boolean(p.cast_shadow) : castShadowDefault;
      mesh.castShadow = cast;
      mesh.receiveShadow = true;
      const pos = vec3(resolve(p.pos ?? [0, 0, 0], params));
      if ("rotation_deg" in p) {
        const r = vec3(resolve(p.rotation_deg, params));
        mesh.rotation.set(r.x * DEG, r.y * DEG, r.z * DEG, "YXZ");
      }
      const pivotV = p.pivot;
      if (pivotV !== undefined && pivotV !== null) {
        // The node sits at the joint, and the mesh hangs at -pivot under it.
        let pivot = new THREE.Vector3();
        const op = String(p.op ?? "");
        if (pivotV === "top") {
          if (op === "cylinder" || op === "capsule") pivot.set(0, toFloat(resolve(p.height ?? 1, params)) / 2, 0);
        } else pivot = vec3(pivotV);
        const joint = new THREE.Group();
        joint.position.copy(pos).add(pivot);
        if ("name" in p) joint.name = String(p.name);
        mesh.position.copy(pivot).negate();
        joint.add(mesh);
        parent.add(joint);
      } else {
        mesh.position.copy(pos);
        if ("name" in p) mesh.name = String(p.name);
        parent.add(mesh);
      }
    }
  }

  /** MeshLib._primitive_mesh, with Godot's mesh shapes and axes. */
  private geometry(p: Dict, params: Dict): THREE.BufferGeometry | null {
    const op = String(p.op ?? "");
    const num = (k: string, d: number) => toFloat(resolve(p[k] ?? d, params));
    if ("csg" in p && String(p.csg) !== "union") note(`a CSG '${String(p.csg)}' is not in this host yet: the part draws unchanged`);
    switch (op) {
      case "lathe": {
        // CSGPolygon3D MODE_SPIN about Y. The profile closes to the axis (_closed_profile).
        const pts = asPoints(resolve(p.profile ?? [], params));
        if (pts.length === 0) return null;
        if (pts[0].x !== 0) pts.unshift(new THREE.Vector2(0, pts[0].y));
        if (pts[pts.length - 1].x !== 0) pts.push(new THREE.Vector2(0, pts[pts.length - 1].y));
        return new THREE.LatheGeometry(pts, Math.max(3, Math.trunc(num("segments", 16))));
      }
      case "extrude": {
        // CSGPolygon3D MODE_DEPTH: the polygon in XY, `depth` along Z, centered on `pos`.
        const pts = asPoints(resolve(p.polygon ?? [], params));
        if (pts.length < 3) return null;
        const depth = num("depth", 0.1);
        return new THREE.ExtrudeGeometry(new THREE.Shape(pts), { depth, bevelEnabled: false }).translate(0, 0, -depth / 2);
      }
      case "sweep": {
        // CSGPolygon3D MODE_PATH: the polygon follows the path's straight segments, one ring each `interval`.
        const pts = asPoints(resolve(p.polygon ?? [], params));
        const path = (Array.isArray(resolve(p.path ?? [], params)) ? (resolve(p.path, params) as unknown[]) : []).map((q) => vec3(q));
        if (pts.length < 3 || path.length < 2) return null;
        const curve = new THREE.CurvePath<THREE.Vector3>();
        for (let i = 1; i < path.length; i++) curve.add(new THREE.LineCurve3(path[i - 1], path[i]));
        const steps = Math.max(1, Math.round(curve.getLength() / Math.max(num("interval", 0.05), 0.001)));
        return new THREE.ExtrudeGeometry(new THREE.Shape(pts), { steps, bevelEnabled: false, extrudePath: curve });
      }
      case "box": {
        const s = vec3(resolve(p.size ?? [1, 1, 1], params));
        return new THREE.BoxGeometry(s.x, s.y, s.z);
      }
      case "sphere":
        return new THREE.SphereGeometry(num("radius", 0.5), 32, 16);
      case "cylinder": {
        const r = num("radius", 0.3);
        return new THREE.CylinderGeometry(r, r, num("height", 1), 32);
      }
      case "capsule": {
        // Godot's capsule height includes both caps.
        const r = num("radius", 0.3);
        return new THREE.CapsuleGeometry(r, Math.max(num("height", 1) - 2 * r, 0), 8, 24);
      }
      case "plane": {
        // PlaneMesh faces +Y.
        const [w, d] = vec2(resolve(p.size ?? [1, 1], params));
        return new THREE.PlaneGeometry(w, d).rotateX(-Math.PI / 2);
      }
      case "quad": {
        // QuadMesh faces +Z.
        const [w, h] = vec2(resolve(p.size ?? [1, 1], params));
        return new THREE.PlaneGeometry(w, h);
      }
      case "prism": {
        // PrismMesh: a triangle in XY with the apex at the top center, as deep as size.z.
        const s = vec3(resolve(p.size ?? [1, 1, 1], params));
        const tri = new THREE.Shape([
          new THREE.Vector2(-s.x / 2, -s.y / 2),
          new THREE.Vector2(s.x / 2, -s.y / 2),
          new THREE.Vector2(0, s.y / 2),
        ]);
        return new THREE.ExtrudeGeometry(tri, { depth: s.z, bevelEnabled: false }).translate(0, 0, -s.z / 2);
      }
      case "torus": {
        // TorusMesh lies in XZ, around the Y axis.
        const inner = num("inner_radius", 0.3);
        const outer = num("outer_radius", 0.5);
        return new THREE.TorusGeometry((inner + outer) / 2, (outer - inner) / 2, 16, 48).rotateX(Math.PI / 2);
      }
    }
    note(`unknown op '${op}'`);
    return null;
  }

  /** MeshLib.material_for: one shared material for each key (ADR 0083). */
  private material(p: Dict, params: Dict): THREE.MeshStandardMaterial {
    const f: Dict = {};
    const mname = String(resolve(p.material ?? "", params));
    if (mname !== "") {
      if (!isDict(this.materials[mname])) note(`unknown material '${mname}'`);
      else Object.assign(f, this.materials[mname]);
    }
    for (const k of ["color", "roughness", "metallic", "emission", "emission_energy"]) if (k in p) f[k] = resolve(p[k], params) as Dict[string];
    const key = JSON.stringify([f.color ?? "#fff", f.roughness ?? 1, f.metallic ?? 0, f.emission ?? null, f.emission_energy ?? 1]);
    const hit = this.materialCache.get(key);
    if (hit) return hit;
    const color = colorOf(f.color ?? "#fff");
    const mat = new THREE.MeshStandardMaterial({
      color,
      roughness: toFloat(f.roughness ?? 1),
      metalness: toFloat(f.metallic ?? 0),
      transparent: (color.alpha ?? 1) < 1,
      opacity: color.alpha ?? 1,
    });
    if ("emission" in f) {
      mat.emissive = colorOf(f.emission);
      mat.emissiveIntensity = toFloat(f.emission_energy ?? 1);
    }
    this.materialCache.set(key, mat);
    return mat;
  }
}

/** MeshLib._param_resolve: "$name" reads params. */
function resolve(v: unknown, params: Dict): unknown {
  return typeof v === "string" && v.startsWith("$") ? (params[v.slice(1)] ?? v) : v;
}

/** MeshLib._to_vec3: [x, y, z], [x, y] (z = 0), or one number for all three. */
export function vec3(v: unknown): THREE.Vector3 {
  if (Array.isArray(v)) {
    if (v.length >= 3) return new THREE.Vector3(toFloat(v[0]), toFloat(v[1]), toFloat(v[2]));
    if (v.length === 2) return new THREE.Vector3(toFloat(v[0]), toFloat(v[1]), 0);
  }
  if (typeof v === "number") return new THREE.Vector3(v, v, v);
  if (v instanceof Vec3) return new THREE.Vector3(v.x, v.y, v.z);
  if (v instanceof Vec2) return new THREE.Vector3(v.x, v.y, 0);
  return new THREE.Vector3();
}

/** A list of [x, y] points. */
function asPoints(v: unknown): THREE.Vector2[] {
  return (Array.isArray(v) ? v : []).filter((q) => Array.isArray(q) && q.length >= 2).map((q) => new THREE.Vector2(toFloat((q as unknown[])[0]), toFloat((q as unknown[])[1])));
}

/** MeshLib._to_vec2: [x, y], or one number for both. The default is [1, 1]. */
function vec2(v: unknown): [number, number] {
  if (Array.isArray(v) && v.length >= 2) return [toFloat(v[0]), toFloat(v[1])];
  if (typeof v === "number") return [v, v];
  return [1, 1];
}
