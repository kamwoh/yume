extends Node

## Auto Agent — controls the player character automatically.
## Walks around, explores, interacts with objects.
## Records actions for training data.
##
## Attach to the Player node.

var player: CharacterBody3D
var speed: float = 5.0
var jump_force: float = 6.0
var gravity: float = 20.0

# Agent state
var current_target: Vector3 = Vector3.ZERO
var wander_timer: float = 0.0
var wander_interval: float = 2.0
var action_log: Array = []
var frame: int = 0

# Room bounds (from meta.json world config)
var room_half_w: float = 8.0
var room_half_h: float = 8.0

func _ready() -> void:
	player = get_parent() as CharacterBody3D
	if not player:
		push_error("AutoAgent must be child of CharacterBody3D")
		return

	# Read config
	var meta_file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if meta_file:
		var meta = JSON.parse_string(meta_file.get_as_text())
		if meta is Dictionary:
			var pcfg = meta.get("player", {})
			if pcfg is Dictionary:
				speed = pcfg.get("move_speed", 5.0)
				jump_force = pcfg.get("jump_force", 6.0)
				gravity = pcfg.get("gravity", 20.0)

	# Read room size
	var prog_file := FileAccess.open("res://data/progression.json", FileAccess.READ)
	if prog_file:
		var prog = JSON.parse_string(prog_file.get_as_text())
		if prog is Dictionary:
			var loc_id: String = str(prog.get("starting_location", ""))
			var loc_file := FileAccess.open("res://data/locations/" + loc_id + ".json", FileAccess.READ)
			if loc_file:
				var loc = JSON.parse_string(loc_file.get_as_text())
				if loc is Dictionary:
					# Grid rooms: size from grid map
					if loc.has("grid"):
						var grid: Dictionary = loc.get("grid", {})
						var grid_map: Array = grid.get("map", [])
						var tile_size: float = grid.get("tile_size", 1.0)
						if grid_map.size() > 0:
							var rows: int = grid_map.size()
							var cols: int = str(grid_map[0]).length()
							room_half_w = cols * tile_size / 2.0 - 1.5
							room_half_h = rows * tile_size / 2.0 - 1.5
					else:
						var layout = loc.get("layout", {})
						if layout is Dictionary:
							room_half_w = layout.get("width", 800) / 50.0 / 2 - 1
							room_half_h = layout.get("height", 800) / 50.0 / 2 - 1

	_pick_new_target()


func _physics_process(delta: float) -> void:
	if not player:
		return

	frame += 1

	# Gravity
	if not player.is_on_floor():
		player.velocity.y -= gravity * delta

	# Navigate toward target
	var to_target: Vector3 = current_target - player.global_position
	to_target.y = 0
	var distance: float = to_target.length()

	var action: String = "idle"

	# Check for nearby enemies — fight if close
	var enemy_dist: float = 999.0
	if player.has_method("get_nearest_enemy_distance"):
		enemy_dist = player.get_nearest_enemy_distance()

	if enemy_dist < 2.5:
		# Combat mode: approach and attack
		var nearest_enemy: Node = _find_nearest_enemy()
		if nearest_enemy:
			var to_enemy: Vector3 = nearest_enemy.global_position - player.global_position
			to_enemy.y = 0
			if to_enemy.length() > 1.5:
				# Move toward enemy
				var dir: Vector3 = to_enemy.normalized()
				player.velocity.x = dir.x * speed
				player.velocity.z = dir.z * speed
				var model = player.get_node_or_null("PlayerModel")
				if model:
					model.rotation.y = lerp_angle(model.rotation.y, atan2(dir.x, dir.z), 10.0 * delta)
				_play_anim("walk")
				action = "chase_enemy"
			else:
				# In range — attack
				player.velocity.x = move_toward(player.velocity.x, 0, speed * delta * 10)
				player.velocity.z = move_toward(player.velocity.z, 0, speed * delta * 10)
				if player.has_method("_try_attack"):
					player._try_attack()
				action = "attack"
	elif distance > 0.5:
		var direction: Vector3 = to_target.normalized()
		player.velocity.x = direction.x * speed
		player.velocity.z = direction.z * speed
		action = "move"

		# Rotate model to face movement
		var model = player.get_node_or_null("PlayerModel")
		if model:
			var target_angle: float = atan2(direction.x, direction.z)
			model.rotation.y = lerp_angle(model.rotation.y, target_angle, 10.0 * delta)

		# Random jump occasionally
		if randf() < 0.01 and player.is_on_floor():
			player.velocity.y = jump_force
			action = "jump"

		# Play walk animation
		_play_anim("walk")
	else:
		# Reached target — pick new one
		player.velocity.x = move_toward(player.velocity.x, 0, speed * delta * 10)
		player.velocity.z = move_toward(player.velocity.z, 0, speed * delta * 10)
		_play_anim("idle")
		_pick_new_target()

	player.move_and_slide()

	# Check if stuck (hitting wall)
	wander_timer += delta
	if wander_timer > wander_interval + 3.0:
		# Stuck — pick new target
		_pick_new_target()

	# Record action
	if frame % 3 == 0:  # Log every 3 frames
		var cam = player.get_node_or_null("CameraArm/Camera")
		action_log.append({
			"frame": frame,
			"pos": [player.global_position.x, player.global_position.y, player.global_position.z],
			"rot": [player.rotation.x, player.rotation.y, player.rotation.z],
			"action": action,
			"velocity": [player.velocity.x, player.velocity.y, player.velocity.z],
			"camera_pos": [cam.global_position.x, cam.global_position.y, cam.global_position.z] if cam else [0, 0, 0],
		})


func _find_nearest_enemy() -> Node:
	var nearest: Node = null
	var nearest_dist: float = 999.0
	for entity in player.get_tree().get_nodes_in_group("enemy"):
		if entity.get("is_dead"):
			continue
		var dist: float = player.global_position.distance_to(entity.global_position)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = entity
	return nearest


func _pick_new_target() -> void:
	# Random point in the room
	current_target = Vector3(
		randf_range(-room_half_w, room_half_w),
		0,
		randf_range(-room_half_h, room_half_h)
	)
	wander_timer = 0.0


func _play_anim(state: String) -> void:
	var anim_player: AnimationPlayer = null
	if player.has_meta("anim_player"):
		anim_player = player.get_meta("anim_player")
	if not anim_player:
		return

	var acfg_file := FileAccess.open("res://data/asset_config.json", FileAccess.READ)
	if not acfg_file:
		return
	var acfg = JSON.parse_string(acfg_file.get_as_text())
	if not acfg is Dictionary:
		return
	var state_map: Dictionary = acfg.get("animation_config", {}).get("state_map", {})
	var target_anim: String = str(state_map.get(state, "Idle_A"))
	if anim_player.has_animation(target_anim) and anim_player.current_animation != target_anim:
		var blend: float = acfg.get("animation_config", {}).get("blend_time", 0.2)
		anim_player.play(target_anim, blend)


## Save recorded actions to file
func save_log() -> void:
	var path: String = "user://captures/action_log.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(action_log))
		print("[Agent] Saved ", action_log.size(), " action records to ", path)
