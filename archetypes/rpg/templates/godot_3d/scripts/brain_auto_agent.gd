extends Node

## AutoAgentBrain — AI that explores rooms and fights enemies.
## Same interface as HumanBrain and StateMachineBrain.
## Implements: decide(entity, world_state) -> Dictionary
## Also records action log for training data export.

var current_target: Vector3 = Vector3.ZERO
var wander_timer: float = 0.0
var wander_interval: float = 2.0
var attack_timer: float = 0.0
var attack_cooldown: float = 0.5
var attack_range: float = 2.0
var attack_damage: float = 25.0
var room_half_w: float = 6.0
var room_half_h: float = 5.0
var _heading_to_exit: bool = false

# Recording
var action_log: Array = []
var frame: int = 0


func init_config(config: Dictionary) -> void:
	attack_cooldown = config.get("attack_cooldown", 0.5)
	attack_range = config.get("attack_range", 2.0)
	attack_damage = config.get("attack_damage", 25.0)
	_load_room_bounds()
	_pick_new_target()


func _load_room_bounds() -> void:
	# Check for dungeon.json — seamless mode has larger bounds
	var dungeon_file := FileAccess.open("res://data/dungeon.json", FileAccess.READ)
	if dungeon_file:
		var dungeon = JSON.parse_string(dungeon_file.get_as_text())
		if dungeon is Dictionary and dungeon.has("rooms"):
			# Calculate total bounds from all rooms + offsets
			var min_x: float = -10.0
			var max_x: float = 10.0
			var min_z: float = -40.0
			var max_z: float = 10.0
			for room in dungeon.get("rooms", []):
				var offset: Dictionary = room.get("offset", {})
				var ox: float = offset.get("x", 0.0)
				var oz: float = offset.get("z", 0.0)
				min_x = min(min_x, ox - 10)
				max_x = max(max_x, ox + 10)
				min_z = min(min_z, oz - 10)
				max_z = max(max_z, oz + 10)
			room_half_w = (max_x - min_x) / 2.0 - 1
			room_half_h = (max_z - min_z) / 2.0 - 1
			print("[AutoAgent] Seamless bounds: w=", room_half_w, " h=", room_half_h)
			return

	# Single room mode
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
			room_half_w = str(grid_map[0]).length() * tile_size / 2.0 - 1.5
			room_half_h = grid_map.size() * tile_size / 2.0 - 1.5
	else:
		var layout = loc.get("layout", {})
		if layout is Dictionary:
			room_half_w = layout.get("width", 800) / 50.0 / 2 - 1
			room_half_h = layout.get("height", 800) / 50.0 / 2 - 1


func decide(entity: CharacterBody3D, world_state: Dictionary) -> Dictionary:
	var dt: float = entity.get_process_delta_time()
	attack_timer -= dt
	wander_timer += dt
	frame += 1

	# Find nearest enemy
	var nearest_enemy: Node = null
	var enemy_dist: float = 999.0
	for e in entity.get_tree().get_nodes_in_group("enemy"):
		if e.get("is_dead"):
			continue
		var dist: float = entity.global_position.distance_to(e.global_position)
		if dist < enemy_dist:
			enemy_dist = dist
			nearest_enemy = e

	var action_name: String = "idle"
	var result: Dictionary = {"action": "idle"}

	# Check for nearby interactables
	var nearest_interactable: Node = null
	var interact_dist: float = 999.0
	for prop in entity.get_tree().get_nodes_in_group("interactable"):
		if prop.get("has_been_interacted") and not prop.get("auto_trigger"):
			continue
		var d: float = entity.global_position.distance_to(prop.global_position)
		if d < interact_dist and d < 3.0:
			interact_dist = d
			nearest_interactable = prop

	# Interact mode: approach and interact with nearby props
	if nearest_interactable and not nearest_interactable.get("auto_trigger") and enemy_dist > 5.0:
		if nearest_interactable.has_method("can_interact") and nearest_interactable.can_interact(entity):
			if interact_dist > 1.5:
				result = {"action": "move_to", "target": nearest_interactable.global_position}
				action_name = "approach_interact"
			else:
				nearest_interactable.interact(entity)
				result = {"action": "idle"}
				action_name = "interact"
		# skip to recording
	# Combat mode: enemy within detection range
	elif nearest_enemy and enemy_dist < 8.0:
		if enemy_dist > attack_range:
			# Chase
			result = {"action": "move_to", "target": nearest_enemy.global_position}
			action_name = "chase_enemy"
		else:
			# Attack
			if attack_timer <= 0:
				attack_timer = attack_cooldown
				if nearest_enemy.has_method("take_damage"):
					nearest_enemy.take_damage(attack_damage)
			result = {"action": "attack"}
			action_name = "attack"
	else:
		# Explore mode: wander, then head to exit after exploring
		var to_target: Vector3 = current_target - entity.global_position
		to_target.y = 0

		# After exploring for a while, look for exits
		if frame > 120 and not _heading_to_exit:
			var exit_node = _find_nearest_exit(entity)
			if exit_node:
				current_target = exit_node.global_position
				_heading_to_exit = true
				action_name = "heading_to_exit"

		if to_target.length() > 0.5:
			result = {"action": "move_to", "target": current_target}
			if action_name == "":
				action_name = "explore"
		else:
			if _heading_to_exit:
				# Reached exit — should trigger transition automatically via Area3D
				_heading_to_exit = false
				frame = 0  # Reset explore timer for new room
			_pick_new_target()
			result = {"action": "idle"}
			action_name = "idle"

		# Stuck detection
		if wander_timer > wander_interval + 3.0:
			_pick_new_target()

		# Random jump
		if randf() < 0.005 and entity.is_on_floor():
			result = {"action": "jump", "direction": to_target.normalized() if to_target.length() > 0.1 else Vector3.FORWARD}
			action_name = "jump"

	# Record action log every 3 frames
	if frame % 3 == 0:
		var cam = entity.get_node_or_null("CameraArm/Camera")
		action_log.append({
			"frame": frame,
			"pos": [entity.global_position.x, entity.global_position.y, entity.global_position.z],
			"rot": [entity.rotation.x, entity.rotation.y, entity.rotation.z],
			"action": action_name,
			"velocity": [entity.velocity.x, entity.velocity.y, entity.velocity.z],
			"camera_pos": [cam.global_position.x, cam.global_position.y, cam.global_position.z] if cam else [0, 0, 0],
			"nearest_enemy_dist": enemy_dist,
		})

	return result


func _find_nearest_exit(entity: CharacterBody3D) -> Node:
	var nearest: Node = null
	var nearest_dist: float = 999.0
	for exit_zone in entity.get_tree().get_nodes_in_group("exit_zone"):
		var dist: float = entity.global_position.distance_to(exit_zone.global_position)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest = exit_zone
	return nearest


func _pick_new_target() -> void:
	current_target = Vector3(
		randf_range(-room_half_w, room_half_w),
		0,
		randf_range(-room_half_h, room_half_h)
	)
	wander_timer = 0.0


func save_log() -> void:
	var path: String = "user://captures/action_log.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(action_log))
		print("[AutoAgent] Saved ", action_log.size(), " action records to ", path)
