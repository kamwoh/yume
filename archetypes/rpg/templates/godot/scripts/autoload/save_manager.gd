extends Node

const SAVE_PATH := "user://save_%d.json"

func save_game(slot: int) -> void:
	var player_pos := Vector2.ZERO
	var player = get_tree().current_scene.get_node_or_null("Player")
	if player:
		player_pos = player.position
	var data := {
		"location": GameManager.current_location_id,
		"player_x": player_pos.x,
		"player_y": player_pos.y,
		"gil": GameManager.gil,
		"flags": GameManager.flags,
		"party": PartyManager.party,
		"inventory": InventoryManager.items,
		"completed_quests": QuestManager.completed_quests,
		"active_quests": QuestManager.active_quests,
		"story": StoryManager.get_save_data(),
	}
	var file := FileAccess.open(SAVE_PATH % slot, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))
		print("Game saved to slot ", slot)

func load_game(slot: int) -> void:
	var file := FileAccess.open(SAVE_PATH % slot, FileAccess.READ)
	if not file:
		push_warning("No save in slot ", slot)
		return
	var data = JSON.parse_string(file.get_as_text())
	if data == null:
		return

	GameManager.gil = data.get("gil", 0)
	GameManager.flags = data.get("flags", {})
	PartyManager.party = data.get("party", [])
	InventoryManager.items = data.get("inventory", [])
	QuestManager.completed_quests = data.get("completed_quests", [])
	QuestManager.active_quests = data.get("active_quests", {})
	StoryManager.load_save_data(data.get("story", {}))
	var loc: String = data.get("location", "")
	print("Game loaded from slot ", slot, " — location: ", loc)
	# Load the saved location
	if loc != "":
		await LocationManager.load_location(loc)
		# Restore player position
		await get_tree().create_timer(0.1).timeout
		var player = get_tree().current_scene.get_node_or_null("Player")
		if player:
			player.position = Vector2(data.get("player_x", 0), data.get("player_y", 100))

func has_save(slot: int) -> bool:
	return FileAccess.file_exists(SAVE_PATH % slot)
