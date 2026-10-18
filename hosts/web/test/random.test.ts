import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { SpecRandom } from "../src/random.ts";

const vectors = JSON.parse(
  readFileSync(new URL("../../../spec/conformance/random_vectors.json", import.meta.url), "utf8"),
);

test("the spec generator gives the reference values (ADR 0095)", () => {
  for (const c of vectors.cases) {
    const r = new SpecRandom(c.seed);
    const u = Array.from({ length: c.u32.length }, () => r.nextU32());
    assert.deepEqual(u, c.u32, `seed ${c.seed} u32`);
    const f = new SpecRandom(c.seed);
    const got = Array.from({ length: c.randf.length }, () => f.randf());
    assert.deepEqual(got, c.randf, `seed ${c.seed} randf`);
  }
});
