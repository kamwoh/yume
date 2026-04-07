extends Node

# Cutscene Manager — plays scripted sequences (camera, NPC movement, dialogue)
# Cutscenes are defined in location JSON under on_enter_events with type "cutscene"

signal cutscene_started
signal cutscene_ended

var is_playing: bool = false

func play_cutscene(steps: Array) -> void:
	if is_playing:
		return
	is_playing = true
	cutscene_started.emit()

	# Freeze player
	var player = get_tree().current_scene.get_node_or_null("Player")
	if player:
		player.can_move = false

	# Execute steps sequentially
	for step in steps:
		var action: String = step.get("action", "")
		match action:
			"dialogue":
				await _do_dialogue(step)
			"narration":
				await _do_narration(step)
			"wait":
				await _do_wait(step)
			"camera_to":
				await _do_camera_to(step)
			"camera_follow_player":
				await _do_camera_follow_player(step)
			"npc_walk":
				await _do_npc_walk(step)
			"npc_face":
				_do_npc_face(step)
			"sfx":
				_do_sfx(step)
			"set_flag":
				GameManager.set_flag(step.get("flag", ""))
			"join_party":
				var char_id: String = step.get("character_id", "")
				if char_id != "":
					PartyManager.join_party(char_id)
					await _do_dialogue({"speaker": "", "text": step.get("name", char_id) + " joined the party!"})
			"screen_shake":
				await _do_screen_shake(step)
			"fade_out":
				var fader = _get_fader()
				if fader:
					await fader.fade_out(step.get("duration", 0.3))
			"fade_in":
				var fader = _get_fader()
				if fader:
					await fader.fade_in(step.get("duration", 0.3))

	# Unfreeze player
	if player:
		player.can_move = true

	is_playing = false
	cutscene_ended.emit()

func _do_dialogue(step: Dictionary) -> void:
	var speaker: String = step.get("speaker", "")
	var text: String = step.get("text", "")
	DialogueManager.show_simple_message(speaker, text)
	# Wait for dialogue to end
	while DialogueManager.is_playing:
		await get_tree().process_frame

func _do_narration(step: Dictionary) -> void:
	var text: String = step.get("text", "")
	DialogueManager.show_simple_message("", text)
	while DialogueManager.is_playing:
		await get_tree().process_frame

func _do_wait(step: Dictionary) -> void:
	var duration: float = step.get("duration", 1.0)
	await get_tree().create_timer(duration).timeout

func _do_camera_to(step: Dictionary) -> void:
	var player = get_tree().current_scene.get_node_or_null("Player")
	if not player:
		return
	var cam = player.get_node_or_null("Camera2D")
	if not cam:
		return

	var layout = LocationManager.current_location_data.get("layout", {})
	var lw: float = layout.get("width", 900)
	var lh: float = layout.get("height", 700)
	var target_x: float = step.get("x", 0) - lw / 2
	var target_y: float = step.get("y", 0) - lh / 2 + 200
	var duration: float = step.get("duration", 1.0)

	# Disable camera follow, move to target
	cam.position_smoothing_enabled = false
	var global_target := Vector2(target_x, target_y)

	# Move camera via offset (since it's child of Player)
	var start_offset: Vector2 = cam.offset
	var needed_offset: Vector2 = global_target - player.position

	var tween := create_tween()
	tween.tween_property(cam, "offset", needed_offset, duration).set_ease(Tween.EASE_IN_OUT)
	await tween.finished

func _do_camera_follow_player(step: Dictionary) -> void:
	var player = get_tree().current_scene.get_node_or_null("Player")
	if not player:
		return
	var cam = player.get_node_or_null("Camera2D")
	if not cam:
		return

	var duration: float = step.get("duration", 0.5)
	var tween := create_tween()
	tween.tween_property(cam, "offset", Vector2.ZERO, duration).set_ease(Tween.EASE_IN_OUT)
	await tween.finished
	cam.position_smoothing_enabled = true

func _do_npc_walk(step: Dictionary) -> void:
	var npc_id: String = step.get("npc_id", "")
	var loc_root = get_tree().current_scene.get_node_or_null("LocationRoot")
	if not loc_root:
		return

	var npc_node: Node2D = null
	for child in loc_root.get_children():
		if child.name == "NPC_" + npc_id:
			npc_node = child as Node2D
			break

	if not npc_node:
		return

	var layout = LocationManager.current_location_data.get("layout", {})
	var lw: float = layout.get("width", 900)
	var lh: float = layout.get("height", 700)
	var target_x: float = step.get("to_x", 0) - lw / 2
	var target_y: float = step.get("to_y", 0) - lh / 2 + 200
	var speed: float = step.get("speed", 60)

	var target := Vector2(target_x, target_y)
	var distance: float = npc_node.position.distance_to(target)
	var duration: float = distance / max(speed, 1)

	var tween := create_tween()
	tween.tween_property(npc_node, "position", target, duration)
	await tween.finished

func _do_npc_face(step: Dictionary) -> void:
	# Placeholder — with real sprites this would change facing direction
	pass

func _do_sfx(step: Dictionary) -> void:
	var sfx_name: String = step.get("name", "")
	if sfx_name != "":
		AudioManager.play_sfx(sfx_name)

func _do_screen_shake(step: Dictionary) -> void:
	var player = get_tree().current_scene.get_node_or_null("Player")
	if not player:
		return
	var cam = player.get_node_or_null("Camera2D")
	if not cam:
		return

	var intensity: float = step.get("intensity", 5.0)
	var duration: float = step.get("duration", 0.3)
	var original_offset: Vector2 = cam.offset
	var elapsed: float = 0.0

	while elapsed < duration:
		cam.offset = original_offset + Vector2(randf_range(-intensity, intensity), randf_range(-intensity, intensity))
		await get_tree().process_frame
		elapsed += get_process_delta_time()

	cam.offset = original_offset

func _get_fader():
	var main = get_tree().current_scene
	if main:
		return main.get_node_or_null("UI/ScreenFader")
	return null
