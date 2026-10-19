// The physics host (ADR 0095 phase 3). Ports of test_articulated_body and
// test_sensor_array in test_runner.gd, plus the character and area paths.
// Motion is host-defined (ADR 0086), so each check is a guarantee with a
// margin, as in the reference.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { MemoryFiles } from "../src/files.ts";
import { PHYSICS_DT } from "../src/live.ts";
import { GroundHeight } from "../src/heightmap.ts";
import { checkArticulation, translateBlocksMotion } from "../src/physics.ts";
import { RapierPhysics, initRapier } from "../src/physics_rapier.ts";
import { type Dict, Vec2, Vec3 } from "../src/value.ts";
import { World } from "../src/world.ts";

const LAYERS = readFileSync(fileURLToPath(new URL("../../../godot/data/lib/physics/layers.json", import.meta.url)), "utf8");

const ROVER: Dict = {
  body_type: "articulated",
  root: "chassis",
  links: {
    chassis: { shape: { type: "box", size: [0.3, 0.08, 0.4] }, mass: 2.0 },
    wheel_l: { shape: { type: "cylinder", radius: 0.1, height: 0.04, axis: "x" }, mass: 0.3, friction: 1.0 },
    wheel_r: { shape: { type: "cylinder", radius: 0.1, height: 0.04, axis: "x" }, mass: 0.3, friction: 1.0 },
    caster: { shape: { type: "sphere", radius: 0.05 }, mass: 0.1, friction: 0.0 },
    mast: { shape: { type: "box", size: [0.04, 0.2, 0.04] }, mass: 0.1 },
  },
  joints: [
    { type: "hinge", parent: "chassis", child: "wheel_l", at: [-0.19, -0.05, -0.1], axis: [-1, 0, 0], motor: { target_velocity: "self.state.left_cmd", max_torque: 3.0 }, report: "wheel_l" },
    { type: "hinge", parent: "chassis", child: "wheel_r", at: [0.19, -0.05, -0.1], axis: [-1, 0, 0], motor: { target_velocity: "self.state.right_cmd", max_torque: 3.0 }, report: "wheel_r" },
    { type: "ball", parent: "chassis", child: "caster", at: [0, -0.1, 0.15] },
    { type: "fixed", parent: "chassis", child: "mast", at: [0, 0.14, 0.1] },
  ],
};

const box = (layer: string, size: number[], offset: number[] = [0, 0, 0]) => ({
  body_type: "static",
  collision_layer: [layer],
  collision_mask: "all",
  collision_shape: { type: "box", size, offset },
});

/** A world of the given defs and instances on a floor slab, with the Rapier host. */
function makeWorld(defs: Dict[], instances: Dict[]): World {
  const game = {
    definitions: [{ id: "floor_slab", physics: box("floor", [20, 1, 20], [0, -0.5, 0]) }, ...defs],
    initial_instances: [{ def: "floor_slab", id: "floor_slab", position: [0, 0, 0] }, ...instances],
  };
  const files = new MemoryFiles({
    "game/scene.json": JSON.stringify({ tick_seconds: PHYSICS_DT }),
    "game/entities/all.json": JSON.stringify(game),
    "lib/physics/layers.json": LAYERS,
  });
  const w = new World("game", files, "lib");
  w.physicsFactory = (layers, bounds) => new RapierPhysics(layers, bounds);
  w.load();
  return w;
}

/** One tick, then one physics step: step_runner._advance for a world with an articulated body. */
function ticks(w: World, n: number): void {
  for (let i = 0; i < n; i++) {
    w.advanceOneTick();
    w.env.physics!.step(PHYSICS_DT);
  }
}

const pos = (w: World, id: string) => w.env.entities.get(id)!.state.position as Vec3;
const num = (w: World, id: string, f: string) => Number(w.env.entities.get(id)!.state[f]);

test("checkArticulation names each defect", () => {
  assert.equal(checkArticulation(ROVER), "");
  const clone = () => JSON.parse(JSON.stringify(ROVER));
  const badRoot = clone();
  badRoot.root = "nope";
  assert.notEqual(checkArticulation(badRoot), "");
  const twoParents = clone();
  twoParents.joints.push({ type: "ball", parent: "wheel_r", child: "caster" });
  assert.notEqual(checkArticulation(twoParents), "");
  const loose = clone();
  loose.links.spare = { shape: { type: "sphere", radius: 0.1 } };
  assert.notEqual(checkArticulation(loose), "");
  const slider = clone();
  slider.joints[0].type = "slider";
  assert.notEqual(checkArticulation(slider), "");
});

test("a rover builds, drives straight, turns in place, and frees", async () => {
  await initRapier();
  const slick = JSON.parse(JSON.stringify(ROVER));
  slick.links.mast.friction = 0.0;
  const w = makeWorld(
    [
      { id: "rover", tags: ["robot"], state_init: { left_cmd: 0.0, right_cmd: 0.0 }, physics: ROVER },
      { id: "slick", tags: [], physics: slick },
    ],
    [
      { def: "rover", id: "rover_1", position: [0, 0.15, 0] },
      { def: "slick", id: "slick_1", position: [5, 0.15, 0] },
    ],
  );
  const ph = w.env.physics as RapierPhysics;
  const rover = w.env.entities.get("rover_1")!;
  assert.deepEqual(ph.counts(rover), { bodies: 4, joints: 3 }, "the fixed mast merges into the chassis");
  // A fixed child with its own friction keeps its own body and a locked joint.
  assert.deepEqual(ph.counts(w.env.entities.get("slick_1")!), { bodies: 5, joints: 4 });
  const poses = ph.linkPoses(rover)!;
  const m = poses.get("mast")!.p;
  const c = poses.get("chassis")!.p;
  assert.ok(Math.hypot(m[0] - c[0], m[1] - c[1] - 0.14, m[2] - c[2] - 0.1) < 0.001, "the mast sits at its 'at' offset");

  ticks(w, 20);
  const p0 = pos(w, "rover_1");
  rover.state.left_cmd = 6.0;
  rover.state.right_cmd = 6.0;
  ticks(w, 60);
  const p1 = pos(w, "rover_1");
  assert.ok(p0.z - p1.z > 0.3, `equal forward speeds move it toward -Z (moved ${(p0.z - p1.z).toFixed(3)} m)`);
  assert.ok(Math.abs(p1.x - p0.x) < 0.1, `equal speeds keep it straight (x drift ${(p1.x - p0.x).toFixed(3)} m)`);
  assert.ok(Math.abs(p1.y - 0.15) < 0.05, `the chassis stays on its wheels (y ${p1.y.toFixed(3)})`);
  assert.ok(num(w, "rover_1", "wheel_l_angle") > 3.0, "the left wheel angle counts whole turns");
  assert.ok(num(w, "rover_1", "wheel_r_speed") > 4.0, "the right wheel speed reads back");
  assert.ok(rover.state.velocity instanceof Vec3, "state.velocity is the root velocity");

  // Opposite speeds turn it left in place, about the midpoint of its axle.
  const axle = () => {
    const l = ph.linkPoses(rover)!.get("wheel_l")!.p;
    const r = ph.linkPoses(rover)!.get("wheel_r")!.p;
    return [(l[0] + r[0]) / 2, (l[2] + r[2]) / 2];
  };
  const a1 = axle();
  const yaw0 = num(w, "rover_1", "yaw");
  rover.state.left_cmd = -4.0;
  rover.state.right_cmd = 4.0;
  ticks(w, 60);
  const a2 = axle();
  assert.ok(num(w, "rover_1", "yaw") - yaw0 > 0.5, "left back and right forward turn it left");
  const drift = Math.hypot(a2[0] - a1[0], a2[1] - a1[1]);
  assert.ok(drift < 0.05, `the turn is in place (the axle midpoint moved ${drift.toFixed(3)} m)`);

  // A remove effect frees every body and joint.
  w.env.physics!.remove(rover);
  w.env.entities.delete("rover_1");
  assert.deepEqual(ph.counts(rover), { bodies: 0, joints: 0 });
  ticks(w, 1);
});

test("ray and lidar sensors read distances, masks and angles", async () => {
  await initRapier();
  const w = makeWorld(
    [
      { id: "wall", tags: [], physics: box("wall", [4, 1, 0.1]) },
      {
        id: "probe",
        tags: [],
        sensors: [
          { type: "ray", direction: [0, 0, -1], range: 5.0, report: "front" },
          { type: "ray", direction: [0, 0, 1], range: 5.0, report: "back" },
          { type: "ray", direction: [0, 0, -1], range: 5.0, report: "blind", collision_mask: ["npc"] },
          { type: "lidar", rays: 4, fov: 2 * Math.PI, range: 5.0, report: "lidar" },
        ],
      },
      { id: "rover", tags: [], physics: ROVER, sensors: [{ type: "ray", link: "chassis", direction: [0, 0, -1], range: 5.0, report: "front" }] },
    ],
    [
      { def: "wall", id: "wall_1", position: [0, 0.5, -2] },
      { def: "probe", id: "probe_1", position: [0, 0.3, 0] },
      { def: "rover", id: "rover_1", position: [1, 0.15, 0] },
    ],
  );
  // A new body joins the ray queries at the next physics step, in Godot too (its test waits two frames).
  w.env.physics!.step(PHYSICS_DT);
  w.advanceOneTick();
  assert.ok(Math.abs(num(w, "probe_1", "front_distance") - 1.95) < 0.05, "a wall 1.95 m ahead reads 1.95 ± 0.05");
  assert.equal(num(w, "probe_1", "front_hit"), 1);
  assert.equal(num(w, "probe_1", "back_distance"), 5.0, "nothing in range reads exactly the range");
  assert.equal(num(w, "probe_1", "back_hit"), 0);
  assert.equal(num(w, "probe_1", "blind_distance"), 5.0, "collision_mask skips a layer it does not list");
  const ranges = w.env.entities.get("probe_1")!.state.lidar_ranges as number[];
  assert.equal(ranges.length, 4);
  assert.ok(Math.abs(num(w, "probe_1", "lidar_min") - 1.95) < 0.05, "lidar_min is the wall");
  assert.ok(Math.abs(num(w, "probe_1", "lidar_min_angle")) < 0.01, "the wall is straight ahead");
  // A sensor on a link skips the robot's own bodies.
  assert.ok(Math.abs(num(w, "rover_1", "front_distance") - 1.95) < 0.05, "a link sensor skips its own links");
  // The frame follows the entity yaw: facing -X, the wall is to the right.
  w.env.entities.get("probe_1")!.state.yaw = Math.PI / 2;
  w.advanceOneTick();
  assert.equal(num(w, "probe_1", "front_distance"), 5.0);
  assert.ok(Math.abs(num(w, "probe_1", "lidar_min_angle") + Math.PI / 2) < 0.01, "the wall is now at -π/2");
});

test("a character walks on the floor, stops at a wall, and enters an area", async () => {
  await initRapier();
  const w = makeWorld(
    [
      {
        id: "walker",
        tags: ["player"],
        state_init: { velocity: [2, 0] },
        physics: { body_type: "character", collision_shape: { type: "capsule", radius: 0.3, height: 1.6 }, collision_layer: ["player"], collision_mask: ["floor", "wall"] },
      },
      { id: "wall", tags: [], physics: box("wall", [0.2, 2, 4], [0, 1, 0]) },
      { id: "zone", tags: ["zone"], physics: { body_type: "area", collision_shape: { type: "box", size: [1, 2, 4], offset: [0, 1, 0] }, collision_mask: ["player"] } },
    ],
    [
      { def: "walker", id: "walker_1", position: [0, 0, 0] },
      { def: "wall", id: "wall_1", position: [3, 0, 0] },
      { def: "zone", id: "zone_1", position: [1.5, 0, 0] },
    ],
  );
  const ph = w.env.physics!;
  const walker = w.env.entities.get("walker_1")!;
  const enters: string[] = [];
  for (let i = 0; i < 120; i++) {
    ph.step(PHYSICS_DT);
    for (const ev of w.env.overlapEvents) if (ev.change === "enter") enters.push(`${ev.a}<-${ev.b}`);
    w.env.overlapEvents.length = 0;
  }
  const p = pos(w, "walker_1");
  assert.ok(Math.abs(p.y) < 0.05, `the floor holds the feet at y 0 (y ${p.y.toFixed(3)})`);
  assert.equal(num(w, "walker_1", "on_floor"), 1);
  assert.ok(p.x > 2.4 && p.x < 2.75, `the wall at x 2.9 stops the 0.3 m capsule (x ${p.x.toFixed(3)})`);
  assert.deepEqual(enters, ["zone_1<-walker_1"], "the area sees the walker enter once");

  // The headless path is Euler integration with no collision, as tick_headless.
  walker.state.velocity = new Vec2(2, 0);
  ph.tickCharactersHeadless(1.0);
  assert.ok(pos(w, "walker_1").x > 4.4, "tick_headless moves through the wall");
});

// Post-mortem 2026-10-19: while a character walked, the controller lifted it
// 0.1 mm for its skin gap. The host kept that lift as an upward speed, and
// the player then rose 3 mm each second, also when it stood still. Found by
// a live walk of doomarena3d in Node.
test("a character that walks, then stops, does not creep up", async () => {
  await initRapier();
  const files = new MemoryFiles({
    "game/scene.json": JSON.stringify({ tick_seconds: PHYSICS_DT }),
    "game/entities/all.json": JSON.stringify({
      definitions: [{ id: "walker", tags: ["player"], physics: { body_type: "character", collision_shape: { type: "capsule", radius: 0.15, height: 1.0 }, collision_mask: ["floor"] } }],
      initial_instances: [{ def: "walker", id: "walker_1", position: [0, 0, 0] }],
    }),
    "lib/physics/layers.json": LAYERS,
  });
  const w = new World("game", files, "lib");
  w.physicsFactory = (layers, bounds) => new RapierPhysics(layers, bounds);
  w.load();
  const ph = w.env.physics!;
  ph.addGround({ mesh: { size: [30, 30] } }, null);
  const walker = w.env.entities.get("walker_1")!;
  walker.state.velocity = new Vec2(0, -2);
  for (let i = 0; i < 90; i++) ph.step(PHYSICS_DT);
  walker.state.velocity = new Vec2(0, 0);
  ph.step(PHYSICS_DT);
  const y0 = pos(w, "walker_1").y;
  for (let i = 0; i < 300; i++) ph.step(PHYSICS_DT);
  const dy = pos(w, "walker_1").y - y0;
  assert.ok(Math.abs(dy) < 0.001, `the feet stay put (moved ${dy.toFixed(4)} m in 5 s)`);
  assert.equal(num(w, "walker_1", "y_velocity"), 0);
});

test("a heightmap ground matches sample_y, and a character stands on it", async () => {
  await initRapier();
  // A 2 × 2 heightmap over a 20 m plane: the -X edge is low, the +X edge high.
  const img = { width: 2, height: 2, red: new Float32Array([0, 1, 0, 1]) };
  const h = new GroundHeight(img, 20, 4, -0.5);
  assert.equal(h.sampleY(-10, 0), -2, "the low edge: (0 - 0.5) × 4");
  assert.equal(h.sampleY(10, 0), 2, "the high edge: (1 - 0.5) × 4");
  assert.equal(h.sampleY(0, 0), 0, "the middle is bilinear");
  assert.equal(h.colliderPoints(), 33, "at least 33 points");
  const w = makeWorld(
    [{ id: "walker", tags: ["player"], physics: { body_type: "character", collision_shape: { type: "capsule", radius: 0.3, height: 1.6 }, collision_mask: ["floor"] } }],
    [{ def: "walker", id: "walker_1", position: [5, 3, 0] }],
  );
  const ph = w.env.physics!;
  ph.addGround({ mesh: { size: [20, 20] } }, h);
  const walker = w.env.entities.get("walker_1")!;
  walker.state.on_floor = 0;
  for (let i = 0; i < 120; i++) ph.step(PHYSICS_DT);
  const y = pos(w, "walker_1").y;
  assert.ok(Math.abs(y - h.sampleY(5, 0)) < 0.1, `the feet rest on the slope at y ${h.sampleY(5, 0)} (y ${y.toFixed(3)})`);
});

test("a trimesh body waits for its faces, then holds a character", async () => {
  await initRapier();
  const w = makeWorld(
    [
      { id: "deck", tags: [], physics: { body_type: "static", collision_layer: ["floor"], collision_shape: { type: "trimesh", mesh: "assets/deck.glb" } } },
      { id: "walker", tags: ["player"], physics: { body_type: "character", collision_shape: { type: "capsule", radius: 0.3, height: 1.6 }, collision_mask: ["floor"] } },
    ],
    [
      { def: "deck", id: "deck_1", position: [0, 2, 0] },
      { def: "walker", id: "walker_1", position: [0, 4, 0] },
    ],
  );
  const ph = w.env.physics!;
  const deck = w.env.entities.get("deck_1")!;
  assert.deepEqual(ph.pendingTrimeshes().map((t) => [t.entity.id, t.mesh]), [["deck_1", "assets/deck.glb"]]);
  assert.deepEqual(ph.pendingTrimeshes(), [], "each trimesh is asked for once");
  // A 4 × 4 m quad in the GLB's native space. The body adds the entity position (y 2).
  ph.setTrimesh(deck, new Float32Array([-2, 0, -2, 2, 0, -2, 2, 0, 2, -2, 0, 2]), new Uint32Array([0, 2, 1, 0, 3, 2]));
  w.env.entities.get("walker_1")!.state.on_floor = 0;
  for (let i = 0; i < 120; i++) ph.step(PHYSICS_DT);
  const y = pos(w, "walker_1").y;
  assert.ok(Math.abs(y - 2) < 0.1, `the deck at y 2 holds the feet (y ${y.toFixed(3)})`);
});

test("a blocks_motion def becomes a static box on the wall layer", () => {
  const def = { id: "crate", tags: ["blocks_motion"], properties: { aabb_extents: [0.5, 1, 0.25], aabb_offset: [0, 1, 0] } };
  assert.deepEqual(translateBlocksMotion(def), {
    body_type: "static",
    collision_shape: { type: "box", size: [1, 2, 0.5], offset: [0, 1, 0] },
    collision_layer: ["wall"],
    collision_mask: "all",
  });
  assert.deepEqual(translateBlocksMotion({ id: "flat", tags: ["blocks_motion"], properties: { aabb_extents: [1, 1] } }), {}, "a 2D extent has no 3D body");
  const own = { body_type: "kinematic" };
  assert.equal(translateBlocksMotion({ id: "x", tags: ["blocks_motion"], physics: own }), own, "a physics block wins");
});
