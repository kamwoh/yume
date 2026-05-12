extends Node
class_name OverlayManager

## ADR 0012 — Tutorial overlay primitive.
##
## Manages an overlay STACK: each overlay is a CanvasLayer + Control
## hierarchy (title + body Labels, optional dim backdrop) instantiated
## via ControlFactory. Overlays auto-dismiss when their advance condition
## is met (input action, named signal, or timer), emitting an
## `overlay_advanced` signal that downstream rules listen for to chain
## tutorial steps.
##
## Per ADR 0021, this module EXPOSES Godot's CanvasLayer + Control + signal
## machinery. The advance-condition state machine + sequencing is the
## genuinely Yume-specific contribution.
##
## Wiring: OverlayManager expects to be a child of a Node whose script is
## `World`. Sibling of GameShell + ScreenFlow.
##
## Interaction with screen_flow (ADR 0011): both push CanvasLayers but
## OverlayManager uses higher layer indices (40+) so overlays render
## above any active screens. World freeze is the union of
## `screen_freeze_world` and `overlay_freeze_world`.
##
## Phase A scope: title + body + 4 advance conditions + skip + freeze
## coordination. NOT in Phase A: highlight rendering (shader + tween),
## scheduled for Phase B.

# ============================================================
# STATE
# ============================================================

var _world: Node = null

# Active overlays — array of:
#   {"id": str, "layer": CanvasLayer, "spec": Dictionary,
#    "elapsed": float, "advance_action_pressed_was": bool}
var _stack: Array = []

# ============================================================
# LIFECYCLE
# ============================================================


func _ready() -> void:
	_world = get_parent()
	if _world == null or not _world.has_method("_build_env"):
		push_error("OverlayManager must be a child of a World node")
		return
	# Ensure env has overlay_event_buffer
	var sched = _world.get("scheduler")
	if sched != null and sched.get("env") != null:
		var env: Dictionary = sched.env
		if not env.has("overlay_event_buffer"):
			env["overlay_event_buffer"] = []


func _process(delta: float) -> void:
	if _world == null:
		return
	_drain_overlay_events()
	_advance_active_overlay(delta)
	_apply_freeze_state()


# ============================================================
# EVENT DRAIN (show / dismiss)
# ============================================================


func _drain_overlay_events() -> void:
	var sched = _world.get("scheduler")
	if sched == null:
		return
	var env: Dictionary = sched.env
	var buf = env.get("overlay_event_buffer", null)
	if not (buf is Array) or (buf as Array).is_empty():
		return
	env["overlay_event_buffer"] = []
	for ev in buf:
		if not (ev is Dictionary):
			continue
		var name := str(ev.get("event", ""))
		match name:
			"show_overlay":
				_show_overlay(ev as Dictionary)
			"dismiss_overlay":
				_dismiss_overlay(str((ev as Dictionary).get("id", "")), "manual")


# ============================================================
# SHOW / DISMISS
# ============================================================


func _show_overlay(spec: Dictionary) -> void:
	var id := str(spec.get("id", ""))
	# Empty id is allowed (anonymous overlays); we generate a unique one.
	if id == "":
		id = "_overlay_%d" % (Time.get_ticks_msec())
		spec["id"] = id
	# Idempotent: if id is already on the stack, no-op. Prevents duplicate
	# stacking when a tick rule fires the same show_overlay every tick
	# until its query condition flips.
	for entry in _stack:
		if str((entry as Dictionary).get("id", "")) == id:
			return
	# Build CanvasLayer at 40 + stack depth (so subsequent overlays stack on top)
	var layer := CanvasLayer.new()
	layer.layer = 40 + _stack.size()
	add_child(layer)

	# Optional dim backdrop (only if freeze_world OR explicit backdrop_alpha)
	var freeze_world := bool(spec.get("freeze_world", true))
	var backdrop_alpha := float(spec.get("backdrop_alpha", 0.5 if freeze_world else 0.0))
	if backdrop_alpha > 0.0:
		var bg := ColorRect.new()
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_STOP
		var c := Color(spec.get("backdrop_color", "#000000"))
		c.a = backdrop_alpha
		bg.color = c
		layer.add_child(bg)

	# Container for title + body
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_PASS
	layer.add_child(root)

	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_CENTER)
	vb.grow_horizontal = Control.GROW_DIRECTION_BOTH
	vb.grow_vertical = Control.GROW_DIRECTION_BOTH
	vb.add_theme_constant_override("separation", 16)
	root.add_child(vb)

	var title := str(spec.get("title", ""))
	if title != "":
		var lbl_t := Label.new()
		lbl_t.text = ControlFactory._resolve_text(title)
		lbl_t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl_t.add_theme_font_size_override("font_size", int(spec.get("title_font_size", 32)))
		lbl_t.add_theme_color_override("font_color", Color(spec.get("title_color", "#fdd068")))
		lbl_t.add_theme_color_override("font_outline_color", Color.BLACK)
		lbl_t.add_theme_constant_override("outline_size", 4)
		vb.add_child(lbl_t)

	var body := str(spec.get("body", ""))
	if body != "":
		var lbl_b := Label.new()
		lbl_b.text = ControlFactory._resolve_text(body)
		lbl_b.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl_b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl_b.custom_minimum_size = Vector2(540, 0)
		lbl_b.add_theme_font_size_override("font_size", int(spec.get("body_font_size", 20)))
		lbl_b.add_theme_color_override("font_color", Color(spec.get("body_color", "#f0e0c0")))
		lbl_b.add_theme_color_override("font_outline_color", Color.BLACK)
		lbl_b.add_theme_constant_override("outline_size", 3)
		vb.add_child(lbl_b)

	# Push to stack
	(
		_stack
		. append(
			{
				"id": id,
				"layer": layer,
				"spec": spec,
				"elapsed": 0.0,
				# Track edge for advance_action so a held key fires once
				"advance_action_pressed_was": false,
				"skip_pressed_was": false,
			}
		)
	)


## Pop matching overlay id and emit overlay_advanced.
## reason: "action" / "signal" / "timer" / "skip" / "manual"
func _dismiss_overlay(id: String, reason: String) -> void:
	var idx := -1
	for i in range(_stack.size()):
		if str((_stack[i] as Dictionary).get("id", "")) == id:
			idx = i
			break
	if idx < 0:
		return
	var entry: Dictionary = _stack[idx]
	(entry["layer"] as Node).queue_free()
	_stack.remove_at(idx)
	_emit_overlay_advanced(id, reason)


func _emit_overlay_advanced(id: String, reason: String) -> void:
	if _world == null:
		return
	var sched = _world.get("scheduler")
	if sched == null:
		return
	var env: Dictionary = sched.env
	var buf = env.get("signal_buffer", null)
	if not (buf is Array):
		buf = []
		env["signal_buffer"] = buf
	(
		(buf as Array)
		. append(
			{
				"name": "overlay_advanced",
				"payload": {"id": id, "reason": reason},
			}
		)
	)


# ============================================================
# ADVANCE CONDITIONS
# ============================================================


## Per-frame: only the TOP overlay of the stack is interactive.
## Check its advance conditions and dismiss if any fires.
func _advance_active_overlay(delta: float) -> void:
	if _stack.is_empty():
		return
	var top: Dictionary = _stack[_stack.size() - 1]
	var spec: Dictionary = top["spec"]
	top["elapsed"] = float(top.get("elapsed", 0.0)) + delta

	# advance_after_seconds
	var after_s = spec.get("advance_after_seconds", null)
	if after_s != null:
		if float(top["elapsed"]) >= float(after_s):
			_dismiss_overlay(str(top["id"]), "timer")
			return

	# advance_action
	var action := str(spec.get("advance_action", ""))
	if action != "" and InputMap.has_action(action):
		var pressed := Input.is_action_pressed(action)
		var was := bool(top.get("advance_action_pressed_was", false))
		top["advance_action_pressed_was"] = pressed
		if pressed and not was:
			_dismiss_overlay(str(top["id"]), "action")
			return

	# advance_signal — observe (don't consume) signal_buffer
	var sig_name := str(spec.get("advance_signal", ""))
	if sig_name != "":
		if _signal_in_buffer(sig_name):
			_dismiss_overlay(str(top["id"]), "signal")
			return

	# Skip via ui_cancel (default)
	if bool(spec.get("skippable", true)) and InputMap.has_action("ui_cancel"):
		var skip_pressed := Input.is_action_pressed("ui_cancel")
		var skip_was := bool(top.get("skip_pressed_was", false))
		top["skip_pressed_was"] = skip_pressed
		if skip_pressed and not skip_was:
			_dismiss_overlay(str(top["id"]), "skip")
			return


## Check if `signal_buffer` contains a signal with the given name.
## Observe-only (don't clear) — phase_scheduler clears it during tick.
func _signal_in_buffer(name: String) -> bool:
	if _world == null:
		return false
	var sched = _world.get("scheduler")
	if sched == null:
		return false
	var env: Dictionary = sched.env
	var buf = env.get("signal_buffer", null)
	if not (buf is Array):
		return false
	for sig in buf as Array:
		if sig is Dictionary and str((sig as Dictionary).get("name", "")) == name:
			return true
	return false


# ============================================================
# FREEZE COORDINATION
# ============================================================


## Set world_state["overlay_freeze_world"] = 1 if any active overlay
## requests freeze. World.gd checks both screen_freeze_world AND
## overlay_freeze_world before ticking.
func _apply_freeze_state() -> void:
	if _world == null:
		return
	var ws = _world.get("world_state")
	if not (ws is Dictionary):
		return
	var freeze := false
	for entry in _stack:
		var spec: Dictionary = (entry as Dictionary)["spec"]
		if bool(spec.get("freeze_world", true)):
			freeze = true
			break
	(ws as Dictionary)["overlay_freeze_world"] = 1 if freeze else 0
