extends CanvasLayer

# Title Screen — shown on game start, hidden after "New Game" or "Continue"

var is_active: bool = true

func _ready() -> void:
	layer = 50  # Above everything
	_build_ui()
	# Pause the game tree while title is showing
	get_tree().paused = true
	process_mode = Node.PROCESS_MODE_ALWAYS

func _build_ui() -> void:
	# Full screen background
	var bg := ColorRect.new()
	bg.name = "TitleBG"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.03, 0.03, 0.08, 1.0)
	add_child(bg)

	# Center container — properly centered
	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(anchor)

	var center := VBoxContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_CENTER)
	center.anchor_left = 0.5
	center.anchor_right = 0.5
	center.anchor_top = 0.5
	center.anchor_bottom = 0.5
	center.offset_left = -200
	center.offset_right = 200
	center.offset_top = -175
	center.offset_bottom = 175
	center.add_theme_constant_override("separation", 20)
	anchor.add_child(center)

	# Title
	var title := Label.new()
	title.text = _get_game_title()
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if UITheme:
		title.add_theme_font_size_override("font_size", 36)
		title.add_theme_color_override("font_color", UITheme.ACCENT)
	else:
		title.add_theme_font_size_override("font_size", 36)
		title.add_theme_color_override("font_color", Color(0.9, 0.75, 0.3))
	center.add_child(title)

	# Subtitle
	var subtitle := Label.new()
	subtitle.text = "夢 — A Yume Game"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if UITheme:
		subtitle.add_theme_font_size_override("font_size", 14)
		subtitle.add_theme_color_override("font_color", UITheme.TEXT_DIM)
	else:
		subtitle.add_theme_font_size_override("font_size", 14)
		subtitle.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	center.add_child(subtitle)

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 40)
	center.add_child(spacer)

	# New Game button
	var new_btn := Button.new()
	new_btn.text = "New Game"
	new_btn.custom_minimum_size = Vector2(200, 40)
	new_btn.pressed.connect(_on_new_game)
	if UITheme: UITheme.style_button(new_btn)
	center.add_child(new_btn)

	# Continue button
	var cont_btn := Button.new()
	cont_btn.text = "Continue"
	cont_btn.custom_minimum_size = Vector2(200, 40)
	cont_btn.disabled = not SaveManager.has_save(0)
	cont_btn.pressed.connect(_on_continue)
	if UITheme: UITheme.style_button(cont_btn)
	center.add_child(cont_btn)

	# Version
	var ver := Label.new()
	ver.text = "Built with Yume Framework"
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ver.add_theme_font_size_override("font_size", 11)
	ver.add_theme_color_override("font_color", Color(0.3, 0.3, 0.3))
	center.add_child(ver)

	# Focus the first button for keyboard navigation
	new_btn.grab_focus()

	# Store buttons for keyboard navigation
	_buttons = [new_btn, cont_btn]
	_selected = 0

var _buttons: Array = []
var _selected: int = 0

func _unhandled_input(event: InputEvent) -> void:
	if not is_active:
		return
	if event.is_action_pressed("move_down") or event.is_action_pressed("ui_down"):
		_selected = min(_selected + 1, _buttons.size() - 1)
		if _selected < _buttons.size():
			_buttons[_selected].grab_focus()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_up") or event.is_action_pressed("ui_up"):
		_selected = max(_selected - 1, 0)
		if _selected < _buttons.size():
			_buttons[_selected].grab_focus()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("interact") or event.is_action_pressed("ui_accept"):
		if _selected < _buttons.size() and not _buttons[_selected].disabled:
			_buttons[_selected].pressed.emit()
		get_viewport().set_input_as_handled()

func _on_new_game() -> void:
	is_active = false
	visible = false

	# Play prologue narration if available
	var prologue = _create_prologue()
	if prologue and prologue.steps.size() > 0:
		prologue.prologue_finished.connect(func():
			_start_gameplay()
		)
		prologue.start()
	else:
		# No prologue — start directly (StoryManager will fire "start" on location enter)
		_start_gameplay_no_prologue()


func _start_gameplay() -> void:
	# Title screen is the SINGLE controller of game start:
	# 1. Skip prologue narration phase (already shown by prologue_screen)
	if has_node("/root/StoryManager"):
		StoryManager.skip_prologue()

	# 2. Unpause
	get_tree().paused = false
	await get_tree().process_frame

	# 3. Load the starting location
	if LocationManager.location_root == null:
		LocationManager._find_location_root()
	if GameManager.current_location_id != "":
		LocationManager.load_location(GameManager.current_location_id)
	# StoryManager.on_location_entered() fires automatically from load_location
	# → triggers "prologue_gameplay" phase (Zidane + tutorial)


func _start_gameplay_no_prologue() -> void:
	# No prologue screen — let StoryManager handle "start" trigger normally
	get_tree().paused = false
	await get_tree().process_frame
	if LocationManager.location_root == null:
		LocationManager._find_location_root()
	if GameManager.current_location_id != "":
		LocationManager.load_location(GameManager.current_location_id)
	# Fire "start" trigger manually since StoryManager no longer auto-fires
	await get_tree().process_frame
	if has_node("/root/StoryManager"):
		StoryManager._check_trigger("start", "")


func _create_prologue():
	var script_path := "res://scripts/ui/prologue_screen.gd"
	if not FileAccess.file_exists(script_path):
		return null
	var scr = load(script_path)
	if scr == null:
		return null
	var prologue = CanvasLayer.new()
	prologue.set_script(scr)
	get_tree().current_scene.add_child(prologue)
	return prologue

func _on_continue() -> void:
	is_active = false
	get_tree().paused = false
	visible = false
	# Load most recent save
	for slot in range(2, -1, -1):
		if SaveManager.has_save(slot):
			SaveManager.load_game(slot)
			return

func show_title() -> void:
	is_active = true
	visible = true
	get_tree().paused = true

func _get_game_title() -> String:
	var file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		if data:
			return data.get("title", "RPG Game")
	return "RPG Game"
