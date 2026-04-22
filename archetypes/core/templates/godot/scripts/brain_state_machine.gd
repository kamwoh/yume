extends Node

const SimPos = preload("res://scripts/sim_pos.gd")

## StateMachineBrain — simple AI: patrol → detect → chase → attack → flee
## All parameters from JSON ai_config. Swappable with BehaviorTreeBrain or LLMBrain.
## Implements: decide(entity, world_state) -> Dictionary

enum State { IDLE, GUARD, PATROL, CHASE, ATTACK, FLEE, DEAD }

var current_state: State = State.IDLE
var patrol_points: Array = []
var patrol_index: int = 0
var guard_position: Vector3 = Vector3.ZERO
var guard_facing: Vector3 = Vector3.FORWARD
var has_guard_pos: bool = false
var attack_timer: float = 0.0
var state_timer: float = 0.0

# Config — set from entity's ai_config
var detect_range: float = 5.0
var attack_range: float = 1.5
var flee_hp_percent: float = 0.2
var attack_cooldown: float = 1.0
var patrol_wait: float = 1.5
var default_state: String = "patrol"

# Grid offset for converting patrol points
var grid_offset_x: float = 0.0
var grid_offset_z: float = 0.0
var tile_size: float = 1.0


func init_config(ai_config: Dictionary, _grid_offset_x: float, _grid_offset_z: float, _tile_size: float) -> void:
	detect_range = ai_config.get("detect_range", 5.0)
	attack_range = ai_config.get("attack_range", 1.5)
	flee_hp_percent = ai_config.get("flee_hp_percent", 0.2)
	attack_cooldown = ai_config.get("attack_cooldown", 1.0)
	patrol_wait = ai_config.get("patrol_wait", 1.5)
	default_state = str(ai_config.get("default_state", "patrol"))
	grid_offset_x = _grid_offset_x
	grid_offset_z = _grid_offset_z
	tile_size = _tile_size

	# Guard position — stand at a specific spot facing a direction
	var gp = ai_config.get("guard_position", null)
	if gp is Dictionary:
		guard_position = Vector3(
			grid_offset_x + gp.get("gx", 0) * tile_size + tile_size / 2,
			0,
			grid_offset_z + gp.get("gz", 0) * tile_size + tile_size / 2
		)
		has_guard_pos = true
		# Facing direction
		var facing: String = str(ai_config.get("guard_facing", "south"))
		match facing:
			"north": guard_facing = Vector3(0, 0, -1)
			"south": guard_facing = Vector3(0, 0, 1)
			"east":  guard_facing = Vector3(1, 0, 0)
			"west":  guard_facing = Vector3(-1, 0, 0)

	# Convert grid patrol points to world coords
	var points = ai_config.get("patrol_points", [])
	patrol_points = []
	for p in points:
		if p is Dictionary:
			var wx: float = grid_offset_x + p.get("gx", 0) * tile_size + tile_size / 2
			var wz: float = grid_offset_z + p.get("gz", 0) * tile_size + tile_size / 2
			patrol_points.append(Vector3(wx, 0, wz))

	# Set initial state based on config
	match default_state:
		"guard":
			current_state = State.GUARD
		"patrol":
			current_state = State.PATROL if patrol_points.size() > 0 else State.IDLE
		_:
			current_state = State.IDLE


func decide(entity: CharacterBody3D, world_state: Dictionary) -> Dictionary:
	## The brain interface — returns what to do this frame.
	var dt: float = entity.get_process_delta_time()
	attack_timer -= dt
	state_timer += dt

	var player_dist: float = world_state.get("player_distance", 999.0)
	var hp_pct: float = world_state.get("self_hp", 1.0) / max(world_state.get("self_max_hp", 1.0), 0.01)

	# State transitions
	match current_state:
		State.IDLE:
			if player_dist < detect_range:
				_change_state(State.CHASE)
			elif has_guard_pos and default_state == "guard":
				_change_state(State.GUARD)
			elif patrol_points.size() > 0 and state_timer > patrol_wait:
				_change_state(State.PATROL)

		State.GUARD:
			if player_dist < detect_range:
				_change_state(State.CHASE)

		State.PATROL:
			if player_dist < detect_range:
				_change_state(State.CHASE)

		State.CHASE:
			if player_dist > detect_range * 1.5:
				# Return to guard post or patrol
				if has_guard_pos and default_state == "guard":
					_change_state(State.GUARD)
				elif patrol_points.size() > 0:
					_change_state(State.PATROL)
				else:
					_change_state(State.IDLE)
			elif player_dist <= attack_range:
				_change_state(State.ATTACK)
			elif hp_pct <= flee_hp_percent:
				_change_state(State.FLEE)

		State.ATTACK:
			if player_dist > attack_range * 1.3:
				_change_state(State.CHASE)
			elif hp_pct <= flee_hp_percent:
				_change_state(State.FLEE)

		State.FLEE:
			if player_dist > detect_range * 2:
				if has_guard_pos and default_state == "guard":
					_change_state(State.GUARD)
				else:
					_change_state(State.IDLE)

	# Execute current state
	match current_state:
		State.IDLE:
			return {"action": "idle"}

		State.GUARD:
			# Stand at guard position, face guard direction
			var here: Vector2 = SimPos.of(entity)
			var post_2d := Vector2(guard_position.x, guard_position.z)
			var dist_to_post: float = here.distance_to(post_2d)
			if dist_to_post > 0.5:
				# Walk back to guard post
				return {"action": "move_to", "target": post_2d}
			else:
				# At post — face guard direction
				return {"action": "face_direction", "direction": guard_facing}

		State.PATROL:
			if patrol_points.is_empty():
				return {"action": "idle"}
			var target: Vector3 = patrol_points[patrol_index]
			var target_2d := Vector2(target.x, target.z)
			var dist: float = SimPos.of(entity).distance_to(target_2d)
			if dist < 0.5:
				patrol_index = (patrol_index + 1) % patrol_points.size()
				state_timer = 0.0
				return {"action": "idle"}
			return {"action": "move_to", "target": target_2d}

		State.CHASE:
			var player_pos = world_state.get("player_pos", entity.global_position)
			var chase_2d: Vector2 = player_pos if player_pos is Vector2 else Vector2(player_pos.x, player_pos.z)
			return {"action": "move_to", "target": chase_2d}

		State.ATTACK:
			var did_attack: bool = false
			if attack_timer <= 0:
				attack_timer = attack_cooldown
				_do_attack(entity, world_state)
				did_attack = true
			return {"action": "attack", "fresh": did_attack}

		State.FLEE:
			var player_pos = world_state.get("player_pos", entity.global_position)
			var flee_2d: Vector2 = player_pos if player_pos is Vector2 else Vector2(player_pos.x, player_pos.z)
			return {"action": "flee", "target": flee_2d}

	return {"action": "idle"}


func _change_state(new_state: State) -> void:
	current_state = new_state
	state_timer = 0.0


func _do_attack(entity: CharacterBody3D, world_state: Dictionary) -> void:
	## Deal damage to player if in range
	var player = entity.get_tree().get_first_node_in_group("player")
	if not player:
		return
	var dist: float = entity.global_position.distance_to(player.global_position)
	if dist <= attack_range:
		if player.has_method("take_damage"):
			player.take_damage(entity.damage)


func get_state_name() -> String:
	match current_state:
		State.IDLE: return "idle"
		State.PATROL: return "patrol"
		State.CHASE: return "chase"
		State.ATTACK: return "attack"
		State.FLEE: return "flee"
		State.DEAD: return "dead"
	return "unknown"
