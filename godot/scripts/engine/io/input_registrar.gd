extends Object
class_name InputRegistrar

## Tier 2.6t — per-game dynamic input registration.
##
## Reads `data/<game>/inputs.json` and registers each declared action
## into Godot's InputMap at runtime. Lets games own their input
## vocabulary instead of bloating project.godot's static input map.
##
## Schema:
##   {
##     "actions": [
##       {"name": "spark", "key": "Space"},
##       {"name": "build_1", "key": "1", "edge": "press"},
##       {"name": "charge", "key": "C", "edge": "hold"},
##       {"name": "weapon_2", "keys": ["2", "Numpad2"]}
##     ]
##   }
##
## - `key` — single keycode string (lookup via OS.find_keycode_from_string)
## - `keys` — array of keycode strings (multiple bindings for one action)
## - `edge` — `"press"` (fire once on press-edge, default) or `"hold"`
##   (fire every frame while held). Engine adds the action to its
##   `input_actions_press` or `input_actions_hold` poll list automatically.
## - At least one of `key` / `keys` is required
##
## Idempotent: calling register on the same action twice doesn't duplicate
## events — the engine clears events for the action before re-binding.
##
## Used by:
##   - World.load_data() — auto-registers per-game inputs at world startup
##     and extends its poll lists with the returned action names
##   - scenario_runner — same hook (test scenarios get the same vocabulary)


## Read inputs config at the given data root and register all actions.
## Returns a Dictionary {"press": [String, ...], "hold": [String, ...]} so
## the caller can extend its poll lists. Silent no-op (returns empty
## dict) if the file doesn't exist.
##
## ADR 0009 (Phase 5b sunset): single canonical path ui/input.json.
## Legacy root-level inputs.json no longer consulted.
static func register_from_data_root(data_root: String) -> Dictionary:
	var out: Dictionary = {"press": [], "hold": []}
	var root := data_root.rstrip("/")
	var path := root + "/ui/input.json"
	if not FileAccess.file_exists(path):
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var raw := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(raw) != OK:
		push_warning("[InputRegistrar] parse error in %s: %s"
			% [path, json.get_error_message()])
		return out
	if not (json.data is Dictionary):
		return out
	# ADR 0043 — resolve @lib + $include refs in input.json so
	# `{"$include": "@lib.input.universal.actions"}` splices the universal
	# WASD action set. LibResolver runs identically on rule files (rule.gd::
	# from_dict); this call site brings input.json into the same pipeline.
	var spec_raw = LibResolver.resolve(json.data)
	if not (spec_raw is Dictionary):
		return out
	var spec: Dictionary = spec_raw
	for action_def in spec.get("actions", []):
		if not (action_def is Dictionary):
			continue
		var name := _register_one(action_def)
		if name == "": continue
		var edge := str((action_def as Dictionary).get("edge", "press"))
		if edge == "hold":
			(out["hold"] as Array).append(name)
		else:
			(out["press"] as Array).append(name)
	return out


## Register one action; returns the action name on success, "" on failure.
static func _register_one(action_def: Dictionary) -> String:
	var name := str(action_def.get("name", ""))
	if name == "":
		return ""

	# Collect keycode strings — accept either `key` (single) or `keys` (array).
	var keys: Array = []
	if action_def.has("key"):
		keys.append(str(action_def["key"]))
	if action_def.has("keys") and action_def["keys"] is Array:
		for k in action_def["keys"]:
			keys.append(str(k))
	# 2026-05-11 (ADR 0043): WASD bindings moved to
	# `data/lib/input/universal.json` and spliced into each game's
	# ui/input.json via `{"$include": "@lib.input.universal.actions"}`.
	# project.godot [input] block deleted. The keys-optional path now
	# serves ONE remaining case: `engine_injected: true` actions queued
	# by engine code (e.g. stop_x / stop_y queued by world.gd::_poll_input
	# on per-axis idle, the lib_wasd_with_fp_variant bundle's stop
	# actions). No key binding is intentional — engine queues directly.
	# We still REGISTER the action (without events) so scenario_runner's
	# Input.action_press can fire it programmatically. Silent — no typo
	# warning.
	if keys.is_empty():
		if InputMap.has_action(name):
			return name
		if bool(action_def.get("engine_injected", false)):
			InputMap.add_action(name)
			return name
		push_warning("[InputRegistrar] action '%s' has no key bindings AND is not already in InputMap — skipping (add `engine_injected: true` if intentional)" % name)
		return ""

	# Idempotent: clear pre-existing events for this action so re-loading
	# a game's inputs doesn't accumulate duplicate bindings.
	if InputMap.has_action(name):
		InputMap.action_erase_events(name)
	else:
		InputMap.add_action(name)

	for key_str in keys:
		var keycode: int = OS.find_keycode_from_string(key_str)
		if keycode == 0:
			push_warning("[InputRegistrar] unknown key '%s' for action '%s'"
				% [key_str, name])
			continue
		var event := InputEventKey.new()
		event.physical_keycode = keycode
		InputMap.action_add_event(name, event)
	return name


# ============================================================
# PER-FRAME POLLING
# ============================================================

## Per-frame input polling. Called from `world.gd::_process(delta)` to
## read Godot's InputMap state and queue actions onto the scheduler
## bound to the active actor. Replaces the in-line `_poll_input` that
## used to live in world.gd (extracted 2026-05-11).
##
## Three responsibilities, in order:
##  1. HOLD actions — fire every frame the key is pressed
##     (Input.is_action_pressed). Tracks per-axis state for stop
##     injection (move_north/_south on Y, move_east/_west on X).
##  2. PRESS actions — fire once on press-edge
##     (Input.is_action_just_pressed).
##  3. Per-axis idle stop injection (ADR 0040): when neither key on an
##     axis is held AND the actor has non-zero velocity on that axis,
##     queue `stop_x` / `stop_y`. SUPPRESSED for actors with
##     `state.zero_velocity_pretick=true` (camera-relative WASD model
##     handles this via pretick zero; injecting stop_x/_y would wipe
##     the diagonal vector's component on the same tick).
##
## Plus legacy global `stop_action_on_idle` for backwards-compat with
## older demos using a single `stop` action.
##
## Why static + parameterized: lets world.gd stay focused on
## orchestration; InputRegistrar owns the full input lifecycle
## (registration + polling). Keeps the per-axis stop logic + ADR 0040
## pretick-zero carve-out co-located with the action lists they
## reference.
static func poll(scheduler, actor_id: String,
                 input_actions_hold: Array, input_actions_press: Array,
                 stop_action_on_idle: String, entities: Dictionary) -> void:
	if actor_id == "":
		return
	# Per-axis idle detection (added 2026-05-10): track which movement
	# axes have keys pressed. When ALL keys on an axis are released,
	# queue a per-axis stop action.
	var ns_held := false
	var ew_held := false
	var any_movement_pressed := false

	# HOLD actions — fire every frame while held. Skip actions not in
	# InputMap (per-game inputs.json may not register every default —
	# Tier 2.6t).
	for action in input_actions_hold:
		if not InputMap.has_action(action):
			continue
		if Input.is_action_pressed(action):
			scheduler.queue_input(action, {"actor": actor_id})
			var act_s := str(action)
			if act_s.begins_with("move_"):
				any_movement_pressed = true
				if act_s == "move_north" or act_s == "move_south":
					ns_held = true
				elif act_s == "move_east" or act_s == "move_west":
					ew_held = true

	# PRESS actions — fire once on press-edge
	for action in input_actions_press:
		if not InputMap.has_action(action):
			continue
		if Input.is_action_just_pressed(action):
			scheduler.queue_input(action, {"actor": actor_id})

	# Per-axis stop: if no key on the axis is held, queue per-axis stop.
	# Read current velocity once; only queue when there's something to
	# stop (avoid spamming the input queue with no-op events).
	#
	# ADR 0040 Defect #1 (2026-05-10): SUPPRESS per-axis stop injection
	# for actors with `state.zero_velocity_pretick=true`. Those actors
	# use camera-relative WASD via velocity_add_relative; their
	# advance_one_tick zeroes velocity each tick BEFORE the input phase,
	# so the pretick zero already handles "no input → zero velocity".
	# The per-axis stop logic was designed for world-frame velocity_set
	# and would WIPE the camera-relative diagonal contributions.
	var actor_ent = entities.get(actor_id, null)
	if actor_ent is Entity:
		var pretick_zero := bool((actor_ent as Entity).get_state("zero_velocity_pretick", false))
		if not pretick_zero:
			var v = (actor_ent as Entity).get_velocity()
			var vx: float = 0.0
			var vy: float = 0.0
			if v is Vector2:
				vx = (v as Vector2).x
				vy = (v as Vector2).y
			elif v is Vector3:
				vx = (v as Vector3).x
				vy = (v as Vector3).z
			if not ew_held and absf(vx) > 0.001:
				scheduler.queue_input("stop_x", {"actor": actor_id})
			if not ns_held and absf(vy) > 0.001:
				scheduler.queue_input("stop_y", {"actor": actor_id})

	# Legacy global stop (fully idle) — kept for backwards-compat with
	# any existing demo using it. New games should use stop_x / stop_y
	# (the lib_wasd_stop_x / lib_wasd_stop_y rules). ADR 0040: same
	# pretick-zero suppression as per-axis stops above.
	var legacy_stop_pretick_zero := false
	if actor_ent is Entity:
		legacy_stop_pretick_zero = bool((actor_ent as Entity).get_state("zero_velocity_pretick", false))
	if not legacy_stop_pretick_zero \
			and stop_action_on_idle != "" \
			and not any_movement_pressed \
			and stop_action_on_idle != "stop_x" \
			and stop_action_on_idle != "stop_y":
		var v2 = (actor_ent as Entity).get_velocity() if actor_ent is Entity else null
		var v_nonzero: bool = false
		if v2 is Vector2:
			v_nonzero = (v2 as Vector2) != Vector2.ZERO
		elif v2 is Vector3:
			v_nonzero = (v2 as Vector3) != Vector3.ZERO
		if v_nonzero:
			scheduler.queue_input(stop_action_on_idle, {"actor": actor_id})
