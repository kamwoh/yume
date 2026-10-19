// The library shader ports (shaders.ts): the uniforms they take from shader_params.
import { test } from "node:test";
import assert from "node:assert/strict";
import * as THREE from "three";
import { groundMaterial, skyCloudsMaterial } from "../src/viewer/shaders.ts";

test("ground_biome_displace takes its biome table, padded to 8, and its textures", () => {
  const asked: string[] = [];
  const mat = groundMaterial(
    "ground_biome_displace",
    { biome_count: 2, biome_key: [[0.6, 0.8, 0.4], [0.5, 0.4, 0.2]], biome_albedo: [[0.2, 0.4, 0.1], [0.2, 0.1, 0.04]], biome_roughness: [0.95, 0.92], biome_map: "a.png", grass_detail: "@lib/g.png", grass_biome_index: 0 },
    156,
    (p) => {
      asked.push(p);
      return new THREE.Texture();
    },
  )!;
  const u = mat.userData.uniforms;
  assert.equal(u.biome_count.value, 2);
  assert.equal(u.biome_key.value.length, 8, "the GLSL array has 8 slots");
  assert.deepEqual(u.biome_albedo.value[1].toArray(), [0.2, 0.1, 0.04], "biome_albedo has no source_color hint: no conversion");
  assert.deepEqual(u.biome_roughness.value.slice(0, 3), [0.95, 0.92, 0]);
  assert.equal(u.plane_size.value, 156);
  assert.deepEqual(asked, ["a.png", "@lib/g.png"]);
  assert.equal(groundMaterial("toon", {}, 10, () => null), null, "an unported shader gives no material");
});

test("sky_clouds takes shader_params over its defaults, with colors as sRGB", () => {
  const mat = skyCloudsMaterial({ cloud_coverage: 0.35, sky_top_color: [0.32, 0.48, 0.72] });
  assert.equal(mat.uniforms.cloud_coverage.value, 0.35);
  assert.equal(mat.uniforms.cloud_scale.value, 5.0, "a default");
  const c = mat.uniforms.sky_top_color.value as THREE.Color;
  assert.ok(Math.abs(c.r - new THREE.Color().setRGB(0.32, 0.48, 0.72, THREE.SRGBColorSpace).r) < 1e-6, "source_color: sRGB to linear");
});

test("water is a plane at its level, or a box whose top face is at its level", async () => {
  const { buildWater } = await import("../src/viewer/water.ts");
  const plane = buildWater({ mesh: { size: [40, 20], level: -1.5, shader: "water_stylized" } }, () => null)!;
  assert.equal(plane.position.y, -1.5);
  const box = buildWater({ mesh: { size: [40, 40], level: -2, box_depth: 8, shader: "water_stylized", shader_params: { depth_fade_m: 1.2 } } }, () => null)!;
  box.updateMatrixWorld(true);
  const b = new THREE.Box3().setFromObject(box);
  assert.ok(Math.abs(b.max.y + 2) < 1e-6 && Math.abs(b.min.y + 10) < 1e-6, "the top face at -2, 8 m deep");
  const u = (box.material as THREE.Material).userData.uniforms;
  assert.equal(u.depth_fade_m.value, 1.2, "a shader param");
  assert.equal(u.fresnel_power.value, 3.5, "a default");
  assert.ok(u.water_normal_tex.value instanceof THREE.DataTexture, "the generated noise normal map");
  assert.equal(buildWater({ mesh: { shader: "other" } }, () => null), null);
});
