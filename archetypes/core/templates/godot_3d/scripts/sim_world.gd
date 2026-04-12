extends Node3D

## Simulation World — open field with naturally scattered elements.
## Reads data/sim/world_config.json for layout.
## Handles: ground plane, element scattering, lighting, day/night cycle.
## NOT a dungeon grid — this is an outdoor natural world.

var world_config: Dictionary = {}
var elements_config: Array = []
var asset_config: Dictionary = {}
var meta_config: Dictionary = {}

# Day/night
var day_night_enabled: bool = true
var cycle_seconds: float = 300.0
var day_ratio: float = 0.7
var time_of_day: float = 0.3  # 0-1, start at morning
var sun_node: DirectionalLight3D
var env: Environment

# World
var world_w: float = 40.0
var world_h: float = 40.0
var tile_size: float = 1.0


func _ready() -> void:
	_load_configs()
	_build_environment()
	_build_ground()
	_scatter_elements()
	_spawn_agents()
	_add_ui()
	_add_frame_capture()
	_add_multi_camera_qa()


func _load_configs() -> void:
	var wc_file := FileAccess.open("res://data/sim/world_config.json", FileAccess.READ)
	if wc_file:
		var data = JSON.parse_string(wc_file.get_as_text())
		if data is Dictionary:
			world_config = data
			var ws: Dictionary = data.get("world_size", {})
			world_w = ws.get("width", 40.0)
			world_h = ws.get("height", 40.0)
			tile_size = data.get("tile_size", 1.0)
			var dn: Dictionary = data.get("day_night", {})
			day_night_enabled = dn.get("enabled", true)
			cycle_seconds = dn.get("cycle_seconds", 300.0)
			day_ratio = dn.get("day_ratio", 0.7)

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


func _build_environment() -> void:
	var atmo: Dictionary = world_config.get("atmosphere", {})
	var bg_arr = atmo.get("bg_color", [0.4, 0.6, 0.8])
	var amb_arr = atmo.get("ambient_light", [0.4, 0.45, 0.35])
	var bg_color := Color(bg_arr[0], bg_arr[1], bg_arr[2]) if bg_arr is Array and bg_arr.size() >= 3 else Color(0.4, 0.6, 0.8)
	var amb_color := Color(amb_arr[0], amb_arr[1], amb_arr[2]) if amb_arr is Array and amb_arr.size() >= 3 else Color(0.4, 0.45, 0.35)

	# Sun
	sun_node = DirectionalLight3D.new()
	sun_node.name = "Sun"
	sun_node.rotation_degrees = Vector3(-45, 30, 0)
	sun_node.light_energy = atmo.get("sun_energy", 0.8)
	sun_node.light_color = Color(1.0, 0.95, 0.8)
	sun_node.shadow_enabled = true
	add_child(sun_node)

	# Environment
	var env_node := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = bg_color
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = amb_color
	env.ambient_light_energy = 0.5
	# Fog for world edges
	env.fog_enabled = true
	env.fog_light_color = Color(0.7, 0.75, 0.8)
	env.fog_density = 0.01
	env.fog_sky_affect = 0.5
	env_node.environment = env
	add_child(env_node)

	print("[SimWorld] Environment built: sun=", sun_node.light_energy, " fog=on")


func _build_ground() -> void:
	# Large flat green plane
	var ground := StaticBody3D.new()
	ground.name = "Ground"

	var mesh_inst := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(world_w, world_h)
	mesh_inst.mesh = plane

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.55, 0.25)  # Grass green
	mat.roughness = 0.9
	mesh_inst.material_override = mat
	ground.add_child(mesh_inst)

	# Collision
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(world_w, 0.1, world_h)
	col.shape = box
	col.position.y = -0.05
	ground.add_child(col)

	add_child(ground)
	print("[SimWorld] Ground: ", world_w, "x", world_h, " green plane")


func _scatter_elements() -> void:
	var scatter_config: Array = world_config.get("element_scatter", [])
	var total_elements: int = 0

	for scatter in scatter_config:
		var element_id: String = str(scatter.get("element", ""))
		var count: int = scatter.get("count", 5)
		var min_spacing: float = scatter.get("min_spacing", 3.0)
		var cluster_size: int = scatter.get("cluster_size", 1)

		# Find element definition
		var element_def: Dictionary = {}
		for el in elements_config:
			if str(el.get("id", "")) == element_id:
				element_def = el
				break

		if element_def.is_empty():
			continue

		var model_name: String = str(element_def.get("model", "rocks"))
		var model_scale: float = element_def.get("model_scale", 1.0)
		var placed_positions: Array = []

		for i in range(count):
			# Find position with min_spacing from existing
			var pos := Vector3.ZERO
			var valid := false
			for attempt in range(50):
				pos = Vector3(
					randf_range(-world_w / 2 + 2, world_w / 2 - 2),
					0,
					randf_range(-world_h / 2 + 2, world_h / 2 - 2)
				)
				valid = true
				for existing in placed_positions:
					if pos.distance_to(existing) < min_spacing:
						valid = false
						break
				if valid:
					break

			if not valid:
				continue

			# Place cluster
			for c in range(cluster_size):
				var cluster_offset := Vector3(
					randf_range(-1.0, 1.0) * c,
					0,
					randf_range(-1.0, 1.0) * c
				)
				var final_pos: Vector3 = pos + cluster_offset
				_spawn_element(element_id, element_def, model_name, model_scale, final_pos)
				total_elements += 1

			placed_positions.append(pos)

	print("[SimWorld] Scattered ", total_elements, " elements")


func _spawn_element(element_id: String, element_def: Dictionary, model_name: String, model_scale: float, pos: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = "Element_" + element_id + "_" + str(randi() % 10000)
	body.position = pos
	body.add_to_group("sim_element")
	body.set_meta("element_id", element_id)
	body.set_meta("element_data", element_def)

	# Load model
	var model_loaded := false
	var search_paths: Array = asset_config.get("model_search_paths", ["res://models/"])
	var extensions: Array = asset_config.get("model_extensions", ["glb", "gltf"])
	var scale_map: Dictionary = asset_config.get("prop_scale_map", {})
	var actual_scale: float = scale_map.get(model_name, 1.0) * model_scale

	for base_path in search_paths:
		if model_loaded:
			break
		for ext in extensions:
			var path: String = str(base_path) + model_name + "." + str(ext)
			if ResourceLoader.exists(path):
				var scene: PackedScene = load(path)
				if scene:
					var instance := scene.instantiate()
					instance.name = "Model"
					instance.scale = Vector3.ONE * actual_scale
					# Random Y rotation for natural feel
					instance.rotation.y = randf() * TAU
					# Tint model based on element type
					_tint_element_model(instance, element_id)
					body.add_child(instance)
					model_loaded = true
					break

	if not model_loaded:
		# Fallback: colored primitive shapes per element type
		var mesh := MeshInstance3D.new()
		var mat := StandardMaterial3D.new()

		match element_id:
			"tree":
				# Tall green cylinder + brown trunk
				var trunk := MeshInstance3D.new()
				trunk.mesh = CylinderMesh.new()
				trunk.mesh.top_radius = 0.15
				trunk.mesh.bottom_radius = 0.2
				trunk.mesh.height = 2.0
				trunk.position.y = 1.0
				var trunk_mat := StandardMaterial3D.new()
				trunk_mat.albedo_color = Color(0.45, 0.3, 0.15)
				trunk.material_override = trunk_mat
				body.add_child(trunk)
				# Green foliage sphere on top
				mesh.mesh = SphereMesh.new()
				mesh.mesh.radius = 0.8
				mesh.mesh.height = 1.2
				mesh.position.y = 2.2
				mat.albedo_color = Color(0.2, 0.55, 0.15)
			"stone":
				mesh.mesh = BoxMesh.new()
				mesh.mesh.size = Vector3(0.8, 0.6, 0.8) * model_scale
				mesh.position.y = 0.3 * model_scale
				mat.albedo_color = Color(0.55, 0.52, 0.48)
			"water":
				mesh.mesh = BoxMesh.new()
				mesh.mesh.size = Vector3(1.2, 0.1, 1.2) * model_scale
				mesh.position.y = -0.05
				mat.albedo_color = Color(0.2, 0.45, 0.75)
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				mat.albedo_color.a = 0.7
			"dirt":
				mesh.mesh = BoxMesh.new()
				mesh.mesh.size = Vector3(1.0, 0.15, 1.0) * model_scale
				mesh.position.y = 0.05
				mat.albedo_color = Color(0.45, 0.32, 0.18)
			"campfire":
				mesh.mesh = CylinderMesh.new()
				mesh.mesh.top_radius = 0.1
				mesh.mesh.bottom_radius = 0.3
				mesh.mesh.height = 0.5
				mesh.position.y = 0.25
				mat.albedo_color = Color(0.6, 0.3, 0.1)
				mat.emission_enabled = true
				mat.emission = Color(1.0, 0.5, 0.1)
				mat.emission_energy_multiplier = 2.0
			"shelter":
				# Simple house shape
				mesh.mesh = BoxMesh.new()
				mesh.mesh.size = Vector3(2.0, 1.5, 2.0)
				mesh.position.y = 0.75
				mat.albedo_color = Color(0.5, 0.35, 0.2)
				# Add roof
				var roof := MeshInstance3D.new()
				roof.mesh = PrismMesh.new()
				roof.mesh.size = Vector3(2.2, 0.8, 2.2)
				roof.position.y = 1.9
				var roof_mat := StandardMaterial3D.new()
				roof_mat.albedo_color = Color(0.6, 0.25, 0.1)
				roof.material_override = roof_mat
				body.add_child(roof)
			_:
				mesh.mesh = BoxMesh.new()
				mesh.mesh.size = Vector3(0.5, 0.5, 0.5) * model_scale
				mesh.position.y = 0.25 * model_scale
				mat.albedo_color = Color(0.5, 0.5, 0.5)

		mesh.material_override = mat
		body.add_child(mesh)

	# Collision (only for solid elements)
	var groups: Dictionary = element_def.get("groups", {})
	if groups.get("solid", 0) > 0:
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(0.8, 1.5, 0.8) * model_scale
		col.shape = box
		col.position.y = 0.75 * model_scale
		body.add_child(col)

	# HP for harvestable elements
	var hp: float = element_def.get("hp", 0)
	if hp > 0:
		body.set_meta("hp", hp)
		body.set_meta("max_hp", hp)

	# Point light for fire elements
	if groups.get("fire", 0) > 0 or groups.get("light_source", 0) > 0:
		var light := OmniLight3D.new()
		light.light_color = Color(1.0, 0.7, 0.3)
		light.light_energy = 2.0
		light.omni_range = 6.0
		light.position.y = 1.0
		light.shadow_enabled = true
		body.add_child(light)

	add_child(body)


func _tint_element_model(node: Node, element_id: String) -> void:
	## Apply color tint to GLB model based on element type
	var tint_colors: Dictionary = {
		"tree": Color(0.6, 0.9, 0.5),
		"stone": Color(0.75, 0.72, 0.68),
		"water": Color(0.5, 0.7, 1.0),
		"dirt": Color(0.7, 0.55, 0.35),
		"farmland": Color(0.65, 0.5, 0.3),
		"campfire": Color(1.0, 0.7, 0.4),
		"shelter": Color(0.8, 0.6, 0.4),
	}
	var tint: Color = tint_colors.get(element_id, Color.WHITE)
	if tint == Color.WHITE:
		return
	_apply_tint_recursive(node, tint)


func _apply_tint_recursive(node: Node, tint: Color) -> void:
	if node is MeshInstance3D:
		var mesh_inst: MeshInstance3D = node
		# Create tinted material
		var mat := StandardMaterial3D.new()
		mat.albedo_color = tint
		mat.roughness = 0.8
		mesh_inst.material_override = mat
	for child in node.get_children():
		_apply_tint_recursive(child, tint)


func _spawn_agents() -> void:
	var agents: Array = world_config.get("agents", [])
	for agent_config in agents:
		var agent_name: String = str(agent_config.get("name", "Agent"))
		var model_name: String = str(agent_config.get("model", "Knight"))
		var brain_type: String = str(agent_config.get("brain", "needs_driven"))
		var spawn: Dictionary = agent_config.get("spawn", {})
		var spawn_x: float = spawn.get("gx", world_w / 2) - world_w / 2
		var spawn_z: float = spawn.get("gz", world_h / 2) - world_h / 2

		# Create player using player_3d.gd pattern
		var player := CharacterBody3D.new()
		player.name = "Player_" + agent_name
		player.set_script(load("res://scripts/player_3d.gd"))
		player.position = Vector3(spawn_x, 0.5, spawn_z)
		player.add_to_group("player")

		# Override brain type in meta temporarily
		# Player_3d reads from meta.json, but we want needs_driven
		# For now, store config on the player
		player.set_meta("sim_brain", brain_type)
		player.set_meta("sim_config", agent_config)

		# Load character model
		var model_loaded := false
		var search_paths: Array = asset_config.get("model_search_paths", ["res://models/"])
		var extensions: Array = asset_config.get("model_extensions", ["glb", "gltf"])
		var scale_map: Dictionary = asset_config.get("prop_scale_map", {})
		var pscale: float = scale_map.get(model_name, 0.4)

		for base_path in search_paths:
			if model_loaded:
				break
			for ext in extensions:
				var path: String = str(base_path) + model_name + "." + str(ext)
				if ResourceLoader.exists(path):
					var scene: PackedScene = load(path)
					if scene:
						var instance := scene.instantiate()
						instance.name = "PlayerModel"
						instance.scale = Vector3.ONE * pscale
						var rot_offset: float = meta_config.get("player", {}).get("model_rotation_offset", 180)
						instance.rotation_degrees.y = rot_offset
						player.add_child(instance)

						# Find AnimationPlayer
						var anim_player: AnimationPlayer = _find_anim_player_recursive(instance)
						if anim_player:
							player.set_meta("anim_player", anim_player)
						model_loaded = true
						break

		# Capsule collision
		var col := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.2
		capsule.height = 0.9
		col.shape = capsule
		col.position.y = 0.45
		player.add_child(col)

		# Camera — higher and further back for simulation view
		var spring_arm := SpringArm3D.new()
		spring_arm.name = "CameraArm"
		spring_arm.position = Vector3(0, 2.0, 0)
		spring_arm.rotation_degrees = Vector3(-30, 0, 0)
		spring_arm.spring_length = 8.0
		spring_arm.collision_mask = 0  # No wall clipping in open world
		player.add_child(spring_arm)

		var camera := Camera3D.new()
		camera.name = "Camera"
		camera.current = true
		spring_arm.add_child(camera)

		add_child(player)
		print("[SimWorld] Agent: ", agent_name, " model=", model_name, " brain=", brain_type, " at (", spawn_x, ",", spawn_z, ")")


func _find_anim_player_recursive(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var result := _find_anim_player_recursive(child)
		if result:
			return result
	return null


func _add_ui() -> void:
	# Minimap
	var minimap_script = load("res://scripts/minimap.gd")
	if minimap_script:
		var canvas := CanvasLayer.new()
		canvas.name = "MinimapLayer"
		var minimap := Control.new()
		minimap.name = "Minimap"
		minimap.set_script(minimap_script)
		canvas.add_child(minimap)
		add_child(canvas)

	# HP bar
	var hp_script = load("res://scripts/hp_bar.gd")
	if hp_script:
		var canvas := CanvasLayer.new()
		canvas.name = "HUDLayer"
		var hud := Control.new()
		hud.name = "HPBar"
		hud.set_script(hp_script)
		canvas.add_child(hud)
		add_child(canvas)


func _add_multi_camera_qa() -> void:
	# Only add if capture.auto is true (QA mode)
	var cap: Dictionary = meta_config.get("capture", {})
	if not cap.get("auto", false):
		return
	var script = load("res://scripts/multi_camera_qa.gd")
	if script:
		var multi_cam := Node3D.new()
		multi_cam.name = "MultiCameraQA"
		multi_cam.set_script(script)
		add_child(multi_cam)


func _add_frame_capture() -> void:
	var script = load("res://scripts/frame_capture.gd")
	if script:
		var capture := Node.new()
		capture.name = "FrameCapture"
		capture.set_script(script)
		add_child(capture)


func _process(delta: float) -> void:
	if day_night_enabled:
		_update_day_night(delta)


func _update_day_night(delta: float) -> void:
	time_of_day += delta / cycle_seconds
	if time_of_day > 1.0:
		time_of_day -= 1.0

	# Sun angle follows time: 0=midnight, 0.25=sunrise, 0.5=noon, 0.75=sunset
	var sun_angle: float = (time_of_day - 0.25) * 360.0
	sun_node.rotation_degrees.x = -sun_angle

	# Sun energy: bright during day, dark at night
	var day_start: float = 0.2
	var day_end: float = day_start + day_ratio
	var sun_energy: float
	if time_of_day > day_start and time_of_day < day_end:
		# Daytime
		var day_progress: float = (time_of_day - day_start) / (day_end - day_start)
		sun_energy = sin(day_progress * PI) * 0.8  # Peak at noon
	else:
		sun_energy = 0.05  # Night

	sun_node.light_energy = sun_energy

	# Sky color shifts
	if time_of_day > day_start and time_of_day < day_end:
		var t: float = (time_of_day - day_start) / (day_end - day_start)
		if t < 0.1:
			# Sunrise: orange → blue
			env.background_color = Color(0.8, 0.5, 0.3).lerp(Color(0.47, 0.65, 1.0), t / 0.1)
		elif t > 0.9:
			# Sunset: blue → orange
			env.background_color = Color(0.47, 0.65, 1.0).lerp(Color(0.8, 0.4, 0.2), (t - 0.9) / 0.1)
		else:
			# Day: blue sky
			env.background_color = Color(0.47, 0.65, 1.0)
		env.ambient_light_energy = 0.4 + sun_energy * 0.3
	else:
		# Night: dark blue
		env.background_color = Color(0.04, 0.04, 0.12)
		env.ambient_light_energy = 0.1

	# Sun color: warm during sunrise/sunset, white during day
	if sun_energy > 0.1:
		var warmth: float = 1.0 - sun_energy  # More warm when low
		sun_node.light_color = Color(1.0, 0.95 - warmth * 0.3, 0.8 - warmth * 0.4)
