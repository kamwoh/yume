// The rules files of a game: the shape that each host accepts.
import { test } from "node:test";
import assert from "node:assert/strict";
import { MemoryFiles } from "../src/files.ts";
import { World } from "../src/world.ts";

// Empirical case 2026-10-19: aldenmere's tutorial.json holds only overlays.
// Godot reads data.get("rules", []), so the file loads with no rules. The
// TypeScript host raised rule.list_not_array on every scenario.
test("a rules file with no `rules` key loads with no error, as in the reference", () => {
  const w = new World("game", new MemoryFiles({ "game/tutorial.json": JSON.stringify({ overlays: [{ id: "intro" }] }) }), "lib");
  w.load();
  assert.deepEqual(w.env.errors.filter((e) => e.code === "rule.list_not_array"), []);
});

test("a `rules` key that is not an array still raises rule.list_not_array", () => {
  const w = new World("game", new MemoryFiles({ "game/tutorial.json": JSON.stringify({ rules: { a: 1 } }) }), "lib");
  w.load();
  assert.equal(w.env.errors.filter((e) => e.code === "rule.list_not_array").length, 1);
});
