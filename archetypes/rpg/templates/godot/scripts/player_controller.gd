extends CharacterBody2D

@export var move_speed: float = 200.0
@export var interact_range: float = 40.0

var can_move: bool = true

func _ready() -> void:
	# Replace plain sprite with better character visual
	var old_sprite = get_node_or_null("PlayerSprite")
	if old_sprite:
		old_sprite.queue_free()
	# Add character silhouette
	var vh = load("res://scripts/visual_helpers.gd")
	if vh:
		vh.create_character_visual(self, Color(0, 0.8, 0.8), true)

func _physics_process(delta: float) -> void:
	# Also check if dialogue or cutscene is active (safety net)
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

	# (Flip disabled for placeholder rectangles — enable when using real sprites)

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
