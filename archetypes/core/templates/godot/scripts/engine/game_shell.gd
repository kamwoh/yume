extends Node
class_name GameShell

## Generic JSON-driven game shell (Tier 2.6h).
##
## Reads `<data_root>/scene.json` and `<data_root>/hud.json` and builds:
##   - Pond/world bounds visual (Polygon2D floor + Line2D border)
##   - Camera2D follow-tag behavior + zoom
##   - HUD CanvasLayer with Label / ProgressBar elements bound to entity state
##   - Controls hint label
##   - Win / lose condition watchers + restart-on-R
##
## This script is **engine** code (universal). Per-game customization lives
## entirely in JSON. Adding a new game = writing scene.json + hud.json,
## never editing GDScript or .tscn.
##
## Wiring: GameShell expects to be a child of a Node whose script is
## `World` (the data-driven simulation host). Scene structure:
##   World (root, type=Node, script=res://scripts/engine/world.gd)
##   ├─ GameShell (this node)
##   └─ Camera2D
## GameShell creates its own children at runtime: PondFloor, PondBorder,
## HUD CanvasLayer with Control children.
##
## Schema sketch (see docs/30 ... eventually):
##   scene.json: {tick_seconds, camera: {follow_tag, lerp, zoom},
##                bounds: {min, max, floor_color, border_color, border_width}}
##   hud.json:   {panels: [{anchor, elements: [...]}],
##                controls_hint, win, lose}

# ------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------

var _scene_cfg: Dictionary = {}
var _hud_cfg: Dictionary = {}

# Runtime references built in _ready
var _world: Node = null            # parent (World instance)
var _camera: Camera2D = null
var _hud_layer: CanvasLayer = null
var _win_panel: Panel = null
var _win_label: Label = null

# Per-element binding state — { Control_node : binding_spec_dict }
var _bound_elements: Array = []

var _won: bool = false
var _lost: bool = false
var _sustain_counter: int = 0


# ============================================================
# LIFECYCLE
# ============================================================

func _ready() -> void:
	_world = get_parent()
	if _world == null or not _world.has_method("_build_env"):
		push_error("GameShell must be a child of a World node")
		return
	_camera = _world.get_node_or_null("Camera2D")
	_load_configs()
	# Apply tick_seconds override if specified
	if _scene_cfg.has("tick_seconds") and _world.get("tick_seconds") != null:
		_world.set("tick_seconds", float(_scene_cfg["tick_seconds"]))
	_build_bounds()
	_build_hud()


func _process(_delta: float) -> void:
	if _won or _lost:
		# After freeze, only listen for restart
		if Input.is_action_just_pressed("ui_accept") or Input.is_key_label_pressed(KEY_R):
			get_tree().reload_current_scene()
		return
	_update_camera_follow()
	_update_bound_elements()
	_check_win_lose()


# ============================================================
# CONFIG LOADING
# ============================================================

func _load_configs() -> void:
	var root := str(_world.get("data_root"))
	if root == "": return
	root = root.rstrip("/")
	_scene_cfg = _read_json(root + "/scene.json")
	_hud_cfg = _read_json(root + "/hud.json")


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	if data is Dictionary: return data
	return {}


# ============================================================
# BOUNDS VISUAL (Polygon2D floor + Line2D border)
# ============================================================

func _build_bounds() -> void:
	var b: Dictionary = _scene_cfg.get("bounds", {}) as Dictionary
	if b.is_empty(): return
	var lo: Vector2 = _to_vec2(b.get("min", [-300, -200]))
	var hi: Vector2 = _to_vec2(b.get("max", [300, 200]))

	# Add bounds as our own children — they render in the default world canvas
	# regardless of parent (CanvasItem inheritance), and we avoid touching
	# World during its _ready (which Godot rejects with "parent busy").
	if b.has("floor_color"):
		var floor := Polygon2D.new()
		floor.polygon = PackedVector2Array([
			Vector2(lo.x, lo.y), Vector2(hi.x, lo.y),
			Vector2(hi.x, hi.y), Vector2(lo.x, hi.y),
		])
		floor.color = _color(b["floor_color"])
		floor.z_index = -50
		add_child(floor)

	if b.has("border_color"):
		var border := Line2D.new()
		border.points = PackedVector2Array([
			Vector2(lo.x, lo.y), Vector2(hi.x, lo.y),
			Vector2(hi.x, hi.y), Vector2(lo.x, hi.y), Vector2(lo.x, lo.y),
		])
		border.width = float(b.get("border_width", 4))
		border.default_color = _color(b["border_color"])
		border.joint_mode = Line2D.LINE_JOINT_BEVEL
		border.z_index = -49
		add_child(border)


# ============================================================
# CAMERA FOLLOW
# ============================================================

func _update_camera_follow() -> void:
	if _camera == null: return
	var cam_cfg: Dictionary = _scene_cfg.get("camera", {}) as Dictionary
	if cam_cfg.is_empty(): return
	# Apply zoom (idempotent)
	if cam_cfg.has("zoom"):
		var z = _to_vec2(cam_cfg["zoom"])
		if _camera.zoom != z: _camera.zoom = z
	# Follow tag
	var tag := str(cam_cfg.get("follow_tag", ""))
	if tag == "": return
	var ent := _find_entity_by_tag(tag)
	if ent == null: return
	if not ent.has_method("get_position"): return
	var p = ent.get_position()
	if p is Vector2:
		var lerp_t := float(cam_cfg.get("lerp", 0.08))
		_camera.position = _camera.position.lerp(p as Vector2, lerp_t)


# ============================================================
# HUD CONSTRUCTION
# ============================================================

func _build_hud() -> void:
	if _hud_cfg.is_empty(): return
	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 10
	add_child(_hud_layer)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(root)

	# Panels
	for panel_cfg in _hud_cfg.get("panels", []):
		_build_panel(root, panel_cfg as Dictionary)

	# Controls hint (bottom-left)
	var hint := str(_hud_cfg.get("controls_hint", ""))
	if hint != "":
		var hl := Label.new()
		hl.text = hint
		hl.position = Vector2(20, 0)
		hl.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
		hl.offset_top = -90
		hl.offset_bottom = -20
		hl.offset_right = 360
		_apply_label_style(hl, 14, Color(0.9, 0.95, 1, 0.85))
		root.add_child(hl)

	# Win / lose panel (hidden until triggered)
	_win_panel = Panel.new()
	_win_panel.set_anchors_preset(Control.PRESET_CENTER)
	_win_panel.size = Vector2(520, 240)
	_win_panel.position = Vector2(-260, -120)
	_win_panel.visible = false
	root.add_child(_win_panel)

	_win_label = Label.new()
	_win_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_win_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_win_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_apply_label_style(_win_label, 28, Color(1, 0.95, 0.7, 1))
	_win_panel.add_child(_win_label)


func _build_panel(root: Control, panel_cfg: Dictionary) -> void:
	var vbox := VBoxContainer.new()
	var anchor := str(panel_cfg.get("anchor", "top-left"))
	match anchor:
		"top-left":
			vbox.position = Vector2(20, 20)
			vbox.size = Vector2(360, 240)
		"top-right":
			vbox.set_anchors_preset(Control.PRESET_TOP_RIGHT)
			vbox.offset_left = -380
			vbox.offset_top = 20
			vbox.offset_right = -20
			vbox.offset_bottom = 240
		"bottom-left":
			vbox.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
			vbox.offset_left = 20
			vbox.offset_top = -240
			vbox.offset_right = 380
			vbox.offset_bottom = -20
	root.add_child(vbox)

	for elem_cfg in panel_cfg.get("elements", []):
		_build_element(vbox, elem_cfg as Dictionary)


func _build_element(parent: Container, cfg: Dictionary) -> void:
	var t := str(cfg.get("type", ""))
	match t:
		"label":
			var lbl := Label.new()
			_apply_label_style(lbl, int(cfg.get("size", 18)),
				_color(cfg.get("color", "#ffffff")))
			parent.add_child(lbl)
			_bound_elements.append({"node": lbl, "cfg": cfg})
		"progress_bar":
			var pb := ProgressBar.new()
			pb.custom_minimum_size = Vector2(280, 16)
			pb.max_value = float(cfg.get("max", 100))
			pb.show_percentage = false
			parent.add_child(pb)
			_bound_elements.append({"node": pb, "cfg": cfg})
		"spacer":
			var sp := Control.new()
			sp.custom_minimum_size = Vector2(1, int(cfg.get("height", 8)))
			parent.add_child(sp)


func _apply_label_style(lbl: Label, font_size: int, color: Color) -> void:
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 4)
	lbl.add_theme_font_size_override("font_size", font_size)


# ============================================================
# HUD UPDATES (per-frame, evaluates bindings)
# ============================================================

func _update_bound_elements() -> void:
	for entry in _bound_elements:
		var node: Node = entry["node"]
		var cfg: Dictionary = entry["cfg"]
		var binding := str(cfg.get("binds", ""))
		if binding == "": continue
		var value = _resolve_binding(binding)
		if value == null: continue
		_apply_binding_to_node(node, cfg, value)


## Resolve a binding path like "player.score" → numeric value.
## Lookup: first entity tagged with the root segment, get_state(field).
## Special root "world" → reads env.world dict.
func _resolve_binding(path: String):
	var parts := path.split(".")
	if parts.size() < 2: return null
	var root := str(parts[0])
	var field := str(parts[1])

	if root == "world":
		var w: Dictionary = (_world.get("world_state") as Dictionary)
		return w.get(field, null) if w != null else null

	var ent := _find_entity_by_tag(root)
	if ent == null: return null
	if ent.has_method("get_state"):
		return ent.get_state(field, null)
	return null


func _apply_binding_to_node(node: Node, cfg: Dictionary, value) -> void:
	if node is Label:
		var lbl: Label = node
		# format_phases: array of strings, picked by float [0, 1]
		if cfg.has("format_phases"):
			var phases: Array = cfg["format_phases"]
			if phases.size() > 0 and (value is float or value is int):
				var idx: int = clamp(int(float(value) * phases.size()), 0, phases.size() - 1)
				lbl.text = str(phases[idx])
				return
		# format with {} placeholder
		var fmt := str(cfg.get("format", "{}"))
		lbl.text = fmt.replace("{}", str(_format_value(value)))
	elif node is ProgressBar:
		var pb: ProgressBar = node
		var v := float(value)
		pb.value = v
		# color_lerp: [low_color, high_color] — interpolate by value/max
		if cfg.has("color_lerp"):
			var arr: Array = cfg["color_lerp"]
			if arr.size() == 2:
				var lo := _color(arr[0])
				var hi := _color(arr[1])
				pb.modulate = lo.lerp(hi, clamp(v / pb.max_value, 0.0, 1.0))


func _format_value(v) -> String:
	if v is float: return "%d" % int(v)  # round to int by default for HUD
	return str(v)


# ============================================================
# WIN / LOSE
# ============================================================

func _check_win_lose() -> void:
	var win_cfg: Dictionary = _hud_cfg.get("win", {}) as Dictionary
	if not win_cfg.is_empty() and _matches(win_cfg):
		_show_outcome(str(win_cfg.get("message", "🌟 YOU WIN! 🌟\nPress R to restart")), true)
		return
	var lose_cfg: Dictionary = _hud_cfg.get("lose", {}) as Dictionary
	if not lose_cfg.is_empty():
		var hit := _matches(lose_cfg)
		var sustained := int(lose_cfg.get("sustained", 0))
		if hit:
			_sustain_counter += 1
			if _sustain_counter >= sustained:
				_show_outcome(str(lose_cfg.get("message", "💀 GAME OVER\nPress R to restart")), false)
		else:
			_sustain_counter = max(0, _sustain_counter - 1)


func _matches(cond: Dictionary) -> bool:
	var binding := str(cond.get("binds", ""))
	var op := str(cond.get("op", ">="))
	var threshold = cond.get("value", 0)
	var v = _resolve_binding(binding)
	if v == null: return false
	var lhs := float(v)
	var rhs := float(threshold)
	match op:
		">=": return lhs >= rhs
		">":  return lhs > rhs
		"<=": return lhs <= rhs
		"<":  return lhs < rhs
		"==": return lhs == rhs
		"!=": return lhs != rhs
	return false


func _show_outcome(message: String, won: bool) -> void:
	if _won or _lost: return
	if won: _won = true
	else: _lost = true
	if _win_label != null:
		_win_label.text = message + "\n\nPress R to restart"
	if _win_panel != null:
		_win_panel.visible = true
	# Freeze World — stops input polling + motion integration. HUD keeps running.
	if _world != null and _world.has_method("set_process"):
		_world.set_process(false)


# ============================================================
# UTIL
# ============================================================

func _find_entity_by_tag(tag: String) -> Object:
	if _world == null: return null
	var entities: Dictionary = _world.get("entities") as Dictionary
	if entities == null: return null
	for ent in entities.values():
		if ent != null and ent.has_method("has_tag") and ent.has_tag(tag):
			return ent
	return null


static func _to_vec2(v) -> Vector2:
	if v is Vector2: return v
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO


static func _color(v) -> Color:
	if v is Color: return v
	if v is String: return Color(str(v))
	return Color.WHITE
