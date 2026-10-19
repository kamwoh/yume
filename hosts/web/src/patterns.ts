// Declarative instance placement (`patterns` in an entities file). Mirrors
// instance_patterns.gd: ring, grid, line, scatter, cluster and mirror each
// expand into initial-instance dicts at load. Scatter and cluster draw from
// a per-pattern stream of the spec generator, seeded with
// level_seed XOR (FNV-1a of the pattern identity | 1), so both hosts place
// each entity at the same spot (ADR 0060, ADR 0095).
import { SpecRandom } from "./random.ts";
import { type Dict, Vec2, Vec3, isDict, toFloat } from "./value.ts";

type V3 = [number, number, number];

/** InstancePatterns.expand. An unknown pattern gives []. */
export function expandPattern(p: Dict, baseSeed = 0): Dict[] {
  switch (String(p.pattern ?? "")) {
    case "ring":
      return ring(p);
    case "grid":
      return grid(p);
    case "line":
      return line(p);
    case "scatter":
      return scatter(p, baseSeed);
    case "cluster":
      return cluster(p, baseSeed);
    case "mirror":
      return mirror(p);
  }
  return [];
}

/** FNV-1a, 32 bits, over the UTF-8 bytes of `s`. */
export function fnv1a32(s: string): number {
  let h = 2166136261;
  for (const b of new TextEncoder().encode(s)) h = Math.imul(h ^ b, 16777619) >>> 0;
  return h >>> 0;
}

/** Godot's str() of a pattern field: an array of strings prints as ["a", "b"]. */
function gdStr(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map((x) => (typeof x === "string" ? `"${x}"` : String(x))).join(", ")}]`;
  return v === undefined || v === null ? "" : String(v);
}

/** InstancePatterns._pattern_rng. */
function patternRng(baseSeed: number, p: Dict): SpecRandom {
  const ident = `${gdStr(p.id_prefix ?? "")}|${gdStr(p.def ?? "")}|${gdStr(p.def_choices ?? [])}`;
  return new SpecRandom(((baseSeed ^ (fnv1a32(ident) | 1)) >>> 0));
}

/** Vec3Util.from_world_pos. */
function wp(v: unknown): V3 {
  if (v instanceof Vec3) return [v.x, v.y, v.z];
  if (v instanceof Vec2) return [v.x, 0, v.y];
  if (Array.isArray(v) && v.length >= 3) return [toFloat(v[0]), toFloat(v[1]), toFloat(v[2])];
  if (Array.isArray(v) && v.length === 2) return [toFloat(v[0]), 0, toFloat(v[1])];
  if (typeof v === "number") return [v, v, v];
  return [0, 0, 0];
}

const int = (v: unknown, d: number) => Math.trunc(toFloat(v ?? d));
const num = (v: unknown, d: number) => toFloat(v ?? d);

function ring(p: Dict): Dict[] {
  const def = String(p.def ?? "");
  const prefix = String(p.id_prefix ?? def);
  const count = int(p.count, 1);
  const radius = num(p.radius, 1);
  const y = num(p.y, 0);
  const yaw = num(p.yaw_offset, 0);
  const o = wp(p.origin ?? [0, 0, 0]);
  if (count <= 0 || def === "") return [];
  return Array.from({ length: count }, (_, i) => {
    const a = yaw + (Math.PI * 2 * i) / count;
    return { def, id: `${prefix}_${i + 1}`, position: [o[0] + Math.cos(a) * radius, o[1] + y, o[2] + Math.sin(a) * radius] };
  });
}

function grid(p: Dict): Dict[] {
  const def = String(p.def ?? "");
  const prefix = String(p.id_prefix ?? def);
  const cols = int(p.cols, 1);
  const rows = int(p.rows, 1);
  const spacing = num(p.spacing, 1);
  const o = wp(p.origin ?? [0, 0, 0]);
  if (cols <= 0 || rows <= 0 || def === "") return [];
  let ox = o[0];
  let oz = o[2];
  if (p.center !== false) {
    ox -= (cols - 1) * spacing * 0.5;
    oz -= (rows - 1) * spacing * 0.5;
  }
  const out: Dict[] = [];
  let n = 1;
  for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) out.push({ def, id: `${prefix}_${n++}`, position: [ox + c * spacing, o[1], oz + r * spacing] });
  return out;
}

function line(p: Dict): Dict[] {
  const def = String(p.def ?? "");
  const prefix = String(p.id_prefix ?? def);
  const count = int(p.count, 1);
  const s = wp(p.start ?? [0, 0, 0]);
  const e = wp(p.end ?? [1, 0, 0]);
  if (count <= 0 || def === "") return [];
  return Array.from({ length: count }, (_, i) => {
    const t = count === 1 ? 0 : i / (count - 1);
    return { def, id: `${prefix}_${i + 1}`, position: [s[0] + (e[0] - s[0]) * t, s[1] + (e[1] - s[1]) * t, s[2] + (e[2] - s[2]) * t] };
  });
}

function inExcludeZone(pos: V3, zones: unknown[]): boolean {
  for (const z of zones) {
    if (!isDict(z)) continue;
    const c = wp(z.center ?? [0, 0, 0]);
    const r = num(z.radius, 0);
    if (r <= 0) continue;
    const dx = pos[0] - c[0];
    const dz = pos[2] - c[2];
    if (dx * dx + dz * dz < r * r) return true;
  }
  return false;
}

const dist = (a: V3, b: V3) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);

function scatter(p: Dict, baseSeed: number): Dict[] {
  const rng = patternRng(baseSeed, p);
  const def = String(p.def ?? "");
  let choices = Array.isArray(p.def_choices) ? p.def_choices.map(String) : [];
  if (choices.length === 0 && def !== "") choices = [def];
  const prefix = String(p.id_prefix ?? (def !== "" ? def : "scatter"));
  const count = int(p.count, 1);
  const minR = num(p.min_r, 0);
  const maxR = num(p.max_r, 5);
  const y = num(p.y, 0);
  const spacing = num(p.min_spacing, 0);
  const maxAttempts = int(p.max_attempts, 100);
  const o = wp(p.origin ?? [0, 0, 0]);
  const zones = Array.isArray(p.exclude_zones) ? p.exclude_zones : [];
  const sMin = num(p.scale_min, 1);
  const sMax = num(p.scale_max, 1);
  const yawJitter = num(p.yaw_jitter, 0);
  const out: Dict[] = [];
  const placed: V3[] = [];
  if (count <= 0 || choices.length === 0) return out;
  let attempts = 0;
  while (placed.length < count && attempts < count * maxAttempts) {
    const t = rng.randf();
    const r = minR + (maxR - minR) * Math.sqrt(t);
    const a = rng.randf() * Math.PI * 2;
    const pos: V3 = [o[0] + Math.cos(a) * r, o[1] + y, o[2] + Math.sin(a) * r];
    let ok = spacing <= 0 || placed.every((q) => dist(q, pos) >= spacing);
    if (ok && zones.length > 0) ok = !inExcludeZone(pos, zones);
    if (ok) {
      placed.push(pos);
      const inst: Dict = { def: choices[rng.nextU32() % choices.length], id: `${prefix}_${placed.length}`, position: [...pos] };
      const st: Dict = {};
      if (sMin !== 1 || sMax !== 1) st.scale = sMin + (sMax - sMin) * rng.randf();
      if (yawJitter > 0) st.yaw = (rng.randf() - 0.5) * 2 * yawJitter;
      if (Object.keys(st).length > 0) inst.state = st;
      out.push(inst);
    }
    attempts++;
  }
  return out;
}

function cluster(p: Dict, baseSeed: number): Dict[] {
  const rng = patternRng(baseSeed, p);
  const def = String(p.def ?? "");
  const prefix = String(p.id_prefix ?? def);
  const count = int(p.count, 1);
  const o = wp(p.origin ?? [0, 0, 0]);
  const spread = num(p.spread, 2);
  const spacing = num(p.min_spacing, 0);
  const maxAttempts = int(p.max_attempts, 100);
  const zones = Array.isArray(p.exclude_zones) ? p.exclude_zones : [];
  const out: Dict[] = [];
  const placed: V3[] = [];
  if (count <= 0 || def === "") return out;
  let attempts = 0;
  while (placed.length < count && attempts < count * maxAttempts) {
    const dx = (rng.randf() - 0.5) * 2 * spread;
    const dz = (rng.randf() - 0.5) * 2 * spread;
    const pos: V3 = [o[0] + dx, o[1], o[2] + dz];
    let ok = spacing <= 0 || placed.every((q) => dist(q, pos) >= spacing);
    if (ok && zones.length > 0) ok = !inExcludeZone(pos, zones);
    if (ok) {
      placed.push(pos);
      out.push({ def, id: `${prefix}_${placed.length}`, position: [...pos] });
    }
    attempts++;
  }
  return out;
}

function mirror(p: Dict): Dict[] {
  const items = Array.isArray(p.items) ? p.items.filter(isDict) : [];
  const axis = String(p.axis ?? "x");
  const suffix = String(p.id_suffix ?? "_mirror");
  const out: Dict[] = [];
  for (const item of items) {
    out.push(JSON.parse(JSON.stringify(item)));
    const v = wp(item.position ?? [0, 0, 0]);
    const m: V3 = axis === "x" ? [-v[0], v[1], v[2]] : axis === "z" ? [v[0], v[1], -v[2]] : v;
    const copy: Dict = JSON.parse(JSON.stringify(item));
    copy.position = m;
    if (String(copy.id ?? "") !== "") copy.id = `${String(copy.id)}${suffix}`;
    out.push(copy);
  }
  return out;
}
