extends SceneTree

## Headless test runner — validates all game systems without rendering.
## Run: godot --headless --path . --script res://tests/test_runner.gd

var passed := 0
var failed := 0
var warnings := 0

func _ok(msg: String) -> void:
	passed += 1
	print("  ✓ ", msg)

func _fail(msg: String) -> void:
	failed += 1
	printerr("  ✗ ", msg)

func _warn(msg: String) -> void:
	warnings += 1
	print("  ⚠ ", msg)

func _init():
	print("\n=== Yume RPG Headless Test Runner ===\n")

	test_json_loading()
	test_location_data()
	test_character_data()
	test_enemy_data()
	test_item_data()
	test_quest_data()
	test_dialogue_data()
	test_progression_data()
	test_location_spawn_logic()
	test_battle_damage_formula()
	test_exit_connectivity()
	test_story_gating()
	test_treasure_density()
	test_party_join_chain()

	print("\n" + "=".repeat(50))
	print("RESULTS: %d passed, %d failed, %d warnings" % [passed, failed, warnings])
	print("=".repeat(50))

	if failed > 0:
		quit(1)
	else:
		quit(0)


func _load_json(path: String):
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return null
	var data = JSON.parse_string(file.get_as_text())
	return data


func test_json_loading():
	print("--- JSON Loading ---")
	var files := [
		"res://data/characters.json",
		"res://data/items.json",
		"res://data/enemies.json",
		"res://data/quests.json",
		"res://data/dialogues.json",
		"res://data/progression.json",
		"res://data/meta.json"
	]
	for f in files:
		var data = _load_json(f)
		if data != null:
			_ok("Loaded " + f)
		else:
			_fail("FAILED to load " + f)


func test_location_data():
	print("\n--- Location Data ---")
	var dir := DirAccess.open("res://data/locations/")
	if not dir:
		_fail("Cannot open locations directory")
		return

	var count := 0
	dir.list_dir_begin()
	var file := dir.get_next()
	while file != "":
		if file.ends_with(".json"):
			var data = _load_json("res://data/locations/" + file)
			if data == null:
				_fail("Invalid JSON: " + file)
			elif not data.has("id"):
				_fail("Missing 'id' field: " + file)
			elif not data.has("layout") and not data.has("connections"):
				_fail("Missing layout AND connections: " + file)
			else:
				count += 1
				# Check required fields
				var required := ["id", "name", "type", "description", "exits", "atmosphere"]
				for key in required:
					if not data.has(key):
						_warn(file + " missing field: " + key)
		file = dir.get_next()

	_ok("Validated %d location files" % count)


func test_character_data():
	print("\n--- Character Data ---")
	var chars = _load_json("res://data/characters.json")
	if chars == null:
		_fail("Cannot load characters.json")
		return

	for c in chars:
		var stats: Dictionary = c.get("stats", {})
		if stats.get("hp", 0) <= 0:
			_fail("Character '%s' has HP <= 0" % c.get("id", "?"))
		if stats.get("strength", 0) <= 0 and stats.get("magic", 0) <= 0:
			_fail("Character '%s' has both STR and MAG <= 0" % c.get("id", "?"))
		if c.get("abilities", []).size() == 0:
			_warn("Character '%s' has no abilities" % c.get("id", "?"))

	_ok("Validated %d characters" % chars.size())


func test_enemy_data():
	print("\n--- Enemy Data ---")
	var enemies = _load_json("res://data/enemies.json")
	if enemies == null:
		_fail("Cannot load enemies.json")
		return

	var boss_count := 0
	for e in enemies:
		var stats: Dictionary = e.get("stats", {})
		if stats.get("hp", 0) <= 0:
			_fail("Enemy '%s' has HP <= 0" % e.get("id", "?"))
		if e.get("is_boss", false):
			boss_count += 1
			if e.get("xp_reward", 0) == 0 and e.get("id", "") != "beatrix":
				_warn("Boss '%s' gives 0 XP" % e.get("id", "?"))

	_ok("Validated %d enemies (%d bosses)" % [enemies.size(), boss_count])


func test_item_data():
	print("\n--- Item Data ---")
	var items = _load_json("res://data/items.json")
	if items == null:
		_fail("Cannot load items.json")
		return

	var weapons := 0
	var armor := 0
	var consumables := 0
	for i in items:
		match i.get("item_type", ""):
			"weapon":
				weapons += 1
				if i.get("stats", {}).size() == 0:
					_fail("Weapon '%s' has no stats" % i.get("id", "?"))
			"armor":
				armor += 1
				if i.get("stats", {}).size() == 0:
					_fail("Armor '%s' has no stats" % i.get("id", "?"))
			"consumable":
				consumables += 1

	_ok("%d items: %d weapons, %d armor, %d consumables" % [items.size(), weapons, armor, consumables])

	if weapons < 3:
		_warn("Only %d weapons — need more for progression" % weapons)
	if armor < 3:
		_warn("Only %d armor — need more for progression" % armor)


func test_quest_data():
	print("\n--- Quest Data ---")
	var quests = _load_json("res://data/quests.json")
	if quests == null:
		_fail("Cannot load quests.json")
		return

	# Check quest chain
	var quest_map := {}
	for q in quests:
		quest_map[q["id"]] = q

	var roots := 0
	for q in quests:
		if q.get("prerequisite") == null:
			roots += 1
		else:
			if not quest_map.has(q.get("prerequisite", "")):
				_fail("Quest '%s' prerequisite '%s' doesn't exist" % [q["id"], q.get("prerequisite", "")])

	if roots == 0:
		_fail("No root quest (prerequisite=null)")
	else:
		_ok("Quest chain: %d quests, %d roots" % [quests.size(), roots])


func test_dialogue_data():
	print("\n--- Dialogue Data ---")
	var dialogues = _load_json("res://data/dialogues.json")
	if dialogues == null:
		_fail("Cannot load dialogues.json")
		return

	for d in dialogues:
		var lines: Array = d.get("lines", [])
		if lines.size() == 0:
			_fail("Dialogue '%s' has zero lines" % d.get("id", "?"))
		for line in lines:
			if not line.has("speaker") or not line.has("text"):
				_fail("Dialogue '%s' line missing speaker/text" % d.get("id", "?"))
				break

	_ok("Validated %d dialogues" % dialogues.size())


func test_progression_data():
	print("\n--- Progression Data ---")
	var prog = _load_json("res://data/progression.json")
	if prog == null:
		_fail("Cannot load progression.json")
		return

	if prog.get("starting_location", "") == "":
		_fail("No starting_location")
	else:
		_ok("Starting location: " + prog.get("starting_location", ""))

	if prog.get("starting_party", []).size() == 0:
		_fail("No starting_party")
	else:
		_ok("Starting party: " + str(prog.get("starting_party", [])))

	var beats: Array = prog.get("story_beats", [])
	_ok("%d story beats defined" % beats.size())


func test_location_spawn_logic():
	print("\n--- Location Spawn Logic ---")
	# Simulate what LocationManager does: parse layout, exits, props, NPCs
	var dir := DirAccess.open("res://data/locations/")
	if not dir:
		_fail("Cannot open locations directory")
		return

	var spawn_errors := 0
	dir.list_dir_begin()
	var file := dir.get_next()
	while file != "":
		if file.ends_with(".json"):
			var data = _load_json("res://data/locations/" + file)
			if data == null:
				file = dir.get_next()
				continue

			var loc_id: String = data.get("id", "")

			# Check layout parsing
			var layout: Dictionary = data.get("layout", {})
			if layout.size() > 0:
				var w: float = layout.get("width", 0)
				var h: float = layout.get("height", 0)
				if w <= 0 or h <= 0:
					_fail("%s: layout has invalid dimensions (%sx%s)" % [loc_id, str(w), str(h)])
					spawn_errors += 1

				# Check areas
				for area in layout.get("areas", []):
					if not area.has("name") or not area.has("x") or not area.has("y"):
						_fail("%s: area missing name/x/y" % loc_id)
						spawn_errors += 1
						break

			# Check exits have valid structure
			for exit_d in data.get("exits", []):
				if not exit_d.has("target") or not exit_d.has("x") or not exit_d.has("y"):
					_fail("%s: exit missing target/x/y" % loc_id)
					spawn_errors += 1

			# Check props have valid structure
			for prop in data.get("props", []):
				if not prop.has("type") or not prop.has("x") or not prop.has("y"):
					_fail("%s: prop missing type/x/y" % loc_id)
					spawn_errors += 1

			# Check ambient NPCs
			for npc in data.get("ambient_npcs", []):
				if not npc.has("name") or not npc.has("x") or not npc.has("y"):
					_fail("%s: NPC missing name/x/y" % loc_id)
					spawn_errors += 1
				if not npc.has("dialogue"):
					_fail("%s: NPC '%s' missing dialogue" % [loc_id, npc.get("name", "?")])
					spawn_errors += 1

			# Check treasures
			for t in data.get("treasures", []):
				if not t.has("item_id") or not t.has("x") or not t.has("y"):
					_fail("%s: treasure missing item_id/x/y" % loc_id)
					spawn_errors += 1

			# Check encounters
			for enc in data.get("encounters", []):
				if not enc.has("enemies"):
					_fail("%s: encounter missing enemies array" % loc_id)
					spawn_errors += 1

		file = dir.get_next()

	if spawn_errors == 0:
		_ok("All locations have valid spawn structure")
	else:
		_fail("%d spawn structure errors found" % spawn_errors)


func test_battle_damage_formula():
	print("\n--- Battle Damage Formula ---")
	# Test the exact formulas from battle_manager.gd
	# _calc_physical: max(1, atk * 3 - def * 2)
	# _calc_magical: max(1, (mag + power) * 2 - spr)

	var chars = _load_json("res://data/characters.json")
	var enemies = _load_json("res://data/enemies.json")
	if chars == null or enemies == null:
		_fail("Cannot load data for damage test")
		return

	# Test physical damage at level 1
	for c in chars:
		if c.get("role") != "party_member":
			continue
		var atk: int = c["stats"].get("strength", 10)
		for e in enemies:
			if e.get("is_boss", false):
				continue
			var def_val: int = e["stats"].get("defense", 5)
			var dmg: int = max(1, atk * 3 - def_val * 2)
			var enemy_hp: int = e["stats"].get("hp", 50)
			var hits_to_kill: int = max(1, ceili(float(enemy_hp) / float(dmg)))
			if hits_to_kill > 20:
				_warn("'%s' needs %d hits to kill '%s' (atk=%d vs def=%d, dmg=%d)" % [c["id"], hits_to_kill, e["id"], atk, def_val, dmg])

	_ok("Physical damage formula verified")

	# Test boss survivability
	for e in enemies:
		if not e.get("is_boss", false):
			continue
		var boss_hp: int = e["stats"].get("hp", 100)
		var boss_atk: int = e["stats"].get("strength", 10)
		# Check boss doesn't one-shot a level 1 party member (HP ~88-105)
		var boss_dmg: int = max(1, boss_atk * 3 - 8 * 2)  # assume 8 def
		if boss_dmg > 120 and e["id"] != "beatrix" and e["id"] != "necron" and e["id"] != "kuja_trance":
			_warn("Boss '%s' deals %d damage — may one-shot early party" % [e["id"], boss_dmg])

	_ok("Boss balance checked")


func test_exit_connectivity():
	print("\n--- Exit Connectivity ---")
	var locations := {}
	var dir := DirAccess.open("res://data/locations/")
	if not dir:
		_fail("Cannot open locations")
		return

	dir.list_dir_begin()
	var file := dir.get_next()
	while file != "":
		if file.ends_with(".json"):
			var data = _load_json("res://data/locations/" + file)
			if data:
				locations[data["id"]] = data
		file = dir.get_next()

	var broken := 0
	for loc_id in locations:
		var loc: Dictionary = locations[loc_id]
		for exit_d in loc.get("exits", []):
			var target: String = exit_d.get("target", "")
			if target != "" and not locations.has(target):
				_fail("Broken exit: %s → %s" % [loc_id, target])
				broken += 1

	if broken == 0:
		_ok("All %d exits point to valid locations" % locations.size())


func test_story_gating():
	print("\n--- Story Gating ---")
	var locations := {}
	var flags_set := {}

	var dir := DirAccess.open("res://data/locations/")
	if not dir:
		_fail("Cannot open locations")
		return

	dir.list_dir_begin()
	var file := dir.get_next()
	while file != "":
		if file.ends_with(".json"):
			var data = _load_json("res://data/locations/" + file)
			if data:
				locations[data["id"]] = data
				for event in data.get("on_enter_events", []):
					for step in event.get("steps", []):
						if step.get("action") == "set_flag":
							flags_set[step.get("flag", "")] = data["id"]
		file = dir.get_next()

	for loc_id in locations:
		var loc: Dictionary = locations[loc_id]
		for exit_d in loc.get("exits", []):
			var req_flag: String = exit_d.get("requires_flag", "")
			if req_flag != "":
				if flags_set.has(req_flag):
					_ok("Gate '%s' in %s — flag set in %s" % [req_flag, loc_id, flags_set[req_flag]])
				else:
					_fail("Gate '%s' in %s — flag NEVER set anywhere!" % [req_flag, loc_id])


func test_treasure_density():
	print("\n--- Treasure Density ---")
	var dir := DirAccess.open("res://data/locations/")
	if not dir:
		return

	var low_count := 0
	var total := 0
	var total_treasures := 0

	dir.list_dir_begin()
	var file := dir.get_next()
	while file != "":
		if file.ends_with(".json"):
			var data = _load_json("res://data/locations/" + file)
			if data:
				total += 1
				var t_count: int = data.get("treasures", []).size()
				total_treasures += t_count
				if t_count < 2:
					low_count += 1
		file = dir.get_next()

	var avg: float = float(total_treasures) / float(max(total, 1))
	if low_count == 0:
		_ok("All rooms have 2+ treasures (avg: %.1f/room)" % avg)
	else:
		_warn("%d/%d rooms have <2 treasures (avg: %.1f/room, target: 3.0+)" % [low_count, total, avg])


func test_party_join_chain():
	print("\n--- Party Join Chain ---")
	var chars = _load_json("res://data/characters.json")
	var prog = _load_json("res://data/progression.json")
	if chars == null or prog == null:
		_fail("Cannot load data")
		return

	var starting: Array = prog.get("starting_party", [])

	# Collect all join_party events
	var joins := {}
	var dir := DirAccess.open("res://data/locations/")
	if not dir:
		_fail("Cannot open locations")
		return

	dir.list_dir_begin()
	var file := dir.get_next()
	while file != "":
		if file.ends_with(".json"):
			var data = _load_json("res://data/locations/" + file)
			if data:
				for event in data.get("on_enter_events", []):
					for step in event.get("steps", []):
						if step.get("action") == "join_party":
							joins[step.get("character_id", "")] = data.get("id", "")
		file = dir.get_next()

	for c in chars:
		if c.get("role") != "party_member":
			continue
		var cid: String = c["id"]
		if cid in starting:
			_ok("'%s' starts in party" % cid)
		elif joins.has(cid):
			_ok("'%s' joins at %s" % [cid, joins[cid]])
		else:
			_fail("'%s' is party_member but NEVER joins!" % cid)
