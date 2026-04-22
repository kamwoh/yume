extends Node

## HumanBrain — reads keyboard/mouse input, returns actions.
## Same interface as StateMachineBrain and LLMBrain.
## Implements: decide(entity, world_state) -> Dictionary

var attack_timer: float = 0.0
var attack_cooldown: float = 0.5
var attack_range: float = 2.0
var attack_damage: float = 25.0
var want_attack: bool = false


func init_config(config: Dictionary) -> void:
	attack_cooldown = config.get("attack_cooldown", 0.5)
	attack_range = config.get("attack_range", 2.0)
	attack_damage = config.get("attack_damage", 25.0)


func _input(event: InputEvent) -> void:
	# Attack on left click
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			want_attack = true


func decide(entity: CharacterBody3D, world_state: Dictionary) -> Dictionary:
	var dt: float = entity.get_process_delta_time()
	attack_timer -= dt

	# Read movement input
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

	# Convert to world direction using CAMERA facing (not player body)
	var cam_arm = entity.get_node_or_null("CameraArm")
	var cam_basis: Basis = cam_arm.global_transform.basis if cam_arm else entity.transform.basis
	var direction := Vector3.ZERO
	direction += cam_basis.z * input.y  # forward/back relative to camera
	direction += cam_basis.x * input.x  # left/right relative to camera
	direction.y = 0
	direction = direction.normalized()

	# Handle attack
	if want_attack and attack_timer <= 0:
		want_attack = false
		attack_timer = attack_cooldown
		_do_attack(entity)
		return {"action": "attack"}
	want_attack = false

	# Handle jump
	if Input.is_action_just_pressed("jump") and entity.is_on_floor():
		return {"action": "jump", "direction": direction}

	# Movement
	if direction.length() > 0:
		return {"action": "move_to_direction", "direction": direction}

	return {"action": "idle"}


func _do_attack(entity: CharacterBody3D) -> void:
	# Find nearest enemy in range
	for e in entity.get_tree().get_nodes_in_group("enemy"):
		if e.get("is_dead"):
			continue
		var dist: float = entity.global_position.distance_to(e.global_position)
		if dist < attack_range and e.has_method("take_damage"):
			e.take_damage(attack_damage)
			break
