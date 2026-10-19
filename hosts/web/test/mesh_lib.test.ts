import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as THREE from "three";
import { MeshLib } from "../src/viewer/mesh_lib.ts";
import { dayFactor, is3D, sunDirectionAt } from "../src/viewer/render3d.ts";

const near = (a: number, b: number, msg: string) => assert.ok(Math.abs(a - b) < 1e-6, `${msg}: ${a} != ${b}`);

function build(primitives: unknown[], params = {}): THREE.Group {
  const g = new THREE.Group();
  new MeshLib({ meshes: {} }).buildInto(g, primitives, params);
  return g;
}

function bounds(o: THREE.Object3D): THREE.Box3 {
  o.updateMatrixWorld(true);
  return new THREE.Box3().setFromObject(o);
}

// Godot's mesh shapes and axes (mesh_lib.gd _primitive_mesh), ADR 0095 phase 2.
test("a capsule's height includes both caps, as Godot's CapsuleMesh", () => {
  const b = bounds(build([{ op: "capsule", radius: 0.3, height: 2 }]));
  near(b.max.y - b.min.y, 2, "capsule height");
});

test("a plane faces +Y and a quad faces +Z", () => {
  const plane = bounds(build([{ op: "plane", size: [2, 4] }]));
  near(plane.max.y - plane.min.y, 0, "plane is flat in y");
  near(plane.max.z - plane.min.z, 4, "plane depth");
  const quad = bounds(build([{ op: "quad", size: [2, 4] }]));
  near(quad.max.z - quad.min.z, 0, "quad is flat in z");
  near(quad.max.y - quad.min.y, 4, "quad height");
});

test("a torus lies in XZ around the Y axis", () => {
  const b = bounds(build([{ op: "torus", inner_radius: 0.3, outer_radius: 0.5 }]));
  near(b.max.x - b.min.x, 1, "torus width");
  near(b.max.y - b.min.y, 0.2, "torus thickness");
});

test("a prism has its apex at the top center", () => {
  const g = build([{ op: "prism", size: [2, 1, 3] }]);
  const b = bounds(g);
  near(b.max.y - b.min.y, 1, "prism height");
  near(b.max.z - b.min.z, 3, "prism depth");
  near(b.min.z, -1.5, "prism is centered in z");
});

test("pos, $params and rotation_deg (Euler YXZ) place a part", () => {
  const g = build([{ op: "box", pos: [1, 2, 3], size: "$s", rotation_deg: [0, 90, 0], color: "$c" }], { s: [2, 1, 1], c: "#ff0000" });
  const b = bounds(g);
  near(b.max.x - b.min.x, 1, "rotated box width");
  near(b.max.z - b.min.z, 2, "rotated box depth");
  near((b.max.y + b.min.y) / 2, 2, "box center y");
  const mat = (g.children[0] as THREE.Mesh).material as THREE.MeshStandardMaterial;
  assert.equal(mat.color.getHexString(), "ff0000");
});

test("a pivot part hangs under a joint node at pos + pivot", () => {
  const g = build([{ op: "cylinder", name: "arm", pos: [0, 1, 0], height: 0.5, radius: 0.1, pivot: "top" }]);
  const joint = g.getObjectByName("arm")!;
  near(joint.position.y, 1.25, "joint y");
  near(joint.children[0].position.y, -0.25, "mesh hangs at -pivot");
});

test("every op in the tracked meshes.json builds", () => {
  const lib = JSON.parse(readFileSync(new URL("../../../godot/data/meshes.json", import.meta.url), "utf8"));
  const ml = new MeshLib(lib);
  for (const [name, def] of Object.entries(lib.meshes as Record<string, { primitives: unknown[] }>)) {
    const g = new THREE.Group();
    ml.buildInto(g, def.primitives, MeshLib.mergeParams(def as never, {}));
    assert.equal(g.children.length, def.primitives.length, `${name}: one node for each primitive`);
  }
});

test("the 3D renderer follows the camera mode", () => {
  assert.equal(is3D({ camera: { mode: "first_person_3d" } }), true);
  assert.equal(is3D({ camera: { center_on_tag: "floor" } }), false);
});

test("the sun points straight down at noon and along +x at 6:00 (lighting_director.gd)", () => {
  const noon = sunDirectionAt(12);
  near(noon.y, -1, "noon y");
  const six = sunDirectionAt(6);
  near(six.x, 1, "6:00 x");
  near(dayFactor(12), 1, "day factor at noon");
  near(dayFactor(0), 0, "day factor at midnight");
});

test("a lathe spins its profile about Y and closes it to the axis", () => {
  const g = build([{ op: "lathe", profile: [[0.5, 0], [0.3, 1]], segments: 8 }]);
  const box = new THREE.Box3().setFromObject(g);
  assert.ok(Math.abs(box.max.x - 0.5) < 1e-6 && Math.abs(box.max.y - 1) < 1e-6 && Math.abs(box.min.y) < 1e-6, "radius 0.5, from y 0 to 1");
});

test("an extrude is centered on pos along Z, and a sweep follows its path", () => {
  const e = new THREE.Box3().setFromObject(build([{ op: "extrude", polygon: [[0, 0], [1, 0], [0, 1]], depth: 0.4 }]));
  assert.ok(Math.abs(e.min.z + 0.2) < 1e-6 && Math.abs(e.max.z - 0.2) < 1e-6, "depth 0.4 centered on z 0");
  const s = new THREE.Box3().setFromObject(build([{ op: "sweep", polygon: [[-0.1, -0.1], [0.1, -0.1], [0, 0.1]], path: [[0, 0, 0], [2, 0, 0]] }]));
  assert.ok(s.max.x > 1.9 && s.min.x < 0.1, "the swept shape spans the 2 m path");
});

test("the 3D viewer lists the lighting fields it draws, all from LightingDirector.FIELDS", async () => {
  const { LIGHTING_DONE } = await import("../src/viewer/render3d.ts");
  const gd = readFileSync(new URL("../../../godot/scripts/engine/directors/lighting_director.gd", import.meta.url), "utf8");
  const m = /"lighting": \[([^\]]*)\]/.exec(gd);
  assert.ok(m, "LightingDirector.FIELDS has a lighting list");
  const fields = m![1].split(",").map((x) => x.trim().replace(/"/g, ""));
  for (const f of LIGHTING_DONE) assert.ok(fields.includes(f), `'${f}' is a lighting field of the reference`);
  assert.ok(fields.some((f) => !LIGHTING_DONE.includes(f)), "the others get a load note (glow, ssao, reflection_probes)");
});
