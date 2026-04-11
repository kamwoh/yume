extends CharacterBody3D

## Player Controller — uses brain abstraction for input.
## Brain is swappable: human (keyboard), auto_agent (AI), llm (future).
## Set via meta.json player.brain field.

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

# Combat
var max_hp: float = 100.0
var current_hp: float = 100.0
var is_dead: bool = false

# Brain — swappable AI controller
var brain: Node = null
var brain_type: String = "human"


func _ready() -> void:
	camera_arm = get_node_or_null("CameraArm")
	add_to_group("player")

	# Load all config from meta.json (one read)
	var meta_file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	var player_config: Dictionary = {}
	if meta_file:
		var meta = JSON.parse_string(meta_file.get_as_text())
		if meta is Dictionary:
			player_config = meta.get("player", {})
			if not player_config is Dictionary:
				player_config = {}

	speed = player_config.get("move_speed", speed)
	jump_force = player_config.get("jump_force", jump_force)
	gravity = player_config.get("gravity", gravity)
	mouse_sensitivity = player_config.get("mouse_sensitivity", mouse_sensitivity)
	rotate_to_movement = player_config.get("rotate_to_movement", true)
	rotation_speed = player_config.get("rotation_speed", 10.0)
	max_hp = player_config.get("hp", 100.0)
	current_hp = max_hp
	brain_type = str(player_config.get("brain", "human"))

	# Camera
	if camera_arm:
		camera_arm.spring_length = player_config.get("camera_distance", 3.5)
		camera_arm.rotation_degrees.x = player_config.get("camera_angle", -25.0)

	# Mouse capture for human brain
	if brain_type == "human":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# Load animation config
	var acfg_file := FileAccess.open("res://data/asset_config.json", FileAccess.READ)
	if acfg_file:
		var acfg = JSON.parse_string(acfg_file.get_as_text())
		if acfg is Dictionary:
			var anim_cfg: Dictionary = acfg.get("animation_config", {})
			if anim_cfg is Dictionary:
				anim_state_map = anim_cfg.get("state_map", {})
				anim_blend_time = anim_cfg.get("blend_time", 0.2)

	# Get animation player (set by world_builder after model loads)
	await get_tree().process_frame
	if has_meta("anim_player"):
		anim_player = get_meta("anim_player")

	# Attach brain based on config
	_attach_brain(player_config)


func _attach_brain(config: Dictionary) -> void:
	var script_path: String = ""
	match brain_type:
		"human":
			script_path = "res://scripts/brain_human.gd"
		"auto_agent":
			script_path = "res://scripts/brain_auto_agent.gd"
		# "llm": script_path = "res://scripts/brain_llm.gd"  # future
		_:
			script_path = "res://scripts/brain_human.gd"

	var brain_script = load(script_path)
	if brain_script:
		var brain_node := Node.new()
		brain_node.name = "Brain"
		brain_node.set_script(brain_script)
		add_child(brain_node)
		brain = brain_node
		if brain.has_method("init_config"):
			brain.init_config(config)
		print("[Player] Brain attached: ", brain_type)


func _input(event: InputEvent) -> void:
	# Camera mouse look — only when human brain controls player
	if brain_type == "human":
		if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			if camera_arm:
				# Rotate camera arm around player (NOT the player body)
				camera_arm.rotate_y(-event.relative.x * mouse_sensitivity)
				camera_arm.rotation.x -= event.relative.y * mouse_sensitivity
				camera_arm.rotation.x = clamp(camera_arm.rotation.x, deg_to_rad(-60), deg_to_rad(30))

	if event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if is_dead:
		return

	# Gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Let brain decide
	if brain and brain.has_method("decide"):
		var world_state: Dictionary = _get_world_state()
		var decision: Dictionary = brain.decide(self, world_state)
		_execute_decision(decision, delta)

	move_and_slide()

	# Animate based on current velocity
	_update_animation()


func _get_world_state() -> Dictionary:
	var state: Dictionary = {
		"self_pos": global_position,
		"self_hp": current_hp,
		"self_max_hp": max_hp,
	}
	# Nearest enemy
	var nearest_dist: float = 999.0
	for e in get_tree().get_nodes_in_group("enemy"):
		if e.get("is_dead"):
			continue
		var d: float = global_position.distance_to(e.global_position)
		if d < nearest_dist:
			nearest_dist = d
			state["nearest_enemy_pos"] = e.global_position
	state["nearest_enemy_dist"] = nearest_dist
	return state


func _execute_decision(decision: Dictionary, delta: float) -> void:
	var action: String = str(decision.get("action", "idle"))

	match action:
		"move_to_direction":
			# HumanBrain: direction already in world space
			var dir = decision.get("direction", Vector3.ZERO)
			if dir is Vector3 and dir.length() > 0:
				velocity.x = dir.x * speed
				velocity.z = dir.z * speed
				_rotate_model(dir, delta)

		"move_to":
			# AutoAgentBrain: target position
			var target = decision.get("target", global_position)
			if target is Vector3:
				var dir: Vector3 = (target - global_position)
				dir.y = 0
				if dir.length() > 0.3:
					dir = dir.normalized()
					velocity.x = dir.x * speed
					velocity.z = dir.z * speed
					_rotate_model(dir, delta)
					# Rotate player BODY too so camera follows behind character
					if brain_type != "human":
						var body_angle: float = atan2(dir.x, dir.z)
						rotation.y = lerp_angle(rotation.y, body_angle, 3.0 * delta)
				else:
					velocity.x = move_toward(velocity.x, 0, speed * delta * 10)
					velocity.z = move_toward(velocity.z, 0, speed * delta * 10)

		"attack":
			velocity.x = move_toward(velocity.x, 0, speed * delta * 10)
			velocity.z = move_toward(velocity.z, 0, speed * delta * 10)
			_play_anim("attack")

		"jump":
			if is_on_floor():
				velocity.y = jump_force
			var dir = decision.get("direction", Vector3.ZERO)
			if dir is Vector3 and dir.length() > 0:
				velocity.x = dir.x * speed
				velocity.z = dir.z * speed

		"idle":
			velocity.x = move_toward(velocity.x, 0, speed * delta * 10)
			velocity.z = move_toward(velocity.z, 0, speed * delta * 10)


func _rotate_model(direction: Vector3, delta: float) -> void:
	if not rotate_to_movement or direction.length() < 0.01:
		return
	var target_angle: float = atan2(direction.x, direction.z)
	var model = get_node_or_null("PlayerModel")
	if model:
		model.rotation.y = lerp_angle(model.rotation.y, target_angle, rotation_speed * delta)


func _update_animation() -> void:
	if not anim_player:
		return
	var horiz_speed: float = Vector2(velocity.x, velocity.z).length()
	var state: String = "idle"
	if not is_on_floor():
		state = "jump"
	elif horiz_speed > 0.5:
		state = "walk"
	var target_anim: String = str(anim_state_map.get(state, "Idle_A"))
	if target_anim != current_anim and anim_player.has_animation(target_anim):
		anim_player.play(target_anim, anim_blend_time)
		current_anim = target_anim


func _play_anim(state: String) -> void:
	if not anim_player:
		return
	var target: String = str(anim_state_map.get(state, "Idle_A"))
	if anim_player.has_animation(target) and current_anim != target:
		anim_player.play(target, anim_blend_time)
		current_anim = target


func take_damage(amount: float) -> void:
	if is_dead:
		return
	current_hp -= amount
	print("[Player] Took ", amount, " damage. HP: ", current_hp, "/", max_hp)
	_play_anim("hit")
	if current_hp <= 0:
		current_hp = 0
		is_dead = true
		_play_anim("death")
		print("[Player] Died! Respawning in 3 seconds...")
		# Respawn after delay
		var tw := create_tween()
		tw.tween_interval(3.0)
		tw.tween_callback(_respawn)


func _respawn() -> void:
	current_hp = max_hp
	is_dead = false
	# Move back to spawn position
	var prog_file := FileAccess.open("res://data/progression.json", FileAccess.READ)
	if prog_file:
		var prog = JSON.parse_string(prog_file.get_as_text())
		if prog is Dictionary:
			var loc_id: String = str(prog.get("starting_location", ""))
			var loc_file := FileAccess.open("res://data/locations/" + loc_id + ".json", FileAccess.READ)
			if loc_file:
				var loc = JSON.parse_string(loc_file.get_as_text())
				if loc is Dictionary and loc.has("spawn_on_grid") and loc.has("grid"):
					var sg: Dictionary = loc.get("spawn_on_grid", {})
					var grid: Dictionary = loc.get("grid", {})
					var grid_map: Array = grid.get("map", [])
					var tile_size: float = grid.get("tile_size", 1.0)
					var rows: int = grid_map.size()
					var cols: int = str(grid_map[0]).length() if rows > 0 else 0
					var ox: float = -cols * tile_size / 2.0
					var oz: float = -rows * tile_size / 2.0
					position = Vector3(
						ox + sg.get("gx", 0) * tile_size + tile_size / 2,
						0.5,
						oz + sg.get("gz", 0) * tile_size + tile_size / 2
					)
	_play_anim("idle")
	print("[Player] Respawned! HP: ", current_hp)


func get_nearest_enemy_distance() -> float:
	var nearest: float = 999.0
	for entity in get_tree().get_nodes_in_group("enemy"):
		if entity.get("is_dead"):
			continue
		var dist: float = global_position.distance_to(entity.global_position)
		if dist < nearest:
			nearest = dist
	return nearest
