import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { bundle } from "../src/bundle.ts";
import { MemoryFiles } from "../src/files.ts";
import { runGame } from "../src/scenario.ts";

const dataRoot = fileURLToPath(new URL("../../../godot/data", import.meta.url));

// The viewer loads a game from a bundle into MemoryFiles, not from disk.
// The sokoban scenarios must pass on that path too (ADR 0095 phase 2).
test("sokoban passes from the browser bundle", () => {
  const b = bundle(dataRoot, "demo_sokoban");
  assert.ok(b, "demo_sokoban bundle");
  const r = runGame("game", new MemoryFiles(b), false, "lib");
  assert.deepEqual(r.failures, []);
  assert.equal(r.passed, 14);
});

test("a bundle refuses a path outside the data folder", () => {
  assert.equal(bundle(dataRoot, "../hosts"), null);
});
