extends Node

## Tier 2.6s — game-specific scenario tests (JSON-driven).
##
## Loads `data/<game>/tests.json`, runs each scenario by:
##   1. Building a fresh World (auto_start=false, no renderer)
##   2. Calling world.load_data() to load entities + rules
##   3. Applying scenario setup (entity_state overrides, world overrides)
##   4. Ticking forward; at scripted ticks, injecting inputs via
##      scheduler.queue_input (same path as live keyboard input)
##   5. Evaluating assertions against the resulting env
##
## Why JSON not GDScript: each game's behavior tests should live with the
## game data, authored by content-designer. No engine-side per-game code.
##
## Invoked via:
##   godot --headless --path . scenes/scenario_test.tscn -- --game=<name>
##
## Schema (data/<game>/tests.json):
##   {
##     "scenarios": [
##       {
##         "name": "bullet_moves_after_fire",
##         "setup": {
##           "entity_state": {"player": {"facing": 0, "ammo": 5}}
##         },
##         "actions": [
##           {"tick": 1, "input": "spark"}
##         ],
##         "ticks": 10,
##         "assertions": [
##           {"type": "entity_count", "query": {"tags_all": ["bullet"]},
##            "op": ">=", "value": 1},
##           {"type": "entity_field", "select": "first",
##            "query": {"tags_all": ["bullet"]},
##            "field": "state.position.x", "op": ">", "value": 5.0}
##         ]
##       }
##     ]
##   }

var passed := 0
var failed := 0
var failures: Array = []
var verbose := true


func _ready() -> void:
	var data_root := _resolve_data_root()
	if data_root == "":
		push_error("[scenario] no --game=<name> cmdline arg")
		get_tree().quit(2)
		return
	var tests_path := data_root + "/tests.json"
	if not FileAccess.file_exists(tests_path):
		print("[scenario] no tests.json at %s — skipping" % tests_path)
		get_tree().quit(0)
		return

	var spec: Dictionary = _read_json(tests_path)
	var scenarios: Array = spec.get("scenarios", [])
	print("=== Yume scenario tests: %s ===" % data_root.get_file())
	for sc in scenarios:
		if not (sc is Dictionary):
			continue
		if (sc as Dictionary).get("_skip", false):
			continue
		_run_one(sc, data_root)
	print("\n=== RESULTS ===")
	print("passed: %d  failed: %d  total: %d" % [passed, failed, passed + failed])
	if failed > 0:
		print("\nFAILURES:")
		for f in failures:
			print("  ✗ " + f)
	get_tree().quit(0 if failed == 0 else 1)


# ============================================================
# Single scenario
# ============================================================

func _run_one(sc: Dictionary, data_root: String) -> void:
	var name := str(sc.get("name", "<unnamed>"))
	if verbose:
		print("\n[scenario] %s" % name)

	# Fresh World per scenario — full env reset.
	var world := World.new()
	world.data_root = data_root
	world.auto_start = false
	world.verbose = false
	world.renderer_script = ""  # headless: no renderer
	world.input_actions_press = PackedStringArray()  # we inject manually
	add_child(world)
	# Run lifecycle: _ready on World already fired during add_child; data
	# isn't loaded because auto_start=false. Load explicitly.
	world.load_data()
	# Mirror GameShell's scene.json read so tick_seconds matches live play.
	# Without this, motion integration uses the World default (0.5s) and
	# velocity test results are 10× off for games with tick_seconds=0.05.
	var scene_path := data_root + "/scene.json"
	if FileAccess.file_exists(scene_path):
		var sf := FileAccess.open(scene_path, FileAccess.READ)
		var raw := sf.get_as_text()
		sf.close()
		var sj := JSON.new()
		if sj.parse(raw) == OK and sj.data is Dictionary:
			var cfg: Dictionary = sj.data
			if cfg.has("tick_seconds"):
				world.tick_seconds = float(cfg["tick_seconds"])

	# Apply setup
	var setup: Dictionary = sc.get("setup", {})
	_apply_setup(world, setup)

	# Pre-resolve actor id for input injection
	var actor_id := _find_actor_id(world)

	# Run ticks; inject scripted inputs at scheduled tick numbers.
	var actions: Array = sc.get("actions", [])
	var n_ticks := int(sc.get("ticks", 30))
	for t in range(1, n_ticks + 1):
		for a in actions:
			if not (a is Dictionary):
				continue
			if int((a as Dictionary).get("tick", -1)) == t:
				var act := str((a as Dictionary).get("input", ""))
				if act != "" and actor_id != "":
					world.scheduler.queue_input(act, {"actor": actor_id})
		world.scheduler.tick()
		if world.has_method("_decrement_lifetimes"):
			world._decrement_lifetimes()
		# Motion integration normally runs in World._process(delta) at
		# frame rate. Headless scenario testing runs ticks discretely, so
		# we simulate motion using tick_seconds as the delta.
		if world.has_method("_integrate_motion"):
			world._integrate_motion(float(world.tick_seconds))

	# Assertions
	var assertions: Array = sc.get("assertions", [])
	for a in assertions:
		_check_assertion(world, a, name)

	# Cleanup
	world.queue_free()
	# Yield one frame so freeing cleans up before next scenario.
	await get_tree().process_frame


# ============================================================
# Setup
# ============================================================

func _apply_setup(world: World, setup: Dictionary) -> void:
	# spawn: extra entities to inject at scenario start.
	# Schema: [{def: "monster_imp", id: "test_imp", position: [x, y, z]}]
	var spawns: Array = setup.get("spawn", [])
	for spec in spawns:
		if not (spec is Dictionary): continue
		var s: Dictionary = spec
		var template := str(s.get("def", ""))
		var defs: Dictionary = world.scheduler.env.get("defs", {})
		if not defs.has(template): continue
		var override: Dictionary = {}
		if s.has("position"):
			override["position"] = s["position"]
		if s.has("state"):
			override["state"] = s["state"]
		var inst_id := str(s.get("id", "%s_setup_%d" % [template, randi()]))
		var ent := Entity.create(defs[template], inst_id, override)
		world.scheduler.env.get("entities", {})[inst_id] = ent
		if world.spatial_index != null:
			world.spatial_index.update_entity(inst_id, ent.get_planar_position())

	# entity_state: {entity_id: {field: value, ...}}
	var es: Dictionary = setup.get("entity_state", {})
	for ent_id in es:
		var ent = world.scheduler.env.get("entities", {}).get(ent_id, null)
		if ent is Entity:
			var fields: Dictionary = es[ent_id]
			var position_changed := false
			for k in fields:
				var v = fields[k]
				if (str(k) == "position" or str(k) == "velocity") and v is Array:
					if v.size() == 2:
						v = Vector2(float(v[0]), float(v[1]))
					elif v.size() == 3:
						v = Vector3(float(v[0]), float(v[1]), float(v[2]))
				ent.state[k] = v
				if str(k) == "position":
					position_changed = true
			# Setup mutating position must also update spatial index, else
			# contact queries against the new position don't find the entity.
			if position_changed and world.spatial_index != null:
				world.spatial_index.update_entity(ent_id, ent.get_planar_position())


func _find_actor_id(world: World) -> String:
	var entities: Dictionary = world.scheduler.env.get("entities", {})
	for id in entities:
		var e = entities[id]
		if e is Entity and e.has_tag(world.actor_tag):
			return id
	return ""


# ============================================================
# Assertions
# ============================================================

func _check_assertion(world: World, a, scenario_name: String) -> void:
	if not (a is Dictionary):
		return
	var atype := str(a.get("type", ""))
	match atype:
		"entity_count":
			_check_entity_count(world, a, scenario_name)
		"entity_field":
			_check_entity_field(world, a, scenario_name)
		_:
			_record_fail(scenario_name, "unknown assertion type '%s'" % atype)


func _check_entity_count(world: World, a: Dictionary, scenario_name: String) -> void:
	var query: Dictionary = a.get("query", {})
	var matches := _query_entities(world, query)
	var expected := float(a.get("value", 0))
	var op := str(a.get("op", "=="))
	var got: float = matches.size()
	if _cmp(got, op, expected):
		_record_pass("entity_count %s %s %s" % [_summarize_query(query), op, expected])
	else:
		_record_fail(scenario_name,
			"entity_count %s: expected %s %s, got %d" % [_summarize_query(query), op, expected, got])


func _check_entity_field(world: World, a: Dictionary, scenario_name: String) -> void:
	var select := str(a.get("select", "first"))
	var ent: Entity = null
	if select == "by_id":
		var lookup_id := str(a.get("id", ""))
		var got_ent = world.scheduler.env.get("entities", {}).get(lookup_id, null)
		if got_ent is Entity:
			ent = got_ent
		else:
			_record_fail(scenario_name,
				"entity_field by_id '%s': no such entity" % lookup_id)
			return
	else:
		var query: Dictionary = a.get("query", {})
		var matches := _query_entities(world, query)
		if matches.is_empty():
			_record_fail(scenario_name,
				"entity_field %s: no entities matched (select=%s)" % [_summarize_query(query), select])
			return
		ent = matches[0]
	var field := str(a.get("field", ""))
	var got = _resolve_field(ent, field)
	var op := str(a.get("op", "=="))
	var expected = a.get("value", 0)
	var label := "id=%s" % a.get("id", "?") if select == "by_id" \
		else _summarize_query(a.get("query", {}))
	if _cmp(got, op, expected):
		_record_pass("entity_field %s.%s %s %s (got %s)" % [label, field, op, expected, got])
	else:
		_record_fail(scenario_name,
			"entity_field %s.%s: expected %s %s, got %s"
			% [label, field, op, expected, got])


# ============================================================
# Query / field resolution
# ============================================================

func _query_entities(world: World, q: Dictionary) -> Array:
	var env: Dictionary = world.scheduler.env
	var entities: Dictionary = env.get("entities", {})
	var out: Array = []
	for id in entities:
		var e = entities[id]
		if e is Entity and QueryLib.matches(e, q, env):
			out.append(e)
	return out


func _resolve_field(e: Entity, path: String):
	# Dotted path: state.position.x, properties.speed, etc.
	var parts := path.split(".")
	var cur = e
	for p in parts:
		if cur is Entity:
			match p:
				"state":     cur = (cur as Entity).state
				"properties":cur = (cur as Entity).properties
				_:           return null
		elif cur is Dictionary:
			if not (cur as Dictionary).has(p):
				return null
			cur = (cur as Dictionary)[p]
		elif cur is Vector2:
			match p:
				"x": cur = (cur as Vector2).x
				"y": cur = (cur as Vector2).y
				_:   return null
		elif cur is Vector3:
			match p:
				"x": cur = (cur as Vector3).x
				"y": cur = (cur as Vector3).y
				"z": cur = (cur as Vector3).z
				_:   return null
		else:
			return null
	return cur


# ============================================================
# Helpers
# ============================================================

func _cmp(got, op: String, expected) -> bool:
	# Coerce to float when both sides are numeric.
	if got is int or got is float:
		var g := float(got)
		var x := float(expected)
		match op:
			"==": return g == x
			"!=": return g != x
			"<":  return g < x
			"<=": return g <= x
			">":  return g > x
			">=": return g >= x
	# Fallback string compare.
	match op:
		"==": return str(got) == str(expected)
		"!=": return str(got) != str(expected)
	return false


func _record_pass(msg: String) -> void:
	passed += 1
	if verbose:
		print("  ✓ %s" % msg)


func _record_fail(scenario_name: String, msg: String) -> void:
	failed += 1
	failures.append("%s — %s" % [scenario_name, msg])
	if verbose:
		print("  ✗ %s" % msg)


func _summarize_query(q: Dictionary) -> String:
	if q.has("tags_all"):
		return "tags=%s" % str(q["tags_all"])
	return str(q)


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var raw := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(raw) != OK:
		push_error("[scenario] JSON parse error in %s: %s" % [path, json.get_error_message()])
		return {}
	return json.data if json.data is Dictionary else {}


func _resolve_data_root() -> String:
	for arg in OS.get_cmdline_user_args():
		var s := str(arg)
		if s.begins_with("--game="):
			return "res://data/" + s.substr(7)
	return ""
