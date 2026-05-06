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


# ============================================================
# LIFECYCLE
# ============================================================

func _ready() -> void:
	relations = RelationStore.new()
	spatial_index = SpatialIndex.new()
	scheduler = PhaseScheduler.new(_build_env())
	# If data_root is empty, look for `--game=<name>` cmdline arg.
	# Lets one universal scene file (scenes/play.tscn) drive any game:
	#   godot --path . scenes/play.tscn -- --game=demo_tinypond
	if data_root == "":
		_resolve_data_root_from_cmdline()
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
			_load_level(current_level)
	else:
		# Single-level layout
		_load_rules_file(root + "/world/physics.json")
		_load_rules_file(root + "/game/rules.json", true)
		_load_rules_file(root + "/tutorial.json", true)
		_load_world_file(root + "/world/state.json")
		_load_entities_path(root)
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
		world_state["has_save"] = 1 if SaveState.has_any_save(_game_name(), slots) else 0
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
	scheduler.flush_effects()
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
					_spawn_initial(inst)
	# Phase 2: process hand-coded initial instances + relations
	for d in dicts:
		for inst in d.get("initial_instances", []):
			if inst is Dictionary:
				_spawn_initial(inst)
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


func _spawn_initial(inst: Dictionary) -> void:
	var def_id := str(inst.get("def", ""))
	if not defs.has(def_id):
		EngineError.raise(_build_env(), EngineError.WORLD_DEF_UNKNOWN,
			"Unknown def: %s" % def_id,
			{"file": "entities.json", "field": "initial_instances.def", "got": def_id, "known_defs": defs.keys()},
			"Add a definition with id '%s' under 'definitions', or fix the typo in the instance's 'def' field." % def_id)
		return
	var count := int(inst.get("count", 1))
	for i in range(count):
		var overrides: Dictionary = (inst.get("overrides", {}) as Dictionary).duplicate(true)
		# Accept shortcut fields at top level of initial-instance JSON
		for sc in ["state", "position", "tags", "properties", "visual"]:
			if inst.has(sc) and not overrides.has(sc):
				overrides[sc] = inst[sc]
		var inst_id := ""
		if inst.has("id") and count == 1:
			inst_id = str(inst["id"])
		else:
			inst_id = "%s_%d" % [def_id, next_id_seq["_"]]
			next_id_seq["_"] += 1
		var ent := Entity.create(defs[def_id], inst_id, overrides)
		entities[inst_id] = ent
		add_child(ent)
		_attach_renderer(ent)
		# Register in spatial index at initial position
		if spatial_index != null:
			spatial_index.update_entity(inst_id, ent.get_planar_position())


## Attach a renderer child to an entity, if `renderer_script` is set.
## No-op for headless/test runs that set it to "".
func _attach_renderer(ent: Entity) -> void:
	if renderer_script == "": return
	# Honor `visual.hidden=true` — entities with no visual representation
	# (singletons like clocks, score trackers, world state holders). Without
	# this, the renderer falls through to the default colored-box and the
	# entity shows as a pink/grey square at its position. Empirically caught
	# during towerdef3d capture (2026-05-03).
	if bool((ent.visual as Dictionary).get("hidden", false)): return
	# `visual.hide_for_camera_attach=true` is now a SHADOW-ONLY flag, not
	# a skip. The renderer reads it and applies SHADOW_CASTING_SETTING_
	# SHADOWS_ONLY to its mesh children — the mesh disappears from the
	# viewer's camera but still casts a shadow on the ground. Doom/CSGO
	# pattern: viewer sees only the viewmodel hand/weapon, but their
	# shadow on the floor reveals their full body. (Empirically caught
	# during doomarena3d 2026-05-04 playtest: "i see only gun shadow.")
	var script := load(renderer_script)
	if script == null: return
	var node = script.new()
	if node is Node:
		# Allow per-game override of renderer's position_scale (and similar
		# exported props) via scene.json's `renderer` block. Tier 2.6q —
		# fpsgarden authors in world units (radius 13 = 13 meters) and
		# needs position_scale=1; existing 2D demos use the default 0.05
		# (200 pixels → 10 world units).
		_apply_renderer_overrides(node)
		ent.add_child(node)


# Cached scene_cfg renderer block — read from data_root/scene.json once.
var _renderer_cfg_loaded: bool = false
var _renderer_cfg: Dictionary = {}
func _apply_renderer_overrides(node) -> void:
	if not _renderer_cfg_loaded:
		_renderer_cfg_loaded = true
		var scene_path: String = data_root.rstrip("/") + "/scene.json"
		if FileAccess.file_exists(scene_path):
			var f := FileAccess.open(scene_path, FileAccess.READ)
			var data = JSON.parse_string(f.get_as_text())
			if data is Dictionary:
				var cfg = (data as Dictionary).get("renderer", {})
				if cfg is Dictionary: _renderer_cfg = cfg
	for k in _renderer_cfg.keys():
		# Only set props the renderer actually exposes
		if node.get(str(k)) != null or k in node:
			node.set(str(k), _renderer_cfg[k])


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
		# Still process pending save/load so a "Save" button in pause works
		process_pending_save_load()
		return
	scheduler.tick()
	_decrement_lifetimes()
	process_pending_level_transition()
	process_pending_save_load()
	# ADR 0016: switch_actor takes effect at next tick boundary. We process
	# AFTER scheduler.tick() so the current tick's rules saw the OLD
	# active_actor; the next tick's input phase will see the NEW one.
	process_pending_actor_switch()
	# Task #99: reset_world resets world_state + non-persistent entities
	# without scene reload. Processed after other deferred ops so any
	# in-flight save/load completes before the reset wipes state.
	process_pending_world_reset()
	if verbose and count % 4 == 0:
		_print_tick_summary(count)


## ADR 0010: process pending save/load between ticks. Same deferred pattern
## as level transitions — keeps save atomic relative to the simulation
## (capture stable post-tick state, never mid-rule).
##
## On save: serialize via SaveState.save_to_slot, refresh has_save binding,
## emit a toast for UI confirmation if a screen is active.
##
## On load: read the slot, refuse on version mismatch, then re-init the
## world (reload data) and overlay saved state. v1 takes the "easy"
## approach: re-load all entities/rules from disk, then apply the saved
## world_state + saved persistent_entities (overwriting their reloaded
## defaults). Persistent entities not in the save are left at default.
func process_pending_save_load() -> void:
	var env: Dictionary = scheduler.env
	# Save first (so a save+load in same frame still saves the pre-load state)
	var pending_save = env.get("_pending_save", null)
	if pending_save != null and pending_save is int:
		env.erase("_pending_save")
		_do_save(int(pending_save))
	var pending_load = env.get("_pending_load", null)
	if pending_load != null and pending_load is int:
		env.erase("_pending_load")
		_do_load(int(pending_load))


func _do_save(slot: int) -> void:
	if save_policy.is_empty():
		EngineError.raise(scheduler.env, EngineError.RULE_FILE_MISSING,
			"save_state effect fired but no save_policy.json present",
			{"slot": slot},
			"Add data/<game>/save_policy.json to opt in to persistence.",
			"warning")
		return
	var tick_n := _clock.tick_count if _clock != null else 0
	var ok := SaveState.save_to_slot(scheduler.env, save_policy, slot, _game_name(), tick_n)
	if ok:
		# Refresh has_save so menus update immediately
		var slots := int(save_policy.get("slots", 1))
		world_state["has_save"] = 1 if SaveState.has_any_save(_game_name(), slots) else 0
		if verbose:
			print("[World] saved slot %d" % slot)
	else:
		push_warning("[World] save to slot %d failed" % slot)


func _do_load(slot: int) -> void:
	if save_policy.is_empty():
		push_warning("load_state effect fired but no save_policy.json present")
		return
	var result: Dictionary = SaveState.read_slot(_game_name(), slot, save_policy)
	if not bool(result.get("ok", false)):
		var err := str(result.get("error", "unknown"))
		push_warning("[World] load slot %d failed: %s" % [slot, err])
		return
	var payload: Dictionary = result["payload"]
	# Apply saved world_state (replaces, doesn't merge — persisted keys are
	# the source of truth on load)
	var ws_in: Dictionary = payload.get("world_state", {}) as Dictionary
	for k in ws_in.keys():
		world_state[str(k)] = ws_in[k]
	# Reload current_level if it changed (re-spawns the level's entities)
	# AFTER state apply so the level loader sees the saved current_level.
	var saved_level := str(world_state.get("current_level", current_level))
	if saved_level != "" and saved_level != current_level:
		_do_level_transition(saved_level)
	# Apply saved persistent entities (overwrite the level's defaults)
	_apply_saved_entities(payload.get("persistent_entities", []))
	# Apply saved relations (additive — relations from level are kept,
	# saved ones added; redundant relate() calls are no-ops in
	# RelationStore)
	var rels = payload.get("relations", [])
	if rels is Array:
		for r in rels:
			if r is Dictionary:
				relations.relate(
					str(r.get("type", "")),
					str(r.get("from", "")),
					str(r.get("to", "")),
				)
	if verbose:
		print("[World] loaded slot %d (tick was %d)" % [slot, int((payload.get("_meta", {}) as Dictionary).get("tick", -1))])


## Apply a saved persistent_entities array. For each record:
##   - if an entity with that id exists, update its position + state
##   - if not, spawn from def at saved position with saved state
## Either way, ensure the entity carries the persistent tag.
func _apply_saved_entities(records: Array) -> void:
	for r in records:
		if not (r is Dictionary): continue
		var rec: Dictionary = r
		var inst_id := str(rec.get("id", ""))
		var def_id := str(rec.get("def", ""))
		if inst_id == "" or def_id == "": continue
		var pos = rec.get("position", null)
		var state_in: Dictionary = rec.get("state", {}) as Dictionary
		var ent = entities.get(inst_id, null)
		if ent != null and ent is Entity:
			# Existing — overwrite position + state
			(ent as Entity).set_position(pos)
			for k in state_in.keys():
				(ent as Entity).set_state(str(k), state_in[k])
		else:
			# Spawn from def
			_spawn_initial({
				"def": def_id, "id": inst_id,
				"position": pos, "state": state_in,
			})


## Resolve the data_root's basename for save namespacing.
## "res://data/demo_sokoban" → "demo_sokoban".
func _game_name() -> String:
	var s := data_root.rstrip("/")
	var slash := s.rfind("/")
	if slash < 0: return s
	return s.substr(slash + 1)


## ADR 0006: process queued level transitions AFTER the tick's effect chain
## has fully drained. Effect handlers set env._pending_level_transition;
## we read + clear it here so entity teardown happens between ticks, not
## mid-rule. Called from _on_tick AND from scenario_runner (which doesn't
## go through _on_tick).
func process_pending_level_transition() -> void:
	var env: Dictionary = scheduler.env
	var pending = env.get("_pending_level_transition", "")
	if str(pending) != "":
		env["_pending_level_transition"] = ""
		_do_level_transition(str(pending))


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
	_poll_input()
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


## Poll input actions and queue them on the scheduler. HOLD actions queue
## every frame the key is pressed; PRESS actions queue once per keypress
## (just_pressed edge). Both resolve `actor` to first entity tagged
## `actor_tag`. `stop_action_on_idle` queues when no movement keys are held.
func _poll_input() -> void:
	var actor_id := _find_actor_id()
	if actor_id == "": return
	var any_movement_pressed := false
	# HOLD actions — fire every frame while held. Skip actions not in
	# InputMap (per-game inputs.json may not register every default —
	# Tier 2.6t).
	for action in input_actions_hold:
		if not InputMap.has_action(action): continue
		if Input.is_action_pressed(action):
			scheduler.queue_input(action, {"actor": actor_id})
			if (action as String).begins_with("move_"):
				any_movement_pressed = true
	# PRESS actions — fire once on press-edge
	for action in input_actions_press:
		if not InputMap.has_action(action): continue
		if Input.is_action_just_pressed(action):
			scheduler.queue_input(action, {"actor": actor_id})
	# Stop action when no movement held (idempotent zero-velocity_set).
	# Type-guard: Vector2 != Vector3 throws in Godot 4.6.1, so check by type.
	if stop_action_on_idle != "" and not any_movement_pressed:
		var actor_ent = entities.get(actor_id, null)
		if actor_ent is Entity:
			var v = (actor_ent as Entity).get_velocity()
			var v_nonzero: bool = false
			if v is Vector2: v_nonzero = (v as Vector2) != Vector2.ZERO
			elif v is Vector3: v_nonzero = (v as Vector3) != Vector3.ZERO
			if v_nonzero:
				scheduler.queue_input(stop_action_on_idle, {"actor": actor_id})


## ADR 0016: resolve which entity should receive input this frame.
## Routes through actor_manager to find the entity controlled by the
## current active actor. Falls back to the legacy actor_tag scan if
## the manager isn't initialized (defensive — shouldn't happen post-load).
func _find_actor_id() -> String:
	if actor_manager != null:
		var id: String = actor_manager.resolve_active_entity(entities)
		if id != "": return id
	# Defensive fallback (matches pre-ADR-0016 behavior)
	for id in entities.keys():
		var ent = entities[id]
		if ent is Entity and (ent as Entity).has_tag(actor_tag):
			return id
	return ""


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
			_load_level(current_level)
	else:
		_load_entities_path(root)
	# 4. Refresh has_save (ADR 0010) — reset doesn't delete saves; it just
	# clears in-memory state. has_save remains accurate.
	if not save_policy.is_empty():
		var slots := int(save_policy.get("slots", 1))
		world_state["has_save"] = 1 if SaveState.has_any_save(_game_name(), slots) else 0
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


## Load the level subfolder at levels/<name>/. Per-level rules.json (if
## present) appends to global scheduler. Entities load from entities.json
## + entities/ directory.
func _load_level(name: String) -> void:
	if levels_root == "" or name == "": return
	var lvl_dir := levels_root + "/" + name
	_load_rules_file(lvl_dir + "/rules.json", true)
	_load_entities_path(lvl_dir)


## Process a queued level transition (set by transition_level effect).
## Removes non-persistent entities, clears scheduler rules, reloads next
## level's content. Player + persistent state survive.
func _do_level_transition(target: String) -> void:
	# Resolve "next" shorthand against progression order.
	if target == "next":
		var idx: int = level_order.find(current_level)
		if idx >= 0 and idx + 1 < level_order.size():
			target = str(level_order[idx + 1])
		else:
			# Past the last level — game won. Set a world-state flag so
			# HUD's win condition can trigger (binds to clock/world).
			world_state["all_levels_complete"] = 1
			if verbose:
				print("[World] all levels complete: ", on_all_complete_msg)
			return
	if not level_order.has(target):
		push_warning("[World] transition_level target '%s' not in progression.levels" % target)
		return
	# Remove non-persistent entities.
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
	# Clear scheduler rules and reload globals (persistent across levels).
	# physics first (register), game-rules appended. Per-level rules get
	# appended in _load_level.
	if scheduler != null and scheduler.has_method("clear_rules"):
		scheduler.clear_rules()
	var root := data_root.rstrip("/")
	_load_rules_file(root + "/world/physics.json")
	_load_rules_file(root + "/game/rules.json", true)
	# ADR 0012: tutorial.json is global (not per-level), re-register here
	# so sequencing rules survive level transitions.
	_load_rules_file(root + "/tutorial.json", true)
	# Load new level
	current_level = target
	world_state["current_level"] = target
	_load_level(target)
	scheduler.flush_effects()
	# ADR 0010 autosave: on_level_transition. Push a save into the env's
	# pending slot so the next process_pending_save_load picks it up.
	# Slot 0 = autosave by convention.
	if not save_policy.is_empty():
		var auto: Dictionary = save_policy.get("autosave", {}) as Dictionary
		if bool(auto.get("on_level_transition", false)):
			scheduler.env["_pending_save"] = 0
	if verbose:
		print("[World] transitioned to level: ", target)


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
	}
