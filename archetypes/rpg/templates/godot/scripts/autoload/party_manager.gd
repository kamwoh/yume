extends Node

var party: Array = []
var all_characters: Dictionary = {}

func _ready() -> void:
	var file := FileAccess.open("res://data/characters.json", FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		if data is Array:
			for c in data:
				all_characters[c["id"]] = c

	# Initialize starting party
	var starting := ["zidane", "vivi", "steiner"] as Array
	for char_id in starting:
		if all_characters.has(char_id):
			var c = all_characters[char_id]
			var stats = c.get("stats", {})
			var debug: bool = GameManager.debug_mode
			var str_val: int = stats.get("strength", 10)
			var mag_val: int = stats.get("magic", 8)
			var spd_val: int = stats.get("speed", 9)
			if debug:
				str_val = 999
				mag_val = 999
				spd_val = 99
			party.append({
				"id": char_id,
				"name": c.get("name", char_id),
				"class": c.get("character_class", ""),
				"level": stats.get("level", 1),
				"max_hp": stats.get("hp", 100),
				"hp": stats.get("hp", 100),
				"max_mp": stats.get("mp", 50),
				"mp": stats.get("mp", 50),
				"strength": str_val,
				"magic": mag_val,
				"defense": stats.get("defense", 7),
				"spirit": stats.get("spirit", 6),
				"speed": spd_val,
				"xp": 0,
			})

func join_party(char_id: String) -> void:
	"""Add a character to the party at runtime (story event)."""
	# Check not already in party
	for m in party:
		if m["id"] == char_id:
			return
	# Find in all_characters
	if not all_characters.has(char_id):
		push_warning("Character not found: " + char_id)
		return
	var c = all_characters[char_id]
	var stats = c.get("stats", {})
	var debug: bool = GameManager.debug_mode if GameManager else false
	var str_val: int = stats.get("strength", 10)
	var mag_val: int = stats.get("magic", 8)
	var spd_val: int = stats.get("speed", 9)
	if debug:
		str_val = 999
		mag_val = 999
		spd_val = 99
	party.append({
		"id": char_id,
		"name": c.get("name", char_id),
		"class": c.get("character_class", ""),
		"level": stats.get("level", 1),
		"max_hp": stats.get("hp", 100),
		"hp": stats.get("hp", 100),
		"max_mp": stats.get("mp", 50),
		"mp": stats.get("mp", 50),
		"strength": str_val,
		"magic": mag_val,
		"defense": stats.get("defense", 7),
		"spirit": stats.get("spirit", 6),
		"speed": spd_val,
		"xp": 0,
	})
	print("[Party] " + c.get("name", char_id) + " joined the party!")

func get_member(char_id: String) -> Dictionary:
	for m in party:
		if m["id"] == char_id:
			return m
	return {}

func heal_member(char_id: String, amount: int) -> void:
	for m in party:
		if m["id"] == char_id:
			m["hp"] = min(m["hp"] + amount, m["max_hp"])
			return

func heal_all() -> void:
	for m in party:
		m["hp"] = m["max_hp"]
		m["mp"] = m["max_mp"]

func gain_xp(amount: int) -> void:
	for m in party:
		m["xp"] += amount
		var needed: int = int(100 * pow(1.5, m["level"] - 1))
		while m["xp"] >= needed:
			m["xp"] -= needed
			m["level"] += 1
			m["max_hp"] += 10
			m["max_mp"] += 5
			m["strength"] += 1
			m["magic"] += 1
			m["defense"] += 1
			m["hp"] = m["max_hp"]
			m["mp"] = m["max_mp"]
			needed = int(100 * pow(1.5, m["level"] - 1))
			print(m["name"], " reached level ", m["level"], "!")
