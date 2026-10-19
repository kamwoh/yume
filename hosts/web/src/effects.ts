// Effects. Mirrors effect_apply.gd, effect_core.gd and effect_resolution.gd
// for the exact effects of ADR 0095 phase 1. Shell effects (screens,
// toasts, save, audio) append a record to env.shellEvents and change no
// other state. An effect outside phase 1 raises effect.unsupported_host.
import { Entity } from "./entity.ts";
import type { Env } from "./env.ts";
import { raise } from "./env.ts";
import { type FormulaContext, evaluate, looksLikeFormula } from "./formula.ts";
import { tickPathfind } from "./pathfinding.ts";
import { attachBody } from "./physics.ts";
import { type Ctx, strOf } from "./query.ts";
import { type Dict, type Value, Vec2, Vec3, deepCopy, equals, isDict, toFloat, toInt } from "./value.ts";

const WORLD_STATE_ALIAS = "_engine";

const SHELL_EFFECTS = [
  "transition_screen", "quit_app", "show_toast", "reload_scene", "scene_change", "screen_fade",
  "show_overlay", "dismiss_overlay", "set_audio_bus_volume",
  "set_input_mapping", "refresh_screen",
];

export function apply(e: Dict, env: Env, ctx: Ctx): void {
  const type = String(e.type ?? "");
  switch (type) {
    case "state_set":
      return stateSet(e, env, ctx);
    case "state_add": {
      const ent = target(e, env, ctx);
      if (ent) ent.addState(String(e.field ?? ""), toFloat(value(e.amount ?? null, ctx, env)));
      return;
    }
    case "state_mul": {
      const ent = target(e, env, ctx);
      if (!ent) return;
      const f = String(e.field ?? "");
      ent.setState(f, toFloat(ent.getState(f, 0)) * toFloat(value(e.amount ?? null, ctx, env)));
      return;
    }
    case "state_clamp": {
      const ent = target(e, env, ctx);
      if (!ent) return;
      const f = String(e.field ?? "");
      const lo = "min" in e ? toFloat(e.min) : -Infinity;
      const hi = "max" in e ? toFloat(e.max) : Infinity;
      const x = toFloat(ent.getState(f, 0));
      ent.setState(f, x < lo ? lo : x > hi ? hi : x);
      return;
    }
    case "spawn":
      spawn(e, env, ctx);
      return;
    case "remove":
      return remove(e, env, ctx);
    case "transform":
      return transform(e, env, ctx);
    case "relate":
    case "unrelate": {
      const t = String(e.relation ?? "");
      const from = resolveId(e.from ?? "self", ctx, env);
      const to = resolveId(e.to ?? "", ctx, env);
      if (t === "" || from === "" || to === "") return;
      if (type === "relate") env.relations.relate(t, from, to, isDict(e.state) ? e.state : {});
      else env.relations.unrelate(t, from, to);
      return;
    }
    case "transfer_relation": {
      const t = String(e.relation ?? "");
      const from = resolveId(e.from ?? "self", ctx, env);
      const to = resolveId(e.to ?? "", ctx, env);
      if ("new_to" in e) env.relations.transferTo(t, from, to, resolveId(e.new_to, ctx, env));
      else if ("new_from" in e) env.relations.transferFrom(t, from, resolveId(e.new_from, ctx, env), to);
      return;
    }
    case "relation_set":
    case "relation_add":
    case "relation_clamp":
      return relationField(type, e, env, ctx);
    case "tag_add":
    case "tag_remove": {
      const ent = target(e, env, ctx);
      const tag = String(e.tag ?? "");
      if (tag === "") raise(env, "effect.tag_missing", `${type}: no \`tag\` field`, "warning");
      if (!ent || tag === "") return;
      if (type === "tag_add") ent.addTag(tag);
      else ent.removeTag(tag);
      return;
    }
    case "emit": {
      const name = String(e.signal ?? "");
      if (name === "") return;
      const raw = isDict(e.payload) ? e.payload : {};
      const payload: Dict = {};
      for (const k of Object.keys(raw)) payload[k] = value(raw[k], ctx, env) as Value;
      pushSignal(env, name, payload);
      return;
    }
    case "emit_shell_event": {
      const ev = String(e.event ?? "");
      if (ev === "") return;
      const rec: Dict = { event: ev };
      for (const k of Object.keys(e)) if (k !== "type" && k !== "event") rec[k] = value(e[k], ctx, env) as Value;
      env.shellEvents.push({ type: "emit_shell_event", ...rec });
      return;
    }
    case "array_set_at":
    case "array_insert_first_empty":
    case "array_count_matching":
    case "array_sync_to_field":
      return arrayEffect(type, e, env, ctx);
    case "advance_time": {
      const units = toInt(value(e.units ?? 1, ctx, env));
      if (units > 0 && env.advanceCalendar) env.advanceCalendar(units);
      return;
    }
    case "save_state":
    case "load_state": {
      // EffectShell.save_state and load_state: the slot is drained after the tick (World.processPending).
      const slot = toInt(value(e.slot ?? 0, ctx, env));
      if (type === "save_state") env.pendingSave = slot;
      else env.pendingLoad = slot;
      return;
    }
    case "reset_world":
      // EffectActor.reset_world: the reset runs after the tick (World.processPending).
      env.pendingReset = true;
      return;
    case "velocity_set":
      return velocitySet(e, env, ctx);
    case "velocity_set_relative":
      return velocityRelative(e, env, ctx, false);
    case "velocity_add_relative":
      return velocityRelative(e, env, ctx, true);
    case "velocity_lerp":
      return velocityLerp(e, env, ctx);
    case "raycast_hit":
      return raycastHit(e, env, ctx);
    case "transition_level":
      return transitionLevel(e, env, ctx);
    case "level_call":
      return levelCall(e, env, ctx);
    case "level_return":
      return levelReturn(e, env, ctx);
    case "pathfind_to": {
      // EffectMotion.pathfind_to (ADR 0024).
      const ent = target(e, env, ctx);
      if (!ent) return;
      const dx = toFloat(value(e.destination_x ?? 0, ctx, env));
      const dy = toFloat(value(e.destination_y ?? 0, ctx, env));
      const dz = toFloat(value(e.destination_z ?? 0, ctx, env));
      const speed = toFloat(value(e.speed ?? 1, ctx, env));
      return tickPathfind(env, ent, dx, dy, dz, speed);
    }
    case "switch_actor": {
      // EffectActor.switch_actor (ADR 0016): the switch waits for the tick boundary.
      const id = strOf(value(e.target_id ?? e.target ?? "", ctx, env));
      if (id === "") {
        console.warn(`switch_actor: missing target_id (rule=${String(ctx._rule_id ?? "")})`);
        return;
      }
      env.pendingActiveActor = id;
      return;
    }
    case "queue_input_for_actor": {
      // EffectActor.queue_input_for_actor: input for any actor, through the scheduler's input queue.
      const actor = strOf(value(e.actor_id ?? "", ctx, env));
      const action = strOf(value(e.action ?? "", ctx, env));
      if (actor === "" || action === "") {
        console.warn(`queue_input_for_actor: missing actor_id or action (rule=${String(ctx._rule_id ?? "")})`);
        return;
      }
      env.queueInput?.(action, { actor, synthesized: true });
      return;
    }
    case "zone_state_set":
    case "zone_state_add":
    case "zone_state_clamp":
      return zoneState(type, e, env, ctx);
  }
  if (SHELL_EFFECTS.includes(type)) {
    const rec: Dict = { type };
    for (const k of Object.keys(e)) if (k !== "type") rec[k] = deepCopy(e[k]);
    env.shellEvents.push(rec);
    return;
  }
  // An error, not a warning: the scenario runner prints errors, so a missing effect cannot pass in silence.
  raise(env, "effect.unsupported_host", `effect '${type}' is not in this host yet (ADR 0095 phase 1)`);
}

/** EffectShell.transition_level: a fade goes to the shell, else the swap waits for the tick end. */
function transitionLevel(e: Dict, env: Env, ctx: Ctx): void {
  const target = strOf(value(e.target ?? "next", ctx, env));
  if (target === "") return;
  const fade = toFloat(value(e.fade_duration ?? 0, ctx, env));
  if (fade > 0) {
    env.shellEvents.push({ type: "transition_level_fade_request", target, fade_duration: fade, color: deepCopy(e.color ?? "#000000") });
    return;
  }
  env.pendingLevel = target;
}

const CALL_STACK_KEY = "_level_call_stack";
const CALL_ARGS_KEY = "_call_args";

/**
 * EffectShell.level_call (ADR 0077): push the caller onto the call stack,
 * store the resolved args, and enter the sub-level after the tick. A
 * screen_mark record lets level_return remove the screens of the sub-level.
 */
function levelCall(e: Dict, env: Env, ctx: Ctx): void {
  const lvl = strOf(value(e.level ?? "", ctx, env));
  if (lvl === "") return;
  const world = env.world;
  const stack = Array.isArray(world[CALL_STACK_KEY]) ? (world[CALL_STACK_KEY] as Value[]) : [];
  stack.push({ level: String(world.current_level ?? ""), return_signal: String(e.return_signal ?? "") });
  world[CALL_STACK_KEY] = stack;
  const args = isDict(e.args) ? value(e.args, ctx, env) : {};
  world[CALL_ARGS_KEY] = (isDict(args) ? args : {}) as Value;
  env.pendingLevelCall = lvl;
  env.shellEvents.push({ type: "screen_mark" });
}

/**
 * EffectShell.level_return (ADR 0077): pop the call stack and return to
 * the caller after the tick, with the resolved result. An empty stack
 * raises level.return_empty_stack and changes nothing.
 */
function levelReturn(e: Dict, env: Env, ctx: Ctx): void {
  const world = env.world;
  const stack = Array.isArray(world[CALL_STACK_KEY]) ? (world[CALL_STACK_KEY] as Value[]) : [];
  if (stack.length === 0) {
    raise(env, "level.return_empty_stack", "level_return with an empty call stack — no caller to return to", "warning");
    return;
  }
  const frame = stack.pop();
  world[CALL_STACK_KEY] = stack;
  const result = isDict(e.result) ? value(e.result, ctx, env) : {};
  const f = isDict(frame) ? frame : {};
  env.pendingLevelReturn = { level: String(f.level ?? ""), return_signal: String(f.return_signal ?? ""), result: (isDict(result) ? result : {}) as Value };
  env.shellEvents.push({ type: "screen_restore" });
}

/** EffectCore.resolve_zone_id: a context binding, then a formula, then the literal id. */
function zoneId(v: unknown, ctx: Ctx, env: Env): string {
  if (v === null || v === undefined) return "";
  if (typeof v !== "string") return String(v);
  if (v in ctx) return String(ctx[v]);
  if (looksLikeFormula(v)) {
    const r = evaluate(v, formulaContext(ctx, env, v), env);
    return r === null || r === undefined ? "" : String(r);
  }
  return v;
}

/** EffectCore.zone_state_set, zone_state_add and zone_state_clamp (ADR 0031). */
function zoneState(type: string, e: Dict, env: Env, ctx: Ctx): void {
  const zs = env.zones;
  if (!zs) return;
  const zid = zoneId(e.zone, ctx, env);
  if (zid === "" || !zs.has(zid)) {
    raise(env, "effect.zone_unknown", `${type}: unknown zone '${zid}'`, "warning");
    return;
  }
  const field = String(e.field ?? "");
  if (type === "zone_state_set") zs.setField(zid, field, value(e.value ?? null, ctx, env) as Value);
  else if (type === "zone_state_add") zs.addField(zid, field, toFloat(value(e.amount ?? e.delta ?? 0, ctx, env)));
  else zs.clampField(zid, field, toFloat(value(e.min ?? -Infinity, ctx, env)), toFloat(value(e.max ?? Infinity, ctx, env)));
}

export function pushSignal(env: Env, name: string, payload: Dict): void {
  if (name === "") return;
  env.signalBuffer.push({ name, payload });
}

function stateSet(e: Dict, env: Env, ctx: Ctx): void {
  const ent = target(e, env, ctx);
  if (!ent) return;
  const field = String(e.field ?? "");
  const v = value(e.value ?? null, ctx, env) as Value;
  if (field === "position") ent.setPosition(v);
  else if (field === "velocity") ent.setVelocity(v);
  else ent.setState(field, v);
}

export function spawn(e: Dict, env: Env, ctx: Ctx): string {
  const template = String(e.template ?? "");
  const def = env.defs.get(template);
  if (!def) {
    raise(env, "effect.spawn_no_def", `spawn: no def '${template}'`);
    return "";
  }
  const overrides: Dict = deepCopy(isDict(e.overrides) ? e.overrides : {});
  if ("position" in e) overrides.position = position(e.position, env, ctx);
  if (isDict(overrides.state)) {
    const st = overrides.state;
    for (const k of Object.keys(st)) {
      const v = st[k];
      if ((k === "position" || k === "velocity") && Array.isArray(v)) st[k] = position(v, env, ctx);
      else if (typeof v === "string") st[k] = value(v, ctx, env) as Value;
    }
  }
  let id = "";
  if ("_forced_id" in overrides) {
    id = String(overrides._forced_id);
    delete overrides._forced_id;
  } else {
    id = `${template}_${env.nextId.n}`;
    env.nextId.n += 1;
  }
  const ent = Entity.create(def, id, overrides);
  env.entities.set(id, ent);
  attachBody(env, ent, def);
  env.dispatchLifecycle?.("spawn", id);
  return id;
}

function remove(e: Dict, env: Env, ctx: Ctx): void {
  const ent = target(e, env, ctx);
  if (!ent) return;
  env.dispatchLifecycle?.("despawn", ent.id);
  env.relations.clearEntity(ent.id);
  env.physics?.remove(ent);
  env.entities.delete(ent.id);
}

function transform(e: Dict, env: Env, ctx: Ctx): void {
  const ent = target(e, env, ctx);
  if (!ent) return;
  const to = String(e.to ?? "");
  if (!env.defs.has(to)) {
    raise(env, "effect.transform_no_def", `transform: no def '${to}'`);
    return;
  }
  const preserved = deepCopy(ent.state);
  remove({ type: "remove", target: e.target ?? "self" }, env, ctx);
  spawn({ type: "spawn", template: to, overrides: { state: preserved } }, env, ctx);
}

function relationField(type: string, e: Dict, env: Env, ctx: Ctx): void {
  const t = String(e.relation ?? "");
  const from = resolveId(e.from ?? "self", ctx, env);
  const to = resolveId(e.to ?? "", ctx, env);
  if (t === "" || from === "" || to === "") return;
  const field = String(e.field ?? "");
  let ok = false;
  if (type === "relation_set") ok = env.relations.setEdgeField(t, from, to, field, value(e.value ?? null, ctx, env) as Value);
  else if (type === "relation_add") ok = env.relations.addEdgeField(t, from, to, field, toFloat(value(e.amount ?? null, ctx, env)));
  else ok = env.relations.clampEdgeField(t, from, to, field, "min" in e ? toFloat(e.min) : -Infinity, "max" in e ? toFloat(e.max) : Infinity);
  if (!ok && !env.relations.hasEdge(t, from, to)) {
    raise(env, "relation.no_edge", `${type}: no ${t} edge ${from} -> ${to}`, "warning");
  }
}

function arrayEffect(type: string, e: Dict, env: Env, ctx: Ctx): void {
  const ent = target(e, env, ctx);
  if (!ent) return;
  if (type === "array_set_at") {
    const field = String(e.field ?? "");
    if (field === "") return;
    const index = toInt(value(e.index ?? 0, ctx, env));
    if (index < 0) return;
    const v = value(e.value ?? null, ctx, env) as Value;
    const cur = ent.getState(field, []);
    const arr: Value[] = Array.isArray(cur) ? [...cur] : [];
    while (arr.length <= index) arr.push(null);
    arr[index] = v;
    ent.setState(field, arr);
  } else if (type === "array_insert_first_empty") {
    const field = String(e.field ?? "");
    if (field === "") return;
    const sentinel = value(e.sentinel ?? "", ctx, env);
    const v = value(e.value ?? null, ctx, env) as Value;
    if (v === null) return;
    const resultField = String(e.result_field ?? "_last_slot");
    const cur = ent.getState(field, []);
    const arr: Value[] = Array.isArray(cur) ? [...cur] : [];
    for (let i = 0; i < arr.length; i++) {
      if (equals(arr[i], sentinel)) {
        arr[i] = v;
        ent.setState(field, arr);
        ent.setState(resultField, i);
        return;
      }
    }
    ent.setState(resultField, -1);
    if (isDict(e.on_full)) {
      const sig = String(e.on_full.signal ?? "");
      if (sig !== "") pushSignal(env, sig, deepCopy(isDict(e.on_full.payload) ? e.on_full.payload : {}));
    }
  } else if (type === "array_count_matching") {
    const af = String(e.array_field ?? "");
    const df = String(e.dest_field ?? "");
    if (af === "" || df === "") return;
    const sentinel = value(e.sentinel ?? "", ctx, env);
    const cur = ent.getState(af, []);
    ent.setState(df, Array.isArray(cur) ? cur.filter((x) => equals(x, sentinel)).length : 0);
  } else {
    const af = String(e.array_field ?? "");
    const inf = String(e.index_field ?? "");
    const df = String(e.dest_field ?? "");
    if (af === "" || inf === "" || df === "") return;
    const dflt = (e.default ?? "") as Value;
    const cur = ent.getState(af, []);
    const idx = toInt(ent.getState(inf, 0));
    let out: Value = dflt;
    if (Array.isArray(cur) && idx >= 0 && idx < cur.length) out = cur[idx] ?? dflt;
    ent.setState(df, out);
  }
}

function velocitySet(e: Dict, env: Env, ctx: Ctx): void {
  const ent = target(e, env, ctx);
  if (!ent) return;
  const cur = ent.getState("velocity", null);
  const cx = cur instanceof Vec2 || cur instanceof Vec3 ? cur.x : 0;
  const cy = cur instanceof Vec2 || cur instanceof Vec3 ? cur.y : 0;
  const vx = "x" in e ? toFloat(value(e.x, ctx, env)) : cx;
  const vy = "y" in e ? toFloat(value(e.y, ctx, env)) : cy;
  if ("z" in e || cur instanceof Vec3) {
    const vz = "z" in e ? toFloat(value(e.z, ctx, env)) : cur instanceof Vec3 ? cur.z : 0;
    ent.setVelocity(new Vec3(vx, vy, vz));
  } else {
    ent.setVelocity(new Vec2(vx, vy));
  }
}

/**
 * EffectMotion.velocity_set_relative and velocity_add_relative (ADR 0040,
 * ADR 0048): forward and strafe turned by the facing. Forward at facing 0 is
 * -Z, and strafe is to the right (+X). The add form zeros the velocity on its
 * first fire in a tick, then sums the fires of that tick.
 */
function velocityRelative(e: Dict, env: Env, ctx: Ctx, add: boolean): void {
  const ent = target(e, env, ctx);
  if (!ent) return;
  const fwd = toFloat(value(e.forward ?? 0, ctx, env));
  const strafe = toFloat(value(e.strafe ?? 0, ctx, env));
  const facing = "facing" in e ? toFloat(value(e.facing, ctx, env)) : toFloat(ent.getState("facing", 0));
  const vx = -Math.sin(facing) * fwd + Math.cos(facing) * strafe;
  const vz = -Math.cos(facing) * fwd - Math.sin(facing) * strafe;
  if (!add) {
    ent.setVelocity(ent.position() instanceof Vec3 ? new Vec3(vx, 0, vz) : new Vec2(vx, vz));
    return;
  }
  const tick = toInt(env.world._tick ?? -1);
  const fresh = tick !== toInt(ent.getState("_vel_add_last_tick", -2));
  if (fresh) ent.setState("_vel_add_last_tick", tick);
  // Entity.get_velocity: a missing velocity is the zero 2D vector.
  const cur = ent.getState("velocity", new Vec2(0, 0));
  if (cur instanceof Vec2) ent.setVelocity(fresh ? new Vec2(vx, vz) : new Vec2(cur.x + vx, cur.y + vz));
  else if (cur instanceof Vec3) ent.setVelocity(fresh ? new Vec3(vx, 0, vz) : new Vec3(cur.x + vx, cur.y, cur.z + vz));
  else ent.setVelocity(ent.position() instanceof Vec3 ? new Vec3(vx, 0, vz) : new Vec2(vx, vz));
}

/** EffectMotion.velocity_lerp: approach (x, y) by `rate` each fire. A 3D velocity counts as zero, as in the reference. */
function velocityLerp(e: Dict, env: Env, ctx: Ctx): void {
  const ent = target(e, env, ctx);
  if (!ent) return;
  const tx = toFloat(value(e.x ?? 0, ctx, env));
  const ty = toFloat(value(e.y ?? 0, ctx, env));
  const rate = Math.min(Math.max(toFloat(value(e.rate ?? 0.15, ctx, env)), 0), 1);
  const cur = ent.getState("velocity", new Vec2(0, 0));
  const c = cur instanceof Vec2 ? cur : new Vec2(0, 0);
  ent.setVelocity(new Vec2(c.x + (tx - c.x) * rate, c.y + (ty - c.y) * rate));
}

type V3 = [number, number, number];
const toV3 = (p: Vec2 | Vec3): V3 => (p instanceof Vec3 ? [p.x, p.y, p.z] : [p.x, 0, p.y]);

/**
 * EffectMotion.raycast_hit: the nearest entity on the tag filters whose
 * `body_radius` sphere the ray meets before a `blocks_motion` box. It runs
 * on_hit with `hit` and `hit_point` bound, else on_miss.
 */
function raycastHit(e: Dict, env: Env, ctx: Ctx): void {
  const origin = toV3(position(e.origin ?? [0, 0, 0], env, ctx));
  let dir = toV3(position(e.direction ?? [0, 0, -1], env, ctx));
  const l = Math.hypot(...dir);
  if (l < 1e-6) return;
  dir = [dir[0] / l, dir[1] / l, dir[2] / l];
  const maxD = toFloat(value(e.max_distance ?? 100.0, ctx, env));
  const tagsAll = Array.isArray(e.tags_all) ? e.tags_all.map(String) : [];
  const tagsNone = Array.isArray(e.tags_none) ? e.tags_none.map(String) : [];
  let closest = maxD;
  if (e.respect_obstacles !== false) {
    for (const b of env.entities.values()) {
      if (!b.hasTag("blocks_motion") || b.properties.aabb_extents === undefined || b.properties.aabb_extents === null) continue;
      const ext = toV3(normalizeWorld(b.properties.aabb_extents));
      const off = toV3(normalizeWorld(b.properties.aabb_offset ?? [0, 0, 0]));
      const p = b.position();
      if (!(p instanceof Vec2 || p instanceof Vec3)) continue;
      const c = toV3(p).map((v, i) => v + off[i]) as V3;
      const t = rayAabb(origin, dir, c.map((v, i) => v - ext[i]) as V3, c.map((v, i) => v + ext[i]) as V3);
      if (t > 0 && t < closest) closest = t;
    }
  }
  let hit = "";
  for (const [id, ent] of env.entities) {
    if (!tagsAll.every((t) => ent.hasTag(t)) || tagsNone.some((t) => ent.hasTag(t))) continue;
    const p = ent.position();
    if (!(p instanceof Vec2 || p instanceof Vec3)) continue;
    const t = raySphere(origin, dir, toV3(p), toFloat(ent.properties.body_radius ?? 0.4));
    if (t > 0 && t < closest) {
      closest = t;
      hit = id;
    }
  }
  const sub: Ctx = { ...ctx, hit_point: new Vec3(origin[0] + dir[0] * closest, origin[1] + dir[1] * closest, origin[2] + dir[2] * closest) };
  if (hit !== "") sub.hit = hit;
  for (const x of Array.isArray(e[hit !== "" ? "on_hit" : "on_miss"]) ? (e[hit !== "" ? "on_hit" : "on_miss"] as unknown[]) : []) {
    if (isDict(x)) apply(x, env, sub);
  }
}

/** Vec3Util.from_world_pos for a property value: [x, y, z], [x, z] or one number. */
function normalizeWorld(v: unknown): Vec2 | Vec3 {
  if (typeof v === "number") return new Vec3(v, v, v);
  if (Array.isArray(v) && v.length >= 3) return new Vec3(toFloat(v[0]), toFloat(v[1]), toFloat(v[2]));
  if (Array.isArray(v) && v.length === 2) return new Vec2(toFloat(v[0]), toFloat(v[1]));
  return v instanceof Vec2 || v instanceof Vec3 ? v : new Vec3(0, 0, 0);
}

/** _ray_aabb_t: the slab method. The first t ≥ 0, or -1. */
function rayAabb(o: V3, d: V3, mn: V3, mx: V3): number {
  let near = -Infinity;
  let far = Infinity;
  for (let i = 0; i < 3; i++) {
    if (Math.abs(d[i]) < 1e-6) {
      if (o[i] < mn[i] || o[i] > mx[i]) return -1;
      continue;
    }
    let t1 = (mn[i] - o[i]) / d[i];
    let t2 = (mx[i] - o[i]) / d[i];
    if (t1 > t2) [t1, t2] = [t2, t1];
    near = Math.max(near, t1);
    far = Math.min(far, t2);
  }
  if (near > far || far < 0) return -1;
  return Math.max(near, 0);
}

/** _ray_sphere_t: the first t > 0, or -1. */
function raySphere(o: V3, d: V3, c: V3, r: number): number {
  const oc: V3 = [o[0] - c[0], o[1] - c[1], o[2] - c[2]];
  const b = oc[0] * d[0] + oc[1] * d[1] + oc[2] * d[2];
  const cc = oc[0] * oc[0] + oc[1] * oc[1] + oc[2] * oc[2] - r * r;
  const disc = b * b - cc;
  if (disc < 0) return -1;
  const sq = Math.sqrt(disc);
  if (-b - sq > 0) return -b - sq;
  if (-b + sq > 0) return -b + sq;
  return -1;
}

// ---------- resolution (effect_resolution.gd) ----------

export function entityId(v: unknown, ctx: Ctx, env: Env): string {
  if (typeof v !== "string") return "";
  if (v in ctx) return strOf(ctx[v]);
  const dot = v.indexOf(".");
  if (dot > 0 && v.slice(0, dot) in ctx) {
    const r = value(v, ctx, env);
    return r === null || r === undefined ? "" : strOf(r);
  }
  return v;
}

export const resolveId = entityId;

export function target(e: Dict, env: Env, ctx: Ctx): Entity | null {
  let id = entityId(e.target ?? "self", ctx, env);
  if (id === "world" && !env.entities.has(id)) id = WORLD_STATE_ALIAS;
  return env.entities.get(id) ?? null;
}

export function value(v: unknown, ctx: Ctx, env: Env): unknown {
  if (typeof v === "number" || typeof v === "boolean") return v;
  if (v instanceof Vec2 || v instanceof Vec3) return v;
  if (Array.isArray(v)) return v.map((x) => value(x, ctx, env));
  if (isDict(v)) {
    const out: Dict = {};
    for (const k of Object.keys(v)) out[k] = value(v[k], ctx, env) as Value;
    return out;
  }
  if (typeof v === "string") {
    if (v in ctx) return ctx[v];
    if (v.startsWith("@")) return v;
    if (looksLikeFormula(v)) {
      const fctx = formulaContext(ctx, env, v);
      return evaluate(v, fctx, env);
    }
    return v;
  }
  return v;
}

export function formulaContext(ctx: Ctx, env: Env, formula = ""): FormulaContext {
  const out: FormulaContext = {};
  for (const role of ["self", "target", "a", "b", "source", "from", "to"]) {
    if (role in ctx) {
      const e = env.entities.get(strOf(ctx[role]));
      if (e) out[role] = e;
    }
  }
  out.world = env.world;
  // ADR 0031: zone state as `zone.<id>.<field>`, built only when the text names `zone`.
  out.zone = env.zones && (formula === "" || formula.includes("zone")) ? env.zones.bindingSnapshot() : {};
  for (const pre of ["self_entity", "a_entity", "b_entity"]) {
    if (pre in ctx) out[pre.replace("_entity", "")] = ctx[pre];
  }
  for (const k of Object.keys(ctx)) {
    if (k in out || k.startsWith("_")) continue;
    const v = ctx[k];
    if (typeof v === "string" && env.entities.has(v)) out[k] = env.entities.get(v);
    else out[k] = v;
  }
  return out;
}

export function position(v: unknown, env: Env, ctx: Ctx): Vec2 | Vec3 {
  if (v instanceof Vec2 || v instanceof Vec3) return v;
  if (Array.isArray(v)) {
    if (v.length === 2) return new Vec2(toFloat(value(v[0], ctx, env)), toFloat(value(v[1], ctx, env)));
    if (v.length === 3) {
      return new Vec3(toFloat(value(v[0], ctx, env)), toFloat(value(v[1], ctx, env)), toFloat(value(v[2], ctx, env)));
    }
  }
  if (typeof v === "string" && v in ctx) {
    const e = env.entities.get(strOf(ctx[v]));
    if (e) {
      const p = e.position();
      if (p instanceof Vec2 || p instanceof Vec3) return p;
    }
  }
  return new Vec2(0, 0);
}
