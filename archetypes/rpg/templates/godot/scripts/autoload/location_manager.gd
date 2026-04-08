extends Node

var _vh = null  # Visual helpers reference

var location_root: Node2D
var dialogues_by_location: Dictionary = {}
var is_transitioning: bool = false
var current_location_data: Dictionary = {}
var step_count: int = 0
var steps_until_encounter: int = 0

## Character colors loaded from characters.json (not hardcoded)
var CHAR_COLORS: Dictionary = {}

## Collision sizes — loaded from meta.json "collision" section, or defaults
var COL_PROP: Vector2 = Vector2(20, 16)
var COL_NPC: Vector2 = Vector2(30, 30)
var COL_AMBIENT: Vector2 = Vector2(26, 26)
var COL_EXIT: Vector2 = Vector2(30, 60)
var COL_TREASURE: Vector2 = Vector2(28, 28)
var COL_SHOP: Vector2 = Vector2(30, 30)

func _load_collision_config() -> void:
	var file := FileAccess.open("res://data/meta.json", FileAccess.READ)
	if not file: return
	var data = JSON.parse_string(file.get_as_text())
	if not data is Dictionary: return
	var col: Dictionary = data.get("collision", {})
	if col.is_empty(): return
	var p = col.get("player")
	if p is Array and p.size() >= 2: pass  # player collision set in main.tscn
	var prop = col.get("prop")
	if prop is Array and prop.size() >= 2: COL_PROP = Vector2(prop[0], prop[1])
	var npc = col.get("npc")
	if npc is Array and npc.size() >= 2: COL_NPC = Vector2(npc[0], npc[1])
	var amb = col.get("ambient_npc")
	if amb is Array and amb.size() >= 2: COL_AMBIENT = Vector2(amb[0], amb[1])
	var ex = col.get("exit")
	if ex is Array and ex.size() >= 2: COL_EXIT = Vector2(ex[0], ex[1])
	var tr = col.get("treasure")
	if tr is Array and tr.size() >= 2: COL_TREASURE = Vector2(tr[0], tr[1])

func _load_char_colors() -> void:
	var file := FileAccess.open("res://data/characters.json", FileAccess.READ)
	if not file: return
	var data = JSON.parse_string(file.get_as_text())
	if data is Array:
		for c in data:
			var cid: String = c.get("id", "")
			var col = c.get("color")
			if col is Array and col.size() >= 3:
				CHAR_COLORS[cid] = Color(col[0], col[1], col[2])
			else:
				CHAR_COLORS[cid] = Color(0.5, 0.5, 0.5)

const LOC_COLORS := {
	"town": Color(0.3, 0.4, 0.25),
	"dungeon": Color(0.2, 0.15, 0.25),
	"field": Color(0.25, 0.35, 0.2),
	"world_map": Color(0.2, 0.3, 0.35),
	"interior": Color(0.3, 0.25, 0.2),
	"special": Color(0.15, 0.15, 0.3)
}

func _ready() -> void:
	_vh = load("res://scripts/visual_helpers.gd")
	# Load dialogue data for NPC wiring
	var dlg_file := FileAccess.open("res://data/dialogues.json", FileAccess.READ)
	if dlg_file:
		var dlg_data = JSON.parse_string(dlg_file.get_as_text())
		if dlg_data is Array:
			for d in dlg_data:
				var loc_id: String = d.get("location_id", "")
				if not dialogues_by_location.has(loc_id):
					dialogues_by_location[loc_id] = []
				dialogues_by_location[loc_id].append(d)

	_load_char_colors()
	_load_collision_config()

	# Don't auto-load here — title_screen controls when to load
	# (prevents race condition with prologue_screen and story_manager)
	# title_screen calls load_location() after prologue finishes

func _find_location_root() -> void:
	var main = get_tree().current_scene
	if main:
		location_root = main.get_node_or_null("LocationRoot")

var _came_from: String = ""

func load_location(location_id: String, from_location: String = "") -> void:
	_came_from = from_location
	if is_transitioning:
		return
	is_transitioning = true

	var fader = _get_fader()
	if fader:
		await fader.fade_out(0.3)

	# Clear old location
	if location_root:
		for child in location_root.get_children():
			child.queue_free()
		await get_tree().process_frame

	# Load location data
	var path := "res://data/locations/" + location_id + ".json"
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("Location not found: " + path)
		is_transitioning = false
		return

	var data = JSON.parse_string(file.get_as_text())
	if data == null:
		push_error("Failed to parse: " + path)
		is_transitioning = false
		return

	GameManager.current_location_id = location_id
	current_location_data = data
	step_count = 0
	steps_until_encounter = randi_range(10, 30)
	_spawn_location(data)

	# Apply lighting BEFORE fade-in (so player never sees bright flash)
	var atmo: Dictionary = data.get("atmosphere", {})
	_apply_lighting(atmo)

	if fader:
		await fader.fade_in(0.3)

	is_transitioning = false

	# Update HUD
	var hud = _get_hud()
	if hud and hud.has_method("update_location"):
		hud.update_location(data.get("name", location_id))

	var music_mood: String = atmo.get("music_mood", "")
	AudioManager.play_bgm_for_location(data.get("type", "town"), music_mood)

	# Fire quest trigger: reached this location
	QuestManager.on_trigger("reach", location_id)

	# Fire story phase trigger
	StoryManager.on_location_entered(location_id)

	# Check for auto-dialogues (story events tied to quests)
	var loc_dialogues: Array = dialogues_by_location.get(location_id, [])
	for dlg in loc_dialogues:
		var trigger_cond: String = dlg.get("trigger_condition", "interact")
		if trigger_cond == "auto":
			# Auto-play this dialogue when entering the location
			await get_tree().create_timer(0.5).timeout
			DialogueManager.start_dialogue(dlg.get("id", ""))
			break
		elif trigger_cond.begins_with("quest:"):
			# Play if the referenced quest is active
			var quest_id: String = trigger_cond.substr(6)
			if QuestManager.is_quest_active(quest_id):
				await get_tree().create_timer(0.5).timeout
				DialogueManager.start_dialogue(dlg.get("id", ""))
				break

	# Check for boss fight at this location
	var boss_enemy_id: String = QuestManager.get_pending_boss_fight()
	if boss_enemy_id != "":
		# Check if this location has a boss encounter with that enemy
		var encounters: Array = data.get("encounters", [])
		for enc in encounters:
			if enc.get("trigger", "") == "boss":
				var enc_enemies: Array = enc.get("enemy_ids", [])
				if boss_enemy_id in enc_enemies:
					await get_tree().create_timer(1.0).timeout
					DialogueManager.show_simple_message("", "A powerful enemy appears!")
					await get_tree().create_timer(0.5).timeout
					start_encounter(enc_enemies)
					# When battle ends, fire the defeat trigger
					await BattleManager.battle_ended
					if BattleManager.state != BattleManager.BattleState.DEFEAT:
						QuestManager.on_trigger("defeat", boss_enemy_id)
					break

func _spawn_location(data: Dictionary) -> void:
	if not location_root:
		_find_location_root()
	if not location_root:
		push_error("LocationRoot not found!")
		return

	var loc_type: String = data.get("type", "field")
	var has_layout: bool = data.has("layout")

	# Use rich layout if available, otherwise fall back to old format
	if has_layout:
		_spawn_rich_location(data)
	else:
		_spawn_simple_location(data)

func _spawn_rich_location(data: Dictionary) -> void:
	var layout: Dictionary = data.get("layout", {})
	var loc_id: String = data.get("id", "")

	var lw: float = layout.get("width", 900)
	var lh: float = layout.get("height", 700)
	var gc: Array = layout.get("ground_color", [0.2, 0.25, 0.2])
	var base_color := Color(gc[0], gc[1], gc[2])
	var ox: float = -lw / 2
	var oy: float = -lh / 2 + 200

	# Ground base
	var ground := ColorRect.new()
	ground.name = "Ground"
	ground.color = base_color
	ground.position = Vector2(ox, oy)
	ground.size = Vector2(lw, lh)
	location_root.add_child(ground)

	# Ground texture variation (subtle noise-like pattern)
	for i in range(12):
		var patch := ColorRect.new()
		var px: float = randf_range(ox + 20, ox + lw - 60)
		var py: float = randf_range(oy + 20, oy + lh - 60)
		var pw: float = randf_range(40, 120)
		var ph: float = randf_range(30, 80)
		patch.position = Vector2(px, py)
		patch.size = Vector2(pw, ph)
		var variation: float = randf_range(-0.03, 0.03)
		patch.color = Color(base_color.r + variation, base_color.g + variation, base_color.b + variation, 0.4)
		location_root.add_child(patch)

	# Border walls (dark edges around the location)
	var border_color := Color(base_color.r * 0.4, base_color.g * 0.4, base_color.b * 0.4)
	var border_w: float = 20
	# Top
	var bt := ColorRect.new()
	bt.position = Vector2(ox, oy - border_w)
	bt.size = Vector2(lw, border_w)
	bt.color = border_color
	location_root.add_child(bt)
	# Bottom
	var bb := ColorRect.new()
	bb.position = Vector2(ox, oy + lh)
	bb.size = Vector2(lw, border_w)
	bb.color = border_color
	location_root.add_child(bb)
	# Left
	var bl := ColorRect.new()
	bl.position = Vector2(ox - border_w, oy - border_w)
	bl.size = Vector2(border_w, lh + border_w * 2)
	bl.color = border_color
	location_root.add_child(bl)
	# Right
	var br := ColorRect.new()
	br.position = Vector2(ox + lw, oy - border_w)
	br.size = Vector2(border_w, lh + border_w * 2)
	br.color = border_color
	location_root.add_child(br)

	# Collision walls (invisible, block player movement)
	_add_wall_collider(location_root, Vector2(ox + lw / 2, oy - border_w / 2), Vector2(lw + border_w * 2, border_w))  # top
	_add_wall_collider(location_root, Vector2(ox + lw / 2, oy + lh + border_w / 2), Vector2(lw + border_w * 2, border_w))  # bottom
	_add_wall_collider(location_root, Vector2(ox - border_w / 2, oy + lh / 2), Vector2(border_w, lh + border_w * 2))  # left
	_add_wall_collider(location_root, Vector2(ox + lw + border_w / 2, oy + lh / 2), Vector2(border_w, lh + border_w * 2))  # right

	# Enable Y-sort on location root so objects overlap correctly
	location_root.y_sort_enabled = true

	# Sub-areas (different colored zones)
	var areas: Array = layout.get("areas", [])
	for area_data in areas:
		var ac: Array = area_data.get("ground_color", gc)
		var area_rect := ColorRect.new()
		area_rect.name = "Area_" + area_data.get("name", "zone").replace(" ", "_")
		area_rect.color = Color(ac[0], ac[1], ac[2])
		var ax: float = area_data.get("x", 0) - lw / 2
		var ay: float = area_data.get("y", 0) - lh / 2 + 200
		var aw: float = area_data.get("w", 100)
		var ah: float = area_data.get("h", 100)
		area_rect.position = Vector2(ax - aw / 2, ay - ah / 2)
		area_rect.size = Vector2(aw, ah)
		location_root.add_child(area_rect)

	# Location name
	var label := Label.new()
	label.name = "LocationName"
	label.text = data.get("name", "???")
	label.position = Vector2(-80, -lh / 2 + 150)
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Color.WHITE)
	location_root.add_child(label)

	# Props
	var props: Array = data.get("props", [])
	for prop_data in props:
		var px: float = prop_data.get("x", 0) - lw / 2
		var py: float = prop_data.get("y", 0) - lh / 2 + 200
		var pc: Array = prop_data.get("color", [0.5, 0.5, 0.5])
		var prop_type: String = prop_data.get("type", "object")
		var prop_label_text: String = prop_data.get("label", "")

		var prop := Node2D.new()
		prop.name = "Prop_" + prop_type
		prop.position = Vector2(px, py)

		var base_c := Color(pc[0], pc[1], pc[2])
		_build_prop_visual(prop, prop_type, base_c)

		# Add collision to solid props (player can't walk through)
		var passthrough_types: Array = ["mist", "light_beam", "frost", "frost_heavy", "prismatic_light", "dark_aura", "sparkles", "carpet", "stone_path"]
		var is_solid: bool = prop_data.get("solid", not prop_type in passthrough_types)
		if is_solid:
			var body := StaticBody2D.new()
			body.name = "Collision"
			var col_shape := CollisionShape2D.new()
			var shape := RectangleShape2D.new()
			shape.size = COL_PROP
			col_shape.shape = shape
			body.add_child(col_shape)
			prop.add_child(body)

		if prop_label_text != "":
			var plbl := Label.new()
			plbl.text = prop_label_text
			plbl.position = Vector2(-30, -25)
			plbl.add_theme_font_size_override("font_size", 9)
			plbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.6))
			prop.add_child(plbl)

		location_root.add_child(prop)

	# Story NPCs (positioned, quest-state dialogues)
	var story_npcs: Array = data.get("story_npcs", [])
	for snpc in story_npcs:
		var npc_id: String = snpc.get("id", "")
		var npc_name: String = snpc.get("name", npc_id)
		var nx: float = snpc.get("x", 100) - lw / 2
		var ny: float = snpc.get("y", 300) - lh / 2 + 200
		var nc: Array = snpc.get("color", [1, 1, 0])

		var npc_node := Node2D.new()
		npc_node.name = "NPC_" + npc_id
		npc_node.position = Vector2(nx, ny)

		# Character silhouette visual
		if _vh:
			_vh.create_character_visual(npc_node, Color(nc[0], nc[1], nc[2]))
		else:
			var sprite := ColorRect.new()
			sprite.name = "Sprite"
			sprite.size = Vector2(20, 24)
			sprite.position = Vector2(-10, -12)
			sprite.color = Color(nc[0], nc[1], nc[2])
			npc_node.add_child(sprite)

		var name_label := Label.new()
		name_label.name = "NameLabel"
		name_label.text = npc_name
		name_label.position = Vector2(-30, -35)
		name_label.add_theme_font_size_override("font_size", 12)
		name_label.add_theme_color_override("font_color", Color.WHITE)
		npc_node.add_child(name_label)

		var area := Area2D.new()
		area.name = "InteractArea"
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(30, 30)
		shape.shape = rect
		area.add_child(shape)
		npc_node.add_child(area)

		# Quest-state dialogue script
		var dlg_map: Dictionary = snpc.get("dialogues_by_quest", {})
		npc_node.set_meta("npc_id", npc_id)
		npc_node.set_meta("npc_name", npc_name)
		npc_node.set_meta("dialogue_map", dlg_map)

		# Also wire to main dialogue system for story dialogues
		var loc_dialogues: Array = dialogues_by_location.get(data.get("id", ""), [])
		var dlg_id: String = ""
		for dlg in loc_dialogues:
			dlg_id = dlg.get("id", "")
			break
		npc_node.set_meta("dialogue_id", dlg_id)

		var script := GDScript.new()
		script.source_code = """extends Node2D

func interact():
	var nid = get_meta("npc_id", "")
	var did = get_meta("dialogue_id", "")
	var dlg_map = get_meta("dialogue_map", {})

	# Find best quest-state dialogue
	var line = _get_quest_dialogue(dlg_map)
	if line != "":
		DialogueManager.show_simple_message(get_meta("npc_name", ""), line)
	elif did != "":
		DialogueManager.start_dialogue(did)
	else:
		DialogueManager.show_simple_message(get_meta("npc_name", ""), dlg_map.get("default", "..."))

	if nid != "":
		QuestManager.on_trigger("talk_to", nid)

func _get_quest_dialogue(dlg_map: Dictionary) -> String:
	# Check quest-state keys: "quest_id:step" or "after:quest_id"
	for key in dlg_map:
		if key == "default":
			continue
		if key.begins_with("after:"):
			var qid = key.substr(6)
			if QuestManager.is_quest_complete(qid):
				return dlg_map[key]
		elif ":" in key:
			var parts = key.split(":")
			var qid = parts[0]
			var step = int(parts[1])
			if QuestManager.is_quest_active(qid):
				if QuestManager.active_quests.has(qid):
					if QuestManager.active_quests[qid]["current_step"] == step:
						return dlg_map[key]
	return ""
"""
		script.reload()
		npc_node.set_script(script)
		npc_node.add_to_group("interactable")
		location_root.add_child(npc_node)

	# Ambient NPCs (with optional patrol)
	var ambient: Array = data.get("ambient_npcs", [])
	for amb in ambient:
		var amb_name: String = amb.get("name", "Villager")
		var ax: float = amb.get("x", 0) - lw / 2
		var ay: float = amb.get("y", 0) - lh / 2 + 200
		var ac: Array = amb.get("color", [0.6, 0.6, 0.5])
		var amb_dialogue: String = amb.get("dialogue", "...")
		var patrol_data = amb.get("patrol")

		var amb_node := Node2D.new()
		amb_node.name = "Ambient_" + amb_name.replace(" ", "_")
		amb_node.position = Vector2(ax, ay)

		var sprite := ColorRect.new()
		sprite.name = "Sprite"
		sprite.size = Vector2(16, 20)
		sprite.position = Vector2(-8, -10)
		sprite.color = Color(ac[0], ac[1], ac[2])
		amb_node.add_child(sprite)

		var name_lbl := Label.new()
		name_lbl.name = "NameLabel"
		name_lbl.text = amb_name
		name_lbl.position = Vector2(-25, -28)
		name_lbl.add_theme_font_size_override("font_size", 10)
		name_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.6))
		amb_node.add_child(name_lbl)

		var amb_area := Area2D.new()
		amb_area.name = "InteractArea"
		var amb_shape := CollisionShape2D.new()
		var amb_rect := RectangleShape2D.new()
		amb_rect.size = COL_AMBIENT
		amb_shape.shape = amb_rect
		amb_area.add_child(amb_shape)
		amb_node.add_child(amb_area)

		amb_node.set_meta("dialogue_line", amb_dialogue)
		amb_node.set_meta("npc_name", amb_name)

		# Patrol + interact script
		var patrol_code: String = ""
		if patrol_data != null and patrol_data is Dictionary:
			var pfx: float = patrol_data.get("from_x", ax) - lw / 2
			var ptx: float = patrol_data.get("to_x", ax + 50) - lw / 2
			var pspd: float = patrol_data.get("speed", 20)
			patrol_code = """
var _patrol_from: float = %f
var _patrol_to: float = %f
var _patrol_speed: float = %f
var _patrol_dir: float = 1.0

func _process(delta):
	position.x += _patrol_dir * _patrol_speed * delta
	if position.x > _patrol_to:
		_patrol_dir = -1.0
	elif position.x < _patrol_from:
		_patrol_dir = 1.0
""" % [pfx, ptx, pspd]

		var amb_script := GDScript.new()
		amb_script.source_code = "extends Node2D\n" + patrol_code + """
func interact():
	var line = get_meta("dialogue_line", "...")
	DialogueManager.show_simple_message(get_meta("npc_name", "NPC"), line)
"""
		amb_script.reload()
		amb_node.set_script(amb_script)
		amb_node.add_to_group("interactable")
		location_root.add_child(amb_node)

	# Exits (positioned)
	var exits: Array = data.get("exits", [])
	if exits.is_empty():
		# Fall back to old connections format
		exits = []
		var conns: Array = data.get("connections", [])
		var ex: float = -300.0
		for conn in conns:
			exits.append({"target": conn, "x": ex + lw / 2, "y": 50, "label": "To " + conn})
			ex += 200
	for exit_data in exits:
		var target: String = exit_data.get("target", "")
		var ex: float = exit_data.get("x", 0) - lw / 2
		var ey: float = exit_data.get("y", 0) - lh / 2 + 200
		var elabel: String = exit_data.get("label", "→ " + target)

		var exit := Node2D.new()
		exit.name = "Exit_" + target
		exit.position = Vector2(ex, ey)

		var marker := ColorRect.new()
		marker.name = "Marker"
		marker.color = Color(0.3, 0.8, 1.0, 0.7)
		marker.size = Vector2(16, 40)
		marker.position = Vector2(-8, -20)
		exit.add_child(marker)

		var exit_label := Label.new()
		exit_label.name = "Label"
		exit_label.text = elabel
		exit_label.position = Vector2(-40, -45)
		exit_label.add_theme_font_size_override("font_size", 11)
		exit_label.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
		exit.add_child(exit_label)

		var area := Area2D.new()
		area.name = "TriggerArea"
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = COL_EXIT
		shape.shape = rect
		area.add_child(shape)
		exit.add_child(area)

		var captured_id: String = target
		var current_loc_id: String = loc_id
		var required_flag: String = exit_data.get("requires_flag", "")
		var locked_msg: String = exit_data.get("locked_message", "The path ahead is blocked.")
		area.body_entered.connect(func(body):
			if body.name == "Player":
				if required_flag != "" and not GameManager.has_flag(required_flag):
					DialogueManager.play_dialogue({"lines": [{"speaker": "", "text": locked_msg}], "branches": [], "trigger_condition": "auto", "sets_flag": ""})
					return
				load_location(captured_id, current_loc_id)
		)
		location_root.add_child(exit)

	# Treasures (positioned)
	var treasures: Array = data.get("treasures", [])
	for t in treasures:
		var item_id: String = t.get("item_id", "")
		var item_name: String = t.get("item_name", item_id)
		var tx: float = t.get("x", 0) - lw / 2
		var ty: float = t.get("y", 0) - lh / 2 + 200
		var chest_key: String = loc_id + "_chest_" + item_id

		if GameManager.has_flag(chest_key):
			continue

		var chest := Node2D.new()
		chest.name = "Chest_" + item_id
		chest.position = Vector2(tx, ty)

		var chest_sprite := ColorRect.new()
		chest_sprite.name = "Sprite"
		chest_sprite.size = Vector2(18, 14)
		chest_sprite.position = Vector2(-9, -7)
		chest_sprite.color = Color(0.8, 0.65, 0.2)
		chest.add_child(chest_sprite)

		var chest_label := Label.new()
		chest_label.name = "Label"
		chest_label.text = "?"
		chest_label.position = Vector2(-5, -22)
		chest_label.add_theme_font_size_override("font_size", 14)
		chest_label.add_theme_color_override("font_color", Color(0.9, 0.8, 0.3))
		chest.add_child(chest_label)

		var chest_area := Area2D.new()
		chest_area.name = "ChestArea"
		var chest_shape := CollisionShape2D.new()
		var chest_rect := RectangleShape2D.new()
		chest_rect.size = COL_TREASURE
		chest_shape.shape = chest_rect
		chest_area.add_child(chest_shape)
		chest.add_child(chest_area)

		var chest_script := GDScript.new()
		chest_script.source_code = """extends Node2D

func interact():
	var item_id = get_meta("item_id", "")
	var item_name = get_meta("item_name", "")
	var chest_key = get_meta("chest_key", "")
	if GameManager.has_flag(chest_key):
		DialogueManager.show_simple_message("", "The chest is empty.")
		return
	GameManager.set_flag(chest_key)
	InventoryManager.add_item(item_id)
	$Label.text = "!"
	$Sprite.color = Color(0.4, 0.35, 0.2, 0.5)
	DialogueManager.show_simple_message("", "Found: " + item_name + "!")
"""
		chest_script.reload()
		chest.set_script(chest_script)
		chest.set_meta("item_id", item_id)
		chest.set_meta("item_name", item_name)
		chest.set_meta("chest_key", chest_key)
		chest.add_to_group("interactable")
		location_root.add_child(chest)

	# Shop NPC
	var shop_data: Array = data.get("shop", [])
	if shop_data.size() > 0:
		var shop_npc := Node2D.new()
		shop_npc.name = "Shopkeeper"
		shop_npc.position = Vector2(lw / 4, -50)

		var shop_sprite := ColorRect.new()
		shop_sprite.name = "Sprite"
		shop_sprite.size = Vector2(20, 24)
		shop_sprite.position = Vector2(-10, -12)
		shop_sprite.color = Color(0.2, 0.7, 0.2)
		shop_npc.add_child(shop_sprite)

		var shop_label := Label.new()
		shop_label.name = "NameLabel"
		shop_label.text = "Shop"
		shop_label.position = Vector2(-15, -30)
		shop_label.add_theme_font_size_override("font_size", 12)
		shop_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3))
		shop_npc.add_child(shop_label)

		var shop_area := Area2D.new()
		shop_area.name = "InteractArea"
		var shop_shape := CollisionShape2D.new()
		var shop_rect := RectangleShape2D.new()
		shop_rect.size = COL_SHOP
		shop_shape.shape = shop_rect
		shop_area.add_child(shop_shape)
		shop_npc.add_child(shop_area)

		var shop_script := GDScript.new()
		shop_script.source_code = """extends Node2D

func interact():
	var shop_ui = get_tree().current_scene.get_node_or_null("ShopUI")
	if shop_ui and shop_ui.has_method("open_shop"):
		shop_ui.open_shop()
	else:
		DialogueManager.show_simple_message("Shopkeeper", "Welcome! (Shop UI not available)")
"""
		shop_script.reload()
		shop_npc.set_script(shop_script)
		shop_npc.add_to_group("interactable")
		location_root.add_child(shop_npc)

	# Atmosphere
	var atmo: Dictionary = data.get("atmosphere", {})
	if not atmo.is_empty():
		var bg_c: Array = atmo.get("bg_color", [0.1, 0.1, 0.15])
		var cam = get_tree().current_scene.get_node_or_null("Player/Camera2D")
		if cam:
			# We can't easily set camera bg in 2D, but we can modify the ground color
			pass
		# Particles
		var particle_type: String = atmo.get("particles", "none")
		if particle_type != "none":
			_spawn_particles(particle_type)

	# Player position — spawn near the exit that leads back to where we came from
	var player = get_tree().current_scene.get_node_or_null("Player")
	if player:
		var spawn_pos := Vector2.ZERO
		var found_spawn: bool = false

		# If we came from another location, find the exit that points back there
		if _came_from != "":
			var exits_data: Array = data.get("exits", [])
			for exit_d in exits_data:
				if exit_d.get("target", "") == _came_from:
					var ex: float = exit_d.get("x", lw / 2) - lw / 2
					var ey: float = exit_d.get("y", lh / 2) - lh / 2 + 200
					spawn_pos = Vector2(ex, ey + 30)  # offset slightly away from trigger
					found_spawn = true
					break

		# Fallback: use the entrance position from layout
		if not found_spawn:
			var entrance: Dictionary = data.get("layout", {}).get("entrance", {})
			var entry_x: float = entrance.get("x", lw / 2) - lw / 2
			var entry_y: float = entrance.get("y", lh - 50) - lh / 2 + 200
			spawn_pos = Vector2(entry_x, entry_y)

		player.position = spawn_pos

	# On-enter events — freeze player during ALL events
	var events: Array = data.get("on_enter_events", [])
	var has_events: bool = false
	for check_evt in events:
		var check_cond: String = check_evt.get("condition", "")
		if check_cond == "first_visit" and not GameManager.has_flag("visited_" + loc_id):
			has_events = true
			break
		elif check_cond.begins_with("quest_active:"):
			var check_qid: String = check_cond.substr(13)
			if QuestManager.is_quest_active(check_qid):
				has_events = true
				break
		elif check_cond == "always":
			has_events = true
			break

	if has_events and player:
		player.can_move = false

	for evt in events:
		var condition: String = evt.get("condition", "")
		var evt_type: String = evt.get("type", "")

		# Check condition
		var should_fire: bool = false
		if condition == "first_visit" and not GameManager.has_flag("visited_" + loc_id):
			GameManager.set_flag("visited_" + loc_id)
			should_fire = true
		elif condition.begins_with("quest_active:"):
			var qid: String = condition.substr(13)
			if QuestManager.is_quest_active(qid):
				should_fire = true
		elif condition == "always":
			should_fire = true

		if not should_fire:
			continue

		# Execute event by type
		match evt_type:
			"narration":
				await get_tree().create_timer(0.3).timeout
				DialogueManager.show_simple_message("", evt.get("text", ""))
				while DialogueManager.is_playing:
					await get_tree().process_frame
			"dialogue":
				await get_tree().create_timer(0.5).timeout
				DialogueManager.start_dialogue(evt.get("dialogue_id", ""))
				while DialogueManager.is_playing:
					await get_tree().process_frame
			"cutscene":
				await get_tree().create_timer(0.3).timeout
				var steps: Array = evt.get("steps", [])
				await CutsceneManager.play_cutscene(steps)

	# Unfreeze player after all events
	if has_events and player:
		player.can_move = true

func _apply_lighting(atmo: Dictionary) -> void:
	# Remove old lighting
	var main = get_tree().current_scene
	if not main:
		return
	var old_mod = main.get_node_or_null("CanvasModulate")
	if old_mod:
		old_mod.queue_free()
	var player = main.get_node_or_null("Player")
	if player:
		var old_light = player.get_node_or_null("PlayerLight")
		if old_light:
			old_light.queue_free()

	var lighting: Dictionary = atmo.get("lighting", {})
	var light_type: String = str(lighting.get("type", "")) if lighting.has("type") else ""

	if light_type == "dark" or light_type == "dim":
		# Darken the whole scene
		var modulate := CanvasModulate.new()
		modulate.name = "CanvasModulate"
		if light_type == "dark":
			modulate.color = Color(0.15, 0.15, 0.2)
		else:
			modulate.color = Color(0.4, 0.4, 0.45)
		main.add_child(modulate)

		# Add a point light on the player
		if player:
			var light := PointLight2D.new()
			light.name = "PlayerLight"
			var radius: float = lighting.get("radius", 150.0)
			light.texture = _create_light_texture()
			light.texture_scale = radius / 256.0
			light.energy = lighting.get("energy", 1.2)
			light.color = Color(
				lighting.get("color", [1.0, 0.9, 0.6])[0],
				lighting.get("color", [1.0, 0.9, 0.6])[1],
				lighting.get("color", [1.0, 0.9, 0.6])[2]
			)
			player.add_child(light)


func _create_light_texture() -> Texture2D:
	# Create a radial gradient texture for the point light
	var img := Image.create(512, 512, false, Image.FORMAT_RGBA8)
	var center := Vector2(256, 256)
	for x in range(512):
		for y in range(512):
			var dist: float = Vector2(x, y).distance_to(center) / 256.0
			var alpha: float = clampf(1.0 - dist, 0.0, 1.0)
			alpha = alpha * alpha  # smooth falloff
			img.set_pixel(x, y, Color(1, 1, 1, alpha))
	return ImageTexture.create_from_image(img)


func _spawn_particles(particle_type: String) -> void:
	# Simple particle effect using CPUParticles2D
	var particles := CPUParticles2D.new()
	particles.name = "AtmosphereParticles"
	particles.emitting = true
	particles.amount = 30
	particles.lifetime = 3.0
	particles.position = Vector2(0, -200)

	match particle_type:
		"rain":
			particles.amount = 80
			particles.direction = Vector2(0, 1)
			particles.gravity = Vector2(0, 400)
			particles.initial_velocity_min = 200
			particles.initial_velocity_max = 300
			particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
			particles.emission_rect_extents = Vector2(500, 10)
			particles.color = Color(0.5, 0.6, 0.8, 0.4)
			particles.scale_amount_min = 0.5
			particles.scale_amount_max = 1.0
		"mist":
			particles.amount = 20
			particles.direction = Vector2(1, 0)
			particles.gravity = Vector2(0, 0)
			particles.initial_velocity_min = 10
			particles.initial_velocity_max = 30
			particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
			particles.emission_rect_extents = Vector2(400, 200)
			particles.color = Color(0.3, 0.5, 0.2, 0.15)
			particles.scale_amount_min = 3.0
			particles.scale_amount_max = 6.0
		"snow":
			particles.amount = 40
			particles.direction = Vector2(0.2, 1)
			particles.gravity = Vector2(0, 50)
			particles.initial_velocity_min = 20
			particles.initial_velocity_max = 50
			particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
			particles.emission_rect_extents = Vector2(500, 10)
			particles.color = Color(0.9, 0.9, 1.0, 0.6)
			particles.scale_amount_min = 1.0
			particles.scale_amount_max = 2.0
		"sparkles":
			particles.amount = 15
			particles.direction = Vector2(0, -1)
			particles.gravity = Vector2(0, -20)
			particles.initial_velocity_min = 10
			particles.initial_velocity_max = 30
			particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
			particles.emission_rect_extents = Vector2(300, 200)
			particles.color = Color(0.8, 0.7, 1.0, 0.5)
			particles.scale_amount_min = 0.5
			particles.scale_amount_max = 1.5
		"embers":
			particles.amount = 20
			particles.direction = Vector2(0, -1)
			particles.gravity = Vector2(0, -30)
			particles.initial_velocity_min = 20
			particles.initial_velocity_max = 60
			particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
			particles.emission_rect_extents = Vector2(400, 100)
			particles.color = Color(1.0, 0.5, 0.1, 0.6)
			particles.scale_amount_min = 0.5
			particles.scale_amount_max = 1.0

	location_root.add_child(particles)

func _add_wall_collider(parent: Node, pos: Vector2, size: Vector2) -> void:
	var body := StaticBody2D.new()
	body.position = pos
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	shape.shape = rect
	body.add_child(shape)
	parent.add_child(body)

func _build_prop_visual(parent: Node2D, prop_type: String, base_c: Color) -> void:
	if _vh:
		_vh.create_prop_visual(parent, prop_type, base_c)

func _spawn_simple_location(data: Dictionary) -> void:
	# Legacy format support — flat ground + objects in a line
	var loc_type: String = data.get("type", "field")
	var loc_color: Color = LOC_COLORS.get(loc_type, Color(0.2, 0.25, 0.2))

	# Ground
	var ground := ColorRect.new()
	ground.name = "Ground"
	ground.color = loc_color
	ground.position = Vector2(-800, 200)
	ground.size = Vector2(1600, 400)
	location_root.add_child(ground)

	# Location name label
	var label := Label.new()
	label.name = "LocationName"
	label.text = data.get("name", "???")
	label.position = Vector2(-80, -250)
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Color.WHITE)
	location_root.add_child(label)

	# NPCs
	var npcs: Array = data.get("npcs", [])
	var npc_x: float = 80.0
	var loc_id: String = data.get("id", "")
	var loc_dialogues: Array = dialogues_by_location.get(loc_id, [])

	for npc_data in npcs:
		var npc_id: String = npc_data.get("id", "")
		var npc_name: String = npc_data.get("name", npc_id)

		var npc_node := Node2D.new()
		npc_node.name = "NPC_" + npc_id
		npc_node.position = Vector2(npc_x, 0)

		# Sprite (colored rectangle)
		var sprite := ColorRect.new()
		sprite.name = "Sprite"
		sprite.size = Vector2(20, 24)
		sprite.position = Vector2(-10, -12)
		var npc_color: Color = CHAR_COLORS.get(npc_id, Color.YELLOW)
		sprite.color = npc_color
		npc_node.add_child(sprite)

		# Name label
		var name_label := Label.new()
		name_label.name = "NameLabel"
		name_label.text = npc_name
		name_label.position = Vector2(-30, -35)
		name_label.add_theme_font_size_override("font_size", 12)
		name_label.add_theme_color_override("font_color", Color.WHITE)
		npc_node.add_child(name_label)

		# Interaction area
		var area := Area2D.new()
		area.name = "InteractArea"
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(30, 30)
		shape.shape = rect
		area.add_child(shape)
		npc_node.add_child(area)

		# Set script-like behavior via metadata
		npc_node.set_meta("npc_name", npc_name)
		npc_node.set_meta("npc_id", npc_id)

		# Wire dialogue
		var dlg_id: String = ""
		for dlg in loc_dialogues:
			dlg_id = dlg.get("id", "")
			break  # first dialogue for this location
		npc_node.set_meta("dialogue_id", dlg_id)

		# Add interact method via script
		var script := GDScript.new()
		script.source_code = """extends Node2D

func interact():
	var nid = get_meta("npc_id", "")
	var did = get_meta("dialogue_id", "")
	if did != "":
		DialogueManager.start_dialogue(did)
	else:
		print("No dialogue for ", nid)
	# Fire quest trigger: talked to this NPC
	if nid != "":
		QuestManager.on_trigger("talk_to", nid)
"""
		script.reload()
		npc_node.set_script(script)
		npc_node.add_to_group("interactable")

		location_root.add_child(npc_node)
		npc_x += 100.0

	# Exit triggers
	var connections: Array = data.get("connections", [])
	var exit_spacing: float = 400.0 / max(connections.size(), 1)
	var exit_x: float = -300.0

	for conn_id in connections:
		var exit := Node2D.new()
		exit.name = "Exit_" + conn_id
		exit.position = Vector2(exit_x, 0)

		# Visual marker
		var marker := ColorRect.new()
		marker.name = "Marker"
		marker.color = Color(0.3, 0.8, 1.0, 0.7)
		marker.size = Vector2(16, 40)
		marker.position = Vector2(-8, -20)
		exit.add_child(marker)

		# Label
		var exit_label := Label.new()
		exit_label.name = "Label"
		exit_label.text = "→ " + conn_id
		exit_label.position = Vector2(-40, -45)
		exit_label.add_theme_font_size_override("font_size", 11)
		exit_label.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
		exit.add_child(exit_label)

		# Trigger area
		var area := Area2D.new()
		area.name = "TriggerArea"
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = COL_EXIT
		shape.shape = rect
		area.add_child(shape)
		exit.add_child(area)

		# Connect transition signal
		var captured_id: String = conn_id
		var cur_loc: String = data.get("id", "")
		area.body_entered.connect(func(body):
			if body.name == "Player":
				load_location(captured_id, cur_loc)
		)

		location_root.add_child(exit)
		exit_x += exit_spacing

	# --- Treasure chests ---
	var treasures: Array = data.get("treasures", [])
	for treasure_data in treasures:
		var item_id: String = treasure_data.get("item_id", "")
		var item_name: String = treasure_data.get("item_name", item_id)
		var chest_key: String = data.get("id", "") + "_chest_" + item_id

		# Skip if already opened
		if GameManager.has_flag(chest_key):
			continue

		var chest := Node2D.new()
		chest.name = "Chest_" + item_id
		var tx: float = treasure_data.get("position_x", -150)
		var ty: float = treasure_data.get("position_y", 0)
		chest.position = Vector2(tx, ty)

		# Chest visual (golden square)
		var chest_sprite := ColorRect.new()
		chest_sprite.name = "Sprite"
		chest_sprite.size = Vector2(18, 14)
		chest_sprite.position = Vector2(-9, -7)
		chest_sprite.color = Color(0.8, 0.65, 0.2)
		chest.add_child(chest_sprite)

		# Label
		var chest_label := Label.new()
		chest_label.name = "Label"
		chest_label.text = "?"
		chest_label.position = Vector2(-5, -22)
		chest_label.add_theme_font_size_override("font_size", 14)
		chest_label.add_theme_color_override("font_color", Color(0.9, 0.8, 0.3))
		chest.add_child(chest_label)

		# Interaction area
		var chest_area := Area2D.new()
		chest_area.name = "ChestArea"
		var chest_shape := CollisionShape2D.new()
		var chest_rect := RectangleShape2D.new()
		chest_rect.size = COL_TREASURE
		chest_shape.shape = chest_rect
		chest_area.add_child(chest_shape)
		chest.add_child(chest_area)

		# Interact script
		var chest_script := GDScript.new()
		chest_script.source_code = """extends Node2D

func interact():
	var item_id = get_meta("item_id", "")
	var item_name = get_meta("item_name", "")
	var chest_key = get_meta("chest_key", "")
	if GameManager.has_flag(chest_key):
		DialogueManager.show_simple_message("", "The chest is empty.")
		return
	GameManager.set_flag(chest_key)
	InventoryManager.add_item(item_id)
	$Label.text = "!"
	$Sprite.color = Color(0.4, 0.35, 0.2, 0.5)
	DialogueManager.show_simple_message("", "Found: " + item_name + "!")
"""
		chest_script.reload()
		chest.set_script(chest_script)
		chest.set_meta("item_id", item_id)
		chest.set_meta("item_name", item_name)
		chest.set_meta("chest_key", chest_key)
		chest.add_to_group("interactable")

		location_root.add_child(chest)

	# --- Ambient NPCs (flavor dialogue) ---
	var ambient_npcs: Array = data.get("ambient_npcs", [])
	for amb in ambient_npcs:
		var amb_name: String = amb.get("name", "Villager")
		var amb_dialogue: String = amb.get("dialogue", "...")
		var amb_x: float = amb.get("position_x", 0)
		var amb_y: float = amb.get("position_y", 0)

		var amb_node := Node2D.new()
		amb_node.name = "Ambient_" + amb_name
		amb_node.position = Vector2(amb_x, amb_y)

		var amb_sprite := ColorRect.new()
		amb_sprite.name = "Sprite"
		amb_sprite.size = Vector2(16, 20)
		amb_sprite.position = Vector2(-8, -10)
		amb_sprite.color = Color(0.6, 0.6, 0.5)  # gray-ish = generic NPC
		amb_node.add_child(amb_sprite)

		var amb_label := Label.new()
		amb_label.name = "NameLabel"
		amb_label.text = amb_name
		amb_label.position = Vector2(-25, -28)
		amb_label.add_theme_font_size_override("font_size", 10)
		amb_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.6))
		amb_node.add_child(amb_label)

		var amb_area := Area2D.new()
		amb_area.name = "InteractArea"
		var amb_shape := CollisionShape2D.new()
		var amb_rect := RectangleShape2D.new()
		amb_rect.size = COL_AMBIENT
		amb_shape.shape = amb_rect
		amb_area.add_child(amb_shape)
		amb_node.add_child(amb_area)

		var amb_script := GDScript.new()
		amb_script.source_code = """extends Node2D

func interact():
	var line = get_meta("dialogue_line", "...")
	DialogueManager.show_simple_message(get_meta("npc_name", "NPC"), line)
"""
		amb_script.reload()
		amb_node.set_script(amb_script)
		amb_node.set_meta("dialogue_line", amb_dialogue)
		amb_node.set_meta("npc_name", amb_name)
		amb_node.add_to_group("interactable")

		location_root.add_child(amb_node)

	# --- Shop NPC (if location has shop data) ---
	var shop_data: Array = data.get("shop", [])
	if shop_data.size() > 0:
		var shop_npc := Node2D.new()
		shop_npc.name = "Shopkeeper"
		shop_npc.position = Vector2(200, -40)

		var shop_sprite := ColorRect.new()
		shop_sprite.name = "Sprite"
		shop_sprite.size = Vector2(20, 24)
		shop_sprite.position = Vector2(-10, -12)
		shop_sprite.color = Color(0.2, 0.7, 0.2)  # green = merchant
		shop_npc.add_child(shop_sprite)

		var shop_label := Label.new()
		shop_label.name = "NameLabel"
		shop_label.text = "Shop"
		shop_label.position = Vector2(-15, -30)
		shop_label.add_theme_font_size_override("font_size", 12)
		shop_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3))
		shop_npc.add_child(shop_label)

		var shop_area := Area2D.new()
		shop_area.name = "InteractArea"
		var shop_shape := CollisionShape2D.new()
		var shop_rect := RectangleShape2D.new()
		shop_rect.size = COL_SHOP
		shop_shape.shape = shop_rect
		shop_area.add_child(shop_shape)
		shop_npc.add_child(shop_area)

		var shop_script := GDScript.new()
		shop_script.source_code = """extends Node2D

func interact():
	var shop_ui = get_tree().current_scene.get_node_or_null("ShopUI")
	if shop_ui and shop_ui.has_method("open_shop"):
		shop_ui.open_shop()
	else:
		DialogueManager.show_simple_message("Shopkeeper", "Welcome! (Shop UI not available)")
"""
		shop_script.reload()
		shop_npc.set_script(shop_script)
		shop_npc.add_to_group("interactable")
		location_root.add_child(shop_npc)

	# Reset player position
	var player = get_tree().current_scene.get_node_or_null("Player")
	if player:
		player.position = Vector2(0, 100)

	# Show entry text (location description)
	var entry_text: String = data.get("entry_text", "")
	if entry_text != "" and not GameManager.has_flag("visited_" + data.get("id", "")):
		GameManager.set_flag("visited_" + data.get("id", ""))
		await get_tree().create_timer(0.3).timeout
		DialogueManager.show_simple_message("", entry_text)

func _process(_delta: float) -> void:
	if is_transitioning or BattleManager.in_battle or DialogueManager.is_playing:
		return
	# Track player movement for random encounters
	var player = get_tree().current_scene.get_node_or_null("Player")
	if player and player.velocity.length() > 10:
		_check_encounter()

var _last_encounter_check: float = 0.0

func _check_encounter() -> void:
	var encounters: Array = current_location_data.get("encounters", [])
	if encounters.is_empty():
		return

	step_count += 1
	if step_count < steps_until_encounter:
		return

	# Roll for encounter
	var enc: Dictionary = encounters[randi() % encounters.size()]
	var rate: float = enc.get("encounter_rate", 0.15)
	if enc.get("trigger", "random") != "random":
		return

	if randf() < rate:
		step_count = 0
		steps_until_encounter = randi_range(15, 40)
		var enemy_ids: Array = enc.get("enemy_ids", [])
		if enemy_ids.size() > 0:
			start_encounter(enemy_ids)

func start_encounter(enemy_ids: Array) -> void:
	var player = get_tree().current_scene.get_node_or_null("Player")
	if player:
		player.can_move = false

	# Flash effect
	var fader = _get_fader()
	if fader:
		await fader.fade_out(0.15)
		await get_tree().create_timer(0.1).timeout
		await fader.fade_in(0.1)
		await get_tree().create_timer(0.05).timeout
		await fader.fade_out(0.2)

	AudioManager.play_battle_bgm()
	BattleManager.start_battle(enemy_ids, GameManager.current_location_id)

	# When battle ends, return to exploration
	if not BattleManager.battle_ended.is_connected(_on_battle_ended):
		BattleManager.battle_ended.connect(_on_battle_ended, CONNECT_ONE_SHOT)

func _on_battle_ended(_victory: bool) -> void:
	var fader = _get_fader()
	if fader:
		await fader.fade_in(0.3)
	var player = get_tree().current_scene.get_node_or_null("Player")
	if player:
		player.can_move = true
	# Resume location BGM
	AudioManager.resume_location_bgm()

func _get_fader():
	var main = get_tree().current_scene
	if main:
		return main.get_node_or_null("UI/ScreenFader")
	return null

func _get_hud():
	var main = get_tree().current_scene
	if main:
		return main.get_node_or_null("UI/HUD")
	return null
