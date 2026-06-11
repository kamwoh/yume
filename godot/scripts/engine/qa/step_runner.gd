extends RefCounted
class_name StepRunner

## ADR 0039 — Playwright-style scenario steps. Single source of truth
## for both `scenario_runner.gd` (headless tests) and `capture_runner.gd`
## (visual QA captures).
##
## 9 verbs: press / hold / release / click / wait / tick / screenshot /
## expect / key. See ADR for schema.
##
## Usage:
##   var ctx := {"data_root": "res://data/demo_X"}
##   var result := StepRunner.run(steps, world, ctx)
##   # result == {"passed": int, "failed": int, "failures": Array,
##   #            "screenshots": Array}
##
## Per Condition C4 (tech-director, 2026-05-10): step runner MUST call
## _advance(world) — the canonical tick body — never invent
## its own. Live play and tests run identical state transitions.


## Run a step list against a World. Returns metrics dict (always present
## fields: passed, failed, failures, screenshots, held).
static func run(steps: Array, world: World, ctx: Dictionary = {}) -> Dictionary:
	if not ctx.has("held"):
		ctx["held"] = []
	if not ctx.has("passed"):
		ctx["passed"] = 0
	if not ctx.has("failed"):
		ctx["failed"] = 0
	if not ctx.has("failures"):
		ctx["failures"] = []
	if not ctx.has("screenshots"):
		ctx["screenshots"] = []
	if not ctx.has("verbose"):
		ctx["verbose"] = true
	if not ctx.has("scenario"):
		ctx["scenario"] = ""

	for step in steps:
		if not (step is Dictionary):
			continue
		var verb := _detect_verb(step)
		match verb:
			"press":
				await _do_press(step, world, ctx)
			"hold":
				await _do_hold(step, world, ctx)
			"release":
				_do_release(step, world, ctx)
			"click":
				_do_click(step, world, ctx)
			"wait":
				_do_wait(step, world, ctx)
			"tick":
				_do_tick(step, world, ctx)
			"screenshot":
				await _do_screenshot(step, world, ctx)
			"expect":
				_do_expect(step, world, ctx)
			"key":
				_do_key(step, world, ctx)
			_:
				_raise(
					world,
					EngineError.STEP_UNKNOWN_VERB,
					"Unknown step verb in: %s" % str(step.keys()),
					{"step": step}
				)

	# Auto-release any still-held actions at end of scenario.
	for action in ctx["held"]:
		Input.action_release(str(action))
	ctx["held"] = []
	return ctx


# Detect which verb-key the step dict uses. Returns "" on unknown.
static func _detect_verb(step: Dictionary) -> String:
	for v in ["press", "hold", "release", "click", "wait", "tick", "screenshot", "expect", "key"]:
		if step.has(v):
			return v
	return ""


# ============================================================
# Verbs
# ============================================================


static func _do_press(step: Dictionary, world: World, _ctx: Dictionary) -> void:
	var action := str(step["press"])
	if not InputMap.has_action(action):
		_raise(
			world,
			EngineError.STEP_UNKNOWN_ACTION,
			"press: unknown action '%s'" % action,
			{"step": step}
		)
		return
	# ADR 0060 Phase 1 — ONE input path. Scripted input is now indistinct
	# from a real keypress: we set Godot's Input state, then drive the SAME
	# InputRegistrar.poll() the live `_process` loop uses (via _drive_poll).
	# poll reads is_action_just_pressed / is_action_pressed and queues onto
	# the scheduler — so press-vs-hold edge classification, per-axis stop
	# injection, and per-tick dedup all match live play exactly. No more
	# direct scheduler.queue_input bypass.
	#
	# Freeze gate mirror: world.gd::_process skips _poll_input when
	# screen_freeze_world / overlay_freeze_world is set (modal/overlay up).
	# Mirrored so a scripted press while a modal is open doesn't re-fire
	# the open-rule (empirical 2026-05-17 I-toggle double-open).
	Input.action_press(action)
	if not _is_world_frozen(world):
		_drive_poll(world)
		world.record_trajectory_action(action)
	_advance(world)
	# Mirror the live-frame screen_flow tick BEFORE releasing so any
	# frame-driven observer (ScreenFlow._handle_global_inputs, GameShell
	# HUD bindings) sees the "pressed" state — the close-toggle path lives
	# in screen_flow's _process, not the scheduler input phase.
	_tick_screen_flow(world)
	Input.action_release(action)
	_tick_screen_flow(world)
	# ADR 0060 Phase 1 — the frame boundary that REPLACES the old
	# _scripted_action_consumed carve-out. Godot's is_action_just_pressed
	# does NOT clear until a real process frame elapses; without this yield,
	# EVERY action pressed earlier in the scenario stays "just_pressed" and
	# poll re-queues all of them each step (rule-ordering then picks the
	# winner — the slot_1/slot_2/slot_4 bug). Awaiting one frame (action
	# already released) clears the edge so the next press is a distinct edge
	# and the live capture poll can't re-fire. Scenario mode sets
	# World._process=false so this frame can't auto-advance a tick, and the
	# scenario loop awaits _run_one so result accounting stays correct.
	if world != null and world.get_tree() != null:
		await world.get_tree().process_frame


static func _do_hold(step: Dictionary, world: World, _ctx: Dictionary):
	var spec = step["hold"]
	var actions: Array = []
	if spec is Array:
		for a in spec:
			actions.append(str(a))
	else:
		actions.append(str(spec))
	# Validate all actions before pressing any.
	for action in actions:
		if not InputMap.has_action(action):
			_raise(
				world,
				EngineError.STEP_UNKNOWN_ACTION,
				"hold: unknown action '%s'" % action,
				{"step": step}
			)
			return
	# Duration check.
	if not (step.has("for")):
		_raise(
			world,
			EngineError.STEP_INVALID_DURATION,
			"hold requires 'for' (seconds)",
			{"step": step}
		)
		return
	var seconds := float(step["for"])
	if seconds <= 0.0:
		_raise(
			world,
			EngineError.STEP_INVALID_DURATION,
			"hold 'for' must be positive (got %s)" % str(seconds),
			{"step": step}
		)
		return
	for action in actions:
		Input.action_press(action)
	# Round (per Condition C3) so sub-tick durations don't silently advance 0.
	var ticks: int = max(1, int(round(seconds / world.tick_seconds)))
	for i in range(ticks):
		# ADR 0060 Phase 1 — drive the live poll each tick. With the actions
		# held in Godot's Input state, poll's hold branch (is_action_pressed)
		# re-queues them every tick, exactly as live play's per-frame poll
		# does. Freeze-mirror: when a modal/overlay is up, world.gd skips
		# _poll_input, so we skip too (queue stays empty for held actions).
		if not _is_world_frozen(world):
			_drive_poll(world)
			for action in actions:
				world.record_trajectory_action(action)
		_advance(world)
	# Mirror live-frame screen_flow tick BEFORE release for screen-toggle
	# observability (see _do_press). Live play always has ≥1 frame of
	# "actually pressed" before release; this re-creates that signal.
	_tick_screen_flow(world)
	for action in actions:
		Input.action_release(action)
	_tick_screen_flow(world)
	# Clear the press-edge across a real frame (see _do_press). Held actions
	# use is_action_pressed, but a trailing just_pressed can latch and re-fire
	# on the next press/poll; one frame after release clears it.
	if world != null and world.get_tree() != null:
		await world.get_tree().process_frame


# ADR 0060 Phase 1 — the single scripted-input seam. Drives the SAME
# InputRegistrar.poll() that world.gd::_process calls for live play, so
# scripted input and real keypresses share one code path. Reads Godot's
# Input state (set by the caller via Input.action_press) + the engine's
# registered press/hold action lists, and queues onto the scheduler bound
# to the resolved actor. Replaces the old direct scheduler.queue_input
# bypass (which diverged from live and needed the _scripted_action_consumed
# carve-out to suppress the resulting double-fire).
static func _drive_poll(world: World) -> void:
	if world == null or world.scheduler == null:
		return
	var actor_id := _find_actor_id(world)
	if actor_id == "":
		return
	var stop_idle := ""
	if "stop_action_on_idle" in world:
		stop_idle = str(world.get("stop_action_on_idle"))
	InputRegistrar.poll(
		world.scheduler,
		actor_id,
		world.input_actions_hold,
		world.input_actions_press,
		stop_idle,
		world.entities,
	)


# One-tick advance helper. Mirrors legacy scenario_runner's per-tick block:
# scheduler runs the input/decide/react phases via advance_one_tick, then motion
# integrator runs once with delta = tick_seconds. In LIVE play, motion integrates
# at frame rate in _process (~60Hz × 0.017s ≈ tick rate) — this synthesizes one
# equivalent tick-step's worth of motion for headless tests.
static func _advance(world: World) -> void:
	world.advance_one_tick()
	# ADR 0045: motion runs per-character-body via _physics_process in
	# live play; headless tests have no physics server, so walk them
	# manually via tick_headless. Non-character entities don't move
	# (use body_type:"character" to opt in).
	_tick_character_bodies(world)
	# ADR 0060 de-legacy (2026-05-31): drain the pending pipelines GameShell
	# drives per-frame in live play (game_shell.gd:208-213) — level transitions,
	# save/load, world reset. The scenario path doesn't mount GameShell, so
	# without this a steps[] scenario can't process a level transition (the old
	# actions[] loop drained _level_transitions by hand). Makes the canonical
	# path equivalent. Idempotent: process_pending no-ops when nothing is queued.
	if world._level_transitions != null:
		world._level_transitions.process_pending(world.scheduler.env)
	if world._save_load != null:
		world._save_load.process_pending(world.scheduler.env)
	if world._world_reset != null:
		world._world_reset.process_pending(world.scheduler.env)


# Mirror what live-play frames do for ScreenFlow:
#   1. _drain_screen_events  → push/pop screens from transition_screen effects
#   2. _handle_global_inputs → fire screen-level edge handlers (I-toggle, M-toggle)
# Synchronous so step_runner can call without breaking _ready's non-async caller.
# Used by _do_press / _do_hold / _do_wait so scripted input observes the same
# screen-state behavior as live play.
static func _tick_screen_flow(world: World) -> void:
	if world == null:
		return
	var sf := _find_screen_flow(world)
	if sf == null:
		return
	if sf.has_method("drain"):
		sf.drain()
	# global_inputs handler is private (`_handle_global_inputs`). Call via
	# `call` so non-existent methods are a no-op rather than a crash.
	if sf.has_method("_handle_global_inputs"):
		sf.call("_handle_global_inputs")


# Locate the ScreenFlow node. WorldBoot mounts it as a sibling/child of
# World (path varies by scene). Cheap lookup paths first; never recurse
# into entity subtrees (live scenes have 200+ entities → recursion is
# expensive). Returns null if no ScreenFlow node is mounted (legitimate
# for pure-headless tests without a UI shell).
static func _find_screen_flow(world: World) -> Node:
	# Sibling-or-child of World (most common — WorldBoot adds as child).
	var sf := world.get_node_or_null("ScreenFlow")
	if sf != null:
		return sf
	sf = world.get_node_or_null("../ScreenFlow")
	if sf != null:
		return sf
	# Walk World's parent's children only (siblings of World) — avoids
	# recursing into the entity tree.
	var parent: Node = world.get_parent()
	if parent != null:
		for sib_v in parent.get_children():
			var sib: Node = sib_v
			if sib.name == "ScreenFlow":
				return sib
	return null


# Mirror world.gd::_process's freeze condition. world.gd skips _poll_input
# when either flag is non-zero, so input rules don't fire under freeze.
# Mirrored here so scripted input has the same gating — without this,
# I-press while inventory is open would re-fire ui_open_inventory and
# double-push the screen. Empirical case 2026-05-17.
static func _is_world_frozen(world: World) -> bool:
	if world == null:
		return false
	# ADR 0060 de-legacy (2026-05-31): the freeze-mirror exists to match live
	# screen behavior (don't re-fire an open-rule while a modal is up — the
	# I-toggle double-open). That applies on the LIVE capture path, where
	# World._process drives the real game/screen loop. In SCENARIO mode
	# StepRunner is the sole tick driver (World._process is disabled,
	# is_processing()==false) and there is no GameShell driving input/screen
	# dismissal — so screen_freeze_world (set by screens.json's starting_screen,
	# e.g. a title screen ScreenFlow pushes at boot) is a phantom that scripted
	# gameplay input must NOT be gated by (the legacy actions[] loop
	# direct-queued past it). Discriminator: _process disabled == scenario mode.
	if not world.is_processing():
		return false
	var ws: Dictionary = world.world_state
	return (
		int(ws.get("screen_freeze_world", 0)) != 0
		or int(ws.get("overlay_freeze_world", 0)) != 0
	)


static func _tick_character_bodies(world: World) -> void:
	var dt: float = float(world.tick_seconds)
	for id in world.entities:
		var ent = world.entities[id]
		if not (ent is Entity):
			continue
		if not (ent as Entity).has_meta("_physics_body"):
			continue
		var body = (ent as Entity).get_meta("_physics_body")
		if body is CharacterBodyRunner:
			(body as CharacterBodyRunner).tick_headless(dt)


static func _find_actor_id(world: World) -> String:
	var entities: Dictionary = world.scheduler.env.get("entities", {})
	# Mirror LIVE play's resolution (ADR 0016): any booted world has an
	# ActorManager, and the active actor's controlled entity is who
	# receives scripted input — exactly like world.gd::_poll_input. A
	# forked tag-scan here silently dropped scripted input for any game
	# whose controlled entity isn't tagged world.actor_tag. Empirical
	# 2026-06-11: autorace possession via actors.json (cars tagged
	# "car"/"actor", not "player") — every --capture-input press
	# resolved to "" and was dropped, while live keyboard worked.
	if "actor_manager" in world and world.actor_manager != null:
		return world.actor_manager.resolve_active_entity(entities)
	# Fallback (actor_manager == null: auto_start=false unit-test
	# worlds only): legacy tag scan.
	var tag := "actor"
	if "actor_tag" in world:
		tag = str(world.get("actor_tag"))
	for id in entities:
		var e = entities[id]
		if e is Entity and e.has_tag(tag):
			return id
	# Fallback: any entity tagged "player".
	for id in entities:
		var e = entities[id]
		if e is Entity and e.has_tag("player"):
			return id
	return ""


static func _do_release(step: Dictionary, world: World, ctx: Dictionary) -> void:
	var action := str(step["release"])
	# Tolerant: release a not-currently-held action is a warning, not error.
	# Strict mode (future) could elevate to STEP_RELEASE_NOT_HELD.
	if not InputMap.has_action(action):
		_raise(
			world,
			EngineError.STEP_UNKNOWN_ACTION,
			"release: unknown action '%s'" % action,
			{"step": step}
		)
		return
	Input.action_release(action)
	if action in ctx["held"]:
		(ctx["held"] as Array).erase(action)


static func _do_click(step: Dictionary, world: World, _ctx: Dictionary) -> void:
	var selector_v = step["click"]
	var sel: Dictionary
	if selector_v is Dictionary:
		sel = selector_v
	else:
		sel = {"text": str(selector_v)}
	var screen_flow := world.get_node_or_null("/root/ScreenFlow")
	# Walk the screen + overlay stacks for matching Controls.
	var matches := _find_controls(screen_flow, sel)
	if matches.is_empty():
		_raise(
			world,
			EngineError.STEP_CLICK_NOT_FOUND,
			"click selector matched nothing: %s" % str(sel),
			{"step": step}
		)
		return
	if matches.size() > 1 and not sel.has("screen"):
		_raise(
			world,
			EngineError.STEP_CLICK_AMBIGUOUS,
			"click selector matched %d controls; add 'screen' to disambiguate" % matches.size(),
			{"step": step, "matches": matches.size()}
		)
		return
	var node = matches[0]
	if node is BaseButton:
		(node as BaseButton).pressed.emit()
	elif node.has_signal("pressed"):
		node.emit_signal("pressed")
	# Drain ScreenFlow event buffer so transition_screen / load_state from
	# on_click chain land BEFORE the next step (Condition C4 follow-up).
	if screen_flow != null and screen_flow.has_method("drain"):
		screen_flow.drain()
	# One tick lets any rule-side effects (state_set, signal emit) propagate.
	_advance(world)


static func _do_wait(step: Dictionary, world: World, _ctx: Dictionary) -> void:
	var spec = step["wait"]
	var ticks: int = 0
	if spec is int or spec is float:
		# Number → seconds.
		ticks = max(1, int(round(float(spec) / world.tick_seconds)))
	elif spec is Dictionary:
		var d: Dictionary = spec
		if d.has("ticks"):
			ticks = int(d["ticks"])
		elif d.has("seconds"):
			ticks = max(1, int(round(float(d["seconds"]) / world.tick_seconds)))
	if ticks <= 0:
		_raise(
			world,
			EngineError.STEP_INVALID_DURATION,
			"wait requires positive seconds or ticks",
			{"step": step}
		)
		return
	for i in range(ticks):
		_advance(world)
	# Mirror live-frame screen_flow tick at end of wait so any pending
	# transition_screen events from upstream rule effects get drained
	# before the next scripted step reads world.current_screen. Without
	# this, the rule's transition_screen sits in env.screen_event_buffer
	# until the next natural frame which may not happen in time.
	_tick_screen_flow(world)


static func _do_tick(step: Dictionary, world: World, _ctx: Dictionary) -> void:
	var n := int(step["tick"])
	if n <= 0:
		_raise(
			world, EngineError.STEP_INVALID_DURATION, "tick requires positive count", {"step": step}
		)
		return
	for i in range(n):
		_advance(world)


static func _do_screenshot(step: Dictionary, world: World, ctx: Dictionary):
	var spec = step["screenshot"]
	var path: String
	var label := ""
	if spec is String:
		path = spec
	elif spec is Dictionary:
		path = str((spec as Dictionary).get("path", ""))
		label = str((spec as Dictionary).get("label", ""))
	if path == "":
		push_warning("[step] screenshot missing path")
		return
	if not path.contains("://"):
		path = "user://" + path
	# Yield TWO frames so pending queue_free's (e.g. just-popped screen
	# layers) actually destroy before we capture. ONE frame is enough to
	# fire the queue_free callbacks but the renderer's next paint comes
	# AFTER. With a single yield, a screenshot taken right after a
	# pop_screen would still include the dying layer's pixels.
	# Empirical case 2026-05-17: i_press_toggle test's third screenshot
	# (after I-toggle pop) captured the inventory layer because it was
	# pending queue_free at await-resume time.
	if world.get_tree() != null:
		await world.get_tree().process_frame
		await world.get_tree().process_frame
	var vp := world.get_viewport()
	if vp == null:
		push_warning("[step] screenshot: no viewport")
		return
	var img: Image = vp.get_texture().get_image()
	if img == null:
		push_warning("[step] screenshot: no viewport image")
		return
	var err := img.save_png(path)
	if err == OK:
		ctx["screenshots"].append({"path": path, "label": label})
		if ctx.get("verbose", true):
			print("  📸 screenshot %s%s" % [path, (" (" + label + ")") if label != "" else ""])
	else:
		push_warning("[step] screenshot save_png err %d at %s" % [err, path])


static func _do_expect(step: Dictionary, world: World, ctx: Dictionary) -> void:
	var assertions = step["expect"]
	var arr: Array
	if assertions is Array:
		arr = assertions
	else:
		arr = [assertions]
	for a in arr:
		if a is Dictionary:
			_check_one(a, world, ctx)


static func _do_key(_step: Dictionary, _world: World, _ctx: Dictionary) -> void:
	# Raw keycode escape hatch. Currently a no-op stub — the typical use
	# (dismissing a hand-wired modal) should go through `click` once
	# control_factory propagates JSON id (C2 above). Future ADR can extend.
	push_warning("[step] verb 'key' is a v1 stub — use 'click' or 'press' instead")


# ============================================================
# Click selector resolution
# ============================================================


# Walks the screen + overlay stacks for Controls matching `sel`.
# Selector keys: text, id, screen (scope to a screen id).
static func _find_controls(screen_flow, sel: Dictionary) -> Array:
	var roots: Array = []
	if screen_flow != null and "_screens_node" in screen_flow:
		var sn = screen_flow.get("_screens_node")
		if sn != null:
			roots.append(sn)
	# Also walk the OverlayManager root, if present.
	if screen_flow != null and screen_flow.has_node("/root/OverlayManager"):
		roots.append(screen_flow.get_node("/root/OverlayManager"))
	# Fallback — scan any CanvasLayer in the scene (covers HUD buttons too).
	if roots.is_empty():
		var tree := Engine.get_main_loop()
		if tree is SceneTree:
			roots.append((tree as SceneTree).root)
	var out: Array = []
	for root in roots:
		_walk_match(root, sel, out)
	return out


static func _walk_match(node: Node, sel: Dictionary, out: Array) -> void:
	if node == null:
		return
	# Optional screen scope: skip if this branch isn't under the named screen.
	# (Implemented as a soft filter on root node names.)
	if sel.has("screen") and "name" in node:
		# Only constrain at top-of-walk; once descended, accept all.
		# (Called recursively; the screen scope check is handled by _find_controls
		# layer in a future tightening — v1 accepts the looser walk.)
		var _screen_id := str(sel["screen"])  # noqa: read-only for future use
	if node is Control:
		var match_text := false
		var match_id := false
		if sel.has("text"):
			var want := str(sel["text"])
			if "text" in node and str(node.text) == want:
				match_text = true
		if sel.has("id"):
			if str(node.name) == str(sel["id"]):
				match_id = true
		# Match if any specified selector hits.
		var has_text_sel := sel.has("text")
		var has_id_sel := sel.has("id")
		if (has_text_sel and match_text) or (has_id_sel and match_id):
			# Only Buttons / pressable Controls qualify.
			if node is BaseButton or node.has_signal("pressed"):
				out.append(node)
	for child in node.get_children():
		_walk_match(child, sel, out)


# ============================================================
# Expect assertions (mirror of scenario_runner._check_assertion)
# ============================================================


static func _check_one(a: Dictionary, world: World, ctx: Dictionary) -> void:
	# Two forms:
	#   1) Old shape:  {"entity_field": {query, field, op, value}}
	#                   {"entity_count": {query, op, value}}
	#                   {"world_field": {field, op, value}}
	#                   {"ui_present": "<text or {id|text|screen}>"}
	#                   {"ui_hidden": ...}
	#                   {"screen_active": "title"}
	#   2) Compact: {"<dotted.path>": {"<op>": value}}
	#       e.g. {"player.state.hp": {">=": 50}}, {"world.day": {"==": 5}}
	if a.has("entity_field"):
		_assert_entity_field(a["entity_field"], world, ctx)
	elif a.has("entity_count"):
		_assert_entity_count(a["entity_count"], world, ctx)
	elif a.has("world_field"):
		_assert_world_field(a["world_field"], world, ctx)
	elif a.has("ui_present"):
		_assert_ui(a["ui_present"], true, world, ctx)
	elif a.has("ui_hidden"):
		_assert_ui(a["ui_hidden"], false, world, ctx)
	elif a.has("screen_active"):
		_assert_screen_active(str(a["screen_active"]), world, ctx)
	else:
		# Compact form: single non-comment key with dotted path. Strip
		# `_comment` keys so authors can document compact assertions inline
		# without breaking detection.
		var path_keys: Array = []
		for k in a.keys():
			if str(k).begins_with("_"):
				continue
			path_keys.append(k)
		if path_keys.size() == 1 and a[path_keys[0]] is Dictionary:
			_assert_compact(str(path_keys[0]), a[path_keys[0]], world, ctx)
		else:
			_fail(ctx, "expect: unknown assertion shape: %s" % str(a))


static func _assert_entity_field(spec: Dictionary, world: World, ctx: Dictionary) -> void:
	var query: Dictionary = spec.get("query", {})
	var matches := _query_entities(world, query)
	if matches.is_empty():
		_fail(ctx, "entity_field %s: no entities matched" % _summarize_query(query))
		return
	var ent: Entity = matches[0]
	var field := str(spec.get("field", ""))
	var got = _resolve_field(ent, field)
	var op := str(spec.get("op", "=="))
	var expected = spec.get("value", 0)
	if _cmp(got, op, expected):
		_pass(
			ctx,
			(
				"entity_field %s.%s %s %s (got %s)"
				% [_summarize_query(query), field, op, str(expected), str(got)]
			)
		)
	else:
		_fail(
			ctx,
			(
				"entity_field %s.%s: expected %s %s, got %s"
				% [_summarize_query(query), field, op, str(expected), str(got)]
			)
		)


static func _assert_entity_count(spec: Dictionary, world: World, ctx: Dictionary) -> void:
	var query: Dictionary = spec.get("query", {})
	var matches := _query_entities(world, query)
	var got: float = matches.size()
	var op := str(spec.get("op", "=="))
	var expected := float(spec.get("value", 0))
	if _cmp(got, op, expected):
		_pass(
			ctx,
			"entity_count %s %s %s (got %d)" % [_summarize_query(query), op, expected, int(got)]
		)
	else:
		_fail(
			ctx,
			(
				"entity_count %s: expected %s %s, got %d"
				% [_summarize_query(query), op, expected, int(got)]
			)
		)


static func _assert_world_field(spec: Dictionary, world: World, ctx: Dictionary) -> void:
	var field := str(spec.get("field", ""))
	var got = world.world_state.get(field, null)
	var op := str(spec.get("op", "=="))
	var expected = spec.get("value", null)
	if _cmp(got, op, expected):
		_pass(ctx, "world_field %s %s %s (got %s)" % [field, op, str(expected), str(got)])
	else:
		_fail(ctx, "world_field %s: expected %s %s, got %s" % [field, op, str(expected), str(got)])


static func _assert_ui(selector_v, expect_present: bool, world: World, ctx: Dictionary) -> void:
	var screen_flow := world.get_node_or_null("/root/ScreenFlow")
	var sel: Dictionary = selector_v if selector_v is Dictionary else {"text": str(selector_v)}
	var matches := _find_controls(screen_flow, sel)
	var present := not matches.is_empty()
	if present == expect_present:
		_pass(ctx, "ui_%s %s" % ["present" if expect_present else "hidden", str(sel)])
	else:
		_fail(
			ctx,
			(
				"ui_%s %s: was %s"
				% [
					"present" if expect_present else "hidden",
					str(sel),
					"present" if present else "hidden"
				]
			)
		)


static func _assert_screen_active(want_id: String, world: World, ctx: Dictionary) -> void:
	var screen_flow := _find_screen_flow(world)
	if screen_flow == null:
		_fail(ctx, "screen_active %s: no ScreenFlow node found in tree" % want_id)
		return
	# ScreenFlow exposes a `top()` or `current_screen` accessor; fall back to
	# inspecting `_stack` if needed.
	var top := ""
	if screen_flow.has_method("current_screen_id"):
		top = str(screen_flow.current_screen_id())
	elif "_stack" in screen_flow:
		var stack = screen_flow.get("_stack")
		if stack is Array and not (stack as Array).is_empty():
			var last = stack[-1]
			if last is Dictionary:
				top = str(last.get("id", ""))
	if top == want_id:
		_pass(ctx, "screen_active == %s" % want_id)
	else:
		_fail(ctx, "screen_active: expected %s, got %s" % [want_id, top])


static func _assert_compact(
	path: String, op_dict: Dictionary, world: World, ctx: Dictionary
) -> void:
	# Resolve "<prefix>.<rest>" — prefix is "world" OR a unique tag.
	var dot := path.find(".")
	if dot < 0:
		_fail(ctx, "expect compact: path '%s' has no '.'" % path)
		return
	var prefix := path.substr(0, dot)
	var rest := path.substr(dot + 1)
	var op: String = "=="
	if op_dict.size() == 1:
		op = str(op_dict.keys()[0])
	var expected = op_dict.get(op, 0)
	if prefix == "world":
		var got = _resolve_world_path(world, rest)
		if _cmp(got, op, expected):
			_pass(ctx, "world.%s %s %s (got %s)" % [rest, op, str(expected), str(got)])
		else:
			_fail(ctx, "world.%s: expected %s %s, got %s" % [rest, op, str(expected), str(got)])
		return
	# Otherwise treat prefix as a tag. tags_all=[prefix], select first.
	var matches := _query_entities(world, {"tags_all": [prefix]})
	if matches.is_empty():
		_fail(ctx, "expect compact: no entity tagged '%s'" % prefix)
		return
	var ent: Entity = matches[0]
	var got = _resolve_field(ent, rest)
	if _cmp(got, op, expected):
		_pass(ctx, "%s.%s %s %s (got %s)" % [prefix, rest, op, str(expected), str(got)])
	else:
		_fail(ctx, "%s.%s: expected %s %s, got %s" % [prefix, rest, op, str(expected), str(got)])


# ============================================================
# Query / field resolution (mirrors scenario_runner's helpers)
# ============================================================


static func _query_entities(world: World, q: Dictionary) -> Array:
	var env: Dictionary = world.scheduler.env
	var entities: Dictionary = env.get("entities", {})
	var out: Array = []
	for id in entities:
		var e = entities[id]
		if e is Entity and QueryLib.matches(e, q, env):
			out.append(e)
	return out


static func _resolve_field(e: Entity, path: String):
	var parts := path.split(".")
	var cur = e
	for p in parts:
		if cur is Entity:
			match p:
				"state":
					cur = (cur as Entity).state
				"properties":
					cur = (cur as Entity).properties
				_:
					return null
		elif cur is Dictionary:
			if not (cur as Dictionary).has(p):
				return null
			cur = (cur as Dictionary)[p]
		elif cur is Vector2:
			match p:
				"x":
					cur = (cur as Vector2).x
				"y":
					cur = (cur as Vector2).y
				_:
					return null
		elif cur is Vector3:
			match p:
				"x":
					cur = (cur as Vector3).x
				"y":
					cur = (cur as Vector3).y
				"z":
					cur = (cur as Vector3).z
				_:
					return null
		else:
			return null
	return cur


static func _resolve_world_path(world: World, path: String):
	var parts := path.split(".")
	var cur = world.world_state
	for p in parts:
		if cur is Dictionary:
			if not (cur as Dictionary).has(p):
				return null
			cur = (cur as Dictionary)[p]
		else:
			return null
	return cur


static func _cmp(got, op: String, expected) -> bool:
	if got is int or got is float:
		var g := float(got)
		var x := float(expected)
		match op:
			"==":
				return g == x
			"!=":
				return g != x
			"<":
				return g < x
			"<=":
				return g <= x
			">":
				return g > x
			">=":
				return g >= x
	match op:
		"==":
			return str(got) == str(expected)
		"!=":
			return str(got) != str(expected)
	return false


static func _summarize_query(q: Dictionary) -> String:
	if q.has("tags_all"):
		return "tags=%s" % str(q["tags_all"])
	return str(q)


# ============================================================
# Recording + diagnostics
# ============================================================


static func _pass(ctx: Dictionary, msg: String) -> void:
	ctx["passed"] = int(ctx["passed"]) + 1
	if ctx.get("verbose", true):
		print("  ✓ %s" % msg)


static func _fail(ctx: Dictionary, msg: String) -> void:
	ctx["failed"] = int(ctx["failed"]) + 1
	var sn := str(ctx.get("scenario", ""))
	(ctx["failures"] as Array).append("%s — %s" % [sn, msg] if sn != "" else msg)
	if ctx.get("verbose", true):
		print("  ✗ %s" % msg)


static func _raise(world: World, code: String, msg: String, info: Dictionary) -> void:
	var env = world.scheduler.env if world.scheduler != null else {}
	if EngineError != null:
		EngineError.raise(env, code, msg, info, "")
	else:
		push_error("[step_runner] %s: %s" % [code, msg])
