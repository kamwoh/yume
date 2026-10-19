// Runs a game's tests.json. Mirrors scenario_runner.gd and step_runner.gd
// for the steps press, hold, release, click, tick, wait and expect.
// Input follows InputRegistrar.poll (input.ts). Each scenario world has a
// ScreenFlow (screen_flow.ts), as WorldBoot mounts one in the reference, so
// a `click` presses a button of an open screen.
import { Entity } from "./entity.ts";
import { type Files, join } from "./files.ts";
import { pollInput } from "./input.ts";
import { PHYSICS_DT } from "./live.ts";
import { attachBody } from "./physics.ts";
import { matches } from "./query.ts";
import { SpecRandom } from "./random.ts";
import { ScreenFlow } from "./screen_flow.ts";
import { type Dict, Vec2, Vec3, isDict, normalizePosition, toFloat } from "./value.ts";
import { World } from "./world.ts";

export type Result = { passed: number; failed: number; failures: string[]; errors: string[] };

const ASSERT_KEYS: Record<string, string[]> = {
  entity_field: ["query", "id", "field", "op", "value"],
  entity_count: ["query", "op", "value"],
  world_field: ["field", "op", "value"],
  relation_field: ["relation", "from_query", "to_query", "field", "op", "value"],
};

/** Builds the physics host of each scenario world (physics_rapier.ts), or null for none. */
export type PhysicsFactory = World["physicsFactory"];

export function runGame(root: string, files: Files, verbose = false, libRoot = "", physics: PhysicsFactory = null): Result {
  const res: Result = { passed: 0, failed: 0, failures: [], errors: [] };
  const text = files.read(join(root, "tests.json"));
  if (text === null) return res;
  const spec = JSON.parse(text);
  for (const sc of Array.isArray(spec.scenarios) ? spec.scenarios : []) {
    if (!isDict(sc) || sc._skip) continue;
    runScenario(root, files, sc, res, verbose, libRoot, physics);
  }
  return res;
}

class Runner {
  world: World;
  name: string;
  res: Result;
  verbose: boolean;
  held = new Set<string>();
  justPressed = new Set<string>();
  flow: ScreenFlow;
  /** ScreenFlow._last_action_state: the actions held at the last frame-observer pass. */
  private observed = new Set<string>();

  constructor(world: World, flow: ScreenFlow, name: string, res: Result, verbose: boolean) {
    this.world = world;
    this.flow = flow;
    this.name = name;
    this.res = res;
    this.verbose = verbose;
  }

  pass(msg: string): void {
    this.res.passed++;
    if (this.verbose) console.log(`  ✓ ${msg}`);
  }
  fail(msg: string): void {
    this.res.failed++;
    this.res.failures.push(`${this.name} — ${msg}`);
    if (this.verbose) console.log(`  ✗ ${msg}`);
  }

  poll(): void {
    pollInput(this.world, this.held, this.justPressed);
  }

  /**
   * step_runner._advance: one tick, the character bodies (tick_headless),
   * one physics step when the world has an articulated body (_step_physics),
   * then the pending swaps that the shell drains in live play.
   */
  private advance(): void {
    this.world.advanceOneTick();
    const ph = this.world.env.physics;
    if (ph) {
      ph.tickCharactersHeadless(this.world.tickSeconds);
      if (ph.hasArticulated()) ph.step(PHYSICS_DT);
    }
    this.world.processPending();
  }

  /**
   * step_runner._tick_frame_observers: the work of a live frame for the UI.
   * ScreenFlow drains its records, then fires the global inputs whose action
   * went down since the last pass.
   */
  private observe(): void {
    this.flow.drain();
    const edges = new Set([...this.held].filter((a) => !this.observed.has(a)));
    this.observed = new Set(this.held);
    this.flow.globalInputs(edges);
  }

  step(step: Dict): void {
    const verb = ["press", "hold", "release", "click", "wait", "tick", "screenshot", "expect", "key"].find((v) => v in step);
    switch (verb) {
      case "press": {
        const a = String(step.press);
        if (!this.world.knowsAction(a)) return this.error(`press: unknown action '${a}'`);
        this.held.add(a);
        this.justPressed.add(a);
        this.poll();
        this.advance();
        this.observe();
        this.held.delete(a);
        this.observe();
        return;
      }
      case "hold": {
        const actions = Array.isArray(step.hold) ? step.hold.map(String) : [String(step.hold)];
        for (const a of actions) if (!this.world.knowsAction(a)) return this.error(`hold: unknown action '${a}'`);
        if (!("for" in step) || toFloat(step.for) <= 0) return this.error("hold requires a positive 'for' (seconds)");
        for (const a of actions) {
          if (!this.held.has(a)) this.justPressed.add(a);
          this.held.add(a);
        }
        const ticks = Math.max(1, Math.round(toFloat(step.for) / this.world.tickSeconds));
        for (let i = 0; i < ticks; i++) {
          this.poll();
          this.advance();
        }
        this.observe();
        for (const a of actions) this.held.delete(a);
        this.observe();
        return;
      }
      case "release":
        this.held.delete(String(step.release));
        return;
      case "tick": {
        const n = Math.trunc(toFloat(step.tick));
        if (n <= 0) return this.error("tick requires a positive count");
        for (let i = 0; i < n; i++) this.advance();
        this.observe();
        return;
      }
      case "wait": {
        const s = step.wait;
        let ticks = 0;
        if (typeof s === "number") ticks = Math.max(1, Math.round(s / this.world.tickSeconds));
        else if (isDict(s)) {
          if ("ticks" in s) ticks = Math.trunc(toFloat(s.ticks));
          else if ("seconds" in s) ticks = Math.max(1, Math.round(toFloat(s.seconds) / this.world.tickSeconds));
        }
        if (ticks <= 0) return this.error("wait requires positive seconds or ticks");
        for (let i = 0; i < ticks; i++) this.advance();
        this.observe();
        return;
      }
      case "expect": {
        const list = Array.isArray(step.expect) ? step.expect : [step.expect];
        for (const a of list) if (isDict(a)) this.check(a);
        return;
      }
      case "click":
        return this.click(step.click);
      case "screenshot":
      case "key":
        return this.error(`step '${verb}' needs a UI and is not in this host yet (ADR 0095 phase 4)`);
    }
    this.error(`unknown step verb in ${JSON.stringify(Object.keys(step))}`);
  }

  /**
   * step_runner._do_click: press the one control of an open screen that the
   * selector names ({id}, {text} or a bare text), drain the stack, then
   * advance one tick.
   */
  private click(selector: unknown): void {
    const sel: Dict = isDict(selector) ? selector : { text: String(selector) };
    const found = this.flow.findControls(sel);
    if (found.length === 0) return this.error(`[step.click_not_found] click selector matched nothing: ${JSON.stringify(sel)}`);
    if (found.length > 1 && !("screen" in sel)) {
      return this.error(`[step.click_ambiguous] click selector matched ${found.length} controls; add 'screen' to disambiguate`);
    }
    this.flow.press(found[0]);
    this.flow.drain();
    this.advance();
  }

  error(msg: string): void {
    this.res.errors.push(`${this.name} — ${msg}`);
    this.fail(msg);
  }

  query(q: Dict): Entity[] {
    return [...this.world.env.entities.values()].filter((e) => matches(e, q, this.world.env));
  }

  check(a: Dict): void {
    for (const kind of Object.keys(ASSERT_KEYS)) {
      const body = a[kind];
      if (!isDict(body)) continue;
      for (const k of Object.keys(body)) {
        if (!k.startsWith("_") && !ASSERT_KEYS[kind].includes(k)) {
          return this.fail(`${kind}: unknown key '${k}'`);
        }
      }
    }
    if (isDict(a.entity_field)) return this.entityField(a.entity_field);
    if (isDict(a.entity_count)) {
      const s = a.entity_count;
      const got = this.query(isDict(s.query) ? s.query : {}).length;
      const op = String(s.op ?? "==");
      const want = toFloat(s.value ?? 0);
      return cmp(got, op, want) ? this.pass(`entity_count ${op} ${want}`) : this.fail(`entity_count: expected ${op} ${want}, got ${got}`);
    }
    if (isDict(a.world_field)) {
      const s = a.world_field;
      const f = String(s.field ?? "");
      const got = f in this.world.env.world ? this.world.env.world[f] : null;
      const op = String(s.op ?? "==");
      return cmp(got, op, s.value ?? null)
        ? this.pass(`world_field ${f}`)
        : this.fail(`world_field ${f}: expected ${op} ${fmt(s.value)}, got ${fmt(got)}`);
    }
    if (isDict(a.relation_field)) return this.relationField(a.relation_field);
    if ("ui_present" in a || "ui_hidden" in a) {
      const want = "ui_present" in a;
      const v = want ? a.ui_present : a.ui_hidden;
      const sel: Dict = isDict(v) ? v : { text: String(v) };
      const present = this.flow.findControls(sel).length > 0;
      const label = `ui_${want ? "present" : "hidden"} ${JSON.stringify(sel)}`;
      return present === want ? this.pass(label) : this.fail(`${label}: was ${present ? "present" : "hidden"}`);
    }
    if ("screen_active" in a) {
      const want = String(a.screen_active);
      const got = this.flow.currentScreen;
      return got === want ? this.pass(`screen_active == ${want}`) : this.fail(`screen_active: expected ${want}, got ${got}`);
    }
    const keys = Object.keys(a).filter((k) => !k.startsWith("_"));
    if (keys.length === 1 && isDict(a[keys[0]])) return this.compact(keys[0], a[keys[0]] as Dict);
    this.fail(`expect: assertion shape not in this host: ${JSON.stringify(a)}`);
  }

  entityField(s: Dict): void {
    let ent: Entity | undefined;
    if ("id" in s) {
      ent = this.world.env.entities.get(String(s.id));
      if (!ent) return this.fail(`entity_field id=${s.id}: no such entity`);
    } else {
      const m = this.query(isDict(s.query) ? s.query : {});
      if (m.length === 0) return this.fail(`entity_field ${JSON.stringify(s.query)}: no entities matched`);
      ent = m[0];
    }
    const field = String(s.field ?? "");
    const got = resolveField(ent, field);
    const op = String(s.op ?? "==");
    const want = s.value ?? 0;
    if (cmp(got, op, want)) this.pass(`entity_field ${field} ${op} ${fmt(want)}`);
    else this.fail(`entity_field ${JSON.stringify(s.query ?? s.id)}.${field}: expected ${op} ${fmt(want)}, got ${fmt(got)}`);
  }

  relationField(s: Dict): void {
    const rel = String(s.relation ?? "");
    const field = String(s.field ?? "");
    const from = this.query(isDict(s.from_query) ? s.from_query : {});
    const to = this.query(isDict(s.to_query) ? s.to_query : {});
    if (from.length === 0 || to.length === 0) return this.fail(`relation_field ${rel}: a query matched no entities`);
    const store = this.world.env.relations;
    if (!store.hasEdge(rel, from[0].id, to[0].id)) return this.fail(`relation_field ${rel}: no such relation edge exists`);
    const edge = store.edgeState(rel, from[0].id, to[0].id);
    if (!(field in edge)) return this.fail(`relation_field ${rel}: edge carries no field '${field}'`);
    const op = String(s.op ?? "==");
    cmp(edge[field], op, s.value ?? 0)
      ? this.pass(`relation_field ${rel}.${field}`)
      : this.fail(`relation_field ${rel}.${field}: expected ${op} ${fmt(s.value)}, got ${fmt(edge[field])}`);
  }

  compact(path: string, opDict: Dict): void {
    const dot = path.indexOf(".");
    if (dot < 0) return this.fail(`expect compact: path '${path}' has no '.'`);
    const prefix = path.slice(0, dot);
    const rest = path.slice(dot + 1);
    const ops = Object.keys(opDict);
    const op = ops.length === 1 ? ops[0] : "==";
    const want = op in opDict ? opDict[op] : 0;
    let got: unknown;
    if (prefix === "world") {
      got = this.world.env.world;
      for (const p of rest.split(".")) got = isDict(got) && p in got ? got[p] : null;
    } else {
      const m = this.query({ tags_all: [prefix] });
      if (m.length === 0) return this.fail(`expect compact: no entity tagged '${prefix}'`);
      got = resolveField(m[0], rest);
    }
    cmp(got, op, want) ? this.pass(`${path} ${op} ${fmt(want)}`) : this.fail(`${path}: expected ${op} ${fmt(want)}, got ${fmt(got)}`);
  }
}

function runScenario(root: string, files: Files, sc: Dict, res: Result, verbose: boolean, libRoot: string, physics: PhysicsFactory): void {
  const name = String(sc.name ?? "<unnamed>");
  if (verbose) console.log(`\n[scenario] ${name}`);
  const world = new World(root, files, libRoot);
  world.physicsFactory = physics;
  world.variantOverride = String(sc.variant ?? "");
  world.load();
  // WorldBoot mounts ScreenFlow in load_data, so its lists see the loaded world and not the setup.
  const flow = new ScreenFlow(() => world, readScreens(world, root, files), readJson(files, join(root, "ui/strings.json")));
  flow.start();
  if ("seed" in sc) SpecRandom.shared.setSeed(Math.trunc(toFloat(sc.seed)));
  if (isDict(sc.setup)) applySetup(world, sc.setup);
  if (!Array.isArray(sc.steps)) {
    res.failed++;
    res.failures.push(`${name} — scenario has no 'steps'`);
    return;
  }
  const r = new Runner(world, flow, name, res, verbose);
  for (const step of sc.steps) if (isDict(step)) r.step(step);
  for (const e of world.env.errors) if (e.severity === "error") res.errors.push(`${name} — [${e.code}] ${e.message}`);
}

/** ScreenFlow._load_config: screens.json with its lib references resolved, or {} for none. */
function readScreens(world: World, root: string, files: Files): Dict {
  const cfg = readJson(files, join(root, "screens.json"));
  const out = world.lib.resolve(cfg);
  return isDict(out) ? out : {};
}

function readJson(files: Files, path: string): Dict {
  const text = files.read(path);
  if (text === null) return {};
  const v = JSON.parse(text);
  return isDict(v) ? v : {};
}

/** step_runner._resolve_field: state.* and properties.* paths, vectors by x/y/z. */
function resolveField(e: Entity, path: string): unknown {
  let cur: unknown = e;
  for (const p of path.split(".")) {
    if (cur instanceof Entity) {
      if (p === "state") cur = cur.state;
      else if (p === "properties") cur = cur.properties;
      else return null;
    } else if (cur instanceof Vec2) {
      if (p === "x") cur = cur.x;
      else if (p === "y") cur = cur.y;
      else return null;
    } else if (cur instanceof Vec3) {
      if (p === "x") cur = cur.x;
      else if (p === "y") cur = cur.y;
      else if (p === "z") cur = cur.z;
      else return null;
    } else if (isDict(cur)) {
      if (!(p in cur)) return null;
      cur = cur[p];
    } else return null;
  }
  return cur;
}

/** step_runner._cmp: a number compares as a float, anything else by its text. */
function cmp(got: unknown, op: string, want: unknown): boolean {
  if (typeof got === "number") {
    const x = toFloat(want);
    switch (op) {
      case "==":
        return got === x;
      case "!=":
        return got !== x;
      case "<":
        return got < x;
      case "<=":
        return got <= x;
      case ">":
        return got > x;
      case ">=":
        return got >= x;
    }
    return false;
  }
  if (op === "==") return text(got) === text(want);
  if (op === "!=") return text(got) !== text(want);
  return false;
}

function text(v: unknown): string {
  if (v === null || v === undefined) return "<null>";
  if (typeof v === "number") return Number.isInteger(v) ? `${v}` : `${v}`;
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "string") return v;
  return JSON.stringify(v);
}

function fmt(v: unknown): string {
  return text(v);
}


/** ScenarioRunner._apply_setup: world_state, spawn, then entity_state. */
function applySetup(world: World, setup: Dict): void {
  const env = world.env;
  if (isDict(setup.world_state)) for (const k of Object.keys(setup.world_state)) env.world[k] = setup.world_state[k];
  let n = 0;
  for (const spec of Array.isArray(setup.spawn) ? setup.spawn : []) {
    if (!isDict(spec)) continue;
    const template = String(spec.def ?? "");
    const def = env.defs.get(template);
    if (!def) continue;
    const override: Dict = {};
    for (const k of ["position", "state", "tags", "properties"]) if (k in spec) override[k] = spec[k];
    const id = String(spec.id ?? `${template}_setup_${n++}`);
    const ent = Entity.create(def, id, override);
    env.entities.set(id, ent);
    attachBody(env, ent, def);
  }
  if (isDict(setup.entity_state)) {
    for (const id of Object.keys(setup.entity_state)) {
      const ent = env.entities.get(id);
      const fields = setup.entity_state[id];
      if (!ent || !isDict(fields)) continue;
      for (const k of Object.keys(fields)) {
        const v = fields[k];
        ent.state[k] = (k === "position" || k === "velocity") && Array.isArray(v) ? normalizePosition(v) : v;
      }
    }
  }
}
