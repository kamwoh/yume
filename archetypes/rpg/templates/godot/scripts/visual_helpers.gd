extends Node

## Visual Helpers — THE visual abstraction layer.
## Priority: 1. Sprite (auto-detect PNG) → 2. Config (visual_config.json) → 3. Fallback defaults
## For 3D: replace this file with a 3D version that loads .glb models.

## Visual config — loaded once, shared across all calls
static var _config: Dictionary = {}
static var _config_loaded: bool = false

static func _ensure_config() -> void:
	if _config_loaded: return
	_config_loaded = true
	var file := FileAccess.open("res://data/visual_config.json", FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		if data is Dictionary:
			_config = data

static func _cfg(section: String, key: String, default = null):
	var s = _config.get(section, {})
	if s is Dictionary:
		return s.get(key, default)
	return default

static func _cfg_vec(section: String, key: String, default: Vector2) -> Vector2:
	var v = _cfg(section, key)
	if v is Array and v.size() >= 2:
		return Vector2(v[0], v[1])
	return default

static func _cfg_color(section: String, key: String, default: Color) -> Color:
	var v = _cfg(section, key)
	if v is Array and v.size() >= 3:
		var a: float = v[3] if v.size() >= 4 else default.a
		return Color(v[0], v[1], v[2], a)
	return default


## Try to load a sprite. Returns true if found.
static func _try_sprite(parent: Node2D, path: String) -> bool:
	if ResourceLoader.exists(path):
		var tex = load(path)
		if tex is Texture2D:
			var sprite := Sprite2D.new()
			sprite.texture = tex
			sprite.name = "Sprite"
			parent.add_child(sprite)
			return true
	return false


static func _add_rect(parent: Node2D, name: String, size: Vector2, pos: Vector2, color: Color, z: int = 0) -> ColorRect:
	var rect := ColorRect.new()
	rect.name = name
	rect.size = size
	rect.position = pos
	rect.color = color
	if z != 0: rect.z_index = z
	parent.add_child(rect)
	return rect


## ============ CHARACTER ============

static func create_character_visual(parent: Node2D, color: Color, is_player: bool = false, character_id: String = "") -> void:
	_ensure_config()

	# Priority 1: Sprite
	if character_id != "":
		var path: String = "res://sprites/characters/" + character_id + ".png"
		if _try_sprite(parent, path):
			var s_size: Vector2 = _cfg_vec("character_base", "shadow_size", Vector2(18, 6))
			var s_off: Vector2 = _cfg_vec("character_base", "shadow_offset", Vector2(-9, 8))
			var s_col: Color = _cfg_color("character_base", "shadow_color", Color(0, 0, 0, 0.3))
			_add_rect(parent, "Shadow", s_size, s_off, s_col, -1)
			return

	# Priority 2: Config-driven shapes
	var body_size: Vector2 = _cfg_vec("character_base", "body_size", Vector2(14, 16))
	var body_off: Vector2 = _cfg_vec("character_base", "body_offset", Vector2(-7, -8))
	var head_size: Vector2 = _cfg_vec("character_base", "head_size", Vector2(12, 12))
	var head_off: Vector2 = _cfg_vec("character_base", "head_offset", Vector2(-6, -18))
	var shadow_size: Vector2 = _cfg_vec("character_base", "shadow_size", Vector2(18, 6))
	var shadow_off: Vector2 = _cfg_vec("character_base", "shadow_offset", Vector2(-9, 8))
	var shadow_col: Color = _cfg_color("character_base", "shadow_color", Color(0, 0, 0, 0.3))

	_add_rect(parent, "Shadow", shadow_size, shadow_off, shadow_col)
	_add_rect(parent, "Body", body_size, body_off, color)
	_add_rect(parent, "Head", head_size, head_off, Color(color.r + 0.1, color.g + 0.1, color.b + 0.1))
	_add_rect(parent, "Hair", Vector2(head_size.x + 2, 4), Vector2(head_off.x - 1, head_off.y - 2), Color(color.r * 0.6, color.g * 0.6, color.b * 0.6))

	if is_player:
		_add_rect(parent, "Glow", Vector2(body_size.x + 4, body_size.y + 4), Vector2(body_off.x - 2, body_off.y - 2), Color(color.r, color.g, color.b, 0.15), -1)


## ============ NPC ============

static func create_npc_visual(parent: Node2D, color: Color, npc_type: String = "default", npc_name: String = "") -> void:
	_ensure_config()

	# Priority 1: Sprite by name
	if npc_name != "":
		var safe_name: String = npc_name.to_lower().replace(" ", "_")
		var path: String = "res://sprites/npcs/" + safe_name + ".png"
		if _try_sprite(parent, path): return
	# Priority 1b: Sprite by type
	if npc_type != "default":
		var path2: String = "res://sprites/npcs/" + npc_type + ".png"
		if _try_sprite(parent, path2): return

	# Priority 2: Config-driven NPC shape
	var type_config: Dictionary = {}
	var npc_types = _config.get("npc_types", {})
	if npc_types is Dictionary:
		type_config = npc_types.get(npc_type, npc_types.get("default", {}))
	if not type_config is Dictionary:
		type_config = {}

	var body_size: Vector2 = Vector2(12, 14)
	var head_size: Vector2 = Vector2(9, 9)
	var bs = type_config.get("body_size")
	if bs is Array and bs.size() >= 2: body_size = Vector2(bs[0], bs[1])
	var hs = type_config.get("head_size")
	if hs is Array and hs.size() >= 2: head_size = Vector2(hs[0], hs[1])

	_add_rect(parent, "Shadow", Vector2(body_size.x + 4, 5), Vector2(-body_size.x / 2 - 2, 8), Color(0, 0, 0, 0.25))
	_add_rect(parent, "Body", body_size, Vector2(-body_size.x / 2, -body_size.y / 2), color)
	_add_rect(parent, "Head", head_size, Vector2(-head_size.x / 2, -body_size.y / 2 - head_size.y), Color(color.r + 0.08, color.g + 0.08, color.b + 0.08))

	# Extras from config (helmet, apron, cape, etc.)
	var extras = type_config.get("extras", [])
	if extras is Array:
		for extra in extras:
			if not extra is Dictionary: continue
			var es = extra.get("size", [10, 4])
			var eo = extra.get("offset", [0, 0])
			var ec = extra.get("color_mult", [1, 1, 1])
			var e_size: Vector2 = Vector2(es[0], es[1]) if es is Array and es.size() >= 2 else Vector2(10, 4)
			var e_off: Vector2 = Vector2(eo[0], eo[1]) if eo is Array and eo.size() >= 2 else Vector2.ZERO
			var e_color := Color(color.r * ec[0], color.g * ec[1], color.b * ec[2]) if ec is Array and ec.size() >= 3 else color
			var e_name: String = str(extra.get("type", "extra"))
			_add_rect(parent, e_name, e_size, e_off, e_color)


## ============ CHEST ============

static func create_chest_visual(parent: Node2D, opened: bool = false) -> void:
	_ensure_config()
	var chest = _config.get("chest", {})
	var base_size: Vector2 = Vector2(18, 10)
	var lid_size: Vector2 = Vector2(18, 6)
	var lock_size: Vector2 = Vector2(4, 4)
	if chest is Dictionary:
		var bs = chest.get("base_size")
		if bs is Array and bs.size() >= 2: base_size = Vector2(bs[0], bs[1])
		var ls = chest.get("lid_size")
		if ls is Array and ls.size() >= 2: lid_size = Vector2(ls[0], ls[1])

	_add_rect(parent, "Shadow", Vector2(base_size.x + 2, 5), Vector2(-base_size.x / 2 - 1, 6), Color(0, 0, 0, 0.25))

	var base_color: Color = Color(0.55, 0.4, 0.15) if not opened else Color(0.35, 0.25, 0.1)
	var lid_color: Color = Color(0.7, 0.55, 0.2) if not opened else Color(0.4, 0.3, 0.12)
	var lock_color: Color = Color(0.8, 0.7, 0.2) if not opened else Color(0.4, 0.35, 0.15)

	_add_rect(parent, "Base", base_size, Vector2(-base_size.x / 2, -base_size.y / 2), base_color)
	_add_rect(parent, "Lid", lid_size, Vector2(-lid_size.x / 2, -base_size.y / 2 - lid_size.y), lid_color)
	_add_rect(parent, "Lock", lock_size, Vector2(-lock_size.x / 2, -base_size.y / 2 - 2), lock_color)

	if not opened:
		_add_rect(parent, "Sparkle", Vector2(3, 3), Vector2(4, -base_size.y / 2 - lid_size.y - 4), Color(1, 0.95, 0.5, 0.8))


## ============ EXIT MARKER ============

static func create_exit_marker(parent: Node2D, label_text: String) -> void:
	_ensure_config()
	var exit_cfg = _config.get("exit_marker", {})
	var pillar_color: Color = Color(0.2, 0.6, 0.9, 0.5)
	var arrow_color: Color = Color(0.3, 0.8, 1.0, 0.8)
	if exit_cfg is Dictionary:
		var pc = exit_cfg.get("pillar_color")
		if pc is Array and pc.size() >= 4: pillar_color = Color(pc[0], pc[1], pc[2], pc[3])
		var ac = exit_cfg.get("arrow_color")
		if ac is Array and ac.size() >= 4: arrow_color = Color(ac[0], ac[1], ac[2], ac[3])

	_add_rect(parent, "Pillar", Vector2(8, 30), Vector2(-4, -18), pillar_color)
	_add_rect(parent, "Arrow1", Vector2(16, 3), Vector2(-8, -20), arrow_color)
	_add_rect(parent, "Arrow2", Vector2(10, 3), Vector2(-5, -23), Color(arrow_color.r, arrow_color.g, arrow_color.b, 0.7))
	_add_rect(parent, "Arrow3", Vector2(4, 3), Vector2(-2, -26), Color(arrow_color.r, arrow_color.g, arrow_color.b, 0.6))

	var lbl := Label.new()
	lbl.text = label_text
	lbl.position = Vector2(-40, -38)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", arrow_color)
	parent.add_child(lbl)

	_add_rect(parent, "Glow", Vector2(20, 4), Vector2(-10, 10), Color(pillar_color.r, pillar_color.g, pillar_color.b, 0.3))


## ============ PROP ============

static func create_prop_visual(parent: Node2D, prop_type: String, base_c: Color) -> void:
	_ensure_config()

	# Priority 1: Sprite
	var path: String = "res://sprites/props/" + prop_type + ".png"
	if _try_sprite(parent, path): return

	# Priority 2: Config-driven prop
	var prop_types = _config.get("prop_types", {})
	var prop_cfg: Dictionary = {}
	if prop_types is Dictionary:
		prop_cfg = prop_types.get(prop_type, prop_types.get("default", {}))
	if not prop_cfg is Dictionary:
		prop_cfg = {}

	# Shadow for all props
	_add_rect(parent, "Shadow", Vector2(14, 4), Vector2(-7, 6), Color(0, 0, 0, 0.2))

	# Check if config has specific shape data
	var has_config: bool = prop_cfg.size() > 0

	if has_config:
		# Generic config-driven prop
		if prop_cfg.has("base_size") and prop_cfg.has("trunk_size"):
			# Tree-like: trunk + canopy
			var trunk_s = prop_cfg.get("trunk_size", [6, 15])
			var canopy_s = prop_cfg.get("canopy_size", [24, 18])
			var ts: Vector2 = Vector2(trunk_s[0], trunk_s[1]) if trunk_s is Array else Vector2(6, 15)
			var cs: Vector2 = Vector2(canopy_s[0], canopy_s[1]) if canopy_s is Array else Vector2(24, 18)
			_add_rect(parent, "Trunk", ts, Vector2(-ts.x / 2, -ts.y + 4), Color(base_c.r * 0.6, base_c.g * 0.5, base_c.b * 0.3))
			_add_rect(parent, "Canopy", cs, Vector2(-cs.x / 2, -ts.y - cs.y + 4), base_c)
		elif prop_cfg.has("base_size") and prop_cfg.has("water_size"):
			# Fountain-like: base + water
			var bs = prop_cfg.get("base_size", [30, 20])
			var ws = prop_cfg.get("water_size", [20, 4])
			var bsv: Vector2 = Vector2(bs[0], bs[1]) if bs is Array else Vector2(30, 20)
			var wsv: Vector2 = Vector2(ws[0], ws[1]) if ws is Array else Vector2(20, 4)
			_add_rect(parent, "Base", bsv, Vector2(-bsv.x / 2, -bsv.y / 2), Color(base_c.r * 0.7, base_c.g * 0.7, base_c.b * 0.7))
			_add_rect(parent, "Water", wsv, Vector2(-wsv.x / 2, -bsv.y / 2 - wsv.y), Color(0.3, 0.5, 0.8, 0.6))
		elif prop_cfg.has("stem_size") and prop_cfg.has("cap_size"):
			# Mushroom-like: stem + cap
			var ss = prop_cfg.get("stem_size", [4, 8])
			var cs = prop_cfg.get("cap_size", [12, 6])
			var ssv: Vector2 = Vector2(ss[0], ss[1]) if ss is Array else Vector2(4, 8)
			var csv: Vector2 = Vector2(cs[0], cs[1]) if cs is Array else Vector2(12, 6)
			_add_rect(parent, "Stem", ssv, Vector2(-ssv.x / 2, -ssv.y + 4), Color(base_c.r * 0.8, base_c.g * 0.8, base_c.b * 0.7))
			_add_rect(parent, "Cap", csv, Vector2(-csv.x / 2, -ssv.y - csv.y + 4), base_c)
		elif prop_cfg.has("post_size") and prop_cfg.has("board_size"):
			# Sign-like: post + board
			var ps = prop_cfg.get("post_size", [3, 16])
			var bs = prop_cfg.get("board_size", [20, 12])
			var psv: Vector2 = Vector2(ps[0], ps[1]) if ps is Array else Vector2(3, 16)
			var bsv: Vector2 = Vector2(bs[0], bs[1]) if bs is Array else Vector2(20, 12)
			_add_rect(parent, "Post", psv, Vector2(-psv.x / 2, -psv.y + 4), Color(base_c.r * 0.6, base_c.g * 0.5, base_c.b * 0.3))
			_add_rect(parent, "Board", bsv, Vector2(-bsv.x / 2, -psv.y - bsv.y + 4), base_c)
		elif prop_cfg.has("base_size") and prop_cfg.has("flame_size"):
			# Torch-like: base + flame
			var bs = prop_cfg.get("base_size", [4, 14])
			var fs = prop_cfg.get("flame_size", [6, 6])
			var bsv: Vector2 = Vector2(bs[0], bs[1]) if bs is Array else Vector2(4, 14)
			var fsv: Vector2 = Vector2(fs[0], fs[1]) if fs is Array else Vector2(6, 6)
			_add_rect(parent, "Base", bsv, Vector2(-bsv.x / 2, -bsv.y + 4), Color(base_c.r * 0.5, base_c.g * 0.4, base_c.b * 0.3))
			_add_rect(parent, "Flame", fsv, Vector2(-fsv.x / 2, -bsv.y - fsv.y + 4), Color(0.9, 0.6, 0.1, 0.8))
		else:
			# Simple box prop
			var sz = prop_cfg.get("size", [16, 16])
			var szv: Vector2 = Vector2(sz[0], sz[1]) if sz is Array else Vector2(16, 16)
			_add_rect(parent, "Body", szv, Vector2(-szv.x / 2, -szv.y / 2), base_c)
	else:
		# No config — simple fallback box
		_add_rect(parent, "Body", Vector2(16, 16), Vector2(-8, -8), base_c)
