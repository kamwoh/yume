extends Node
class_name World

## Top-level orchestrator. Owns the entity map, definitions, relation store,
## phase scheduler, world clock, and global world-state dictionary.
##
## Contract: docs/30_framework_primitives.md § "File layout after redesign"
##
## **Renderer-agnostic.** World extends plain Node — no transform of its own.
## Entities (also plain Node) are children. Each entity gets a positioned
## RENDERER child attached (Sprite2D for 2D scenes, MeshInstance3D for 3D),
## which reads `entity.state.position` and updates its own transform per
## frame. Camera2D / Camera3D live as siblings of entities in the scene
## tree. Same World script powers both world_2d.tscn and world_3d.tscn.

@export_dir var data_root: String = ""       # e.g. "res://data/demo_ecology/"
@export var auto_start: bool = true
@export var tick_seconds: float = 0.5
@export var verbose: bool = false
## Optional: path to a Node2D script that renders Entity visuals. Each spawn
## attaches one instance as a child of the Entity. Set empty to disable (useful
## for headless tests).
@export_file("*.gd") var renderer_script: String = "res://scripts/renderer_2d/entity_sprite_2d.gd"
## Input actions polled while HELD — fire every frame the key is down.
## Suitable for continuous things (movement, charge meters).
##
## Default empty: per-game `inputs.json` declares each action's edge type
## (hold/press). Engine has no genre opinions about what's hold vs press —
## those are content decisions. (2026-05-05: dropped baked-in shooter
## defaults that broke turn-based games like sokoban.)
@export var input_actions_hold: PackedStringArray = PackedStringArray()
## Input actions polled on PRESS edge — fire once per keypress, not every frame.
## Suitable for discrete events (spawn bullet, toggle, dialog advance).
##
## Default empty — see input_actions_hold note.
@export var input_actions_press: PackedStringArray = PackedStringArray()
@export var actor_tag: String = "player"
## "stop" action queued when no movement keys pressed (lets velocity_set
## reset to zero). Empty string disables.
@export var stop_action_on_idle: String = "stop"

## ADR 0009 Phase 2d: variant override. If non-empty, takes precedence
## over scene.json's "variant" key and the YUME_VARIANT env var. Used
## by scenario_runner to test variant logic without mutating shared
## global state.
@export var variant_override: String = ""

# ============================================================
# STATE
# ============================================================

var entities: Dictionary = {}                 # instance_id → Entity
var defs: Dictionary = {}                     # def_id → entity definition dict
var relations: RelationStore = null
var spatial_index: SpatialIndex = null        # W3 — bucket hash for radius queries
var scheduler: PhaseScheduler = null
var world_state: Dictionary = {}              # global "world.*" bindings
var next_id_seq: Dictionary = {"_": 0}        # shared counter for spawns
var _clock: WorldClock = null
## Tier 2.6a — accumulating buffer of structured engine errors. Shared
## by reference into `env.error_buffer`; readable by qa-tester / VQA /
## LLM agents. Drain with `EngineError.drain(env)` between scenarios.
var error_buffer: Array = []
## ADR 0010 — save/load policy loaded from <data_root>/save_policy.json.
## Empty if the game hasn't opted in to persistence; save_state /
## load_state effects are no-ops when empty.
var save_policy: Dictionary = {}
## ADR 0019 — per-game macro expander. Loaded once at game start;
## passed into every Rule.load_from_file call so macro references in
## any rules file (world/physics.json, game/rules.json, levels/<n>/rules.json,
## tutorial.json) are expanded uniformly.
var macro_expander = null
## ADR 0016 — multi-actor manager. Loaded at game start; synthesizes a
## default single-actor config if no actors.json present (zero-migration
## for legacy demos). active_actor_id mirrored into world_state for
## binding readers (camera follow, input dispatch).
var actor_manager = null
## SpawnManager (extracted from world.gd 2026-05-11). Owns the entity
## spawn pipeline + renderer-attach + persistent-clobber guard + grid
## snap + renderer_cfg cache. Single public entry: `spawn(inst)`.
var _spawn_manager: SpawnManager = null
## LevelTransitionCoordinator (extracted from world.gd 2026-05-12).
## Owns ADR 0006 multi-level pipeline: process_pending(env),
## do_transition(target), load_level(name).
var _level_transitions: LevelTransitionCoordinator = null
## SaveLoadCoordinator (extracted from world.gd 2026-05-12). Owns
## ADR 0010 save/load pipeline: process_pending(env), do_save(slot),
## do_load(slot).
var _save_load: SaveLoadCoordinator = null
## ADR 0014 — chunk streamer. Non-null only when the game opted into
## open-world mode by shipping a `world.json`. When null, single-chunk
## legacy behavior; all entities live in env.entities for the whole run.
## When non-null, _on_tick calls update() each tick.
var chunk_streamer: ChunkStreamer = null
## ADR 0031 — zone-state primitive. Hierarchical aggregate scope alongside
## entities + world_state. Always non-null (an empty store is fine);
## populated from world/zones.json if that file exists. Passed through env
## so effects (zone_state_*) and Formula (zone.X.Y bindings) can access it.
var zone_store: ZoneStore = null


# ============================================================
# LIFECYCLE
# ============================================================

## Resolve --game= cmdline arg in _enter_tree, which fires top-down before
## any _ready (children's _ready otherwise runs before parent's _ready and
## sees data_root="" when GameShell + ScreenFlow try to read scene.json).
## Empirically caught 2026-05-07: play.tscn rendered blank gray for merchant
## because GameShell read empty scene_cfg → no camera follow_tag → camera
## stuck at (0,0) while player at (1500, 2400).
func _enter_tree() -> void:
	if data_root == "":
		_resolve_data_root_from_cmdline()


var _multimesh_director: MultiMeshDirector = null


func _ready() -> void:
	relations = RelationStore.new()
	spatial_index = SpatialIndex.new()
	# ADR 0031: zone_store always exists (empty until zones.json loads).
	# Empty store has no overhead and lets env.zone_store be non-null
	# everywhere — backward-compat for demos with no zones file.
	zone_store = ZoneStore.new()
	scheduler = PhaseScheduler.new(_build_env())
	_spawn_manager = SpawnManager.new(self)
	_level_transitions = LevelTransitionCoordinator.new(self)
	_save_load = SaveLoadCoordinator.new(self)
	if auto_start:
		start()


func start() -> void:
	if data_root != "":
		load_data()
	_start_clock()


## Look for `--game=<name>` in user args. The user-args separator `--`
## is required so Godot doesn't try to interpret these as engine flags.
## Game names are folder names under `res://data/` (e.g. `demo_tinypond`).
func _resolve_data_root_from_cmdline() -> void:
	for arg in OS.get_cmdline_user_args():
		var s := str(arg)
		if s.begins_with("--game="):
			data_root = "res://data/" + s.substr(7)
			if verbose:
				print("[World] resolved data_root from cmdline: ", data_root)
			return


# ============================================================
# DATA LOADING
# ============================================================

## Load entity defs, initial instances, initial relations, rules, and world
## state from `data_root/`. Order: rules → entities → world → initial flush.
## Rules load first so that spawn-triggered rules can fire during initial
## entity load (per W0 finding on lifecycle-flush-at-load).
##
## ADR 0009 (Phase 5b sunset, 2026-05-05): single canonical layout —
## world/physics.json + game/rules.json + game/flow.json +
## levels/<name>/rules.json + world/state.json. Legacy single-file paths
## (world_rules.json, progression.json, world.json) are no longer
## consulted — all in-tree demos migrated. If you hit a "no rules
## loaded" warning on an old game, rename world_rules.json →
## world/physics.json (or split per Phase 3b classification).
func load_data() -> void:
	var root := data_root.rstrip("/")
	# ADR 0027 — load shared `data/lib/**.json` into LibResolver cache
	# BEFORE any per-game JSON loader runs. Resolver runs cache-once;
	# subsequent calls are no-op. Lets later loaders (entities, rules,
	# screens, scene, hud) call LibResolver.resolve transparently.
	LibResolver.init_cache(root)
	# Tier 2.6t — register per-game input actions from inputs.json (if any).
	# Lets games own their input vocabulary; project.godot stays generic.
	# v2.6r: registrar returns press/hold action names so the engine extends
	# its poll lists. Without this, per-game actions get InputMap entries
	# but never reach the rule scheduler.
	# ADR 0009: registrar also checks new ui/input.json path.
	var registered: Dictionary = InputRegistrar.register_from_data_root(root)
	for n in (registered.get("press", []) as Array):
		if not (input_actions_press as Array).has(str(n)):
			input_actions_press.append(str(n))
	for n in (registered.get("hold", []) as Array):
		if not (input_actions_hold as Array).has(str(n)):
			input_actions_hold.append(str(n))
	# v2.6: scene.json may declare a `level_seed` integer that's applied to
	# Godot's global PRNG before any pattern/scatter/cluster runs. Makes
	# procedurally-generated layouts reproducible — same seed = same map.
	# Omit for stochastic per-session randomization.
	_apply_level_seed_if_set(root)
	# ADR 0019: load per-game macros (if any) BEFORE rules, so every
	# rules file (world/physics.json, game/rules.json, levels/<n>/rules.json,
	# tutorial.json) can reference the same macro vocabulary. Empty
	# expander if no macros.json present (no-op pass-through).
	macro_expander = MacroExpander.load_from_data_root(root, _build_env())
	# ADR 0016: load (or synthesize) actor config. Single code path —
	# legacy single-player demos get a synthesized default actor whose
	# starting_entity_tag = the existing actor_tag export var. Mirror
	# active_actor_id into world_state so bindings can read it.
	actor_manager = ActorManager.load_or_synthesize(root, actor_tag)
	world_state["active_actor_id"] = actor_manager.active_actor_id
	# ADR 0018 Phase A: load scripted policies for any ai_policy actors.
	# No-op for legacy demos (no ai_policy actors in synthesized default).
	actor_manager.load_policies(root)
	# ADR 0006: multi-level support. If game/flow.json exists, load
	# progression + the starting level's content. Persistent entities come
	# from the root's entities.json. Otherwise (single-level games), load
	# entities + rules from the root directly.
	var prog_path := root + "/game/flow.json"
	if FileAccess.file_exists(prog_path):
		_load_progression(prog_path)
		# Global rules (cross-level): physics first (register), game-rules
		# appended. Per-level rules append on top in _load_level.
		_load_rules_file(root + "/world/physics.json")
		_load_rules_file(root + "/game/rules.json", true)
		# ADR 0012: tutorial.json — optional, treated as additional rules
		# at global scope. Steps are rules whose effects fire show_overlay /
		# dismiss_overlay; sequencing via overlay_advanced signal + state.
		_load_rules_file(root + "/tutorial.json", true)
		_load_world_file(root + "/world/state.json")
		# Per ADR 0006: tag persistent entities "persistent" to survive
		# level transitions.
		_load_entities_path(root)
		if current_level != "":
			_level_transitions.load_level(current_level)
	else:
		# Single-level layout
		_load_rules_file(root + "/world/physics.json")
		_load_rules_file(root + "/game/rules.json", true)
		_load_rules_file(root + "/tutorial.json", true)
		_load_world_file(root + "/world/state.json")
		_load_entities_path(root)
		# ADR 0024: build navmesh for single-level games (multi-level
		# games build inside _load_level). No-op when no walkable_floor
		# entities exist.
		if scheduler != null:
			Pathfinding.build_navmesh_for_level(scheduler.env)
	# ADR 0031: load zones.json (optional). Backward-compat — absent file
	# means no zones, no overhead. Loads AFTER entities + world_state so
	# error reports can reach env.error_buffer; loads BEFORE save layer
	# so saved zone_state restores on top of state_init.
	_load_zones_file(root + "/world/zones.json")
	# ADR 0014: open-world chunk streaming. world.json declares chunked-world
	# mode; absent means single-chunk legacy mode (no streaming, no chunks
	# directory consulted). When present:
	#   - chunks/_persistent/entities.json is loaded ONCE (entities live for
	#     the whole session, regardless of chunk eviction)
	#   - the starting chunk + stream_radius neighbors are loaded
	#   - per-tick update() in _on_tick handles drift loads/unloads
	chunk_streamer = ChunkStreamer.try_load(root, verbose)
	if chunk_streamer != null:
		# Persistent chunk first — its entities never leave env.entities.
		var persist_dir := root + "/chunks/_persistent"
		if DirAccess.dir_exists_absolute(persist_dir):
			load_entities_file(persist_dir + "/entities.json")
		# Boot: load starting_chunk + stream_radius neighbors.
		chunk_streamer.boot(_build_env())
	# ADR 0009 Phase 2d: variant overlay applies after rules + world_state +
	# entities are loaded. Read variant name from scene.json's "variant" key
	# or YUME_VARIANT env var. Variant file at variants/<name>.json applies
	# rule-id-keyed field overrides + world_state overrides + entity-id state
	# overrides. Purely additive — cannot change rule structure.
	_apply_variant_if_active(root)
	# ADR 0010: load save policy + expose has_save binding for menus.
	save_policy = SaveState.load_policy(root)
	if not save_policy.is_empty():
		var slots := int(save_policy.get("slots", 1))
		world_state["has_save"] = 1 if SaveState.has_any_save(SaveLoadCoordinator.game_name_from_root(data_root), slots) else 0
	else:
		world_state["has_save"] = 0
	# ADR 0013: now that scheduler + env are built, run SettingsManager's
	# apply_all so each setting's `apply` block fires (set_audio_bus_volume,
	# set_input_mapping, state_set target=world). SettingsManager is a Node
	# sibling — it loaded the schema + config in its own _ready, but
	# deferred apply_all here so EffectApply has a valid env.
	var settings_mgr := get_node_or_null("SettingsManager")
	if settings_mgr != null and settings_mgr.has_method("apply_all"):
		settings_mgr.apply_all()
	# ADR 0029: ScheduleDirector reads each entity def's `schedule` block
	# (if present) and starts resolving slots once World ticks. Register
	# AFTER entities are loaded so register_schedules_from_env can walk
	# env.entities and find their defs. No-op for games shipping no
	# schedules (existing demos unaffected).
	var sched_dir := get_node_or_null("ScheduleDirector")
	if sched_dir != null and sched_dir.has_method("register_schedules_from_env"):
		sched_dir.register_schedules_from_env(scheduler.env)
	# ADR 0036: LifecycleDirector reads each entity def's `lifecycle` block
	# and registers per-entity stage tables. No-op for games shipping no
	# lifecycle templates (existing demos unaffected — backward-compat by
	# absence of the field).
	var lc_dir := get_node_or_null("LifecycleDirector")
	if lc_dir != null and lc_dir.has_method("register_lifecycles_from_env"):
		lc_dir.register_lifecycles_from_env(scheduler.env)
	# ADR 0030: ClassManager loads class defs from <root>/classes/*.json
	# if the directory exists. No-op for games without occupations.
	# Loaded after entities so signal listeners (game-rules) are already
	# wired by the time the first switch_class effect can fire.
	var class_mgr := get_node_or_null("ClassManager")
	if class_mgr != null and class_mgr.has_method("register_classes_from_data_root"):
		class_mgr.register_classes_from_data_root(root, scheduler.env)
	# ADR 0033: TechTreeDirector loads tree defs from <root>/tech_trees.json
	# if present. No-op for games without a tech tree (existing demos
	# unaffected). Loaded after entities so signal listeners are wired
	# before the first try_discover_tech / learn_from_master effect can fire.
	var tech_dir := get_node_or_null("TechTreeDirector")
	if tech_dir != null and tech_dir.has_method("register_trees_from_data_root"):
		tech_dir.register_trees_from_data_root(root, scheduler.env)
	# ADR 0034: DynastyDirector hosts the four succession effects
	# (transfer_inventory / transfer_reputation / transfer_techs /
	# transition_player_to) plus the heir-resolver helper used by
	# per-game succession rules. No boot-time data to load — heir
	# state lives on each actor entity (state.heirs +
	# state.inheritance_policy), serialized via the normal entity
	# snapshot path (ADR 0010). Backward-compat: games without
	# heirs never trigger the director (Node may be absent from the
	# scene; the four effects log a no-manager warning and no-op).
	var _dynasty_dir := get_node_or_null("DynastyDirector")
	if _dynasty_dir != null and verbose:
		print("[World] DynastyDirector mounted (ADR 0034)")
	# ADR 0032: FactionDirector loads faction defs + initial relationships
	# from <root>/factions.json if present. No-op for games without
	# politics. Loaded after entities so member_count bindings can resolve
	# against the live entity set on first tick.
	_load_factions_file(root + "/factions.json")
	scheduler.flush_effects()
	# ADR 0041: render-side batching for static decoration. Runs AFTER all
	# entities are loaded + rules registered (the director scans rules to
	# decide which entities are static). No-op when no mesh def has
	# multimesh_eligible: true (backward-compat for all existing demos).
	_run_multimesh_director()
	if verbose:
		var lvl_str := (" [level: " + current_level + "]") if current_level != "" else ""
		print("[World] loaded: %d defs, %d entities, %d relations%s" % [
			defs.size(), entities.size(), relations.count_total(), lvl_str
		])


## Load entity data from `<root>/entities.json` and/or `<root>/entities/`.
## Two-phase: collect all dicts first, then process (a) definitions before
## (b) initial_instances + initial_relations so spawn-time def lookups work
## regardless of file order.
func _load_entities_path(root: String) -> void:
	var env := _build_env()
	var dicts: Array[Dictionary] = []

	var single := root + "/entities.json"
	if FileAccess.file_exists(single):
		var d := _read_entities_json(single, env)
		if not d.is_empty(): dicts.append(d)

	var dir_path := root + "/entities"
	if DirAccess.dir_exists_absolute(dir_path):
		var dir := DirAccess.open(dir_path)
		if dir != null:
			var files: Array[String] = []
			dir.list_dir_begin()
			var fname := dir.get_next()
			while fname != "":
				if not dir.current_is_dir() and fname.ends_with(".json"):
					files.append(fname)
				fname = dir.get_next()
			files.sort()
			for f in files:
				var d2 := _read_entities_json(dir_path + "/" + f, env)
				if not d2.is_empty(): dicts.append(d2)

	if dicts.is_empty():
		EngineError.raise(env, EngineError.WORLD_ENTITIES_MISSING,
			"No entities found at %s (checked entities.json + entities/)" % root,
			{"file": root},
			"Create entities.json or an entities/ directory with one JSON file per def.",
			"warning")
		return

	# Phase 1: register all definitions
	for d in dicts:
		for def in d.get("definitions", []):
			if def is Dictionary:
				defs[str(def.get("id", ""))] = def
	# Phase 1.5: expand declarative patterns into concrete instance dicts.
	# Tier 2.6q — entities/zz_instances.json (and similar) can declare
	# `patterns: [{def, pattern, count, ...}]` instead of hand-typing
	# every position. Patterns expand to the same shape as initial_instances.
	for d in dicts:
		for p in d.get("patterns", []):
			if p is Dictionary:
				for inst in InstancePatterns.expand(p):
					_spawn_manager.spawn(inst)
	# Phase 2: process hand-coded initial instances + relations
	for d in dicts:
		for inst in d.get("initial_instances", []):
			if inst is Dictionary:
				_spawn_manager.spawn(inst)
		for rel in d.get("initial_relations", []):
			if rel is Dictionary:
				relations.relate(
					str(rel.get("type", "")),
					str(rel.get("from", "")),
					str(rel.get("to", "")),
				)


## ADR 0014: load a single entities JSON file (definitions + patterns +
## initial_instances + initial_relations). Used by ChunkStreamer to
## stream per-chunk content; reuses the same definition-then-instance
## pipeline as `_load_entities_path` so chunk-loaded entities and
## bootstrap entities follow identical semantics.
##
## Called at runtime — definitions appearing in chunk files are added
## to `defs` if new; existing-id collisions are silently overwritten
## (chunks may share defs with the root entities folder).
func load_entities_file(path: String) -> void:
	if not FileAccess.file_exists(path): return
	var env := _build_env()
	var d := _read_entities_json(path, env)
	if d.is_empty(): return
	# Definitions
	for def in d.get("definitions", []):
		if def is Dictionary:
			defs[str(def.get("id", ""))] = def
	# Patterns
	for p in d.get("patterns", []):
		if p is Dictionary:
			for inst in InstancePatterns.expand(p):
				_spawn_manager.spawn(inst)
	# Initial instances
	for inst in d.get("initial_instances", []):
		if inst is Dictionary:
			_spawn_manager.spawn(inst)
	# Initial relations
	for rel in d.get("initial_relations", []):
		if rel is Dictionary:
			relations.relate(
				str(rel.get("type", "")),
				str(rel.get("from", "")),
				str(rel.get("to", "")),
			)


## Read one entities JSON file. Returns {} on missing/malformed; reports
## structured errors via env.error_buffer. Public-ish — used by the
## directory walker and the legacy single-file path.
func _read_entities_json(path: String, env: Dictionary) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		EngineError.raise(env, EngineError.WORLD_ENTITIES_INVALID,
			"Invalid JSON: %s" % path,
			{"file": path},
			"Top-level must be a JSON object with 'definitions' / 'initial_instances' / 'initial_relations'.")
		return {}
	# ADR 0027: expand @lib.X / $extends / $include refs before consumption.
	# Pass-through if no refs present.
	var resolved = LibResolver.resolve(data)
	if resolved is Dictionary:
		return resolved as Dictionary
	return data as Dictionary


func _load_rules_file(path: String, append: bool = false) -> void:
	if not FileAccess.file_exists(path):
		return
	var env := _build_env()
	# ADR 0019: macro_expander expands per-game macro effect references
	# in this file's rules to primitive sequences before parsing into
	# Rule instances. Null when game has no macros.json.
	var rules := Rule.load_from_file(path, env, macro_expander)
	var errors := Rule.validate_all(rules)
	for record in errors:
		EngineError.report(env, record)
	if append and scheduler.has_method("append_rules"):
		scheduler.append_rules(rules)
	else:
		scheduler.register_rules(rules)
	if verbose:
		print("[World] %d rules %s" % [rules.size(), "appended" if append else "registered"])


## ADR 0009 Phase 2d — variant overlay loader.
##
## Schema (variants/<name>.json):
##   {
##     "rules":        {"<rule_id>": {"<dotted.path>": <new_value>}},
##     "world_state":  {"<key>": <value>},
##     "entities":     {"<entity_id>": {"<state_field>": <value>}}
##   }
##
## Rules path supports:
##   "chance"                 → rule.chance
##   "effect.<field>"         → rule.effects[0][<field>]  (single-effect rules)
##   "effects.<idx>.<field>"  → rule.effects[<idx>][<field>]  (multi-effect rules)
##
## Variants are PURELY ADDITIVE — they override numeric / scalar values
## but cannot add or remove rules / change rule structure / introduce
## new effect types. Use a separate game/rules.json for structural
## changes.
func _apply_variant_if_active(root: String) -> void:
	var variant_name := _active_variant_name(root)
	if variant_name == "":
		return
	var path := root + "/variants/" + variant_name + ".json"
	if not FileAccess.file_exists(path):
		if verbose:
			print("[variant] '%s' selected but no file at %s — skipping" % [variant_name, path])
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var raw := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		push_warning("[variant] %s: invalid JSON" % path)
		return
	var v: Dictionary = parsed

	# 1. Rule overrides
	var rule_overrides: Dictionary = v.get("rules", {})
	for rid_v in rule_overrides:
		var rid := str(rid_v)
		var rule := scheduler.get_rule_by_id(rid)
		if rule == null:
			push_warning("[variant] rule '%s' not found — override skipped" % rid)
			continue
		var fields: Dictionary = rule_overrides[rid_v]
		for path_key in fields:
			_apply_rule_override(rule, str(path_key), fields[path_key])

	# 2. world_state overlay
	var ws_overrides: Dictionary = v.get("world_state", {})
	for k in ws_overrides:
		world_state[str(k)] = ws_overrides[k]

	# 3. Entity state overrides
	var ent_overrides: Dictionary = v.get("entities", {})
	for ent_id_v in ent_overrides:
		var ent_id := str(ent_id_v)
		var ent = entities.get(ent_id, null)
		if not (ent is Entity):
			push_warning("[variant] entity '%s' not found — override skipped" % ent_id)
			continue
		var state_overrides: Dictionary = ent_overrides[ent_id_v]
		for sk in state_overrides:
			(ent as Entity).set_state(str(sk), state_overrides[sk])

	if verbose:
		print("[variant] applied: %s (%d rules, %d world_state, %d entities)" % [
			variant_name, rule_overrides.size(), ws_overrides.size(), ent_overrides.size()
		])


## Determine the active variant. Precedence:
##   1. self.variant_override property (set by scenario_runner / tests)
##   2. scene.json's "variant" key
##   3. YUME_VARIANT env var
##   4. "" (no variant)
func _active_variant_name(root: String) -> String:
	if variant_override != "":
		return variant_override
	var scene_path := root + "/scene.json"
	if FileAccess.file_exists(scene_path):
		var f := FileAccess.open(scene_path, FileAccess.READ)
		var raw := f.get_as_text()
		f.close()
		var parsed = JSON.parse_string(raw)
		if parsed is Dictionary:
			var v := str((parsed as Dictionary).get("variant", ""))
			if v != "":
				return v
	return OS.get_environment("YUME_VARIANT")


## Apply a single override. Path forms:
##   "chance"                 → rule.chance
##   "effect.<key>"           → rule.effects[0][<key>]
##   "effects.<idx>.<key>"    → rule.effects[<idx>][<key>]
func _apply_rule_override(rule: Rule, path: String, value) -> void:
	if path == "chance":
		rule.chance = float(value)
		return
	if path.begins_with("effect."):
		var key := path.substr("effect.".length())
		if rule.effects.size() == 0:
			push_warning("[variant] rule '%s' has no effects to override .%s" % [rule.id, key])
			return
		(rule.effects[0] as Dictionary)[key] = value
		return
	if path.begins_with("effects."):
		var rest := path.substr("effects.".length())
		var dot := rest.find(".")
		if dot < 0:
			push_warning("[variant] malformed effects path '%s' — expected effects.<idx>.<field>" % path)
			return
		var idx := int(rest.substr(0, dot))
		var key2 := rest.substr(dot + 1)
		if idx < 0 or idx >= rule.effects.size():
			push_warning("[variant] rule '%s' effects index %d out of range" % [rule.id, idx])
			return
		(rule.effects[idx] as Dictionary)[key2] = value
		return
	push_warning("[variant] unsupported override path '%s' on rule '%s'" % [path, rule.id])


func _load_world_file(path: String) -> void:
	if not FileAccess.file_exists(path): return
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	if data is Dictionary:
		# Merge `state` block into world_state (preserves any pre-set keys
		# like current_level from progression.json).
		var s: Dictionary = data.get("state", {}) as Dictionary
		for k in s.keys():
			world_state[str(k)] = s[k]


## ADR 0031 — load world/zones.json into ZoneStore.
## Optional file; absent = empty store, full backward-compat. Validation
## errors (cycles, multi-parent, unknown ids) report to env.error_buffer
## but don't halt engine boot — partial zones are still usable.
func _load_zones_file(path: String) -> void:
	if zone_store == null:
		zone_store = ZoneStore.new()
	if not FileAccess.file_exists(path): return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return
	var raw := f.get_as_text()
	f.close()
	var data = JSON.parse_string(raw)
	if not (data is Dictionary):
		EngineError.raise(_build_env(), "zone.invalid_json",
			"world/zones.json is not a JSON object",
			{"file": path},
			"The top-level value must be a dict like {\"zones\": [...]}.")
		return
	var errors := zone_store.load_from_dict(data, _build_env())
	if verbose:
		print("[World] zone_store loaded: %d zones, %d errors" % [
			zone_store.count(), errors.size()
		])


## ADR 0032 — load factions.json into FactionDirector.
## Optional file; absent = no-op (FactionDirector keeps an empty registry,
## full backward-compat). Validation errors (unknown faction in
## relationship from/to, invalid stance) report to env.error_buffer but
## don't halt engine boot.
func _load_factions_file(path: String) -> void:
	var fd := get_node_or_null("FactionDirector")
	if fd == null or not fd.has_method("register_factions"):
		return
	if not FileAccess.file_exists(path): return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return
	var raw := f.get_as_text()
	f.close()
	var data = JSON.parse_string(raw)
	if not (data is Dictionary):
		EngineError.raise(_build_env(), "faction.invalid_json",
			"factions.json is not a JSON object",
			{"file": path},
			"The top-level value must be a dict like {\"factions\": [...], \"relationships\": [...]}.",
			"warning")
		return
	var errors = fd.call("register_factions", data, _build_env())
	if verbose:
		var errs_size: int = (errors as Array).size() if errors is Array else 0
		var known_count: int = 0
		if fd.has_method("known_faction_ids"):
			known_count = (fd.call("known_faction_ids") as Array).size()
		print("[World] faction_director loaded: %d factions, %d errors" % [
			known_count, errs_size
		])




# ADR 0041 — bootstrap the multimesh director (lazy-init on first use).
# Reads renderer.position_scale from SpawnManager's renderer_cfg cache
# (default 0.05) and passes World as parent so MultiMeshInstance3D nodes
# sit at world scope. The cache is owned by SpawnManager (extracted
# 2026-05-11) — multimesh reads it as a consumer.
func _ensure_multimesh_director() -> MultiMeshDirector:
	if _multimesh_director != null: return _multimesh_director
	_multimesh_director = MultiMeshDirector.new()
	var cfg: Dictionary = _spawn_manager.renderer_cfg() if _spawn_manager != null else {}
	var ps: float = float(cfg.get("position_scale", 0.05))
	_multimesh_director.configure(self, ps)
	return _multimesh_director


func _run_multimesh_director() -> void:
	# Static-only optimization — skip when no entities use 3D renderer.
	# Also skip when renderer_script is empty (headless test mode).
	if renderer_script == "": return
	if not renderer_script.contains("entity_mesh_3d"): return
	var dir := _ensure_multimesh_director()
	var stats := dir.scan_and_batch(scheduler.env)
	if verbose and stats.get("groups", 0) > 0:
		print("[MULTIMESH-BUILD] entities=%d groups=%d instances=%d" % [
			stats.get("entities", 0),
			stats.get("groups", 0),
			stats.get("instances", 0),
		])




# ============================================================
# CLOCK
# ============================================================

func _start_clock() -> void:
	_clock = WorldClock.new()
	_clock.name = "WorldClock"
	_clock.tick_seconds = tick_seconds
	add_child(_clock)
	_clock.tick.connect(_on_tick)


func _on_tick(count: int) -> void:
	# ADR 0011 + 0012: when a screen OR overlay with freeze_world=true is
	# active, suppress simulation. Renderer keeps drawing the frozen scene
	# behind the modal/overlay. Input still routes to the active screen
	# (ScreenFlow's _process) or overlay (OverlayManager's _process); we
	# just skip scheduler.tick().
	var freeze := int(world_state.get("screen_freeze_world", 0)) != 0
	freeze = freeze or int(world_state.get("overlay_freeze_world", 0)) != 0
	if freeze:
		# Still process pending save/load so a "Save" button in pause works,
		# AND pending level transitions so a "New Game / Travel" button on a
		# freeze_world screen can swap the level (ScreenFlow buttons fire
		# transition_level via shell_event_buffer; GameShell drives the
		# fade + queues _pending_level_transition; this runs the swap).
		_save_load.process_pending(scheduler.env)
		_level_transitions.process_pending(scheduler.env)
		return
	advance_one_tick()
	if verbose and count % 4 == 0:
		_print_tick_summary(count)


## ADR 0039: canonical tick body. Used by:
##   1. The live clock callback `_on_tick` (above) after the freeze check.
##   2. The step runner (`step_runner.gd`) for headless tests + capture VQA.
##
## Single source of truth — both paths exercise identical engine state
## transitions, so scenario tests cannot pass while live play silently
## diverges. Includes scheduler.tick(), LifecycleDirector.tick,
## actor_manager.tick_policies, lifetime decrement, and all `process_pending_*`
## drains in the original phase order.
##
## Does NOT include the freeze guard — callers are expected to gate the
## call on their own freeze policy. The step runner intentionally bypasses
## freeze (tests need to advance state regardless of modal screens).
func advance_one_tick() -> void:
	# ADR 0040: pretick velocity zero for actors with the opt-in flag.
	# Camera-relative WASD uses velocity_add_relative each tick; without
	# this reset, contributions accumulate unbounded. Runs BEFORE
	# scheduler.tick so the input phase's add contributions sum to a
	# fresh value each tick.
	for id in entities.keys():
		var pre_ent = entities[id]
		if pre_ent is Entity and bool((pre_ent as Entity).get_state("zero_velocity_pretick", false)):
			var pre_vel = (pre_ent as Entity).get_velocity()
			if pre_vel is Vector2:
				(pre_ent as Entity).set_velocity(Vector2.ZERO)
			elif pre_vel is Vector3:
				(pre_ent as Entity).set_velocity(Vector3.ZERO)
	# ADR 0018 Phase A: tick AI policies BEFORE scheduler.tick so their
	# synthesized actions land in the input queue and are processed in
	# the same tick as human input. AI actors decide simultaneously
	# with human-controlled ones.
	if actor_manager != null:
		actor_manager.tick_policies(scheduler.env)
	scheduler.tick()
	# ADR 0040: post-input speed clamp. Per Condition C4 tightening
	# (2026-05-10), default max_speed=INF means clamp DISABLED unless
	# explicitly declared. Originally gated on zero_velocity_pretick (iso
	# mode), but FP mode also wants this — without it, W+D in FP gives
	# √2 × walking speed (classic Quake diagonal-fastrun bug). Refined
	# 2026-05-10 (FP rollout): any actor with max_speed < INF gets clamped.
	for id in entities.keys():
		var clamp_ent = entities[id]
		if not (clamp_ent is Entity): continue
		var max_s := float((clamp_ent as Entity).get_state("max_speed", INF))
		if max_s < INF:
			var v = (clamp_ent as Entity).get_velocity()
			if v is Vector2 and (v as Vector2).length() > max_s:
				(clamp_ent as Entity).set_velocity((v as Vector2).normalized() * max_s)
			elif v is Vector3 and (v as Vector3).length() > max_s:
				(clamp_ent as Entity).set_velocity((v as Vector3).normalized() * max_s)
	# ADR 0036: LifecycleDirector advances entity ages + checks stage
	# thresholds on the same per-tick cadence. dt = tick_seconds so a
	# year_seconds=900 template ages an entity by tick_seconds/900 years
	# per tick (Phase 1 default → schema-only when age_per_in_game_year=0).
	# No-op when no entity has a lifecycle template registered.
	var lc_dir2 := get_node_or_null("LifecycleDirector")
	if lc_dir2 != null and lc_dir2.has_method("tick"):
		lc_dir2.tick(scheduler.env, tick_seconds)
	_decrement_lifetimes()
	_level_transitions.process_pending(scheduler.env)
	# ADR 0014: chunk streaming runs after level transition (level changes
	# may relocate the actor) and before save/load (save needs to capture
	# the post-stream current_chunk). No-op when chunk_streamer is null
	# (single-chunk legacy mode).
	process_chunk_streaming()
	_save_load.process_pending(scheduler.env)
	# ADR 0016: switch_actor takes effect at next tick boundary. We process
	# AFTER scheduler.tick() so the current tick's rules saw the OLD
	# active_actor; the next tick's input phase will see the NEW one.
	process_pending_actor_switch()
	# Task #99: reset_world resets world_state + non-persistent entities
	# without scene reload. Processed after other deferred ops so any
	# in-flight save/load completes before the reset wipes state.
	process_pending_world_reset()


## ADR 0014: per-tick chunk streaming. Resolves the active actor's planar
## position via ActorManager, then asks chunk_streamer to load any
## chunks within stream_radius and despawn entities in chunks beyond
## unload_radius. Persistent entities (from chunks/_persistent/ or
## tagged via persistent_tags) are never affected — they live in env
## for the whole session.
##
## No-op when chunk_streamer is null (legacy single-chunk demos).
func process_chunk_streaming() -> void:
	if chunk_streamer == null: return
	var actor_id := _find_actor_id()
	if actor_id == "": return
	chunk_streamer.update(scheduler.env, actor_id)



## Tier 2.6j: entities with state.lifetime > 0 auto-decrement each tick;
## removed when lifetime reaches 0. Standard pattern for transient entities
## (bullets, particles, sparkles, "+10" damage numbers).
##
## Entities without a lifetime field are unaffected. Lifetime is in TICKS,
## not seconds — keeps it predictable across tick_seconds settings.
func _decrement_lifetimes() -> void:
	var to_remove: Array[String] = []
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity): continue
		var lf = (ent as Entity).get_state("lifetime", null)
		if lf == null: continue
		var lifetime := float(lf)
		if lifetime <= 0.0: continue
		lifetime -= 1.0
		(ent as Entity).set_state("lifetime", lifetime)
		if lifetime <= 0.0:
			to_remove.append(str(id))
	# Remove after iteration so we don't mutate the dict mid-loop.
	for id in to_remove:
		var ent: Entity = entities.get(id, null)
		if ent == null: continue
		if relations != null:
			relations.clear_entity(id)
		if spatial_index != null and spatial_index.has_method("remove_entity"):
			spatial_index.remove_entity(id)
		entities.erase(id)
		ent.queue_free()


# ============================================================
# PER-FRAME: input polling + motion integration (W2.2 + W2.5)
# ============================================================

func _process(delta: float) -> void:
	if scheduler == null: return
	# Input polling lives in InputRegistrar (extracted 2026-05-11 — kept
	# the full input lifecycle co-located in one module). _find_actor_id
	# stays here because actor routing is world.gd's concern.
	InputRegistrar.poll(
		scheduler, _find_actor_id(),
		input_actions_hold, input_actions_press,
		stop_action_on_idle, entities
	)
	_integrate_motion(delta)


## Tier 2.6o Phase 3 — accumulate mouse motion across the frame.
## GameShell drains env.mouse_delta in first/third-person camera modes
## to update the actor's state.facing (yaw). Set + reset per frame.
func _input(event: InputEvent) -> void:
	if scheduler == null: return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		var current = scheduler.env.get("mouse_delta", Vector2.ZERO)
		if not (current is Vector2): current = Vector2.ZERO
		scheduler.env["mouse_delta"] = (current as Vector2) + motion.relative



## ADR 0016: resolve which entity should receive input this frame.
## Routes through actor_manager (single code path per ADR 0016).
## The legacy `actor_tag` scan fallback was removed 2026-05-11 — it
## was dead code in production paths AND silently masked authoring
## bugs in actors.json (a typoed starting_entity_tag would invisibly
## fall back to "player" tag instead of surfacing as "no actor entity
## found"). Returns "" if no entity matches; callers handle.
func _find_actor_id() -> String:
	if actor_manager == null:
		return ""  # auto_start=false test mode; no input routing
	return actor_manager.resolve_active_entity(entities)


## ADR 0016: process queued switch_actor between ticks. Effect handlers
## set env._pending_active_actor; we read + clear it here so input
## routing changes happen at tick boundaries, not mid-rule.
func process_pending_actor_switch() -> void:
	var env: Dictionary = scheduler.env
	var pending = env.get("_pending_active_actor", null)
	if pending == null or actor_manager == null: return
	env.erase("_pending_active_actor")
	var target := str(pending)
	if actor_manager.set_active(target):
		world_state["active_actor_id"] = target
		if verbose:
			print("[World] active actor → ", target)


## Task #99 — process queued reset_world between ticks. Despawns all
## non-persistent entities, resets world_state to initial values, and
## reloads the starting level (or root entities for single-level games).
## NO scene reload — the World node + scheduler + screen_flow + settings
## persist. Used by "New Game" buttons to clean up after a Continue.
func process_pending_world_reset() -> void:
	var env: Dictionary = scheduler.env
	if not bool(env.get("_pending_world_reset", false)): return
	env.erase("_pending_world_reset")
	_do_world_reset()


func _do_world_reset() -> void:
	var root := data_root.rstrip("/")
	# 1. Despawn all non-persistent entities (matches transition_level)
	var to_remove: Array[String] = []
	for id in entities.keys():
		var ent = entities[id]
		if ent is Entity and not (ent as Entity).has_tag("persistent"):
			to_remove.append(str(id))
	for rid in to_remove:
		var rent: Entity = entities.get(rid, null)
		if rent == null: continue
		if relations != null:
			relations.clear_entity(rid)
		if spatial_index != null and spatial_index.has_method("remove_entity"):
			spatial_index.remove_entity(rid)
		entities.erase(rid)
		rent.queue_free()
	# 2. Reset world_state to initial values. Clear in-place so any
	# external references (env.world is a back-ref) stay valid.
	world_state.clear()
	world_state["tick"] = 0
	_load_world_file(root + "/world/state.json")
	# 3. Reload entities + relations. For multi-level games, reset to
	# the progression's starting_level. For single-level, just re-load
	# root entities.
	var prog_path := root + "/game/flow.json"
	if FileAccess.file_exists(prog_path):
		_load_progression(prog_path)         # resets current_level → starting_level
		world_state["current_level"] = current_level
		_load_entities_path(root)            # re-load persistent root entities
		if current_level != "":
			_level_transitions.load_level(current_level)
	else:
		_load_entities_path(root)
	# 4. Refresh has_save (ADR 0010) — reset doesn't delete saves; it just
	# clears in-memory state. has_save remains accurate.
	if not save_policy.is_empty():
		var slots := int(save_policy.get("slots", 1))
		world_state["has_save"] = 1 if SaveState.has_any_save(SaveLoadCoordinator.game_name_from_root(data_root), slots) else 0
	# 5. Refresh active_actor_id mirror (ActorManager state untouched).
	if actor_manager != null:
		world_state["active_actor_id"] = actor_manager.active_actor_id
	scheduler.flush_effects()
	if verbose:
		print("[World] reset_world complete (level: %s)" % current_level)


## Integrate velocity → position each frame for smooth motion.
## Velocity is in units-per-second; multiply by delta. Updates spatial index.
##
## Tier 2.6i: entities with state.drag > 0 decelerate when no input is
## actively setting velocity. drag is per-second factor (0.0 = no drag,
## 1.0 = full stop in 1s). Velocity multiplies by (1 - drag * delta) each
## frame. Below DRAG_REST_EPSILON it snaps to zero.
##
## ADR 0004: entities with the `blocks_motion` tag and `properties.aabb_extents`
## act as static obstacles. Each moving entity is tested against blockers as
## a circle (XZ plane) with radius from `properties.body_radius` (default
## 0.4). On intersection, motion slides along separate axes — try X-only, then
## Z-only, else stay. Approximation: no swept CCD, so very fast entities at
## oblique angles can tunnel through thin walls. Acceptable for arcade-feel.
const DRAG_REST_EPSILON := 0.5
const DEFAULT_BODY_RADIUS := 0.4
var _pending_remove_ids: Array[String] = []

func _integrate_motion(delta: float) -> void:
	# ADR 0004: collect blockers once per frame (immovable static obstacles).
	var blockers: Array = _collect_blockers()
	_pending_remove_ids = []
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity): continue
		var v = (ent as Entity).get_velocity()
		if v == null: continue
		# Apply drag if configured. Skipped if drag = 0 (default). Works for
		# both Vector2 (2D entities) and Vector3 (3D / FPS entities).
		var drag_v := float((ent as Entity).get_state("drag", 0.0))
		if drag_v > 0.0:
			var factor: float = 1.0 - clamp(drag_v * delta, 0.0, 1.0)
			if v is Vector2:
				var v2: Vector2 = v
				if v2 != Vector2.ZERO:
					v2 *= factor
					if v2.length() < DRAG_REST_EPSILON: v2 = Vector2.ZERO
					(ent as Entity).set_velocity(v2)
					v = v2
			elif v is Vector3:
				var v3: Vector3 = v
				if v3 != Vector3.ZERO:
					v3 *= factor
					if v3.length() < DRAG_REST_EPSILON * 0.01: v3 = Vector3.ZERO
					(ent as Entity).set_velocity(v3)
					v = v3
		var moved := false
		# Skip blocker-vs-blocker self-block (an obstacle isn't moving).
		var is_blocker: bool = (ent as Entity).has_tag("blocks_motion")
		# Projectiles stop dead at walls (no slide) — bullets shouldn't
		# crawl AROUND a wall. Walking creatures slide normally.
		var is_projectile: bool = (ent as Entity).has_tag("projectile")
		var body_r: float = float((ent as Entity).get_property("body_radius", DEFAULT_BODY_RADIUS))
		var p = (ent as Entity).get_position()
		if v is Vector2 and v != Vector2.ZERO:
			if p is Vector2:
				var new_p2: Vector2 = (p as Vector2) + (v as Vector2) * delta
				if not is_blocker and not blockers.is_empty():
					if is_projectile:
						new_p2 = _resolve_projectile_2d(p as Vector2, new_p2, body_r, blockers)
					else:
						new_p2 = _resolve_motion_2d(p as Vector2, new_p2, body_r, blockers)
				(ent as Entity).set_position(new_p2)
				moved = true
			elif p is Vector3:
				var v2: Vector2 = v as Vector2
				var new_p3v: Vector3 = (p as Vector3) + Vector3(v2.x, 0, v2.y) * delta
				if not is_blocker and not blockers.is_empty():
					if is_projectile:
						new_p3v = _resolve_projectile_3d(p as Vector3, new_p3v, body_r, blockers)
					else:
						new_p3v = _resolve_motion_3d(p as Vector3, new_p3v, body_r, blockers)
				(ent as Entity).set_position(new_p3v)
				moved = true
		elif v is Vector3 and v != Vector3.ZERO:
			if p is Vector3:
				var new_p3: Vector3 = (p as Vector3) + (v as Vector3) * delta
				if not is_blocker and not blockers.is_empty():
					if is_projectile:
						new_p3 = _resolve_projectile_3d(p as Vector3, new_p3, body_r, blockers)
					else:
						new_p3 = _resolve_motion_3d(p as Vector3, new_p3, body_r, blockers)
				(ent as Entity).set_position(new_p3)
				moved = true
			elif p is Vector2:
				var v3: Vector3 = v as Vector3
				var new_p2v: Vector2 = (p as Vector2) + Vector2(v3.x, v3.z) * delta
				if not is_blocker and not blockers.is_empty():
					if is_projectile:
						new_p2v = _resolve_projectile_2d(p as Vector2, new_p2v, body_r, blockers)
					else:
						new_p2v = _resolve_motion_2d(p as Vector2, new_p2v, body_r, blockers)
				(ent as Entity).set_position(new_p2v)
				moved = true
		# Projectile that hit a blocker: queue for immediate removal so it
		# doesn't hang at the wall. Collected post-loop to avoid mutating
		# entities mid-iteration. (Set velocity=0 first as a defensive
		# guard against late-frame motion before the deferred removal.)
		if is_projectile and moved:
			var p_after = (ent as Entity).get_position()
			if p_after == p:
				(ent as Entity).set_velocity(Vector3.ZERO if p is Vector3 else Vector2.ZERO)
				_pending_remove_ids.append(str(id))
		if moved and spatial_index != null:
			spatial_index.update_entity(id, (ent as Entity).get_planar_position())
	# Drain queued projectile removals (bullets that hit walls). Runs OUTSIDE
	# the entities.keys() loop so we don't mutate during iter.
	for rid in _pending_remove_ids:
		var rent: Entity = entities.get(rid, null)
		if rent == null: continue
		if relations != null:
			relations.clear_entity(rid)
		if spatial_index != null and spatial_index.has_method("remove_entity"):
			spatial_index.remove_entity(rid)
		entities.erase(rid)
		rent.queue_free()
	_pending_remove_ids = []
	# Ground primitive (Tier 2.6r): if scene.json declares a ground.y,
	# clamp tagged "creature" entities to that Y, and remove tagged
	# "projectile" entities that drop below it. Replaces game-level
	# creature_bounds + projectile_floor_despawn rules with a single
	# engine behavior. Empty / missing ground config = no-op.
	_apply_ground()


var _ground_cfg_loaded: bool = false
var _ground_y: float = -INF
var _ground_clamp_tags: Array = []
var _ground_despawn_tags: Array = []
func _load_ground_cfg() -> void:
	if _ground_cfg_loaded: return
	_ground_cfg_loaded = true
	var path := data_root.rstrip("/") + "/scene.json"
	if not FileAccess.file_exists(path): return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK: return
	if not (json.data is Dictionary): return
	var cfg: Dictionary = json.data
	if not (cfg.get("ground", null) is Dictionary): return
	var g: Dictionary = cfg["ground"]
	if g.has("y"):
		_ground_y = float(g["y"])
	_ground_clamp_tags = g.get("clamp_tags", ["creature"])
	_ground_despawn_tags = g.get("despawn_tags", ["projectile"])


# ADR 0038: grid-based placement config. Loaded once from scene.json's
# `grid` block (mirroring _load_ground_cfg), exposed via env["scene_grid"]
# in _build_env. Empty dict = grid disabled (default for 13 existing demos
# that don't declare a grid block — backward-compat sentinel).
var _grid_cfg_loaded: bool = false
var _grid_cfg: Dictionary = {}
func _load_grid_cfg() -> void:
	if _grid_cfg_loaded: return
	_grid_cfg_loaded = true
	var path := data_root.rstrip("/") + "/scene.json"
	if not FileAccess.file_exists(path): return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK: return
	if not (json.data is Dictionary): return
	var cfg: Dictionary = json.data
	if cfg.get("grid", null) is Dictionary:
		_grid_cfg = cfg["grid"]


# ============================================================
# MULTI-LEVEL (ADR 0006)
# ============================================================
## Active level + progression. current_level == "" for single-level games.
var current_level: String = ""
var level_order: Array = []
var levels_root: String = ""
var on_all_complete_msg: String = ""


func _load_progression(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK: return
	if not (json.data is Dictionary): return
	var p: Dictionary = json.data
	level_order = p.get("levels", [])
	current_level = str(p.get("starting_level", level_order[0] if level_order.size() > 0 else ""))
	levels_root = data_root.rstrip("/") + "/levels"
	var oac = p.get("on_all_complete", null)
	if oac is Dictionary:
		on_all_complete_msg = str((oac as Dictionary).get("win_message", ""))
	# Mirror current_level into world state for formula access.
	world_state["current_level"] = current_level





func _apply_level_seed_if_set(root: String) -> void:
	var path := root + "/scene.json"
	if not FileAccess.file_exists(path): return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK: return
	if not (json.data is Dictionary): return
	if not (json.data as Dictionary).has("level_seed"): return
	var s: int = int((json.data as Dictionary).get("level_seed", 0))
	seed(s)
	if verbose:
		print("[World] level_seed=%d applied — patterns are deterministic" % s)


func _apply_ground() -> void:
	_load_ground_cfg()
	if _ground_y == -INF: return
	var to_remove: Array[String] = []
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity): continue
		var p = (ent as Entity).get_position()
		var py: float = p.y if p is Vector3 else 0.0
		if py >= _ground_y: continue
		# Below ground. Despawn projectiles, clamp creatures.
		var despawn := false
		for t in _ground_despawn_tags:
			if (ent as Entity).has_tag(str(t)):
				despawn = true; break
		if despawn:
			to_remove.append(str(id))
			continue
		var clamp_match := false
		for t in _ground_clamp_tags:
			if (ent as Entity).has_tag(str(t)):
				clamp_match = true; break
		if clamp_match and p is Vector3:
			(ent as Entity).set_position(Vector3(p.x, _ground_y, p.z))
	for rid in to_remove:
		var rent: Entity = entities.get(rid, null)
		if rent == null: continue
		if relations != null:
			relations.clear_entity(rid)
		if spatial_index != null and spatial_index.has_method("remove_entity"):
			spatial_index.remove_entity(rid)
		entities.erase(rid)
		rent.queue_free()


## ADR 0004: build a snapshot of all `blocks_motion` AABBs for this frame.
## Each entry: full 3D AABB {minx, maxx, miny, maxy, minz, maxz}. The AABB
## is centered at `entity.position + properties.aabb_offset` (default zero
## offset), with half-extents from `properties.aabb_extents`. Y handling
## matters for projectiles fired upward — without it, bullets at high
## altitude get stuck against tall walls visually beneath them.
func _collect_blockers() -> Array:
	var out: Array = []
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity): continue
		if not (ent as Entity).has_tag("blocks_motion"): continue
		var ext = (ent as Entity).get_property("aabb_extents", null)
		if ext == null: continue
		var ext_v: Vector3 = _to_vec3(ext)
		var off_v: Vector3 = _to_vec3((ent as Entity).get_property("aabb_offset", [0, 0, 0]))
		var pos = (ent as Entity).get_position()
		var pos_v: Vector3 = Vector3.ZERO
		if pos is Vector3: pos_v = pos
		elif pos is Vector2: pos_v = Vector3(pos.x, 0, pos.y)
		else: continue
		var center: Vector3 = pos_v + off_v
		out.append({
			"minx": center.x - ext_v.x,
			"maxx": center.x + ext_v.x,
			"miny": center.y - ext_v.y,
			"maxy": center.y + ext_v.y,
			"minz": center.z - ext_v.z,
			"maxz": center.z + ext_v.z,
		})
	return out


## Resolve 3D motion against AABB blockers via separate-axes slide on XZ.
## Uses SWEPT (segment) intersection for correctness when entities move
## fast (bullets at 22 m/s × tick 0.05s = 1.1m/tick can teleport past
## 0.5m-thick walls if only endpoints are tested — empirically caught
## in doomarena3d "bullet bypass wall" bug 2026-05-04).
##
## When all 3 axes are blocked, position fully reverts so projectiles
## stop dead at the wall instead of sliding along it.
static func _resolve_motion_3d(old_p: Vector3, new_p: Vector3, body_r: float, blockers: Array) -> Vector3:
	if not _segment_intersects(old_p, new_p, body_r, blockers):
		return new_p
	# Try X-only: keep new x, old y/z. Segment from old → (new.x, old.y, old.z).
	var x_target := Vector3(new_p.x, old_p.y, old_p.z)
	if not _segment_intersects(old_p, x_target, body_r, blockers):
		return Vector3(new_p.x, new_p.y, old_p.z)
	# Try Z-only.
	var z_target := Vector3(old_p.x, old_p.y, new_p.z)
	if not _segment_intersects(old_p, z_target, body_r, blockers):
		return Vector3(old_p.x, new_p.y, new_p.z)
	# Try Y-only: bullets fired upward can clear a wall by altitude alone.
	var y_target := Vector3(old_p.x, new_p.y, old_p.z)
	if not _segment_intersects(old_p, y_target, body_r, blockers):
		return Vector3(old_p.x, new_p.y, old_p.z)
	# All blocked: stay (no axis can advance without crossing a blocker).
	return old_p


## Projectile variant — no slide. If the segment from old_p to new_p
## crosses any blocker, return old_p (caller is responsible for setting
## lifetime=0 so the bullet despawns at the wall instead of hanging).
## Without this, the slide-axis logic makes bullets crawl AROUND walls
## (empirically caught in doomarena3d 2026-05-04 playtest).
static func _resolve_projectile_3d(old_p: Vector3, new_p: Vector3, body_r: float, blockers: Array) -> Vector3:
	if _segment_intersects(old_p, new_p, body_r, blockers):
		return old_p
	return new_p


static func _resolve_projectile_2d(old_p: Vector2, new_p: Vector2, body_r: float, blockers: Array) -> Vector2:
	var o3 := Vector3(old_p.x, 0.0, old_p.y)
	var n3 := Vector3(new_p.x, 0.0, new_p.y)
	if _segment_intersects(o3, n3, body_r, blockers):
		return old_p
	return new_p


## 2D variant. Y=0 in the underlying 3D check.
static func _resolve_motion_2d(old_p: Vector2, new_p: Vector2, body_r: float, blockers: Array) -> Vector2:
	var o3 := Vector3(old_p.x, 0.0, old_p.y)
	var n3 := Vector3(new_p.x, 0.0, new_p.y)
	if not _segment_intersects(o3, n3, body_r, blockers):
		return new_p
	if not _segment_intersects(o3, Vector3(new_p.x, 0.0, old_p.y), body_r, blockers):
		return Vector2(new_p.x, old_p.y)
	if not _segment_intersects(o3, Vector3(old_p.x, 0.0, new_p.y), body_r, blockers):
		return Vector2(old_p.x, new_p.y)
	return old_p


## Test if a sphere at (px, py, pz) with radius r overlaps any blocker AABB.
## 3D static-position check — used by tests + as a building block.
static func _aabb_intersects(px: float, py: float, pz: float, r: float, blockers: Array) -> bool:
	var r2 := r * r
	for b in blockers:
		var cx: float = clamp(px, b["minx"], b["maxx"])
		var cy: float = clamp(py, b["miny"], b["maxy"])
		var cz: float = clamp(pz, b["minz"], b["maxz"])
		var dx := px - cx
		var dy := py - cy
		var dz := pz - cz
		if dx * dx + dy * dy + dz * dz < r2:
			return true
	return false


## Swept (segment) test for fast-moving entities. Slab method against
## AABB expanded by body_r in each axis (Minkowski sum approximated as
## an inflated box — correct enough for arcade-feel collision; not a true
## sphere-vs-AABB swept test). Returns true if the segment from p0 to p1
## crosses any blocker. Catches tunneling — entities moving > AABB
## thickness per tick can't slip through anymore.
static func _segment_intersects(p0: Vector3, p1: Vector3, body_r: float, blockers: Array) -> bool:
	if p0 == p1:
		return _aabb_intersects(p1.x, p1.y, p1.z, body_r, blockers)
	var dir := p1 - p0
	for b in blockers:
		var minx: float = b["minx"] - body_r
		var maxx: float = b["maxx"] + body_r
		var miny: float = b["miny"] - body_r
		var maxy: float = b["maxy"] + body_r
		var minz: float = b["minz"] - body_r
		var maxz: float = b["maxz"] + body_r
		var t_near := -INF
		var t_far := INF
		var hit := true
		# X slab
		if abs(dir.x) < 1e-6:
			if p0.x < minx or p0.x > maxx: hit = false
		else:
			var t1: float = (minx - p0.x) / dir.x
			var t2: float = (maxx - p0.x) / dir.x
			if t1 > t2:
				var tmp := t1; t1 = t2; t2 = tmp
			t_near = max(t_near, t1)
			t_far = min(t_far, t2)
		# Y slab
		if hit:
			if abs(dir.y) < 1e-6:
				if p0.y < miny or p0.y > maxy: hit = false
			else:
				var t1: float = (miny - p0.y) / dir.y
				var t2: float = (maxy - p0.y) / dir.y
				if t1 > t2:
					var tmp := t1; t1 = t2; t2 = tmp
				t_near = max(t_near, t1)
				t_far = min(t_far, t2)
		# Z slab
		if hit:
			if abs(dir.z) < 1e-6:
				if p0.z < minz or p0.z > maxz: hit = false
			else:
				var t1: float = (minz - p0.z) / dir.z
				var t2: float = (maxz - p0.z) / dir.z
				if t1 > t2:
					var tmp := t1; t1 = t2; t2 = tmp
				t_near = max(t_near, t1)
				t_far = min(t_far, t2)
		# Segment crosses if there's a valid interval and it overlaps [0,1].
		if hit and t_near <= t_far and t_far >= 0.0 and t_near <= 1.0:
			return true
	return false


## Coerce Array / Vector2 / Vector3 to Vector3.
static func _to_vec3(v) -> Vector3:
	if v is Vector3: return v
	if v is Vector2: return Vector3(v.x, 0, v.y)
	if v is Array:
		var a := v as Array
		if a.size() >= 3: return Vector3(float(a[0]), float(a[1]), float(a[2]))
		if a.size() == 2: return Vector3(float(a[0]), 0, float(a[1]))
	return Vector3.ZERO


## Generic tick summary: total entity count + counts per common tag.
## Adapts to whatever tags the loaded data uses; silent if no common ones match.
func _print_tick_summary(count: int) -> void:
	var bits: Array = ["n=%d" % entities.size()]
	# Probe a small set of common tags. Add yours here if useful.
	var probe_tags := ["seed", "young", "mature", "rotten", "water",
		"player", "sparkle", "enemy", "projectile", "crop",
		"fire", "tree", "burning_tree", "ash",
		"grass", "rabbit", "fox", "animal", "predator", "prey",
		"bird", "iron_ore", "iron", "copper_ore", "copper",
		"fertilizer", "mushroom", "seedling", "weather", "bush",
		"square", "piece"]
	for t in probe_tags:
		var n := QueryLib.run({"tags_all": [t]}, _build_env()).size()
		if n > 0:
			bits.append("%s=%d" % [t, n])
	# If a "ctr_1" counter is present, show its state (demo convenience).
	var ctr = entities.get("ctr_1", null)
	if ctr is Entity:
		bits.append("ctr=%s" % (ctr as Entity).state)
	print("[t%d] %s" % [count, " ".join(bits)])


# ============================================================
# PUBLIC API
# ============================================================

func queue_input(action: String, params: Dictionary = {}) -> void:
	scheduler.queue_input(action, params)


func entity(id: String) -> Entity:
	return entities.get(id, null)


func count_entities_matching(spec: Dictionary) -> int:
	return QueryLib.run(spec, _build_env()).size()


func count_relations_of(type: String) -> int:
	return relations.count(type)


# ============================================================
# INTERNAL
# ============================================================

func _build_env() -> Dictionary:
	# ADR 0038: ensure grid config is loaded before any rule resolves it.
	# Idempotent — first call from any path triggers; subsequent are no-op.
	_load_grid_cfg()
	return {
		"entities": entities,
		"defs": defs,
		"relations": relations,
		"spatial_index": spatial_index,
		"world": world_state,
		"parent": self,
		"next_id": next_id_seq,
		"error_buffer": error_buffer,
		# ADR 0011: ScreenFlow drains transition_screen / quit_app /
		# show_toast / reload_scene effects from this buffer. Lazily created
		# by effect_apply if no ScreenFlow is mounted (harmless — events
		# accumulate and stay quiet).
		"screen_event_buffer": [],
		# ADR 0012: OverlayManager drains show_overlay / dismiss_overlay
		# effects from this buffer.
		"overlay_event_buffer": [],
		# ADR 0031: zone-state primitive. Always non-null (empty store is
		# fine — backward-compat for demos with no world/zones.json).
		"zone_store": zone_store,
		# ADR 0038: grid config (empty dict = grid disabled). Step runner +
		# build_place + SpawnManager.spawn all read this via GridSnap helpers.
		"scene_grid": _grid_cfg,
	}
