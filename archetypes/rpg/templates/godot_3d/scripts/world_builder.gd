extends Node3D

## World Builder — reads location JSON and spawns 3D world.
## Same JSON as 2D engine — different renderer.
## Loads GLB models from models/ folder, falls back to primitive boxes.

var current_location: Dictionary = {}
var asset_config: Dictionary = {}
var meta_config: Dictionary = {}
var world_config: Dictionary = {}
var player_config: Dictionary = {}

func _ready() -> void:
	_load_asset_config()
	_load_meta_config()
	_build_environment()
	_load_and_build_location()
	_add_frame_capture()


func _add_frame_capture() -> void:
	var script = load("res://scripts/frame_capture.gd")
	if script:
		var capture := Node.new()
		capture.name = "FrameCapture"
		capture.set_script(script)
		add_child(capture)


func _load_meta_config() -> void:
	var file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		if data is Dictionary:
			meta_config = data
			world_config = data.get("world", {})
			if not world_config is Dictionary: world_config = {}
			player_config = data.get("player", {})
			if not player_config is Dictionary: player_config = {}


func _w(key: String, default = null):
	return world_config.get(key, default)

func _p(key: String, default = null):
	return player_config.get(key, default)


func _load_asset_config() -> void:
	var file := FileAccess.open("res://data/asset_config.json", FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		if data is Dictionary:
			asset_config = data


func _build_environment() -> void:
	# Read atmosphere from location data or use defaults
	var atmo: Dictionary = current_location.get("atmosphere", {})
	var bg_color_arr = atmo.get("bg_color", [0.4, 0.6, 0.8])
	var ambient_arr = atmo.get("ambient_light", [0.3, 0.3, 0.4])
	var bg_color := Color(bg_color_arr[0], bg_color_arr[1], bg_color_arr[2]) if bg_color_arr is Array and bg_color_arr.size() >= 3 else Color(0.4, 0.6, 0.8)
	var ambient_color := Color(ambient_arr[0], ambient_arr[1], ambient_arr[2]) if ambient_arr is Array and ambient_arr.size() >= 3 else Color(0.3, 0.3, 0.4)

	# Sun — config from meta.json world section
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	var sun_rot = _w("sun_rotation", [-45, 30, 0])
	if sun_rot is Array and sun_rot.size() >= 3:
		light.rotation_degrees = Vector3(sun_rot[0], sun_rot[1], sun_rot[2])
	light.light_energy = _w("sun_energy", 0.8)
	light.shadow_enabled = true
	add_child(light)

	# World environment
	var env_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = bg_color
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = ambient_color
	environment.ambient_light_energy = _w("ambient_energy", 0.5)
	env_node.environment = environment
	add_child(env_node)

	# Dark rooms
	var lighting: Dictionary = atmo.get("lighting", {})
	var light_type = lighting.get("type", "")
	if str(light_type) == "dark":
		environment.ambient_light_energy = _w("dark_ambient_energy", 0.1)
	elif str(light_type) == "dim":
		environment.ambient_light_energy = _w("dim_ambient_energy", 0.3)


func _load_and_build_location() -> void:
	# Load starting location from progression.json
	var prog_file := FileAccess.open("res://data/progression.json", FileAccess.READ)
	var location_id := ""
	if prog_file:
		var prog = JSON.parse_string(prog_file.get_as_text())
		if prog is Dictionary:
			location_id = str(prog.get("starting_location", ""))

	if location_id == "":
		# Fallback: load first JSON in locations/
		var dir := DirAccess.open("res://data/locations/")
		if dir:
			dir.list_dir_begin()
			var f := dir.get_next()
			while f != "":
				if f.ends_with(".json"):
					location_id = f.replace(".json", "")
					break
				f = dir.get_next()

	if location_id == "":
		push_warning("No location to load")
		return

	_build_location(location_id)
	_spawn_player()


func _build_location(location_id: String) -> void:
	var path: String = "res://data/locations/" + location_id + ".json"
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("Location not found: " + path)
		return

	var data = JSON.parse_string(file.get_as_text())
	if not data is Dictionary:
		push_error("Invalid JSON: " + path)
		return

	current_location = data
	_build_environment()  # Re-build with location atmosphere

	# Check if room uses grid-based design (modular tiles)
	if data.has("grid"):
		_build_grid_room(data)
		return

	var layout: Dictionary = data.get("layout", {})
	var scale_factor: float = _w("pixels_to_units", 50.0)
	var width: float = layout.get("width", 900) / scale_factor
	var height: float = layout.get("height", 600) / scale_factor
	var floor_thick: float = _w("floor_thickness", 0.2)
	var wall_h: float = _w("wall_height", 3.0)
	var wall_thick: float = _w("wall_thickness", 0.3)
	var ground_color_arr = layout.get("ground_color", [0.3, 0.5, 0.25])
	var ground_color := Color(ground_color_arr[0], ground_color_arr[1], ground_color_arr[2]) if ground_color_arr is Array else Color(0.3, 0.5, 0.25)

	# Floor
	_add_box("Floor", Vector3(width, floor_thick, height), Vector3(0, -floor_thick / 2, 0), ground_color, true)

	# Walls
	var wall_color := Color(ground_color.r * 0.7, ground_color.g * 0.7, ground_color.b * 0.7)
	_add_box("Wall_N", Vector3(width, wall_h, wall_thick), Vector3(0, wall_h / 2, -height / 2), wall_color, true)
	_add_box("Wall_S", Vector3(width, wall_h, wall_thick), Vector3(0, wall_h / 2, height / 2), wall_color, true)
	_add_box("Wall_W", Vector3(wall_thick, wall_h, height), Vector3(-width / 2, wall_h / 2, 0), wall_color, true)
	_add_box("Wall_E", Vector3(wall_thick, wall_h, height), Vector3(width / 2, wall_h / 2, 0), wall_color, true)

	# Props from JSON
	var props: Array = data.get("props", [])
	for prop in props:
		# Support both 2D pixel coords (x,y) and explicit 3D coords (x3d, y3d, z3d)
		var px: float
		var py: float = 0.0
		var pz: float
		if prop.has("x3d"):
			px = prop.get("x3d", 0)
			py = prop.get("y3d", 0)
			pz = prop.get("z3d", 0)
		else:
			px = prop.get("x", 0) / scale_factor - width / 2
			pz = prop.get("y", 0) / scale_factor - height / 2
		var prop_type: String = str(prop.get("type", "box"))
		var pc = prop.get("color", [0.5, 0.5, 0.5])
		var prop_color := Color(pc[0], pc[1], pc[2]) if pc is Array and pc.size() >= 3 else Color(0.5, 0.5, 0.5)

		# Try loading GLB model
		var loaded := _try_load_model(prop_type, Vector3(px, py, pz))
		if not loaded:
			# Fallback: primitive box
			var size := _prop_size(prop_type)
			_add_box("Prop_" + prop_type, size, Vector3(px, size.y / 2, pz), prop_color, true)

	# Treasures
	var treasures: Array = data.get("treasures", [])
	for t in treasures:
		var tx: float
		var tz: float
		if t.has("x3d"):
			tx = t.get("x3d", 0)
			tz = t.get("z3d", 0)
		else:
			tx = t.get("x", 0) / scale_factor - width / 2
			tz = t.get("y", 0) / scale_factor - height / 2
		var loaded := _try_load_model("chest", Vector3(tx, 0, tz))
		if not loaded:
			var chest_size: Vector3 = _prop_size("chest")
			_add_box("Chest", chest_size, Vector3(tx, chest_size.y / 2, tz), Color(0.7, 0.55, 0.2), true)

	# NPCs
	var npcs: Array = data.get("ambient_npcs", [])
	for npc in npcs:
		var nx: float
		var nz: float
		if npc.has("x3d"):
			nx = npc.get("x3d", 0)
			nz = npc.get("z3d", 0)
		else:
			nx = npc.get("x", 0) / scale_factor - width / 2
			nz = npc.get("y", 0) / scale_factor - height / 2
		var nc = npc.get("color", [0.5, 0.5, 0.5])
		var npc_color := Color(nc[0], nc[1], nc[2]) if nc is Array and nc.size() >= 3 else Color(0.5, 0.5, 0.5)
		# Try character model by NPC name, then generic
		var npc_model: String = str(npc.get("model", "character-human"))
		var loaded := _try_load_model(npc_model, Vector3(nx, 0, nz))
		if not loaded:
			# Fallback: capsule
			_add_capsule(str(npc.get("name", "NPC")), 0.25, 1.0, Vector3(nx, 0.5, nz), npc_color)

	print("[World] Built: ", data.get("name", location_id), " (", props.size(), " props, ", treasures.size(), " chests, ", npcs.size(), " NPCs)")


func _build_grid_room(data: Dictionary) -> void:
	## Build room from modular tiles on a grid.
	var grid: Dictionary = data.get("grid", {})
	var tile_size: float = grid.get("tile_size", 1.0)
	var tile_names: Dictionary = grid.get("tiles", {})
	var grid_map: Array = grid.get("map", [])

	if grid_map.is_empty():
		return

	var rows: int = grid_map.size()
	var cols: int = str(grid_map[0]).length() if rows > 0 else 0
	var offset_x: float = -cols * tile_size / 2.0
	var offset_z: float = -rows * tile_size / 2.0

	print("[Grid] Building ", cols, "x", rows, " grid room")

	# Place tiles based on the map
	for z in range(rows):
		var row: String = str(grid_map[z])
		for x in range(cols):
			if x >= row.length():
				continue
			var cell: String = row[x]
			var world_x: float = offset_x + x * tile_size + tile_size / 2
			var world_z: float = offset_z + z * tile_size + tile_size / 2
			var pos := Vector3(world_x, 0, world_z)

			match cell:
				"F":
					# Floor tile
					var floor_model: String = str(tile_names.get("floor", "floor"))
					_try_load_model(floor_model, pos)
				"W":
					# Wall tile (floor + wall on top)
					var floor_model: String = str(tile_names.get("floor", "floor"))
					_try_load_model(floor_model, pos)
					var wall_model: String = str(tile_names.get("wall", "wall"))
					_try_load_model(wall_model, pos)
				"D":
					# Doorway (floor + opening)
					var floor_model: String = str(tile_names.get("floor", "floor"))
					_try_load_model(floor_model, pos)
					var door_model: String = str(tile_names.get("door", "wall-opening"))
					_try_load_model(door_model, pos)
				".":
					pass  # Empty — no tile

	# Place props on grid coordinates
	var props_on_grid: Array = data.get("props_on_grid", [])
	for prop in props_on_grid:
		var gx: int = prop.get("gx", 0)
		var gz: int = prop.get("gz", 0)
		var y_off: float = prop.get("y_offset", 0.0)
		var world_x: float = offset_x + gx * tile_size + tile_size / 2
		var world_z: float = offset_z + gz * tile_size + tile_size / 2
		var prop_type: String = str(prop.get("type", "barrel"))
		_try_load_model(prop_type, Vector3(world_x, y_off, world_z))

	# Place NPCs on grid coordinates
	var npcs_on_grid: Array = data.get("npcs_on_grid", [])
	for npc in npcs_on_grid:
		var gx: int = npc.get("gx", 0)
		var gz: int = npc.get("gz", 0)
		var world_x: float = offset_x + gx * tile_size + tile_size / 2
		var world_z: float = offset_z + gz * tile_size + tile_size / 2
		var npc_model: String = str(npc.get("model", "character-human"))
		_try_load_model(npc_model, Vector3(world_x, 0, world_z))

	print("[Grid] Done: ", props_on_grid.size(), " props, ", npcs_on_grid.size(), " NPCs")


func _try_load_model(model_name: String, pos: Vector3) -> bool:
	## All paths, mappings, and extensions from asset_config.json — zero hardcoded.
	var prop_map: Dictionary = asset_config.get("prop_model_map", {})
	var char_map: Dictionary = asset_config.get("character_model_map", {})
	var resolved: String = model_name
	if prop_map.has(model_name):
		resolved = str(prop_map[model_name])
	elif char_map.has(model_name):
		resolved = str(char_map[model_name])

	var search_paths: Array = asset_config.get("model_search_paths", ["res://models/"])
	var extensions: Array = asset_config.get("model_extensions", ["glb", "gltf"])

	# Get scale and Y offset from config
	var scale_map: Dictionary = asset_config.get("prop_scale_map", {})
	var y_offset_map: Dictionary = asset_config.get("prop_y_offset_map", {})
	var model_scale: float = scale_map.get(resolved, scale_map.get(model_name, scale_map.get("default", 1.0)))
	var y_offset: float = y_offset_map.get(resolved, y_offset_map.get(model_name, y_offset_map.get("default", 0.0)))

	for base_path in search_paths:
		for ext in extensions:
			var path: String = str(base_path) + resolved + "." + str(ext)
			if ResourceLoader.exists(path):
				var scene: PackedScene = load(path)
				if scene:
					var body := StaticBody3D.new()
					body.name = "Model_" + resolved
					body.position = Vector3(pos.x, pos.y + y_offset, pos.z)
					var instance := scene.instantiate()
					instance.scale = Vector3(model_scale, model_scale, model_scale)
					# Random Y rotation for variety (unless disabled in config)
					var no_rotate: Array = asset_config.get("no_random_rotation", [])
					var allow_rotate: bool = "_all" not in no_rotate and model_name not in no_rotate and resolved not in no_rotate
					if allow_rotate:
						instance.rotation_degrees.y = randf() * 360.0
					body.add_child(instance)
					_add_mesh_collision(body, instance)
					add_child(body)
					return true
	return false


func _add_mesh_collision(body: StaticBody3D, model: Node) -> void:
	## Add collision shape based on the model's bounding box.
	## Scans all MeshInstance3D children to find the AABB.
	var aabb := AABB()
	var found := false
	for child in model.get_children():
		if child is MeshInstance3D:
			var mesh_aabb: AABB = child.get_aabb()
			if not found:
				aabb = mesh_aabb
				found = true
			else:
				aabb = aabb.merge(mesh_aabb)
		for sub in child.get_children():
			if sub is MeshInstance3D:
				var sub_aabb: AABB = sub.get_aabb()
				if not found:
					aabb = sub_aabb
					found = true
				else:
					aabb = aabb.merge(sub_aabb)

	if found and aabb.size.length() > 0.01:
		var col := CollisionShape3D.new()
		col.name = "AutoCollision"
		var shape := BoxShape3D.new()
		shape.size = aabb.size
		col.shape = shape
		col.position = aabb.get_center()
		body.add_child(col)


func _prop_size(prop_type: String) -> Vector3:
	## Read from asset_config.json — zero hardcoded sizes.
	var sizes: Dictionary = asset_config.get("prop_sizes", {})
	var s = sizes.get(prop_type, sizes.get("default", [0.5, 0.5, 0.5]))
	if s is Array and s.size() >= 3:
		return Vector3(s[0], s[1], s[2])
	return Vector3(0.5, 0.5, 0.5)


func _load_animations(player: CharacterBody3D, model_node: Node3D) -> void:
	## Load animations from separate GLB files (KayKit pattern).
	## Animation GLB paths come from asset_config.json.
	var anim_files: Array = asset_config.get("animation_files", [
		"res://models/assets_library/animations/Rig_Medium_General.glb",
		"res://models/assets_library/animations/Rig_Medium_MovementBasic.glb"
	])

	# Find or create AnimationPlayer on the model
	var anim_player: AnimationPlayer = null
	for child in model_node.get_children():
		if child is AnimationPlayer:
			anim_player = child
			break

	if anim_player == null:
		anim_player = AnimationPlayer.new()
		anim_player.name = "AnimationPlayer"
		model_node.add_child(anim_player)

	# Load animations from each file
	for anim_path in anim_files:
		if not ResourceLoader.exists(str(anim_path)):
			continue
		var anim_scene: PackedScene = load(str(anim_path))
		if not anim_scene:
			continue
		var anim_instance := anim_scene.instantiate()
		# Find AnimationPlayer in the animation GLB
		for child in anim_instance.get_children():
			_copy_animations_recursive(child, anim_player)
		anim_instance.queue_free()

	# Play idle by default
	if anim_player.has_animation("Idle_A"):
		anim_player.play("Idle_A")

	# Store reference for player controller to use
	player.set_meta("anim_player", anim_player)


func _copy_animations_recursive(node: Node, target_player: AnimationPlayer) -> void:
	if node is AnimationPlayer:
		var source_player: AnimationPlayer = node
		for anim_name in source_player.get_animation_list():
			if anim_name == "T-Pose":
				continue
			var anim: Animation = source_player.get_animation(anim_name)
			if anim:
				var lib: AnimationLibrary = null
				if target_player.has_animation_library(""):
					lib = target_player.get_animation_library("")
				else:
					lib = AnimationLibrary.new()
					target_player.add_animation_library("", lib)
				if not lib.has_animation(anim_name):
					# Set looping based on config prefixes
					var loop_prefixes: Array = asset_config.get("animation_config", {}).get("loop_prefixes", [])
					for prefix in loop_prefixes:
						if anim_name.begins_with(str(prefix)):
							anim.loop_mode = Animation.LOOP_LINEAR
							break
					lib.add_animation(anim_name, anim)
	for child in node.get_children():
		_copy_animations_recursive(child, target_player)


func _add_box(node_name: String, size: Vector3, pos: Vector3, color: Color, is_static: bool) -> void:
	var body := StaticBody3D.new() if is_static else Node3D.new()
	body.name = node_name
	body.position = pos

	var mesh_inst := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh_inst.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh_inst.material_override = mat
	body.add_child(mesh_inst)

	if is_static:
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		col.shape = shape
		body.add_child(col)

	add_child(body)


func _add_capsule(node_name: String, radius: float, height: float, pos: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = pos

	var mesh_inst := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh_inst.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh_inst.material_override = mat
	mesh_inst.position.y = height / 2
	body.add_child(mesh_inst)

	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = radius
	shape.height = height
	col.shape = shape
	col.position.y = height / 2
	body.add_child(col)

	add_child(body)


func _spawn_player() -> void:
	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(load("res://scripts/player_3d.gd"))

	# Read player color from characters.json
	var player_color := Color(0.2, 0.7, 0.9)
	var char_file := FileAccess.open("res://data/characters.json", FileAccess.READ)
	if char_file:
		var chars = JSON.parse_string(char_file.get_as_text())
		if chars is Array and chars.size() > 0:
			var c = chars[0].get("color")
			if c is Array and c.size() >= 3:
				player_color = Color(c[0], c[1], c[2])

	# Spawn position from layout
	var layout: Dictionary = current_location.get("layout", {})
	var entrance: Dictionary = layout.get("entrance", {})
	var sf: float = _w("pixels_to_units", 50.0)
	var width: float = layout.get("width", 900) / sf
	var height: float = layout.get("height", 600) / sf
	var spawn_x: float = entrance.get("x", 450) / sf - width / 2
	var spawn_z: float = entrance.get("y", 300) / sf - height / 2
	player.position = Vector3(spawn_x, _p("spawn_height", 1.0), spawn_z)

	# Try loading a GLB model for the player
	var player_model: String = str(asset_config.get("character_model_map", {}).get("default", "character-human"))
	# Read from meta.json if player has a model override
	var meta_file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if meta_file:
		var meta = JSON.parse_string(meta_file.get_as_text())
		if meta is Dictionary:
			var pm = meta.get("player", {})
			if pm is Dictionary and pm.has("model"):
				player_model = str(pm.get("model"))

	var model_loaded := false
	var search_paths: Array = asset_config.get("model_search_paths", ["res://models/"])
	var extensions: Array = asset_config.get("model_extensions", ["glb", "gltf"])
	for base_path in search_paths:
		for ext in extensions:
			var path: String = str(base_path) + player_model + "." + str(ext)
			if ResourceLoader.exists(path):
				var scene: PackedScene = load(path)
				if scene:
					var instance := scene.instantiate()
					instance.name = "PlayerModel"
					# Apply scale from asset_config
					var scale_map: Dictionary = asset_config.get("prop_scale_map", {})
					var pscale: float = scale_map.get(player_model, scale_map.get("default", 1.0))
					instance.scale = Vector3(pscale, pscale, pscale)
					# Apply rotation offset from meta.json
					instance.rotation_degrees.y = _p("model_rotation_offset", 0.0)
					player.add_child(instance)
					model_loaded = true
					# Load animations from separate GLBs
					_load_animations(player, instance)
					break
		if model_loaded:
			break

	# Fallback: capsule if no model found
	if not model_loaded:
		var mesh_inst := MeshInstance3D.new()
		mesh_inst.name = "PlayerMesh"
		var mesh := CapsuleMesh.new()
		mesh.radius = _p("capsule_radius", 0.3)
		mesh.height = _p("capsule_height", 1.2)
		mesh_inst.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = player_color
		mesh_inst.material_override = mat
		mesh_inst.position.y = _p("capsule_height", 1.2) / 2.0
		player.add_child(mesh_inst)

	# Collision
	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = _p("capsule_radius", 0.3)
	shape.height = _p("capsule_height", 1.2)
	col.shape = shape
	col.position.y = _p("capsule_height", 1.2) / 2.0
	player.add_child(col)

	# Camera
	var spring_arm := SpringArm3D.new()
	spring_arm.name = "CameraArm"
	spring_arm.position = Vector3(0, _p("camera_height", 1.2), 0)
	spring_arm.rotation_degrees = Vector3(_p("camera_angle", -20), 0, 0)
	spring_arm.spring_length = _p("camera_distance", 5.0)
	player.add_child(spring_arm)

	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.current = true
	spring_arm.add_child(camera)

	add_child(player)
