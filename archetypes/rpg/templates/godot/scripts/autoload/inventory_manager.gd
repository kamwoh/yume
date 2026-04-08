extends Node

var items: Array = []  # [{"id": "potion", "qty": 3}, ...]
var item_db: Dictionary = {}

func _ready() -> void:
	# Load item database
	var file := FileAccess.open("res://data/items.json", FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		if data is Array:
			for item in data:
				item_db[item["id"]] = item

	# Add starting items from progression.json (NOT hardcoded)
	var prog_file := FileAccess.open("res://data/progression.json", FileAccess.READ)
	if prog_file:
		var prog = JSON.parse_string(prog_file.get_as_text())
		if prog is Dictionary:
			var starting = prog.get("starting_items", [])
			if starting is Array:
				for item_id in starting:
					add_item(str(item_id))

func add_item(item_id: String, qty: int = 1) -> void:
	for slot in items:
		if slot["id"] == item_id:
			slot["qty"] += qty
			return
	items.append({"id": item_id, "qty": qty})

func remove_item(item_id: String, qty: int = 1) -> bool:
	for i in range(items.size()):
		if items[i]["id"] == item_id:
			items[i]["qty"] -= qty
			if items[i]["qty"] <= 0:
				items.remove_at(i)
			return true
	return false

func has_item(item_id: String, qty: int = 1) -> bool:
	for slot in items:
		if slot["id"] == item_id and slot["qty"] >= qty:
			return true
	return false

func use_item(item_id: String, target_id: String) -> bool:
	if not has_item(item_id):
		return false
	var data = item_db.get(item_id, {})
	if data.get("item_type") == "consumable":
		var heal: int = data.get("heal_amount", 0)
		if heal > 0:
			PartyManager.heal_member(target_id, heal)
		remove_item(item_id)
		return true
	return false

func get_item_data(item_id: String) -> Dictionary:
	return item_db.get(item_id, {})
