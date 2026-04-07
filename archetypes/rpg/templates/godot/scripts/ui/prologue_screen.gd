extends CanvasLayer

## Prologue Screen — visual narration before gameplay.
## Each step can have a "visual" field defining bg_color, particles, and silhouettes.
## Reads from game_state.json prologue phase.

var steps: Array = []
var current_step: int = 0
var is_active: bool = false

var bg: ColorRect
var scene_container: Control
var text_panel: PanelContainer
var label: RichTextLabel
var speaker_label: Label
var particles_node: CPUParticles2D
var prompt_label: Label

signal prologue_finished

func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 15

	var file := FileAccess.open("res://data/game_state.json", FileAccess.READ)
	if not file:
		return
	var data = JSON.parse_string(file.get_as_text())
	if data == null:
		return

	var phases = data.get("phases", [])
	if phases.size() == 0:
		return
	var first_phase = phases[0]
	if str(first_phase.get("trigger", "")) != "start":
		return

	var all_steps = first_phase.get("cutscene", [])
	for s in all_steps:
		var action = str(s.get("action", ""))
		if action in ["dialogue", "wait"]:
			var text = str(s.get("text", ""))
			if text.begins_with("[Tutorial") or text.begins_with("[Tip"):
				break
			steps.append(s)


func start() -> void:
	if steps.size() == 0:
		done()
		return
	is_active = true
	visible = true
	current_step = 0
	_build_ui()
	_apply_visuals_for_step(0)
	_show_step()


func _build_ui() -> void:
	# Background
	bg = ColorRect.new()
	bg.color = Color(0.02, 0.02, 0.08, 1.0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# Scene container for visual elements (silhouettes, effects)
	scene_container = Control.new()
	scene_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(scene_container)

	# Text panel at bottom (like a visual novel)
	text_panel = PanelContainer.new()
	text_panel.position = Vector2(40, 480)
	text_panel.size = Vector2(1200, 200)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.75)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.content_margin_left = 30
	style.content_margin_right = 30
	style.content_margin_top = 15
	style.content_margin_bottom = 15
	text_panel.add_theme_stylebox_override("panel", style)
	add_child(text_panel)

	var vbox := VBoxContainer.new()
	text_panel.add_child(vbox)

	speaker_label = Label.new()
	speaker_label.add_theme_font_size_override("font_size", 20)
	speaker_label.add_theme_color_override("font_color", Color(0.9, 0.75, 0.4))
	vbox.add_child(speaker_label)

	label = RichTextLabel.new()
	label.bbcode_enabled = true
	label.scroll_active = false
	label.fit_content = true
	label.add_theme_font_size_override("normal_font_size", 17)
	label.add_theme_color_override("default_color", Color(0.9, 0.9, 0.95))
	label.custom_minimum_size = Vector2(1100, 100)
	vbox.add_child(label)

	# "Press SPACE" prompt
	prompt_label = Label.new()
	prompt_label.text = "▼"
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	prompt_label.add_theme_font_size_override("font_size", 16)
	prompt_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7, 0.7))
	prompt_label.position = Vector2(1180, 660)
	add_child(prompt_label)


func _apply_visuals_for_step(idx: int) -> void:
	if idx >= steps.size():
		return

	var step = steps[idx]
	var text = str(step.get("text", "")).to_lower()

	# Auto-detect visual scene from text content
	var target_bg := Color(0.02, 0.02, 0.08)
	var particle_type := ""
	var silhouettes: Array = []

	if "lightning" in text or "storm" in text or "ocean" in text or "waves" in text:
		target_bg = Color(0.03, 0.03, 0.12)  # dark stormy blue
		particle_type = "rain"
	elif "small girl" in text or "cloak" in text or "boat" in text:
		target_bg = Color(0.04, 0.04, 0.14)  # deep ocean
		particle_type = "rain"
		silhouettes = [{"type": "boat", "x": 640, "y": 280}]
	elif "gravity" in text or "weightless" in text or "catapult" in text:
		target_bg = Color(0.08, 0.08, 0.2)  # flash
		particle_type = "rain"
	elif "woke" in text or "gasp" in text or "morning sun" in text:
		target_bg = Color(0.15, 0.12, 0.05)  # warm golden morning
		particle_type = "sparkles"
	elif "kingdom" in text or "alexandria" in text or "crystal" in text or "waterfall" in text:
		target_bg = Color(0.12, 0.1, 0.04)  # golden kingdom
		particle_type = "sparkles"
		silhouettes = [{"type": "castle", "x": 640, "y": 250}]
	elif "dream" in text or "vision" in text or "who was" in text:
		target_bg = Color(0.1, 0.08, 0.06)  # warm interior
		silhouettes = [{"type": "character", "x": 640, "y": 300, "color": Color(1.0, 0.6, 0.2)}]
	elif "tantalus" in text or "theater" in text or "tonight" in text or "celebrating" in text:
		target_bg = Color(0.08, 0.06, 0.12)  # evening purple
		particle_type = "sparkles"
	elif "meanwhile" in text or "castle gates" in text:
		target_bg = Color(0.06, 0.06, 0.1)  # dusk transition
	elif "forge" in text or "anvil" in text or "fire" in text or "ember" in text:
		target_bg = Color(0.12, 0.06, 0.02)  # forge warm
		particle_type = "embers"
	elif "frost" in text or "ice" in text or "freeze" in text or "winter" in text or "empire" in text:
		target_bg = Color(0.05, 0.08, 0.15)  # cold blue
		particle_type = "snow"

	# Tween background color
	var tween = create_tween()
	tween.tween_property(bg, "color", target_bg, 0.8)

	# Update particles
	_set_particles(particle_type)

	# Update silhouettes
	_clear_silhouettes()
	for s in silhouettes:
		_add_silhouette(s)


func _set_particles(ptype: String) -> void:
	if particles_node:
		particles_node.queue_free()
		particles_node = null

	if ptype == "":
		return

	particles_node = CPUParticles2D.new()
	particles_node.position = Vector2(640, 0)
	particles_node.amount = 60
	particles_node.lifetime = 3.0
	particles_node.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	particles_node.emission_rect_extents = Vector2(700, 10)

	match ptype:
		"rain":
			particles_node.direction = Vector2(0.2, 1)
			particles_node.gravity = Vector2(0, 400)
			particles_node.initial_velocity_min = 200
			particles_node.initial_velocity_max = 350
			particles_node.scale_amount_min = 0.5
			particles_node.scale_amount_max = 1.5
			particles_node.color = Color(0.5, 0.55, 0.7, 0.4)
		"snow":
			particles_node.direction = Vector2(0.1, 1)
			particles_node.gravity = Vector2(0, 50)
			particles_node.initial_velocity_min = 20
			particles_node.initial_velocity_max = 60
			particles_node.scale_amount_min = 1.0
			particles_node.scale_amount_max = 3.0
			particles_node.color = Color(0.8, 0.85, 0.95, 0.5)
		"sparkles":
			particles_node.direction = Vector2(0, -1)
			particles_node.gravity = Vector2(0, -20)
			particles_node.initial_velocity_min = 10
			particles_node.initial_velocity_max = 40
			particles_node.scale_amount_min = 1.0
			particles_node.scale_amount_max = 2.5
			particles_node.color = Color(1.0, 0.9, 0.5, 0.4)
			particles_node.position.y = 450
		"embers":
			particles_node.direction = Vector2(0, -1)
			particles_node.gravity = Vector2(0, -30)
			particles_node.initial_velocity_min = 30
			particles_node.initial_velocity_max = 80
			particles_node.scale_amount_min = 1.0
			particles_node.scale_amount_max = 2.0
			particles_node.color = Color(0.9, 0.4, 0.1, 0.5)
			particles_node.position.y = 450

	scene_container.add_child(particles_node)


func _clear_silhouettes() -> void:
	for child in scene_container.get_children():
		if child != particles_node:
			child.queue_free()


func _add_silhouette(data: Dictionary) -> void:
	var stype = str(data.get("type", ""))
	var sx = data.get("x", 640)
	var sy = data.get("y", 300)
	var scolor = data.get("color", Color(0.15, 0.15, 0.2))

	match stype:
		"boat":
			# Simple boat shape
			var boat := ColorRect.new()
			boat.color = Color(0.2, 0.15, 0.1, 0.6)
			boat.size = Vector2(120, 30)
			boat.position = Vector2(sx - 60, sy)
			scene_container.add_child(boat)
			# Small figure on boat
			var figure := ColorRect.new()
			figure.color = Color(0.3, 0.25, 0.2, 0.7)
			figure.size = Vector2(15, 35)
			figure.position = Vector2(sx - 8, sy - 35)
			scene_container.add_child(figure)

		"castle":
			# Castle silhouette
			var base := ColorRect.new()
			base.color = Color(0.18, 0.15, 0.1, 0.5)
			base.size = Vector2(300, 120)
			base.position = Vector2(sx - 150, sy + 30)
			scene_container.add_child(base)
			# Tower
			var tower := ColorRect.new()
			tower.color = Color(0.2, 0.17, 0.12, 0.5)
			tower.size = Vector2(40, 180)
			tower.position = Vector2(sx - 20, sy - 150)
			scene_container.add_child(tower)
			# Crystal spire
			var spire := ColorRect.new()
			spire.color = Color(0.4, 0.5, 0.8, 0.4)
			spire.size = Vector2(12, 100)
			spire.position = Vector2(sx - 6, sy - 240)
			scene_container.add_child(spire)

		"character":
			# Character silhouette (head + body)
			var body := ColorRect.new()
			body.color = scolor * Color(1, 1, 1, 0.5)
			body.size = Vector2(30, 50)
			body.position = Vector2(sx - 15, sy)
			scene_container.add_child(body)
			var head := ColorRect.new()
			head.color = scolor * Color(1, 1, 1, 0.6)
			head.size = Vector2(20, 20)
			head.position = Vector2(sx - 10, sy - 22)
			scene_container.add_child(head)


func _show_step() -> void:
	if current_step >= steps.size():
		done()
		return

	var step = steps[current_step]
	var action = str(step.get("action", ""))

	if action == "wait":
		var dur = step.get("duration", 0.5)
		prompt_label.visible = false
		await get_tree().create_timer(dur).timeout
		current_step += 1
		_show_step()
		return

	# Apply visuals for this step
	_apply_visuals_for_step(current_step)

	var speaker = step.get("speaker")
	var text = str(step.get("text", ""))

	if speaker != null and str(speaker) != "":
		speaker_label.text = str(speaker)
		speaker_label.visible = true
	else:
		speaker_label.text = ""
		speaker_label.visible = false

	label.text = text
	prompt_label.visible = true


func _unhandled_input(event: InputEvent) -> void:
	if not is_active:
		return
	if event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_select"):
		get_viewport().set_input_as_handled()
		current_step += 1
		if current_step >= steps.size():
			done()
		else:
			_show_step()


func done() -> void:
	is_active = false
	# Fade out
	var tween = create_tween()
	tween.tween_property(bg, "color", Color(0, 0, 0, 1), 0.5)
	await tween.finished
	visible = false
	for child in get_children():
		child.queue_free()
	prologue_finished.emit()
