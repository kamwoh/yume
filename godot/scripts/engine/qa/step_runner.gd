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
				_do_press(step, world, ctx)
			"hold":
				_do_hold(step, world, ctx)
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
	# Single press-edge: queue + advance one tick + (no need to dequeue —
	# the scheduler consumes per-tick). Input.action_press also fires for
	# live captures so GameShell / renderer-side input handlers see the
	# press. In headless tests, queue_input is what actually drives rules.
	Input.action_press(action)
	_queue_input(world, action)
	_advance(world)
	Input.action_release(action)


static func _do_hold(step: Dictionary, world: World, _ctx: Dictionary) -> void:
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
		# Per-tick re-queue: hold semantics in scheduler.input_queue is
		# "each tick the action is held, fire its rule once". The live
		# poll_input does the same — re-queues every frame for hold-edge.
		for action in actions:
			_queue_input(world, action)
		_advance(world)
	for action in actions:
		Input.action_release(action)


# Queue an input into the scheduler's per-tick input queue. Mirrors the
# legacy scenario_runner pattern: scheduler.queue_input(action, ctx). The
# `actor` binding lets rules whose query targets the player resolve to
# the right entity.
static func _queue_input(world: World, action: String) -> void:
	if world.scheduler == null:
		return
	var actor_id := _find_actor_id(world)
	var ctx_dict: Dictionary = {}
	if actor_id != "":
		ctx_dict["actor"] = actor_id
	world.scheduler.queue_input(action, ctx_dict)


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
	# Yield one frame so the renderer paints latest state into the viewport
	# before we read it.
	if world.get_tree() != null:
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
	var screen_flow := world.get_node_or_null("/root/ScreenFlow")
	if screen_flow == null:
		_fail(ctx, "screen_active %s: no ScreenFlow autoload" % want_id)
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
