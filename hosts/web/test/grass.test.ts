// Ground decoration (grass_renderer.gd): points only on the grass biome, on the displaced ground.
import { test } from "node:test";
import assert from "node:assert/strict";
import * as THREE from "three";
import { GroundHeight } from "../src/heightmap.ts";
import { buildGrass } from "../src/viewer/grass.ts";

test("flowers scatter only on the grass half of the splat map, at the ground height", () => {
  // A 4 × 1 splat map over a 20 m plane: grass, grass, dirt, dirt. _is_grass reads
  // pixel int(u × (W - 1)), so grass covers u < 2/3, that is x < 3.33.
  const g = [160, 216, 112, 255];
  const d = [138, 106, 64, 255];
  const biome = { width: 4, height: 1, data: new Uint8ClampedArray([...g, ...g, ...d, ...d]) };
  const height = new GroundHeight({ width: 1, height: 1, red: new Float32Array([1]) }, 20, 2, -0.5);
  const ground = {
    mesh: { size: [20, 20], shader_params: { grass_biome_index: 0, biome_key: [[0.627, 0.847, 0.439], [0.541, 0.416, 0.251]] } },
    flowers: { enabled: true, count: 200, radius: 9, seed: 3 },
  };
  const [im] = buildGrass(ground, biome, height) as THREE.InstancedMesh[];
  assert.ok(im.count > 50, `flowers placed (${im.count})`);
  const m = new THREE.Matrix4();
  const p = new THREE.Vector3();
  for (let i = 0; i < im.count; i++) {
    im.getMatrixAt(i, m);
    p.setFromMatrixPosition(m);
    assert.ok(p.x < 3.34, `flower ${i} is on the grass (x ${p.x.toFixed(2)})`);
    assert.ok(Math.abs(p.y - 1) < 1e-6, "on the ground: (1 - 0.5) × 2");
  }
  assert.deepEqual(buildGrass({ mesh: { shader_params: {} }, flowers: { enabled: true } }, null, null), [], "no grass biome, no decoration");
});
