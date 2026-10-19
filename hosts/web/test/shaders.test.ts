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
