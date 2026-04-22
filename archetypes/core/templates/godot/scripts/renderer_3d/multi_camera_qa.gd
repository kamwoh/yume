extends Node3D

## Multi-Camera QA — purposeful cameras, each checks something specific.
## look_offset = direction RELATIVE to camera position (not world point).
## Every camera must show world content. Never just sky.

var cameras: Array = []
var camera_names: Array = []
var current_cam: int = 0
var switch_timer: float = 0.0
var switch_interval: float = 1.5
var world_w: float = 100.0
var world_h: float = 100.0


func _ready() -> void:
	# Resolve data_root from meta.json (same pattern as sim_world.gd).
	var data_root: String = "res://data/sim/"
	var meta_file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if meta_file:
		var meta = JSON.parse_string(meta_file.get_as_text())
		if meta is Dictionary:
			var dr: String = str(meta.get("data_root", data_root))
			if not dr.ends_with("/"):
				dr += "/"
			data_root = dr

	# Load world_config.json from data_root — optional; defaults kick in if missing.
	var json_cameras: Array = []
	var wc_file := FileAccess.open(data_root + "world_config.json", FileAccess.READ)
	if wc_file:
		var data = JSON.parse_string(wc_file.get_as_text())
		if data is Dictionary:
			var ws: Dictionary = data.get("world_size", {})
			world_w = ws.get("width", 100.0)
			world_h = ws.get("height", 100.0)
			switch_interval = float(data.get("camera_switch_interval", switch_interval))
			json_cameras = data.get("cameras", [])

	if json_cameras.size() > 0:
		_create_cameras_from_json(json_cameras)
		print("[MultiCam] ", cameras.size(), " cameras from JSON (data_root=", data_root, ")")
	else:
		_create_cameras()

	# Wait for player camera to finish setup, then override it
	await get_tree().create_timer(0.5).timeout
	var player = get_tree().get_first_node_in_group("player")
	if player:
		var player_cam = player.get_node_or_null("CameraArm/Camera")
		if player_cam:
			player_cam.current = false
			print("[MultiCam] Disabled player camera")

	if cameras.size() > 0:
		cameras[0].current = true
		print("[MultiCam] ", cameras.size(), " purpose cameras active. Switching every ", switch_interval, "s")


func _create_cameras_from_json(json_cameras: Array) -> void:
	"""Build cameras from world_config.json cameras[] array.
	Schema per entry: {name, pos:[x,y,z], look_at:[x,y,z], fov?}."""
	for c in json_cameras:
		if not (c is Dictionary):
			continue
		var cam := Camera3D.new()
		var cn: String = str(c.get("name", "cam"))
		cam.name = "QACam_" + cn
		var pos_arr = c.get("pos", [0, 2, 5])
		var look_arr = c.get("look_at", [0, 1, 0])
		var cam_pos := Vector3(float(pos_arr[0]), float(pos_arr[1]), float(pos_arr[2]))
		var look_pt := Vector3(float(look_arr[0]), float(look_arr[1]), float(look_arr[2]))
		cam.position = cam_pos
		cam.current = false
		if c.has("fov"):
			cam.fov = float(c["fov"])
		add_child(cam)
		cam.look_at(cam.global_position + (look_pt - cam_pos))
		cameras.append(cam)
		camera_names.append(cn)


func _create_cameras() -> void:
	var hw: float = world_w / 2.0 - 2
	var hh: float = world_h / 2.0 - 2

	# Each camera: PURPOSE + look_offset (RELATIVE direction from camera pos)
	# look_offset.y negative = look down. All different directions.
	var positions: Array = [
		# PURPOSE: overall layout — look straight down
		{"pos": Vector3(0, 20, 0), "look_offset": Vector3(0.01, -20, 0.01), "name": "map_overview"},

		# PURPOSE: camp area — angled down at center
		{"pos": Vector3(5, 8, 5), "look_offset": Vector3(-5, -7, -5), "name": "camp_above"},

		# PURPOSE: terrain slopes — isometric, looking toward center-ish
		{"pos": Vector3(hw * 0.3, 6, hh * 0.3), "look_offset": Vector3(-5, -5, -5), "name": "terrain_se"},
		{"pos": Vector3(-hw * 0.3, 6, -hh * 0.3), "look_offset": Vector3(5, -5, 5), "name": "terrain_nw"},

		# PURPOSE: forest walk — FORWARD in different directions
		{"pos": Vector3(0, 2, 10), "look_offset": Vector3(0, -0.5, -10), "name": "walk_south"},
		{"pos": Vector3(10, 2, 0), "look_offset": Vector3(-10, -0.5, 0), "name": "walk_west"},
		{"pos": Vector3(-10, 2, -10), "look_offset": Vector3(10, -0.5, 10), "name": "walk_se"},
		{"pos": Vector3(0, 2, -10), "look_offset": Vector3(0, -0.5, 10), "name": "walk_north"},

		# PURPOSE: close-up — look at nearby ground in DIFFERENT directions
		{"pos": Vector3(3, 1.5, 3), "look_offset": Vector3(2, -1, 2), "name": "closeup_se"},
		{"pos": Vector3(-8, 1.5, 5), "look_offset": Vector3(-3, -1, -2), "name": "closeup_sw"},
		{"pos": Vector3(12, 1.5, -8), "look_offset": Vector3(-2, -1, 3), "name": "closeup_ne"},

		# PURPOSE: edge check — look OUTWARD toward boundary
		{"pos": Vector3(0, 3, hh * 0.5), "look_offset": Vector3(0, -1, 10), "name": "edge_south"},
		{"pos": Vector3(hw * 0.5, 3, 0), "look_offset": Vector3(10, -1, 0), "name": "edge_east"},

		# PURPOSE: player perspective — eye level, different facing
		{"pos": Vector3(0, 1.2, 5), "look_offset": Vector3(3, -0.3, -5), "name": "player_sw"},
		{"pos": Vector3(5, 1.2, 0), "look_offset": Vector3(-5, -0.3, 3), "name": "player_nw"},
	]

	# Find terrain for height queries
	var terrain_node: Node = null
	for child in get_parent().get_children():
		if child.name == "Terrain" and child.has_method("get_height_at"):
			terrain_node = child
			break

	for p in positions:
		var cam := Camera3D.new()
		var cam_name: String = str(p.get("name", ""))
		cam.name = "QACam_" + cam_name
		var cam_pos: Vector3 = p.get("pos", Vector3.ZERO)

		# Ensure camera is ABOVE terrain at its position
		if terrain_node:
			var terrain_h: float = terrain_node.get_height_at(cam_pos.x, cam_pos.z)
			if cam_pos.y < terrain_h + 1.0:
				cam_pos.y = terrain_h + cam_pos.y  # Add requested height ON TOP of terrain

		cam.position = cam_pos
		cam.current = false
		add_child(cam)
		var look_off: Vector3 = p.get("look_offset", Vector3(0, -1, 0))
		cam.look_at(cam.global_position + look_off)
		cameras.append(cam)
		camera_names.append(cam_name)


func _process(delta: float) -> void:
	if cameras.is_empty():
		return

	switch_timer += delta
	if switch_timer >= switch_interval:
		switch_timer = 0.0
		cameras[current_cam].current = false
		current_cam = (current_cam + 1) % cameras.size()
		cameras[current_cam].current = true
		var cam: Camera3D = cameras[current_cam]
		var cn: String = camera_names[current_cam] if current_cam < camera_names.size() else "?"
		print("[QACam] #", current_cam, " '", cn, "' pos=(",
			snapped(cam.global_position.x, 0.1), ",",
			snapped(cam.global_position.y, 0.1), ",",
			snapped(cam.global_position.z, 0.1), ") dir=(",
			snapped(-cam.global_transform.basis.z.x, 0.1), ",",
			snapped(-cam.global_transform.basis.z.y, 0.1), ",",
			snapped(-cam.global_transform.basis.z.z, 0.1), ")")
