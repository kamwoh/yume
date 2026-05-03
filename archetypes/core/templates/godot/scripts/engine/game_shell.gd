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
var _camera: Camera2D = null       # 2D mode camera (if scene has Camera2D)
var _camera3d: Camera3D = null     # 3D mode camera (if scene has Camera3D)
var _hud_layer: CanvasLayer = null
var _win_panel: Panel = null
var _win_label: Label = null

# Floor tint state — modulates floor color by a binding (e.g. clock.sunlight)
var _floor: Polygon2D = null
var _floor_tint_bind: String = ""
var _floor_color_low: Color = Color.BLACK
var _floor_color_high: Color = Color.WHITE

# Tier 2.6l — camera shake + screen flash. Rules emit_shell_event into
# env.shell_event_buffer; we drain each frame and apply to camera/overlay.
var _shake_remaining: int = 0       # frames left of shake
var _shake_intensity: float = 0.0   # px offset magnitude
var _camera_base_pos: Vector2 = Vector2.ZERO
var _flash_overlay: ColorRect = null
var _flash_remaining: int = 0
var _flash_color: Color = Color(1, 0, 0, 0.5)

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
	_camera3d = _world.get_node_or_null("Camera3D")
	_load_configs()
	# Apply tick_seconds override if specified
	if _scene_cfg.has("tick_seconds") and _world.get("tick_seconds") != null:
		_world.set("tick_seconds", float(_scene_cfg["tick_seconds"]))
	_build_bounds()
	_build_hud()
	# Wire shell_event_buffer into the world's env so EffectApply._emit_shell_event
	# has somewhere to push. Scheduler holds the env reference.
	var sched = _world.get("scheduler")
	if sched != null and sched.get("env") != null:
		var env: Dictionary = sched.env
		if not env.has("shell_event_buffer"):
			env["shell_event_buffer"] = []


func _process(_delta: float) -> void:
	if _won or _lost:
		# After freeze, only listen for restart
		if Input.is_action_just_pressed("ui_accept") or Input.is_key_label_pressed(KEY_R):
			get_tree().reload_current_scene()
		return
	_update_camera_follow()
	_update_bound_elements()
	_update_floor_tint()
	_drain_shell_events()
	_update_shake_and_flash()
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
	if b.has("floor_color") or b.has("floor_color_day"):
		var floor := Polygon2D.new()
		floor.polygon = PackedVector2Array([
			Vector2(lo.x, lo.y), Vector2(hi.x, lo.y),
			Vector2(hi.x, hi.y), Vector2(lo.x, hi.y),
		])
		floor.color = _color(b.get("floor_color_day", b.get("floor_color", "#222")))
		floor.z_index = -50
		add_child(floor)
		_floor = floor
		# Optional: tint floor by a state binding (e.g. clock.sunlight) — lerps
		# between floor_color_night (low) and floor_color_day (high) per frame.
		if b.has("floor_tint_binding"):
			_floor_tint_bind = str(b["floor_tint_binding"])
			_floor_color_high = _color(b.get("floor_color_day", "#3a8090"))
			_floor_color_low = _color(b.get("floor_color_night", "#0a0820"))

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

## Tier 2.6l — drain shell events that rules emitted via emit_shell_event.
## Each event is a Dictionary with at least {"event": "shake"|"flash"|...}.
## Unknown events are silently ignored (forward-compatible).
func _drain_shell_events() -> void:
	if _world == null: return
	var sched = _world.get("scheduler")
	if sched == null: return
	var env: Dictionary = sched.env
	var buf: Array = env.get("shell_event_buffer", [])
	if buf.is_empty(): return
	env["shell_event_buffer"] = []
	for ev in buf:
		var name := str(ev.get("event", ""))
		match name:
			"shake":
				var intensity := float(ev.get("intensity", 4.0))
				var duration := int(ev.get("duration", 8))
				if intensity * duration > _shake_intensity * _shake_remaining:
					_shake_intensity = intensity
					_shake_remaining = duration
			"flash":
				var color = ev.get("color", "#ff0000")
				_flash_color = _color(color)
				if not _flash_color.a or _flash_color.a == 0.0:
					_flash_color.a = 0.5
				_flash_remaining = int(ev.get("duration", 8))


## Apply current shake offset to camera + flash alpha to overlay. Both
## decay each frame. No-op when neither is active.
func _update_shake_and_flash() -> void:
	if _camera != null:
		if _shake_remaining > 0:
			# Snapshot the camera's "base" position only when starting fresh
			# so we don't accumulate drift.
			var offset := Vector2(
				(randf() - 0.5) * 2.0 * _shake_intensity,
				(randf() - 0.5) * 2.0 * _shake_intensity
			)
			_camera.offset = offset
			_shake_remaining -= 1
			if _shake_remaining <= 0:
				_camera.offset = Vector2.ZERO
		elif _camera.offset != Vector2.ZERO:
			_camera.offset = Vector2.ZERO
	if _flash_overlay != null:
		if _flash_remaining > 0:
			var t: float = float(_flash_remaining) / 12.0
			_flash_overlay.color = Color(
				_flash_color.r, _flash_color.g, _flash_color.b,
				_flash_color.a * clamp(t, 0.0, 1.0)
			)
			_flash_remaining -= 1
		elif _flash_overlay.color.a > 0.0:
			_flash_overlay.color = Color(0, 0, 0, 0)


## Lerp the floor color between night (low) and day (high) based on the
## binding value (expected 0..1, e.g. clock.sunlight). No-op if no binding
## was configured in scene.json.
func _update_floor_tint() -> void:
	if _floor == null or _floor_tint_bind == "": return
	var v = _resolve_binding(_floor_tint_bind)
	if v == null: return
	var t: float = clamp(float(v), 0.0, 1.0)
	_floor.color = _floor_color_low.lerp(_floor_color_high, t)


## Tier 2.6o — camera mode dispatch. scene.json's camera.mode picks one of:
##   top_down_2d    : Camera2D, optional follow_tag, optional zoom (default)
##   side_scroll_2d : Camera2D, follow x-axis only, y clamped to config
##   fixed          : Camera2D held at camera.position, no follow
##   top_down_3d    : Camera3D directly above entity, orthographic
##   isometric_3d   : Camera3D at 45° angle behind/above, orthographic
##   third_person_3d: Camera3D offset behind entity, perspective (no mouse)
##   first_person_3d: Camera3D at entity eye height (Phase 3 — needs mouse)
##
## Default if unspecified: top_down_2d (preserves prior behavior).
## 3D modes require Camera3D in scene + 3D mesh visual fields on entities.
## Phase 3 adds mouse-look for first_person_3d and orbit for third_person_3d.
func _update_camera_follow() -> void:
	var cam_cfg: Dictionary = _scene_cfg.get("camera", {}) as Dictionary
	if cam_cfg.is_empty(): return
	var mode := str(cam_cfg.get("mode", "top_down_2d"))
	# 2D modes need Camera2D; 3D modes need Camera3D. If wrong type missing,
	# silent skip — content responsibility.
	match mode:
		"top_down_2d":
			if _camera != null:
				_apply_2d_zoom(cam_cfg)
				_camera_top_down_2d(cam_cfg)
		"side_scroll_2d":
			if _camera != null:
				_apply_2d_zoom(cam_cfg)
				_camera_side_scroll_2d(cam_cfg)
		"fixed":
			if _camera != null:
				_apply_2d_zoom(cam_cfg)
				_camera_fixed(cam_cfg)
		"top_down_3d":
			if _camera3d != null: _camera_top_down_3d(cam_cfg)
		"isometric_3d":
			if _camera3d != null: _camera_isometric_3d(cam_cfg)
		"third_person_3d":
			if _camera3d != null: _camera_third_person_3d(cam_cfg)
		_:
			# Unknown mode — fall back to top_down_2d
			if _camera != null:
				_apply_2d_zoom(cam_cfg)
				_camera_top_down_2d(cam_cfg)


func _apply_2d_zoom(cam_cfg: Dictionary) -> void:
	if cam_cfg.has("zoom") and _camera != null:
		var z = _to_vec2(cam_cfg["zoom"])
		if _camera.zoom != z: _camera.zoom = z


func _camera_top_down_2d(cam_cfg: Dictionary) -> void:
	var tag := str(cam_cfg.get("follow_tag", ""))
	if tag == "": return
	var ent := _find_entity_by_tag(tag)
	if ent == null: return
	if not ent.has_method("get_position"): return
	var p = ent.get_position()
	if p is Vector2:
		var lerp_t := float(cam_cfg.get("lerp", 0.08))
		_camera.position = _camera.position.lerp(p as Vector2, lerp_t)


## Side-scroller: camera follows entity's x; y stays at config value
## (or initial position if no fixed_y given). Common for platformers.
func _camera_side_scroll_2d(cam_cfg: Dictionary) -> void:
	var tag := str(cam_cfg.get("follow_tag", ""))
	if tag == "": return
	var ent := _find_entity_by_tag(tag)
	if ent == null: return
	if not ent.has_method("get_position"): return
	var p = ent.get_position()
	if not (p is Vector2): return
	var lerp_t := float(cam_cfg.get("lerp", 0.08))
	var fixed_y := float(cam_cfg.get("fixed_y", _camera.position.y))
	var target := Vector2((p as Vector2).x, fixed_y)
	_camera.position = _camera.position.lerp(target, lerp_t)


## Fixed camera: holds at camera.position from scene.json. No follow.
## Common for cinematic / one-room observer games.
func _camera_fixed(cam_cfg: Dictionary) -> void:
	if cam_cfg.has("position"):
		var pos := _to_vec2(cam_cfg["position"])
		if _camera.position != pos: _camera.position = pos


# ============================================================
# 3D CAMERA MODES (Tier 2.6o Phase 2)
# ============================================================
#
# All three look at the followed entity. Set scene.json:
#   "camera": {
#     "mode": "top_down_3d" | "isometric_3d" | "third_person_3d",
#     "follow_tag": "player",
#     "lerp": 0.1,
#     "height": 20,         // distance above target (3D world units)
#     "distance": 12,       // (third_person_3d) distance behind target
#     "ortho_size": 16      // (top_down_3d, isometric_3d) ortho viewport size
#   }


## Top-down 3D: Camera3D directly above entity, looking down. Orthographic.
## Stardew-but-3D look. World up is +Y; camera at (target.x, +height, target.z).
func _camera_top_down_3d(cam_cfg: Dictionary) -> void:
	var target_v = _follow_target_3d(cam_cfg)
	if target_v == null: return
	var target: Vector3 = target_v
	var height := float(cam_cfg.get("height", 20.0))
	var lerp_t := float(cam_cfg.get("lerp", 0.1))
	var desired := target + Vector3(0, height, 0)
	_camera3d.global_position = _camera3d.global_position.lerp(desired, lerp_t)
	_camera3d.look_at(target, Vector3(0, 0, -1))
	_apply_ortho(cam_cfg, true)


## Isometric 3D: Camera3D at 45° angle behind+above target. Orthographic.
## Tactics-RPG / city-builder look. Convention: 45° rotation around Y, 30° tilt.
func _camera_isometric_3d(cam_cfg: Dictionary) -> void:
	var target_v = _follow_target_3d(cam_cfg)
	if target_v == null: return
	var target: Vector3 = target_v
	var distance := float(cam_cfg.get("distance", 16.0))
	var lerp_t := float(cam_cfg.get("lerp", 0.1))
	# Standard isometric offset: 45° yaw + 30° pitch from target
	var offset := Vector3(distance * 0.6, distance * 0.7, distance * 0.6)
	var desired := target + offset
	_camera3d.global_position = _camera3d.global_position.lerp(desired, lerp_t)
	_camera3d.look_at(target, Vector3.UP)
	_apply_ortho(cam_cfg, true)


## Third-person 3D: Camera3D fixed offset behind entity. Perspective (no
## mouse-orbit yet — that lands in Phase 3 with mouse-input infrastructure).
## For now a static camera-behind-player view. Action-adventure / MMO feel.
func _camera_third_person_3d(cam_cfg: Dictionary) -> void:
	var target_v = _follow_target_3d(cam_cfg)
	if target_v == null: return
	var target: Vector3 = target_v
	var distance := float(cam_cfg.get("distance", 12.0))
	var height := float(cam_cfg.get("height", 5.0))
	var lerp_t := float(cam_cfg.get("lerp", 0.1))
	# Behind on -Z, above on +Y. Phase 3 adds yaw orbit from mouse.
	var desired := target + Vector3(0, height, distance)
	_camera3d.global_position = _camera3d.global_position.lerp(desired, lerp_t)
	_camera3d.look_at(target, Vector3.UP)
	_apply_ortho(cam_cfg, false)


## Resolve follow target's 3D position. Entity might store position as Vector2
## (top-down 2D content) — project onto XZ plane in that case (y=0).
func _follow_target_3d(cam_cfg: Dictionary):
	var tag := str(cam_cfg.get("follow_tag", ""))
	if tag == "": return null
	var ent := _find_entity_by_tag(tag)
	if ent == null: return null
	if not ent.has_method("get_position"): return null
	var p = ent.get_position()
	if p is Vector3:
		return p as Vector3
	if p is Vector2:
		# 2D position → XZ plane in 3D world (y=0)
		return Vector3((p as Vector2).x, 0.0, (p as Vector2).y)
	return null


## Apply orthographic projection if mode wants it. Sets ortho_size from
## config (default 16). Re-set each frame so config edits take effect live.
func _apply_ortho(cam_cfg: Dictionary, want_ortho: bool) -> void:
	if _camera3d == null: return
	if want_ortho:
		_camera3d.projection = Camera3D.PROJECTION_ORTHOGONAL
		_camera3d.size = float(cam_cfg.get("ortho_size", 16.0))
	else:
		_camera3d.projection = Camera3D.PROJECTION_PERSPECTIVE
		_camera3d.fov = float(cam_cfg.get("fov", 75.0))


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

	# Tier 2.6l — full-screen flash overlay for damage / impact feedback
	_flash_overlay = ColorRect.new()
	_flash_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_overlay.color = Color(0, 0, 0, 0)
	root.add_child(_flash_overlay)

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
