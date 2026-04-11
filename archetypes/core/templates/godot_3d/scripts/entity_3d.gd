extends CharacterBody3D

## Entity — base for all NPCs, enemies, companions.
## Has: model, stats, brain (AI controller).
## Brain is swappable: state_machine today, LLM tomorrow.

signal died(entity: CharacterBody3D)
signal took_damage(entity: CharacterBody3D, amount: float)

# Stats — all from JSON
var entity_name: String = "Entity"
var max_hp: float = 50.0
var current_hp: float = 50.0
var damage: float = 10.0
var move_speed: float = 3.0
var attack_range: float = 1.5
var detect_range: float = 5.0
var attack_cooldown: float = 1.0
var is_dead: bool = false

# Brain reference
var brain: Node = null

# Animation
var anim_player: AnimationPlayer = null
var current_anim: String = ""

# Config
var ai_config: Dictionary = {}
var gravity: float = 20.0


func init_from_json(config: Dictionary) -> void:
	entity_name = str(config.get("name", "Entity"))
	var stats: Dictionary = config.get("stats", {})
	if stats is Dictionary:
		max_hp = stats.get("hp", 50.0)
		damage = stats.get("damage", 10.0)
		move_speed = stats.get("speed", 3.0)
		attack_range = stats.get("attack_range", 1.5)
		detect_range = stats.get("detect_range", 5.0)
		attack_cooldown = stats.get("attack_cooldown", 1.0)
	current_hp = max_hp
	ai_config = config.get("ai_config", {})
	if not ai_config is Dictionary:
		ai_config = {}


func take_damage(amount: float) -> void:
	if is_dead:
		return
	current_hp -= amount
	took_damage.emit(self, amount)
	play_anim("hit")

	if current_hp <= 0:
		current_hp = 0
		_die()


func _die() -> void:
	is_dead = true
	play_anim("death")
	died.emit(self)
	# Remove after death animation
	var tw := create_tween()
	tw.tween_interval(1.0)
	tw.tween_callback(queue_free)


## Maps generic states to animation names. Tries multiple naming conventions.
var _anim_map: Dictionary = {
	"idle": ["idle", "Idle_A", "Idle"],
	"walk": ["walk", "Walking_A", "Walk"],
	"run": ["sprint", "Running_A", "Run"],
	"attack": ["attack-melee-right", "Hit_A", "Attack"],
	"hit": ["hit", "Hit_A", "Hurt"],
	"death": ["die", "Death_A", "Death"],
	"jump": ["jump", "Jump_Idle", "Jump"],
}

func play_anim(state: String, force: bool = false) -> void:
	if not anim_player:
		return
	if is_dead and state != "death":
		return

	# Try each naming convention for this state
	var candidates: Array = _anim_map.get(state, [state])
	for candidate in candidates:
		if anim_player.has_animation(candidate):
			if force or current_anim != candidate:
				anim_player.play(candidate, 0.2)
				current_anim = candidate
				return


func get_world_state() -> Dictionary:
	## Returns what the brain sees — nearby entities, own state, etc.
	var state: Dictionary = {
		"self_pos": global_position,
		"self_hp": current_hp,
		"self_max_hp": max_hp,
		"self_dead": is_dead,
	}

	# Find player
	var player = get_tree().get_first_node_in_group("player")
	if player:
		state["player_pos"] = player.global_position
		state["player_distance"] = global_position.distance_to(player.global_position)
		state["player_hp"] = player.get("current_hp") if player.has_method("get") else -1
	else:
		state["player_distance"] = 999.0

	return state


func _physics_process(delta: float) -> void:
	if is_dead:
		return

	# Gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Let brain decide
	if brain and brain.has_method("decide"):
		var world_state: Dictionary = get_world_state()
		var decision: Dictionary = brain.decide(self, world_state)
		_execute_decision(decision, delta)

	move_and_slide()


func _execute_decision(decision: Dictionary, delta: float) -> void:
	var action: String = str(decision.get("action", "idle"))

	match action:
		"move_to":
			var target_pos = decision.get("target", global_position)
			if target_pos is Vector3:
				var direction: Vector3 = (target_pos - global_position)
				direction.y = 0
				if direction.length() > 0.3:
					direction = direction.normalized()
					velocity.x = direction.x * move_speed
					velocity.z = direction.z * move_speed
					# Face movement direction
					var model = get_node_or_null("EntityModel")
					if model:
						var angle: float = atan2(direction.x, direction.z)
						model.rotation.y = lerp_angle(model.rotation.y, angle, 10.0 * delta)
					play_anim("walk")
				else:
					velocity.x = move_toward(velocity.x, 0, move_speed * delta * 10)
					velocity.z = move_toward(velocity.z, 0, move_speed * delta * 10)
					play_anim("idle")

		"attack":
			velocity.x = move_toward(velocity.x, 0, move_speed * delta * 10)
			velocity.z = move_toward(velocity.z, 0, move_speed * delta * 10)
			# Replay attack anim on each fresh attack (cooldown reset)
			var fresh: bool = decision.get("fresh", false)
			if fresh:
				play_anim("attack", true)
			else:
				play_anim("idle")

		"face_direction":
			# Stand still, face a specific direction (for guard state)
			velocity.x = move_toward(velocity.x, 0, move_speed * delta * 10)
			velocity.z = move_toward(velocity.z, 0, move_speed * delta * 10)
			var face_dir = decision.get("direction", Vector3.FORWARD)
			if face_dir is Vector3 and face_dir.length() > 0.01:
				var model = get_node_or_null("EntityModel")
				if model:
					var angle: float = atan2(face_dir.x, face_dir.z)
					model.rotation.y = lerp_angle(model.rotation.y, angle, 5.0 * delta)
			play_anim("idle")

		"idle":
			velocity.x = move_toward(velocity.x, 0, move_speed * delta * 10)
			velocity.z = move_toward(velocity.z, 0, move_speed * delta * 10)
			play_anim("idle")

		"flee":
			var away_from = decision.get("target", global_position)
			if away_from is Vector3:
				var direction: Vector3 = (global_position - away_from)
				direction.y = 0
				if direction.length() > 0.1:
					direction = direction.normalized()
					velocity.x = direction.x * move_speed * 1.2
					velocity.z = direction.z * move_speed * 1.2
					play_anim("run")
