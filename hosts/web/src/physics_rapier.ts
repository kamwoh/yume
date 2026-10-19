// The physics host on Rapier (ADR 0095 phase 3). Mirrors the Godot
// reference: physics_body_builder.gd (static, kinematic, rigid and area
// bodies), character_body_runner.gd (character bodies), articulated_body.gd
// (ADR 0091) and sensor_array.gd (ADR 0092).
//
// Motion is host-defined (ADR 0086). These choices follow the reference
// where Rapier gives a choice:
//   - Collision pairs: (a.layer & b.mask) or (b.layer & a.mask), as Godot.
//     A contact hook applies it, because Rapier groups need both sides.
//   - The links of one robot never collide with each other.
//   - Friction combines by the minimum. The default friction is 1, the
//     default bounce 0, and the default damping 0.1, as Godot.
//   - A hinge motor is a capped impulse between solves, as in Godot. Rapier's
//     JS motor has no cap, so the host substeps a world with motors.
//   - A rigid body writes nothing back to state, as in the reference.
//
// A shape `mesh` and a `from_visual_mesh` box take their size from the GLB
// bounds (glb.ts), as the reference does.
//
// A trimesh gets its faces from the viewer, which loads the GLB anyway. A
// displaced ground is a heightfield from heightmap.ts.
//
// Not in this host yet: the "base" footprint of from_visual_mesh. It raises
// host.unsupported once.
import RAPIER from "@dimforge/rapier3d-compat";
import type { Entity } from "./entity.ts";
import type { Bounds } from "./glb.ts";
import { GroundHeight } from "./heightmap.ts";
import type { Env } from "./env.ts";
import { raise } from "./env.ts";
import { evaluate } from "./formula.ts";
import { type PhysicsHost, type Pose, SENSOR_TYPES, checkArticulation, layerMask, qAxisAngle, shapeTransform } from "./physics.ts";
import { type Dict, Vec2, Vec3, isDict, toFloat } from "./value.ts";

type V3 = [number, number, number];
type Q = [number, number, number, number];

let ready: Promise<void> | null = null;

/** Load the Rapier WASM module once. Call it before the first `new RapierPhysics`. */
export function initRapier(): Promise<void> {
  ready ??= (async () => {
    // Rapier's own loader prints a wasm-bindgen deprecation note on each init. It is not ours to fix.
    const warn = console.warn;
    console.warn = (...a: unknown[]) => {
      if (!String(a[0]).startsWith("using deprecated parameters")) warn(...a);
    };
    try {
      await RAPIER.init();
    } finally {
      console.warn = warn;
    }
  })();
  return ready;
}

/** Godot's project defaults. */
const GRAVITY = 9.8;
const DEFAULT_FRICTION = 1.0;
const DEFAULT_DAMP = 0.1;
/** The substeps of a step in a world with motors. See applyMotors. */
const MOTOR_SUBSTEPS = 8;
/** CharacterBodyRunner._apply_vertical: state.gravity defaults to 18. */
const CHARACTER_GRAVITY = 18.0;

type ColliderInfo = { entity: Entity | null; layer: number; mask: number; area: boolean };

type SimpleBody = { kind: "static" | "kinematic" | "rigid" | "area"; body: RAPIER.RigidBody; yaw: number; pushed: string; vel: string };

type CharacterBody = {
  body: RAPIER.RigidBody;
  collider: RAPIER.Collider;
  kcc: RAPIER.KinematicCharacterController;
  mask: number;
  /** CharacterBody3D.velocity: x and z from state.velocity, y from state.y_velocity. */
  vel: V3;
  pushed: string;
  velKey: string;
  floorMaxAngle: number;
};

type JointRec = {
  joint: RAPIER.ImpulseJoint;
  type: string;
  a: string;
  b: string;
  motor: Dict | null;
  target: number;
  maxTorque: number;
  report: string;
  axisA: V3;
  refA: V3;
  refB: V3;
  angle: number;
  last: number;
};

type Articulated = {
  entity: Entity;
  root: string;
  owner: Map<string, string>;
  inOwner: Map<string, Pose>;
  bodies: Map<string, RAPIER.RigidBody>;
  joints: JointRec[];
  poses: Map<string, Pose>;
};

type Sensor = { type: string; link: string; at: V3; dir: V3; range: number; rays: number; fov: number; report: string; mask: number };

export class RapierPhysics implements PhysicsHost {
  world: RAPIER.World;
  private layers: Dict;
  private env: Env | null = null;
  private colliders = new Map<number, ColliderInfo>();
  private simple = new Map<Entity, SimpleBody>();
  private characters = new Map<Entity, CharacterBody>();
  private articulated = new Map<Entity, Articulated>();
  private sensors = new Map<Entity, Sensor[]>();
  /** The collider info and GLB path of each static body whose trimesh waits for its faces. */
  private trimeshInfo = new Map<Entity, ColliderInfo & { mesh: string; asked: boolean }>();
  private events: RAPIER.EventQueue;
  private warned = new Set<string>();
  private hooks: RAPIER.PhysicsHooks;

  private bounds: (path: string) => Bounds | null;

  /** `layers` is @lib.physics.layers.layers: name → bit number. `bounds` reads the GLB bounds of an asset path. */
  constructor(layers: Dict, bounds: (path: string) => Bounds | null = () => null) {
    this.layers = layers;
    this.bounds = bounds;
    this.world = new RAPIER.World({ x: 0, y: -GRAVITY, z: 0 });
    this.world.timestep = 1 / 60;
    this.events = new RAPIER.EventQueue(true);
    this.hooks = {
      filterContactPair: (c1, c2) => (this.pairCollides(c1, c2) ? RAPIER.SolverFlags.COMPUTE_IMPULSE : null),
      filterIntersectionPair: (c1, c2) => this.pairCollides(c1, c2),
    };
  }

  /** Godot's pair test: either side's layer is in the other side's mask. One robot never collides with itself. */
  private pairCollides(h1: number, h2: number): boolean {
    const a = this.colliders.get(h1);
    const b = this.colliders.get(h2);
    if (!a || !b) return true;
    if (a.entity !== null && a.entity === b.entity) return false;
    // An area watches bodies on its mask. It is not watched (monitorable = false).
    if (a.area) return (b.layer & a.mask) !== 0;
    if (b.area) return (a.layer & b.mask) !== 0;
    return (a.layer & b.mask) !== 0 || (b.layer & a.mask) !== 0;
  }

  private warnOnce(code: string, msg: string): void {
    if (this.warned.has(msg) || !this.env) return;
    this.warned.add(msg);
    raise(this.env, code, msg, "warning");
  }

  private mask(v: unknown): number {
    return layerMask(v, this.layers, this.env, (env, code, msg) => raise(env, code, msg));
  }

  private collider(desc: RAPIER.ColliderDesc, body: RAPIER.RigidBody, info: ColliderInfo): RAPIER.Collider {
    desc.setActiveHooks(RAPIER.ActiveHooks.FILTER_CONTACT_PAIRS | RAPIER.ActiveHooks.FILTER_INTERSECTION_PAIRS);
    desc.setFrictionCombineRule(RAPIER.CoefficientCombineRule.Min);
    const c = this.world.createCollider(desc, body);
    this.colliders.set(c.handle, info);
    return c;
  }

  // ------------------------------------------------------------------
  // Build and free
  // ------------------------------------------------------------------

  add(e: Entity, def: Dict, env: Env): void {
    this.env = env;
    const cfg = isDict(def.physics) ? def.physics : null;
    if (cfg && Object.keys(cfg).length > 0) {
      const bt = String(cfg.body_type ?? "kinematic");
      if (bt === "articulated") this.buildArticulated(e, cfg);
      else if (bt === "character") this.buildCharacter(e, cfg);
      else this.buildSimple(e, cfg, bt);
    }
    if (Array.isArray(def.sensors) && def.sensors.length > 0) this.buildSensors(e, def.sensors);
  }

  remove(e: Entity): void {
    const s = this.simple.get(e);
    if (s) {
      this.freeBody(s.body);
      this.simple.delete(e);
    }
    const c = this.characters.get(e);
    if (c) {
      this.world.removeCharacterController(c.kcc);
      this.freeBody(c.body);
      this.characters.delete(e);
    }
    const ab = this.articulated.get(e);
    if (ab) {
      for (const j of ab.joints) this.world.removeImpulseJoint(j.joint, false);
      for (const b of ab.bodies.values()) this.freeBody(b);
      this.articulated.delete(e);
    }
    this.sensors.delete(e);
    this.trimeshInfo.delete(e);
  }

  private freeBody(b: RAPIER.RigidBody): void {
    for (let i = 0; i < b.numColliders(); i++) this.colliders.delete(b.collider(i).handle);
    this.world.removeRigidBody(b);
  }

  /** PhysicsBodyBuilder.build_3d and build_area_3d. */
  private buildSimple(e: Entity, cfg: Dict, bt: string): void {
    cfg = { ...cfg };
    if (isDict(cfg.collision_shape)) cfg.collision_shape = this.shrinkwrap(cfg.collision_shape, e);
    let kind = bt as SimpleBody["kind"];
    if (!["static", "kinematic", "rigid", "area"].includes(bt)) {
      if (this.env) raise(this.env, "physics.unknown_body_type", `'${bt}' is not a body type (ADR 0090).`);
      kind = "kinematic";
    }
    const shape = isDict(cfg.collision_shape) ? cfg.collision_shape : null;
    const yaw = shape && String(shape.type ?? "") === "box" ? entityYaw(e) : 0;
    const desc =
      kind === "rigid" ? RAPIER.RigidBodyDesc.dynamic() : kind === "kinematic" ? RAPIER.RigidBodyDesc.kinematicPositionBased() : RAPIER.RigidBodyDesc.fixed();
    desc.setTranslation(...position3(e)).setRotation(quat(yawQuat(yaw)));
    if (kind === "rigid") {
      desc.setLinearDamping(toFloat(cfg.linear_damp ?? DEFAULT_DAMP)).setAngularDamping(toFloat(cfg.angular_damp ?? DEFAULT_DAMP));
      if ("gravity_scale" in cfg) desc.setGravityScale(toFloat(cfg.gravity_scale));
    }
    const body = this.world.createRigidBody(desc);
    const area = kind === "area";
    const info: ColliderInfo = {
      entity: e,
      layer: this.mask(cfg.collision_layer ?? (area ? [] : "all")),
      mask: this.mask(cfg.collision_mask ?? "all"),
      area,
    };
    if (shape && String(shape.type ?? "") === "trimesh") this.trimeshInfo.set(e, { ...info, mesh: String(shape.mesh ?? ""), asked: false });
    if (shape) {
      const cd = this.shapeDesc(shape, [1, 1, 1]);
      if (cd) {
        const off = vecOr(shape.offset, [0, 0, 0]);
        cd.setTranslation(...off);
        if (kind === "rigid") {
          cd.setFriction(toFloat(cfg.friction ?? DEFAULT_FRICTION)).setRestitution(toFloat(cfg.restitution ?? 0));
          if ("mass" in cfg) cd.setMass(toFloat(cfg.mass));
        } else cd.setFriction(DEFAULT_FRICTION);
        if (area) {
          cd.setSensor(true).setActiveEvents(RAPIER.ActiveEvents.COLLISION_EVENTS).setActiveCollisionTypes(RAPIER.ActiveCollisionTypes.ALL);
        }
        this.collider(cd, body, info);
      }
    }
    this.simple.set(e, { kind, body, yaw, pushed: posKey(e), vel: "" });
    if (kind === "rigid") this.pushVelocity(e, body);
  }

  /**
   * PhysicsBodyBuilder._shrinkwrap_box_to_visual: a `from_visual_mesh` box
   * wraps the drawn GLB. The renderer draws it one unit tall, base on the
   * ground, then scales it by the height of state.scale.
   */
  private shrinkwrap(shape: Dict, e: Entity): Dict {
    const fvm = shape.from_visual_mesh;
    if (String(shape.type ?? "") !== "box" || !(fvm === true || fvm === "base")) return shape;
    const mesh = String(e.visual.mesh ?? "");
    if (!mesh.endsWith(".glb") && !mesh.endsWith(".gltf")) return shape;
    const bb = this.bounds(mesh);
    if (!bb || bb.max[1] - bb.min[1] <= 0.0001) return shape;
    if (fvm === "base") this.warnOnce("host.unsupported", "the 'base' footprint of from_visual_mesh is not in this host yet; the box wraps the full model");
    const h = stateScale(e)[1];
    const k = h / (bb.max[1] - bb.min[1]);
    return { ...shape, size: [(bb.max[0] - bb.min[0]) * k, h, (bb.max[2] - bb.min[2]) * k], offset: [0, h / 2, 0] };
  }

  /** _build_collision_shape_node: a shape `mesh` gives the sizes from its GLB bounds. */
  private meshSized(shape: Dict): Dict {
    const path = shape.mesh;
    if (typeof path !== "string" || path === "") return shape;
    const bb = this.bounds(path);
    if (!bb) {
      this.warnOnce("host.unsupported", `no GLB bounds for collision mesh '${path}'`);
      return shape;
    }
    const sx = bb.max[0] - bb.min[0];
    const sy = bb.max[1] - bb.min[1];
    const sz = bb.max[2] - bb.min[2];
    const r = Math.max(sx, sz) / 2;
    switch (String(shape.type ?? "")) {
      case "box":
        return { ...shape, size: [sx, sy, sz] };
      case "sphere":
        return { ...shape, radius: r };
      case "capsule":
      case "cylinder":
        return { ...shape, radius: r, height: sy };
    }
    return shape;
  }

  /** PhysicsBodyBuilder.build_character_3d. */
  private buildCharacter(e: Entity, cfg: Dict): void {
    const body = this.world.createRigidBody(RAPIER.RigidBodyDesc.kinematicPositionBased().setTranslation(...position3(e)));
    const shape = isDict(cfg.collision_shape) ? this.meshSized(cfg.collision_shape) : {};
    const scale = stateScale(e);
    const cd = this.shapeDesc(shape, scale);
    let collider: RAPIER.Collider;
    const info: ColliderInfo = { entity: e, layer: this.mask(cfg.collision_layer ?? []), mask: this.mask(cfg.collision_mask ?? []), area: false };
    if (cd) {
      // The shape base sits at the body origin: entity.position is the feet.
      const off = Array.isArray(shape.offset) && shape.offset.length >= 3 ? vecOr(shape.offset, [0, 0, 0]) : [0, autoLift(shape), 0];
      cd.setTranslation(off[0] * scale[0], off[1] * scale[1], off[2] * scale[2]);
      collider = this.collider(cd, body, info);
    } else collider = this.collider(RAPIER.ColliderDesc.ball(0.01), body, info);
    const kcc = this.world.createCharacterController(0.01);
    kcc.setUp({ x: 0, y: 1, z: 0 });
    const maxAngle = (toFloat(cfg.floor_max_angle_deg ?? 50) * Math.PI) / 180;
    kcc.setMaxSlopeClimbAngle(maxAngle);
    kcc.setMinSlopeSlideAngle(maxAngle);
    const snap = toFloat(cfg.floor_snap_length ?? 0.5);
    if (snap > 0) kcc.enableSnapToGround(snap);
    else kcc.disableSnapToGround();
    kcc.setApplyImpulsesToDynamicBodies(false);
    const ch: CharacterBody = { body, collider, kcc, mask: info.mask, vel: [0, 0, 0], pushed: posKey(e), velKey: "", floorMaxAngle: maxAngle };
    this.characters.set(e, ch);
    this.syncCharacterVelocity(e, ch);
  }

  /** PhysicsBodyBuilder._create_shape_3d, with an optional scale for each axis. */
  private shapeDesc(shape: Dict, s: V3): RAPIER.ColliderDesc | null {
    const t = String(shape.type ?? "box");
    // The viewer gives a trimesh its faces when the GLB loads (setTrimesh). A headless run has none.
    if (t === "trimesh") return null;
    switch (t) {
      case "box": {
        const sz = vecOr(shape.size, [1, 1, 1]);
        return RAPIER.ColliderDesc.cuboid((sz[0] * s[0]) / 2, (sz[1] * s[1]) / 2, (sz[2] * s[2]) / 2);
      }
      case "sphere":
        return RAPIER.ColliderDesc.ball(toFloat(shape.radius ?? 0.5) * Math.max(...s));
      case "capsule": {
        // Godot's capsule height includes both caps.
        const r = toFloat(shape.radius ?? 0.4) * Math.max(s[0], s[2]);
        const h = toFloat(shape.height ?? 1.0) * s[1];
        return RAPIER.ColliderDesc.capsule(Math.max(h / 2 - r, 0), r);
      }
      case "cylinder":
        return RAPIER.ColliderDesc.cylinder((toFloat(shape.height ?? 1.0) * s[1]) / 2, toFloat(shape.radius ?? 0.4) * Math.max(s[0], s[2]));
    }
    this.warnOnce("host.unsupported", `collision shape '${t}' is not in this host yet`);
    return null;
  }

  /** ArticulatedBody.build and _build. */
  private buildArticulated(e: Entity, cfg: Dict): void {
    const problem = checkArticulation(cfg);
    if (problem !== "") {
      if (this.env) raise(this.env, "physics.bad_articulation", `${e.id}: ${problem}`);
      return;
    }
    const root = String(cfg.root);
    const links = cfg.links as Dict;
    const joints = (Array.isArray(cfg.joints) ? cfg.joints : []).filter(isDict);
    // Spawn poses: the root at the entity position and yaw, each child at `at` in its parent frame.
    const rootPose: Pose = { p: position3(e), q: yawQuat(toFloat(e.getState("yaw", 0))) };
    const spawn = new Map<string, Pose>([[root, rootPose]]);
    const owner = new Map<string, string>([[root, root]]);
    const ordered: Dict[] = [];
    let pending = [...joints];
    while (pending.length > 0) {
      const rest: Dict[] = [];
      for (const j of pending) {
        const p = String(j.parent);
        if (!spawn.has(p)) {
          rest.push(j);
          continue;
        }
        const c = String(j.child);
        spawn.set(c, poseMul(spawn.get(p)!, { p: vecOr(j.at, [0, 0, 0]), q: [0, 0, 0, 1] }));
        owner.set(c, merges(j, links) ? owner.get(p)! : c);
        ordered.push(j);
      }
      if (rest.length === pending.length) break;
      pending = rest;
    }
    const ab: Articulated = { entity: e, root, owner, inOwner: new Map(), bodies: new Map(), joints: [], poses: new Map() };
    for (const [name, pose] of spawn) ab.inOwner.set(name, poseMul(poseInv(spawn.get(owner.get(name)!)!), pose));
    const info: ColliderInfo = { entity: e, layer: this.mask(cfg.collision_layer ?? "all"), mask: this.mask(cfg.collision_mask ?? "all"), area: false };
    for (const name of spawn.keys()) {
      const ownerName = owner.get(name)!;
      if (!ab.bodies.has(ownerName)) {
        const sp = spawn.get(ownerName)!;
        // A robot stops and starts on a motor command, and a motor change does not wake a body that sleeps.
        const desc = RAPIER.RigidBodyDesc.dynamic()
          .setTranslation(...sp.p)
          .setRotation(quat(sp.q))
          .setCanSleep(false)
          .setLinearDamping(toFloat(cfg.linear_damp ?? DEFAULT_DAMP))
          .setAngularDamping(toFloat(cfg.angular_damp ?? DEFAULT_DAMP));
        ab.bodies.set(ownerName, this.world.createRigidBody(desc));
      }
      const lcfg = links[name] as Dict;
      const ownerCfg = links[ownerName] as Dict;
      const body = ab.bodies.get(ownerName)!;
      const shape = isDict(lcfg.shape) ? lcfg.shape : null;
      const cd = shape && "type" in shape ? this.shapeDesc(shape, [1, 1, 1]) : null;
      // A link with no shape still has its mass.
      const desc = cd ?? RAPIER.ColliderDesc.ball(0.001).setSensor(true);
      const local = poseMul(ab.inOwner.get(name)!, shape ? shapeTransform(shape) : { p: [0, 0, 0], q: [0, 0, 0, 1] });
      desc.setTranslation(...local.p).setRotation(quat(local.q));
      // A body has one material: the owner link's.
      desc.setFriction(toFloat(ownerCfg.friction ?? DEFAULT_FRICTION)).setRestitution(toFloat(ownerCfg.restitution ?? 0));
      desc.setMass(toFloat(lcfg.mass ?? 1.0));
      this.collider(desc, body, info);
    }
    for (const j of ordered) if (!merges(j, links)) ab.joints.push(this.makeJoint(ab, j, spawn));
    this.articulated.set(e, ab);
    this.readPoses(ab);
  }

  /** ArticulatedBody._make_joint. */
  private makeJoint(ab: Articulated, j: Dict, spawn: Map<string, Pose>): JointRec {
    const a = ab.owner.get(String(j.parent))!;
    const b = String(j.child);
    const anchor = spawn.get(b)!.p;
    const sa = spawn.get(a)!;
    const sb = spawn.get(b)!;
    const la = poseApply(poseInv(sa), anchor);
    const lb = poseApply(poseInv(sb), anchor);
    const type = String(j.type);
    const rec: JointRec = {
      joint: null as unknown as RAPIER.ImpulseJoint,
      type,
      a,
      b,
      motor: null,
      target: 0,
      maxTorque: 0,
      report: "",
      axisA: [0, 0, 1],
      refA: [1, 0, 0],
      refB: [1, 0, 0],
      angle: 0,
      last: 0,
    };
    let data: RAPIER.JointData;
    if (type === "fixed") {
      // A fixed child with its own material: a joint with every axis locked.
      data = RAPIER.JointData.fixed(vec(la), quat(qMul(qConj(sa.q), sb.q)), vec(lb), quat([0, 0, 0, 1]));
    } else if (type === "ball") {
      data = RAPIER.JointData.spherical(vec(la), vec(lb));
    } else {
      const axisWorld = qRotate(spawn.get(String(j.parent))!.q, normalize(vecOr(j.axis, [1, 0, 0])));
      const basis = basisZ(axisWorld);
      rec.axisA = qRotate(qConj(sa.q), basis.z);
      rec.refA = qRotate(qConj(sa.q), basis.x);
      rec.refB = qRotate(qConj(sb.q), basis.x);
      // Both frames share the root rotation at spawn, so one local axis serves both bodies.
      data = RAPIER.JointData.revolute(vec(la), vec(lb), vec(rec.axisA));
      const limit = j.limit;
      if (Array.isArray(limit) && limit.length === 2) {
        data.limitsEnabled = true;
        data.limits = [toFloat(limit[0]), toFloat(limit[1])];
      }
      if (isDict(j.motor)) {
        rec.motor = j.motor;
        rec.maxTorque = toFloat(j.motor.max_torque ?? 1.0);
      }
      rec.report = String(j.report ?? "");
    }
    rec.joint = this.world.createImpulseJoint(data, ab.bodies.get(a)!, ab.bodies.get(b)!, true);
    rec.joint.setContactsEnabled(false);
    return rec;
  }

  /** SensorArray.build. */
  private buildSensors(e: Entity, cfgs: unknown[]): void {
    const out: Sensor[] = [];
    for (const c of cfgs) {
      if (!isDict(c)) continue;
      const t = String(c.type ?? "");
      if (!SENSOR_TYPES.includes(t) || String(c.report ?? "") === "") {
        if (this.env) raise(this.env, "sensor.bad_config", `${e.id}: a sensor needs a type (${SENSOR_TYPES.join(", ")}) and a report name (ADR 0092).`);
        continue;
      }
      const d = vecOr(c.direction, [0, 0, -1]);
      out.push({
        type: t,
        link: String(c.link ?? ""),
        at: vecOr(c.at, [0, 0, 0]),
        dir: len(d) > 1e-6 ? normalize(d) : [0, 0, -1],
        range: toFloat(c.range ?? 5.0),
        rays: Math.max(1, Math.trunc(toFloat(c.rays ?? 1))),
        fov: toFloat(c.fov ?? 2 * Math.PI),
        report: String(c.report),
        mask: this.mask(c.collision_mask ?? "all"),
      });
    }
    this.sensors.set(e, out);
  }

  /**
   * GroundRenderer: the floor layer. A flat ground is a 0.2 m box with its
   * top at y = 0. A displaced ground is a heightfield of 1 m cells, sampled
   * from the same function as the drawn ground (sample_y).
   */
  addGround(ground: Dict, height: GroundHeight | null): void {
    const mesh = isDict(ground.mesh) ? ground.mesh : null;
    if (!mesh) return;
    const size = Array.isArray(mesh.size) ? mesh.size : [400, 400];
    const w = toFloat(size[0] ?? 400);
    const d = size.length >= 2 ? toFloat(size[1]) : w;
    const body = this.world.createRigidBody(RAPIER.RigidBodyDesc.fixed());
    let cd: RAPIER.ColliderDesc;
    if (height) {
      const n = height.colliderPoints();
      const plane = height.planeSize;
      const step = plane / (n - 1);
      const heights = new Float32Array(n * n);
      // Rapier's order: the point (ix, iz) is at ix * n + iz.
      for (let ix = 0; ix < n; ix++) for (let iz = 0; iz < n; iz++) heights[ix * n + iz] = height.sampleY(-plane / 2 + ix * step, -plane / 2 + iz * step);
      cd = RAPIER.ColliderDesc.heightfield(n - 1, n - 1, heights, { x: plane, y: 1, z: plane });
    } else {
      if (GroundHeight.heightmapPath(ground) !== "") this.warnOnce("host.unsupported", "the heightmap of this ground did not load; the floor is flat");
      cd = RAPIER.ColliderDesc.cuboid(w / 2, 0.1, d / 2).setTranslation(0, -0.1, 0);
    }
    this.collider(cd.setFriction(DEFAULT_FRICTION), body, { entity: null, layer: this.mask(["floor"]), mask: 0, area: false });
  }

  setTrimesh(e: Entity, vertices: Float32Array, indices: Uint32Array): void {
    const s = this.simple.get(e);
    if (!s || s.kind === "rigid" || indices.length < 3) return;
    const cd = RAPIER.ColliderDesc.trimesh(vertices, indices).setFriction(DEFAULT_FRICTION);
    const t = this.trimeshInfo.get(e);
    if (!t) return;
    this.trimeshInfo.delete(e);
    this.collider(cd, s.body, { entity: t.entity, layer: t.layer, mask: t.mask, area: t.area });
  }

  /** Each waiting trimesh once: the viewer loads its GLB. */
  pendingTrimeshes(): { entity: Entity; mesh: string }[] {
    const out: { entity: Entity; mesh: string }[] = [];
    for (const [e, t] of this.trimeshInfo) {
      if (t.asked || t.mesh === "") continue;
      t.asked = true;
      out.push({ entity: e, mesh: t.mesh });
    }
    return out;
  }

  // ------------------------------------------------------------------
  // The tick
  // ------------------------------------------------------------------

  hasArticulated(): boolean {
    return this.articulated.size > 0;
  }

  /** ArticulatedBody.read_back. */
  readBack(): void {
    for (const ab of this.articulated.values()) {
      this.readPoses(ab);
      const rp = ab.poses.get(ab.root)!;
      const e = ab.entity;
      e.state.position = new Vec3(rp.p[0], rp.p[1], rp.p[2]);
      e.state.yaw = eulerYawYXZ(rp.q);
      const lv = ab.bodies.get(ab.root)!.linvel();
      e.state.velocity = new Vec3(lv.x, lv.y, lv.z);
      for (const j of ab.joints) {
        if (j.report === "") continue;
        const qa = ab.poses.get(j.a)!.q;
        const qb = ab.poses.get(j.b)!.q;
        const axis = normalize(qRotate(qa, j.axisA));
        const r0 = qRotate(qa, j.refA);
        const r1 = qRotate(qb, j.refB);
        const raw = Math.atan2(dot(axis, cross(r0, r1)), dot(r0, r1));
        // Unwrap: a wheel angle counts whole turns, as an encoder does.
        j.angle += wrap(raw - j.last);
        j.last = raw;
        const wa = ab.bodies.get(j.a)!.angvel();
        const wb = ab.bodies.get(j.b)!.angvel();
        e.state[`${j.report}_angle`] = j.angle;
        e.state[`${j.report}_speed`] = dot([wb.x - wa.x, wb.y - wa.y, wb.z - wa.z], axis);
      }
    }
  }

  /** SensorArray.read. */
  readSensors(): void {
    if (this.sensors.size === 0) return;
    this.pushMovedBodies();
    for (const [e, list] of this.sensors) {
      const own = this.ownBodies(e);
      for (const s of list) {
        const frame = this.frame(e, s.link);
        const origin = poseApply(frame, s.at);
        const dir = normalize(qRotate(frame.q, s.dir));
        if (s.type === "ray") {
          const d = this.cast(origin, dir, s.range, s.mask, own);
          e.state[`${s.report}_distance`] = d;
          e.state[`${s.report}_hit`] = d < s.range ? 1 : 0;
          continue;
        }
        const n = s.rays;
        const full = s.fov >= 2 * Math.PI - 1e-3;
        const step = full ? s.fov / n : n > 1 ? s.fov / (n - 1) : 0;
        const start = n > 1 ? -s.fov / 2 : 0;
        const up = normalize(qRotate(frame.q, [0, 1, 0]));
        const ranges: number[] = [];
        let best = s.range;
        let bestAngle = 0;
        for (let i = 0; i < n; i++) {
          const angle = start + step * i;
          const d = this.cast(origin, qRotate(qAxisAngle(up, angle), dir), s.range, s.mask, own);
          ranges.push(d);
          if (d < best) {
            best = d;
            bestAngle = angle;
          }
        }
        e.state[`${s.report}_ranges`] = ranges;
        e.state[`${s.report}_min`] = best;
        e.state[`${s.report}_min_angle`] = bestAngle;
      }
    }
  }

  /** A ray hits body shapes on `mask`, never areas or the entity's own bodies. A shape that holds the origin is skipped (Godot hit_from_inside = false). */
  private cast(origin: V3, dir: V3, range: number, mask: number, own: Set<number>): number {
    let best = range;
    this.world.intersectionsWithRay(
      new RAPIER.Ray(vec(origin), vec(dir)),
      range,
      true,
      (hit) => {
        if (hit.timeOfImpact > 1e-6 && hit.timeOfImpact < best) best = hit.timeOfImpact;
        return true;
      },
      RAPIER.QueryFilterFlags.EXCLUDE_SENSORS,
      undefined,
      undefined,
      undefined,
      (c) => {
        const info = this.colliders.get(c.handle);
        if (!info || info.area) return false;
        const b = c.parent();
        if (b && own.has(b.handle)) return false;
        return (info.layer & mask) !== 0;
      },
    );
    return best;
  }

  /** The sensor frame: a link pose, or the entity position and yaw. */
  private frame(e: Entity, link: string): Pose {
    const ab = this.articulated.get(e);
    if (link !== "" && ab && ab.poses.has(link)) return ab.poses.get(link)!;
    return { p: position3(e), q: yawQuat(toFloat(e.getState("yaw", 0))) };
  }

  private ownBodies(e: Entity): Set<number> {
    const out = new Set<number>();
    const ab = this.articulated.get(e);
    if (ab) for (const b of ab.bodies.values()) out.add(b.handle);
    const s = this.simple.get(e);
    if (s) out.add(s.body.handle);
    const c = this.characters.get(e);
    if (c) out.add(c.body.handle);
    return out;
  }

  /** ArticulatedBody.drive: each motor reads its target formula after the rules ran. */
  drive(env: Env): void {
    for (const ab of this.articulated.values()) {
      for (const j of ab.joints) {
        if (!j.motor) continue;
        j.target = toFloat(evaluate(j.motor.target_velocity ?? 0, { self: ab.entity, world: env.world }, env));
      }
    }
  }

  step(dt: number): void {
    this.pushMovedBodies();
    for (const [e, ch] of this.characters) this.moveCharacter(e, ch, dt);
    const subs = this.articulated.size > 0 ? MOTOR_SUBSTEPS : 1;
    this.world.timestep = dt / subs;
    for (let i = 0; i < subs; i++) {
      for (const ab of this.articulated.values()) this.applyMotors(ab, dt / subs);
      this.world.step(this.events, this.hooks);
    }
    this.drainEvents();
  }

  /**
   * A hinge motor: the impulse that reaches the target speed, capped at
   * max_torque × dt. Godot applies its capped motor impulse in each solver
   * iteration, between the contact solves. Rapier's JS motor has no cap, so
   * the host substeps instead: the capped impulse, then a solve, MOTOR_SUBSTEPS
   * times for each step.
   */
  private applyMotors(ab: Articulated, dt: number): void {
    for (const j of ab.joints) {
      if (!j.motor) continue;
      const ba = ab.bodies.get(j.a)!;
      const bb = ab.bodies.get(j.b)!;
      const axis = normalize(qRotate(rotOf(ba), j.axisA));
      const wa = ba.angvel();
      const wb = bb.angvel();
      const speed = dot([wb.x - wa.x, wb.y - wa.y, wb.z - wa.z], axis);
      const k = dot(axis, invInertia(ba, axis)) + dot(axis, invInertia(bb, axis));
      if (k <= 0) continue;
      const cap = j.maxTorque * dt;
      const imp = Math.max(-cap, Math.min(cap, (j.target - speed) / k));
      bb.applyTorqueImpulse(vec(scale(axis, imp)), true);
      ba.applyTorqueImpulse(vec(scale(axis, -imp)), true);
    }
  }

  private drainEvents(): void {
    this.events.drainCollisionEvents((h1, h2, started) => {
      const a = this.colliders.get(h1);
      const b = this.colliders.get(h2);
      if (!a || !b) return;
      const [area, other] = a.area ? [a, b] : b.area ? [b, a] : [null, null];
      if (!area || !other || !area.entity || !other.entity || area.entity === other.entity) return;
      this.env?.overlapEvents.push({ a: area.entity.id, b: other.entity.id, change: started ? "enter" : "exit" });
    });
  }

  /** CharacterBodyRunner._physics_process: gravity, the speed clamp, the slide, then the writeback. */
  private moveCharacter(e: Entity, ch: CharacterBody, dt: number): void {
    this.syncCharacterVelocity(e, ch);
    let yVel = toFloat(e.getState("y_velocity", 0));
    if (Math.trunc(toFloat(e.getState("on_floor", 1))) === 0) yVel -= toFloat(e.getState("gravity", CHARACTER_GRAVITY)) * dt;
    ch.vel[1] = yVel;
    e.state.y_velocity = yVel;
    clampSpeed(e, ch.vel);
    const maxStep = toFloat(e.getState("max_step_height", 0));
    if (maxStep > 0) ch.kcc.enableAutostep(maxStep, 0.05, false);
    else ch.kcc.disableAutostep();
    const desired: V3 = [ch.vel[0] * dt, ch.vel[1] * dt, ch.vel[2] * dt];
    ch.kcc.computeColliderMovement(ch.collider, vec(desired), RAPIER.QueryFilterFlags.EXCLUDE_SENSORS, undefined, (c) => {
      const info = this.colliders.get(c.handle);
      return !!info && !info.area && info.entity !== e && (info.layer & ch.mask) !== 0;
    });
    const mv = ch.kcc.computedMovement();
    const t = ch.body.translation();
    const next: V3 = [t.x + mv.x, t.y + mv.y, t.z + mv.z];
    let grounded = ch.kcc.computedGrounded();
    // A vertical move that a ceiling or a floor blocks keeps the speed that
    // the slide left. A skin or snap correction adds no speed, as in move_and_slide.
    if (desired[1] > 0 && mv.y < desired[1] - 1e-6) ch.vel[1] = Math.max(mv.y, 0) / dt;
    else if (desired[1] < 0 && mv.y > desired[1] + 1e-6) ch.vel[1] = Math.min(mv.y, 0) / dt;
    const floorY = e.getState("floor_y", null);
    if (floorY !== null && next[1] <= toFloat(floorY)) {
      next[1] = toFloat(floorY);
      grounded = true;
    }
    e.state.on_floor = grounded ? 1 : 0;
    if (grounded && ch.vel[1] < 0) {
      ch.vel[1] = 0;
      e.state.y_velocity = 0;
    } else e.state.y_velocity = ch.vel[1];
    ch.body.setNextKinematicTranslation(vec(next));
    e.state.position = new Vec3(next[0], next[1], next[2]);
    ch.pushed = posKey(e);
  }

  /** CharacterBodyRunner.tick_headless: the speed clamp, then position += velocity × dt. */
  tickCharactersHeadless(dt: number): void {
    for (const [e, ch] of this.characters) {
      this.syncCharacterVelocity(e, ch);
      clampSpeed(e, ch.vel);
      const p = position3(e);
      const next: V3 = [p[0] + ch.vel[0] * dt, p[1] + ch.vel[1] * dt, p[2] + ch.vel[2] * dt];
      e.state.position = new Vec3(next[0], next[1], next[2]);
      ch.body.setTranslation(vec(next), false);
      ch.pushed = posKey(e);
    }
  }

  /** PhysicsBodyBuilder.sync_body_velocity: a 2D velocity keeps the body's vertical speed. */
  private syncCharacterVelocity(e: Entity, ch: CharacterBody): void {
    const v = e.state.velocity;
    const key = velKey(v);
    if (key === ch.velKey) return;
    ch.velKey = key;
    if (v instanceof Vec2) ch.vel = [v.x, ch.vel[1], v.y];
    else if (v instanceof Vec3) ch.vel = [v.x, v.y, v.z];
  }

  /** Entity.set_position and set_velocity move the attached body (sync_body_transform, sync_body_velocity). */
  private pushMovedBodies(): void {
    for (const [e, s] of this.simple) {
      const key = posKey(e);
      if (key !== s.pushed) {
        s.pushed = key;
        const p = vec(position3(e));
        if (s.kind === "kinematic") s.body.setNextKinematicTranslation(p);
        else s.body.setTranslation(p, true);
      }
      if (s.kind === "rigid") this.pushVelocity(e, s.body);
    }
    for (const [e, ch] of this.characters) {
      const key = posKey(e);
      if (key === ch.pushed) continue;
      ch.pushed = key;
      ch.body.setTranslation(vec(position3(e)), false);
    }
  }

  private pushVelocity(e: Entity, body: RAPIER.RigidBody): void {
    const s = this.simple.get(e);
    const v = e.state.velocity;
    const key = velKey(v);
    if (!s || key === s.vel || key === "") return;
    s.vel = key;
    const cur = body.linvel();
    if (v instanceof Vec2) body.setLinvel({ x: v.x, y: cur.y, z: v.y }, true);
    else if (v instanceof Vec3) body.setLinvel({ x: v.x, y: v.y, z: v.z }, true);
  }

  private readPoses(ab: Articulated): void {
    const ownerPose = new Map<string, Pose>();
    for (const [name, b] of ab.bodies) {
      const t = b.translation();
      ownerPose.set(name, { p: [t.x, t.y, t.z], q: rotOf(b) });
    }
    for (const [name, o] of ab.owner) ab.poses.set(name, poseMul(ownerPose.get(o)!, ab.inOwner.get(name)!));
  }

  /** The host bodies and joints of an entity, for tests. */
  counts(e: Entity): { bodies: number; joints: number } {
    const ab = this.articulated.get(e);
    if (ab) return { bodies: ab.bodies.size, joints: ab.joints.length };
    return { bodies: this.simple.has(e) || this.characters.has(e) ? 1 : 0, joints: 0 };
  }

  linkPoses(e: Entity): Map<string, Pose> | null {
    return this.articulated.get(e)?.poses ?? null;
  }
}

// --------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------

/** A fixed child merges into its parent body, unless it sets its own material. */
function merges(j: Dict, links: Dict): boolean {
  if (String(j.type) !== "fixed") return false;
  const child = links[String(j.child)];
  return !(isDict(child) && ("friction" in child || "restitution" in child));
}

/** _build_collision_shape_node: the lift that puts the shape base at the body origin. */
function autoLift(shape: Dict): number {
  switch (String(shape.type ?? "")) {
    case "sphere":
      return toFloat(shape.radius ?? 0.5);
    case "capsule":
      return toFloat(shape.height ?? 1.8) / 2;
    case "cylinder":
      return toFloat(shape.height ?? 1.0) / 2;
  }
  return 0;
}

function clampSpeed(e: Entity, v: V3): void {
  const maxS = e.getState("max_speed", null);
  if (maxS === null) return;
  const m = toFloat(maxS);
  const l = len(v);
  if (l > m && l > 0) for (let i = 0; i < 3; i++) v[i] = (v[i] / l) * m;
}

function position3(e: Entity): V3 {
  const p = e.state.position;
  if (p instanceof Vec3) return [p.x, p.y, p.z];
  if (p instanceof Vec2) return [p.x, 0, p.y];
  return [0, 0, 0];
}

function posKey(e: Entity): string {
  return position3(e).join(",");
}

function velKey(v: unknown): string {
  if (v instanceof Vec2) return `${v.x},${v.y}`;
  if (v instanceof Vec3) return `${v.x},${v.y},${v.z}`;
  return "";
}

/** PhysicsBodyBuilder._entity_yaw: state.yaw (or state.facing) plus mesh_yaw_offset. */
function entityYaw(e: Entity): number {
  const raw = e.getState("yaw", null) ?? e.getState("facing", null);
  if (raw === null) return 0;
  return toFloat(raw) + toFloat(e.properties.mesh_yaw_offset ?? 0);
}

/** state.scale as [x, y, z], as _apply_state_scale_to_body reads it. */
function stateScale(e: Entity): V3 {
  const s = e.getState("scale", null);
  if (typeof s === "number") return [s, s, s];
  if (s instanceof Vec3) return [s.x, s.y, s.z];
  if (Array.isArray(s) && s.length === 3) return [toFloat(s[0]), toFloat(s[1]), toFloat(s[2])];
  if (Array.isArray(s) && s.length === 2) return [toFloat(s[0]), toFloat(s[0]), toFloat(s[1])];
  return [1, 1, 1];
}

function vecOr(v: unknown, d: V3): V3 {
  if (Array.isArray(v) && v.length >= 3) return [toFloat(v[0]), toFloat(v[1]), toFloat(v[2])];
  if (v instanceof Vec3) return [v.x, v.y, v.z];
  return [...d];
}

const vec = (v: V3) => ({ x: v[0], y: v[1], z: v[2] });
const quat = (q: Q) => ({ x: q[0], y: q[1], z: q[2], w: q[3] });
const dot = (a: V3, b: V3) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a: V3, b: V3): V3 => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const len = (a: V3) => Math.hypot(a[0], a[1], a[2]);
const scale = (a: V3, k: number): V3 => [a[0] * k, a[1] * k, a[2] * k];
function normalize(a: V3): V3 {
  const l = len(a);
  return l > 0 ? scale(a, 1 / l) : [0, 0, 0];
}
/** wrapf(x, -π, π). */
function wrap(x: number): number {
  const r = x - 2 * Math.PI * Math.floor((x + Math.PI) / (2 * Math.PI));
  return r;
}

function rotOf(b: RAPIER.RigidBody): Q {
  const r = b.rotation();
  return [r.x, r.y, r.z, r.w];
}

/** The world inverse inertia of a body times a vector. */
function invInertia(b: RAPIER.RigidBody, v: V3): V3 {
  const m = b.effectiveWorldInvInertia();
  // SdpMatrix3 stores the upper triangle: m11 m12 m13 m22 m23 m33.
  const e = m.elements;
  return [e[0] * v[0] + e[1] * v[1] + e[2] * v[2], e[1] * v[0] + e[3] * v[1] + e[4] * v[2], e[2] * v[0] + e[4] * v[1] + e[5] * v[2]];
}

export function qMul(a: Q, b: Q): Q {
  return [
    a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
    a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
    a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
    a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
  ];
}
const qConj = (q: Q): Q => [-q[0], -q[1], -q[2], q[3]];
export function qRotate(q: Q, v: V3): V3 {
  const r = qMul(qMul(q, [v[0], v[1], v[2], 0]), qConj(q));
  return [r[0], r[1], r[2]];
}
const yawQuat = (yaw: number): Q => qAxisAngle([0, 1, 0], yaw);
function poseMul(a: Pose, b: Pose): Pose {
  const r = qRotate(a.q, b.p);
  return { p: [a.p[0] + r[0], a.p[1] + r[1], a.p[2] + r[2]], q: qMul(a.q, b.q) };
}
function poseInv(a: Pose): Pose {
  const qi = qConj(a.q);
  const r = qRotate(qi, a.p);
  return { p: [-r[0], -r[1], -r[2]], q: qi };
}
function poseApply(a: Pose, v: V3): V3 {
  const r = qRotate(a.q, v);
  return [a.p[0] + r[0], a.p[1] + r[1], a.p[2] + r[2]];
}
/** Basis.get_euler().y in Godot's default order (YXZ): atan2(m02, m22). */
export function eulerYawYXZ(q: Q): number {
  const [x, y, z, w] = q;
  const m12 = 2 * (y * z - w * x);
  if (m12 >= 1 || m12 <= -1) {
    // Gimbal lock: Godot reads atan2(-m20, m00).
    return Math.atan2(-2 * (x * z - w * y), 1 - 2 * (y * y + z * z));
  }
  return Math.atan2(2 * (x * z + w * y), 1 - 2 * (x * x + y * y));
}
/** ArticulatedBody._basis_z: an orthonormal basis whose z is the given axis. */
function basisZ(zAxis: V3): { x: V3; y: V3; z: V3 } {
  const z = normalize(zAxis);
  const up: V3 = Math.abs(dot(z, [0, 1, 0])) < 0.99 ? [0, 1, 0] : [1, 0, 0];
  const x = normalize(cross(up, z));
  return { x, y: cross(z, x), z };
}
