// The effect vocabulary of the spec (tools/validators/engine_vocabulary.json)
// against the TypeScript host. A missing effect raises effect.unsupported_host
// as an error, and the scenario runner prints it. This test lists each one.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { apply } from "../src/effects.ts";
import { MemoryFiles } from "../src/files.ts";
import { World } from "../src/world.ts";

const repo = join(dirname(fileURLToPath(import.meta.url)), "../../..");

test("the host handles each effect of the engine vocabulary", () => {
  const vocab = JSON.parse(readFileSync(join(repo, "tools/validators/engine_vocabulary.json"), "utf8"));
  const missing: string[] = [];
  for (const type of Object.keys(vocab.effects)) {
    const w = new World("game", new MemoryFiles({ "game/scene.json": "{}" }), "lib");
    w.load();
    w.env.errors.length = 0;
    apply({ type }, w.env, { _rule_id: "vocabulary_test" });
    if (w.env.errors.some((e) => e.code === "effect.unsupported_host")) missing.push(type);
  }
  assert.deepEqual(missing, [], `effects not in the host: ${missing.join(", ")}`);
});

test("a missing effect raises effect.unsupported_host as an error", () => {
  const w = new World("game", new MemoryFiles({ "game/scene.json": "{}" }), "lib");
  w.load();
  apply({ type: "no_such_effect" }, w.env, {});
  const e = w.env.errors.find((x) => x.code === "effect.unsupported_host");
  assert.equal(e?.severity, "error");
});
