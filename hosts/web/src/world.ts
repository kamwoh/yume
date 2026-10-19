// A world: entities, rules and state loaded from a game folder. Mirrors
// world.gd, world_boot.gd and world_loader.gd for the parts in ADR 0095
// phase 1. Features outside phase 1 raise host.unsupported once at load.
import { type Files, dirname, join } from "./files.ts";
import type { Bounds } from "./glb.ts";
import { Entity } from "./entity.ts";
import type { Env } from "./env.ts";
import { raise } from "./env.ts";
import { LibResolver } from "./lib_resolver.ts";
import { expandPattern } from "./patterns.ts";
import { type PhysicsHost, attachBody } from "./physics.ts";
import { SpecRandom } from "./random.ts";
import { RelationStore } from "./relations.ts";
import { Rule, VALID_TRIGGERS } from "./rule.ts";
import { PhaseScheduler } from "./scheduler.ts";
import { MemorySaveStore, type SaveStore, buildPayload, hasAnySave, readSlot } from "./save.ts";
import { type Dict, type Value, Vec3, isDict, normalizePosition, toFloat } from "./value.ts";

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
  /** scene.json level_seed: the base of each pattern's stream (ADR 0060). */
  levelSeed = 0;
  /** VariantOverlay precedence 1: a scenario's `variant` field. */
  variantOverride = "";
  savePolicy: Dict = {};

  libRoot: string;
  files: Files;
  /** The key names of each action, from ui/input.json (InputRegistrar). */
  actionKeys = new Map<string, string[]>();
  /** The mouse button names of each action (`mouse_button`, `mouse_buttons`). */
  actionMouse = new Map<string, string[]>();
  /** Where saves live (host-defined, ADR 0086). A scenario run keeps them in memory. */
  saveStore: SaveStore = MemorySaveStore.shared;
  /** The save namespace: the game folder name (SaveLoadCoordinator.game_name_from_root). */
  gameName = "";

  /**
   * Builds the physics host (ADR 0095 phase 3) from the layer names and a
   * GLB bounds lookup. Without it, physics blocks raise host.unsupported.
   */
  physicsFactory: ((layers: Dict, glbBounds: (path: string) => Bounds | null) => PhysicsHost) | null = null;

  /** `libRoot` defaults to the `lib/` folder next to the game folder, as in the reference. */
  constructor(root: string, files: Files, libRoot = "") {
    this.files = files;
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
      pendingReset: false,
      pendingSave: null,
      pendingLoad: null,
      overlapEvents: [],
      physics: null,
    };
    this.scheduler = new PhaseScheduler(this.env);
    this.lib = new LibResolver(this.libRoot, files);
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
      if (this.files.exists(join(this.root, f))) raise(this.env, "host.unsupported", `${f} is not in this host yet (ADR 0095 phase 1)`, "warning");
    }
    if (this.physicsFactory) {
      const layers = this.lib.resolve("@lib.physics.layers.layers");
      this.env.physics = this.physicsFactory(isDict(layers) ? layers : {}, (p) => this.glbBounds(p));
    }
    this.spawnEngineEntity();
    this.loadEngineRules();
    this.registerInputs();
    if (isDict(scene) && "level_seed" in scene) {
      this.levelSeed = Math.trunc(toFloat(scene.level_seed));
      SpecRandom.shared.setSeed(this.levelSeed);
    }
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
    if (this.files.exists(prog)) this.loadProgression(prog);
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

  /** step_runner._advance: the pending level swap, the save, the load, then the world reset. The host drains them after each tick. */
  processPending(): void {
    const pending = this.env.pendingLevel;
    if (pending !== "") {
      this.env.pendingLevel = "";
      this.doTransition(pending);
    }
    // A save goes first, so a save and a load in one tick save the state before the load.
    if (this.env.pendingSave !== null) {
      const slot = this.env.pendingSave;
      this.env.pendingSave = null;
      this.doSave(slot);
    }
    if (this.env.pendingLoad !== null) {
      const slot = this.env.pendingLoad;
      this.env.pendingLoad = null;
      this.doLoad(slot);
    }
    if (this.env.pendingReset) {
      this.env.pendingReset = false;
      this.doReset();
    }
  }

  /**
   * WorldResetCoordinator.do_reset: remove each entity with no `persistent`
   * tag, clear world state and load world/state.json, load the global rules
   * again, then load the starting level and the root entities again.
   */
  doReset(): void {
    for (const [id, e] of [...this.env.entities]) {
      if (e.hasTag("persistent")) continue;
      this.env.relations.clearEntity(id);
      this.env.physics?.remove(e);
      this.env.entities.delete(id);
    }
    // Clear in place: the _engine entity's state is this same object (ADR 0047).
    for (const k of Object.keys(this.env.world)) delete this.env.world[k];
    this.env.world.tick = 0;
    this.loadWorldFile();
    this.reloadGlobalRules();
    const prog = join(this.root, "game/flow.json");
    if (this.files.exists(prog)) {
      this.loadProgression(prog);
      this.loadEntities(this.root);
      if (this.currentLevel !== "") this.loadLevel(this.currentLevel);
    } else this.loadEntities(this.root);
    if (Object.keys(this.savePolicy).length > 0) this.env.world.has_save = hasAnySave(this.saveStore, this.saveGame, Math.trunc(toFloat(this.savePolicy.slots ?? 1))) ? 1 : 0;
    this.env.world.active_actor_id = "default_player";
    this.scheduler.flush();
  }

  private get saveGame(): string {
    return this.gameName !== "" ? this.gameName : this.root.slice(this.root.lastIndexOf("/") + 1);
  }

  /** SaveLoadCoordinator.do_save. */
  doSave(slot: number): void {
    if (Object.keys(this.savePolicy).length === 0) {
      raise(this.env, "rule.file_missing", "save_state effect fired but no save_policy.json present", "warning");
      return;
    }
    this.saveStore.write(this.saveGame, slot, JSON.stringify(buildPayload(this.env, this.savePolicy, this.saveGame, this.simTick), null, 2));
    this.env.world.has_save = hasAnySave(this.saveStore, this.saveGame, Math.trunc(toFloat(this.savePolicy.slots ?? 1))) ? 1 : 0;
  }

  /**
   * SaveLoadCoordinator.do_load: the saved world state, a swap to the saved
   * level when it differs, the saved persistent entities, then the saved
   * relations. The level check reads the level from before the state write.
   */
  doLoad(slot: number): void {
    if (Object.keys(this.savePolicy).length === 0) {
      raise(this.env, "rule.file_missing", "load_state effect fired but no save_policy.json present", "warning");
      return;
    }
    const r = readSlot(this.saveStore, this.saveGame, slot, this.savePolicy);
    if (!r.ok) {
      raise(this.env, "save.load_failed", `load slot ${slot} failed: ${r.error}`, "warning");
      return;
    }
    const levelBefore = this.currentLevel;
    const ws = isDict(r.payload.world_state) ? r.payload.world_state : {};
    for (const k of Object.keys(ws)) this.env.world[k] = ws[k];
    const saved = String(this.env.world.current_level ?? levelBefore);
    if (saved !== "" && saved !== levelBefore) {
      // do_transition reads the target, so the current level goes back to the old one first.
      this.currentLevel = levelBefore;
      this.doTransition(saved);
    }
    for (const rec of Array.isArray(r.payload.persistent_entities) ? r.payload.persistent_entities : []) {
      if (!isDict(rec)) continue;
      const id = String(rec.id ?? "");
      const def = String(rec.def ?? "");
      if (id === "" || def === "") continue;
      const state = isDict(rec.state) ? rec.state : {};
      const ent = this.env.entities.get(id);
      if (ent) {
        if (Array.isArray(rec.position)) ent.setPosition(rec.position as Value);
        for (const k of Object.keys(state)) ent.setState(k, k === "position" || k === "velocity" ? normalizePosition(state[k]) : state[k]);
      } else this.spawnInstance({ def, id, position: rec.position ?? null, state });
    }
    for (const rel of Array.isArray(r.payload.relations) ? r.payload.relations : []) {
      if (isDict(rel)) this.env.relations.relate(String(rel.type ?? ""), String(rel.from ?? ""), String(rel.to ?? ""));
    }
  }

  /** LevelTransitionCoordinator.reload_global_rules: the swap and the reset both start from the global rules. */
  private reloadGlobalRules(): void {
    this.scheduler.clearRules();
    this.loadGlobalRules();
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
      this.env.physics?.remove(e);
      this.env.entities.delete(id);
    }
    this.reloadGlobalRules();
    this.currentLevel = target;
    this.loadLevel(target);
    this.scheduler.flush();
    const auto = this.savePolicy.autosave;
    // ADR 0010 autosave: slot 0, drained with the other pending requests.
    if (isDict(auto) && Boolean(auto.on_level_transition)) this.env.pendingSave = 0;
  }

  /** VariantOverlay.apply (ADR 0009 phase 2d): rule, world-state and entity overrides. */
  private applyVariant(): void {
    let name = this.variantOverride;
    if (name === "") {
      const scene = this.readJson("scene.json");
      if (isDict(scene) && String(scene.variant ?? "") !== "") name = String(scene.variant);
    }
    if (name === "") name = (globalThis as { process?: { env: Record<string, string | undefined> } }).process?.env.YUME_VARIANT ?? "";
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
    const any = Object.keys(this.savePolicy).length > 0 && hasAnySave(this.saveStore, this.saveGame, Math.trunc(toFloat(this.savePolicy.slots ?? 1)));
    this.env.world.has_save = any ? 1 : 0;
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
    if (!this.files.exists(dir)) return;
    for (const f of this.files.list(dir).filter((x) => x.endsWith(".json")).sort()) {
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
      // A declaration with keys replaces the bindings. One without keys keeps them.
      const keys = [...("key" in a ? [String(a.key)] : []), ...(Array.isArray(a.keys) ? a.keys.map(String) : [])];
      if (keys.length > 0) this.actionKeys.set(name, keys);
      const buttons = [...("mouse_button" in a ? [String(a.mouse_button)] : []), ...(Array.isArray(a.mouse_buttons) ? a.mouse_buttons.map(String) : [])];
      if (buttons.length > 0) this.actionMouse.set(name, buttons);
    }
    for (const [name, edge] of edgeByName) (edge === "hold" ? this.actionsHold : this.actionsPress).push(name);
  }

  knowsAction(a: string): boolean {
    return this.actionsPress.includes(a) || this.actionsHold.includes(a);
  }

  private parseRules(path: string): Rule[] {
    if (!this.files.exists(path)) return [];
    let data: unknown;
    try {
      data = JSON.parse(this.files.read(path) ?? "");
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
    if (!this.files.exists(path)) return;
    const rules = this.parseRules(path);
    if (append) this.scheduler.appendRules(rules);
    else this.scheduler.registerRules(rules);
  }

  /** WorldLoader.load_rules_files_for: a folder of rule files in name order, or one file. */
  private loadRulesFor(path: string, append: boolean): void {
    const dir = path.replace(/\.json$/, "");
    if (this.files.exists(dir)) {
      let first = true;
      for (const f of this.files.list(dir).filter((x) => x.endsWith(".json")).sort()) {
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
    if (this.files.exists(dir)) {
      for (const f of this.files.list(dir).filter((x) => x.endsWith(".json")).sort()) {
        const d = this.readAbs(join(dir, f));
        if (isDict(d)) docs.push(this.lib.resolve(d) as Dict);
      }
    }
    if (docs.length === 0) {
      raise(this.env, "world.entities_missing", `No entities found at ${root} (checked entities.json + entities/)`, "warning");
      return;
    }
    for (const d of docs) for (const def of asList(d.definitions)) if (isDict(def)) this.env.defs.set(String(def.id ?? ""), def);
    // WorldLoader phase 1.5: every file's patterns expand before any initial instance (patterns.ts).
    for (const d of docs) for (const p of asList(d.patterns)) if (isDict(p)) for (const inst of expandPattern(p, this.levelSeed)) this.spawnInstance(inst);
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
      const e = Entity.create(def, id, overrides);
      this.env.entities.set(id, e);
      attachBody(this.env, e, def);
      this.env.dispatchLifecycle?.("spawn", id);
    }
  }

  /** world.gd advance_one_tick. The runner steps the bodies after it. */
  advanceOneTick(): void {
    this.simTick += 1;
    this.env.world._tick = this.simTick;
    const ph = this.env.physics;
    ph?.readBack(); // ADR 0091: body poses → state, before rules
    ph?.readSensors(); // ADR 0092: rays → state, after the poses
    this.scheduler.tick();
    ph?.drive(this.env); // ADR 0091: motor targets, after rules
  }

  /**
   * GroundConstraint.apply, once for each live frame (world.gd _process; a
   * scenario run has no such call). With `ground.y` in scene.json, an entity
   * below it with a despawn tag leaves the world, and one with a clamp tag
   * goes back up to it.
   */
  applyGroundConstraint(): void {
    if (this.groundCfg === undefined) {
      const scene = this.readJson("scene.json");
      const g = isDict(scene) && isDict(scene.ground) ? scene.ground : null;
      this.groundCfg = g && "y" in g
        ? { y: toFloat(g.y), clamp: asList(g.clamp_tags ?? ["creature"]).map(String), despawn: asList(g.despawn_tags ?? ["projectile"]).map(String) }
        : null;
    }
    const cfg = this.groundCfg;
    if (!cfg) return;
    const out: string[] = [];
    for (const [id, e] of this.env.entities) {
      const p = e.position();
      const y = p instanceof Vec3 ? p.y : 0;
      if (y >= cfg.y) continue;
      if (cfg.despawn.some((t) => e.hasTag(t))) out.push(id);
      else if (p instanceof Vec3 && cfg.clamp.some((t) => e.hasTag(t))) e.setPosition(new Vec3(p.x, cfg.y, p.z));
    }
    for (const id of out) this.despawn(id);
  }

  private groundCfg: { y: number; clamp: string[]; despawn: string[] } | null | undefined = undefined;

  /** SpawnManager.despawn: the despawn trigger, the relations, the body, then the entity. */
  despawn(id: string): void {
    const e = this.env.entities.get(id);
    if (!e) return;
    this.env.dispatchLifecycle?.("despawn", id);
    this.env.relations.clearEntity(id);
    this.env.physics?.remove(e);
    this.env.entities.delete(id);
  }

  /** AssetPath.resolve (ADR 0087): `@lib/<p>` is under the lib folder, any other path under the game folder. */
  glbBounds(path: string): Bounds | null {
    if (path.includes("://") || path.startsWith("/") || path.split("/").includes("..")) return null;
    return this.files.glbBounds(path.startsWith("@lib/") ? join(this.libRoot, path.slice(5)) : join(this.root, path));
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
    if (!this.files.exists(p)) return null;
    try {
      return JSON.parse(this.files.read(p) ?? "");
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
