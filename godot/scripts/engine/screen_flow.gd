extends Node
class_name ScreenFlow

## ADR 0011 — Declarative screen flow.
##
## Reads `<data_root>/screens.json` and runs the screen graph: title,
## game, pause, settings, game_over, etc. Each screen is a JSON-declared
## Godot Control hierarchy (instantiated via ControlFactory).
##
## Per ADR 0021, this module EXPOSES Godot's Control + CanvasLayer + signal
## system; it does not reimplement UI rendering or focus management.
##
## Wiring: ScreenFlow expects to be a child of a Node whose script is
## `World`. Sibling of GameShell. ScreenFlow takes priority over GameShell's
## win/lose + pause-input handling when screens.json is present.
##
## File schema: see docs/adr/0011-declarative-screen-flow.md
##
## States the World needs to coordinate with:
##   world.world_state["current_screen"]      → screen id (binding-readable)
##   world.world_state["screen_freeze_world"] → bool (World checks before tick)
##   env.screen_event_buffer                   → array of pending screen events
##                                               (transition, toast, quit, reload)


# ============================================================
# CONFIG
# ============================================================

var _cfg: Dictionary = {}                # parsed screens.json
var _screens_by_id: Dictionary = {}      # id → screen-spec dict
var _world: Node = null                  # parent (World instance)
var _starting_screen: String = ""

# Modal stack — array of {id, layer (CanvasLayer), bound (Array)}.
# Top of stack = active screen. Underneath modals stay rendered + frozen.
var _stack: Array = []

# Toast layer — shared CanvasLayer above all screens for transient labels.
var _toast_layer: CanvasLayer = null

# Per-screen bound elements with visible_if / enabled_if formulas.
# Re-evaluated each frame for the active screen only.

# Tracks edge for global_inputs (so a held key fires once per press)
var _last_action_state: Dictionary = {}  # action → bool (was pressed last frame)


# ============================================================
# LIFECYCLE
# ============================================================

func _ready() -> void:
	_world = get_parent()
	if _world == null or not _world.has_method("_build_env"):
		push_error("ScreenFlow must be a child of a World node")
		return
	_load_config()
	if _cfg.is_empty():
		# No screens.json — engine auto-launches world (legacy behavior).
		# Mark world_state so binding-readers know there's no screen system.
		_set_world_state("current_screen", "")
		_set_world_state("screen_freeze_world", 0)
		return
	# Install @-resolver as a metadata on Engine so ControlFactory can use it
	# without holding a reference. World's GameShell uses the same string
	# table; we share via the data_root + lazy-load. ControlFactory looks up
	# Engine.has_meta("yume_at_resolver"). Safe across multiple World
	# instances because the resolver closes over _world via this method.
	Engine.set_meta("yume_at_resolver", Callable(self, "_resolve_at_ref"))
	# Ensure env has screen_event_buffer
	var sched = _world.get("scheduler")
	if sched != null and sched.get("env") != null:
		var env: Dictionary = sched.env
		if not env.has("screen_event_buffer"):
			env["screen_event_buffer"] = []
	# Build toast layer (above all screens, below nothing)
	_toast_layer = CanvasLayer.new()
	_toast_layer.layer = 50
	add_child(_toast_layer)
	# Push starting screen SYNCHRONOUSLY (not deferred) so freeze_world lands
	# before the world's first tick — eliminates the "1 frame of game then
	# title" flash. Previously we used call_deferred to wait for
	# SettingsManager's schema load, but only the settings screen depends
	# on that, and the settings screen is never the starting_screen. The
	# title / story splash / etc. don't read the settings schema.
	_starting_screen = str(_cfg.get("starting_screen", ""))
	if _starting_screen != "" and _screens_by_id.has(_starting_screen):
		_push_screen(_starting_screen, false)


func _process(_delta: float) -> void:
	if _cfg.is_empty(): return
	_drain_screen_events()
	_update_bound_elements()
	_handle_global_inputs()


# ============================================================
# CONFIG LOADING
# ============================================================

func _load_config() -> void:
	var root := str(_world.get("data_root"))
	if root == "": return
	root = root.rstrip("/")
	var path := root + "/screens.json"
	if not FileAccess.file_exists(path): return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary): return
	_cfg = data
	for s in _cfg.get("screens", []):
		if s is Dictionary and (s as Dictionary).has("id"):
			_screens_by_id[str((s as Dictionary)["id"])] = s


# ============================================================
# SCREEN MANAGEMENT
# ============================================================

## Push a screen onto the stack. If `as_modal`=true, previous screen stays
## visible underneath (frozen). Otherwise replace the entire stack.
func _push_screen(screen_id: String, as_modal: bool) -> void:
	var spec: Dictionary = _screens_by_id.get(screen_id, {})
	if spec.is_empty():
		push_warning("ScreenFlow: unknown screen id '%s'" % screen_id)
		return
	if not as_modal:
		# Replace: tear down full stack first
		for entry in _stack:
			(entry["layer"] as Node).queue_free()
		_stack.clear()
	# Build new layer + control tree
	var layer := CanvasLayer.new()
	layer.layer = 20 + _stack.size()
	add_child(layer)
	# Optional background color/dim (modal effect)
	if spec.has("background_color") or spec.has("background_alpha"):
		var bg := ColorRect.new()
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_STOP  # block clicks behind modal
		var c := Color(spec.get("background_color", "#000000"))
		c.a = float(spec.get("background_alpha", 1.0))
		bg.color = c
		layer.add_child(bg)
	# Root Control under which all elements mount
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_PASS
	layer.add_child(root)
	# Build elements
	var bound: Array = []
	var dispatcher := Callable(self, "_dispatch_effects")
	for elem in spec.get("elements", []):
		if elem is Dictionary:
			ControlFactory.build(elem as Dictionary, root, dispatcher, bound)
	# ADR 0013: fill any settings_renderer placeholders. ControlFactory
	# leaves them as empty VBoxes; we walk the schema + populate per-setting
	# UI here, where we have access to the SettingsManager sibling.
	_populate_settings_renderers(root, dispatcher)
	# Push entry
	_stack.append({"id": screen_id, "spec": spec, "layer": layer,
				   "bound": bound})
	# Update world_state
	_apply_active_screen()


## Replace top of stack, then push (used by transition_screen target=top).
func _transition_to(screen_id: String) -> void:
	var spec: Dictionary = _screens_by_id.get(screen_id, {})
	if spec.is_empty():
		push_warning("ScreenFlow: transition to unknown screen '%s'" % screen_id)
		return
	var as_modal: bool = bool(spec.get("modal", false))
	_push_screen(screen_id, as_modal)


## Pop top of stack. If empty, no-op (caller's responsibility).
func _pop_screen() -> void:
	if _stack.is_empty(): return
	var top: Dictionary = _stack[_stack.size() - 1]
	(top["layer"] as Node).queue_free()
	_stack.pop_back()
	_apply_active_screen()


## Update world_state["current_screen"] + freeze flag from top of stack.
func _apply_active_screen() -> void:
	if _stack.is_empty():
		_set_world_state("current_screen", "")
		_set_world_state("screen_freeze_world", 0)
		return
	var top: Dictionary = _stack[_stack.size() - 1]
	var spec: Dictionary = top["spec"]
	_set_world_state("current_screen", str(top["id"]))
	_set_world_state("screen_freeze_world",
		1 if bool(spec.get("freeze_world", false)) else 0)


# ============================================================
# EFFECT DISPATCH
# ============================================================

## Invoked by Button.pressed (and other interaction signals). Iterates
## the effect list and applies each via existing effect_apply pipeline.
## Effects flush at end of frame like any other effect.
func _dispatch_effects(effects, _ctx: Dictionary) -> void:
	if not (effects is Array): return
	if _world == null: return
	var sched = _world.get("scheduler")
	if sched == null: return
	var env: Dictionary = sched.env
	for eff in effects:
		if not (eff is Dictionary): continue
		var ctx: Dictionary = {"_rule_id": "screen_flow", "_source": "ui"}
		EffectApply.apply(eff as Dictionary, env, ctx)


# ============================================================
# SCREEN EVENT BUFFER (drained from env.screen_event_buffer each frame)
# ============================================================

## Drain pending screen events emitted by transition_screen / quit_app /
## show_toast / reload_scene effects. Same pattern as GameShell's
## shell_event_buffer.
func _drain_screen_events() -> void:
	if _world == null: return
	var sched = _world.get("scheduler")
	if sched == null: return
	var env: Dictionary = sched.env
	var buf = env.get("screen_event_buffer", null)
	if not (buf is Array) or (buf as Array).is_empty(): return
	env["screen_event_buffer"] = []
	for ev in buf:
		if not (ev is Dictionary): continue
		var name := str(ev.get("event", ""))
		match name:
			"transition_screen":
				var target := str(ev.get("target", ""))
				if target == "":
					push_warning("ScreenFlow: transition_screen missing target")
					continue
				# Special targets:
				#   "@previous" pops the modal stack one level
				#   "@root" pops the entire stack (back to no-screen / gameplay)
				# @root is used by boot flows where multiple modals stack
				# (title → difficulty → story_inheritance) and the user
				# commits to gameplay — popping one-by-one would leave the
				# underneath modals visible.
				if target == "@previous":
					_pop_screen()
				elif target == "@root":
					while not _stack.is_empty():
						_pop_screen()
				else:
					_transition_to(target)
			"quit_app":
				get_tree().quit()
			"show_toast":
				_show_toast(str(ev.get("text", "")), float(ev.get("duration", 2.0)))
			"reload_scene":
				# DESTRUCTIVE — reload the entire current Godot scene.
				# Anything queued after this in the same effect chain was
				# already pushed to the buffer; we still drain them in
				# order, but the next-frame scene reload tears them down.
				# Per `.claude/rules/engine-scripts.md` § effect-chain
				# validation, reload_scene must be LAST in any chain.
				get_tree().reload_current_scene()
			"scene_change":
				# DESTRUCTIVE — full Godot scene swap to target .tscn path.
				# Like reload_scene, must be LAST in any chain (anything
				# queued after gets dropped at end-of-frame).
				var path := str(ev.get("target", ""))
				if path == "":
					push_warning("ScreenFlow: scene_change missing target")
					continue
				var err: int = get_tree().change_scene_to_file(path)
				if err != OK:
					push_warning("ScreenFlow: scene_change failed (path=%s err=%d)"
						% [path, err])


# ============================================================
# TOAST
# ============================================================

## Transient label shown for `duration` seconds, fades out, removes itself.
## Anchored to bottom-center.
func _show_toast(text: String, duration: float) -> void:
	if _toast_layer == null: return
	var resolved := text
	if resolved.begins_with("@"):
		resolved = _resolve_at_ref(resolved)
		if resolved == "": resolved = text
	var lbl := Label.new()
	lbl.text = resolved
	lbl.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	lbl.offset_top = -80
	lbl.offset_bottom = -40
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", Color(1, 1, 0.85, 1))
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 4)
	_toast_layer.add_child(lbl)
	# Tween fade-out using SceneTree's create_tween
	var tween := get_tree().create_tween()
	tween.tween_interval(max(duration - 0.5, 0.1))
	tween.tween_property(lbl, "modulate:a", 0.0, 0.5)
	tween.tween_callback(func(): lbl.queue_free())


# ============================================================
# BOUND ELEMENT UPDATES (visible_if / enabled_if)
# ============================================================

func _update_bound_elements() -> void:
	if _stack.is_empty(): return
	var top: Dictionary = _stack[_stack.size() - 1]
	var bound: Array = top.get("bound", [])
	if bound.is_empty(): return
	var ctx: Dictionary = _formula_ctx()
	for entry in bound:
		var node: Control = entry["node"]
		var cfg: Dictionary = entry["cfg"]
		if cfg.has("visible_if"):
			var v = _eval_formula(str(cfg["visible_if"]), ctx)
			node.visible = bool(v) if v != null else true
		if cfg.has("enabled_if") and node is Button:
			var v2 = _eval_formula(str(cfg["enabled_if"]), ctx)
			(node as Button).disabled = not (bool(v2) if v2 != null else true)


func _formula_ctx() -> Dictionary:
	# Minimal context for visible_if/enabled_if: world.* keys readable.
	# Future extension: per-screen state, per-element params.
	var ws: Dictionary = (_world.get("world_state") as Dictionary) if _world != null else {}
	return {"world": ws}


func _eval_formula(expr_str: String, ctx: Dictionary):
	# Use the engine's Formula module so the same syntax + bindings as rule
	# formulas work here (clamp, sin/cos, world.* refs, etc.).
	if expr_str == "": return null
	return Formula.evaluate(expr_str, ctx)


# ============================================================
# GLOBAL INPUTS
# ============================================================

## Per-frame check of global_inputs. If the action is press-edge AND the
## current_screen matches if_screen filter, fire the on_press effect chain.
func _handle_global_inputs() -> void:
	var globals = _cfg.get("global_inputs", null)
	if not (globals is Array): return
	var current := ""
	if not _stack.is_empty():
		current = str(_stack[_stack.size() - 1]["id"])
	for g in globals:
		if not (g is Dictionary): continue
		var action := str(g.get("action", ""))
		if action == "" or not InputMap.has_action(action): continue
		var screen_filter := str(g.get("if_screen", ""))
		# 2026-05-08: if_screen now matches symmetrically. `if_screen: ""`
		# fires only when stack empty (current=""); `if_screen: "X"` fires
		# only when current=X. Old behavior was "empty = always fire" which
		# made M re-push world_map while world_map was already up. Lets
		# data declare a paired close-rule (if_screen: "world_map" →
		# transition_screen @previous) for toggle behavior.
		if screen_filter != current: continue
		var pressed := Input.is_action_pressed(action)
		var was_pressed := bool(_last_action_state.get(action, false))
		_last_action_state[action] = pressed
		if pressed and not was_pressed:
			var effects = g.get("on_press", null)
			if effects is Array:
				_dispatch_effects(effects, {"_source": "global_input"})


# ============================================================
# UTIL — @-resolver shared with ControlFactory
# ============================================================

## Resolve @strings.x.y refs through ui/strings.json. Same logic as
## GameShell's resolver — kept here so ScreenFlow can run independently.
var _strings_cache: Dictionary = {}
var _strings_loaded: bool = false

func _resolve_at_ref(ref: String) -> String:
	if not ref.begins_with("@"): return ref
	var rest: String = ref.substr(1)
	var dot: int = rest.find(".")
	if dot < 0: return ""
	var ns: String = rest.substr(0, dot)
	var key: String = rest.substr(dot + 1)
	if ns == "strings":
		if not _strings_loaded: _load_strings()
		return _resolve_dotted(_strings_cache, key)
	# Other namespaces (cues, assets) — defer to GameShell or asset library
	return ""


func _load_strings() -> void:
	_strings_loaded = true
	if _world == null: return
	var dr = _world.get("data_root")
	var root := (str(dr) if dr != null else "").rstrip("/")
	if root == "": return
	var path := root + "/ui/strings.json"
	if not FileAccess.file_exists(path): return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return
	var data = JSON.parse_string(f.get_as_text())
	if data is Dictionary:
		_strings_cache = data


static func _resolve_dotted(cache: Dictionary, key: String) -> String:
	var parts: PackedStringArray = key.split(".")
	var cur = cache
	for part in parts:
		if not (cur is Dictionary): return ""
		if not (cur as Dictionary).has(part): return ""
		cur = (cur as Dictionary)[part]
	return str(cur) if cur != null else ""


func _set_world_state(key: String, value) -> void:
	if _world == null: return
	var ws = _world.get("world_state")
	if ws is Dictionary:
		(ws as Dictionary)[key] = value


# ============================================================
# SETTINGS RENDERER (ADR 0013)
# ============================================================

## Walk the just-built control tree for any settings_renderer placeholders
## and fill them with per-setting UI generated from the schema.
## Each generated control's value-changed signal calls SettingsManager.set
## (which persists + runs the apply block).
func _populate_settings_renderers(root: Control, dispatcher: Callable) -> void:
	if _world == null: return
	var settings_mgr = _world.get_node_or_null("SettingsManager")
	if settings_mgr == null: return
	# Find every node with the "settings_spec" meta (set by ControlFactory)
	var queue: Array = [root]
	while not queue.is_empty():
		var node: Node = queue.pop_back()
		if node.has_meta("settings_spec"):
			_populate_one_settings_renderer(node, settings_mgr, dispatcher)
		for child in node.get_children():
			queue.push_back(child)


## For one settings_renderer placeholder (a VBoxContainer): iterate the
## schema's categories + settings, generate a Control per setting,
## connect its change signal to SettingsManager.set_value.
func _populate_one_settings_renderer(host: Control, settings_mgr,
									 dispatcher: Callable) -> void:
	var categories: Array = settings_mgr.categories()
	for cat in categories:
		if not (cat is Dictionary): continue
		var cat_dict: Dictionary = cat
		# Category header
		var header := Label.new()
		header.text = ControlFactory._resolve_text(cat_dict.get("label", cat_dict.get("id", "")))
		header.add_theme_font_size_override("font_size", 24)
		header.add_theme_color_override("font_color", Color("#fdd068"))
		host.add_child(header)
		# Per-setting row
		for s in cat_dict.get("settings", []):
			if not (s is Dictionary): continue
			_build_setting_row(host, s as Dictionary, settings_mgr)


## One row = HBox with Label (setting name) + appropriate Control.
func _build_setting_row(host: Control, s: Dictionary, settings_mgr) -> void:
	var key := str(s.get("key", ""))
	if key == "": return
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	host.add_child(row)
	# Label
	var lbl := Label.new()
	lbl.text = ControlFactory._resolve_text(s.get("label", key))
	lbl.custom_minimum_size = Vector2(220, 0)
	row.add_child(lbl)
	# Control by type
	var current = settings_mgr.get_value(key)
	var ctrl: Control = null
	match str(s.get("type", "")):
		"slider":
			var sl := HSlider.new()
			sl.min_value = float(s.get("min", 0.0))
			sl.max_value = float(s.get("max", 1.0))
			sl.step = float(s.get("step", 0.05))
			sl.value = float(current)
			sl.custom_minimum_size = Vector2(220, 20)
			sl.value_changed.connect(func(v): settings_mgr.set_value(key, v))
			ctrl = sl
		"bool":
			var cb := CheckBox.new()
			cb.button_pressed = bool(current)
			cb.text = "  "  # padding so the box has visible footprint
			cb.custom_minimum_size = Vector2(220, 30)
			cb.toggled.connect(func(v): settings_mgr.set_value(key, v))
			ctrl = cb
		"enum":
			var ob := OptionButton.new()
			var options: Array = s.get("options", [])
			for opt in options:
				ob.add_item(ControlFactory._resolve_text(str(opt)))
			var idx := options.find(current)
			if idx >= 0: ob.select(idx)
			ob.item_selected.connect(func(i):
				var v = options[i] if i < options.size() else null
				settings_mgr.set_value(key, v))
			ctrl = ob
		"key_binding":
			# Phase A: read-only label showing current key. Click-to-rebind
			# is Phase B (needs press-to-bind state machine).
			var kb := Button.new()
			kb.text = str(current)
			kb.disabled = true
			ctrl = kb
		_:
			var l := Label.new()
			l.text = "(unknown setting type)"
			ctrl = l
	row.add_child(ctrl)
