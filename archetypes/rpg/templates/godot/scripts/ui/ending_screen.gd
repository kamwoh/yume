extends CanvasLayer

# Ending — triggered after final boss. Shows ending cutscene, then credits, then title.

func _ready() -> void:
	layer = 40
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS

func show_ending() -> void:
	visible = true
	get_tree().paused = true

	# Build ending UI
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 1)
	add_child(bg)

	# Play ending sequence
	await get_tree().create_timer(1.0).timeout
	await _show_text("The Crystal World collapses around them...", 3.0)
	await _show_text("But in his final act, Kuja uses his remaining power\nto teleport the party to safety.", 4.0)
	await _show_text("Months later...\nAlexandria Castle, during a performance of\n'I Want to Be Your Canary'", 4.0)
	await _show_text("A familiar figure appears on stage...", 2.0)
	await _show_text("Zidane pulls back his hood, revealing himself alive.", 3.0)
	await _show_text("Garnet runs to him, tears streaming.\nThey embrace as the crowd cheers.", 4.0)
	await _show_text("\"You're not alone.\"\n\"I never was.\"", 4.0)

	# Credits
	await get_tree().create_timer(2.0).timeout
	await _show_credits()

	# Return to title
	await get_tree().create_timer(2.0).timeout
	_return_to_title()

func _show_text(text: String, duration: float) -> void:
	var label := Label.new()
	label.text = text
	label.set_anchors_preset(Control.PRESET_CENTER)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(600, 100)
	if UITheme:
		label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE_HEADER)
		label.add_theme_color_override("font_color", UITheme.TEXT_COLOR)
	else:
		label.add_theme_font_size_override("font_size", 20)
		label.add_theme_color_override("font_color", Color.WHITE)

	# Fade in
	label.modulate.a = 0.0
	add_child(label)
	var tween := create_tween()
	tween.tween_property(label, "modulate:a", 1.0, 0.8)
	await tween.finished

	await get_tree().create_timer(duration).timeout

	# Fade out
	var tween2 := create_tween()
	tween2.tween_property(label, "modulate:a", 0.0, 0.8)
	await tween2.finished
	label.queue_free()

func _show_credits() -> void:
	var credits_text := """
— CREDITS —

Created with Yume Framework

Story: Final Fantasy IX (Square Enix)
Engine: Godot 4
Framework: Yume (夢)

Characters: Zidane, Garnet, Vivi, Steiner, Freya
Villains: Kuja, Brahne, Garland, Necron

"You're Not Alone"

Thank you for playing.
"""

	var label := Label.new()
	label.text = credits_text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	if UITheme:
		label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE_BODY)
		label.add_theme_color_override("font_color", UITheme.ACCENT)
	else:
		label.add_theme_font_size_override("font_size", 16)
		label.add_theme_color_override("font_color", Color(0.9, 0.75, 0.3))

	label.modulate.a = 0.0
	add_child(label)

	# Fade in
	var tween := create_tween()
	tween.tween_property(label, "modulate:a", 1.0, 1.5)
	await tween.finished

	# Hold for reading
	await get_tree().create_timer(8.0).timeout

	# Fade out
	var tween2 := create_tween()
	tween2.tween_property(label, "modulate:a", 0.0, 2.0)
	await tween2.finished
	label.queue_free()

func _return_to_title() -> void:
	# Clean up
	for child in get_children():
		child.queue_free()
	visible = false
	get_tree().paused = false

	# Reset and show title
	GameManager.flags.clear()
	var title_screen = get_tree().current_scene.get_node_or_null("TitleScreen")
	if title_screen:
		title_screen.show_title()
