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
@export var input_actions_hold: PackedStringArray = PackedStringArray([
	"move_north", "move_south", "move_east", "move_west",
])
## Input actions polled on PRESS edge — fire once per keypress, not every frame.
## Suitable for discrete events (spawn bullet, toggle, dialog advance).
@export var input_actions_press: PackedStringArray = PackedStringArray([
	"spark", "fire_north", "fire_south", "fire_east", "fire_west",
])
@export var actor_tag: String = "player"
## "stop" action queued when no movement keys pressed (lets velocity_set
## reset to zero). Empty string disables.
@export var stop_action_on_idle: String = "stop"

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
func load_data() -> void:
	var root := data_root.rstrip("/")
	# Tier 2.6t — register per-game input actions from inputs.json (if any).
	# Lets games own their input vocabulary; project.godot stays generic.
	InputRegistrar.register_from_data_root(root)
	_load_rules_file(root + "/world_rules.json")
	_load_world_file(root + "/world.json")
	# Entities can come from a single entities.json OR a per-def entities/
	# directory (each .json file = one entity blueprint). Both work; if both
	# exist they merge — directory load is additive on top.
	_load_entities_path(root)
	# Flush any effects queued by spawn triggers during initial load
	# (actual spawn-trigger dispatch lands in W2; flush is a no-op for W1).
	scheduler.flush_effects()
	if verbose:
		print("[World] loaded: %d defs, %d entities, %d relations" % [
			defs.size(), entities.size(), relations.count_total()
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


func _load_rules_file(path: String) -> void:
	var env := _build_env()
	var rules := Rule.load_from_file(path, env)
	var errors := Rule.validate_all(rules)
	for record in errors:
		EngineError.report(env, record)
	scheduler.register_rules(rules)
	if verbose:
		print("[World] %d rules registered" % rules.size())


func _load_world_file(path: String) -> void:
	if not FileAccess.file_exists(path): return
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	if data is Dictionary:
		world_state = (data.get("state", {}) as Dictionary).duplicate(true)


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
	scheduler.tick()
	_decrement_lifetimes()
	if verbose and count % 4 == 0:
		_print_tick_summary(count)


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
	# HOLD actions — fire every frame while held
	for action in input_actions_hold:
		if Input.is_action_pressed(action):
			scheduler.queue_input(action, {"actor": actor_id})
			if (action as String).begins_with("move_"):
				any_movement_pressed = true
	# PRESS actions — fire once on press-edge
	for action in input_actions_press:
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


func _find_actor_id() -> String:
	for id in entities.keys():
		var ent = entities[id]
		if ent is Entity and (ent as Entity).has_tag(actor_tag):
			return id
	return ""


## Integrate velocity → position each frame for smooth motion.
## Velocity is in units-per-second; multiply by delta. Updates spatial index.
##
## Tier 2.6i: entities with state.drag > 0 decelerate when no input is
## actively setting velocity. drag is per-second factor (0.0 = no drag,
## 1.0 = full stop in 1s). Velocity multiplies by (1 - drag * delta) each
## frame. Below DRAG_REST_EPSILON it snaps to zero.
const DRAG_REST_EPSILON := 0.5
func _integrate_motion(delta: float) -> void:
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
		if v is Vector2 and v != Vector2.ZERO:
			var p = (ent as Entity).get_position()
			if p is Vector2:
				(ent as Entity).set_position(p + v * delta)
				moved = true
			elif p is Vector3:
				# 2D velocity on 3D pos: project to XZ plane
				(ent as Entity).set_position(p + Vector3(v.x, 0, v.y) * delta)
				moved = true
		elif v is Vector3 and v != Vector3.ZERO:
			var p = (ent as Entity).get_position()
			if p is Vector3:
				(ent as Entity).set_position(p + v * delta)
				moved = true
			elif p is Vector2:
				# 3D velocity on 2D pos: take XZ
				(ent as Entity).set_position(p + Vector2(v.x, v.z) * delta)
				moved = true
		if moved and spatial_index != null:
			spatial_index.update_entity(id, (ent as Entity).get_planar_position())


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
	}
