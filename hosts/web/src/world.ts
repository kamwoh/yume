// A world: entities, rules and state loaded from a game folder. Mirrors
// world.gd, world_boot.gd and world_loader.gd for the parts in ADR 0095
// phase 1. Features outside phase 1 raise host.unsupported once at load.
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { Entity } from "./entity.ts";
import type { Env } from "./env.ts";
import { raise } from "./env.ts";
import { LibResolver } from "./lib_resolver.ts";
import { SpecRandom } from "./random.ts";
import { RelationStore } from "./relations.ts";
import { Rule, VALID_TRIGGERS } from "./rule.ts";
import { PhaseScheduler } from "./scheduler.ts";
import { type Dict, isDict, toFloat } from "./value.ts";

const UNSUPPORTED_FILES = ["game/flow.json", "macros.json", "actors.json", "world/zones.json", "chunks"];

export class World {
  root: string;
  env: Env;
  scheduler: PhaseScheduler;
  lib: LibResolver;
  engineRules: Rule[] = [];
  actionsPress: string[] = [];
  actionsHold: string[] = [];
  tickSeconds = 0.0167;
  actorTag = "player";
  stopActionOnIdle = "stop";
  simTick = 0;

  libRoot: string;

  /** `libRoot` defaults to the `lib/` folder next to the game folder, as in the reference. */
  constructor(root: string, libRoot = "") {
    this.root = root.replace(/\/+$/, "");
    this.libRoot = libRoot !== "" ? libRoot : join(dirname(this.root), "lib");
    const world: Dict = {};
    this.env = {
      entities: new Map(),
      defs: new Map(),
      relations: new RelationStore(),
      world,
      signalBuffer: [],
      nextId: { n: 0 },
      errors: [],
      shellEvents: [],
      dispatchLifecycle: null,
      advanceCalendar: null,
    };
    this.scheduler = new PhaseScheduler(this.env);
    this.lib = new LibResolver(this.libRoot);
  }

  /** world.gd load_data + WorldBoot.run, in the same order. */
  load(): void {
    const scene = this.readJson("scene.json");
    if (isDict(scene)) {
      if ("tick_seconds" in scene) this.tickSeconds = toFloat(scene.tick_seconds);
      const ws = scene.world_seed;
      if (typeof ws === "number" && Math.trunc(ws) !== 0) SpecRandom.shared.setSeed(Math.trunc(ws));
    }
    for (const f of UNSUPPORTED_FILES) {
      if (existsSync(join(this.root, f))) raise(this.env, "host.unsupported", `${f} is not in this host yet (ADR 0095 phase 1)`, "warning");
    }
    this.spawnEngineEntity();
    this.loadEngineRules();
    this.registerInputs();
    if (isDict(scene) && "level_seed" in scene) SpecRandom.shared.setSeed(Math.trunc(toFloat(scene.level_seed)));
    this.env.world.active_actor_id = "default_player";
    this.loadRulesFor("world/rules.json", false);
    this.loadRulesFor("game/goals.json", true);
    this.loadRulesFile(join(this.root, "tutorial.json"), true);
    this.loadWorldFile();
    this.loadEntities();
    if (!existsSync(join(this.root, "save_policy.json"))) this.env.world.has_save = 0;
    else this.env.world.has_save = 0;
    this.scheduler.flush();
  }

  private spawnEngineEntity(): void {
    const e = new Entity();
    e.id = "_engine";
    e.defId = "_engine";
    e.tags = ["_engine", "persistent"];
    e.state = this.env.world;
    this.env.entities.set("_engine", e);
  }

  private loadEngineRules(): void {
    const dir = join(this.libRoot, "engine_rules");
    if (!existsSync(dir)) return;
    for (const f of readdirSync(dir).filter((x) => x.endsWith(".json")).sort()) {
      const rules = this.parseRules(join(dir, f));
      this.engineRules.push(...rules);
      this.scheduler.appendRules(rules);
    }
  }

  private registerInputs(): void {
    const raw = this.readJson("ui/input.json");
    if (!isDict(raw)) return;
    const spec = this.lib.resolve(raw);
    if (!isDict(spec)) return;
    const edgeByName = new Map<string, string>();
    for (const a of Array.isArray(spec.actions) ? spec.actions : []) {
      if (!isDict(a)) continue;
      const name = String(a.name ?? "");
      if (name === "") continue;
      edgeByName.set(name, String(a.edge ?? "press") === "hold" ? "hold" : "press");
    }
    for (const [name, edge] of edgeByName) (edge === "hold" ? this.actionsHold : this.actionsPress).push(name);
  }

  knowsAction(a: string): boolean {
    return this.actionsPress.includes(a) || this.actionsHold.includes(a);
  }

  private parseRules(path: string): Rule[] {
    if (!existsSync(path)) return [];
    let data: unknown;
    try {
      data = JSON.parse(readFileSync(path, "utf8"));
    } catch {
      raise(this.env, "rule.invalid_json", `Rules file is not valid JSON: ${path}`);
      return [];
    }
    const resolved = this.lib.resolve(data);
    if (!isDict(resolved)) return [];
    const list = resolved.rules;
    if (!Array.isArray(list)) {
      raise(this.env, "rule.list_not_array", `${path}: 'rules' must be an array`);
      return [];
    }
    const rules = list.filter(isDict).map((d) => Rule.fromDict(d));
    for (const r of rules) {
      if (r.id === "") raise(this.env, "rule.missing_id", "a rule has no id");
      else if (!VALID_TRIGGERS.includes(r.triggerType())) raise(this.env, "rule.trigger_invalid", `rule '${r.id}': invalid trigger`);
    }
    return rules;
  }

  /** WorldLoader.load_rules_file. A replace keeps the engine rules (ADR 0049). */
  loadRulesFile(path: string, append: boolean): void {
    if (!existsSync(path)) return;
    const rules = this.parseRules(path);
    if (append) this.scheduler.appendRules(rules);
    else this.scheduler.registerRules([...this.engineRules, ...rules]);
  }

  /** WorldLoader.load_rules_files_for: a folder of rule files in name order, or one file. */
  private loadRulesFor(rel: string, append: boolean): void {
    const dir = join(this.root, rel.replace(/\.json$/, ""));
    if (existsSync(dir)) {
      let first = true;
      for (const f of readdirSync(dir).filter((x) => x.endsWith(".json")).sort()) {
        this.loadRulesFile(join(dir, f), first ? append : true);
        first = false;
      }
      return;
    }
    this.loadRulesFile(join(this.root, rel), append);
  }

  private loadWorldFile(): void {
    const data = this.readJson("world/state.json");
    if (isDict(data) && isDict(data.state)) Object.assign(this.env.world, data.state);
  }

  private loadEntities(): void {
    const docs: Dict[] = [];
    const single = this.readJson("entities.json");
    if (isDict(single)) docs.push(this.lib.resolve(single) as Dict);
    const dir = join(this.root, "entities");
    if (existsSync(dir)) {
      for (const f of readdirSync(dir).filter((x) => x.endsWith(".json")).sort()) {
        const d = this.readJson(join("entities", f));
        if (isDict(d)) docs.push(this.lib.resolve(d) as Dict);
      }
    }
    for (const d of docs) for (const def of asList(d.definitions)) if (isDict(def)) this.env.defs.set(String(def.id ?? ""), def);
    for (const d of docs) {
      if (asList(d.patterns).length > 0) raise(this.env, "host.unsupported", "instance patterns are host-side scatter, not in this host yet", "warning");
    }
    for (const d of docs) {
      for (const inst of asList(d.initial_instances)) if (isDict(inst)) this.spawnInstance(inst);
      for (const rel of asList(d.initial_relations)) {
        if (!isDict(rel)) continue;
        this.env.relations.relate(String(rel.type ?? ""), String(rel.from ?? ""), String(rel.to ?? ""), isDict(rel.state) ? rel.state : {});
      }
    }
  }

  /** SpawnManager.spawn for an initial instance. */
  spawnInstance(inst: Dict): void {
    const defId = String(inst.def ?? "");
    const def = this.env.defs.get(defId);
    if (!def) {
      raise(this.env, "world.def_unknown", `Unknown def: ${defId}`);
      return;
    }
    const count = Math.trunc(toFloat(inst.count ?? 1));
    for (let i = 0; i < count; i++) {
      const overrides: Dict = isDict(inst.overrides) ? structuredCopy(inst.overrides) : {};
      for (const k of ["state", "position", "tags", "properties", "visual"]) {
        if (k in inst && !(k in overrides)) overrides[k] = inst[k];
      }
      let id: string;
      if ("id" in inst && count === 1) id = String(inst.id);
      else {
        id = `${defId}_${this.env.nextId.n}`;
        this.env.nextId.n += 1;
      }
      if (isDict(def.physics)) {
        raise(this.env, "host.unsupported", `def '${defId}': physics bodies are phase 3 of ADR 0095`, "warning");
      }
      const e = Entity.create(def, id, overrides);
      this.env.entities.set(id, e);
      this.env.dispatchLifecycle?.("spawn", id);
    }
  }

  /** world.gd advance_one_tick, for the parts in phase 1. */
  advanceOneTick(): void {
    this.simTick += 1;
    this.env.world._tick = this.simTick;
    this.scheduler.tick();
  }

  /** ActorManager.resolve_active_entity for the default actor: the first entity with the actor tag. */
  activeActorId(): string {
    for (const e of this.env.entities.values()) if (e.hasTag(this.actorTag)) return e.id;
    return "";
  }

  private readJson(rel: string): unknown {
    const p = join(this.root, rel);
    if (!existsSync(p)) return null;
    try {
      return JSON.parse(readFileSync(p, "utf8"));
    } catch {
      raise(this.env, "world.invalid_json", `Invalid JSON: ${p}`);
      return null;
    }
  }
}

function asList(v: unknown): unknown[] {
  return Array.isArray(v) ? v : [];
}

function structuredCopy(d: Dict): Dict {
  return JSON.parse(JSON.stringify(d));
}
