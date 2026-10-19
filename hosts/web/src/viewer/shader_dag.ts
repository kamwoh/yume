// The ground shader graph (ground.mesh.shader_dag, ADR 0058). Godot reads
// a .gdshader that tools/yume_shadergen/compiler.py builds at authoring
// time. This host compiles the same graph at load, with the same rules:
// each op names a primitive of lib/shaders/primitives, `$key` reads
// ground.mesh, `@var` reads an earlier op, and the primitive's Jinja
// template gives the GLSL. A sampler input declares a uniform named by its
// spec key, and each biome declares albedo_<name>. Floats render as GLSL
// literals.
//
// The GLSL then runs in a patched MeshStandardMaterial, so the ground keeps
// the lighting of every other mesh. Godot's builtins map to three.js:
// VERTEX and NORMAL in the vertex stage move the object-space position
// and normal; ALBEDO, ROUGHNESS, METALLIC, EMISSION and ALPHA in the
// fragment stage set the standard material's inputs.
import * as THREE from "three";
import { type Dict, isDict } from "../value.ts";

const BUILTINS = ["NORMAL", "ALBEDO", "ROUGHNESS", "METALLIC", "VERTEX", "ALPHA", "EMISSION"];

type Uniform = { name: string; type: string; hint: string; default?: unknown };
export type CompiledDag = { vertex: string; fragment: string; uniforms: Uniform[]; consts: string; varyings: string[] };

// ------------------------------------------------------------- Jinja subset

type Ctx = Record<string, unknown>;

/** The Jinja the primitives use: {{ path }}, {% for x in path %}, loop.last, {% if [not] path %}…{% else %}…{% endif %}. */
export function jinja(src: string, ctx: Ctx): string {
  const tokens = src.split(/(\{\{.*?\}\}|\{%.*?%\})/s);
  let pos = 0;
  const render = (scope: Ctx, stop: string[]): { out: string; end: string } => {
    let out = "";
    while (pos < tokens.length) {
      const t = tokens[pos++];
      if (t.startsWith("{{")) out += fmt(lookup(t.slice(2, -2).trim(), scope));
      else if (t.startsWith("{%")) {
        const stmt = t.slice(2, -2).trim();
        const word = stmt.split(/\s+/)[0];
        if (stop.includes(word)) return { out, end: word };
        if (word === "for") {
          const m = /^for\s+(\w+)\s+in\s+(.+)$/.exec(stmt)!;
          const list = lookup(m[2].trim(), scope);
          const items = Array.isArray(list) ? list : [];
          const start = pos;
          if (items.length === 0) skip(["endfor"]);
          items.forEach((item, i) => {
            pos = start;
            out += render({ ...scope, [m[1]]: item, loop: { last: i === items.length - 1, first: i === 0, index0: i } }, ["endfor"]).out;
          });
        } else if (word === "if") {
          const cond = truthy(stmt.slice(2).trim(), scope);
          const a = render(scope, ["else", "endif"]);
          if (a.end === "else") {
            const b = render(scope, ["endif"]);
            out += cond ? a.out : b.out;
          } else out += cond ? a.out : "";
        }
      } else out += t;
    }
    return { out, end: "" };
  };
  const skip = (stop: string[]) => {
    let depth = 0;
    while (pos < tokens.length) {
      const t = tokens[pos++];
      if (!t.startsWith("{%")) continue;
      const w = t.slice(2, -2).trim().split(/\s+/)[0];
      if (w === "for" || w === "if") depth++;
      else if ((w === "endfor" || w === "endif") && depth > 0) depth--;
      else if (stop.includes(w) && depth === 0) return;
    }
  };
  return render(ctx, []).out;
}

function truthy(expr: string, scope: Ctx): boolean {
  if (expr.startsWith("not ")) return !truthy(expr.slice(4).trim(), scope);
  const v = lookup(expr, scope);
  return !(v === undefined || v === null || v === false || v === 0 || v === "" || (Array.isArray(v) && v.length === 0));
}

function lookup(path: string, scope: Ctx): unknown {
  let cur: unknown = scope;
  for (const part of path.match(/[A-Za-z_]\w*|\[\d+\]/g) ?? []) {
    if (part.startsWith("[")) cur = Array.isArray(cur) ? cur[Number(part.slice(1, -1))] : undefined;
    else cur = isDict(cur) || (typeof cur === "object" && cur !== null) ? (cur as Record<string, unknown>)[part] : undefined;
  }
  return cur;
}

/**
 * A rendered value. JSON in JavaScript has no int or float, and GLSL ES has
 * no int × float. So a number renders with a decimal point, as the Python
 * compiler renders a float. (An `int` input renders as an integer.)
 */
function fmt(v: unknown): string {
  if (v === undefined || v === null) return "";
  if (typeof v === "boolean") return v ? "True" : "False";
  if (typeof v === "number") return Number.isInteger(v) ? `${v}.0` : String(v);
  return String(v);
}

// ---------------------------------------------------------------- compiler

/** compiler.py emit_op_glsl's float format: up to 6 decimals, always with a point. */
function glslFloat(v: number): string {
  let s = v.toFixed(6).replace(/0+$/, "").replace(/\.$/, "");
  if (s === "" || s === "-") s = "0";
  return s.includes(".") ? s : `${s}.0`;
}

/** compiler.py compile_dag. Throws on an unknown primitive, a stage mismatch or a missing input. */
export function compileDag(mesh: Dict, primitives: Map<string, Dict>): CompiledDag {
  const dag = isDict(mesh.shader_dag) ? mesh.shader_dag : {};
  // yume_shadergen load_spec: the mesh fields except the meta keys, then the
  // shader_params keys that the mesh does not set (texture paths live there).
  const SKIP = ["shader_dag", "shader", "shader_params", "_comment", "_comment_template", "_comment_subdivide", "_comment_color"];
  const spec: Dict = {};
  for (const k of Object.keys(mesh)) if (!SKIP.includes(k)) spec[k] = mesh[k];
  const sp = isDict(mesh.shader_params) ? mesh.shader_params : {};
  for (const k of Object.keys(sp)) if (!k.startsWith("_") && !(k in spec)) spec[k] = sp[k];
  const stages = isDict(dag.stages) ? dag.stages : {};
  const uniforms = new Map<string, Uniform>();
  const varyings = new Set<string>();
  const bodies: Record<string, string> = { vertex: "", fragment: "" };
  for (const stage of ["vertex", "fragment"]) {
    const locals = new Set<string>();
    const lines: string[] = [];
    for (const op of Array.isArray(stages[stage]) ? stages[stage] : []) {
      if (!isDict(op)) continue;
      const prim = primitives.get(String(op.op ?? ""));
      if (!prim) throw new Error(`[${stage}] unknown primitive: '${String(op.op)}'`);
      const pstage = String(prim.stage ?? "fragment");
      if (pstage !== "both" && pstage !== stage) throw new Error(`[${stage}] primitive '${String(op.op)}' has stage '${pstage}'`);
      const inBlock = isDict(op.in) ? op.in : {};
      const pin = isDict(prim.inputs) ? prim.inputs : {};
      const pout = isDict(prim.outputs) ? prim.outputs : {};
      // A primitive's own uniforms register first, as in emit_op_glsl, so its hint wins.
      for (const u of Array.isArray(prim.uniforms) ? prim.uniforms : []) if (isDict(u) && !uniforms.has(String(u.name))) uniforms.set(String(u.name), { name: String(u.name), type: String(u.type ?? "float"), hint: String(u.hint ?? ""), default: u.default });
      const inputs: Ctx = {};
      for (const name of Object.keys(pin)) {
        const def = isDict(pin[name]) ? pin[name] : {};
        let v: unknown;
        if (name in inBlock) {
          const raw = inBlock[name];
          if (typeof raw === "string" && raw.startsWith("$")) {
            if (!(raw.slice(1) in spec)) throw new Error(`[${stage}] $key '${raw.slice(1)}' not in spec`);
            v = spec[raw.slice(1)];
          } else if (typeof raw === "string" && raw.startsWith("@")) {
            if (!locals.has(raw.slice(1))) throw new Error(`[${stage}] @var '${raw.slice(1)}' not declared by a prior op`);
            v = raw.slice(1);
          } else v = raw;
        } else if ("default" in def) v = def.default;
        else throw new Error(`[${stage}] ${String(op.op)}: missing required input '${name}'`);
        const type = String(def.type ?? "");
        if (type.startsWith("list<") && Array.isArray(v)) {
          inputs[name] = v;
          inputs[`${name}_list`] = v;
        } else if (typeof v === "number") inputs[name] = type === "int" ? String(Math.trunc(v)) : glslFloat(v);
        else inputs[name] = v;
        // A sampler input declares a uniform named by the spec key (or the literal).
        if (type === "sampler2D") {
          const raw = inBlock[name];
          let uname = "";
          if (typeof raw === "string" && raw.startsWith("$")) uname = raw.slice(1);
          else if (typeof raw === "string" && !raw.startsWith("@")) uname = raw;
          if (uname !== "") {
            if (!uniforms.has(uname)) {
              const hint = uname.includes("albedo") || uname.includes("color") ? "source_color, filter_linear_mipmap, repeat_enable" : "source_color, filter_linear, repeat_disable";
              uniforms.set(uname, { name: uname, type: "sampler2D", hint });
            }
            inputs[name] = uname;
          }
        }
      }
      const outputs: Ctx = {};
      const out = op.out;
      const outNames = Object.keys(pout);
      if (typeof out === "string") {
        if (outNames.length === 1) outputs[outNames[0]] = out;
        else if (outNames.length > 1) throw new Error(`[${stage}] ${String(op.op)}: ${outNames.length} outputs need an 'out' dict`);
      } else if (isDict(out)) for (const n of outNames) if (n in out) outputs[n] = out[n];
      for (const v of Object.values(outputs)) if (!BUILTINS.includes(String(v))) locals.add(String(v));
      for (const v of Array.isArray(prim.varyings) ? prim.varyings : []) varyings.add(String(v));
      const tpl = String((stage === "vertex" ? prim.glsl_vertex : prim.glsl_fragment) ?? "");
      if (tpl === "") continue;
      const glsl = jinja(tpl, { inputs, outputs });
      if (glsl.trim() !== "") lines.push(glsl);
    }
    // strip_builtin_type_prefix: `vec3 NORMAL = ...` assigns the builtin.
    bodies[stage] = lines.join("\n").replace(/^(\s*)(?:vec[234]|float|int|bool)\s+(NORMAL|ALBEDO|ROUGHNESS|METALLIC|VERTEX|ALPHA|EMISSION)(\s*=)/gm, "$1$2$3");
  }
  // collect_biome_albedo_uniforms, and the per-biome reference colors.
  let consts = "";
  for (const b of Array.isArray(spec.biomes) ? spec.biomes : []) {
    if (!isDict(b) || !("name" in b)) continue;
    const n = `albedo_${String(b.name)}`;
    if (!uniforms.has(n)) uniforms.set(n, { name: n, type: "sampler2D", hint: "source_color, filter_linear_mipmap, repeat_enable" });
    if (Array.isArray(b.color)) consts += `const vec3 BIOME_COLOR_${String(b.name).toUpperCase()} = vec3(${b.color.map(Number).map(glslFloat).join(", ")});\n`;
  }
  return { vertex: bodies.vertex, fragment: bodies.fragment, uniforms: [...uniforms.values()], consts, varyings: [...varyings] };
}

// ----------------------------------------------------------- the material

type TextureLoad = (path: string, srgb: boolean) => THREE.Texture | null;

/** The graph as a patched MeshStandardMaterial. Sampler values come from ground.mesh.shader_params (GroundRenderer). */
export function dagMaterial(mesh: Dict, primitives: Map<string, Dict>, load: TextureLoad): THREE.MeshStandardMaterial {
  const c = compileDag(mesh, primitives);
  const params = isDict(mesh.shader_params) ? mesh.shader_params : {};
  const u: Record<string, THREE.IUniform> = { dagTime: { value: 0 } };
  let decl = "uniform float dagTime;\n";
  for (const un of c.uniforms) {
    if (un.type === "sampler2D") {
      const path = params[un.name];
      // Godot's gl_compatibility renderer (project.godot) reads a custom shader's
      // source_color sampler raw. Test 2026-10-19: aldenmere's splat probe matches
      // its raw BIOME_COLOR constants only so, as the Godot capture shows. With an
      // sRGB decode every biome weight was the same, and the ground was one blend.
      const tex = typeof path === "string" ? load(path, false) : null;
      if (tex && !un.hint.includes("repeat_enable")) tex.wrapS = tex.wrapT = THREE.ClampToEdgeWrapping;
      u[un.name] = { value: tex };
    } else u[un.name] = { value: un.name in params ? params[un.name] : (un.default ?? 0) };
    decl += `uniform ${un.type} ${un.name};\n`;
  }
  decl += c.consts;
  const varyingDecl = c.varyings.map((v) => `varying vec3 ${v};`).join("\n");
  const rename = (src: string, map: Record<string, string>) => src.replace(/\b[A-Z_]+\b/g, (w) => map[w] ?? w);
  const vbody = rename(c.vertex, { VERTEX: "dagVertex", NORMAL: "dagNormal", MODEL_MATRIX: "modelMatrix", TIME: "dagTime", UV: "uv" });
  const fbody = rename(c.fragment, {
    ALBEDO: "dagAlbedo", ROUGHNESS: "dagRough", METALLIC: "dagMetal", EMISSION: "dagEmission", ALPHA: "dagAlpha", TIME: "dagTime", UV: "vDagUv",
  });
  const mat = new THREE.MeshStandardMaterial({ color: 0xffffff });
  mat.userData.uniforms = u;
  mat.userData.dagGlsl = { vbody, fbody };
  mat.onBeforeCompile = (sh) => {
    Object.assign(sh.uniforms, u);
    sh.vertexShader = sh.vertexShader
      .replace("#include <common>", `#include <common>\n${decl}${varyingDecl}\nvarying vec2 vDagUv;`)
      .replace("#include <beginnormal_vertex>", `#include <beginnormal_vertex>\nvec3 dagVertex = position;\nvec3 dagNormal = objectNormal;\nvDagUv = uv;\n${vbody}\nobjectNormal = dagNormal;`)
      .replace("#include <begin_vertex>", "vec3 transformed = dagVertex;\n#ifdef USE_ALPHAHASH\nvPosition = vec3( position );\n#endif");
    sh.fragmentShader = sh.fragmentShader
      .replace("#include <common>", `#include <common>\n${decl}${varyingDecl}\nvarying vec2 vDagUv;`)
      .replace(
        "#include <color_fragment>",
        `#include <color_fragment>\nvec3 dagAlbedo = diffuseColor.rgb;\nfloat dagRough = roughness;\nfloat dagMetal = metalness;\nvec3 dagEmission = vec3(0.0);\nfloat dagAlpha = diffuseColor.a;\n${fbody}\ndiffuseColor = vec4(dagAlbedo, dagAlpha);`,
      )
      .replace("#include <roughnessmap_fragment>", "#include <roughnessmap_fragment>\nroughnessFactor = dagRough;")
      .replace("#include <metalnessmap_fragment>", "#include <metalnessmap_fragment>\nmetalnessFactor = dagMetal;")
      .replace("#include <emissivemap_fragment>", "#include <emissivemap_fragment>\ntotalEmissiveRadiance += dagEmission;");
  };
  return mat;
}
