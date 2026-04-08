extends CharacterBody2D

var move_speed: float = 200.0
var interact_range: float = 40.0
var can_move: bool = true

func _ready() -> void:
	# Load player config from meta.json
	var file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		if data is Dictionary:
			var player_config: Dictionary = data.get("player", {})
			move_speed = player_config.get("move_speed", 200.0)
			interact_range = player_config.get("interact_range", 40.0)

	# Get player character color from characters.json
	var player_color := Color(0.5, 0.5, 0.5)
	var player_id: String = ""
	if PartyManager.party.size() > 0:
		player_id = PartyManager.party[0].get("id", "")
	if player_id == "" and GameManager:
		# Fallback: read starting_party from progression.json
		var prog_file := FileAccess.open("res://data/progression.json", FileAccess.READ)
		if prog_file:
			var prog = JSON.parse_string(prog_file.get_as_text())
			if prog is Dictionary:
				var sp = prog.get("starting_party", [])
				if sp is Array and sp.size() > 0:
					player_id = str(sp[0])

	# Read color from characters.json
	if player_id != "":
		var char_file := FileAccess.open("res://data/characters.json", FileAccess.READ)
		if char_file:
			var chars = JSON.parse_string(char_file.get_as_text())
			if chars is Array:
				for c in chars:
					if c.get("id", "") == player_id:
						var col = c.get("color")
						if col is Array and col.size() >= 3:
							player_color = Color(col[0], col[1], col[2])
						break

	# Replace plain sprite with character visual
	var old_sprite = get_node_or_null("PlayerSprite")
	if old_sprite:
		old_sprite.queue_free()
	var vh = load("res://scripts/visual_helpers.gd")
	if vh:
		vh.create_character_visual(self, player_color, true, player_id)

func _physics_process(delta: float) -> void:
	if DialogueManager and DialogueManager.is_playing:
		can_move = false
	if CutsceneManager and CutsceneManager.is_playing:
		can_move = false

	if not can_move:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var input := Vector2.ZERO
	input.x = Input.get_axis("move_left", "move_right")
	input.y = Input.get_axis("move_up", "move_down")

	velocity = input.normalized() * move_speed
	move_and_slide()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact") and can_move:
		_try_interact()

func _try_interact() -> void:
	var areas = $InteractArea.get_overlapping_areas()
	for area in areas:
		var parent = area.get_parent()
		if parent.is_in_group("interactable"):
			parent.interact()
			return
