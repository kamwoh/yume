extends StaticBody3D

## Interactable prop — chest, gate, trap, coin, barrel.
## Plays built-in GLB animations on interaction.
## Config from JSON: type, contents, interaction_range.

signal interacted(prop: StaticBody3D, interactor: Node)
signal state_changed(prop: StaticBody3D, old_state: String, new_state: String)

# Config — from JSON
var prop_type: String = "chest"
var prop_state: String = "closed"  # closed, open, broken, collected, triggered
var interaction_range: float = 1.5
var contents: Array = []  # items inside (for chests)
var damage: float = 0.0  # for traps
var requires_key: String = ""  # for gates
var auto_trigger: bool = false  # traps trigger on proximity, not interaction

# Internal
var anim_player: AnimationPlayer = null
var has_been_interacted: bool = false


func init_from_json(config: Dictionary) -> void:
	prop_type = str(config.get("type", "chest"))
	interaction_range = config.get("interaction_range", 1.5)
	contents = config.get("contents", [])
	damage = config.get("damage", 15.0)
	requires_key = str(config.get("requires_key", ""))
	auto_trigger = config.get("auto_trigger", prop_type == "trap")

	# Add to interactable group
	add_to_group("interactable")
	if prop_type == "coin":
		add_to_group("collectible")


func setup_anim_player() -> void:
	# Find AnimationPlayer in children (loaded from GLB)
	for child in get_children():
		_find_anim_recursive(child)


func _find_anim_recursive(node: Node) -> void:
	if node is AnimationPlayer:
		anim_player = node
		return
	for child in node.get_children():
		_find_anim_recursive(child)


func _physics_process(_delta: float) -> void:
	if has_been_interacted or not auto_trigger or prop_state == "collected":
		return

	# Auto-trigger: check player proximity (for traps)
	var player = get_tree().get_first_node_in_group("player")
	if not player:
		return
	var dist: float = global_position.distance_to(player.global_position)
	if dist < interaction_range:
		interact(player)


func can_interact(interactor: Node) -> bool:
	if has_been_interacted:
		return false
	if requires_key != "":
		# Future: check if player has key item
		return false
	var dist: float = global_position.distance_to(interactor.global_position)
	return dist < interaction_range


func interact(interactor: Node) -> void:
	if has_been_interacted:
		return
	has_been_interacted = true

	var old_state: String = prop_state

	match prop_type:
		"chest":
			_open_chest(interactor)
		"gate":
			_open_gate(interactor)
		"trap":
			_trigger_trap(interactor)
		"coin":
			_collect_coin(interactor)
		"barrel":
			_break_barrel(interactor)
		_:
			_generic_interact(interactor)

	interacted.emit(self, interactor)
	state_changed.emit(self, old_state, prop_state)


func _open_chest(_interactor: Node) -> void:
	prop_state = "open"
	if anim_player and anim_player.has_animation("open"):
		anim_player.play("open")
	# Spawn loot items (visual only — float up from chest)
	for item in contents:
		_spawn_loot_visual(str(item))
	print("[Interact] Chest opened! Contents: ", contents)


func _open_gate(_interactor: Node) -> void:
	prop_state = "open"
	if anim_player and anim_player.has_animation("open"):
		anim_player.play("open")
	print("[Interact] Gate opened!")


func _trigger_trap(interactor: Node) -> void:
	prop_state = "triggered"
	if anim_player and anim_player.has_animation("show"):
		anim_player.play("show")
	# Deal damage
	if interactor.has_method("take_damage") and damage > 0:
		interactor.take_damage(damage)
	print("[Interact] Trap triggered! Damage: ", damage)
	# Reset after delay
	var tw := create_tween()
	tw.tween_interval(2.0)
	tw.tween_callback(_reset_trap)


func _reset_trap() -> void:
	has_been_interacted = false
	prop_state = "closed"
	if anim_player and anim_player.has_animation("hide"):
		anim_player.play("hide")


func _collect_coin(_interactor: Node) -> void:
	prop_state = "collected"
	# Disable physics processing immediately to prevent re-trigger
	set_physics_process(false)
	# Float up and shrink
	var tw := create_tween()
	tw.tween_property(self, "position:y", position.y + 1.0, 0.3)
	tw.parallel().tween_property(self, "scale", Vector3(0.01, 0.01, 0.01), 0.3)
	tw.tween_callback(queue_free)
	print("[Interact] Coin collected!")


func _break_barrel(_interactor: Node) -> void:
	prop_state = "broken"
	set_physics_process(false)
	# Shrink and remove (no animation in model)
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector3(0.01, 0.01, 0.01), 0.2)
	tw.tween_callback(queue_free)
	print("[Interact] Barrel broken!")


func _generic_interact(_interactor: Node) -> void:
	prop_state = "interacted"
	print("[Interact] ", prop_type, " interacted")


func _spawn_loot_visual(item_name: String) -> void:
	# Simple visual: a small glowing sphere floats up
	var loot := MeshInstance3D.new()
	loot.mesh = SphereMesh.new()
	loot.mesh.radius = 0.1
	loot.mesh.height = 0.2
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.85, 0.2)  # gold
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.85, 0.2)
	mat.emission_energy_multiplier = 2.0
	loot.material_override = mat
	loot.position = Vector3(0, 0.5, 0)
	add_child(loot)

	# Float up and fade
	var tw := create_tween()
	tw.tween_property(loot, "position:y", 2.0, 1.0)
	tw.parallel().tween_property(loot, "scale", Vector3.ZERO, 1.0).set_delay(0.5)
	tw.tween_callback(loot.queue_free)


func get_interaction_data() -> Dictionary:
	return {
		"type": prop_type,
		"state": prop_state,
		"position": [global_position.x, global_position.y, global_position.z],
		"interacted": has_been_interacted,
	}
