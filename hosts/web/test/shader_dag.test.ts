// The ground shader graph (ADR 0058): the host compiler must give the same
// GLSL as tools/yume_shadergen/compiler.py. The fixture holds the Python
// output for a copy of a real game's graph, made with the tracked primitives.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { compileDag, jinja } from "../src/viewer/shader_dag.ts";

const primDir = fileURLToPath(new URL("../../../godot/data/lib/shaders/primitives/", import.meta.url));
const primitives = new Map(
  readdirSync(primDir).filter((f) => f.endsWith(".json") && !f.startsWith("_")).map((f) => {
    const d = JSON.parse(readFileSync(primDir + f, "utf8"));
    return [d.id, d];
  }),
);
const fixture = JSON.parse(readFileSync(new URL("./fixtures/shader_dag_ground.json", import.meta.url), "utf8"));
const norm = (s: string) => s.replace(/\s+/g, " ").trim();

test("the host compiles a ground graph to the same GLSL as the Python compiler", () => {
  const c = compileDag(fixture.mesh, primitives);
  assert.equal(norm(c.vertex), norm(fixture.vertex), "vertex stage");
  assert.equal(norm(c.fragment), norm(fixture.fragment), "fragment stage");
  for (const u of c.uniforms) {
    assert.ok(fixture.uniforms.includes(`uniform ${u.type} ${u.name}${u.hint ? ` : ${u.hint}` : ""}`), `uniform ${u.name} matches`);
  }
  for (const line of fixture.uniforms.split("\n").filter((l: string) => l.startsWith("const "))) assert.ok(c.consts.includes(line), line);
});

test("the Jinja subset: paths, loops with loop.last, if and else", () => {
  const out = jinja("{% for b in xs %}{{ b.n }}{% if b.on %}!{% else %}?{% endif %}{% if not loop.last %},{% endif %}{% endfor %} {{ v[1] }}", {
    xs: [{ n: "a", on: true }, { n: "b" }],
    v: [0, 2.5],
  });
  assert.equal(out, "a!,b? 2.5");
});

test("a graph with an unknown primitive or a missing input fails at compile", () => {
  assert.throws(() => compileDag({ shader_dag: { stages: { fragment: [{ op: "nope" }] } } }, primitives), /unknown primitive/);
  assert.throws(() => compileDag({ shader_dag: { stages: { fragment: [{ op: "sample_biome_map", in: {} }] } } }, primitives), /missing required input/);
});
