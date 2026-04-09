extends CharacterBody3D

## 3D Player Controller — reads config from meta.json, not hardcoded.

var speed: float = 5.0
var jump_force: float = 6.0
var gravity: float = 20.0
var mouse_sensitivity: float = 0.003

var camera_arm: SpringArm3D
var anim_player: AnimationPlayer
var current_anim: String = ""
var anim_state_map: Dictionary = {}
var anim_blend_time: float = 0.2
var rotate_to_movement: bool = true
var rotation_speed: float = 10.0

func _ready() -> void:
	camera_arm = get_node_or_null("CameraArm")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Load animation config from asset_config.json
	var acfg_file := FileAccess.open("res://data/asset_config.json", FileAccess.READ)
	if acfg_file:
		var acfg = JSON.parse_string(acfg_file.get_as_text())
		if acfg is Dictionary:
			var anim_cfg: Dictionary = acfg.get("animation_config", {})
			if anim_cfg is Dictionary:
				anim_state_map = anim_cfg.get("state_map", {})
				anim_blend_time = anim_cfg.get("blend_time", 0.2)

	# Load rotation config from meta.json
	var meta_f := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if meta_f:
		var meta = JSON.parse_string(meta_f.get_as_text())
		if meta is Dictionary:
			var pcfg = meta.get("player", {})
			if pcfg is Dictionary:
				rotate_to_movement = pcfg.get("rotate_to_movement", true)
				rotation_speed = pcfg.get("rotation_speed", 10.0)

	# Get animation player (set by world_builder)
	await get_tree().process_frame
	if has_meta("anim_player"):
		anim_player = get_meta("anim_player")

	# Load config from meta.json
	var file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		if data is Dictionary:
			var player: Dictionary = data.get("player", {})
			if player is Dictionary:
				speed = player.get("move_speed", speed)
				jump_force = player.get("jump_force", jump_force)
				gravity = player.get("gravity", gravity)
				mouse_sensitivity = player.get("mouse_sensitivity", mouse_sensitivity)
				var cam_distance = player.get("camera_distance", 5.0)
				var cam_angle = player.get("camera_angle", -20.0)
				if camera_arm:
					camera_arm.spring_length = cam_distance
					camera_arm.rotation_degrees.x = cam_angle


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if camera_arm:
			rotate_y(-event.relative.x * mouse_sensitivity)
			camera_arm.rotation.x -= event.relative.y * mouse_sensitivity
			camera_arm.rotation.x = clamp(camera_arm.rotation.x, deg_to_rad(-60), deg_to_rad(30))

	if event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta

	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_force

	var input := Vector2.ZERO
	if Input.is_action_pressed("move_forward"):
		input.y -= 1
	if Input.is_action_pressed("move_back"):
		input.y += 1
	if Input.is_action_pressed("move_left"):
		input.x -= 1
	if Input.is_action_pressed("move_right"):
		input.x += 1
	input = input.normalized()

	var direction := Vector3.ZERO
	direction += transform.basis.z * input.y
	direction += transform.basis.x * input.x
	direction.y = 0
	direction = direction.normalized()

	if direction.length() > 0:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
		# Rotate MODEL to face movement direction (not the player body — camera is attached to body)
		if rotate_to_movement:
			var target_angle: float = atan2(direction.x, direction.z)
			var model = get_node_or_null("PlayerModel")
			if model:
				model.rotation.y = lerp_angle(model.rotation.y, target_angle, rotation_speed * delta)
	else:
		velocity.x = move_toward(velocity.x, 0, speed * delta * 10)
		velocity.z = move_toward(velocity.z, 0, speed * delta * 10)

	move_and_slide()

	# Play animations based on state — all names from asset_config.json
	if anim_player:
		var is_moving: bool = direction.length() > 0
		var is_jumping: bool = not is_on_floor()
		var state: String = "idle"
		if is_jumping:
			state = "jump"
		elif is_moving:
			state = "walk"
		var target_anim: String = str(anim_state_map.get(state, "Idle_A"))
		if target_anim != current_anim and anim_player.has_animation(target_anim):
			anim_player.play(target_anim, anim_blend_time)
			current_anim = target_anim
