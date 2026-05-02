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
	if auto_start:
		start()


func start() -> void:
	if data_root != "":
		load_data()
	_start_clock()


# ============================================================
# DATA LOADING
# ============================================================

## Load entity defs, initial instances, initial relations, rules, and world
## state from `data_root/`. Order: rules → entities → world → initial flush.
## Rules load first so that spawn-triggered rules can fire during initial
## entity load (per W0 finding on lifecycle-flush-at-load).
func load_data() -> void:
	var root := data_root.rstrip("/")
	_load_rules_file(root + "/world_rules.json")
	_load_world_file(root + "/world.json")
	_load_entities_file(root + "/entities.json")
	# Flush any effects queued by spawn triggers during initial load
	# (actual spawn-trigger dispatch lands in W2; flush is a no-op for W1).
	scheduler.flush_effects()
	if verbose:
		print("[World] loaded: %d defs, %d entities, %d relations" % [
			defs.size(), entities.size(), relations.count_total()
		])


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


func _load_entities_file(path: String) -> void:
	var env := _build_env()
	if not FileAccess.file_exists(path):
		EngineError.raise(env, EngineError.WORLD_ENTITIES_MISSING,
			"No entities file: %s" % path,
			{"file": path},
			"Create an entities.json under data_root with {\"definitions\": [...], \"initial_instances\": [...]}.",
			"warning")
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		EngineError.raise(env, EngineError.WORLD_ENTITIES_INVALID,
			"Invalid JSON: %s" % path,
			{"file": path},
			"Top-level must be a JSON object with 'definitions' / 'initial_instances' / 'initial_relations'.")
		return
	for def in data.get("definitions", []):
		if def is Dictionary:
			defs[str(def.get("id", ""))] = def
	for inst in data.get("initial_instances", []):
		if inst is Dictionary:
			_spawn_initial(inst)
	for rel in data.get("initial_relations", []):
		if rel is Dictionary:
			relations.relate(
				str(rel.get("type", "")),
				str(rel.get("from", "")),
				str(rel.get("to", "")),
			)


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
		ent.add_child(node)


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
	if verbose and count % 4 == 0:
		_print_tick_summary(count)


# ============================================================
# PER-FRAME: input polling + motion integration (W2.2 + W2.5)
# ============================================================

func _process(delta: float) -> void:
	if scheduler == null: return
	_poll_input()
	_integrate_motion(delta)


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
func _integrate_motion(delta: float) -> void:
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity): continue
		var v = (ent as Entity).get_velocity()
		if v == null: continue
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
