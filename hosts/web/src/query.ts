// Queries. Mirrors query.gd. Results come in world order (ADR 0095): the
// insertion order of env.entities. A radius query filters by distance,
// and order_by sorts by distance with ties in world order.
import { Entity } from "./entity.ts";
import type { Env } from "./env.ts";
import { type Dict, type Value, Vec2, Vec3, equals, isDict, lessThan, toFloat } from "./value.ts";

const OPERATOR_SUFFIXES = ["_eq", "_ne", "_gt", "_lt", "_gte", "_lte", "_atleast", "_atmost"];
const EDGE_STATE_KEY = "_edge";

export type Ctx = { [k: string]: unknown };

export function matches(e: Entity, spec: Dict, env: Env, ctx: Ctx = {}): boolean {
  if (Object.keys(spec).length === 0) return true;
  if ("tags_all" in spec) for (const t of asArray(spec.tags_all)) if (!e.hasTag(String(t))) return false;
  if ("tags_any" in spec && !asArray(spec.tags_any).some((t) => e.hasTag(String(t)))) return false;
  if ("tags_none" in spec) for (const t of asArray(spec.tags_none)) if (e.hasTag(String(t))) return false;
  if ("id" in spec && e.id !== strOf(spec.id)) return false;
  if ("ids" in spec && !asArray(spec.ids).some((x) => strOf(x) === e.id)) return false;
  if ("properties" in spec && !matchFields(e.properties, asDict(spec.properties))) return false;
  if ("state" in spec && !matchFields(e.state, asDict(spec.state))) return false;
  if ("relations" in spec && !matchRelations(e, asDict(spec.relations), env, ctx)) return false;
  return true;
}

export function run(spec: Dict, env: Env, ctx: Ctx = {}): Entity[] {
  const hasRadius = "radius" in spec;
  const radius = toFloat(spec.radius ?? 0);
  const origin = resolveOrigin(env, ctx);
  let out: Entity[] = [];
  for (const e of env.entities.values()) {
    if (!matches(e, spec, env, ctx)) continue;
    if (hasRadius && e.planarPosition().distanceTo(origin) > radius) continue;
    out.push(e);
  }
  const ob = String(spec.order_by ?? "");
  const sign = ob === "distance_asc" ? 1 : ob === "distance_desc" ? -1 : 0;
  if (sign !== 0) {
    // Array.prototype.sort is stable, so equal distances keep world order.
    out.sort((a, b) => sign * (a.planarPosition().distanceTo(origin) - b.planarPosition().distanceTo(origin)));
  }
  if ("limit" in spec) {
    const n = Math.trunc(toFloat(spec.limit));
    if (out.length > n) out = out.slice(0, n);
  }
  return out;
}

export function matchFields(fields: Dict, spec: Dict): boolean {
  for (const key of Object.keys(spec)) {
    const target = spec[key];
    if (key.endsWith("_has")) {
      const f = key.slice(0, -4);
      if (!(f in fields)) return false;
      const arr = fields[f];
      if (!Array.isArray(arr) || !arr.some((x) => equals(x, target))) return false;
      continue;
    }
    if (key.endsWith("_in")) {
      const f = key.slice(0, -3);
      if (!(f in fields)) return false;
      if (!Array.isArray(target) || !target.some((x) => equals(x, fields[f]))) return false;
      continue;
    }
    let op = "eq";
    let field = key;
    for (const suf of OPERATOR_SUFFIXES) {
      if (key.endsWith(suf)) {
        op = suf.slice(1);
        field = key.slice(0, -suf.length);
        break;
      }
    }
    if (!(field in fields)) return false;
    if (!compare(fields[field], target, op)) return false;
  }
  return true;
}

export function compare(actual: Value, target: Value, op: string): boolean {
  switch (op) {
    case "eq":
      return equals(actual, target);
    case "ne":
      return !equals(actual, target);
    case "gt":
      return lessThan(target, actual) === true;
    case "lt":
      return lessThan(actual, target) === true;
    case "gte":
    case "atleast":
      return lessThan(actual, target) === false;
    case "lte":
    case "atmost":
      return lessThan(target, actual) === false;
  }
  return false;
}

function matchRelations(e: Entity, relSpec: Dict, env: Env, ctx: Ctx): boolean {
  for (const relType of Object.keys(relSpec)) {
    if (!checkRelation(e, relType, relSpec[relType], env, ctx)) return false;
  }
  return true;
}

function checkRelation(e: Entity, relType: string, target: Value, env: Env, ctx: Ctx): boolean {
  const store = env.relations;
  if (typeof target === "string") {
    let targetId = "";
    if (target.startsWith("$")) targetId = strOf(ctx[target.slice(1)] ?? "");
    else if (target in ctx) targetId = strOf(ctx[target]);
    else targetId = target;
    if (targetId === "") return false;
    return store.hasEdge(relType, e.id, targetId);
  }
  if (isDict(target)) {
    let edgeSpec: Dict = {};
    let entitySpec: Dict = target;
    if (EDGE_STATE_KEY in target) {
      edgeSpec = isDict(target[EDGE_STATE_KEY]) ? (target[EDGE_STATE_KEY] as Dict) : {};
      entitySpec = { ...target };
      delete entitySpec[EDGE_STATE_KEY];
    }
    for (const cid of store.targets(relType, e.id)) {
      const cand = env.entities.get(cid);
      if (!cand) continue;
      if (Object.keys(edgeSpec).length > 0 && !matchFields(store.edgeState(relType, e.id, cid), edgeSpec)) continue;
      if (matches(cand, entitySpec, env, ctx)) return true;
    }
  }
  return false;
}

function resolveOrigin(env: Env, ctx: Ctx): Vec2 {
  if ("_origin_position" in ctx) {
    const p = ctx._origin_position;
    if (p instanceof Vec2) return p;
    if (p instanceof Vec3) return new Vec2(p.x, p.z);
    if (Array.isArray(p) && p.length >= 2) return new Vec2(toFloat(p[0]), toFloat(p[1]));
  }
  if ("self" in ctx) {
    const e = env.entities.get(strOf(ctx.self));
    if (e) return e.planarPosition();
  }
  return new Vec2(0, 0);
}

function asArray(v: unknown): Value[] {
  return Array.isArray(v) ? v : [];
}
function asDict(v: unknown): Dict {
  return isDict(v) ? v : {};
}
/** The reference str() for ids: a whole number prints with no decimals. */
export function strOf(v: unknown): string {
  if (typeof v === "string") return v;
  if (v instanceof Entity) return v.id;
  if (v === null || v === undefined) return "";
  return String(v);
}
