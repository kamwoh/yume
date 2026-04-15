extends Node3D

## Simulation World — orchestrator. Reads JSON, then delegates building to:
##   ModelHelpers, WorldEnvironment (Node), WorldTerrain, WorldElements, WorldAgents.
## Owns shared state (configs, terrain_node ref). All content from JSON; nothing
## random or hardcoded happens here.

var world_data: Dictionary = {}
var asset_config: Dictionary = {}
var meta_config: Dictionary = {}
var elements_config: Array = []
var sky_config: Dictionary = {}
var world_w: float = 100.0
var world_h: float = 100.0

# data_root: subdirectory under res://data/ that holds generated_world.json + elements.json.
# Default is the real simulation. Override via meta.json "data_root" to run a lab
# (e.g. "res://data/labs/house/"). asset_config.json stays at res://data/ (shared).
var data_root: String = "res://data/sim/"

# Reference to the heightmap terrain node (used by elements/edge-trees/paths/camp
# for height queries). Null when terrain falls back to flat ground.
var terrain_node: Node = null


func _ready() -> void:
	_load_configs()
	_build_environment_module()
	_start_world_clock()
	terrain_node = WorldTerrain.build_heightmap(self, world_data, world_w, world_h)
	WorldTerrain.build_edge_trees(self, world_data, terrain_node, elements_config, asset_config)
	WorldTerrain.build_paths(self, world_data, terrain_node, asset_config)
	WorldTerrain.build_camp(self, world_data, terrain_node, elements_config, asset_config)
	WorldElements.build_all(self, world_data, terrain_node, elements_config, asset_config)
	WorldAgents.spawn_player(self, world_data, meta_config, asset_config)
	_start_population_manager()
	_start_world_rules()
	_add_ui()
	_add_frame_capture()
	_add_multi_camera_qa()


func _load_configs() -> void:
	# Meta first — it holds the data_root selector.
	var meta_file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if meta_file:
		var data = JSON.parse_string(meta_file.get_as_text())
		if data is Dictionary:
			meta_config = data

	var dr: String = str(meta_config.get("data_root", "res://data/sim/"))
	if not dr.ends_with("/"):
		dr += "/"
	data_root = dr
	print("[SimWorld] data_root=", data_root)

	var wf := FileAccess.open(data_root + "generated_world.json", FileAccess.READ)
	if wf:
		var data = JSON.parse_string(wf.get_as_text())
		if data is Dictionary:
			world_data = data
			var ws: Dictionary = data.get("world_size", {})
			world_w = ws.get("width", 100.0)
			world_h = ws.get("height", 100.0)
			print("[SimWorld] Loaded generated world: ", world_w, "x", world_h, " seed=", data.get("seed", "?"))

	# Element definitions are shared across labs — fall back to res://data/sim/elements.json.
	var el_path := data_root + "elements.json"
	if not FileAccess.file_exists(el_path):
		el_path = "res://data/sim/elements.json"
	var el_file := FileAccess.open(el_path, FileAccess.READ)
	if el_file:
		var data = JSON.parse_string(el_file.get_as_text())
		if data is Dictionary:
			elements_config = data.get("elements", [])
			sky_config = data.get("sky", {})

	var ac_file := FileAccess.open("res://data/asset_config.json", FileAccess.READ)
	if ac_file:
		var data = JSON.parse_string(ac_file.get_as_text())
		if data is Dictionary:
			asset_config = data


func _start_world_clock() -> void:
	## Single tick source for the simulation. Brains + rules engine subscribe
	## to its `tick` signal. Movement physics is unaffected.
	var clock := Node.new()
	clock.name = "WorldClock"
	clock.set_script(load("res://scripts/world_clock.gd"))
	add_child(clock)


func _build_environment_module() -> void:
	var env_node := Node.new()
	env_node.name = "WorldEnvironment"
	env_node.set_script(load("res://scripts/world_environment.gd"))
	add_child(env_node)
	env_node.build(self, world_data, sky_config)


func _start_population_manager() -> void:
	## Respawns agents when they die so the sim keeps running. Opt-in.
	var pop_cfg: Dictionary = meta_config.get("population", {})
	if pop_cfg.get("respawn_enabled", true) == false:
		return
	var initial: Array = world_data.get("agents", [])
	if initial.is_empty():
		return
	var mgr := Node.new()
	mgr.name = "PopulationManager"
	mgr.set_script(load("res://scripts/population_manager.gd"))
	add_child(mgr)
	mgr.setup(self, initial)


func spawn_element_at(element_id: String, pos: Vector3) -> Node:
	## Public helper — any script (brain, rule, command) can create a new
	## sim_element at a position. Used by farming/planting, rule spawns, etc.
	return WorldElements.spawn_one(self, element_id, pos, terrain_node, elements_config, asset_config)


func _start_world_rules() -> void:
	## Instantiate the rules engine. Must run AFTER agents spawn so the engine's
	## target-resolution can find them.
	var wr_cfg: Dictionary = meta_config.get("world_rules", {})
	if wr_cfg.get("enabled", true) == false:
		print("[SimWorld] World rules disabled via meta.json")
		return
	var script = load("res://scripts/world_rules_engine.gd")
	if not script:
		push_warning("[SimWorld] world_rules_engine.gd not found")
		return
	var node := Node.new()
	node.name = "WorldRulesEngine"
	node.set_script(script)
	# Hand the engine refs it needs to spawn/transform elements.
	node.world_root = self
	node.terrain_node = terrain_node
	node.elements_config = elements_config
	node.asset_config = asset_config
	add_child(node)


func _add_ui() -> void:
	for script_name in ["minimap", "hp_bar", "needs_hud"]:
		var script = load("res://scripts/" + script_name + ".gd")
		if script:
			var canvas := CanvasLayer.new()
			var ctrl := Control.new()
			ctrl.name = script_name.capitalize()
			ctrl.set_script(script)
			canvas.add_child(ctrl)
			add_child(canvas)


func _add_frame_capture() -> void:
	var script = load("res://scripts/frame_capture.gd")
	if script:
		var node := Node.new()
		node.name = "FrameCapture"
		node.set_script(script)
		add_child(node)


func _add_multi_camera_qa() -> void:
	var cap: Dictionary = meta_config.get("capture", {})
	if not cap.get("auto", false):
		return
	var script = load("res://scripts/multi_camera_qa.gd")
	if script:
		var node := Node3D.new()
		node.name = "MultiCameraQA"
		node.set_script(script)
		add_child(node)
