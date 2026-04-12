extends Node3D

## Simulation World — reads generated_world.json and renders everything.
## ALL content comes from JSON. Godot only renders — no random generation here.
## Use tools/generate_sim_world.py to create the JSON.

var world_data: Dictionary = {}
var asset_config: Dictionary = {}
var meta_config: Dictionary = {}
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
	# Sky gradient — procedural sky instead of flat color
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.3, 0.5, 0.9)       # Deep blue at top
	sky_mat.sky_horizon_color = Color(0.65, 0.75, 0.95) # Light blue at horizon
	sky_mat.ground_bottom_color = Color(0.35, 0.55, 0.25) # Green ground reflection
	sky_mat.ground_horizon_color = Color(0.6, 0.7, 0.85)  # Hazy horizon
	sky_mat.sun_angle_max = 30.0
	sky_mat.sun_curve = 0.1
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

			# Place flowers on terrain surface
			var flowers: Array = terrain_data.get("flowers", [])
			for f in flowers:
				var fx: float = f.get("x", 0)
				var fz: float = f.get("z", 0)
				var fh: float = terrain.get_height_at(fx, fz)
				var flower := MeshInstance3D.new()
				flower.mesh = SphereMesh.new()
				flower.mesh.radius = f.get("size", 0.06)
				flower.mesh.height = f.get("size", 0.06) * 2
				flower.position = Vector3(fx, fh + 0.05, fz)
				var fmat := StandardMaterial3D.new()
				var fc: Dictionary = {"yellow": Color(0.9, 0.85, 0.2), "red": Color(0.9, 0.3, 0.3),
					"white": Color(0.95, 0.95, 0.9), "purple": Color(0.6, 0.3, 0.8)}
				fmat.albedo_color = fc.get(str(f.get("color", "white")), Color.WHITE)
				flower.material_override = fmat
				add_child(flower)

			print("[SimWorld] Heightmap terrain + ", flowers.size(), " flowers")
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
	var edge_trees: Array = world_data.get("edge_trees", [])
	for et in edge_trees:
		var ex: float = et.get("x", 0)
		var ez: float = et.get("z", 0)
		var ey: float = 0.0
		if terrain_node and terrain_node.has_method("get_height_at"):
			ey = terrain_node.get_height_at(ex, ez)
		_load_model_at(
			str(et.get("model", "tree_default")),
			Vector3(ex, ey, ez),
			et.get("scale", 1.0),
			et.get("rotation_y", 0)
		)
	print("[SimWorld] Edge trees: ", edge_trees.size())


func _build_paths() -> void:
	var paths: Array = world_data.get("paths", [])
	for p in paths:
		_load_model_at(
			str(p.get("model", "ground_pathStraight")),
			Vector3(p.get("x", 0), 0.01, p.get("z", 0)),
			p.get("scale", 0.5),
			p.get("rotation_y", 0)
		)
	print("[SimWorld] Paths: ", paths.size(), " tiles")


func _build_camp() -> void:
	var camp: Array = world_data.get("camp", [])
	for c in camp:
		var pos := Vector3(c.get("x", 0), 0, c.get("z", 0))
		var model: String = str(c.get("model", "_primitive"))
		var scale: float = c.get("scale", 1.0)
		var rot_y: float = c.get("rotation_y", 0)

		var body := StaticBody3D.new()
		body.name = "Camp_" + str(c.get("element", ""))
		body.position = pos
		body.add_to_group("sim_element")
		body.set_meta("element_id", str(c.get("element", "")))

		if _try_add_model(body, model, scale, rot_y):
			pass  # Model loaded
		# Point light for campfire
		if str(c.get("element", "")) == "campfire":
			var light := OmniLight3D.new()
			light.light_color = Color(1.0, 0.7, 0.3)
			light.light_energy = 2.5
			light.omni_range = 8.0
			light.position.y = 1.0
			light.shadow_enabled = true
			body.add_child(light)

		add_child(body)
	print("[SimWorld] Camp: ", camp.size(), " structures")


func _build_elements() -> void:
	var elements: Array = world_data.get("elements", [])
	for el in elements:
		var eid: String = str(el.get("element", ""))
		var pos := Vector3(el.get("x", 0), 0, el.get("z", 0))
		var model: String = str(el.get("model", "_primitive"))
		var scale: float = el.get("scale", 1.0)
		var rot_y: float = el.get("rotation_y", 0)

		# Place on terrain surface
		if terrain_node and terrain_node.has_method("get_height_at"):
			pos.y = terrain_node.get_height_at(pos.x, pos.z)

		var body := StaticBody3D.new()
		body.name = "El_" + eid + "_" + str(randi() % 10000)
		body.position = pos
		body.add_to_group("sim_element")
		body.set_meta("element_id", eid)

		if not _try_add_model(body, model, scale, rot_y):
			_add_primitive_fallback(body, eid, scale)

		# Collision for solid elements
		if eid in ["tree", "stone", "shelter"]:
			var col := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(0.8, 1.5, 0.8) * scale
			col.shape = box
			col.position.y = 0.75 * scale
			body.add_child(col)

		# Light for fire
		if eid == "campfire":
			var light := OmniLight3D.new()
			light.light_color = Color(1.0, 0.7, 0.3)
			light.light_energy = 2.0
			light.omni_range = 6.0
			light.position.y = 1.0
			body.add_child(light)

		add_child(body)
	print("[SimWorld] Elements: ", elements.size())


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
			mesh.mesh.top_radius = 1.5 * size_var
			mesh.mesh.bottom_radius = 1.6 * size_var
			mesh.mesh.height = 0.08
			mesh.position.y = -0.02
			mat.albedo_color = Color(0.15, 0.35, 0.7, 0.75)
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.metallic = 0.3
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
