extends Node

var dialogues: Dictionary = {}
var current_dialogue: Dictionary = {}
var current_line_index: int = 0
var is_playing: bool = false

signal dialogue_started
signal dialogue_line(speaker: String, text: String)
signal dialogue_ended

func _ready() -> void:
	var file := FileAccess.open("res://data/dialogues.json", FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		if data is Array:
			for d in data:
				dialogues[d["id"]] = d

func start_dialogue(dialogue_id: String) -> void:
	if is_playing:
		return
	if not dialogues.has(dialogue_id):
		push_warning("Dialogue not found: " + dialogue_id)
		return

	current_dialogue = dialogues[dialogue_id]
	current_line_index = 0
	is_playing = true

	# Freeze player
	var player = get_tree().current_scene.get_node_or_null("Player")
	if player:
		player.can_move = false

	dialogue_started.emit()
	_show_current_line()

func advance() -> void:
	if not is_playing:
		return
	current_line_index += 1
	var lines: Array = current_dialogue.get("lines", [])
	if current_line_index < lines.size():
		_show_current_line()
	else:
		end_dialogue()

func _show_current_line() -> void:
	var lines: Array = current_dialogue.get("lines", [])
	if current_line_index < lines.size():
		var line = lines[current_line_index]
		dialogue_line.emit(line.get("speaker", ""), line.get("text", ""))

func end_dialogue() -> void:
	# Set flag if specified
	var flag: String = current_dialogue.get("sets_flag", "")
	if flag != "":
		GameManager.set_flag(flag)

	# Fire quest triggers for NPCs mentioned in dialogue
	var lines: Array = current_dialogue.get("lines", [])
	var speakers_triggered: Array = []
	for line in lines:
		var speaker: String = line.get("speaker", "").to_lower().replace(" ", "_")
		# Map common names to character IDs
		if speaker == "garnet_(dagger)" or speaker == "dagger":
			speaker = "garnet"
		if speaker == "adelbert_steiner":
			speaker = "steiner"
		if speaker != "" and speaker not in speakers_triggered:
			speakers_triggered.append(speaker)
			QuestManager.on_trigger("talk_to", speaker)

	is_playing = false
	current_dialogue = {}
	current_line_index = 0

	# Unfreeze player
	var player = get_tree().current_scene.get_node_or_null("Player")
	if player:
		player.can_move = true

	dialogue_ended.emit()

func show_simple_message(speaker: String, text: String) -> void:
	# Create a temporary one-line dialogue and play it through the normal system
	if is_playing:
		return
	var temp_dialogue: Dictionary = {
		"id": "_simple_msg",
		"lines": [{"speaker": speaker, "text": text}],
		"sets_flag": ""
	}
	current_dialogue = temp_dialogue
	current_line_index = 0
	is_playing = true

	var player = get_tree().current_scene.get_node_or_null("Player")
	if player:
		player.can_move = false

	dialogue_started.emit()
	_show_current_line()
