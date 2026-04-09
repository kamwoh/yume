extends Node3D

## Auto Capture — runs automatically, moves camera to defined positions,
## captures screenshots at each. No human needed.
##
## Usage: set as main scene script, or load via --script
## Reads camera_positions from data/capture_config.json

var capture_dir: String = "user://captures/"
var positions: Array = []
var current_pos: int = 0
var frames_waited: int = 0
var done: bool = false

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(capture_dir)

	# Load capture positions from config
	var file := FileAccess.open("res://data/capture_config.json", FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		if data is Dictionary:
			positions = data.get("camera_positions", [])
			capture_dir = data.get("output_dir", capture_dir)

	if positions.is_empty():
		# Default: capture from 4 corners + center + top-down
		positions = _generate_default_positions()

	# Build the world first
	_build_world()

	print("[AutoCapture] ", positions.size(), " positions to capture")


func _generate_default_positions() -> Array:
	# Read room size from location JSON
	var room_w: float = 8.0
	var room_h: float = 8.0

	var prog_file := FileAccess.open("res://data/progression.json", FileAccess.READ)
	if prog_file:
		var prog = JSON.parse_string(prog_file.get_as_text())
		if prog is Dictionary:
			var loc_id: String = str(prog.get("starting_location", "test_room"))
			var loc_file := FileAccess.open("res://data/locations/" + loc_id + ".json", FileAccess.READ)
			if loc_file:
				var loc = JSON.parse_string(loc_file.get_as_text())
				if loc is Dictionary:
					var layout: Dictionary = loc.get("layout", {})
					room_w = layout.get("width", 800) / 50.0
					room_h = layout.get("height", 800) / 50.0

	var hw: float = room_w / 2 - 1
	var hh: float = room_h / 2 - 1

	return [
		# Overview from above
		{"pos": [0, 8, 0], "look_at": [0, 0, 0], "name": "top_down"},
		# 4 corners looking inward
		{"pos": [-hw, 2, -hh], "look_at": [0, 0, 0], "name": "corner_nw"},
		{"pos": [hw, 2, -hh], "look_at": [0, 0, 0], "name": "corner_ne"},
		{"pos": [-hw, 2, hh], "look_at": [0, 0, 0], "name": "corner_sw"},
		{"pos": [hw, 2, hh], "look_at": [0, 0, 0], "name": "corner_se"},
		# Eye level walkthrough
		{"pos": [0, 1, hh - 1], "look_at": [0, 0.5, -hh], "name": "eye_south"},
		{"pos": [0, 1, -hh + 1], "look_at": [0, 0.5, hh], "name": "eye_north"},
		{"pos": [-hw + 1, 1, 0], "look_at": [hw, 0.5, 0], "name": "eye_west"},
		{"pos": [hw - 1, 1, 0], "look_at": [-hw, 0.5, 0], "name": "eye_east"},
		# Close-up center
		{"pos": [0, 1.5, 2], "look_at": [0, 0.3, 0], "name": "center_close"},
	]


func _build_world() -> void:
	# Load and build the world (reuse world_builder logic)
	var wb_script = load("res://scripts/world_builder.gd")
	if wb_script:
		var wb := Node3D.new()
		wb.name = "World"
		wb.set_script(wb_script)
		add_child(wb)


func _process(_delta: float) -> void:
	if done:
		return

	# Wait a few frames for world to build and render
	frames_waited += 1
	if frames_waited < 5:
		return

	if current_pos >= positions.size():
		print("[AutoCapture] Done! ", current_pos, " screenshots saved to ", capture_dir)
		done = true
		# Quit after a brief delay
		await get_tree().create_timer(0.5).timeout
		get_tree().quit()
		return

	# Only capture every 3 frames (give renderer time)
	if (frames_waited - 5) % 3 != 0:
		return

	var cam_data: Dictionary = positions[current_pos]
	_capture_at(cam_data)
	current_pos += 1


func _capture_at(cam_data: Dictionary) -> void:
	# Create or reuse camera
	var cam: Camera3D = get_node_or_null("AutoCam") as Camera3D
	if not cam:
		cam = Camera3D.new()
		cam.name = "AutoCam"
		cam.current = true
		add_child(cam)

	# Position camera
	var pos_arr = cam_data.get("pos", [0, 5, 0])
	var look_arr = cam_data.get("look_at", [0, 0, 0])
	var cam_name: String = str(cam_data.get("name", "frame_%d" % current_pos))

	if pos_arr is Array and pos_arr.size() >= 3:
		cam.position = Vector3(pos_arr[0], pos_arr[1], pos_arr[2])
	if look_arr is Array and look_arr.size() >= 3:
		cam.look_at(Vector3(look_arr[0], look_arr[1], look_arr[2]))

	# Wait one frame for render
	await get_tree().process_frame
	await get_tree().process_frame

	# Capture
	var viewport := get_viewport()
	if viewport:
		var img := viewport.get_texture().get_image()
		if img:
			var path: String = capture_dir + cam_name + ".png"
			img.save_png(path)
			print("[AutoCapture] Saved: ", cam_name, ".png")
