extends Node2D
class_name World

## Top-level orchestrator. Owns the entity map, definitions, relation store,
## phase scheduler, world clock, and global world-state dictionary. Loads a
## data folder on `load_data()`, starts ticking on `_ready` if `auto_start`.
##
## Contract: docs/30_framework_primitives.md § "File layout after redesign"
##
## Entity nodes are children of this World node so they render in its coordinate
## frame. Renderer scripts (renderer_2d/) read `entity.visual` and draw on top.

@export_dir var data_root: String = ""       # e.g. "res://data/demo_ecology/"
@export var auto_start: bool = true
@export var tick_seconds: float = 0.5
@export var verbose: bool = false
## Optional: path to a Node2D script that renders Entity visuals. Each spawn
## attaches one instance as a child of the Entity. Set empty to disable (useful
## for headless tests).
@export_file("*.gd") var renderer_script: String = "res://scripts/renderer_2d/entity_sprite_2d.gd"

# ============================================================
# STATE
# ============================================================

var entities: Dictionary = {}                 # instance_id → Entity
var defs: Dictionary = {}                     # def_id → entity definition dict
var relations: RelationStore = null
var scheduler: PhaseScheduler = null
var world_state: Dictionary = {}              # global "world.*" bindings
var next_id_seq: Dictionary = {"_": 0}        # shared counter for spawns
var _clock: WorldClock = null


# ============================================================
# LIFECYCLE
# ============================================================

func _ready() -> void:
	relations = RelationStore.new()
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
	if verbose and count % 2 == 0:
		var seed_ent = entities.get("seed_1", null)
		if seed_ent is Entity:
			print("[tick %d] seed_1.growth=%s" % [count, (seed_ent as Entity).get_state("growth")])


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
		"world": world_state,
		"parent": self,
		"next_id": next_id_seq,
	}
