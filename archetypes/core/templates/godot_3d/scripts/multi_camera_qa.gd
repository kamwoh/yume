extends Node3D

## Multi-Camera QA — places cameras around the world, cycles through them.
## Each frame captures a different viewpoint for visual QA and training data.
## Attach to sim_world or world_builder scene.

var cameras: Array = []
var current_cam: int = 0
var switch_timer: float = 0.0
var switch_interval: float = 1.5  # seconds per camera
var world_w: float = 40.0
var world_h: float = 40.0


func _ready() -> void:
	# Read world size
	var wc_file := FileAccess.open("res://data/sim/world_config.json", FileAccess.READ)
	if wc_file:
		var data = JSON.parse_string(wc_file.get_as_text())
		if data is Dictionary:
			var ws: Dictionary = data.get("world_size", {})
			world_w = ws.get("width", 40.0)
			world_h = ws.get("height", 40.0)

	# Disable player camera
	var player = get_tree().get_first_node_in_group("player")
	if player:
		var player_cam = player.get_node_or_null("CameraArm/Camera")
		if player_cam:
			player_cam.current = false

	_create_cameras()

	if cameras.size() > 0:
		cameras[0].current = true
		print("[MultiCam] ", cameras.size(), " cameras placed. Switching every ", switch_interval, "s")


func _create_cameras() -> void:
	var hw: float = world_w / 2.0 - 2
	var hh: float = world_h / 2.0 - 2

	var positions: Array = [
		# Overview — always look DOWN at ground, not at horizon
		{"pos": Vector3(0, 15, 1), "look": Vector3(0, 0, 0), "name": "top_down"},
		{"pos": Vector3(2, 5, hw * 0.3), "look": Vector3(0, 0, -5), "name": "south_overview"},
		{"pos": Vector3(hw * 0.4, 5, 2), "look": Vector3(-5, 0, -2), "name": "east_overview"},
		{"pos": Vector3(-hw * 0.3, 5, -hh * 0.3), "look": Vector3(5, 0, 5), "name": "nw_overview"},

		# Corner views — elevated, looking toward center
		{"pos": Vector3(-hw * 0.7, 6, -hh * 0.7), "look": Vector3(0, 0, 0), "name": "corner_nw"},
		{"pos": Vector3(hw * 0.7, 6, -hh * 0.7), "look": Vector3(0, 0, 0), "name": "corner_ne"},
		{"pos": Vector3(-hw * 0.7, 6, hh * 0.7), "look": Vector3(0, 0, 0), "name": "corner_sw"},
		{"pos": Vector3(hw * 0.7, 6, hh * 0.7), "look": Vector3(0, 0, 0), "name": "corner_se"},

		# Eye-level — inside the world, looking ACROSS ground
		{"pos": Vector3(0, 2, hh * 0.5), "look": Vector3(0, 0.5, -hh * 0.3), "name": "eye_south"},
		{"pos": Vector3(0, 2, -hh * 0.5), "look": Vector3(0, 0.5, hh * 0.3), "name": "eye_north"},
		{"pos": Vector3(-hw * 0.5, 2, 0), "look": Vector3(hw * 0.3, 0.5, 0), "name": "eye_west"},
		{"pos": Vector3(hw * 0.5, 2, 0), "look": Vector3(-hw * 0.3, 0.5, 0), "name": "eye_east"},

		# Close-ups — near ground, looking at elements
		{"pos": Vector3(3, 2, 3), "look": Vector3(0, 0.3, 0), "name": "close_center"},
		{"pos": Vector3(-5, 1.5, -3), "look": Vector3(-2, 0.3, 0), "name": "close_offset"},
		{"pos": Vector3(8, 1.5, -5), "look": Vector3(5, 0.3, -2), "name": "close_east"},

		# Cinematic — low angle looking along ground
		{"pos": Vector3(0, 1.0, hh * 0.4), "look": Vector3(0, 0.5, -hh * 0.2), "name": "dramatic_low"},
	]

	for p in positions:
		var cam := Camera3D.new()
		var cam_name: String = str(p.get("name", ""))
		cam.name = "QACam_" + cam_name
		cam.position = p.get("pos", Vector3.ZERO)
		cam.look_at(p.get("look", Vector3.ZERO))
		cam.current = false
		add_child(cam)
		cameras.append(cam)
		camera_names.append(cam_name)


var camera_names: Array = []


func _process(delta: float) -> void:
	if cameras.is_empty():
		return

	switch_timer += delta
	if switch_timer >= switch_interval:
		switch_timer = 0.0
		cameras[current_cam].current = false
		current_cam = (current_cam + 1) % cameras.size()
		cameras[current_cam].current = true
		# Log camera info for QA analysis
		var cam: Camera3D = cameras[current_cam]
		var cam_name: String = camera_names[current_cam] if current_cam < camera_names.size() else "unknown"
		print("[QACam] #", current_cam, " '", cam_name, "' pos=(",
			snapped(cam.global_position.x, 0.1), ",",
			snapped(cam.global_position.y, 0.1), ",",
			snapped(cam.global_position.z, 0.1), ") looking_at=(",
			snapped(-cam.global_transform.basis.z.x, 0.1), ",",
			snapped(-cam.global_transform.basis.z.y, 0.1), ",",
			snapped(-cam.global_transform.basis.z.z, 0.1), ")")
