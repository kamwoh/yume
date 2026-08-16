extends Object
class_name EffectShell

## Shell-tier effect handlers — engine ↔ game-shell boundary.
##
##   - transition_level / screen_fade / scene_change — level/scene swaps
##     (ADR 0006, 0011). Destructive: anything queued after a swap is
##     dropped at end-of-frame (effect-chain gate enforces ordering).
##   - transition_screen / quit_app / show_toast / reload_scene
##     (ADR 0011 screen flow primitives)
##   - save_state / load_state (ADR 0010 persistence)
##   - show_overlay_effect / dismiss_overlay_effect (ADR 0012 overlays)
##   - set_audio_bus_volume / set_input_mapping (ADR 0013 settings)
##
## All static. Push events onto env.screen_event_buffer / .overlay_event_buffer
## for GameShell to drain. Private helpers _push_screen_event +
## _push_overlay_event stay internal — only EffectShell handlers use them.


## ADR 0006: defer level transition. Sets env._pending_level_transition to
## target name; world.gd processes this between ticks (after the current
## rule's effect chain finishes) so we don't mutate entities mid-rule.
## target = "next" → engine looks up the next level in progression.levels.
##
## Optional `fade_duration` (seconds): when present and > 0, the transition
## is delegated to GameShell which runs a 3-phase state machine:
##   1. FADING_OUT (fade_duration/2 s): overlay alpha 0→1
##   2. SWAP at midpoint: GameShell sets env._pending_level_transition so
##      World picks it up on next tick (atomicity preserved)
##   3. FADING_IN (fade_duration/2 s): overlay alpha 1→0
## Without fade_duration the original instant-swap behavior is preserved.
##
## DESTRUCTIVE — like all transition_level paths, the level swap will
## remove non-persistent entities. Effect-chain validation gate applies:
## anything queued AFTER this effect that depends on the OLD level's
## entities will be silently dropped on swap.
static func transition_level(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var target := str(EffectResolution.value(e.get("target", "next"), ctx, env))
	if target == "":
		return
	var fade_dur := float(EffectResolution.value(e.get("fade_duration", 0.0), ctx, env))
	if fade_dur > 0.0:
		# Delegate to GameShell. It will set _pending_level_transition at
		# fade midpoint, so world.gd's existing process_pending_level_transition
		# does the actual swap on the next tick boundary.
		var color = e.get("color", "#000000")
		var buf_v = env.get("shell_event_buffer", null)
		var buf: Array
		if buf_v is Array:
			buf = buf_v
		else:
			buf = []
			env["shell_event_buffer"] = buf
		(
			buf
			. append(
				{
					"event": "transition_level_fade_request",
					"target": target,
					"fade_duration": fade_dur,
					"color": color,
				}
			)
		)
		return
	env["_pending_level_transition"] = target


# ============================================================
# LEVEL SUBROUTINES (ADR 0077)
# ============================================================

## World-state keys. Underscore-prefixed: engine bookkeeping, not content
## vocabulary. They live in world state so they persist with the save — a
## player who saves inside a sub-level still returns to the right caller.
const CALL_STACK_KEY: String = "_level_call_stack"
const CALL_ARGS_KEY: String = "_call_args"


## DESTRUCTIVE — must be LAST in its effect chain (same rule as
## transition_level). Anything queued after is dropped at the swap.
##
## Push the current level + the caller's return_signal onto the call stack,
## then swap to `level`. `args` land in world state under `_call_args` for
## the sub-level's rules to read.
##
## Sub-levels are OFF-PROGRESSION: the target is not required to be in
## level_order, so `transition_level "next"` can never walk into one.
static func level_call(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var target := str(EffectResolution.value(e.get("level", ""), ctx, env))
	if target == "":
		return
	var ws = env.get("world", null)
	if not (ws is Dictionary):
		return
	var world: Dictionary = ws
	var stack_v = world.get(CALL_STACK_KEY, [])
	var stack: Array = stack_v if stack_v is Array else []
	(
		stack
		. append(
			{
				"level": str(world.get("current_level", "")),
				"return_signal": str(e.get("return_signal", "")),
			}
		)
	)
	world[CALL_STACK_KEY] = stack
	var args = e.get("args", {})
	world[CALL_ARGS_KEY] = (args as Dictionary).duplicate(true) if args is Dictionary else {}
	env["_pending_level_call"] = target


## DESTRUCTIVE — must be LAST in its effect chain.
##
## Pop the call stack, swap back to the caller's level, and emit the caller's
## return_signal with `result` as the payload AFTER the swap (the caller's
## rules are not registered until its level loads, so emitting before would
## fall on an empty bucket — LevelTransitionCoordinator does the emit).
##
## Empty stack is a logged no-op, not a crash: a sub-level reached directly
## (debug, a test, a save made inside one) can still run this harmlessly.
static func level_return(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ws = env.get("world", null)
	if not (ws is Dictionary):
		return
	var world: Dictionary = ws
	var stack_v = world.get(CALL_STACK_KEY, [])
	var stack: Array = stack_v if stack_v is Array else []
	if stack.is_empty():
		(
			EngineError
			. raise(
				env,
				EngineError.LEVEL_RETURN_EMPTY_STACK,
				"level_return with an empty call stack — no caller to return to",
				{"rule_id": str(ctx.get("_rule_id", ""))},
				(
					"This level was entered directly rather than via level_call."
					+ " Use transition_level to leave it, or enter it with level_call."
				),
				"warning"
			)
		)
		return
	var frame = stack.pop_back()
	world[CALL_STACK_KEY] = stack
	var result = e.get("result", {})
	var payload: Dictionary = (
		(result as Dictionary).duplicate(true) if result is Dictionary else {}
	)
	env["_pending_level_return"] = {
		"level": str((frame as Dictionary).get("level", "")),
		"return_signal": str((frame as Dictionary).get("return_signal", "")),
		"result": payload,
	}


## ADR 0078 — step the CALENDAR clock N units, synchronously, inside this
## effect chain. Does NOT touch the 60Hz heartbeat: the `tick` bucket does
## not run, `tick_seconds` is not a balance knob, and `interval` still means
## ticks. `units` is counted in calendar units — the engine has no idea what
## a "day" is; that mapping is content's, exactly like `hp` or `gold`.
##
## NOT destructive: it mutates state but replaces neither the entity set nor
## the scene, so effects may follow it in a chain.
static func advance_time(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var units := int(EffectResolution.value(e.get("units", 1), ctx, env))
	if units <= 0:
		return
	var cb = env.get("advance_calendar", null)
	if cb is Callable:
		(cb as Callable).call(units)


## Tween the screen-fade overlay's alpha to a target value over `duration`
## seconds. GameShell owns the overlay (lives on a CanvasLayer above the
## HUD) and the per-frame lerp. duration=0 → instant.
##   {type: screen_fade, alpha: 0.8, duration: 0.3, color: "#000000"}
##
## Additive (non-destructive) — stacks fine with effects after it in a chain.
static func screen_fade(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var alpha := float(EffectResolution.value(e.get("alpha", 1.0), ctx, env))
	var duration := float(EffectResolution.value(e.get("duration", 0.0), ctx, env))
	var color = e.get("color", "#000000")
	var buf_v = env.get("shell_event_buffer", null)
	var buf: Array
	if buf_v is Array:
		buf = buf_v
	else:
		buf = []
		env["shell_event_buffer"] = buf
	(
		buf
		. append(
			{
				"event": "screen_fade",
				"alpha": alpha,
				"duration": duration,
				"color": color,
			}
		)
	)


## Hard Godot scene swap via SceneTree.change_scene_to_file. DESTRUCTIVE —
## anything queued after this in the same effect chain is silently dropped
## when the scene reload lands at end-of-frame. See `.claude/rules/
## engine-scripts.md` § effect-chain validation gate. Pushes a screen
## event so ScreenFlow drains and performs the swap (same pattern as
## reload_scene/quit_app).
##   {type: scene_change, target: "res://scenes/title.tscn"}
##
## Target is read raw (no _value formula evaluation) — `res://...` paths
## contain `/`, `:`, and `.` which Formula.looks_like_formula treats as
## expression syntax. Resource paths are always literal.
static func scene_change(e: Dictionary, env: Dictionary, _ctx: Dictionary) -> void:
	var target := str(e.get("target", ""))
	if target == "":
		push_warning("scene_change effect missing target (rule=%s)" % str(_ctx.get("_rule_id", "")))
		return
	_push_screen_event(env, {"event": "scene_change", "target": target})


# ============================================================
# SCREEN FLOW EFFECTS (ADR 0011)
# ============================================================
#
# Same pattern as emit_shell_event: push a record onto env.screen_event_buffer.
# ScreenFlow drains it each frame (see screen_flow.gd _drain_screen_events).
# Effects don't touch CanvasLayers directly — that's screen_flow's job.


static func _push_screen_event(env: Dictionary, record: Dictionary) -> void:
	var buf_v = env.get("screen_event_buffer", null)
	var buf: Array
	if buf_v is Array:
		buf = buf_v
	else:
		buf = []
		env["screen_event_buffer"] = buf
	buf.append(record)


## Transition to a named screen. ScreenFlow handles modal-vs-replace based
## on the target screen's spec. Special target "@previous" pops the modal
## stack (returns from settings → pause).
static func transition_screen(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var target := str(EffectResolution.value(e.get("target", ""), ctx, env))
	if target == "":
		push_warning(
			"transition_screen effect missing target (rule=%s)" % str(ctx.get("_rule_id", ""))
		)
		return
	_push_screen_event(env, {"event": "transition_screen", "target": target})


## Quit the application. ScreenFlow calls get_tree().quit() when drained.
static func quit_app(_e: Dictionary, env: Dictionary, _ctx: Dictionary) -> void:
	_push_screen_event(env, {"event": "quit_app"})


## Show a transient toast label (e.g. "Saved!" after save_state).
## text resolves @strings.X refs. duration in seconds.
##
## NOTE: text uses EffectResolution.value_text() (literal-or-@-only), NOT EffectResolution.value(). Display
## prose like "Debt installment paid" contains spaces, which would trip
## Formula.looks_like_formula and cause a runtime parse error. show_toast's
## text field is meant for human-readable strings, not computation. If you
## need a computed message, build it in a state_set rule first then reference
## the state via @strings.<key> resolved at HUD time.
static func show_toast(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var text := EffectResolution.value_text(e.get("text", ""), ctx)
	var duration := float(EffectResolution.value(e.get("duration", 2.0), ctx, env))
	_push_screen_event(env, {"event": "show_toast", "text": text, "duration": duration})


## Reload the entire current Godot scene. DESTRUCTIVE — anything queued
## after this in the same effect chain is silently dropped when the scene
## reload lands at end-of-frame. See `.claude/rules/engine-scripts.md`
## § effect-chain validation gate.
##
## For "reset world without scene reload" use the future `reset_world`
## effect (task #99). For most "New Game" buttons, just `transition_screen`
## is sufficient because the world is already at initial state on scene
## load.
static func reload_scene(e: Dictionary, env: Dictionary, _ctx: Dictionary) -> void:
	var args = e.get("args", {})
	_push_screen_event(env, {"event": "reload_scene", "args": args})


# ============================================================
# SAVE / LOAD EFFECTS (ADR 0010)
# ============================================================
#
# Both effects are DEFERRED — they set env._pending_save / env._pending_load
# (slot number). World.gd processes the pending request between ticks
# (after the current effect chain drains), same pattern as transition_level.
# This keeps save/load atomic relative to the simulation: a save captures
# a stable post-tick state, never mid-rule.


static func save_state(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var slot := int(EffectResolution.value(e.get("slot", 0), ctx, env))
	env["_pending_save"] = slot


static func load_state(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var slot := int(EffectResolution.value(e.get("slot", 0), ctx, env))
	env["_pending_load"] = slot


# ============================================================
# OVERLAY EFFECTS (ADR 0012)
# ============================================================
#
# Same pattern as screen events: push records into env.overlay_event_buffer.
# OverlayManager (a Node sibling of GameShell) drains each frame.


static func _push_overlay_event(env: Dictionary, record: Dictionary) -> void:
	var buf_v = env.get("overlay_event_buffer", null)
	var buf: Array
	if buf_v is Array:
		buf = buf_v
	else:
		buf = []
		env["overlay_event_buffer"] = buf
	buf.append(record)


## Show an overlay (modal text + advance condition). All fields except
## "type" are forwarded verbatim into the buffer record so OverlayManager
## sees the full spec (id, title, body, advance_action, advance_signal,
## advance_after_seconds, freeze_world, skippable, highlight_tag, etc.).
##
## Strings pass through raw (so "Press WASD to move." isn't mis-parsed as
## a formula by Formula.looks_like_formula's space/dot heuristic). @-refs
## resolve at show time via ControlFactory._resolve_text. Non-strings
## (numbers, bools) go through _value so dynamic specs from state work
## (e.g. `advance_after_seconds: world.tutorial_step + 2`).
static func show_overlay_effect(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var record: Dictionary = {"event": "show_overlay"}
	for k in e.keys():
		if str(k) == "type":
			continue
		var v = e[k]
		if v is String:
			record[str(k)] = v
		else:
			record[str(k)] = EffectResolution.value(v, ctx, env)
	_push_overlay_event(env, record)


## Dismiss an overlay by id. Pops from the stack and fires
## overlay_advanced{id, reason: "manual"}. If the id isn't on the
## stack, no-op (idempotent).
static func dismiss_overlay_effect(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var id := str(EffectResolution.value(e.get("id", ""), ctx, env))
	_push_overlay_event(env, {"event": "dismiss_overlay", "id": id})


# ============================================================
# SETTINGS EFFECTS (ADR 0013)
# ============================================================
#
# Thin wrappers around Godot's AudioServer + InputMap. Per ADR 0021,
# we expose the existing Godot machinery rather than reimplementing it.
# These effects fire from settings_schema.json's `apply` blocks when a
# player changes a setting.


## Set the volume of a Godot AudioServer bus (by name) to a linear
## level in [0.0, 1.0]. Linear converts to dB internally
## (Godot's AudioServer takes dB, but linear is the player-facing value).
static func set_audio_bus_volume(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var bus_name := str(EffectResolution.value(e.get("bus", "Master"), ctx, env))
	var linear := float(EffectResolution.value(e.get("linear", 1.0), ctx, env))
	linear = clamp(linear, 0.0, 1.0)
	var bus_idx := AudioServer.get_bus_index(bus_name)
	if bus_idx < 0:
		# Bus may not exist if AudioBus autoload didn't add it (e.g. in
		# headless tests). Silent skip to keep this effect cheap-fail.
		return
	# Godot's volume is in dB; linear_to_db handles 0.0 → -inf cleanly.
	AudioServer.set_bus_volume_db(bus_idx, linear_to_db(linear))


## Remap a Godot InputMap action to a new physical key.
## Erases existing bindings for the action, then adds the new key.
## key string is parsed via OS.find_keycode_from_string.
static func set_input_mapping(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var action := str(EffectResolution.value(e.get("action", ""), ctx, env))
	var key_str := str(EffectResolution.value(e.get("key", ""), ctx, env))
	if action == "" or key_str == "":
		return
	if not InputMap.has_action(action):
		# Action doesn't exist in this game's InputMap. Silent skip.
		return
	var keycode := OS.find_keycode_from_string(key_str)
	if keycode == KEY_NONE:
		push_warning("set_input_mapping: unknown key '%s' for action '%s'" % [key_str, action])
		return
	# Erase any existing key events on this action, keep non-key events
	# (gamepad, mouse) untouched.
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			InputMap.action_erase_event(action, ev)
	var new_ev := InputEventKey.new()
	new_ev.keycode = keycode
	InputMap.action_add_event(action, new_ev)
