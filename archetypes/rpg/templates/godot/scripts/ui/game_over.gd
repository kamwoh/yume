extends CanvasLayer

# Game Over — shown on party defeat. Options: Retry (load last save) or Title Screen.

func _ready() -> void:
	layer = 45
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	BattleManager.battle_ended.connect(_on_battle_ended)
	_build_ui()

var _panel: Control

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.name = "GameOverBG"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.05, 0.0, 0.0, 0.9)
	add_child(bg)

	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(anchor)

	_panel = VBoxContainer.new()
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -175
	_panel.offset_right = 175
	_panel.offset_top = -125
	_panel.offset_bottom = 125
	_panel.add_theme_constant_override("separation", 16)
	anchor.add_child(_panel)

	var title := Label.new()
	title.text = "Game Over"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if UITheme:
		title.add_theme_font_size_override("font_size", 32)
		title.add_theme_color_override("font_color", UITheme.DANGER)
	else:
		title.add_theme_font_size_override("font_size", 32)
		title.add_theme_color_override("font_color", Color(0.8, 0.1, 0.1))
	_panel.add_child(title)

	var msg := Label.new()
	msg.text = "Your party has been defeated..."
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if UITheme:
		msg.add_theme_font_size_override("font_size", 16)
		msg.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	_panel.add_child(msg)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	_panel.add_child(spacer)

	var retry_btn := Button.new()
	retry_btn.text = "Retry"
	retry_btn.custom_minimum_size = Vector2(250, 36)
	retry_btn.pressed.connect(_on_retry)
	if UITheme: UITheme.style_button(retry_btn)
	_panel.add_child(retry_btn)

	var title_btn := Button.new()
	title_btn.text = "Title Screen"
	title_btn.custom_minimum_size = Vector2(250, 36)
	title_btn.pressed.connect(_on_title)
	if UITheme: UITheme.style_button(title_btn)
	_panel.add_child(title_btn)

	# Keyboard support
	retry_btn.grab_focus()

func _on_battle_ended(victory: bool) -> void:
	if not victory:
		# Check if this was a real defeat (not a flee)
		await get_tree().create_timer(1.0).timeout
		# Check party — if all dead, game over
		var all_dead: bool = true
		for m in PartyManager.party:
			if m["hp"] > 0:
				all_dead = false
				break
		if all_dead:
			_show_game_over()

func _show_game_over() -> void:
	visible = true
	get_tree().paused = true

func _on_retry() -> void:
	visible = false
	get_tree().paused = false
	# Heal party and reload current location (safe, no save corruption)
	PartyManager.heal_all()
	LocationManager.load_location(GameManager.current_location_id)

func _on_title() -> void:
	visible = false
	get_tree().paused = false
	# Reset game state
	GameManager.flags.clear()
	GameManager.gil = 200
	PartyManager.party.clear()
	PartyManager._ready()
	InventoryManager.items.clear()
	InventoryManager._ready()
	QuestManager.completed_quests.clear()
	QuestManager.active_quests.clear()
	QuestManager._ready()
	# Show title screen
	var title_screen = get_tree().current_scene.get_node_or_null("TitleScreen")
	if title_screen:
		title_screen.show_title()
