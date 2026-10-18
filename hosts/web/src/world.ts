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
import { type Dict, type Value, isDict, toFloat } from "./value.ts";

const UNSUPPORTED_FILES = ["macros.json", "actors.json", "world/zones.json", "chunks"];

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
  /** ADR 0006 progression (game/flow.json). */
  levelOrder: string[] = [];
  levelPersistentTags: string[] = ["persistent"];
  levelsRoot = "";
  onAllCompleteMsg = "";
  /** VariantOverlay precedence 1: a scenario's `variant` field. */
  variantOverride = "";
  savePolicy: Dict = {};

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
      pendingLevel: "",
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
    this.loadContent();
    this.applyVariant();
    this.loadSavePolicy();
    this.scheduler.flush();
  }

  get currentLevel(): string {
    return String(this.env.world.current_level ?? "");
  }

  /** ADR 0047: current_level writes through to world state. */
  set currentLevel(v: string) {
    this.env.world.current_level = v;
  }

  /** WorldBoot._load_content: the progression, the global rules, then the starting level. */
  private loadContent(): void {
    const prog = join(this.root, "game/flow.json");
    if (existsSync(prog)) this.loadProgression(prog);
    this.loadGlobalRules();
    this.loadWorldFile();
    this.loadEntities(this.root);
    if (this.levelsRoot !== "" && this.currentLevel !== "") this.loadLevel(this.currentLevel);
  }

  private loadGlobalRules(): void {
    this.loadRulesFor(join(this.root, "world/rules.json"), false);
    this.loadRulesFor(join(this.root, "game/goals.json"), true);
    this.loadRulesFile(join(this.root, "tutorial.json"), true);
  }

  /** WorldLoader.load_progression. */
  private loadProgression(path: string): void {
    const p = this.readJson(path.slice(this.root.length + 1));
    if (!isDict(p)) return;
    this.levelOrder = asList(p.levels).map(String);
    const ptags = p.persistent_tags;
    if (Array.isArray(ptags) && ptags.length > 0) this.levelPersistentTags = ptags.map(String);
    this.currentLevel = String(p.starting_level ?? (this.levelOrder[0] ?? ""));
    this.levelsRoot = join(this.root, "levels");
    if (isDict(p.on_all_complete)) this.onAllCompleteMsg = String(p.on_all_complete.win_message ?? "");
  }

  /** LevelTransitionCoordinator.load_level: the level rules (appended), then its entities. */
  private loadLevel(name: string): void {
    if (this.levelsRoot === "" || name === "") return;
    const dir = join(this.levelsRoot, name);
    this.loadRulesFor(join(dir, "rules.json"), true);
    this.loadEntities(dir);
  }

  /** LevelTransitionCoordinator.process_pending. The host drains it after each tick. */
  processPending(): void {
    const pending = this.env.pendingLevel;
    if (pending === "") return;
    this.env.pendingLevel = "";
    this.doTransition(pending);
  }

  /** LevelTransitionCoordinator.do_transition. */
  doTransition(target: string): void {
    if (target === "next") {
      const idx = this.levelOrder.indexOf(this.currentLevel);
      if (idx >= 0 && idx + 1 < this.levelOrder.length) target = this.levelOrder[idx + 1];
      else {
        this.env.world.all_levels_complete = 1;
        return;
      }
    }
    if (!this.levelOrder.includes(target)) {
      raise(this.env, "level.unknown_target", `transition_level target '${target}' not in progression.levels`, "warning");
      return;
    }
    // Entities with any persistent tag survive the swap (Invariant #12).
    // The engine-owned `_engine` entity always survives.
    const keep = [...this.levelPersistentTags, "_engine"];
    for (const [id, e] of [...this.env.entities]) {
      if (keep.some((t) => e.hasTag(t))) continue;
      this.env.relations.clearEntity(id);
      this.env.entities.delete(id);
    }
    this.scheduler.clearRules();
    this.loadGlobalRules();
    this.currentLevel = target;
    this.loadLevel(target);
    this.scheduler.flush();
    const auto = this.savePolicy.autosave;
    if (isDict(auto) && Boolean(auto.on_level_transition)) {
      // Saving is host-defined storage (ADR 0086). This host records the request.
      this.env.shellEvents.push({ type: "save_state", slot: 0, autosave: true });
    }
  }

  /** VariantOverlay.apply (ADR 0009 phase 2d): rule, world-state and entity overrides. */
  private applyVariant(): void {
    let name = this.variantOverride;
    if (name === "") {
      const scene = this.readJson("scene.json");
      if (isDict(scene) && String(scene.variant ?? "") !== "") name = String(scene.variant);
    }
    if (name === "") name = process.env.YUME_VARIANT ?? "";
    if (name === "") return;
    const v = this.readJson(join("variants", `${name}.json`));
    if (!isDict(v)) return;
    for (const [rid, fields] of Object.entries(isDict(v.rules) ? v.rules : {})) {
      const rule = this.scheduler.ruleById(rid);
      if (!rule) {
        raise(this.env, "variant.rule_unknown", `variant rule '${rid}' not found`, "warning");
        continue;
      }
      if (!isDict(fields)) continue;
      for (const [path, val] of Object.entries(fields)) applyRuleOverride(this.env, rule, path, val);
    }
    if (isDict(v.world_state)) Object.assign(this.env.world, v.world_state);
    for (const [id, st] of Object.entries(isDict(v.entities) ? v.entities : {})) {
      const e = this.env.entities.get(id);
      if (!e) {
        raise(this.env, "variant.entity_unknown", `variant entity '${id}' not found`, "warning");
        continue;
      }
      if (isDict(st)) for (const [k, val] of Object.entries(st)) e.state[k] = val;
    }
  }

  /** WorldBoot._load_save_policy. This host keeps no saves, so has_save is 0. */
  private loadSavePolicy(): void {
    const p = this.readJson("save_policy.json");
    this.savePolicy = isDict(p) ? p : {};
    this.env.world.has_save = 0;
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
      this.scheduler.pinnedRules.push(...rules);
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
    else this.scheduler.registerRules(rules);
  }

  /** WorldLoader.load_rules_files_for: a folder of rule files in name order, or one file. */
  private loadRulesFor(path: string, append: boolean): void {
    const dir = path.replace(/\.json$/, "");
    if (existsSync(dir)) {
      let first = true;
      for (const f of readdirSync(dir).filter((x) => x.endsWith(".json")).sort()) {
        this.loadRulesFile(join(dir, f), first ? append : true);
        first = false;
      }
      return;
    }
    this.loadRulesFile(path, append);
  }

  private loadWorldFile(): void {
    const data = this.readJson("world/state.json");
    if (isDict(data) && isDict(data.state)) Object.assign(this.env.world, data.state);
  }

  /** WorldLoader.load_entities_path: entities.json, then entities/*.json in name order. */
  private loadEntities(root: string): void {
    const docs: Dict[] = [];
    const single = this.readAbs(join(root, "entities.json"));
    if (isDict(single)) docs.push(this.lib.resolve(single) as Dict);
    const dir = join(root, "entities");
    if (existsSync(dir)) {
      for (const f of readdirSync(dir).filter((x) => x.endsWith(".json")).sort()) {
        const d = this.readAbs(join(dir, f));
        if (isDict(d)) docs.push(this.lib.resolve(d) as Dict);
      }
    }
    if (docs.length === 0) {
      raise(this.env, "world.entities_missing", `No entities found at ${root} (checked entities.json + entities/)`, "warning");
      return;
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
      // The persistent-clobber guard (Invariant #12): a level that declares a
      // persistent entity again moves it, and keeps its state.
      const existing = this.env.entities.get(id);
      if (existing && this.levelPersistentTags.some((t) => existing.hasTag(t))) {
        const p = inst.position;
        if (Array.isArray(p) && p.length >= 2) existing.setPosition(p as Value);
        continue;
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
    return this.readAbs(join(this.root, rel));
  }

  private readAbs(p: string): unknown {
    if (!existsSync(p)) return null;
    try {
      return JSON.parse(readFileSync(p, "utf8"));
    } catch {
      raise(this.env, "world.invalid_json", `Invalid JSON: ${p}`);
      return null;
    }
  }
}

/** VariantOverlay._apply_rule_override: chance, effect.<key>, effects.<idx>.<key>. */
function applyRuleOverride(env: Env, rule: Rule, path: string, val: unknown): void {
  if (path === "chance") {
    rule.chance = toFloat(val);
    return;
  }
  let idx = 0;
  let key = "";
  if (path.startsWith("effect.")) key = path.slice("effect.".length);
  else if (path.startsWith("effects.")) {
    const rest = path.slice("effects.".length);
    const dot = rest.indexOf(".");
    if (dot < 0) {
      raise(env, "variant.bad_path", `malformed effects path '${path}'`, "warning");
      return;
    }
    idx = Math.trunc(Number(rest.slice(0, dot)));
    key = rest.slice(dot + 1);
  } else {
    raise(env, "variant.bad_path", `unsupported override path '${path}' on rule '${rule.id}'`, "warning");
    return;
  }
  if (idx < 0 || idx >= rule.effects.length) {
    raise(env, "variant.bad_path", `rule '${rule.id}' effects index ${idx} out of range`, "warning");
    return;
  }
  rule.effects[idx][key] = val as Dict[string];
}

function asList(v: unknown): unknown[] {
  return Array.isArray(v) ? v : [];
}

function structuredCopy(d: Dict): Dict {
  return JSON.parse(JSON.stringify(d));
}
