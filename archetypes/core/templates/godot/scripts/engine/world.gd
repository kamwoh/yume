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
## Input actions to poll each frame and convert to engine input triggers.
## For each action in this list, if it's pressed/just-pressed, queue an
## input event. The `actor` payload resolves to the first entity tagged
## with `actor_tag` (W2 minimum — extensible to multi-actor later).
@export var input_actions: PackedStringArray = PackedStringArray([
	"move_north", "move_south", "move_east", "move_west", "spark",
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
			defs.size(), entities.size(), relations.count("_total_")
		])


func _load_rules_file(path: String) -> void:
	var rules := Rule.load_from_file(path)
	var errors := Rule.validate_all(rules)
	if not errors.is_empty():
		for e in errors:
			push_error("[Rules] " + e)
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
	if not FileAccess.file_exists(path):
		push_warning("No entities file: " + path); return
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		push_error("Invalid JSON: " + path); return
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
		push_error("Unknown def: " + def_id); return
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


## Poll Input.is_action_pressed for each configured input action; if pressed,
## queue an input event with `actor` resolved to first entity tagged
## `actor_tag`. Also queues `stop_action_on_idle` when no movement is pressed
## (lets velocity_set zero out cleanly).
func _poll_input() -> void:
	if input_actions.is_empty(): return
	var actor_id := _find_actor_id()
	if actor_id == "": return
	var any_movement_pressed := false
	for action in input_actions:
		if Input.is_action_just_pressed(action) or Input.is_action_pressed(action):
			scheduler.queue_input(action, {"actor": actor_id})
			# Heuristic: any move_* action counts as movement. Keep simple.
			if (action as String).begins_with("move_"):
				any_movement_pressed = true
	if stop_action_on_idle != "" and not any_movement_pressed:
		# Only queue stop ONCE per "no movement" period. Use just_released-like
		# heuristic: queue stop when previously something was pressed and now nothing.
		# For W2 minimum, just queue every frame — the velocity_set is idempotent.
		# Skip if all velocity-changing rules already set zero last frame.
		var actor_ent = entities.get(actor_id, null)
		if actor_ent is Entity:
			var v = (actor_ent as Entity).get_velocity()
			if v != null and v != Vector2.ZERO and v != Vector3.ZERO:
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
		"grass", "rabbit", "fox", "animal", "predator", "prey"]
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
	}
