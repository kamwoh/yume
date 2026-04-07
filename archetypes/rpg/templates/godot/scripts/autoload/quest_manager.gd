extends Node

signal quest_started(quest_id: String)
signal quest_step_completed(quest_id: String, step: int)
signal quest_completed(quest_id: String)
signal objective_changed(text: String)

var quest_db: Dictionary = {}
var active_quests: Dictionary = {}
var completed_quests: Array = []

func _ready() -> void:
	var file := FileAccess.open("res://data/quests.json", FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		if data is Array:
			for q in data:
				quest_db[q["id"]] = q

	# Auto-start first main quest
	for qid in quest_db:
		var q = quest_db[qid]
		if q.get("quest_type") == "main" and q.get("prerequisite", "") == "":
			start_quest(qid)
			break

	# Emit initial objective after a short delay (ensure HUD is ready)
	await get_tree().create_timer(1.0).timeout
	_update_objective()

func start_quest(quest_id: String) -> void:
	if active_quests.has(quest_id) or quest_id in completed_quests:
		return
	if not quest_db.has(quest_id):
		return
	var q = quest_db[quest_id]
	var prereq_val = q.get("prerequisite")
	var prereq: String = str(prereq_val) if prereq_val != null else ""
	if prereq != "" and not prereq in completed_quests:
		return
	active_quests[quest_id] = {"current_step": 0}
	quest_started.emit(quest_id)
	_update_objective()
	print("[Quest] Started: ", q.get("name", quest_id))

func is_quest_active(quest_id: String) -> bool:
	return active_quests.has(quest_id)

func is_quest_complete(quest_id: String) -> bool:
	return quest_id in completed_quests

func on_trigger(trigger_type: String, target_id: String) -> void:
	var trigger: String = trigger_type + ":" + target_id
	var to_complete: Array = []
	for qid in active_quests:
		var q = quest_db[qid]
		var steps: Array = q.get("steps", [])
		var step_idx: int = active_quests[qid]["current_step"]
		if step_idx < steps.size():
			if steps[step_idx].get("trigger") == trigger:
				active_quests[qid]["current_step"] += 1
				quest_step_completed.emit(qid, active_quests[qid]["current_step"])
				print("[Quest] Step complete: ", steps[step_idx].get("description", ""))
				if active_quests[qid]["current_step"] >= steps.size():
					to_complete.append(qid)
				else:
					_update_objective()
	for qid in to_complete:
		_complete_quest(qid)

func _complete_quest(quest_id: String) -> void:
	active_quests.erase(quest_id)
	completed_quests.append(quest_id)
	var q = quest_db[quest_id]

	# Awards
	var gil_reward: int = q.get("gil_reward", 0)
	var xp_reward: int = q.get("xp_reward", 0)
	if gil_reward > 0:
		GameManager.add_gil(gil_reward)
	if xp_reward > 0:
		PartyManager.gain_xp(xp_reward)
	for item_id in q.get("rewards", []):
		InventoryManager.add_item(item_id)

	quest_completed.emit(quest_id)
	print("[Quest] Complete: ", q.get("name", quest_id), " (+", xp_reward, " XP, +", gil_reward, " Gil)")

	# Auto-start next quests whose prerequisite is now met
	for qid in quest_db:
		var next_q = quest_db[qid]
		if next_q.get("prerequisite", "") == quest_id:
			start_quest(qid)

	_update_objective()

func get_current_objective() -> String:
	for qid in active_quests:
		var q = quest_db[qid]
		var steps: Array = q.get("steps", [])
		var step_idx: int = active_quests[qid]["current_step"]
		if step_idx < steps.size():
			return q.get("name", "") + ": " + steps[step_idx].get("description", "")
	if completed_quests.size() > 0 and active_quests.size() == 0:
		return "All quests complete!"
	return ""

func _update_objective() -> void:
	objective_changed.emit(get_current_objective())

func get_pending_boss_fight() -> String:
	"""Check if the current quest step requires defeating a boss. Returns enemy_id or empty."""
	for qid in active_quests:
		var q = quest_db[qid]
		var steps: Array = q.get("steps", [])
		var step_idx: int = active_quests[qid]["current_step"]
		if step_idx < steps.size():
			var trigger: String = steps[step_idx].get("trigger", "")
			if trigger.begins_with("defeat:"):
				return trigger.substr(7)  # return enemy_id
	return ""
