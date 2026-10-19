// The physics seam of the core (ADR 0095 phase 3). Motion is host-defined
// (ADR 0086), so the core holds only this interface and the exact parts of
// the spec: the closed vocabularies, the layer names and the tree check of
// an articulated body. physics_rapier.ts implements the interface.
//
// Tick order, as world.gd advance_one_tick:
//   readBack (articulated poses → state), readSensors, the rules, drive
//   (motor targets). The runner then steps the bodies: one step for each
//   tick in a scenario with an articulated body, one step for each 1/60 s
//   in live play.
import type { Entity } from "./entity.ts";
import type { Env } from "./env.ts";
import type { GroundHeight } from "./heightmap.ts";
import { raise } from "./env.ts";
import { type Dict, isDict, toFloat } from "./value.ts";

/** physics_body_builder.gd BODY_TYPES (ADR 0090, ADR 0091). */
export const BODY_TYPES = ["static", "kinematic", "rigid", "area", "character", "articulated"];
/** articulated_body.gd JOINT_TYPES (ADR 0091). */
export const JOINT_TYPES = ["hinge", "ball", "fixed"];
/** sensor_array.gd SENSOR_TYPES (ADR 0092). */
export const SENSOR_TYPES = ["ray", "lidar"];

/** A world pose: a position and a unit quaternion [x, y, z, w]. */
export type Pose = { p: [number, number, number]; q: [number, number, number, number] };

export interface PhysicsHost {
  /** Build the body and the sensors of an entity. Its def has a `physics` block or a `sensors` list. */
  add(e: Entity, def: Dict, env: Env): void;
  /** Free the bodies, joints and sensors of an entity. */
  remove(e: Entity): void;
  hasArticulated(): boolean;
  /** ArticulatedBody.read_back: root pose and reported hinges → state. */
  readBack(): void;
  /** SensorArray.read: rays → state. */
  readSensors(): void;
  /** ArticulatedBody.drive: each motor reads its target formula. */
  drive(env: Env): void;
  /** One physics step: the character controllers, the motors, then the rigid world. */
  step(dt: number): void;
  /** CharacterBodyRunner.tick_headless for every character body. */
  tickCharactersHeadless(dt: number): void;
  /** The world pose of each link of an articulated entity, for the renderer. */
  linkPoses(e: Entity): Map<string, Pose> | null;
  /** GroundRenderer: the floor collider of `scene.json` ground (live play only), displaced when `height` is given. */
  addGround(ground: Dict, height: GroundHeight | null): void;
  /** The trimesh of a static body, from the faces of its GLB in native space (the viewer loads them). */
  setTrimesh(e: Entity, vertices: Float32Array, indices: Uint32Array): void;
  /** The static bodies whose trimesh waits for faces, with the GLB path of each. */
  pendingTrimeshes(): { entity: Entity; mesh: string }[];
}

/** PhysicsBodyBuilder.layer_mask: "all", one layer name or a list of names → a bit mask. */
export function layerMask(value: unknown, layers: Dict, env: Env | null, raise: (env: Env, code: string, msg: string) => void): number {
  if (value === "all") return 0xffffffff;
  const names = Array.isArray(value) ? value : [value];
  let mask = 0;
  for (const name of names) {
    const bit = typeof name === "string" ? Number(layers[name] ?? 0) : 0;
    if (bit >= 1 && bit <= 32) mask |= 1 << (bit - 1);
    else if (env) raise(env, "physics.unknown_layer", `'${String(name)}' is not a collision layer name. See @lib.physics.layers (ADR 0090).`);
  }
  return mask >>> 0;
}

/** ArticulatedBody._check: "" when the block is one tree of known joint types, else the problem. */
export function checkArticulation(cfg: Dict): string {
  const links = cfg.links;
  if (!isDict(links) || Object.keys(links).length === 0) return "an articulated body needs a 'links' object";
  const root = String(cfg.root ?? "");
  if (!(root in links)) return `'root' must name a link, got '${root}'`;
  const parentOf = new Map<string, string>();
  for (const j of Array.isArray(cfg.joints) ? cfg.joints : []) {
    if (!isDict(j)) return "each joint must be an object";
    const jt = String(j.type ?? "");
    if (!JOINT_TYPES.includes(jt)) return `'${jt}' is not a joint type. The types are: ${JOINT_TYPES.join(", ")}`;
    const p = String(j.parent ?? "");
    const c = String(j.child ?? "");
    if (!(p in links) || !(c in links)) return `joint ${p} → ${c} names a link that does not exist`;
    if (c === root || parentOf.has(c)) return `link '${c}' has more than one parent`;
    parentOf.set(c, p);
  }
  for (const name of Object.keys(links)) {
    if (name === root) continue;
    const seen = new Set<string>();
    let cur = name;
    while (cur !== root) {
      if (!parentOf.has(cur) || seen.has(cur)) return `link '${name}' does not connect to the root`;
      seen.add(cur);
      cur = parentOf.get(cur)!;
    }
  }
  return "";
}

/** SpawnManager._build_physics_body_if_declared and _build_sensors_if_declared. */
export function attachBody(env: Env, e: Entity, def: Dict): void {
  const physics = translateBlocksMotion(def);
  const hasBody = Object.keys(physics).length > 0;
  const hasSensors = Array.isArray(def.sensors) && def.sensors.length > 0;
  if (!hasBody && !hasSensors) return;
  if (env.physics) env.physics.add(e, physics === def.physics ? def : { ...def, physics }, env);
  else raise(env, "host.unsupported", `def '${String(def.id ?? "")}': this run has no physics host`, "warning");
}

/**
 * PhysicsBodyBuilder.translate_blocks_motion: a def with no physics block,
 * the `blocks_motion` tag and properties.aabb_extents (half sizes) gets a
 * static box on the wall layer. A 2D extent has no 3D body.
 */
export function translateBlocksMotion(def: Dict): Dict {
  if (isDict(def.physics) && Object.keys(def.physics).length > 0) return def.physics;
  if (!(Array.isArray(def.tags) && def.tags.includes("blocks_motion"))) return {};
  const props = isDict(def.properties) ? def.properties : {};
  const ext = props.aabb_extents;
  if (!Array.isArray(ext) || ext.length < 3) return {};
  const off = Array.isArray(props.aabb_offset) ? props.aabb_offset : [0, 0, 0];
  return {
    body_type: "static",
    collision_shape: {
      type: "box",
      size: [toFloat(ext[0]) * 2, toFloat(ext[1]) * 2, toFloat(ext[2]) * 2],
      offset: [toFloat(off[0] ?? 0), toFloat(off[1] ?? 0), toFloat(off[2] ?? 0)],
    },
    collision_layer: ["wall"],
    collision_mask: "all",
  };
}

/** ArticulatedBody.shape_transform: a cylinder or capsule lies along `axis` ("y" by default), then `offset` moves it. */
export function shapeTransform(shape: Dict): Pose {
  let q: Pose["q"] = [0, 0, 0, 1];
  const axis = String(shape.axis ?? "y");
  if (axis === "x") q = qAxisAngle([0, 0, 1], -Math.PI / 2);
  else if (axis === "z") q = qAxisAngle([1, 0, 0], Math.PI / 2);
  const o = shape.offset;
  const p: Pose["p"] = Array.isArray(o) && o.length >= 3 ? [toFloat(o[0]), toFloat(o[1]), toFloat(o[2])] : [0, 0, 0];
  return { p, q };
}

export function qAxisAngle(axis: Pose["p"], angle: number): Pose["q"] {
  const l = Math.hypot(axis[0], axis[1], axis[2]) || 1;
  const a = [axis[0] / l, axis[1] / l, axis[2] / l];
  const s = Math.sin(angle / 2);
  return [a[0] * s, a[1] * s, a[2] * s, Math.cos(angle / 2)];
}
