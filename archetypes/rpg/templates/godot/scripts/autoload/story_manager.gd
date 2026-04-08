extends Node

## Story Manager — centralized story flow control.
## Reads game_state.json and fires phases based on triggers.
## Player explores freely; story advances when triggers match.

signal phase_changed(phase_id: String)
signal story_event_started
signal story_event_ended

var phases: Array = []
var phase_map: Dictionary = {}  # id -> phase index
var current_phase_index: int = 0
var current_phase_id: String = ""
var is_processing: bool = false

func _s(val) -> String:
	if val == null: return ""
	return str(val)

func _ready() -> void:
	var file := FileAccess.open("res://data/game_state.json", FileAccess.READ)
	if not file:
		push_warning("No game_state.json found — story manager inactive")
		return

	var data = JSON.parse_string(file.get_as_text())
	if data == null:
		push_error("Failed to parse game_state.json")
		return

	phases = data.get("phases", [])
	for i in range(phases.size()):
		phase_map[_s(phases[i].get("id"))] = i

	current_phase_id = _s(data.get("starting_phase"))
	if phase_map.has(current_phase_id):
		current_phase_index = phase_map[current_phase_id]

	# Don't auto-fire here — title_screen controls the flow:
	# 1. prologue_screen plays narration
	# 2. skip_prologue() advances past narration phase
	# 3. title_screen loads location → on_location_entered fires gameplay phase


var prologue_handled: bool = false


## Called by title_screen after prologue_screen finishes — skip the narration phase
func skip_prologue() -> void:
	prologue_handled = true
	if current_phase_index < phases.size():
		var phase: Dictionary = phases[current_phase_index]
		if _s(phase.get("trigger")) == "start":
			# Apply quest/flag effects but skip the cutscene (already shown)
			var quest = phase.get("quest")
			if quest is Dictionary:
				var q_start = quest.get("start")
				if q_start != null:
					QuestManager.start_quest(_s(q_start))
			var flag_list = phase.get("sets_flags", [])
			if flag_list is Array:
				for flag in flag_list:
					GameManager.set_flag(_s(flag))
			# Advance to next phase (the gameplay phase)
			var next_id = _s(phase.get("next"))
			if next_id != "" and phase_map.has(next_id):
				current_phase_index = phase_map[next_id]
				current_phase_id = next_id
			else:
				current_phase_index += 1


func on_location_entered(location_id: String) -> void:
	_check_trigger("reach", location_id)


func on_boss_defeated(enemy_id: String) -> void:
	_check_trigger("defeat", enemy_id)


func _check_trigger(trigger_type: String, target: String) -> void:
	if is_processing:
		return
	if current_phase_index >= phases.size():
		return

	var phase: Dictionary = phases[current_phase_index]
	var trigger = _s(phase.get("trigger"))

	var matches: bool = false
	if trigger == "start" and trigger_type == "start":
		matches = true
	elif trigger_type == "reach" and trigger == "reach:" + target:
		matches = true
	elif trigger_type == "defeat" and trigger == "defeat:" + target:
		matches = true

	if matches:
		await _fire_phase(phase)


func _fire_phase(phase: Dictionary) -> void:
	is_processing = true
	var phase_id = _s(phase.get("id"))
	current_phase_id = phase_id
	story_event_started.emit()
	phase_changed.emit(phase_id)

	var player = get_tree().current_scene.get_node_or_null("Player")
	if player:
		player.can_move = false

	# Add party members
	var adds = phase.get("adds_party", [])
	if adds is Array:
		for char_id in adds:
			PartyManager.join_party(_s(char_id))

	# Set flags
	var flag_list = phase.get("sets_flags", [])
	if flag_list is Array:
		for flag in flag_list:
			GameManager.set_flag(_s(flag))

	# Unlock exits
	var unlocks = phase.get("unlocks_exits", [])
	if unlocks is Array:
		for unlock in unlocks:
			var from_loc = _s(unlock.get("from"))
			var to_loc = _s(unlock.get("to"))
			if from_loc != "" and to_loc != "":
				_unlock_exit(from_loc, to_loc)

	# Quest updates
	var quest = phase.get("quest")
	if quest is Dictionary:
		var q_start = quest.get("start")
		if q_start != null:
			QuestManager.start_quest(_s(q_start))
		var q_progress = quest.get("progress")
		if q_progress != null:
			QuestManager.on_trigger("reach", GameManager.current_location_id)
		var q_complete = quest.get("complete")
		if q_complete != null:
			_force_complete_quest(_s(q_complete))

	# Play cutscene
	var cutscene_steps = phase.get("cutscene", [])
	if cutscene_steps is Array and cutscene_steps.size() > 0:
		await get_tree().create_timer(0.3).timeout
		await CutsceneManager.play_cutscene(cutscene_steps)

	# Start boss fight if phase defines one
	var boss_id = phase.get("boss")
	if boss_id != null and _s(boss_id) != "":
		var enemy_id: String = _s(boss_id)
		# Find boss enemy IDs from location encounters, or use directly
		var loc_data = LocationManager.current_location_data
		var boss_enemies: Array = [enemy_id]
		if loc_data:
			for enc in loc_data.get("encounters", []):
				if enc.get("is_boss", false):
					boss_enemies = enc.get("enemies", [enemy_id])
					break
		# Start the battle — player fights the boss
		await get_tree().create_timer(0.5).timeout
		LocationManager.start_encounter(boss_enemies)
		# Wait for battle to end
		await BattleManager.battle_ended
		# Boss defeat trigger fires automatically via BattleManager → on_boss_defeated

	# Unfreeze player
	if player:
		player.can_move = true

	# Advance to next phase
	var next_id = _s(phase.get("next"))
	if next_id != "" and phase_map.has(next_id):
		current_phase_index = phase_map[next_id]
		current_phase_id = next_id
	else:
		current_phase_index += 1

	is_processing = false
	story_event_ended.emit()

	# Check if NEXT phase triggers immediately
	await get_tree().process_frame
	if current_phase_index < phases.size():
		var next_phase: Dictionary = phases[current_phase_index]
		var next_trigger = _s(next_phase.get("trigger"))
		if next_trigger == "reach:" + GameManager.current_location_id:
			_check_trigger("reach", GameManager.current_location_id)


func _unlock_exit(from_loc: String, to_loc: String) -> void:
	var path := "res://data/locations/" + from_loc + ".json"
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return
	var data = JSON.parse_string(file.get_as_text())
	if data == null:
		return
	var exits = data.get("exits", [])
	if exits is Array:
		for exit_d in exits:
			if _s(exit_d.get("target")) == to_loc:
				var req_flag = _s(exit_d.get("requires_flag"))
				if req_flag != "":
					GameManager.set_flag(req_flag)


func _force_complete_quest(quest_id: String) -> void:
	if not QuestManager.is_quest_active(quest_id):
		return
	var quest_data = null
	for q in QuestManager.all_quests:
		if _s(q.get("id")) == quest_id:
			quest_data = q
			break
	if quest_data:
		for step in quest_data.get("steps", []):
			var trigger = _s(step.get("trigger"))
			var parts = trigger.split(":")
			if parts.size() >= 2:
				QuestManager.on_trigger(parts[0], parts[1])


func get_save_data() -> Dictionary:
	return {
		"current_phase_id": current_phase_id,
		"current_phase_index": current_phase_index,
	}

func load_save_data(data: Dictionary) -> void:
	current_phase_id = _s(data.get("current_phase_id"))
	current_phase_index = int(data.get("current_phase_index", 0))
