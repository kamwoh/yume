extends Node3D

## Simulation World — reads generated_world.json and renders everything.
## ALL content comes from JSON. Godot only renders — no random generation here.
## Use tools/generate_sim_world.py to create the JSON.

var world_data: Dictionary = {}
var asset_config: Dictionary = {}
var meta_config: Dictionary = {}
var elements_config: Array = []
var world_w: float = 100.0
var world_h: float = 100.0

# Day/night
var day_night_enabled: bool = true
var cycle_seconds: float = 300.0
var day_ratio: float = 0.7
var time_of_day: float = 0.3
var sun_node: DirectionalLight3D
var env: Environment


func _ready() -> void:
	_load_configs()
	_build_environment()
	_build_heightmap_terrain()
	_build_edge_trees()
	_build_paths()
	_build_camp()
	_build_elements()
	_spawn_agents()
	_add_ui()
	_add_frame_capture()
	_add_multi_camera_qa()


func _load_configs() -> void:
	# Load generated world
	var wf := FileAccess.open("res://data/sim/generated_world.json", FileAccess.READ)
	if wf:
		var data = JSON.parse_string(wf.get_as_text())
		if data is Dictionary:
			world_data = data
			var ws: Dictionary = data.get("world_size", {})
			world_w = ws.get("width", 100.0)
			world_h = ws.get("height", 100.0)
			print("[SimWorld] Loaded generated world: ", world_w, "x", world_h, " seed=", data.get("seed", "?"))

	# Load element definitions
	var el_file := FileAccess.open("res://data/sim/elements.json", FileAccess.READ)
	if el_file:
		var data = JSON.parse_string(el_file.get_as_text())
		if data is Dictionary:
			elements_config = data.get("elements", [])

	var ac_file := FileAccess.open("res://data/asset_config.json", FileAccess.READ)
	if ac_file:
		var data = JSON.parse_string(ac_file.get_as_text())
		if data is Dictionary:
			asset_config = data

	var meta_file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if meta_file:
		var data = JSON.parse_string(meta_file.get_as_text())
		if data is Dictionary:
			meta_config = data

	var dn: Dictionary = world_data.get("day_night", {})
	day_night_enabled = dn.get("enabled", true)
	cycle_seconds = dn.get("cycle_seconds", 300.0)
	day_ratio = dn.get("day_ratio", 0.7)


func _build_environment() -> void:
	var atmo: Dictionary = world_data.get("atmosphere", {})
	var bg = atmo.get("bg_color", [0.47, 0.65, 1.0])
	var amb = atmo.get("ambient_light", [0.4, 0.45, 0.35])
	var sun_col = atmo.get("sun_color", [1.0, 0.9, 0.7])
	var sun_rot = atmo.get("sun_rotation", [-45, 30, 0])

	sun_node = DirectionalLight3D.new()
	sun_node.name = "Sun"
	sun_node.rotation_degrees = Vector3(sun_rot[0], sun_rot[1], sun_rot[2])
	sun_node.light_energy = atmo.get("sun_energy", 0.8)
	sun_node.light_color = Color(sun_col[0], sun_col[1], sun_col[2])
	sun_node.shadow_enabled = true
	add_child(sun_node)

	var env_node := WorldEnvironment.new()
	env = Environment.new()
	# Sky from JSON config (elements.json → sky section)
	var sky_cfg: Dictionary = {}
	var el_file2 := FileAccess.open("res://data/sim/elements.json", FileAccess.READ)
	if el_file2:
		var el_data2 = JSON.parse_string(el_file2.get_as_text())
		if el_data2 is Dictionary:
			sky_cfg = el_data2.get("sky", {})

	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	var st = sky_cfg.get("top_color", [0.3, 0.5, 0.9])
	var sh = sky_cfg.get("horizon_color", [0.65, 0.75, 0.95])
	var gb = sky_cfg.get("ground_bottom_color", [0.35, 0.55, 0.25])
	var gh = sky_cfg.get("ground_horizon_color", [0.6, 0.7, 0.85])
	sky_mat.sky_top_color = Color(st[0], st[1], st[2])
	sky_mat.sky_horizon_color = Color(sh[0], sh[1], sh[2])
	sky_mat.ground_bottom_color = Color(gb[0], gb[1], gb[2])
	sky_mat.ground_horizon_color = Color(gh[0], gh[1], gh[2])
	sky_mat.sun_angle_max = sky_cfg.get("sun_angle_max", 30.0)
	sky_mat.sun_curve = sky_cfg.get("sun_curve", 0.1)
	sky.sky_material = sky_mat
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(amb[0], amb[1], amb[2])
	env.ambient_light_energy = atmo.get("ambient_energy", 0.7)
	env.fog_enabled = true
	env.fog_light_color = Color(atmo.get("fog_color", [0.65, 0.72, 0.82])[0], atmo.get("fog_color", [0.65, 0.72, 0.82])[1], atmo.get("fog_color", [0.65, 0.72, 0.82])[2])
	env.fog_density = atmo.get("fog_density", 0.015)
	env.fog_sky_affect = 0.8
	env_node.environment = env
	add_child(env_node)


var terrain_node: Node = null  # Reference to terrain for height queries

func _build_heightmap_terrain() -> void:
	var terrain_data: Dictionary = world_data.get("terrain", {})
	var hmap: Dictionary = terrain_data.get("heightmap", {})

	if not hmap.is_empty():
		# Use real heightmap terrain
		var script = load("res://scripts/terrain.gd")
		if script:
			var terrain := StaticBody3D.new()
			terrain.name = "Terrain"
			terrain.set_script(script)
			add_child(terrain)
			terrain.build_from_data(hmap, world_w, world_h)
			terrain_node = terrain

			# Flowers are now handled by element scatter (grass_detail) — no need for separate sphere flowers
			print("[SimWorld] Heightmap terrain built")
			return

	# Fallback: flat ground
	_build_flat_ground()


func _build_flat_ground() -> void:
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	var mesh_inst := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(world_w, world_h)
	mesh_inst.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.55, 0.25)
	mat.roughness = 0.9
	mesh_inst.material_override = mat
	ground.add_child(mesh_inst)

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(world_w, 0.1, world_h)
	col.shape = box
	col.position.y = -0.05
	ground.add_child(col)
	add_child(ground)

	# Ground patches from JSON
	var patches: Array = world_data.get("terrain", {}).get("patches", [])
	for p in patches:
		var patch := MeshInstance3D.new()
		patch.mesh = CylinderMesh.new()
		patch.mesh.top_radius = p.get("radius", 2.0)
		patch.mesh.bottom_radius = p.get("radius", 2.0) * 1.1
		patch.mesh.height = 0.02
		patch.position = Vector3(p.get("x", 0), 0.01, p.get("z", 0))
		var pmat := StandardMaterial3D.new()
		var shade: String = str(p.get("shade", "lighter"))
		if shade == "lighter":
			pmat.albedo_color = Color(0.38, 0.58, 0.28)
		else:
			pmat.albedo_color = Color(0.3, 0.48, 0.2)
		patch.material_override = pmat
		ground.add_child(patch)

	# Flowers from JSON
	var flower_color_map: Dictionary = {
		"yellow": Color(0.9, 0.85, 0.2),
		"red": Color(0.9, 0.3, 0.3),
		"white": Color(0.95, 0.95, 0.9),
		"purple": Color(0.6, 0.3, 0.8),
	}
	var flowers: Array = world_data.get("terrain", {}).get("flowers", [])
	for f in flowers:
		var flower := MeshInstance3D.new()
		flower.mesh = SphereMesh.new()
		flower.mesh.radius = f.get("size", 0.06)
		flower.mesh.height = f.get("size", 0.06) * 2
		flower.position = Vector3(f.get("x", 0), 0.05, f.get("z", 0))
		var fmat := StandardMaterial3D.new()
		fmat.albedo_color = flower_color_map.get(str(f.get("color", "white")), Color.WHITE)
		flower.material_override = fmat
		ground.add_child(flower)

	print("[SimWorld] Ground: ", world_w, "x", world_h, " + ", patches.size(), " patches + ", flowers.size(), " flowers")


func _build_terrain() -> void:
	var hills: Array = world_data.get("terrain", {}).get("hills", [])
	for h in hills:
		var hill := MeshInstance3D.new()
		hill.mesh = SphereMesh.new()
		var r: float = h.get("radius", 3.0)
		var height: float = h.get("height", 0.5)
		hill.mesh.radius = r
		hill.mesh.height = r * 2
		hill.position = Vector3(h.get("x", 0), -r + height, h.get("z", 0))
		hill.scale = Vector3(1.0, height / r, 1.0)
		var hmat := StandardMaterial3D.new()
		hmat.albedo_color = Color(0.33, 0.53, 0.23)
		hmat.roughness = 1.0
		hill.material_override = hmat
		add_child(hill)
	print("[SimWorld] Terrain: ", hills.size(), " hills")


func _build_edge_trees() -> void:
	# Load tree tint config
	var tree_tint: Dictionary = {}
	for edef in elements_config:
		if str(edef.get("id", "")) == "tree":
			tree_tint = edef.get("tint", {})
			break

	var edge_trees: Array = world_data.get("edge_trees", [])
	for et in edge_trees:
		var ex: float = et.get("x", 0)
		var ez: float = et.get("z", 0)
		var ey: float = 0.0
		if terrain_node and terrain_node.has_method("get_height_at"):
			ey = terrain_node.get_height_at(ex, ez) - 0.15  # Sink into terrain
		var node := Node3D.new()
		node.name = "EdgeTree_" + str(randi() % 10000)
		node.position = Vector3(ex, ey, ez)
		if _try_add_model(node, str(et.get("model", "tree_default")), et.get("scale", 1.0), et.get("rotation_y", 0)):
			if tree_tint.get("enabled", false):
				_apply_tint(node, tree_tint)
		add_child(node)
	print("[SimWorld] Edge trees: ", edge_trees.size())


func _build_paths() -> void:
	var paths: Array = world_data.get("paths", [])
	var path_tint: Dictionary = {"enabled": true, "color": [0.55, 0.42, 0.25, 1.0]}  # Brown dirt color
	for p in paths:
		var px: float = p.get("x", 0)
		var pz: float = p.get("z", 0)
		var py: float = 0.02
		if terrain_node and terrain_node.has_method("get_height_at"):
			py = terrain_node.get_height_at(px, pz) + 0.02
		var node := Node3D.new()
		node.name = "Path_" + str(randi() % 10000)
		node.position = Vector3(px, py, pz)
		if _try_add_model(node, str(p.get("model", "ground_pathStraight")), p.get("scale", 1.0), p.get("rotation_y", 0)):
			_apply_tint(node, path_tint)  # Brown tint for dirt path
		add_child(node)
	print("[SimWorld] Paths: ", paths.size(), " brown tiles")


func _build_camp() -> void:
	var camp: Array = world_data.get("camp", [])
	# Load element defs for tinting camp elements
	var el_defs: Dictionary = {}
	for edef in elements_config:
		el_defs[str(edef.get("id", ""))] = edef

	for c in camp:
		var pos := Vector3(c.get("x", 0), 0, c.get("z", 0))
		# Place on terrain — sink slightly
		if terrain_node and terrain_node.has_method("get_height_at"):
			pos.y = terrain_node.get_height_at(pos.x, pos.z) - 0.1
		var model: String = str(c.get("model", "_primitive"))
		var scale: float = c.get("scale", 1.0)
		var rot_y: float = c.get("rotation_y", 0)

		var body := StaticBody3D.new()
		body.name = "Camp_" + str(c.get("element", ""))
		body.position = pos
		body.add_to_group("sim_element")
		body.set_meta("element_id", str(c.get("element", "")))

		_try_add_model(body, model, scale, rot_y)

		# Apply tint if defined
		var eid: String = str(c.get("element", ""))
		var edef: Dictionary = el_defs.get(eid, {})
		var tint_cfg = edef.get("tint", null)
		if tint_cfg is Dictionary and tint_cfg.get("enabled", false):
			_apply_tint(body, tint_cfg)

		# Light from JSON element config
		var light_cfg = edef.get("light", null)
		if light_cfg is Dictionary:
			var light := OmniLight3D.new()
			var lc = light_cfg.get("color", [1.0, 0.7, 0.3])
			light.light_color = Color(lc[0], lc[1], lc[2])
			light.light_energy = light_cfg.get("energy", 2.5)
			light.omni_range = light_cfg.get("range", 8.0)
			light.position.y = light_cfg.get("height", 1.0)
			light.shadow_enabled = true
			body.add_child(light)

		add_child(body)
	print("[SimWorld] Camp: ", camp.size(), " structures")


func _build_elements() -> void:
	var elements: Array = world_data.get("elements", [])
	# Load element definitions for material/collision/light config
	var el_defs: Dictionary = {}
	for edef in elements_config:
		el_defs[str(edef.get("id", ""))] = edef

	for el in elements:
		var eid: String = str(el.get("element", ""))
		var pos := Vector3(el.get("x", 0), 0, el.get("z", 0))
		var model: String = str(el.get("model", "_primitive"))
		var scale: float = el.get("scale", 1.0)
		var rot_y: float = el.get("rotation_y", 0)
		var edef: Dictionary = el_defs.get(eid, {})
		var obj_type: String = str(edef.get("object_type", "decoration"))

		# Place on terrain surface — sink slightly to avoid floating
		if terrain_node and terrain_node.has_method("get_height_at"):
			pos.y = terrain_node.get_height_at(pos.x, pos.z) - 0.1

		# Choose node type based on object_type
		var node: Node3D
		if obj_type == "entity" or obj_type == "element":
			var body := StaticBody3D.new()
			body.name = "El_" + eid + "_" + str(randi() % 10000)
			node = body
		else:
			# Decoration — just a Node3D, no physics
			node = Node3D.new()
			node.name = "Decor_" + eid + "_" + str(randi() % 10000)

		node.position = pos
		node.add_to_group("sim_element")
		node.set_meta("element_id", eid)
		node.set_meta("object_type", obj_type)

		# Load model or build from material config
		var mat_cfg = edef.get("material", null)
		var model_loaded := _try_add_model(node, model, scale, rot_y)
		if not model_loaded:
			if mat_cfg != null and mat_cfg is Dictionary:
				_add_from_material_config(node, mat_cfg, scale)
			else:
				_add_primitive_fallback(node, eid, scale)

		# Apply tint from JSON if model loaded but needs color correction
		if model_loaded:
			var tint_cfg = edef.get("tint", null)
			if tint_cfg is Dictionary and tint_cfg.get("enabled", false):
				_apply_tint(node, tint_cfg)

		# Collision from JSON config
		var col_cfg = edef.get("collision", null)
		if col_cfg != null and col_cfg is Dictionary and node is StaticBody3D:
			var col := CollisionShape3D.new()
			var col_type: String = str(col_cfg.get("type", "box"))
			if col_type == "box":
				var box := BoxShape3D.new()
				var s = col_cfg.get("size", [0.8, 1.5, 0.8])
				box.size = Vector3(s[0], s[1], s[2]) * scale
				col.shape = box
			col.position.y = col_cfg.get("offset_y", 0.5) * scale
			node.add_child(col)

		# Light from JSON config
		var light_cfg = edef.get("light", null)
		if light_cfg != null and light_cfg is Dictionary:
			var light := OmniLight3D.new()
			var lc = light_cfg.get("color", [1.0, 0.7, 0.3])
			light.light_color = Color(lc[0], lc[1], lc[2])
			light.light_energy = light_cfg.get("energy", 2.0)
			light.omni_range = light_cfg.get("range", 6.0)
			light.position.y = light_cfg.get("height", 1.0)
			light.shadow_enabled = true
			node.add_child(light)

		# Store HP for entities
		if edef.has("hp"):
			node.set_meta("hp", edef.get("hp"))
			node.set_meta("max_hp", edef.get("hp"))

		add_child(node)

	var entity_count: int = 0
	var element_count: int = 0
	var decor_count: int = 0
	for el in elements:
		var eid2: String = str(el.get("element", ""))
		var t: String = str(el_defs.get(eid2, {}).get("object_type", "decoration"))
		if t == "entity": entity_count += 1
		elif t == "element": element_count += 1
		else: decor_count += 1
	print("[SimWorld] Elements: ", elements.size(), " (", entity_count, " entities, ", element_count, " elements, ", decor_count, " decorations)")


func _load_model_at(model_name: String, pos: Vector3, scale: float, rot_y: float) -> void:
	"""Load a model as a simple Node3D (no collision, no group)."""
	var node := Node3D.new()
	node.name = "M_" + model_name
	node.position = pos
	if _try_add_model(node, model_name, scale, rot_y):
		add_child(node)


func _try_add_model(parent: Node3D, model_name: String, scale: float, rot_y: float) -> bool:
	"""Try loading GLB model. Returns true if loaded."""
	if model_name.begins_with("_primitive"):
		return false
	var search_paths: Array = asset_config.get("model_search_paths", ["res://models/"])
	var extensions: Array = asset_config.get("model_extensions", ["glb", "gltf"])
	for base_path in search_paths:
		for ext in extensions:
			var path: String = str(base_path) + model_name + "." + str(ext)
			if ResourceLoader.exists(path):
				var scene: PackedScene = load(path)
				if scene:
					var instance := scene.instantiate()
					instance.name = "Model"
					instance.scale = Vector3.ONE * scale
					instance.rotation_degrees.y = rot_y
					parent.add_child(instance)
					return true
	return false


func _apply_tint(node: Node3D, tint_cfg: Dictionary) -> void:
	"""Apply color tint to loaded GLB model from JSON config.
	Smart tinting: leaves get leaf color, bark gets trunk color."""
	var leaf_color_arr = tint_cfg.get("color", [0.3, 0.6, 0.25, 1.0])
	var trunk_color_arr = tint_cfg.get("trunk_color", null)
	var leaf_color := Color(leaf_color_arr[0], leaf_color_arr[1], leaf_color_arr[2], leaf_color_arr[3] if leaf_color_arr.size() > 3 else 1.0)
	var trunk_color: Color = leaf_color
	if trunk_color_arr is Array and trunk_color_arr.size() >= 3:
		trunk_color = Color(trunk_color_arr[0], trunk_color_arr[1], trunk_color_arr[2], trunk_color_arr[3] if trunk_color_arr.size() > 3 else 1.0)
	_tint_recursive(node, leaf_color, trunk_color)


func _tint_recursive(node: Node, leaf_color: Color, trunk_color: Color) -> void:
	if node is MeshInstance3D:
		var mat := StandardMaterial3D.new()
		# Check if this is bark/trunk by name
		var node_name: String = node.name.to_lower()
		var parent_name: String = node.get_parent().name.to_lower() if node.get_parent() else ""
		if "bark" in node_name or "trunk" in node_name or "wood" in node_name or "bark" in parent_name:
			mat.albedo_color = trunk_color
		else:
			mat.albedo_color = leaf_color
		mat.roughness = 0.85
		node.material_override = mat
	for child in node.get_children():
		_tint_recursive(child, leaf_color, trunk_color)


func _add_from_material_config(parent: Node3D, mat_cfg: Dictionary, scale: float) -> void:
	"""Build mesh from JSON material properties — no hardcoded values."""
	var mesh := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()

	# Color
	var c = mat_cfg.get("color", [0.5, 0.5, 0.5, 1.0])
	if c is Array:
		mat.albedo_color = Color(c[0], c[1], c[2], c[3] if c.size() > 3 else 1.0)

	# Material physics
	mat.metallic = mat_cfg.get("metallic", 0.0)
	mat.roughness = mat_cfg.get("roughness", 0.8)
	if str(mat_cfg.get("transparency", "")) == "alpha":
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	# Emission
	var em = mat_cfg.get("emission", null)
	if em != null and em is Array:
		mat.emission_enabled = true
		mat.emission = Color(em[0], em[1], em[2])
		mat.emission_energy_multiplier = mat_cfg.get("emission_energy", 1.0)

	# Shape from config
	var shape: String = str(mat_cfg.get("shape", "sphere"))
	var size_var: float = scale * (0.8 + randf() * 0.4)

	match shape:
		"cylinder":
			mesh.mesh = CylinderMesh.new()
			mesh.mesh.top_radius = mat_cfg.get("shape_radius", 1.0) * size_var
			mesh.mesh.bottom_radius = mat_cfg.get("shape_radius", 1.0) * size_var * 1.1
			mesh.mesh.height = mat_cfg.get("shape_height", 0.1) * size_var
		"sphere":
			mesh.mesh = SphereMesh.new()
			mesh.mesh.radius = mat_cfg.get("shape_radius", 0.5) * size_var
			mesh.mesh.height = mat_cfg.get("shape_radius", 0.5) * size_var * 2
		"box":
			mesh.mesh = BoxMesh.new()
			var bsize: float = mat_cfg.get("shape_radius", 0.5) * size_var
			mesh.mesh.size = Vector3(bsize, mat_cfg.get("shape_height", bsize), bsize)
		_:
			mesh.mesh = SphereMesh.new()
			mesh.mesh.radius = 0.3 * size_var

	mesh.position.y = mat_cfg.get("offset_y", 0.0) * size_var
	mesh.material_override = mat
	parent.add_child(mesh)


func _add_primitive_fallback(parent: Node3D, element_id: String, scale: float) -> void:
	"""Fallback primitive shapes when GLB not available."""
	var mesh := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	var size_var: float = scale

	match element_id:
		"tree":
			var trunk := MeshInstance3D.new()
			trunk.mesh = CylinderMesh.new()
			trunk.mesh.top_radius = 0.08 * size_var
			trunk.mesh.bottom_radius = 0.15 * size_var
			trunk.mesh.height = 2.0 * size_var
			trunk.position.y = 1.0 * size_var
			var tmat := StandardMaterial3D.new()
			tmat.albedo_color = Color(0.4, 0.25, 0.12)
			trunk.material_override = tmat
			parent.add_child(trunk)
			mesh.mesh = SphereMesh.new()
			mesh.mesh.radius = 0.7 * size_var
			mesh.mesh.height = 1.0 * size_var
			mesh.position.y = 2.2 * size_var
			mat.albedo_color = Color(0.2, 0.5, 0.15)
		"stone":
			mesh.mesh = BoxMesh.new()
			mesh.mesh.size = Vector3(0.7, 0.5, 0.6) * size_var
			mesh.position.y = 0.25 * size_var
			mat.albedo_color = Color(0.5, 0.48, 0.45)
		"water", "_primitive_water":
			mesh.mesh = CylinderMesh.new()
			mesh.mesh.top_radius = 2.0 * size_var
			mesh.mesh.bottom_radius = 2.2 * size_var
			mesh.mesh.height = 0.15
			mesh.position.y = -0.05
			mat.albedo_color = Color(0.15, 0.4, 0.75, 0.8)
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.metallic = 0.4
			mat.roughness = 0.05
		"campfire":
			mesh.mesh = SphereMesh.new()
			mesh.mesh.radius = 0.15
			mesh.position.y = 0.15
			mat.albedo_color = Color(1.0, 0.4, 0.05)
			mat.emission_enabled = true
			mat.emission = Color(1.0, 0.4, 0.05)
			mat.emission_energy_multiplier = 3.0
		_:
			mesh.mesh = BoxMesh.new()
			mesh.mesh.size = Vector3(0.5, 0.5, 0.5) * size_var
			mesh.position.y = 0.25 * size_var
			mat.albedo_color = Color(0.5, 0.5, 0.5)

	mesh.material_override = mat
	parent.add_child(mesh)


func _spawn_agents() -> void:
	var spawn: Dictionary = world_data.get("spawn", {})
	var spawn_x: float = spawn.get("x", 0)
	var spawn_z: float = spawn.get("z", 0)

	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(load("res://scripts/player_3d.gd"))
	player.position = Vector3(spawn_x, 0.5, spawn_z)
	player.add_to_group("player")

	# Load character model
	var player_model: String = str(meta_config.get("player", {}).get("model", "Knight"))
	var scale_map: Dictionary = asset_config.get("prop_scale_map", {})
	var pscale: float = scale_map.get(player_model, 0.4)
	var search_paths: Array = asset_config.get("model_search_paths", [])
	var extensions: Array = asset_config.get("model_extensions", ["glb", "gltf"])

	for base_path in search_paths:
		var found := false
		for ext in extensions:
			var path: String = str(base_path) + player_model + "." + str(ext)
			if ResourceLoader.exists(path):
				var scene: PackedScene = load(path)
				if scene:
					var instance := scene.instantiate()
					instance.name = "PlayerModel"
					instance.scale = Vector3.ONE * pscale
					instance.rotation_degrees.y = meta_config.get("player", {}).get("model_rotation_offset", 180)
					player.add_child(instance)
					var anim := _find_anim_player(instance)
					if anim:
						player.set_meta("anim_player", anim)
					found = true
					break
		if found:
			break

	# Capsule
	var col := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.2
	capsule.height = 0.9
	col.shape = capsule
	col.position.y = 0.45
	player.add_child(col)

	# Camera
	var spring := SpringArm3D.new()
	spring.name = "CameraArm"
	spring.position = Vector3(0, 2.0, 0)
	spring.rotation_degrees = Vector3(-30, 0, 0)
	spring.spring_length = 8.0
	spring.collision_mask = 0
	player.add_child(spring)
	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.current = true
	spring.add_child(cam)

	add_child(player)
	print("[SimWorld] Player spawned at (", spawn_x, ",", spawn_z, ")")


func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var r := _find_anim_player(child)
		if r:
			return r
	return null


func _add_ui() -> void:
	for script_name in ["minimap", "hp_bar"]:
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


var _multi_cam_added: bool = false

func _add_multi_camera_qa() -> void:
	if _multi_cam_added:
		return
	var cap: Dictionary = meta_config.get("capture", {})
	if not cap.get("auto", false):
		return
	_multi_cam_added = true
	var script = load("res://scripts/multi_camera_qa.gd")
	if script:
		var node := Node3D.new()
		node.name = "MultiCameraQA"
		node.set_script(script)
		add_child(node)


func _process(delta: float) -> void:
	if day_night_enabled:
		_update_day_night(delta)


func _update_day_night(delta: float) -> void:
	time_of_day += delta / cycle_seconds
	if time_of_day > 1.0:
		time_of_day -= 1.0

	var sun_angle: float = (time_of_day - 0.25) * 360.0
	sun_node.rotation_degrees.x = -sun_angle

	var day_start: float = 0.2
	var day_end: float = day_start + day_ratio
	var sun_energy: float
	if time_of_day > day_start and time_of_day < day_end:
		var day_progress: float = (time_of_day - day_start) / (day_end - day_start)
		sun_energy = sin(day_progress * PI) * 0.8
	else:
		sun_energy = 0.05

	sun_node.light_energy = sun_energy

	if time_of_day > day_start and time_of_day < day_end:
		var t: float = (time_of_day - day_start) / (day_end - day_start)
		if t < 0.1:
			env.background_color = Color(0.8, 0.5, 0.3).lerp(Color(0.47, 0.65, 1.0), t / 0.1)
		elif t > 0.9:
			env.background_color = Color(0.47, 0.65, 1.0).lerp(Color(0.8, 0.4, 0.2), (t - 0.9) / 0.1)
		else:
			env.background_color = Color(0.47, 0.65, 1.0)
		env.ambient_light_energy = 0.4 + sun_energy * 0.3
	else:
		env.background_color = Color(0.04, 0.04, 0.12)
		env.ambient_light_energy = 0.1

	if sun_energy > 0.1:
		var warmth: float = 1.0 - sun_energy
		sun_node.light_color = Color(1.0, 0.95 - warmth * 0.3, 0.8 - warmth * 0.4)
