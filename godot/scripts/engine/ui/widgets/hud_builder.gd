extends RefCounted
class_name HudBuilder

## JSON-driven HUD: reads `hud.json`, builds a CanvasLayer + Control tree,
## evaluates per-element bindings each frame, and owns the flash overlay
## (shell-event-driven screen tint for damage / impact feedback).
##
## ADR 0021/0044/0045 audit (2026-05-13): JSON-driven Control construction
## is the CORRECT pattern — engine reads hud.json, instantiates Godot
## Controls (Label / ProgressBar / Panel / VBoxContainer / ColorRect),
## applies per-element style overrides. NOT replaceable by Theme +
## PackedScene: that would tie HUD authoring to .tscn files (Godot editor)
## instead of JSON, breaking the LLM-content-generation pipeline.
##
## Owned by GameShell. WinLoseWidget reads `_win_panel` + `_win_label`
## from this widget via the shell back-ref.

# Public-readable from WinLoseWidget (game_shell exposes via the shell ref)
var _hud_layer: CanvasLayer = null
var _win_panel: Panel = null
var _win_label: Label = null

# Flash overlay state — full-screen ColorRect that fades after a "flash"
# shell event. Triggered by GameShell._drain_shell_events → trigger_flash().
var _flash_overlay: ColorRect = null
var _flash_color: Color = Color(1, 0, 0, 0.5)
var _flash_remaining: int = 0

# Per-element binding state — list of {node, cfg} dicts. update_bound_elements()
# iterates and refreshes each Control's text/value from its binding source.
var _bound_elements: Array = []

var _shell: Node = null  # GameShell back-ref (for _resolve_binding / _resolve_at_ref)


func _init(shell: Node) -> void:
	_shell = shell


## Construct the entire HUD tree once at startup. No-op if hud.json was
## empty.
func build(hud_cfg: Dictionary) -> void:
	if hud_cfg.is_empty():
		return
	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 10
	_shell.add_child(_hud_layer)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(root)

	# Tier 2.6l — full-screen flash overlay for damage / impact feedback.
	# Added FIRST so panels + controls-hint render on TOP of it. Empirical
	# case 2026-05-17: prior order (flash added after panels) made damage
	# / sleep flashes cover the entire HUD — vitals bars, controls hint,
	# objective banner all blanked out for the flash's duration. The
	# fix is purely the add-order: later siblings render on top in Godot
	# Control trees, so flash needs to be the FIRST child of HUD root.
	_flash_overlay = ColorRect.new()
	_flash_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_overlay.color = Color(0, 0, 0, 0)
	root.add_child(_flash_overlay)

	# Panels
	for panel_cfg in hud_cfg.get("panels", []):
		_build_panel(root, panel_cfg as Dictionary)

	# Controls hint (bottom-left). ADR 0009 Phase 2c: @-prefix resolution.
	var hint := str(hud_cfg.get("controls_hint", ""))
	if hint.begins_with("@"):
		var resolved_hint := str(_shell.call("_resolve_at_ref", hint))
		if resolved_hint != "":
			hint = resolved_hint
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

	# Win / lose panel (hidden until triggered). Geometry + style are
	# data-driven from the hud.json win/lose block — EVERYTHING configurable
	# (2026-06-06). Optional keys on `win` (or `lose` if win absent):
	#   panel_width (520), panel_height (240), font_size (28),
	#   text_color ("#fff2b3"), panel_color (default theme), inset (16).
	# Defaults reproduce the previous hardcoded look.
	var wl: Dictionary = {}
	if hud_cfg.get("win") is Dictionary:
		wl = hud_cfg["win"]
	elif hud_cfg.get("lose") is Dictionary:
		wl = hud_cfg["lose"]
	var pw := float(wl.get("panel_width", 520))
	var ph := float(wl.get("panel_height", 240))
	var fs := int(wl.get("font_size", 28))
	var inset := float(wl.get("inset", 16))
	var tcol := _color_or(wl.get("text_color", null), Color(1, 0.95, 0.7, 1))

	_win_panel = Panel.new()
	_win_panel.set_anchors_preset(Control.PRESET_CENTER)
	_win_panel.size = Vector2(pw, ph)
	_win_panel.position = Vector2(-pw * 0.5, -ph * 0.5)
	_win_panel.visible = false
	# Optional panel background color (StyleBoxFlat); omit → engine theme.
	if wl.has("panel_color"):
		var sb := StyleBoxFlat.new()
		sb.bg_color = _color_or(wl.get("panel_color"), Color(0.1, 0.1, 0.12, 0.92))
		sb.set_corner_radius_all(8)
		_win_panel.add_theme_stylebox_override("panel", sb)
	root.add_child(_win_panel)

	_win_label = Label.new()
	# Inset the label inside the panel so wrapped text doesn't kiss the edges.
	_win_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_win_label.offset_left = inset
	_win_label.offset_top = inset
	_win_label.offset_right = -inset
	_win_label.offset_bottom = -inset
	_win_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_win_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Wrap long win/lose messages instead of overflowing the panel
	# (2026-06-06: "You gathered all three lost lanterns before nightfall."
	# ran off both edges at font 28 in the 520px panel). WORD_SMART keeps
	# words intact; the label clips to the inset rect as a backstop.
	_win_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_win_label.clip_text = true
	_apply_label_style(_win_label, fs, tcol)
	_win_panel.add_child(_win_label)


# ============================================================
# PANEL + ELEMENT CONSTRUCTION
# ============================================================


func _build_panel(root: Control, panel_cfg: Dictionary) -> void:
	var vbox := VBoxContainer.new()
	var anchor := str(panel_cfg.get("anchor", "top-left"))
	# Unified anchor + size positioning via ControlFactory (#104 v3,
	# 2026-05-16). HUD panels now use the SAME pattern as modal screens:
	# author specifies `anchor` + `width` + `height` + `x_offset` +
	# `y_offset`, the helper computes the four Control offsets so the
	# vbox spans the right rect for that anchor. No more hardcoded per-
	# anchor pixel math here. Defaults preserve the prior layout for
	# back-compat.
	var defaults := _panel_defaults(anchor)
	# Author may specify pixels (number) OR percent-of-viewport ("25%").
	# ControlFactory.resolve_pct converts; viewport queried lazily via
	# _viewport_size (falls back to project's design 960×540 if none yet).
	var vp := ControlFactory._viewport_size(root)
	var w: float = ControlFactory.resolve_pct(panel_cfg.get("width", defaults.get("width", 200)), vp.x)
	var h: float = ControlFactory.resolve_pct(panel_cfg.get("height", defaults.get("height", 240)), vp.y)
	var ox: float = ControlFactory.resolve_pct(panel_cfg.get("x_offset", defaults.get("x_offset", 0)), vp.x)
	var oy: float = ControlFactory.resolve_pct(panel_cfg.get("y_offset", defaults.get("y_offset", 12)), vp.y)
	ControlFactory.apply_anchor_sized_rect(vbox, anchor, w, h, ox, oy)
	# Per-anchor inner alignment default; author override via "align".
	var default_align: String = defaults.get("align", "begin")
	var align := str(panel_cfg.get("align", default_align))
	match align:
		"begin":
			vbox.alignment = BoxContainer.ALIGNMENT_BEGIN
		"center":
			vbox.alignment = BoxContainer.ALIGNMENT_CENTER
		"end":
			vbox.alignment = BoxContainer.ALIGNMENT_END
	root.add_child(vbox)

	# Centered anchors expect their child labels to render horizontally
	# centered inside the vbox. Default Label alignment is LEFT; pass an
	# alignment hint to _build_element.
	var center_children := anchor in ["center", "top-center", "bottom-center"]
	for elem_cfg in panel_cfg.get("elements", []):
		_build_element(vbox, elem_cfg as Dictionary, center_children)


## Resolve size_flags_horizontal for a progress_bar element. Default
## SHRINK_BEGIN keeps the bar at its authored width inside a vbox; author
## can set `size_flags_h: "expand_fill"` if they want a full-width bar.
func _size_flag_for_progress_bar(cfg: Dictionary) -> int:
	var s := str(cfg.get("size_flags_h", "shrink_begin"))
	match s:
		"shrink_begin":
			return Control.SIZE_SHRINK_BEGIN
		"shrink_center":
			return Control.SIZE_SHRINK_CENTER
		"shrink_end":
			return Control.SIZE_SHRINK_END
		"expand":
			return Control.SIZE_EXPAND
		"expand_fill":
			return Control.SIZE_EXPAND_FILL
		"fill":
			return Control.SIZE_FILL
	return Control.SIZE_SHRINK_BEGIN


## Per-anchor default size + offset + inner alignment. Match the
## historical hud_builder layout for back-compat. Author overrides any
## via `width`/`height`/`x_offset`/`y_offset`/`align` in panel cfg.
func _panel_defaults(anchor: String) -> Dictionary:
	match anchor:
		"top-left":
			return {"width": 360, "height": 240, "x_offset": 20, "y_offset": 50, "align": "begin"}
		"top-right":
			return {"width": 200, "height": 320, "x_offset": -10, "y_offset": 12, "align": "end"}
		"top-center":
			return {"width": 760, "height": 32, "x_offset": 0, "y_offset": 12, "align": "center"}
		"center":
			return {"width": 64, "height": 64, "x_offset": 0, "y_offset": 0, "align": "center"}
		"center-left":
			return {"width": 200, "height": 240, "x_offset": 20, "y_offset": 0, "align": "begin"}
		"center-right":
			return {"width": 200, "height": 240, "x_offset": -20, "y_offset": 0, "align": "begin"}
		"bottom-left":
			return {"width": 360, "height": 220, "x_offset": 20, "y_offset": -20, "align": "begin"}
		"bottom-center":
			return {"width": 920, "height": 30, "x_offset": 0, "y_offset": -10, "align": "center"}
		"bottom-right":
			return {"width": 360, "height": 220, "x_offset": -20, "y_offset": -20, "align": "begin"}
		_:
			return {"width": 200, "height": 240, "x_offset": 0, "y_offset": 0, "align": "begin"}


func _build_element(parent: Container, cfg: Dictionary, center_h: bool = false) -> void:
	var t := str(cfg.get("type", ""))
	match t:
		"label":
			var lbl := Label.new()
			_apply_label_style(lbl, int(cfg.get("size", 18)), _color(cfg.get("color", "#ffffff")))
			# Static text — set immediately (binding-less labels would
			# otherwise render empty since _apply_binding_to_node only
			# fires when `binds` is set). Per data-demo.md text discipline:
			# format strings start with capital letter or → to bypass
			# the formula evaluator.
			if cfg.has("text"):
				lbl.text = str(cfg["text"])
			# Per-label `align` hint overrides panel default.
			var align := str(cfg.get("align", ""))
			if align == "center" or (align == "" and center_h):
				lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			elif align == "right":
				lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			parent.add_child(lbl)
			_bound_elements.append({"node": lbl, "cfg": cfg})
		"progress_bar":
			var pb := ProgressBar.new()
			# Honor explicit width/height when authored; default 280x16.
			var pb_w: float = float(cfg.get("width", 280))
			var pb_h: float = float(cfg.get("height", 16))
			pb.custom_minimum_size = Vector2(pb_w, pb_h)
			pb.max_value = float(cfg.get("max", 100))
			pb.show_percentage = false
			# Default to SHRINK_BEGIN so the bar respects its authored width
			# instead of expanding to fill the parent vbox (#104 v4 fix,
			# 2026-05-16). Without this, vital bars in a 360-wide bottom-left
			# panel stretched to 360 px wide each, overlapping visually with
			# the inventory cells on the right side of the screen. Author can
			# override via `size_flags_h`.
			pb.size_flags_horizontal = _size_flag_for_progress_bar(cfg)
			parent.add_child(pb)
			_bound_elements.append({"node": pb, "cfg": cfg})
		"spacer":
			var sp := Control.new()
			sp.custom_minimum_size = Vector2(1, int(cfg.get("height", 8)))
			parent.add_child(sp)
		"crosshair":
			# Simple text-based crosshair — Label with a glyph. In
			# 3rd-person mode the glyph re-positions per-frame to track
			# the player's facing-direction projection on screen (task
			# #106). FPS mode leaves it centered.
			var ch := Label.new()
			ch.text = str(cfg.get("glyph", "+"))
			_apply_label_style(ch, int(cfg.get("size", 28)), _color(cfg.get("color", "#ffffff")))
			ch.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			ch.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			parent.add_child(ch)
			# Tag with type so update_bound_elements applies the dynamic
			# POV offset each frame.
			var ch_cfg: Dictionary = cfg.duplicate()
			ch_cfg["type"] = "crosshair"
			_bound_elements.append({"node": ch, "cfg": ch_cfg})
		"minimap":
			# Drawn-dot top-down map. See minimap_widget.gd for spec docs.
			var mm := MinimapWidget.new()
			mm.configure(cfg)
			mm.bind_world(_shell.get("_world"))
			parent.add_child(mm)
			_bound_elements.append({"node": mm, "cfg": cfg})
		"slot_grid":
			# Tier-A inventory primitive (#99). Same builder + updater as
			# ControlFactory uses for modal screens — one source of truth.
			var sg := ControlFactory._build_slot_grid(cfg)
			parent.add_child(sg)
			_bound_elements.append({"node": sg, "cfg": cfg})


func _apply_label_style(lbl: Label, font_size: int, color: Color) -> void:
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 4)
	lbl.add_theme_font_size_override("font_size", font_size)


# ============================================================
# PER-FRAME UPDATES
# ============================================================


## Walk bound elements + re-evaluate their bindings. Called from
## GameShell._process. Cheap O(N bound elements) per frame.
func update_bound_elements() -> void:
	for entry in _bound_elements:
		var node: Node = entry["node"]
		var cfg: Dictionary = entry["cfg"]
		# Minimap self-redraws per frame from live world.entities;
		# no string binding needed.
		if node is MinimapWidget:
			(node as MinimapWidget).tick()
			continue
		# slot_grid: dispatch shared updater that resolves binds (array)
		# + active_binds (int) and rewrites per-cell content + active style.
		if node.has_meta("slot_grid_cfg"):
			ControlFactory.update_slot_grid(
				node, Callable(_shell, "_resolve_binding")
			)
			continue
		# Dynamic-POV crosshair (task #106). When camera mode is third-
		# person, position the crosshair to match the player-facing
		# direction projected to screen space (camera_director writes
		# world_state.crosshair_screen_x/y). FPS mode leaves the label
		# centered.
		if cfg.get("type", "") == "crosshair":
			_apply_crosshair_pov(node as Label)
			continue
		var binding := str(cfg.get("binds", ""))
		if binding == "":
			continue
		var value = _shell.call("_resolve_binding", binding)
		if value == null:
			continue
		_apply_binding_to_node(node, cfg, value)


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
		# format with {} placeholder. ADR 0009 Phase 2c: @strings.x.y
		# refs resolve via ui/strings.json.
		var fmt := str(cfg.get("format", "{}"))
		if fmt.begins_with("@"):
			var resolved := str(_shell.call("_resolve_at_ref", fmt))
			if resolved != "":
				fmt = resolved
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


static func _format_value(v) -> String:
	if v is float:
		return "%d" % int(v)  # round to int by default for HUD
	return str(v)


# ============================================================
# FLASH OVERLAY (shell-event-driven)
# ============================================================


## Called from GameShell._drain_shell_events when a "flash" event drains.
## Sets the overlay color + remaining frame count.
func trigger_flash(color, duration: int) -> void:
	_flash_color = _color(color)
	if not _flash_color.a or _flash_color.a == 0.0:
		_flash_color.a = 0.5
	# A flash is FEEDBACK — a translucent tint over the scene, never a full
	# obscure. A 6-digit hex (e.g. "#ff0000") parses to alpha 1.0, which would
	# blank the whole screen on every hit (you can't see what's attacking you).
	# Cap it so an opaque color still reads as a flash, not a wipe. For an
	# intentional full-screen wipe use screen_fade. Empirical 2026-06-06:
	# doomarena3d's "#ff0000" damage flash washed the screen solid red on every
	# monster melee, hiding the enemies, once monsters could actually reach the
	# player.
	_flash_color.a = minf(_flash_color.a, 0.5)
	_flash_remaining = duration


## Per-frame flash decay. Called from GameShell._process.
func tick_flash() -> void:
	if _flash_overlay == null:
		return
	if _flash_remaining > 0:
		var t: float = float(_flash_remaining) / 12.0
		_flash_overlay.color = Color(
			_flash_color.r,
			_flash_color.g,
			_flash_color.b,
			_flash_color.a * clamp(t, 0.0, 1.0),
		)
		_flash_remaining -= 1
	elif _flash_overlay.color.a > 0.0:
		_flash_overlay.color = Color(0, 0, 0, 0)


# ============================================================
# LOCAL HELPERS
# ============================================================


## Local hex/array → Color helper. Avoids the indirect _shell.call for the
## common case (used heavily during build_element).
static func _color(v) -> Color:
	if v is Color:
		return v
	if v is String:
		return Color(v as String)
	return Color.WHITE


## Like _color but null/invalid → the supplied default (not white). Used by
## the data-driven win/lose panel where omitted fields keep their defaults.
static func _color_or(v, fallback: Color) -> Color:
	if v is Color:
		return v
	if v is String and (v as String) != "":
		return Color(v as String)
	return fallback


## Dynamic-POV crosshair positioning (task #106). When camera_mode is
## third_person_3d, camera_director writes world_state.crosshair_screen_x
## and crosshair_screen_y (in viewport pixels) per frame. We move the
## crosshair Label to that screen pixel. FPS mode (sentinel < 0) leaves
## the label centered. Called every frame from update_bound_elements.
func _apply_crosshair_pov(lbl: Label) -> void:
	if lbl == null or _shell == null:
		return
	var world = _shell.get("_world")
	if world == null:
		return
	var ws: Dictionary = world.get("world_state") as Dictionary
	if ws == null:
		return
	var sx = ws.get("crosshair_screen_x", -1)
	var sy = ws.get("crosshair_screen_y", -1)
	if not (sx is float or sx is int):
		return
	# Sentinel < 0 = "use default center placement" (FPS mode)
	if float(sx) < 0 or float(sy) < 0:
		# Restore to the default center alignment if we had moved it
		lbl.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		return
	# Custom screen position. Anchor to top-left then offset to (sx, sy)
	# minus half-size so the glyph center lands at the target pixel.
	lbl.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	var half := lbl.size / 2.0
	lbl.position = Vector2(float(sx) - half.x, float(sy) - half.y)
