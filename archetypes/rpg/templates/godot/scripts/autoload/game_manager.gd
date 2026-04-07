extends Node

var current_location_id: String = ""
var gil: int = 200
var flags: Dictionary = {}
var debug_mode: bool = false

func _ready() -> void:
	var file := FileAccess.open("res://data/progression.json", FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		if data:
			current_location_id = data.get("starting_location", "")
			var items: Array = data.get("starting_items", [])
			if items.size() > 0:
				gil = items.size() * 50
			else:
				gil = 200

func change_location(location_id: String) -> void:
	current_location_id = location_id
	LocationManager.load_location(location_id)

func set_flag(flag: String) -> void:
	flags[flag] = true

func has_flag(flag: String) -> bool:
	return flags.has(flag)

func add_gil(amount: int) -> void:
	gil += amount

func spend_gil(amount: int) -> bool:
	if gil >= amount:
		gil -= amount
		return true
	return false
