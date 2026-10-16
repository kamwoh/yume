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

var _cfg: Dictionary = {}  # parsed screens.json
var _screens_by_id: Dictionary = {}  # id → screen-spec dict
var _world: Node = null  # parent (World instance)
var _starting_screen: String = ""

# Modal stack — array of {id, layer (CanvasLayer), bound (Array)}.
# Top of stack = active screen. Underneath modals stay rendered + frozen.
var _stack: Array = []

# Toast layer — shared CanvasLayer above all screens for transient labels.
var _toast_layer: CanvasLayer = null
## Fade tween of the toast currently on screen. Held so a replacing toast can
## kill it before freeing the label it captured (see _show_toast).
## Screen-stack depths remembered by `screen_mark` (ADR 0077 sub-level UI).
var _screen_marks: Array = []
var _toast_tween: Tween = null

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
	# Screen-INDEPENDENT shell services (toasts, quit_app, reload_scene
	# event drain) exist regardless of screens.json — build them BEFORE
	# the no-screens early return. Empirical 2026-06-11 (autorace, no
	# screens.json): show_toast was a silent no-op in every screens-less
	# demo — the early return skipped both the toast layer and the drain.
	var sched0 = _world.get("scheduler")
	if sched0 != null and sched0.get("env") != null:
		var env0: Dictionary = sched0.env
		if not env0.has("screen_event_buffer"):
			env0["screen_event_buffer"] = []
	_toast_layer = CanvasLayer.new()
	_toast_layer.layer = 50
	add_child(_toast_layer)
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
	# Stash the World ref for any modal element that needs to bind to live
	# world state (e.g. minimap inside the map screen — #104, 2026-05-16).
	# ControlFactory looks this up to wire MinimapWidget.bind_world; per-
	# frame tick happens via _update_bound_elements.
	Engine.set_meta("yume_world", _world)
	# (screen_event_buffer + toast layer built above, before the
	# no-screens early return — they are screen-independent.)
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
	# Drain BEFORE the no-screens guard: toasts / quit_app / reload_scene
	# are screen-independent (see _ready note, empirical 2026-06-11).
	_drain_screen_events()
	if _cfg.is_empty():
		return
	_update_bound_elements()
	_handle_global_inputs()


# ============================================================
# CONFIG LOADING
# ============================================================


func _load_config() -> void:
	var root := str(_world.get("data_root"))
	if root == "":
		return
	root = root.rstrip("/")
	var path := root + "/screens.json"
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		return
	# ADR 0027 (2026-05-20 consistency fix): route screens.json through lib
	# resolver so `@lib.palettes.X` and `$extends: @lib.X.Y` refs expand
	# before consumption. game_shell.gd already does this for hud.json /
	# scene.json; screens.json was the only loader missing it. Empirical
	# case: HUD-minimap and M-key map drifted on tag_colors (28 vs 9
	# entries) — shared palette fixes the drift but only works if both
	# loaders resolve lib refs.
	var resolved = LibResolver.resolve(data)
	if resolved is Dictionary:
		data = resolved
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
		# Replace: tear down full stack first. Detach before freeing, for the same
		# reason as _pop_screen — a deferred free leaves the layer in the tree and
		# its controls findable but dead.
		for entry in _stack:
			var dead := entry["layer"] as Node
			if dead != null:
				if dead.get_parent() != null:
					dead.get_parent().remove_child(dead)
				dead.queue_free()
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
	# Give the first interactive control focus so the screen is reachable by
	# KEYBOARD and gamepad, not only by mouse. Godot activates a focused
	# Button on ui_accept for free; without an initial focus holder there is
	# nothing to activate, so a title screen with two buttons is a dead end
	# for anyone not using a mouse.
	#
	# Empirical 2026-08-16: found while scripting a capture through a title
	# screen — ui_accept did nothing, in EVERY demo, because ControlFactory
	# never calls grab_focus and nothing else did either.
	_focus_first_interactive(root)
	# Push entry
	_stack.append({"id": screen_id, "spec": spec, "layer": layer, "bound": bound})
	# Update world_state
	_apply_active_screen()
	# Synchronize edge-tracking with current Godot Input state. Without
	# this, a global_input with `if_screen` matching the just-pushed
	# screen would see `pressed=true, was_pressed=false (default)` on
	# the same frame the screen pushed → fire on_press immediately and
	# pop the screen (1-frame flash). Empirical case 2026-05-16.
	_sync_global_input_edge_state()


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
	if _stack.is_empty():
		return
	var top: Dictionary = _stack[_stack.size() - 1]
	# remove_child BEFORE queue_free. queue_free is DEFERRED, so a layer freed but
	# left parented stays IN THE TREE until the frame ends — and a headless
	# scenario run has no frame between steps. Anything that looks a control up by
	# walking the tree then finds a control belonging to a dead layer, whose
	# lambda captures are already gone: pressing it produces
	# "Lambda capture at index 0 was freed" and no dispatch at all, so the click
	# silently does nothing.
	#
	# This is the same defect fixed in _refresh_top_screen on 2026-08-17. That fix
	# was applied only at the site where it surfaced, so the identical hazard sat
	# here untouched — `.claude/rules/post-mortem.md` step 3a is exactly about not
	# doing that. Every teardown path in this file now detaches first.
	var old_layer := top["layer"] as Node
	if old_layer != null:
		if old_layer.get_parent() != null:
			old_layer.get_parent().remove_child(old_layer)
		old_layer.queue_free()
	_stack.pop_back()
	_apply_active_screen()
	_sync_global_input_edge_state()


## Capture current Godot Input state into _last_action_state for every
## global_inputs action. Call after any stack mutation so the on_press
## edge detector doesn't fire spuriously on the SAME frame the filter
## starts matching. Symmetric: push (above) inlines the same loop.
## Depth-first search for the first control that can take focus, and give it
## focus. Returns true once something was focused.
##
## Deliberately generic: any Control with focus_mode != FOCUS_NONE qualifies,
## so buttons, sliders, checkboxes and option-buttons all work without this
## function knowing the element vocabulary.
func _focus_first_interactive(node: Node) -> bool:
	for child in node.get_children():
		if child is Control and (child as Control).focus_mode != Control.FOCUS_NONE:
			(child as Control).grab_focus()
			return true
		if _focus_first_interactive(child):
			return true
	return false


func _sync_global_input_edge_state() -> void:
	for g in _cfg.get("global_inputs", []):
		if not (g is Dictionary):
			continue
		var act := str((g as Dictionary).get("action", ""))
		if act != "" and InputMap.has_action(act):
			_last_action_state[act] = Input.is_action_pressed(act)


## Update world_state["current_screen"] + freeze flag from top of stack.
func _apply_active_screen() -> void:
	if _stack.is_empty():
		_set_world_state("current_screen", "")
		_set_world_state("screen_freeze_world", 0)
		return
	var top: Dictionary = _stack[_stack.size() - 1]
	var spec: Dictionary = top["spec"]
	_set_world_state("current_screen", str(top["id"]))
	_set_world_state("screen_freeze_world", 1 if bool(spec.get("freeze_world", false)) else 0)


# ============================================================
# EFFECT DISPATCH
# ============================================================


## Invoked by Button.pressed (and other interaction signals). Iterates
## the effect list and applies each via existing effect_apply pipeline.
## Effects flush at end of frame like any other effect.
func _dispatch_effects(effects, _ctx: Dictionary) -> void:
	if not (effects is Array):
		return
	if _world == null:
		return
	var sched = _world.get("scheduler")
	if sched == null:
		return
	var env: Dictionary = sched.env
	for eff in effects:
		if not (eff is Dictionary):
			continue
		var ctx: Dictionary = {"_rule_id": "screen_flow", "_source": "ui"}
		EffectApply.apply(eff as Dictionary, env, ctx)


# ============================================================
# SCREEN EVENT BUFFER (drained from env.screen_event_buffer each frame)
# ============================================================


## ADR 0039: public alias for _drain_screen_events. Step runner calls
## this after a `click` verb fires `Button.pressed.emit()` so any
## transition_screen / transition_level / load_state effects queued
## by the on_click chain land BEFORE the next step. Without this drain,
## the per-frame `_process` callback wouldn't run between scripted
## steps in headless tests (no Godot main loop frame ticks).
func drain() -> void:
	_drain_screen_events()


## Rebuild the top screen in place, preserving the modal stack beneath it.
##
## ADR 0076 gave query-bound `list` elements two rebuild triggers: screen open,
## and World.world_loaded. This is the third, and it is the one a menu-driven
## game needs constantly — "an action I took on this screen changed what this
## screen shows". A conversation box that displays a relationship value and the
## other party's reply is stale the instant you act, because its rows were built
## once on open.
##
## Cheaper alternatives were rejected: popping and re-pushing flickers and loses
## the stack position, and re-querying every list per frame is the performance
## trap ADR 0076 explicitly avoided.
func _refresh_top_screen() -> void:
	if _stack.is_empty():
		return
	var top: Dictionary = _stack[-1]
	var screen_id := str(top.get("id", ""))
	if screen_id == "" or not _screens_by_id.has(screen_id):
		return
	# Drop just this entry, then re-push non-modally onto the remaining stack so
	# the layer below is untouched.
	# remove_child BEFORE queue_free: queue_free is DEFERRED, so the outgoing
	# layer would still be in the tree when the replacement is added — two live
	# copies of the same screen for a frame. That duplicates every Control in it,
	# which makes a by-id lookup ambiguous and can double-fire input.
	#
	# Empirical 2026-08-17: after a refresh, a scenario's click on a button in
	# the rebuilt screen aborted with "matched 2 controls".
	var old_layer := top["layer"] as Node
	remove_child(old_layer)
	old_layer.queue_free()
	_stack.pop_back()
	_push_screen(screen_id, true)


## Drain pending screen events emitted by transition_screen / quit_app /
## show_toast / reload_scene effects. Same pattern as GameShell's
## shell_event_buffer.
func _drain_screen_events() -> void:
	if _world == null:
		return
	var sched = _world.get("scheduler")
	if sched == null:
		return
	var env: Dictionary = sched.env
	var buf = env.get("screen_event_buffer", null)
	if not (buf is Array) or (buf as Array).is_empty():
		return
	env["screen_event_buffer"] = []
	for ev in buf:
		if not (ev is Dictionary):
			continue
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
			"refresh_screen":
				_refresh_top_screen()
			"screen_mark":
				# Entering a sub-level: remember how deep the stack is, so whatever
				# the sub-level pushes can be dismissed wholesale on the way out.
				_screen_marks.append(_stack.size())
			"screen_restore":
				# Leaving a sub-level: pop back to the remembered depth. Popping the
				# ENTIRE stack instead would close the caller's own base screen —
				# in a menu-driven game the town view IS a screen, so @root would
				# leave the player looking at nothing.
				var want: int = int(_screen_marks.pop_back()) if not _screen_marks.is_empty() else 0
				var guard := 0
				while _stack.size() > want and guard < 32:
					_pop_screen()
					guard += 1
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
					push_warning("ScreenFlow: scene_change failed (path=%s err=%d)" % [path, err])


# ============================================================
# TOAST
# ============================================================


## Transient label shown for `duration` seconds, fades out, removes itself.
## Anchored to bottom-center.
func _show_toast(text: String, duration: float) -> void:
	if _toast_layer == null:
		return
	var resolved := text
	if resolved.begins_with("@"):
		resolved = _resolve_at_ref(resolved)
		if resolved == "":
			resolved = text
	# Every toast renders at the SAME anchor, so a second one arriving while the
	# first is still fading draws two strings through each other — illegible.
	# `.claude/rules/data-demo.md` used to tell authors to design around this
	# ("stagger rule intervals, or merge into one message"), which is not a
	# thing content can reliably do: any two rules reacting to one player action
	# can collide, and a player can click twice inside the fade.
	#
	# A single-anchor toast system has to be last-writer-wins. Clearing the
	# previous toast makes non-overlap a guarantee instead of a caution.
	#
	# Empirical 2026-08-17: two drink-feedback toasts rendered as
	# "又近了一点— 不过今天大概就到这儿了。" — two messages in one line.
	# Kill the outgoing toast's fade tween BEFORE freeing its label. The tween's
	# completion callback captures that label and calls queue_free on it; freeing
	# the label without killing the tween leaves the callback holding a dangling
	# capture, which Godot reports as
	#   "Lambda capture at index 0 was freed. Passed null instead."
	# followed by "Cannot call method 'queue_free' on a null value".
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = null
	for old in _toast_layer.get_children():
		_toast_layer.remove_child(old)
		old.queue_free()
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
	_toast_tween = tween
	tween.tween_interval(max(duration - 0.5, 0.1))
	tween.tween_property(lbl, "modulate:a", 0.0, 0.5)
	# Validity guard, independent of the kill above. The label can also go away
	# with the whole layer — screen teardown, reload_scene, world reset — while
	# this tween is still mid-fade. That crash predates last-writer-wins; it was
	# simply hard to hit before, because nothing else freed a live toast.
	tween.tween_callback(
		func():
			if is_instance_valid(lbl):
				lbl.queue_free()
	)


# ============================================================
# BOUND ELEMENT UPDATES (visible_if / enabled_if)
# ============================================================


func _update_bound_elements() -> void:
	if _stack.is_empty():
		return
	var top: Dictionary = _stack[_stack.size() - 1]
	var bound: Array = top.get("bound", [])
	if bound.is_empty():
		return
	var ctx: Dictionary = _formula_ctx()
	# Defer to GameShell's resolver for `binds` — same syntax as HUD
	# (world.X, world_clock.X, player.X). Required for screens like
	# `inventory` that display live entity state. Empirical case
	# 2026-05-16: inventory screen labels with `binds:` rendered empty.
	var shell = _world.get_node_or_null("GameShell") if _world != null else null
	for entry in bound:
		var node: Control = entry["node"]
		var cfg: Dictionary = entry["cfg"]
		if cfg.has("visible_if"):
			var v = _eval_formula(str(cfg["visible_if"]), ctx)
			node.visible = bool(v) if v != null else true
		if cfg.has("enabled_if") and node is Button:
			var v2 = _eval_formula(str(cfg["enabled_if"]), ctx)
			(node as Button).disabled = not (bool(v2) if v2 != null else true)
		# slot_grid: dispatch its per-cell update + active highlight via the
		# shared static helper. Detect by meta set in _build_slot_grid.
		if node.has_meta("slot_grid_cfg") and shell != null:
			ControlFactory.update_slot_grid(
				node, Callable(shell, "_resolve_binding")
			)
			continue
		# Minimap inside a modal (#104, 2026-05-16). Mirror HudBuilder's
		# tick — the widget self-redraws each frame from live world state.
		if node is MinimapWidget:
			(node as MinimapWidget).tick()
			continue
		# Label binding (mirrors HudBuilder._apply_binding_to_node)
		if cfg.has("binds") and node is Label and shell != null:
			var binding := str(cfg["binds"])
			if binding != "":
				var value = shell.call("_resolve_binding", binding)
				if value != null:
					# ADR 0009 Phase 2c keeps @-refs unevaluated so the CONSUMER
					# resolves them. A label is the consumer: world state holding
					# "@strings.x.y" (e.g. an objective written by a rule, which
					# must be localisable like any other text) would otherwise
					# render the raw key on screen.
					if value is String and str(value).begins_with("@"):
						var rv := str(shell.call("_resolve_at_ref", str(value)))
						if rv != "":
							value = rv
					var fmt := str(cfg.get("format", "{}"))
					# ADR 0009 Phase 2c — a `format` is user-facing text and so
					# must resolve @strings.* like `text` does. HudBuilder has
					# always resolved it; ScreenFlow never did, so a localised
					# screen label rendered the literal "@strings.town.fmt.day".
					# Same asymmetry class as the number formatting below.
					if fmt.begins_with("@"):
						var resolved := str(shell.call("_resolve_at_ref", fmt))
						if resolved != "":
							fmt = resolved
					# Shared with HudBuilder — JSON numbers are all floats, so
					# without this every screen label renders "120.0".
					(node as Label).text = fmt.replace(
						"{}", ControlFactory.format_bound_value(value)
					)


func _formula_ctx() -> Dictionary:
	# Minimal context for visible_if/enabled_if: world.* keys readable.
	# Future extension: per-screen state, per-element params.
	var ws: Dictionary = (_world.get("world_state") as Dictionary) if _world != null else {}
	return {"world": ws}


func _eval_formula(expr_str: String, ctx: Dictionary):
	# Use the engine's Formula module so the same syntax + bindings as rule
	# formulas work here (clamp, sin/cos, world.* refs, etc.).
	if expr_str == "":
		return null
	return Formula.evaluate(expr_str, ctx)


# ============================================================
# GLOBAL INPUTS
# ============================================================


## Per-frame check of global_inputs. If the action is press-edge AND the
## current_screen matches if_screen filter, fire the on_press effect chain.
func _handle_global_inputs() -> void:
	var globals = _cfg.get("global_inputs", null)
	if not (globals is Array):
		return
	var current := ""
	if not _stack.is_empty():
		current = str(_stack[_stack.size() - 1]["id"])
	# Press-edge is computed ONCE PER ACTION per frame, BEFORE firing any
	# entry. Multiple global_inputs may share one action — the paired-
	# if_screen toggle pattern (open when if_screen="", close when
	# if_screen="X"). Previously _last_action_state[action] was updated
	# per-entry, so the FIRST entry for an action clobbered the second
	# entry's `was_pressed` → the close half never saw the edge.
	# Empirical 2026-06-06: the shell H-help opened but would not close
	# (first same-action toggle pair shipped; bug was latent until then).
	var is_edge := _compute_action_edges(globals)
	for g in globals:
		if not (g is Dictionary):
			continue
		var action := str(g.get("action", ""))
		if action == "" or not InputMap.has_action(action):
			continue
		# 2026-05-08: if_screen matches symmetrically. `if_screen: ""` fires
		# only when stack empty (current=""); `if_screen: "X"` fires only
		# when current=X. Lets data declare paired close-rules
		# (if_screen: "X" → transition_screen @previous) for toggle behavior.
		if str(g.get("if_screen", "")) != current:
			continue
		if bool(is_edge.get(action, false)):
			var effects = g.get("on_press", null)
			if effects is Array:
				_dispatch_effects(effects, {"_source": "global_input"})


## True when a screens.json global input uses an action that the key
## triggers. GameShell asks this before it handles ESC itself.
func binds_key(keycode: int) -> bool:
	var globals = _cfg.get("global_inputs", null)
	if not (globals is Array):
		return false
	for g in globals:
		var action := str((g as Dictionary).get("action", "")) if g is Dictionary else ""
		if action == "" or not InputMap.has_action(action):
			continue
		for ev in InputMap.action_get_events(action):
			if ev is InputEventKey and keycode in [ev.keycode, ev.physical_keycode, ev.key_label]:
				return true
	return false


## Compute press-edge (pressed-this-frame AND not-last-frame) per ACTION
## across the global_inputs list, updating _last_action_state ONCE per
## action. Returns {action: bool is_edge}. Extracted + pure-ish (reads
## Input via the injectable _pressed_lookup seam) so the same-action
## toggle invariant is unit-testable without a live Input device.
func _compute_action_edges(globals: Array) -> Dictionary:
	var is_edge: Dictionary = {}
	for g in globals:
		if not (g is Dictionary):
			continue
		var action := str(g.get("action", ""))
		if action == "" or is_edge.has(action) or not InputMap.has_action(action):
			continue
		var pressed := _action_pressed(action)
		var was_pressed := bool(_last_action_state.get(action, false))
		is_edge[action] = pressed and not was_pressed
		_last_action_state[action] = pressed
	return is_edge


## Input seam — overridable in tests (set _pressed_lookup to a Dictionary
## {action: bool}); falls back to the live Input device.
var _pressed_lookup = null
func _action_pressed(action: String) -> bool:
	if _pressed_lookup is Dictionary:
		return bool((_pressed_lookup as Dictionary).get(action, false))
	return Input.is_action_pressed(action)


# ============================================================
# UTIL — @-resolver shared with ControlFactory
# ============================================================

## Resolve @strings.x.y refs through ui/strings.json. Same logic as
## GameShell's resolver — kept here so ScreenFlow can run independently.
var _strings_cache: Dictionary = {}
var _strings_loaded: bool = false


func _resolve_at_ref(ref: String) -> String:
	if not ref.begins_with("@"):
		return ref
	var rest: String = ref.substr(1)
	var dot: int = rest.find(".")
	if dot < 0:
		return ""
	var ns: String = rest.substr(0, dot)
	var key: String = rest.substr(dot + 1)
	if ns == "strings":
		# Delegate to GameShell — it owns the ONE strings loader, including
		# locale merging (ui/strings.<lang>.json over ui/strings.json). ScreenFlow
		# used to carry its own duplicate loader + cache reading only the base
		# file, so `text` (resolved through this path) stayed in the base
		# language while `format` (resolved through GameShell) localised
		# correctly. Two implementations of one thing; the drift WAS the bug.
		#
		# Empirical 2026-08-17: a Chinese game rendered every bound number label
		# in Chinese and every static text label in English.
		var shell = _world.get_node_or_null("GameShell") if _world != null else null
		if shell != null and shell.has_method("_resolve_at_ref"):
			return str(shell.call("_resolve_at_ref", ref))
		# No GameShell mounted (sim-only scene): fall back to the local reader,
		# which is base-language only but better than an empty string.
		if not _strings_loaded:
			_load_strings()
		return _resolve_dotted(_strings_cache, key)
	# Other namespaces (cues, assets) — defer to GameShell or asset library
	return ""


func _load_strings() -> void:
	_strings_loaded = true
	if _world == null:
		return
	var dr = _world.get("data_root")
	var root := (str(dr) if dr != null else "").rstrip("/")
	if root == "":
		return
	var path := root + "/ui/strings.json"
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	if data is Dictionary:
		_strings_cache = data


static func _resolve_dotted(cache: Dictionary, key: String) -> String:
	var parts: PackedStringArray = key.split(".")
	var cur = cache
	for part in parts:
		if not (cur is Dictionary):
			return ""
		if not (cur as Dictionary).has(part):
			return ""
		cur = (cur as Dictionary)[part]
	return str(cur) if cur != null else ""


func _set_world_state(key: String, value) -> void:
	if _world == null:
		return
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
	if _world == null:
		return
	var settings_mgr = _world.get_node_or_null("SettingsManager")
	if settings_mgr == null:
		return
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
func _populate_one_settings_renderer(host: Control, settings_mgr, _dispatcher: Callable) -> void:
	var categories: Array = settings_mgr.categories()
	for cat in categories:
		if not (cat is Dictionary):
			continue
		var cat_dict: Dictionary = cat
		# Category header
		var header := Label.new()
		header.text = ControlFactory._resolve_text(cat_dict.get("label", cat_dict.get("id", "")))
		header.add_theme_font_size_override("font_size", 24)
		header.add_theme_color_override("font_color", Color("#fdd068"))
		host.add_child(header)
		# Per-setting row
		for s in cat_dict.get("settings", []):
			if not (s is Dictionary):
				continue
			_build_setting_row(host, s as Dictionary, settings_mgr)


## One row = HBox with Label (setting name) + appropriate Control.
func _build_setting_row(host: Control, s: Dictionary, settings_mgr) -> void:
	var key := str(s.get("key", ""))
	if key == "":
		return
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
			# A toggle Button that says "On" or "Off". The CheckBox it
			# replaces drew the theme's dark unchecked icon, which did not
			# show on a dark panel. Empirical 2026-10-16: sokoban's
			# "Reduced motion" row looked empty.
			var tb := Button.new()
			tb.toggle_mode = true
			tb.button_pressed = bool(current)
			tb.text = "On" if tb.button_pressed else "Off"
			tb.custom_minimum_size = Vector2(120, 30)
			tb.toggled.connect(
				func(v):
					tb.text = "On" if v else "Off"
					settings_mgr.set_value(key, v)
			)
			ctrl = tb
		"enum":
			var ob := OptionButton.new()
			var options: Array = s.get("options", [])
			for opt in options:
				ob.add_item(ControlFactory._resolve_text(str(opt)))
			var idx := options.find(current)
			if idx >= 0:
				ob.select(idx)
			ob.item_selected.connect(
				func(i):
					var v = options[i] if i < options.size() else null
					settings_mgr.set_value(key, v)
			)
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
