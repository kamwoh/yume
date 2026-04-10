extends Node3D

## Camera Controller — the agent's "eyes".
## Swappable brain: follow, free, cinematic, orbital, random_smooth.
## Config via meta.json camera section.
## Records camera pose every frame for training data export.

var camera: Camera3D
var brain_type: String = "follow"
var player: CharacterBody3D = null

# Follow brain config
var follow_distance: float = 3.5
var follow_height: float = 1.5
var follow_angle: float = -25.0
var follow_smoothing: float = 5.0

# Free brain config
var free_speed: float = 5.0
var free_sensitivity: float = 0.003

# Orbital config
var orbital_radius: float = 5.0
var orbital_speed: float = 0.5
var orbital_height: float = 3.0
var orbital_center: Vector3 = Vector3.ZERO

# Random smooth config
var smooth_speed: float = 2.0
var smooth_target: Vector3 = Vector3.ZERO
var smooth_look_target: Vector3 = Vector3.ZERO
var smooth_timer: float = 0.0
var smooth_interval: float = 3.0

# Room bounds for random targets
var room_half_w: float = 6.0
var room_half_h: float = 5.0

# Recording
var pose_log: Array = []
var frame: int = 0

# Internal
var yaw: float = 0.0
var pitch: float = -0.4


func _ready() -> void:
	# Load config
	var meta_file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if meta_file:
		var meta = JSON.parse_string(meta_file.get_as_text())
		if meta is Dictionary:
			var cam_cfg: Dictionary = meta.get("camera", {})
			if not cam_cfg is Dictionary:
				cam_cfg = {}
			brain_type = str(cam_cfg.get("brain", meta.get("player", {}).get("camera_brain", "follow")))
			follow_distance = cam_cfg.get("distance", meta.get("player", {}).get("camera_distance", 3.5))
			follow_height = cam_cfg.get("height", meta.get("player", {}).get("camera_height", 1.5))
			follow_angle = deg_to_rad(cam_cfg.get("angle", meta.get("player", {}).get("camera_angle", -25.0)))
			follow_smoothing = cam_cfg.get("smoothing", 5.0)
			free_speed = cam_cfg.get("free_speed", 5.0)
			free_sensitivity = cam_cfg.get("sensitivity", meta.get("player", {}).get("mouse_sensitivity", 0.003))
			orbital_radius = cam_cfg.get("orbital_radius", 5.0)
			orbital_speed = cam_cfg.get("orbital_speed", 0.5)
			orbital_height = cam_cfg.get("orbital_height", 3.0)
			smooth_speed = cam_cfg.get("smooth_speed", 2.0)
			smooth_interval = cam_cfg.get("smooth_interval", 3.0)

	_load_room_bounds()
	pitch = follow_angle

	# Find or create camera
	await get_tree().process_frame
	player = get_tree().get_first_node_in_group("player")

	# If brain is not "follow", we need a standalone camera (not attached to player)
	if brain_type != "follow":
		_setup_standalone_camera()
	else:
		# Follow mode uses the player's existing camera
		if player:
			camera = player.get_node_or_null("CameraArm/Camera")

	print("[Camera] Brain: ", brain_type)


func _setup_standalone_camera() -> void:
	# Disable the player's camera and create our own
	if player:
		var player_cam = player.get_node_or_null("CameraArm/Camera")
		if player_cam:
			player_cam.current = false

	camera = Camera3D.new()
	camera.name = "BrainCamera"
	camera.current = true
	add_child(camera)

	# Start position
	if player:
		global_position = player.global_position + Vector3(0, follow_height, follow_distance)
		camera.look_at(player.global_position + Vector3(0, 0.5, 0))

	if brain_type == "random_smooth":
		_pick_smooth_target()
	elif brain_type == "orbital":
		orbital_center = player.global_position if player else Vector3.ZERO


func _load_room_bounds() -> void:
	var prog_file := FileAccess.open("res://data/progression.json", FileAccess.READ)
	if not prog_file:
		return
	var prog = JSON.parse_string(prog_file.get_as_text())
	if not prog is Dictionary:
		return
	var loc_id: String = str(prog.get("starting_location", ""))
	var loc_file := FileAccess.open("res://data/locations/" + loc_id + ".json", FileAccess.READ)
	if not loc_file:
		return
	var loc = JSON.parse_string(loc_file.get_as_text())
	if not loc is Dictionary:
		return
	if loc.has("grid"):
		var grid: Dictionary = loc.get("grid", {})
		var grid_map: Array = grid.get("map", [])
		var tile_size: float = grid.get("tile_size", 1.0)
		if grid_map.size() > 0:
			room_half_w = str(grid_map[0]).length() * tile_size / 2.0 - 1.0
			room_half_h = grid_map.size() * tile_size / 2.0 - 1.0


func _input(event: InputEvent) -> void:
	if brain_type == "free" and event is InputEventMouseMotion:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			yaw -= event.relative.x * free_sensitivity
			pitch -= event.relative.y * free_sensitivity
			pitch = clamp(pitch, deg_to_rad(-80), deg_to_rad(80))


func _physics_process(delta: float) -> void:
	frame += 1

	match brain_type:
		"follow":
			_process_follow(delta)
		"free":
			_process_free(delta)
		"orbital":
			_process_orbital(delta)
		"random_smooth":
			_process_random_smooth(delta)
		"cinematic":
			_process_cinematic(delta)

	# Record pose every 3 frames
	if camera and frame % 3 == 0:
		pose_log.append({
			"frame": frame,
			"pos": [camera.global_position.x, camera.global_position.y, camera.global_position.z],
			"rot": [camera.global_rotation.x, camera.global_rotation.y, camera.global_rotation.z],
			"fov": camera.fov,
			"brain": brain_type,
		})


func _process_follow(_delta: float) -> void:
	# Follow brain uses the player's SpringArm — handled by player_3d.gd
	pass


func _process_free(delta: float) -> void:
	if not camera:
		return
	# WASD movement in camera's local space
	var input := Vector3.ZERO
	if Input.is_action_pressed("move_forward"):
		input.z -= 1
	if Input.is_action_pressed("move_back"):
		input.z += 1
	if Input.is_action_pressed("move_left"):
		input.x -= 1
	if Input.is_action_pressed("move_right"):
		input.x += 1
	if Input.is_action_pressed("jump"):
		input.y += 1

	input = input.normalized() * free_speed * delta
	global_position += camera.global_transform.basis * input
	camera.rotation = Vector3(pitch, yaw, 0)


func _process_orbital(delta: float) -> void:
	if not camera:
		return
	# Update center to follow player
	if player:
		orbital_center = orbital_center.lerp(player.global_position, 2.0 * delta)

	yaw += orbital_speed * delta
	var x: float = orbital_center.x + cos(yaw) * orbital_radius
	var z: float = orbital_center.z + sin(yaw) * orbital_radius
	var target_pos := Vector3(x, orbital_center.y + orbital_height, z)

	global_position = global_position.lerp(target_pos, 3.0 * delta)
	camera.look_at(orbital_center + Vector3(0, 0.5, 0))


func _process_random_smooth(delta: float) -> void:
	if not camera:
		return
	smooth_timer += delta

	# Pick new target periodically
	if smooth_timer > smooth_interval:
		_pick_smooth_target()

	# Smoothly move toward target
	global_position = global_position.lerp(smooth_target, smooth_speed * delta)

	# Smoothly look toward look target
	var current_dir: Vector3 = -camera.global_transform.basis.z
	var target_dir: Vector3 = (smooth_look_target - camera.global_position).normalized()
	if target_dir.length() > 0.01:
		camera.look_at(camera.global_position + current_dir.lerp(target_dir, 2.0 * delta))


func _pick_smooth_target() -> void:
	smooth_timer = 0.0
	# Random position in room at varying height
	smooth_target = Vector3(
		randf_range(-room_half_w, room_half_w),
		randf_range(1.5, 4.0),
		randf_range(-room_half_h, room_half_h)
	)
	# Look at player or random point
	if player and randf() > 0.3:
		smooth_look_target = player.global_position + Vector3(0, 0.5, 0)
	else:
		smooth_look_target = Vector3(
			randf_range(-room_half_w * 0.5, room_half_w * 0.5),
			0.5,
			randf_range(-room_half_h * 0.5, room_half_h * 0.5)
		)


func _process_cinematic(_delta: float) -> void:
	# TODO: read scripted camera path from JSON
	# For now, do a slow dolly along one axis
	if not camera:
		return
	var t: float = frame * 0.01
	global_position = Vector3(
		sin(t * 0.3) * room_half_w * 0.6,
		2.0 + sin(t * 0.5) * 0.5,
		cos(t * 0.2) * room_half_h * 0.6
	)
	if player:
		camera.look_at(player.global_position + Vector3(0, 0.5, 0))
	else:
		camera.look_at(Vector3.ZERO)


func save_log() -> void:
	var path: String = "user://captures/camera_log.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(pose_log))
		print("[Camera] Saved ", pose_log.size(), " pose records to ", path)
