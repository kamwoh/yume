// Animation state rules (animation_director.gd) and library clips (animation_translator.gd).
import { test } from "node:test";
import assert from "node:assert/strict";
import * as THREE from "three";
import { Entity } from "../src/entity.ts";
import { Vec2 } from "../src/value.ts";
import { clipAliases, hasDefault, libraryClip, pickState } from "../src/viewer/anim.ts";

const RULES = [
  { if_state_eq: { on_floor: 0 }, state: "jump" },
  { if_velocity_gt: 4.5, state: "run", clip_alias: "Running" },
  { if_velocity_gt: 0.1, state: "walk", clip_alias: "Walking" },
  { if_tag: "sleepy", state: "sleep" },
  { default: "idle", clip_alias: "Idle" },
];

test("the first rule that matches picks the state, and default ends the list", () => {
  const e = Entity.create({ id: "p", tags: [], state_init: { on_floor: 1 } }, "p");
  assert.equal(pickState(RULES, e), "idle");
  e.state.velocity = new Vec2(1, 0);
  assert.equal(pickState(RULES, e), "walk");
  e.state.velocity = new Vec2(5, 0);
  assert.equal(pickState(RULES, e), "run");
  e.state.on_floor = 0;
  assert.equal(pickState(RULES, e), "jump", "an earlier rule wins");
  e.state.on_floor = 1.0;
  e.state.velocity = new Vec2(0, 0);
  e.addTag("sleepy");
  assert.equal(pickState(RULES, e), "sleep");
  assert.equal(pickState([{ if_state_in: { mood: ["a", "b"] }, state: "m" }, { default: "x" }], Entity.create({ id: "q", state_init: { mood: "b" } }, "q")), "m");
});

test("clip aliases map states to GLB clip names, and the default is required", () => {
  assert.deepEqual([...clipAliases(RULES)], [["run", "Running"], ["walk", "Walking"], ["idle", "Idle"]]);
  assert.equal(hasDefault(RULES), true);
  assert.equal(hasDefault(RULES.slice(0, 2)), false);
});

test("a library clip spaces keys over the duration, adds translation and replaces rotation", () => {
  const root = new THREE.Group();
  const wing = new THREE.Group();
  wing.name = "left_wing";
  wing.position.set(0, 1, 0);
  root.add(wing);
  const clip = libraryClip("fly", { duration: 0.4, tracks: [{ piece: "left_wing", rotation_z: [0, 0.7, 0], translation_y: [0, 0.5] }] }, root)!;
  assert.equal(clip.duration, 0.4);
  const rot = clip.tracks.find((t) => t.name === "left_wing.quaternion")!;
  // three.js keeps key times as Float32.
  assert.ok([0, 0.2, 0.4].every((t, i) => Math.abs(rot.times[i] - t) < 1e-6) && rot.times.length === 3, "three keys over 0.4 s");
  const q = new THREE.Quaternion().fromArray([...rot.values].slice(4, 8));
  assert.ok(Math.abs(new THREE.Euler().setFromQuaternion(q, "YXZ").z - 0.7) < 1e-6, "the middle key turns z to 0.7");
  const pos = clip.tracks.find((t) => t.name === "left_wing.position")!;
  assert.ok([0, 1, 0, 0, 1.5, 0].every((v, i) => Math.abs(pos.values[i] - v) < 1e-6), "translation adds to the rest position");
});
