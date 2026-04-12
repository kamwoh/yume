extends Node

## Inventory — agent carries items. Supports add, remove, count, has.
## Shared by player and NPC entities.

var items: Dictionary = {}  # item_id → count
var max_slots: int = 20


func add_item(item_id: String, count: int = 1) -> bool:
	if items.has(item_id):
		items[item_id] += count
	else:
		if items.size() >= max_slots:
			return false  # Full
		items[item_id] = count
	return true


func remove_item(item_id: String, count: int = 1) -> bool:
	if not items.has(item_id) or items[item_id] < count:
		return false
	items[item_id] -= count
	if items[item_id] <= 0:
		items.erase(item_id)
	return true


func has_item(item_id: String, count: int = 1) -> bool:
	return items.get(item_id, 0) >= count


func get_count(item_id: String) -> int:
	return items.get(item_id, 0)


func has_items(required: Array) -> bool:
	## Check if all items in [{item, count}] are available
	for req in required:
		if not has_item(str(req.get("item", "")), req.get("count", 1)):
			return false
	return true


func remove_items(required: Array) -> bool:
	## Remove all items — check first, remove atomically
	if not has_items(required):
		return false
	for req in required:
		remove_item(str(req.get("item", "")), req.get("count", 1))
	return true


func get_all() -> Dictionary:
	return items.duplicate()


func get_food_items() -> Array:
	## Return items that are food (can check item definitions)
	var food: Array = []
	for item_id in items:
		if item_id.begins_with("food_") or item_id == "cooked_food":
			food.append(item_id)
	return food


func get_tools() -> Array:
	var tools: Array = []
	for item_id in items:
		if item_id in ["axe", "pickaxe", "hoe"]:
			tools.append(item_id)
	return tools


func to_string_summary() -> String:
	var parts: Array = []
	for item_id in items:
		parts.append("%s:%d" % [item_id, items[item_id]])
	return ", ".join(parts) if parts.size() > 0 else "(empty)"
