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
		# Overview shots
		{"pos": Vector3(0, 20, 0), "look": Vector3(0, 0, 0), "name": "top_down"},
		{"pos": Vector3(0, 15, 15), "look": Vector3(0, 0, 0), "name": "south_overview"},
		{"pos": Vector3(15, 15, 0), "look": Vector3(0, 0, 0), "name": "east_overview"},
		{"pos": Vector3(-15, 15, -15), "look": Vector3(0, 0, 0), "name": "nw_overview"},

		# Corner views — see diagonal across world
		{"pos": Vector3(-hw, 8, -hh), "look": Vector3(hw, 0, hh), "name": "corner_nw"},
		{"pos": Vector3(hw, 8, -hh), "look": Vector3(-hw, 0, hh), "name": "corner_ne"},
		{"pos": Vector3(-hw, 8, hh), "look": Vector3(hw, 0, -hh), "name": "corner_sw"},
		{"pos": Vector3(hw, 8, hh), "look": Vector3(-hw, 0, -hh), "name": "corner_se"},

		# Eye-level views — like walking through
		{"pos": Vector3(0, 2, hh), "look": Vector3(0, 1, -hh), "name": "eye_south"},
		{"pos": Vector3(0, 2, -hh), "look": Vector3(0, 1, hh), "name": "eye_north"},
		{"pos": Vector3(-hw, 2, 0), "look": Vector3(hw, 1, 0), "name": "eye_west"},
		{"pos": Vector3(hw, 2, 0), "look": Vector3(-hw, 1, 0), "name": "eye_east"},

		# Close-up center
		{"pos": Vector3(3, 3, 3), "look": Vector3(0, 0.5, 0), "name": "close_center"},
		{"pos": Vector3(-5, 2, -3), "look": Vector3(0, 0.5, 0), "name": "close_offset"},

		# Cinematic — low angle dramatic
		{"pos": Vector3(0, 1.5, hw), "look": Vector3(0, 2, -hh), "name": "dramatic_low"},
		{"pos": Vector3(hw, 1.5, 0), "look": Vector3(-hw, 2, 0), "name": "dramatic_side"},
	]

	for p in positions:
		var cam := Camera3D.new()
		cam.name = "QACam_" + str(p.get("name", ""))
		cam.position = p.get("pos", Vector3.ZERO)
		cam.look_at(p.get("look", Vector3.ZERO))
		cam.current = false
		add_child(cam)
		cameras.append(cam)


func _process(delta: float) -> void:
	if cameras.is_empty():
		return

	switch_timer += delta
	if switch_timer >= switch_interval:
		switch_timer = 0.0
		# Deactivate current
		cameras[current_cam].current = false
		# Next camera
		current_cam = (current_cam + 1) % cameras.size()
		cameras[current_cam].current = true
