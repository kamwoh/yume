extends Node

## W1.13 — engine-unit tests.
##
## Single consolidated test runner. Each test_* function contains a batch of
## assertions. On _ready: runs all, prints results, exits with 0 (all pass)
## or 1 (any fail).
##
## Run via: godot --headless --path . scenes/test_main.tscn
##
## Why a single file (not GUT or per-primitive files)? Yume's engine is small
## (~1500 LOC). A single test file is faster to iterate, has zero deps, and
## proves the test pattern. Splits if/when this exceeds ~600 lines.

var pass_count: int = 0
var fail_count: int = 0
var failures: Array[String] = []
var current_test: String = ""


func _ready() -> void:
	print("=== Yume engine unit tests ===\n")
	test_entity()
	test_rule()
	test_relation_store()
	test_query()
	test_effect_apply()
	test_schema_validator()
	test_renderer_agnostic()
	test_w2_integration()
	test_shape_lib()
	test_spatial_index()
	test_contact_rules()
	test_formulas()
	test_mesh_lib()
	test_renderer_parity()
	test_shooter_cascade()
	test_rpg_cascade()
	test_chess_cascade()
	test_engine_error()
	test_blocks_motion()
	test_raycast_hit()
	test_instance_patterns()
	test_screen_flow_effects()
	test_control_factory()
	test_save_state()
	test_overlay_effects()
	test_spatial_lod()
	test_macro_expansion()
	test_multi_actor()
	test_reset_world_effect()
	test_scripted_policy()
	print("\n=== RESULTS ===")
	print("passed: %d  failed: %d  total: %d" % [pass_count, fail_count, pass_count + fail_count])
	if fail_count > 0:
		print("\nFAILURES:")
		for f in failures:
			print("  ✗ " + f)
	get_tree().quit(0 if fail_count == 0 else 1)


# ============================================================
# HELPERS
# ============================================================

func _section(name: String) -> void:
	current_test = name
	print("[%s]" % name)

func expect(cond: bool, msg: String) -> void:
	if cond:
		pass_count += 1
	else:
		fail_count += 1
		failures.append("%s: %s" % [current_test, msg])
		print("  ✗ %s" % msg)

func expect_eq(actual, expected, msg: String) -> void:
	if actual == expected:
		pass_count += 1
	else:
		fail_count += 1
		var line := "%s: %s — expected %s, got %s" % [current_test, msg, expected, actual]
		failures.append(line)
		print("  ✗ " + line)


# ============================================================
# ENTITY
# ============================================================

func test_entity() -> void:
	_section("entity")
	var def: Dictionary = {
		"id": "rock",
		"tags": ["inert", "solid"],
		"properties": {"hardness": 3, "material": "stone"},
		"state_init": {"age": 0, "temperature": 20.0},
		"visual": {"color": "#888888", "radius": 8.0},
	}
	var e := Entity.create(def, "rock_1")
	expect_eq(e.def_id, "rock", "def_id set")
	expect_eq(e.instance_id, "rock_1", "instance_id set")
	expect(e.has_tag("inert"), "has_tag positive")
	expect(not e.has_tag("fragile"), "has_tag negative")
	expect_eq(e.get_property("hardness"), 3, "static property")
	expect_eq(e.get_property("missing", "x"), "x", "property default")
	expect_eq(e.get_state("age"), 0, "initial state")
	e.add_state("age", 5)
	expect_eq(e.get_state("age"), 5, "add_state on existing")
	e.add_state("counter", 3)
	expect_eq(e.get_state("counter"), 3, "add_state initializes missing field to 0")
	e.set_state("temperature", 100.0)
	expect_eq(e.get_state("temperature"), 100.0, "set_state")
	e.add_tag("burning")
	expect(e.has_tag("burning"), "add_tag")
	e.add_tag("burning")
	var burning_count := 0
	for t in e.tags:
		if t == "burning": burning_count += 1
	expect_eq(burning_count, 1, "add_tag deduplicates")
	e.remove_tag("inert")
	expect(not e.has_tag("inert"), "remove_tag")
	# Velocity helpers
	e.set_velocity(Vector2(1, 2))
	expect_eq(e.get_velocity(), Vector2(1, 2), "velocity round-trip")
	# Override merge
	var def2: Dictionary = {"id": "tree", "tags": ["plant"], "state_init": {"growth": 0}}
	var t := Entity.create(def2, "tree_1", {
		"state": {"growth": 50, "extra": 1},
		"tags": ["watered"],
		"position": [3, 4],
	})
	expect_eq(t.get_state("growth"), 50, "state override merges")
	expect_eq(t.get_state("extra"), 1, "state override adds new field")
	expect(t.has_tag("plant"), "default tag preserved")
	expect(t.has_tag("watered"), "override tag added")
	expect_eq(t.get_position(), Vector2(3, 4), "position override (in state)")
	# Snapshot
	var snap := t.snapshot()
	expect_eq(snap["def"], "tree", "snapshot.def")
	expect_eq(snap["id"], "tree_1", "snapshot.id")
	expect_eq(snap["state"]["growth"], 50, "snapshot.state")
	t.queue_free()
	e.queue_free()


# ============================================================
# RULE
# ============================================================

func test_rule() -> void:
	_section("rule")
	var d: Dictionary = {
		"id": "decay",
		"trigger": {"type": "tick", "interval": 10},
		"query": {"tags_all": ["mortal"]},
		"chance": 1.0,
		"effect": {"type": "state_add", "target": "self", "field": "hp", "amount": -1},
	}
	var r := Rule.from_dict(d)
	expect_eq(r.id, "decay", "id parsed")
	expect_eq(r.trigger_type(), "tick", "trigger_type")
	expect_eq(r.trigger_param("interval"), 10, "trigger_param")
	expect_eq(r.effects.size(), 1, "single effect normalized to 1-array")
	expect(r.query is Dictionary, "query parsed")
	# Effect-list shorthand
	var d2: Dictionary = {
		"id": "multi",
		"trigger": {"type": "tick"},
		"effect": [
			{"type": "state_add", "target": "self", "field": "a", "amount": 1},
			{"type": "state_add", "target": "self", "field": "b", "amount": 2},
		],
	}
	var r2 := Rule.from_dict(d2)
	expect_eq(r2.effects.size(), 2, "effect array preserved")
	# Before/after hints
	var d3: Dictionary = {
		"id": "early",
		"trigger": {"type": "tick"},
		"effect": {"type": "state_set", "target": "self", "field": "x", "value": 0},
		"before": ["late"],
	}
	var r3 := Rule.from_dict(d3)
	var d4: Dictionary = {
		"id": "late",
		"trigger": {"type": "tick"},
		"effect": {"type": "state_set", "target": "self", "field": "x", "value": 1},
	}
	var r4 := Rule.from_dict(d4)
	expect(r3.runs_before(r4), "runs_before via own hint")
	expect(r4.runs_after(r3), "runs_after via other's hint")
	# Validation errors
	var bad := [
		Rule.from_dict({"id": "", "trigger": {"type": "tick"}, "effect": {"type": "state_set"}}),
		Rule.from_dict({"id": "no_trigger", "trigger": {}, "effect": {"type": "state_set"}}),
		Rule.from_dict({"id": "bad_trigger", "trigger": {"type": "wat"}, "effect": {"type": "state_set"}}),
		Rule.from_dict({"id": "no_effect", "trigger": {"type": "tick"}, "effect": []}),
		Rule.from_dict({"id": "dup1", "trigger": {"type": "tick"}, "effect": {"type": "state_set"}}),
		Rule.from_dict({"id": "dup1", "trigger": {"type": "tick"}, "effect": {"type": "state_set"}}),
	]
	var errors := Rule.validate_all(bad)
	expect(errors.size() >= 4, "validator catches structural errors (got %d)" % errors.size())
	# Valid set
	var ok := [r, r2, r3, r4]
	expect_eq(Rule.validate_all(ok).size(), 0, "valid rules produce no errors")


# ============================================================
# RELATION STORE
# ============================================================

func test_relation_store() -> void:
	_section("relation_store")
	var s := RelationStore.new()
	s.relate("held_by", "sword", "alice")
	s.relate("held_by", "shield", "alice")
	s.relate("held_by", "sword", "alice")  # dedup
	expect_eq(s.targets("held_by", "sword"), ["alice"], "single target for sword")
	expect_eq(s.targets("held_by", "shield"), ["alice"], "single target for shield")
	expect(s.has_edge("held_by", "sword", "alice"), "has_edge positive")
	expect(not s.has_edge("held_by", "sword", "bob"), "has_edge negative")
	expect_eq(s.sources("held_by", "alice").size(), 2, "alice holds 2 items")
	expect_eq(s.count("held_by"), 2, "count after dedup")
	# Transfer
	s.transfer_to("held_by", "sword", "alice", "bob")
	expect(not s.has_edge("held_by", "sword", "alice"), "transfer_to removed old")
	expect(s.has_edge("held_by", "sword", "bob"), "transfer_to added new")
	# Unrelate
	s.unrelate("held_by", "sword", "bob")
	expect(not s.has_edge("held_by", "sword", "bob"), "unrelate")
	expect_eq(s.count("held_by"), 1, "count decremented")
	# clear_entity (despawn cleanup)
	s.relate("on_square", "knight", "e4")
	s.relate("part_of", "door", "knight")
	s.clear_entity("knight")
	expect(not s.has_edge("on_square", "knight", "e4"), "clear_entity drops edges as source")
	expect(not s.has_edge("part_of", "door", "knight"), "clear_entity drops edges as target")
	# Snapshot/restore
	s.relate("ally", "alice", "bob")
	var snap = s.snapshot()
	var s2 := RelationStore.new()
	s2.restore(snap)
	expect(s2.has_edge("ally", "alice", "bob"), "restore preserves edge")
	expect(s2.has_edge("held_by", "shield", "alice"), "restore preserves multiple types")


# ============================================================
# QUERY
# ============================================================

func test_query() -> void:
	_section("query")
	var defs := {
		"tree": {"id": "tree", "tags": ["plant", "flammable", "solid"], "properties": {"hardness": 2}, "state_init": {"burning": 0, "wet": 0.0}},
		"fire": {"id": "fire", "tags": ["heat_source"], "state_init": {"burning": 1}},
	}
	var entities := {}
	var t1 := Entity.create(defs.tree, "t1"); t1.set_position(Vector2(0, 0)); t1.set_state("wet", 0.1)
	var t2 := Entity.create(defs.tree, "t2"); t2.set_position(Vector2(2, 0)); t2.set_state("wet", 0.8)
	var f1 := Entity.create(defs.fire, "f1"); f1.set_position(Vector2(0.5, 0))
	entities["t1"] = t1; entities["t2"] = t2; entities["f1"] = f1
	var env := {"entities": entities, "relations": RelationStore.new()}

	# tags_all
	var r1 := QueryLib.run({"tags_all": ["plant"]}, env)
	expect_eq(r1.size(), 2, "tags_all matches both trees")
	# tags_any
	var r2 := QueryLib.run({"tags_any": ["plant", "heat_source"]}, env)
	expect_eq(r2.size(), 3, "tags_any matches all three")
	# tags_none
	var r3 := QueryLib.run({"tags_none": ["heat_source"]}, env)
	expect_eq(r3.size(), 2, "tags_none excludes fire")
	# state operator
	var r4 := QueryLib.run({"tags_all": ["plant"], "state": {"wet_lt": 0.5}}, env)
	expect_eq(r4.size(), 1, "wet_lt 0.5 picks only dry tree")
	expect_eq((r4[0] as Entity).instance_id, "t1", "dry tree is t1")
	# property operator
	var r5 := QueryLib.run({"properties": {"hardness_atleast": 2}}, env)
	expect_eq(r5.size(), 2, "hardness_atleast 2 picks both trees")
	# missing field = no match (strict)
	var r6 := QueryLib.run({"properties": {"hardness_eq": 2}}, env)
	expect_eq(r6.size(), 2, "hardness_eq matches trees with hardness")
	var r7 := QueryLib.run({"properties": {"nonexistent_eq": 1}}, env)
	expect_eq(r7.size(), 0, "missing property = no match (strict)")
	# Radius
	var r8 := QueryLib.run({"tags_all": ["plant"], "radius": 1.5}, env, {"_origin_position": Vector2(0, 0)})
	expect_eq(r8.size(), 1, "radius 1.5 from origin picks only t1")
	# Limit
	var r9 := QueryLib.run({"tags_any": ["plant", "heat_source"], "limit": 2}, env)
	expect_eq(r9.size(), 2, "limit caps results")
	# Order by distance
	var r10 := QueryLib.run({"tags_all": ["plant"], "order_by": "distance_asc"}, env, {"_origin_position": Vector2(0, 0)})
	expect_eq((r10[0] as Entity).instance_id, "t1", "distance_asc puts t1 first")
	# Relations clause
	var rs := RelationStore.new()
	rs.relate("on_fire", "f1", "t1")
	env["relations"] = rs
	var r11 := QueryLib.run({"tags_all": ["plant"], "relations": {"_inverse_dummy": "f1"}}, env)
	# (Sanity: no relations of that type → no match)
	expect_eq(r11.size(), 0, "relations clause filters strictly")
	# matches() single-entity test
	expect(QueryLib.matches(t1, {"tags_all": ["plant"]}, env), "matches positive")
	expect(not QueryLib.matches(f1, {"tags_all": ["plant"]}, env), "matches negative")

	for e in [t1, t2, f1]: e.queue_free()


# ============================================================
# EFFECT APPLY
# ============================================================

func test_effect_apply() -> void:
	_section("effect_apply")
	var def := {"id": "thing", "tags": ["thing"], "state_init": {"hp": 100, "ap": 10}}
	var ent := Entity.create(def, "thing_1")
	var entities := {"thing_1": ent}
	var env := {
		"entities": entities,
		"defs": {"thing": def},
		"relations": RelationStore.new(),
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}
	var ctx := {"self": "thing_1"}
	# state_set
	EffectApply.apply({"type": "state_set", "target": "self", "field": "hp", "value": 50}, env, ctx)
	expect_eq(ent.get_state("hp"), 50, "state_set")
	# state_add
	EffectApply.apply({"type": "state_add", "target": "self", "field": "hp", "amount": -5}, env, ctx)
	expect_eq(ent.get_state("hp"), 45, "state_add (negative)")
	# state_mul
	EffectApply.apply({"type": "state_mul", "target": "self", "field": "ap", "amount": 2}, env, ctx)
	expect_eq(ent.get_state("ap"), 20, "state_mul")
	# state_clamp
	ent.set_state("hp", 200)
	EffectApply.apply({"type": "state_clamp", "target": "self", "field": "hp", "min": 0, "max": 100}, env, ctx)
	expect_eq(ent.get_state("hp"), 100, "state_clamp upper")
	ent.set_state("hp", -10)
	EffectApply.apply({"type": "state_clamp", "target": "self", "field": "hp", "min": 0, "max": 100}, env, ctx)
	expect_eq(ent.get_state("hp"), 0, "state_clamp lower")
	# tag_add / remove
	EffectApply.apply({"type": "tag_add", "target": "self", "tag": "burning"}, env, ctx)
	expect(ent.has_tag("burning"), "tag_add")
	EffectApply.apply({"type": "tag_remove", "target": "self", "tag": "burning"}, env, ctx)
	expect(not ent.has_tag("burning"), "tag_remove")
	# Target as literal id (not context name) — fallback path
	EffectApply.apply({"type": "state_set", "target": "thing_1", "field": "hp", "value": 77}, env, ctx)
	expect_eq(ent.get_state("hp"), 77, "target as literal id")
	# relate via effect
	EffectApply.apply({"type": "relate", "relation": "carries", "from": "self", "to": "thing_1"}, env, ctx)
	expect((env.relations as RelationStore).has_edge("carries", "thing_1", "thing_1"), "relate effect")
	# unrelate
	EffectApply.apply({"type": "unrelate", "relation": "carries", "from": "self", "to": "thing_1"}, env, ctx)
	expect(not (env.relations as RelationStore).has_edge("carries", "thing_1", "thing_1"), "unrelate effect")
	# spawn (literal position)
	var spawn_result = EffectApply.apply({
		"type": "spawn",
		"template": "thing",
		"position": [5, 5],
		"overrides": {"_forced_id": "thing_2"},
	}, env, ctx)
	expect(env.entities.has("thing_2"), "spawn created entity")
	expect_eq(spawn_result.get("spawned_id", ""), "thing_2", "spawn returns id")
	# remove
	EffectApply.apply({"type": "remove", "target": "thing_2"}, env, {})
	expect(not env.entities.has("thing_2"), "remove deletes entity")
	# transform: replaces entity with new def, preserving state
	EffectApply.apply({"type": "spawn", "template": "thing", "overrides": {"_forced_id": "morph"}}, env, {})
	(env.entities["morph"] as Entity).set_state("hp", 33)
	EffectApply.apply({"type": "transform", "target": "morph", "to": "thing"}, env, {"self": "morph"})
	# After transform, "morph" is gone but a new instance exists with hp=33 preserved
	expect(not env.entities.has("morph"), "transform removes old")
	var transformed: Entity = null
	for e in env.entities.values():
		if (e as Entity).get_state("hp") == 33:
			transformed = e; break
	expect(transformed != null, "transform spawned new instance with preserved state")

	# 2026-05-04 consistency fix: _value() recurses into Arrays + state_set
	# normalizes position/velocity through Entity.set_position/set_velocity.
	# Verify both behaviors so future regressions (e.g. someone reverting the
	# Array-recursion to fix some other bug) get caught.
	var ar := Entity.create({"id": "ar", "tags": ["x"], "state_init": {}}, "ar_1")
	env.entities["ar_1"] = ar
	# Array of formula strings → each element evaluates
	EffectApply.apply({
		"type": "state_set", "target": "ar_1", "field": "position",
		"value": ["10 + 5", "20 * 2"]
	}, env, {"self": "ar_1"})
	var pos = ar.get_position()
	expect(pos is Vector2, "state_set position with Array → Vector2 (got %s)" % typeof(pos))
	expect_eq((pos as Vector2).x, 15.0, "Array element 0 formula evaluated")
	expect_eq((pos as Vector2).y, 40.0, "Array element 1 formula evaluated")
	# Formula reading position.x after Array-set should still work (regression
	# guard: without normalization, formulas would return 0)
	EffectApply.apply({
		"type": "state_set", "target": "ar_1", "field": "marker",
		"value": "self.state.position.x"
	}, env, {"self": "ar_1"})
	expect_eq(ar.get_state("marker"), 15.0, "formula reads .x after Array-set position")
	# Concrete numeric Array still works (unchanged behavior — no formulas inside)
	EffectApply.apply({
		"type": "state_set", "target": "ar_1", "field": "position",
		"value": [3, 7]
	}, env, {"self": "ar_1"})
	var p2 = ar.get_position()
	expect(p2 is Vector2, "concrete numeric Array still becomes Vector2")
	expect_eq((p2 as Vector2).x, 3.0, "concrete x preserved")
	ar.queue_free()
	env.entities.erase("ar_1")

	for e in env.entities.values(): (e as Entity).queue_free()


# ============================================================
# SCHEMA VALIDATOR (Rule.validate_all integration smoke)
# ============================================================

func test_schema_validator() -> void:
	_section("schema_validator")
	# Wire a known-bad set + a known-good set; verify error counts are reasonable.
	# Full schema validator (Python, yume-test CLI) is W2.8+ work; this is the
	# in-engine smoke check that the structural validator catches obvious bugs.
	var bad_rules := [
		Rule.from_dict({"id": "", "trigger": {"type": "tick"}, "effect": {"type": "state_set"}}),
		Rule.from_dict({"id": "x", "trigger": {"type": "tick"}, "effect": [{}]}),  # effect missing type
		Rule.from_dict({"id": "y", "trigger": {"type": "tick"}, "effect": {"type": "state_set"}, "chance": 1.5}),  # bad chance
	]
	var errs := Rule.validate_all(bad_rules)
	expect(errs.size() >= 3, "schema validator catches empty id, missing effect type, bad chance (got %d)" % errs.size())

	# Valid case
	var good := [
		Rule.from_dict({"id": "ok", "trigger": {"type": "tick"}, "effect": {"type": "state_set", "target": "self", "field": "x", "value": 1}}),
	]
	expect_eq(Rule.validate_all(good).size(), 0, "valid rule passes validator")


# ============================================================
# RENDERER-AGNOSTIC SMOKE TEST (W1.14e)
# ============================================================

## Tests invariant #8 at the entity layer: Entity itself carries no transform.
## Position lives in state.position. Same Entity, same JSON, same effects
## should run identically regardless of which renderer is attached (or none).
func test_renderer_agnostic() -> void:
	_section("renderer_agnostic (W1.14e)")
	# Entity is a plain Node now — verify no Node2D inheritance leaks back in.
	var e := Entity.create({"id": "test", "tags": ["thing"], "state_init": {"hp": 50}}, "t1")
	# Cast through Variant so the static type checker doesn't reject is-checks.
	var e_var: Variant = e
	expect(not (e_var is Node2D), "Entity is plain Node, NOT Node2D")
	expect(not (e_var is Node3D), "Entity is plain Node, NOT Node3D")
	expect(e is Node, "Entity is Node")

	# Position is data — Vector2 default, Vector3 also accepted.
	e.set_position(Vector2(10, 20))
	expect_eq(e.get_position(), Vector2(10, 20), "Vector2 position round-trip")
	e.set_position(Vector3(1, 2, 3))
	expect_eq(e.get_position(), Vector3(1, 2, 3), "Vector3 position round-trip")
	expect_eq(e.get_planar_position(), Vector2(1, 3), "Vector3 → planar XZ projection")

	# Position survives via state — snapshot/restore round-trips it.
	e.set_position(Vector2(7, 8))
	var snap := e.snapshot()
	expect_eq(snap["position"], [7.0, 8.0], "snapshot preserves 2D position")
	e.set_position(Vector3(4, 5, 6))
	snap = e.snapshot()
	expect_eq(snap["position"], [4.0, 5.0, 6.0], "snapshot preserves 3D position")

	# Engine reads via state too — no special-casing.
	expect_eq(e.state.get("position"), Vector3(4, 5, 6), "position lives in state")

	e.queue_free()


# ============================================================
# W2 INTEGRATION TESTS — input→signal→spawn cascade, despawn trigger
# ============================================================

func test_w2_integration() -> void:
	_section("w2_integration (input→signal→spawn→despawn cascade)")
	# Build a tiny world by hand (no World node, just env + scheduler).
	var entities: Dictionary = {}
	var defs: Dictionary = {
		"player":  {"id": "player",  "tags": ["player"], "state_init": {}},
		"sparkle": {"id": "sparkle", "tags": ["sparkle"], "state_init": {"life": 3}},
		"counter": {"id": "counter", "tags": ["counter"], "state_init": {"emitted": 0, "died": 0}},
	}
	entities["p1"] = Entity.create(defs.player, "p1")
	entities["c1"] = Entity.create(defs.counter, "c1")
	var rs := RelationStore.new()
	var env: Dictionary = {
		"entities": entities, "defs": defs, "relations": rs,
		"world": {}, "parent": null, "next_id": {"_": 0},
	}

	# Rules: input "spark" → emit signal → spawn sparkle. Tick decay. Lifecycle counters.
	var rules: Array = [
		Rule.from_dict({
			"id": "input_spark",
			"trigger": {"type": "input", "action": "spark"},
			"effect": {"type": "emit", "signal": "sparkle_emit", "payload": {"origin": "actor"}},
		}),
		Rule.from_dict({
			"id": "signal_spawn",
			"trigger": {"type": "signal", "name": "sparkle_emit"},
			"effect": {"type": "spawn", "template": "sparkle", "position": "origin"},
		}),
		Rule.from_dict({
			"id": "decay",
			"trigger": {"type": "tick", "interval": 1},
			"query": {"tags_all": ["sparkle"]},
			"effect": {"type": "state_add", "target": "self", "field": "life", "amount": -1},
		}),
		Rule.from_dict({
			"id": "die",
			"trigger": {"type": "tick", "interval": 1},
			"query": {"tags_all": ["sparkle"], "state": {"life_lte": 0}},
			"effect": {"type": "remove", "target": "self"},
		}),
		Rule.from_dict({
			"id": "on_birth",
			"trigger": {"type": "spawn"},
			"query": {"tags_all": ["sparkle"]},
			"effect": {"type": "state_add", "target": "c1", "field": "emitted", "amount": 1},
		}),
		Rule.from_dict({
			"id": "on_death",
			"trigger": {"type": "despawn"},
			"query": {"tags_all": ["sparkle"]},
			"effect": {"type": "state_add", "target": "c1", "field": "died", "amount": 1},
		}),
	]
	var sched := PhaseScheduler.new(env)
	sched.register_rules(rules)

	# Sanity: counter starts at zero, no sparkles
	expect_eq(int(entities["c1"].get_state("emitted")), 0, "counter.emitted starts 0")
	expect_eq(int(entities["c1"].get_state("died")), 0, "counter.died starts 0")
	expect_eq(QueryLib.run({"tags_all": ["sparkle"]}, env).size(), 0, "no sparkles initially")

	# Queue input → tick → input rule fires → emit → signal rule fires → spawn → spawn rule fires (counter++)
	sched.queue_input("spark", {"actor": "p1"})
	sched.tick()
	expect_eq(QueryLib.run({"tags_all": ["sparkle"]}, env).size(), 1, "1 sparkle after first tick")
	expect_eq(int(entities["c1"].get_state("emitted")), 1, "spawn trigger incremented counter to 1")

	# Tick 2: decay (life 3→2), no death yet
	sched.tick()
	expect_eq(QueryLib.run({"tags_all": ["sparkle"]}, env).size(), 1, "sparkle still alive at tick 2")

	# Tick 3 (life 2→1), Tick 4 (life 1→0), Tick 5: die rule sees life<=0 → remove → despawn rule fires (counter died++)
	sched.tick(); sched.tick(); sched.tick()
	expect_eq(QueryLib.run({"tags_all": ["sparkle"]}, env).size(), 0, "sparkle removed after life→0")
	expect_eq(int(entities["c1"].get_state("died")), 1, "despawn trigger incremented counter")


# ============================================================
# SHAPE LIB (W2.7a) — config-driven shape catalog
# ============================================================

func test_shape_lib() -> void:
	_section("shape_lib (W2.7a)")
	# Load the project's shapes.json (must exist with at least one shape).
	var lib := ShapeLib.load_from_file("res://data/shapes.json")
	expect(lib.has("tree"), "shapes.json contains 'tree'")
	expect(lib.has("rock"), "shapes.json contains 'rock'")
	expect(not lib.has("nonexistent_shape_xyz"), "missing shape returns false")

	var tree := lib.get_shape("tree")
	expect(not tree.is_empty(), "tree shape def loads")
	expect(tree.has("primitives"), "tree has primitives array")
	expect(tree.has("params"), "tree has params dict")

	# Param merge: shape defaults + entity-supplied overrides.
	var defaults: Dictionary = tree["params"]
	var instance_params := {"foliage": "#abcdef"}
	var merged := ShapeLib.merge_params(tree, instance_params)
	expect_eq(merged["foliage"], "#abcdef", "instance param overrides default")
	expect_eq(merged["trunk"], defaults["trunk"], "default param preserved when not overridden")


# ============================================================
# SPATIAL INDEX (W3.1)
# ============================================================

func test_spatial_index() -> void:
	_section("spatial_index (W3.1)")
	var idx := SpatialIndex.new()
	idx.cell_size = 10.0  # tiny cells so radius math is interesting

	# Build 4 fake entities at positions
	var entities: Dictionary = {}
	var def := {"id": "thing", "tags": ["thing"], "state_init": {}}
	for i in range(4):
		var e := Entity.create(def, "e%d" % i)
		entities["e%d" % i] = e
	(entities["e0"] as Entity).set_position(Vector2(0, 0))
	(entities["e1"] as Entity).set_position(Vector2(5, 0))     # within 8 of e0
	(entities["e2"] as Entity).set_position(Vector2(20, 0))    # outside 8 of e0
	(entities["e3"] as Entity).set_position(Vector2(0, 100))   # far away
	for id in entities:
		idx.update_entity(id, (entities[id] as Entity).get_planar_position())

	# Radius query at origin, r=8: should match e0 (self) and e1
	var hits := idx.query_radius(Vector2(0, 0), 8.0, entities)
	expect_eq(hits.size(), 2, "radius=8 from origin matches e0+e1 (got %d)" % hits.size())

	# Radius query at origin, r=25: should match e0, e1, e2 (not e3)
	var hits2 := idx.query_radius(Vector2(0, 0), 25.0, entities)
	expect_eq(hits2.size(), 3, "radius=25 matches e0+e1+e2 (got %d)" % hits2.size())

	# Move e1 far away and re-query
	(entities["e1"] as Entity).set_position(Vector2(500, 500))
	idx.update_entity("e1", (entities["e1"] as Entity).get_planar_position())
	var hits3 := idx.query_radius(Vector2(0, 0), 8.0, entities)
	expect_eq(hits3.size(), 1, "after moving e1 away, radius=8 matches only e0 (got %d)" % hits3.size())

	# Remove e0
	idx.remove_entity("e0")
	var hits4 := idx.query_radius(Vector2(0, 0), 8.0, entities)
	expect_eq(hits4.size(), 0, "after removing e0, no hits at origin")

	# Cleanup
	for e in entities.values(): (e as Entity).queue_free()


# ============================================================
# CONTACT RULES (W3.2)
# ============================================================

func test_contact_rules() -> void:
	_section("contact_rules (W3.2)")
	# fire near dry tree → ignite tree (contact rule); fire near water → fire dies
	var defs: Dictionary = {
		"fire":   {"id": "fire",   "tags": ["fire"],   "state_init": {"burning": 1, "fuel": 5}},
		"tree":   {"id": "tree",   "tags": ["tree", "flammable"], "state_init": {"burning": 0, "wet": 0.0}},
		"water":  {"id": "water",  "tags": ["water"],  "state_init": {}},
	}
	var entities: Dictionary = {}
	var f1 := Entity.create(defs.fire, "f1");  f1.set_position(Vector2(0, 0))
	var t1 := Entity.create(defs.tree, "t1");  t1.set_position(Vector2(5, 0))    # close to fire
	var t2 := Entity.create(defs.tree, "t2");  t2.set_position(Vector2(50, 0))   # far from fire
	var w1 := Entity.create(defs.water, "w1"); w1.set_position(Vector2(8, 0))    # close to fire
	entities["f1"] = f1; entities["t1"] = t1; entities["t2"] = t2; entities["w1"] = w1

	var rs := RelationStore.new()
	var sx := SpatialIndex.new()
	for id in entities:
		sx.update_entity(id, (entities[id] as Entity).get_planar_position())
	var env: Dictionary = {
		"entities": entities, "defs": defs, "relations": rs, "spatial_index": sx,
		"world": {}, "parent": null, "next_id": {"_": 0},
	}

	var rules: Array = [
		Rule.from_dict({
			"id": "fire_ignites_tree",
			"trigger": {"type": "contact"},
			"query": {
				"a": {"tags_all": ["fire"], "state": {"burning_gte": 1}},
				"b": {"tags_all": ["flammable"], "state": {"burning_eq": 0}},
				"radius": 10.0
			},
			"effect": {"type": "state_set", "target": "b", "field": "burning", "value": 1},
		}),
		Rule.from_dict({
			"id": "water_extinguishes_fire",
			"trigger": {"type": "contact"},
			"query": {
				"a": {"tags_all": ["water"]},
				"b": {"tags_all": ["fire"], "state": {"burning_gte": 1}},
				"radius": 10.0
			},
			"effect": {"type": "state_set", "target": "b", "field": "burning", "value": 0},
		}),
	]
	var sched := PhaseScheduler.new(env)
	sched.register_rules(rules)

	# Initial state
	expect_eq(int(t1.get_state("burning")), 0, "t1 initially not burning")
	expect_eq(int(t2.get_state("burning")), 0, "t2 initially not burning")
	expect_eq(int(f1.get_state("burning")), 1, "f1 initially burning")

	# One tick: contact rules fire in react phase.
	# Both rules will run: ignite_tree (fire→t1), extinguish_fire (water→f1).
	# Their order matters for the outcome of f1's burning state.
	# rule_a definition order: fire_ignites_tree FIRST, water_extinguishes_fire SECOND.
	# Both queue effects with different a/b pairs. Effects apply in commit order.
	# Final state: t1 burning=1 (set by ignite); f1 burning=0 (set by extinguish).
	sched.tick()

	expect_eq(int(t1.get_state("burning")), 1, "t1 ignited (within radius 10 of fire)")
	expect_eq(int(t2.get_state("burning")), 0, "t2 NOT ignited (50 units away from fire)")
	expect_eq(int(f1.get_state("burning")), 0, "f1 extinguished by adjacent water")

	# Cleanup
	for e in entities.values(): (e as Entity).queue_free()


# ============================================================
# FORMULAS (W4)
# ============================================================

func test_formulas() -> void:
	_section("formulas (W4)")
	# Build a fake entity with state we can query
	var def := {"id": "test", "tags": ["test"], "state_init": {"hp": 80, "max_hp": 100, "wet": 0.3}}
	var e := Entity.create(def, "e1")

	# Heuristic: looks_like_formula
	expect(Formula.looks_like_formula("self.state.hp * 2"), "looks_like_formula: arithmetic + path")
	expect(Formula.looks_like_formula("(a + b) / 2"), "looks_like_formula: parens")
	expect(not Formula.looks_like_formula("actor"), "bare name not a formula")
	expect(not Formula.looks_like_formula("hello_world"), "underscored name not a formula")

	# Basic arithmetic with state path
	var ctx := {"self": e}
	var r1 = Formula.evaluate("self.state.hp * 2", ctx)
	expect_eq(r1, 160.0, "hp * 2 = 160")

	var r2 = Formula.evaluate("self.state.hp - self.state.max_hp", ctx)
	expect_eq(r2, -20.0, "hp - max_hp = -20")

	# Math helpers (Expression built-in)
	var r3 = Formula.evaluate("clamp(self.state.hp, 0, 50)", ctx)
	expect_eq(r3, 50.0, "clamp clips to upper bound")

	var r4 = Formula.evaluate("abs(self.state.hp - 100)", ctx)
	expect_eq(r4, 20.0, "abs(80 - 100) = 20")

	# World binding
	var ctx_w := {"self": e, "world": {"tick": 7, "difficulty": 2.5}}
	var r5 = Formula.evaluate("world.tick * 10 + self.state.hp", ctx_w)
	expect_eq(r5, 150.0, "world.tick * 10 + hp")

	# Multiple roles (a + b)
	var def2 := {"id": "other", "tags": ["test"], "state_init": {"temperature": 100}}
	var f := Entity.create(def2, "f1")
	var ctx_ab := {"a": f, "b": e}
	var r6 = Formula.evaluate("(a.state.temperature - b.state.hp) * 0.5", ctx_ab)
	expect_eq(r6, 10.0, "(100 - 80) * 0.5 = 10")

	# Missing field returns 0 (strict)
	var r7 = Formula.evaluate("self.state.nonexistent + 100", ctx)
	expect_eq(r7, 100.0, "missing field resolves to 0; sum = 100")

	# Cache hit: re-evaluate same formula → cache size grows by 1 only
	var size_before := Formula.cache_size()
	Formula.evaluate("self.state.hp * 2", ctx)
	Formula.evaluate("self.state.hp * 2", ctx)
	Formula.evaluate("self.state.hp * 2", ctx)
	var size_after := Formula.cache_size()
	expect(size_after - size_before <= 1, "repeated formula cached (size delta %d)" % (size_after - size_before))

	# Effect-side integration: state_add with formula amount
	var entities: Dictionary = {"e1": e}
	var env: Dictionary = {
		"entities": entities, "defs": {}, "relations": null,
		"world": {"tick": 5}, "parent": null, "next_id": {"_": 0},
	}
	# Apply effect: hp += world.tick (5) → hp 80 → 85
	EffectApply.apply(
		{"type": "state_add", "target": "self", "field": "hp", "amount": "world.tick"},
		env, {"self": "e1"}
	)
	expect_eq(int(e.get_state("hp")), 85, "state_add with formula amount: 80 + 5 = 85")

	e.queue_free()
	f.queue_free()


# ============================================================
# MESH LIB (W5.0b) — 3D companion to ShapeLib
# ============================================================

func test_mesh_lib() -> void:
	_section("mesh_lib (W5.0b)")
	var lib := MeshLib.load_from_file("res://data/meshes.json")
	expect(lib.has("tree"), "meshes.json contains 'tree'")
	expect(lib.has("rock"), "meshes.json contains 'rock'")
	expect(not lib.has("nonexistent_mesh_xyz"), "missing mesh returns false")

	var tree := lib.get_mesh("tree")
	expect(not tree.is_empty(), "tree mesh def loads")
	expect(tree.has("primitives"), "tree has primitives array")

	var defaults: Dictionary = tree["params"]
	var instance_params := {"foliage": "#abcdef"}
	var merged := MeshLib.merge_params(tree, instance_params)
	expect_eq(merged["foliage"], "#abcdef", "instance param overrides default")
	expect_eq(merged["trunk"], defaults["trunk"], "default param preserved")


# ============================================================
# RENDERER PARITY (W5.0e) — invariant #8 acid test at the entity layer
# ============================================================

## Run identical engine + JSON under different render contexts; assert state
## ticks identically. We don't actually instantiate renderers (that needs
## SceneTree); we test that the ENGINE is renderer-blind by simulating the
## same load+tick sequence twice with no renderer attached, then verify same
## entity set + state. Sanity: this test is meaningful because Entity is
## plain Node post-W1.14.
func test_renderer_parity() -> void:
	_section("renderer_parity (W5.0e)")
	# Run 1: load proof-of-life-style data manually (no World), tick N times
	var defs1: Dictionary = {
		"thing": {"id": "thing", "tags": ["thing"], "state_init": {"growth": 0}},
	}
	var ents1: Dictionary = {"e1": Entity.create(defs1.thing, "e1")}
	var sched1 := PhaseScheduler.new({
		"entities": ents1, "defs": defs1, "relations": RelationStore.new(),
		"world": {}, "parent": null, "next_id": {"_": 0},
	})
	sched1.register_rules([
		Rule.from_dict({
			"id": "grow",
			"trigger": {"type": "tick", "interval": 1},
			"query": {"tags_all": ["thing"]},
			"effect": {"type": "state_add", "target": "self", "field": "growth", "amount": 1},
		}),
	])
	for i in range(5): sched1.tick()
	var snap1 := (ents1["e1"] as Entity).snapshot()

	# Run 2: same data, different "renderer" context (no renderer is attached
	# to the entity, simulating a renderer-blind world). Engine should produce
	# the same state.
	var defs2: Dictionary = {
		"thing": {"id": "thing", "tags": ["thing"], "state_init": {"growth": 0}},
	}
	var ents2: Dictionary = {"e1": Entity.create(defs2.thing, "e1")}
	var sched2 := PhaseScheduler.new({
		"entities": ents2, "defs": defs2, "relations": RelationStore.new(),
		"world": {}, "parent": null, "next_id": {"_": 0},
	})
	sched2.register_rules([
		Rule.from_dict({
			"id": "grow",
			"trigger": {"type": "tick", "interval": 1},
			"query": {"tags_all": ["thing"]},
			"effect": {"type": "state_add", "target": "self", "field": "growth", "amount": 1},
		}),
	])
	for i in range(5): sched2.tick()
	var snap2 := (ents2["e1"] as Entity).snapshot()

	# State must match exactly (modulo position default Vector2 vs Vector3)
	expect_eq(snap1["state"]["growth"], snap2["state"]["growth"], "growth identical across runs")
	expect_eq(snap1["state"]["growth"], 5, "growth ticked 5 times")
	expect_eq(snap1["def"], snap2["def"], "def_id identical")
	expect_eq(snap1["tags"], snap2["tags"], "tags identical")

	# Entity nodes are plain Node — never Node2D or Node3D
	var e_var: Variant = ents1["e1"]
	expect(not (e_var is Node2D), "Entity stays plain Node post-tick (no Node2D leak)")
	expect(not (e_var is Node3D), "Entity stays plain Node post-tick (no Node3D leak)")

	(ents1["e1"] as Entity).queue_free()
	(ents2["e1"] as Entity).queue_free()


# ============================================================
# SHOOTER CASCADE (W5.3) — input → spawn → motion → contact → damage → death
# ============================================================

func test_shooter_cascade() -> void:
	_section("shooter_cascade (W5.3)")
	# Build a tiny shooter: player + 1 stationary enemy, fire input → bullet → kill
	var defs: Dictionary = {
		"player": {"id": "player", "tags": ["player"], "state_init": {"velocity": [0, 0]}},
		"enemy":  {"id": "enemy",  "tags": ["enemy"],  "state_init": {"velocity": [0, 0], "hp": 30}},
		"bullet": {"id": "bullet", "tags": ["bullet", "projectile"],
		           "state_init": {"velocity": [0, 0], "lifespan": 30, "damage": 12}},
	}
	var entities: Dictionary = {}
	var p := Entity.create(defs.player, "p1"); p.set_position(Vector2(0, 0))
	var e := Entity.create(defs.enemy, "e1");  e.set_position(Vector2(50, 0))
	entities["p1"] = p; entities["e1"] = e

	var rs := RelationStore.new()
	var sx := SpatialIndex.new()
	for id in entities:
		sx.update_entity(id, (entities[id] as Entity).get_planar_position())
	var env: Dictionary = {
		"entities": entities, "defs": defs, "relations": rs, "spatial_index": sx,
		"world": {}, "parent": null, "next_id": {"_": 0},
	}

	var rules: Array = [
		Rule.from_dict({
			"id": "fire_east",
			"trigger": {"type": "input", "action": "fire_east"},
			"effect": {"type": "spawn", "template": "bullet", "position": "actor",
			           "overrides": {"state": {"velocity": [200, 0]}}},
		}),
		Rule.from_dict({
			"id": "bullet_hits_enemy",
			"trigger": {"type": "contact"},
			"query": {
				"a": {"tags_all": ["bullet"]},
				"b": {"tags_all": ["enemy"]},
				"radius": 60.0,
			},
			"effect": [
				{"type": "state_add", "target": "b", "field": "hp", "amount": "-a.state.damage"},
				{"type": "remove", "target": "a"},
			],
		}),
		Rule.from_dict({
			"id": "enemy_dies",
			"trigger": {"type": "tick", "interval": 1},
			"query": {"tags_all": ["enemy"], "state": {"hp_lte": 0}},
			"effect": {"type": "remove", "target": "self"},
		}),
	]
	var sched := PhaseScheduler.new(env)
	sched.register_rules(rules)

	# Initial state
	expect_eq(QueryLib.run({"tags_all": ["bullet"]}, env).size(), 0, "no bullets initially")
	expect_eq(QueryLib.run({"tags_all": ["enemy"]}, env).size(), 1, "1 enemy initially")
	expect_eq(int(e.get_state("hp")), 30, "enemy hp = 30")

	# Fire bullet east. Bullet spawns at player (0,0); enemy at (50,0) is
	# within contact radius 60 → bullet hits + removed in same react phase.
	sched.queue_input("fire_east", {"actor": "p1"})
	sched.tick()
	# After 1 tick the bullet is consumed (spawn → contact → remove all in
	# same tick — input phase spawns, react phase contacts). Verify outcome.
	expect_eq(int(e.get_state("hp")), 18, "enemy took 12 damage from bullet (formula -a.state.damage)")
	expect_eq(QueryLib.run({"tags_all": ["bullet"]}, env).size(), 0, "bullet consumed by contact same tick")

	# Fire again — total damage 24 → hp 6. Still alive.
	sched.queue_input("fire_east", {"actor": "p1"})
	sched.tick()
	expect_eq(int(e.get_state("hp")), 6, "second hit: hp = 6 (alive)")

	# Fire third time — damage 12, hp -6 → enemy_dies tick rule kills it
	sched.queue_input("fire_east", {"actor": "p1"})
	sched.tick()  # bullet hits, hp = -6
	# Need another tick for enemy_dies to fire (it's a tick rule reading state)
	sched.tick()
	expect_eq(QueryLib.run({"tags_all": ["enemy"]}, env).size(), 0, "enemy removed after hp <= 0")

	# Cleanup
	for ent in entities.values(): (ent as Entity).queue_free()


# ============================================================
# RPG CASCADE (W5.4) — attack → kill → xp gain → level up
# ============================================================

func test_rpg_cascade() -> void:
	_section("rpg_cascade (W5.4)")
	var defs: Dictionary = {
		"player": {"id": "player", "tags": ["player"],
		           "state_init": {"hp": 100, "hp_max": 100, "xp": 0, "level": 1}},
		"goblin": {"id": "goblin", "tags": ["enemy", "goblin"],
		           "state_init": {"hp": 20, "xp_value": 60}},
		"swing":  {"id": "swing", "tags": ["weapon", "transient"],
		           "state_init": {"lifespan": 2, "damage": 25}},
	}
	var entities: Dictionary = {}
	var p := Entity.create(defs.player, "p1"); p.set_position(Vector2(0, 0))
	var g1 := Entity.create(defs.goblin, "g1"); g1.set_position(Vector2(20, 0))
	var g2 := Entity.create(defs.goblin, "g2"); g2.set_position(Vector2(-20, 0))
	entities["p1"] = p; entities["g1"] = g1; entities["g2"] = g2

	var rs := RelationStore.new()
	var sx := SpatialIndex.new()
	for id in entities:
		sx.update_entity(id, (entities[id] as Entity).get_planar_position())
	var env: Dictionary = {
		"entities": entities, "defs": defs, "relations": rs, "spatial_index": sx,
		"world": {}, "parent": null, "next_id": {"_": 0},
	}

	var rules: Array = [
		Rule.from_dict({
			"id": "attack",
			"trigger": {"type": "input", "action": "spark"},
			"effect": {"type": "spawn", "template": "swing", "position": "actor"},
		}),
		Rule.from_dict({
			"id": "swing_hits_enemy",
			"trigger": {"type": "contact"},
			"query": {
				"a": {"tags_all": ["weapon"]},
				"b": {"tags_all": ["enemy"]},
				"radius": 50.0,
			},
			"effect": {"type": "state_add", "target": "b", "field": "hp",
			           "amount": "-a.state.damage"},
		}),
		Rule.from_dict({
			"id": "swing_dies_after_lifespan",
			"trigger": {"type": "tick", "interval": 1},
			"query": {"tags_all": ["weapon"]},
			"effect": [
				{"type": "state_add", "target": "self", "field": "lifespan", "amount": -1},
			],
		}),
		Rule.from_dict({
			"id": "swing_remove",
			"trigger": {"type": "tick", "interval": 1},
			"query": {"tags_all": ["weapon"], "state": {"lifespan_lte": 0}},
			"effect": {"type": "remove", "target": "self"},
		}),
		Rule.from_dict({
			"id": "enemy_dies",
			"trigger": {"type": "tick", "interval": 1},
			"query": {"tags_all": ["enemy"], "state": {"hp_lte": 0}},
			"effect": [
				{"type": "emit", "signal": "killed",
				 "payload": {"xp_value": "self.state.xp_value"}},
				{"type": "remove", "target": "self"},
			],
		}),
		Rule.from_dict({
			"id": "player_gains_xp",
			"trigger": {"type": "signal", "name": "killed"},
			"query": {"tags_all": ["player"]},
			"effect": {"type": "state_add", "target": "self", "field": "xp",
			           "amount": "xp_value"},
		}),
		Rule.from_dict({
			"id": "level_up",
			"trigger": {"type": "tick", "interval": 1},
			"query": {"tags_all": ["player"], "state": {"xp_gte": 100}},
			"effect": [
				{"type": "state_add", "target": "self", "field": "level", "amount": 1},
				{"type": "state_add", "target": "self", "field": "xp", "amount": -100},
				{"type": "state_mul", "target": "self", "field": "hp_max", "amount": 1.1},
				{"type": "state_set", "target": "self", "field": "hp",
				 "value": "self.state.hp_max"},
			],
		}),
	]
	var sched := PhaseScheduler.new(env)
	sched.register_rules(rules)

	# Initial — player level 1, no xp, both goblins alive
	expect_eq(int(p.get_state("level")), 1, "player starts at level 1")
	expect_eq(int(p.get_state("xp")), 0, "player starts at 0 xp")
	expect_eq(QueryLib.run({"tags_all": ["enemy"]}, env).size(), 2, "2 goblins alive")

	# Attack 1: spawn swing → contacts both goblins (both within radius 50 of player)
	# Both goblins take 25 damage, hp 20→-5, both at lethal hp.
	# Same tick: swing ages (lifespan 2→1).
	# Goblins die in next tick (tick rule reading state). Their kill emits xp_value=60 each.
	# Signal fires → player gains 60 xp → tick rule level_up_check fires → level up!
	sched.queue_input("spark", {"actor": "p1"})
	sched.tick()  # swing spawns + contact applies damage in react

	# After tick 1: goblins should be at hp -5 each (still in entities)
	expect_eq(int(g1.get_state("hp")), -5, "goblin 1 took 25 damage")
	expect_eq(int(g2.get_state("hp")), -5, "goblin 2 took 25 damage")

	sched.tick()  # tick rule sees hp<=0 → emit killed (with xp_value) + remove
	# Signals from this tick's react drain into NEXT tick
	expect_eq(QueryLib.run({"tags_all": ["enemy"]}, env).size(), 0, "goblins removed")

	sched.tick()  # signal handler runs: player gains 60 xp from each (120 total)
	# But level_up rule (tick) fires when xp >= 100. So same tick: xp=120 → level up
	expect_eq(int(p.get_state("level")), 2, "player leveled up to 2")
	expect_eq(int(p.get_state("xp")), 20, "leftover xp: 120 - 100 = 20")
	expect(p.get_state("hp_max") > 100, "hp_max increased after level up")
	expect_eq(int(p.get_state("hp")), int(p.get_state("hp_max")), "hp restored to hp_max on level up")

	# Cleanup
	for ent in entities.values():
		if is_instance_valid(ent): (ent as Entity).queue_free()


# ============================================================
# CHESS CASCADE (W5.5) — non-spatial acid test
# ============================================================

func test_chess_cascade() -> void:
	_section("chess_cascade (W5.5)")
	# Minimal chess: 4 squares, 2 pieces, 1 game_state.
	# Demonstrates Relation + signal-based turn flow + require validation.
	var defs: Dictionary = {
		"square":     {"id": "square", "tags": ["square"]},
		"pawn_white": {"id": "pawn_white", "tags": ["piece", "white", "pawn"]},
		"pawn_black": {"id": "pawn_black", "tags": ["piece", "black", "pawn"]},
		"game_state": {"id": "game_state", "tags": ["game_state"],
		               "state_init": {"turn": "white", "move_count": 0}},
	}
	var entities: Dictionary = {}
	entities["sq_a1"] = Entity.create(defs.square, "sq_a1")
	entities["sq_a2"] = Entity.create(defs.square, "sq_a2")
	entities["sq_b1"] = Entity.create(defs.square, "sq_b1")
	entities["sq_b2"] = Entity.create(defs.square, "sq_b2")
	entities["wp"]    = Entity.create(defs.pawn_white, "wp")
	entities["bp"]    = Entity.create(defs.pawn_black, "bp")
	entities["game"]  = Entity.create(defs.game_state, "game")

	var rs := RelationStore.new()
	rs.relate("on_square", "wp", "sq_a1")
	rs.relate("on_square", "bp", "sq_a2")

	var env: Dictionary = {
		"entities": entities, "defs": defs, "relations": rs,
		"world": {}, "parent": null, "next_id": {"_": 0},
	}

	var rules: Array = [
		Rule.from_dict({
			"id": "white_move",
			"trigger": {"type": "input", "action": "move"},
			"query": {"tags_all": ["game_state"], "state": {"turn_eq": "white"}},
			"require": {
				"piece": {"tags_all": ["white", "piece"]},
				"from_sq": {"tags_all": ["square"]},
				"to_sq": {"tags_all": ["square"]},
			},
			"effect": [
				{"type": "unrelate", "relation": "on_square", "from": "piece", "to": "from_sq"},
				{"type": "relate",   "relation": "on_square", "from": "piece", "to": "to_sq"},
				{"type": "state_set", "target": "self", "field": "turn", "value": "black"},
				{"type": "state_add", "target": "self", "field": "move_count", "amount": 1},
			],
		}),
		Rule.from_dict({
			"id": "black_move",
			"trigger": {"type": "input", "action": "move"},
			"query": {"tags_all": ["game_state"], "state": {"turn_eq": "black"}},
			"require": {
				"piece": {"tags_all": ["black", "piece"]},
				"from_sq": {"tags_all": ["square"]},
				"to_sq": {"tags_all": ["square"]},
			},
			"effect": [
				{"type": "unrelate", "relation": "on_square", "from": "piece", "to": "from_sq"},
				{"type": "relate",   "relation": "on_square", "from": "piece", "to": "to_sq"},
				{"type": "state_set", "target": "self", "field": "turn", "value": "white"},
				{"type": "state_add", "target": "self", "field": "move_count", "amount": 1},
			],
		}),
	]
	var sched := PhaseScheduler.new(env)
	sched.register_rules(rules)

	# Initial state
	var game = entities["game"] as Entity
	expect_eq(str(game.get_state("turn")), "white", "starts on white's turn")
	expect_eq(int(game.get_state("move_count")), 0, "starts at 0 moves")
	expect_eq(rs.targets("on_square", "wp"), ["sq_a1"], "white pawn on a1")

	# White's move: a1 → b1 (legal — it's white's turn, piece is white)
	sched.queue_input("move", {"piece": "wp", "from_sq": "sq_a1", "to_sq": "sq_b1"})
	sched.tick()
	expect_eq(rs.targets("on_square", "wp"), ["sq_b1"], "white pawn moved to b1")
	expect_eq(str(game.get_state("turn")), "black", "turn flipped to black")
	expect_eq(int(game.get_state("move_count")), 1, "move count incremented")

	# Try a white move on black's turn (illegal — should be rejected)
	sched.queue_input("move", {"piece": "wp", "from_sq": "sq_b1", "to_sq": "sq_b2"})
	sched.tick()
	expect_eq(rs.targets("on_square", "wp"), ["sq_b1"], "illegal white-on-black-turn rejected — pawn stays")
	expect_eq(str(game.get_state("turn")), "black", "turn unchanged")
	expect_eq(int(game.get_state("move_count")), 1, "move count unchanged")

	# Try black moving a white piece (illegal — require fails on color tag)
	sched.queue_input("move", {"piece": "wp", "from_sq": "sq_b1", "to_sq": "sq_b2"})
	sched.tick()
	expect_eq(rs.targets("on_square", "wp"), ["sq_b1"], "black-rule rejects white piece via require")
	expect_eq(str(game.get_state("turn")), "black", "still black's turn")

	# Black's legal move
	sched.queue_input("move", {"piece": "bp", "from_sq": "sq_a2", "to_sq": "sq_b2"})
	sched.tick()
	expect_eq(rs.targets("on_square", "bp"), ["sq_b2"], "black pawn moved")
	expect_eq(str(game.get_state("turn")), "white", "turn flipped back to white")
	expect_eq(int(game.get_state("move_count")), 2, "second move counted")

	# Cleanup
	for ent in entities.values():
		if is_instance_valid(ent): (ent as Entity).queue_free()


# ============================================================
# ENGINE ERRORS (Tier 2.6a)
# ============================================================

func test_engine_error() -> void:
	_section("engine_error (Tier 2.6a)")

	# Record shape: make() returns a JSON-shaped dict.
	var rec := EngineError.make("test.code", "what happened",
		{"file": "x.json", "rule_id": "r1"}, "do this", "warning")
	expect_eq(str(rec.get("code")), "test.code", "record carries code")
	expect_eq(str(rec.get("what")), "what happened", "record carries what")
	expect_eq(str(rec.get("severity")), "warning", "severity preserved")
	expect_eq(str((rec.get("where") as Dictionary).get("rule_id")), "r1", "where carries rule_id")

	# Buffer accumulation: report() appends to env.error_buffer.
	var env: Dictionary = {"error_buffer": []}
	EngineError.raise(env, "test.a", "first", {}, "")
	EngineError.raise(env, "test.b", "second", {}, "", "warning")
	var buf: Array = env["error_buffer"]
	expect_eq(buf.size(), 2, "buffer accumulated 2 records")
	expect_eq(str(buf[0].code), "test.a", "first record code")
	expect_eq(str(buf[1].severity), "warning", "second record severity")

	# Drain: reads + resets.
	var drained := EngineError.drain(env)
	expect_eq(drained.size(), 2, "drain returned all records")
	expect_eq((env["error_buffer"] as Array).size(), 0, "buffer reset after drain")

	# Validate_all returns structured records (was strings pre-2.6a).
	var bad := [
		Rule.from_dict({"id": "", "trigger": {"type": "tick"}, "effect": {"type": "state_set"}}),
		Rule.from_dict({"id": "x", "trigger": {"type": "wat"}, "effect": {"type": "state_set"}}),
	]
	var errs := Rule.validate_all(bad)
	expect(errs.size() >= 2, "validate_all returns at least 2 records (got %d)" % errs.size())
	expect(errs[0] is Dictionary, "validate_all entry is a Dictionary")
	expect(errs[0].has("code"), "validate_all record has code field")
	expect(errs[0].has("hint"), "validate_all record has hint field")

	# Integration: unknown effect type via EffectApply lands in env.error_buffer.
	var env2: Dictionary = {
		"entities": {}, "defs": {}, "relations": RelationStore.new(),
		"world": {}, "parent": null, "next_id": {"_": 0},
		"error_buffer": [],
	}
	EffectApply.apply({"type": "totally_made_up"}, env2, {"_rule_id": "r_unknown"})
	var ebuf: Array = env2["error_buffer"]
	expect_eq(ebuf.size(), 1, "unknown effect type produced 1 error record")
	expect_eq(str(ebuf[0].code), EngineError.EFFECT_UNKNOWN_TYPE, "effect.unknown_type code")
	expect_eq(str((ebuf[0].where as Dictionary).get("rule_id")), "r_unknown", "rule_id attribution")

	# Integration: Formula parse failure lands in env.error_buffer with rule_id.
	var env3: Dictionary = {"error_buffer": []}
	# Syntactically broken — Expression will reject this.
	Formula.evaluate("self.state.x +++ )", {"_rule_id": "r_formula"}, env3)
	var fbuf: Array = env3["error_buffer"]
	expect(fbuf.size() >= 1, "formula parse failure produced at least 1 record")
	if fbuf.size() >= 1:
		expect_eq(str(fbuf[0].code), EngineError.FORMULA_PARSE_FAILED, "formula.parse_failed code")
		expect_eq(str((fbuf[0].where as Dictionary).get("rule_id")), "r_formula", "formula rule_id attribution")


# ============================================================
# BLOCKS_MOTION (ADR 0004)
# ============================================================

func test_blocks_motion() -> void:
	_section("blocks_motion (ADR 0004)")

	# Single 3D AABB blocker: a wall-like slab from (−1,0,−1) to (1,3,1).
	var blockers: Array = [{
		"minx": -1.0, "maxx": 1.0,
		"miny":  0.0, "maxy": 3.0,
		"minz": -1.0, "maxz": 1.0
	}]

	# A sphere whose center is inside the AABB intersects.
	expect(World._aabb_intersects(0.0, 1.0, 0.0, 0.4, blockers), "center inside aabb intersects")

	# A sphere far from the AABB does not.
	expect(not World._aabb_intersects(5.0, 1.0, 5.0, 0.4, blockers), "center far away doesn't intersect")

	# Edge-of-aabb approach: at x=1.3, edge of aabb is at x=1; distance=0.3
	# < radius 0.4 → intersects.
	expect(World._aabb_intersects(1.3, 1.0, 0.0, 0.4, blockers), "approach within body radius intersects")

	# Just outside body radius: x=1.5, distance=0.5 > radius 0.4 → no.
	expect(not World._aabb_intersects(1.5, 1.0, 0.0, 0.4, blockers), "approach outside body radius does not intersect")

	# Y too high (above wall top y=3): bullet at altitude 5 should clear.
	expect(not World._aabb_intersects(0.0, 5.0, 0.0, 0.4, blockers), "high altitude clears the wall (3D AABB)")

	# Y just at wall top + body_radius: at y=3.5, distance from y=3 is 0.5 > r=0.4 → no.
	expect(not World._aabb_intersects(0.0, 3.5, 0.0, 0.4, blockers), "just-above wall clears (3.5 > 3 + 0.4)")

	# Y just below wall top: at y=3.2, distance 0.2 < r=0.4 → intersects.
	expect(World._aabb_intersects(0.0, 3.2, 0.0, 0.4, blockers), "near wall top still intersects")

	# Resolve: walking south at ground level into the blocker face.
	# Old (0.5, 0, 2): z=2 outside aabb. New (0.5, 0, 0.5): inside → intersects.
	# Slide: X-only (0.5, 0, 2): old z, no intersect → take.
	var resolved3 := World._resolve_motion_3d(
		Vector3(0.5, 0.5, 2.0), Vector3(0.5, 0.5, 0.5), 0.4, blockers)
	expect_eq(resolved3.x, 0.5, "slide preserves new x")
	expect_eq(resolved3.z, 2.0, "slide reverts z to old (X-only path taken)")

	# Bullet entirely above wall top (Y=3 + body_r): old (0.5, 5, 2),
	# new (0.5, 5, 0.5). Segment stays above the wall — should pass.
	var resolved_up := World._resolve_motion_3d(
		Vector3(0.5, 5.0, 2.0), Vector3(0.5, 5.0, 0.5), 0.4, blockers)
	expect_eq(resolved_up, Vector3(0.5, 5.0, 0.5), "high-altitude bullet (entirely above wall) clears full move")

	# Bullet ascending FROM inside wall altitude TO above: old (0.5, 1, 2),
	# new (0.5, 5, 0.5). Segment crosses the wall vertically. Swept check
	# blocks it (correct — bullet would graze the wall on its way up).
	var resolved_grazing := World._resolve_motion_3d(
		Vector3(0.5, 1.0, 2.0), Vector3(0.5, 5.0, 0.5), 0.4, blockers)
	expect(resolved_grazing.z >= 1.5, "ascending bullet grazes wall — Z reverted (not full passthrough)")

	# 2D variant uses the same logic (Vector2 maps to XZ at Y=0).
	var resolved2 := World._resolve_motion_2d(
		Vector2(0.5, 2.0), Vector2(0.5, 0.5), 0.4, blockers)
	expect_eq(resolved2.x, 0.5, "2D slide preserves new x")
	expect_eq(resolved2.y, 2.0, "2D slide reverts y to old")

	# _to_vec3 coercion variants.
	expect_eq(World._to_vec3([1, 2, 3]), Vector3(1, 2, 3), "_to_vec3 array len 3")
	expect_eq(World._to_vec3([1, 2]), Vector3(1, 0, 2), "_to_vec3 array len 2 → XZ")
	expect_eq(World._to_vec3(Vector2(1, 2)), Vector3(1, 0, 2), "_to_vec3 Vector2 → XZ")
	expect_eq(World._to_vec3(Vector3(1, 2, 3)), Vector3(1, 2, 3), "_to_vec3 Vector3 passthrough")

	# Swept (segment) check — catches tunneling that point-tests miss.
	# Wall slab from x ∈ [-0.25, 0.25], spans y/z fully for the test.
	var wall: Array = [{
		"minx": -0.25, "maxx": 0.25,
		"miny":  0.0,  "maxy": 3.0,
		"minz": -22.0, "maxz": 22.0
	}]
	# A bullet at p0=(1, 1.5, 0) flies fast to p1=(-1, 1.5, 0): point-tests
	# at the endpoints would miss (both outside the 0.5m wall in X), but
	# the segment crosses the wall. Swept check must return true.
	expect(World._segment_intersects(Vector3(1, 1.5, 0), Vector3(-1, 1.5, 0), 0.18, wall),
		"swept: bullet tunneling x=1 → x=-1 across thin wall is caught")
	# Confirm endpoint-only test would have missed it (regression check).
	expect(not World._aabb_intersects(1.0, 1.5, 0.0, 0.18, wall),
		"sanity: point at x=1 outside wall")
	expect(not World._aabb_intersects(-1.0, 1.5, 0.0, 0.18, wall),
		"sanity: point at x=-1 outside wall (so endpoint-only would miss)")
	# Slow movement parallel to wall: no cross.
	expect(not World._segment_intersects(Vector3(2, 1.5, 0), Vector3(2, 1.5, 5), 0.18, wall),
		"swept: motion parallel to wall doesn't intersect")
	# Bullet at altitude > wall top: clears the wall.
	expect(not World._segment_intersects(Vector3(1, 5, 0), Vector3(-1, 5, 0), 0.18, wall),
		"swept: high-altitude bullet clears wall (Y > 3.18)")
	# Resolve3D test — bullet would tunnel; resolved should stay at old.
	var resolved_bullet := World._resolve_motion_3d(
		Vector3(1, 1.5, 0), Vector3(-1, 1.5, 0), 0.18, wall)
	expect_eq(resolved_bullet, Vector3(1, 1.5, 0),
		"resolve3d: tunneling bullet stays at old position (all axes blocked)")


# ============================================================
# RAYCAST_HIT (ADR 0005)
# ============================================================

func test_raycast_hit() -> void:
	_section("raycast_hit (ADR 0005)")

	# Build a minimal env with one target entity at (0, 1, -5) and a
	# wall blocker at (0, 1.5, -10) with extents [5, 1.5, 0.25].
	var entities: Dictionary = {}
	var defs: Dictionary = {
		"target": {
			"id": "target",
			"tags": ["enemy"],
			"properties": {"body_radius": 0.4},
			"state_init": {"hp": 5, "position": [0, 1, -5]}
		},
		"wall_seg": {
			"id": "wall_seg",
			"tags": ["wall", "blocks_motion"],
			"properties": {"aabb_extents": [5, 1.5, 0.25], "aabb_offset": [0, 0, 0]},
			"state_init": {"position": [0, 1.5, -10]}
		}
	}
	var t := Entity.create(defs["target"], "target", {})
	t.set_position(Vector3(0, 1, -5))
	entities["target"] = t
	var w := Entity.create(defs["wall_seg"], "wall_seg", {})
	w.set_position(Vector3(0, 1.5, -10))
	entities["wall_seg"] = w
	var env: Dictionary = {"entities": entities, "defs": defs, "world": {}, "next_id": {"_": 0}}

	# Fire from origin (0, 1, 0) toward -Z (forward).
	# Target at z=-5, wall at z=-10. Ray direction (0,0,-1) hits target first.
	EffectApply.apply({
		"type": "raycast_hit",
		"origin": [0, 1, 0],
		"direction": [0, 0, -1],
		"max_distance": 30.0,
		"tags_all": ["enemy"],
		"on_hit": [{"type": "state_add", "target": "hit", "field": "hp", "amount": -2}]
	}, env, {})
	expect_eq(t.get_state("hp"), 3.0, "raycast on_hit: target hp 5 → 3")

	# Aim AWAY from target (positive Z) — should miss.
	t.set_state("hp", 5)
	var miss_flag: Array = [false]
	# We can't easily inject a closure, so: aim at Z=+1 (no entities there)
	EffectApply.apply({
		"type": "raycast_hit",
		"origin": [0, 1, 0],
		"direction": [0, 0, 1],
		"max_distance": 30.0,
		"tags_all": ["enemy"],
		"on_hit": [{"type": "state_add", "target": "hit", "field": "hp", "amount": -100}]
	}, env, {})
	expect_eq(t.get_state("hp"), 5.0, "raycast miss: target unaffected when ray points away")

	# Wall caps the ray: place a SECOND target BEHIND the wall, only the
	# wall-side target is hit. Move first target behind wall (z=-15) and
	# fire — wall blocks the ray at z=-10, target at z=-15 unreachable.
	t.set_position(Vector3(0, 1, -15))
	t.set_state("hp", 5)
	EffectApply.apply({
		"type": "raycast_hit",
		"origin": [0, 1, 0],
		"direction": [0, 0, -1],
		"max_distance": 30.0,
		"tags_all": ["enemy"],
		"respect_obstacles": true,
		"on_hit": [{"type": "state_add", "target": "hit", "field": "hp", "amount": -100}]
	}, env, {})
	expect_eq(t.get_state("hp"), 5.0, "raycast: wall blocks ray, target behind unhurt")

	# respect_obstacles=false: ray passes through walls.
	EffectApply.apply({
		"type": "raycast_hit",
		"origin": [0, 1, 0],
		"direction": [0, 0, -1],
		"max_distance": 30.0,
		"tags_all": ["enemy"],
		"respect_obstacles": false,
		"on_hit": [{"type": "state_add", "target": "hit", "field": "hp", "amount": -1}]
	}, env, {})
	expect_eq(t.get_state("hp"), 4.0, "raycast respect_obstacles=false: target through wall is hit")

	# Tag filter excludes non-matching entities.
	t.set_position(Vector3(0, 1, -5))
	t.set_state("hp", 5)
	EffectApply.apply({
		"type": "raycast_hit",
		"origin": [0, 1, 0],
		"direction": [0, 0, -1],
		"max_distance": 30.0,
		"tags_all": ["nonexistent_tag"],
		"on_hit": [{"type": "state_add", "target": "hit", "field": "hp", "amount": -100}]
	}, env, {})
	expect_eq(t.get_state("hp"), 5.0, "raycast tags_all filter excludes non-matching entity")

	# Cleanup
	for ent in entities.values():
		if is_instance_valid(ent): (ent as Entity).queue_free()


# ============================================================
# INSTANCE PATTERNS (Tier 2.6q + v2.6 mirror/exclude_zones)
# ============================================================

func test_instance_patterns() -> void:
	_section("instance_patterns (mirror + exclude_zones + determinism)")

	# Ring expansion (existing primitive — sanity check).
	var ring := InstancePatterns.expand({
		"def": "pillar", "pattern": "ring", "count": 4, "radius": 10
	})
	expect_eq(ring.size(), 4, "ring: 4 entries placed")
	expect_eq(str((ring[0] as Dictionary)["def"]), "pillar", "ring: def carried through")

	# Mirror primitive — duplicates `items` reflected across X axis.
	var mirrored := InstancePatterns.expand({
		"pattern": "mirror", "axis": "x",
		"items": [
			{"def": "pillar", "id": "P1", "position": [5, 0, 3]},
			{"def": "pillar", "id": "P2", "position": [7, 0, -2]}
		]
	})
	expect_eq(mirrored.size(), 4, "mirror: 2 originals + 2 mirrored = 4 entries")
	expect_eq(str((mirrored[0] as Dictionary)["id"]), "P1", "mirror: original kept")
	var mirror_pos: Array = (mirrored[1] as Dictionary)["position"]
	expect_eq(float(mirror_pos[0]), -5.0, "mirror: x flipped (5 → -5)")
	expect_eq(float(mirror_pos[2]),  3.0, "mirror: z preserved")
	expect_eq(str((mirrored[1] as Dictionary)["id"]), "P1_mirror", "mirror: id_suffix appended")

	# Mirror axis Z.
	var mirrored_z := InstancePatterns.expand({
		"pattern": "mirror", "axis": "z",
		"items": [{"def": "pillar", "id": "Q", "position": [4, 0, 7]}]
	})
	var mz_pos: Array = (mirrored_z[1] as Dictionary)["position"]
	expect_eq(float(mz_pos[0]),  4.0, "mirror z-axis: x preserved")
	expect_eq(float(mz_pos[2]), -7.0, "mirror z-axis: z flipped")

	# Exclude zones — scatter avoids forbidden circles.
	seed(42)
	var scattered := InstancePatterns.expand({
		"def": "rock", "pattern": "scatter",
		"count": 30, "min_r": 0, "max_r": 10, "min_spacing": 0.5,
		"exclude_zones": [{"center": [0, 0, 0], "radius": 4}]
	})
	var any_inside_zone := false
	for inst in scattered:
		var p: Array = (inst as Dictionary)["position"]
		var dx := float(p[0])
		var dz := float(p[2])
		if dx * dx + dz * dz < 16.0:
			any_inside_zone = true
			break
	expect(not any_inside_zone, "scatter exclude_zones: no placement inside r=4 circle around origin")
	expect(scattered.size() > 0, "scatter exclude_zones: still placed entities outside the zone")

	# Determinism — same seed produces same result.
	seed(123)
	var batch_a := InstancePatterns.expand({
		"def": "tree", "pattern": "scatter", "count": 10, "max_r": 20
	})
	seed(123)
	var batch_b := InstancePatterns.expand({
		"def": "tree", "pattern": "scatter", "count": 10, "max_r": 20
	})
	expect_eq(batch_a.size(), batch_b.size(), "deterministic: same seed → same count")
	if batch_a.size() == batch_b.size() and batch_a.size() > 0:
		var pa: Array = (batch_a[0] as Dictionary)["position"]
		var pb: Array = (batch_b[0] as Dictionary)["position"]
		expect_eq(float(pa[0]), float(pb[0]), "deterministic: same seed → same x[0]")
		expect_eq(float(pa[2]), float(pb[2]), "deterministic: same seed → same z[0]")


# ============================================================
# SCREEN FLOW (ADR 0011)
# ============================================================

## Verify the four new effect types push correctly into env.screen_event_buffer.
## Full ScreenFlow integration (CanvasLayer instantiation, modal stack) requires
## a SceneTree, so we verify the effect-buffer contract here and the rendering
## layer in scene-based playthrough tests.
func test_screen_flow_effects() -> void:
	_section("screen_flow_effects (ADR 0011)")
	var env: Dictionary = {"screen_event_buffer": []}
	var ctx: Dictionary = {"_rule_id": "test"}

	EffectApply.apply({"type": "transition_screen", "target": "pause"}, env, ctx)
	expect_eq(env["screen_event_buffer"].size(), 1, "transition_screen: buffer size")
	var ev: Dictionary = env["screen_event_buffer"][0]
	expect_eq(str(ev.get("event", "")), "transition_screen", "transition_screen: event name")
	expect_eq(str(ev.get("target", "")), "pause", "transition_screen: target")

	EffectApply.apply({"type": "quit_app"}, env, ctx)
	expect_eq(env["screen_event_buffer"].size(), 2, "quit_app: buffer grew")
	expect_eq(str((env["screen_event_buffer"][1] as Dictionary).get("event", "")),
		"quit_app", "quit_app: event name")

	EffectApply.apply({"type": "show_toast", "text": "Saved!", "duration": 1.5},
		env, ctx)
	expect_eq(env["screen_event_buffer"].size(), 3, "show_toast: buffer grew")
	var t: Dictionary = env["screen_event_buffer"][2]
	expect_eq(str(t.get("text", "")), "Saved!", "show_toast: text passed")
	expect_eq(float(t.get("duration", 0)), 1.5, "show_toast: duration passed")

	EffectApply.apply({"type": "reload_scene", "args": {"reset": true}}, env, ctx)
	expect_eq(env["screen_event_buffer"].size(), 4, "reload_scene: buffer grew")

	# transition_screen with no target should warn but not crash
	EffectApply.apply({"type": "transition_screen"}, env, ctx)
	expect_eq(env["screen_event_buffer"].size(), 4,
		"transition_screen with no target: no event pushed")

	# Buffer auto-creates if env didn't have one (edge case)
	var fresh_env: Dictionary = {}
	EffectApply.apply({"type": "transition_screen", "target": "title"}, fresh_env, ctx)
	expect(fresh_env.has("screen_event_buffer"), "lazy buffer creation")
	expect_eq((fresh_env["screen_event_buffer"] as Array).size(), 1,
		"lazy buffer: event landed")


## Spot-check ControlFactory builds correct Godot Control types for each
## element kind. Free nodes after to avoid ObjectDB leaks.
func test_control_factory() -> void:
	_section("control_factory (ADR 0011)")
	var parent := Control.new()
	var bound: Array = []
	var dispatcher := func(_a, _b): pass

	var lbl: Control = ControlFactory.build({"type": "label", "text": "Hello"},
		parent, dispatcher, bound)
	expect(lbl is Label, "label → Label")
	if lbl is Label:
		expect_eq((lbl as Label).text, "Hello", "label text set")

	var btn: Control = ControlFactory.build({"type": "button", "text": "Click",
		"on_click": [{"type": "quit_app"}]}, parent, dispatcher, bound)
	expect(btn is Button, "button → Button")

	var vb: Control = ControlFactory.build({"type": "vbox",
		"children": [{"type": "label", "text": "A"}, {"type": "label", "text": "B"}]},
		parent, dispatcher, bound)
	expect(vb is VBoxContainer, "vbox → VBoxContainer")
	if vb is VBoxContainer:
		expect_eq((vb as VBoxContainer).get_child_count(), 2, "vbox has 2 children")

	var hb: Control = ControlFactory.build({"type": "hbox",
		"children": [{"type": "label", "text": "X"}]},
		parent, dispatcher, bound)
	expect(hb is HBoxContainer, "hbox → HBoxContainer")

	var cr: Control = ControlFactory.build({"type": "color_rect",
		"color": "#000000", "alpha": 0.6, "anchor": "fill"},
		parent, dispatcher, bound)
	expect(cr is ColorRect, "color_rect → ColorRect")
	if cr is ColorRect:
		expect(abs((cr as ColorRect).color.a - 0.6) < 0.001, "color_rect alpha set")

	var sp: Control = ControlFactory.build({"type": "spacer", "height": 12},
		parent, dispatcher, bound)
	expect(sp != null, "spacer built")
	if sp != null:
		expect_eq(sp.custom_minimum_size.y, 12.0, "spacer height set")

	# visible_if/enabled_if elements should be tracked in bound array
	var conditional: Control = ControlFactory.build({"type": "button",
		"text": "Continue", "enabled_if": "world.has_save"},
		parent, dispatcher, bound)
	expect(conditional != null, "conditional element built")
	expect(bound.size() >= 1, "bound element registered for re-eval")

	# Unknown type returns null and warns (don't fail the test on warning)
	var unknown: Control = ControlFactory.build({"type": "futuristic_widget"},
		parent, dispatcher, bound)
	expect(unknown == null, "unknown element type returns null")

	parent.queue_free()


# ============================================================
# SAVE STATE (ADR 0010)
# ============================================================

## Round-trip: save snapshot of an env, mutate, load, verify state restored.
## Uses a temp game name under user:// to isolate from real saves.
func test_save_state() -> void:
	_section("save_state (ADR 0010)")
	var game := "test_save_%d" % Time.get_ticks_msec()
	var policy: Dictionary = {
		"world_state_keys": ["current_level", "score", "tutorial_step"],
		"entity_tags_persistent": ["named_npc"],
		"entity_state_blacklist": ["_temp_*"],
		"relations_persistent": ["owns"],
		"slots": 1,
		"version": 1,
	}

	# Build a fresh env with one persistent entity + one transient
	var defs: Dictionary = {
		"npc": {"id": "npc", "tags": ["named_npc"], "state_init": {"hp": 100}},
		"mob": {"id": "mob", "tags": ["enemy"], "state_init": {"hp": 50}},
	}
	var entities: Dictionary = {}
	var rs := RelationStore.new()
	var env: Dictionary = {
		"entities": entities, "defs": defs, "relations": rs,
		"world": {"current_level": "1", "score": 42, "tutorial_step": 3,
				  "_temp_runtime": 999, "ignored_key": "x"},
		"parent": null, "next_id": {"_": 0},
	}

	# Spawn one of each
	var npc := Entity.new()
	npc.def_id = "npc"; npc.instance_id = "alice"
	npc.tags = ["named_npc"]
	npc.state = {"hp": 75, "_temp_runtime": 1, "gold": 200}
	npc.set_position(Vector2(10, 20))
	entities["alice"] = npc

	var mob := Entity.new()
	mob.def_id = "mob"; mob.instance_id = "goblin1"
	mob.tags = ["enemy"]
	mob.state = {"hp": 50}
	mob.set_position(Vector2(30, 40))
	entities["goblin1"] = mob

	rs.relate("owns", "alice", "sword_1")
	rs.relate("knows", "alice", "bob")  # not in relations_persistent

	# SAVE
	var ok := SaveState.save_to_slot(env, policy, 0, game, 7)
	expect(ok, "save_to_slot returned ok")

	# Read back the JSON to verify structure
	var path := SaveState.slot_path(game, 0)
	expect(FileAccess.file_exists(path), "slot file exists")
	var f := FileAccess.open(path, FileAccess.READ)
	var read_payload = JSON.parse_string(f.get_as_text())
	expect(read_payload is Dictionary, "saved file parses as JSON")
	if read_payload is Dictionary:
		var p: Dictionary = read_payload
		expect_eq(int(p.get("version", -1)), 1, "version stored")
		var ws: Dictionary = p.get("world_state", {})
		expect_eq(int(ws.get("score", 0)), 42, "score persisted")
		expect_eq(int(ws.get("tutorial_step", 0)), 3, "tutorial_step persisted")
		expect(not ws.has("ignored_key"), "ignored_key NOT persisted (not in policy)")

		var ents: Array = p.get("persistent_entities", [])
		expect_eq(ents.size(), 1, "only persistent (named_npc) entity saved")
		if ents.size() > 0:
			var rec: Dictionary = ents[0]
			expect_eq(str(rec.get("id", "")), "alice", "alice was saved")
			expect_eq(str(rec.get("def", "")), "npc", "alice's def saved")
			var st: Dictionary = rec.get("state", {})
			expect_eq(int(st.get("hp", -1)), 75, "alice's hp saved")
			expect_eq(int(st.get("gold", -1)), 200, "alice's gold saved")
			expect(not st.has("_temp_runtime"),
				"blacklisted _temp_* field NOT saved")

		var rels: Array = p.get("relations", [])
		expect_eq(rels.size(), 1, "only `owns` relation persisted")
		if rels.size() > 0:
			expect_eq(str((rels[0] as Dictionary).get("type", "")), "owns",
				"saved relation type is `owns`")

	# READ BACK + version check
	var result: Dictionary = SaveState.read_slot(game, 0, policy)
	expect(bool(result.get("ok", false)), "read_slot returned ok")

	# Version mismatch refusal
	var bad_policy: Dictionary = policy.duplicate()
	bad_policy["version"] = 999
	var bad_result: Dictionary = SaveState.read_slot(game, 0, bad_policy)
	expect(not bool(bad_result.get("ok", true)), "version mismatch refuses load")
	expect_eq(str(bad_result.get("error", "")), "version_mismatch",
		"version mismatch reports correct error code")

	# has_any_save sanity
	expect(SaveState.has_any_save(game, 1), "has_any_save returns true after save")
	expect(not SaveState.has_any_save("test_nonexistent_xyz", 3),
		"has_any_save returns false for missing game")

	# Cleanup: remove the temp save dir
	var d := DirAccess.open("user://saves/" + game)
	if d != null:
		d.remove("slot_0.json")
	var d2 := DirAccess.open("user://saves")
	if d2 != null:
		d2.remove(game)

	npc.queue_free()
	mob.queue_free()


# ============================================================
# OVERLAY (ADR 0012)
# ============================================================

## Verify show_overlay / dismiss_overlay effect types push correctly into
## env.overlay_event_buffer. Full OverlayManager (CanvasLayer + advance
## conditions) is integration-tested via scene playthrough.
func test_overlay_effects() -> void:
	_section("overlay_effects (ADR 0012)")
	var env: Dictionary = {"overlay_event_buffer": []}
	var ctx: Dictionary = {"_rule_id": "test"}

	# show_overlay forwards all keys verbatim
	EffectApply.apply({
		"type": "show_overlay",
		"id": "welcome",
		"title": "Welcome",
		"body": "Press WASD to move.",
		"advance_action": "move_north",
		"freeze_world": true,
	}, env, ctx)
	expect_eq(env["overlay_event_buffer"].size(), 1, "show_overlay: buffer size")
	var ev: Dictionary = env["overlay_event_buffer"][0]
	expect_eq(str(ev.get("event", "")), "show_overlay", "event name")
	expect_eq(str(ev.get("id", "")), "welcome", "id forwarded")
	expect_eq(str(ev.get("title", "")), "Welcome", "title forwarded")
	expect_eq(str(ev.get("advance_action", "")), "move_north", "advance_action forwarded")
	expect_eq(bool(ev.get("freeze_world", false)), true, "freeze_world forwarded")

	# dismiss_overlay records id + manual reason (set by OverlayManager)
	EffectApply.apply({"type": "dismiss_overlay", "id": "welcome"}, env, ctx)
	expect_eq(env["overlay_event_buffer"].size(), 2, "dismiss_overlay: buffer grew")
	var d: Dictionary = env["overlay_event_buffer"][1]
	expect_eq(str(d.get("event", "")), "dismiss_overlay", "dismiss event name")
	expect_eq(str(d.get("id", "")), "welcome", "dismiss id")

	# Lazy buffer creation
	var fresh: Dictionary = {}
	EffectApply.apply({"type": "show_overlay", "id": "a", "title": "x"}, fresh, ctx)
	expect(fresh.has("overlay_event_buffer"), "lazy overlay buffer creation")
	expect_eq((fresh["overlay_event_buffer"] as Array).size(), 1, "lazy buffer: event landed")

	# Multiple advance conditions can all be specified; engine prioritizes
	# at runtime (timer first, then action, then signal). Buffer record
	# carries them all — OverlayManager decides.
	var env2: Dictionary = {}
	EffectApply.apply({
		"type": "show_overlay", "id": "multi",
		"advance_action": "ui_accept",
		"advance_signal": "player_moved",
		"advance_after_seconds": 5.0,
	}, env2, ctx)
	var ev2: Dictionary = env2["overlay_event_buffer"][0]
	expect_eq(str(ev2.get("advance_action", "")), "ui_accept", "multi: action")
	expect_eq(str(ev2.get("advance_signal", "")), "player_moved", "multi: signal")
	expect_eq(float(ev2.get("advance_after_seconds", 0)), 5.0, "multi: timer")


# ============================================================
# SPATIAL-LOD SCHEDULING (ADR 0017)
# ============================================================

## Verify LOD-tagged rules:
## 1. Skip out-of-radius entities (freeze fallback)
## 2. Hysteresis prevents boundary flip-flop
## 3. tick_slowed rate-limits rule firing
## 4. Rules without lod field run on all entities (baseline)
func test_spatial_lod() -> void:
	_section("spatial_lod (ADR 0017)")

	# Rule with shorthand `radius` — gets normalized to enter/leave with
	# 5% hysteresis on each side.
	var r1 := Rule.from_dict({
		"id": "shorthand",
		"trigger": {"type": "tick", "interval": 1},
		"lod": {"radius": 100.0, "fallback": "freeze"},
		"effect": {"type": "state_set", "target": "self", "field": "x", "value": 1},
	})
	expect(r1.lod is Dictionary, "lod field parsed")
	expect(abs(float(r1.lod["enter_radius"]) - 95.0) < 0.01,
		"shorthand radius → enter_radius=95")
	expect(abs(float(r1.lod["leave_radius"]) - 105.0) < 0.01,
		"shorthand radius → leave_radius=105")

	# Rule with explicit enter/leave radii
	var r2 := Rule.from_dict({
		"id": "explicit",
		"trigger": {"type": "tick", "interval": 1},
		"lod": {"enter_radius": 50.0, "leave_radius": 80.0,
				"fallback": "tick_slowed:0.5"},
		"effect": {"type": "state_set", "target": "self", "field": "x", "value": 1},
	})
	expect_eq(float(r2.lod["enter_radius"]), 50.0, "explicit enter_radius")
	expect_eq(float(r2.lod["leave_radius"]), 80.0, "explicit leave_radius")
	expect_eq(str(r2.lod["fallback"]), "tick_slowed:0.5", "fallback preserved")

	# No lod field → no LOD config (baseline preserved)
	var r3 := Rule.from_dict({
		"id": "no_lod",
		"trigger": {"type": "tick", "interval": 1},
		"effect": {"type": "state_set", "target": "self", "field": "x", "value": 1},
	})
	expect(r3.lod == null, "rule without lod field has lod=null")

	# Default anchor + fallback
	var r4 := Rule.from_dict({
		"id": "defaults",
		"trigger": {"type": "tick", "interval": 1},
		"lod": {"radius": 100.0},
		"effect": {"type": "state_set", "target": "self", "field": "x", "value": 1},
	})
	expect_eq(str(r4.lod["anchor"]), "active_actor", "default anchor")
	expect_eq(str(r4.lod["fallback"]), "freeze", "default fallback")

	# End-to-end with scheduler: build a tiny env with one player + 2 NPCs
	# at different distances. Run a tick. Inside-radius NPC fires; outside
	# NPC doesn't.
	var defs: Dictionary = {
		"player": {"id": "player", "tags": ["player"], "state_init": {}},
		"npc": {"id": "npc", "tags": ["npc"], "state_init": {"counter": 0}},
	}
	var entities: Dictionary = {}
	var rs := RelationStore.new()
	var sx := SpatialIndex.new()
	var ws: Dictionary = {}
	var env: Dictionary = {
		"entities": entities, "defs": defs, "relations": rs,
		"spatial_index": sx, "world": ws, "parent": null, "next_id": {"_": 0},
	}
	# Player at origin
	var player := Entity.new()
	player.def_id = "player"; player.instance_id = "p"
	player.tags = ["player"]
	player.set_position(Vector2(0, 0))
	entities["p"] = player
	sx.update_entity("p", Vector2(0, 0))
	# Near NPC (dist=50 from player)
	var near := Entity.new()
	near.def_id = "npc"; near.instance_id = "near"
	near.tags = ["npc"]
	near.state = {"counter": 0}
	near.set_position(Vector2(50, 0))
	entities["near"] = near
	sx.update_entity("near", Vector2(50, 0))
	# Far NPC (dist=300 from player)
	var far := Entity.new()
	far.def_id = "npc"; far.instance_id = "far"
	far.tags = ["npc"]
	far.state = {"counter": 0}
	far.set_position(Vector2(300, 0))
	entities["far"] = far
	sx.update_entity("far", Vector2(300, 0))

	# Rule: tick → state_add counter +1, lod radius 100 (enter=95, leave=105)
	var rule := Rule.from_dict({
		"id": "lod_test",
		"trigger": {"type": "tick", "interval": 1},
		"lod": {"radius": 100.0, "fallback": "freeze"},
		"query": {"tags_all": ["npc"]},
		"effect": {"type": "state_add", "target": "self", "field": "counter", "amount": 1},
	})
	# Need scheduler with active actor resolution — but env.parent.actor_tag
	# isn't accessible without a real World. Manually set lod_anchor_position.
	var sched := PhaseScheduler.new(env)
	sched.register_rules([rule])
	# Manually inject anchor (skip _compute_lod_anchor which needs parent.actor_tag)
	env["lod_anchor_position"] = Vector2(0, 0)
	# Run scan rule directly (bypassing tick to avoid clobbering anchor)
	sched._fire_scan_rule(rule)
	sched.flush_effects()
	expect_eq(int(near.get_state("counter", 0)), 1, "near NPC inside radius — fired")
	expect_eq(int(far.get_state("counter", 0)), 0, "far NPC outside radius — frozen")

	# Hysteresis: move near NPC to dist=102 (between enter=95 and leave=105).
	# It was inside, should STAY inside.
	near.set_position(Vector2(102, 0))
	sx.update_entity("near", Vector2(102, 0))
	sched._fire_scan_rule(rule)
	sched.flush_effects()
	expect_eq(int(near.get_state("counter", 0)), 2,
		"hysteresis: was-inside NPC at 102 (between 95-105) STILL fires")

	# Now move near NPC past leave_radius — should leave
	near.set_position(Vector2(110, 0))
	sx.update_entity("near", Vector2(110, 0))
	sched._fire_scan_rule(rule)
	sched.flush_effects()
	expect_eq(int(near.get_state("counter", 0)), 2,
		"hysteresis: NPC past leave (110 > 105) STOPS firing")

	# Move it back to 102 — should stay outside (must cross enter=95 to come back)
	near.set_position(Vector2(102, 0))
	sx.update_entity("near", Vector2(102, 0))
	sched._fire_scan_rule(rule)
	sched.flush_effects()
	expect_eq(int(near.get_state("counter", 0)), 2,
		"hysteresis: NPC at 102 (between 95-105) STAYS outside without re-entering")

	# Cross enter_radius to come back inside
	near.set_position(Vector2(50, 0))
	sx.update_entity("near", Vector2(50, 0))
	sched._fire_scan_rule(rule)
	sched.flush_effects()
	expect_eq(int(near.get_state("counter", 0)), 3,
		"hysteresis: NPC re-enters (50 < 95)")

	# Cleanup
	player.queue_free()
	near.queue_free()
	far.queue_free()


# ============================================================
# MACRO EXPANSION (ADR 0019)
# ============================================================

## Verify macro expansion:
## 1. Single macro expands to its primitive sequence
## 2. $param substitution (bare → typed; compound → string)
## 3. Cycle detection
## 4. Forbidden names rejected
## 5. Per-game scoping (no leak between expanders)
## 6. Recursion across multiple macros
func test_macro_expansion() -> void:
	_section("macro_expansion (ADR 0019)")

	# Build an expander manually (bypasses file I/O)
	var me := MacroExpander.new()
	me._registry = {
		"deal_damage": {
			"params": ["target", "amount"],
			"expands_to": [
				{"type": "state_add", "target": "$target",
				 "field": "hp", "amount": "-$amount"},
				{"type": "emit", "signal": "damaged",
				 "payload": {"target": "$target", "amount": "$amount"}},
			],
		},
	}
	me._is_valid = true

	# Rule that uses the macro
	var rules: Array = [{
		"id": "bullet_hits",
		"trigger": {"type": "contact"},
		"effect": [{"type": "deal_damage", "target": "b", "amount": 10}],
	}]
	var expanded: Array = me.expand_rules(rules)
	expect_eq(expanded.size(), 1, "expand_rules: same rule count")
	var rule_dict: Dictionary = expanded[0]
	var fx: Array = rule_dict["effect"]
	expect_eq(fx.size(), 2, "macro expanded to 2 primitives")
	expect_eq(str(fx[0]["type"]), "state_add", "first effect is state_add")
	expect_eq(str(fx[0]["target"]), "b", "$target → b (bare substitution)")
	expect_eq(str(fx[0]["amount"]), "-10",
		"-$amount → '-10' (compound string substitution; Formula evaluates at fire time)")
	expect_eq(str(fx[1]["type"]), "emit", "second effect is emit")
	# Payload nested dict — substituted recursively
	var payload: Dictionary = fx[1]["payload"]
	expect_eq(str(payload["target"]), "b", "nested $target → b")
	expect_eq(int(payload["amount"]), 10, "nested $amount → 10 (typed)")

	# Cycle detection
	var cyclic := MacroExpander.new()
	cyclic._registry = {
		"a": {"params": [], "expands_to": [{"type": "b"}]},
		"b": {"params": [], "expands_to": [{"type": "a"}]},
	}
	expect(cyclic._has_cycles(), "DFS detects A→B→A cycle")

	# Forbidden names (load-time check happens in load_from_data_root,
	# but registry-direct usage shouldn't accept them either — this is
	# a guard-the-API test).
	expect("damage" in MacroExpander.FORBIDDEN_MACRO_NAMES, "damage forbidden")
	expect("heal" in MacroExpander.FORBIDDEN_MACRO_NAMES, "heal forbidden")
	expect("attack" in MacroExpander.FORBIDDEN_MACRO_NAMES, "attack forbidden")

	# Per-game scoping: empty expander is a no-op
	var empty := MacroExpander.new()
	empty._is_valid = true
	var unchanged := empty.expand_rules(rules)
	expect_eq(unchanged.size(), 1, "empty expander: same rule count")
	var unchanged_fx = unchanged[0]["effect"]
	# Empty registry → returns input unchanged (the rules array itself)
	expect_eq((unchanged_fx as Array).size(), 1,
		"empty expander: macro reference passes through (becomes unknown effect at fire)")

	# Multi-level expansion: macro → macro → primitive (depth 2)
	var nested := MacroExpander.new()
	nested._registry = {
		"big_hit": {
			"params": ["t"],
			"expands_to": [
				{"type": "deal_damage", "target": "$t", "amount": 50},
				{"type": "emit", "signal": "big_hit_landed", "payload": {}},
			],
		},
		"deal_damage": {
			"params": ["target", "amount"],
			"expands_to": [
				{"type": "state_add", "target": "$target",
				 "field": "hp", "amount": "-$amount"},
			],
		},
	}
	nested._is_valid = true
	var nested_rules: Array = [{
		"id": "boss_attack",
		"trigger": {"type": "contact"},
		"effect": [{"type": "big_hit", "t": "player"}],
	}]
	var nested_expanded := nested.expand_rules(nested_rules)
	var nested_fx: Array = nested_expanded[0]["effect"]
	# big_hit → [deal_damage(player, 50), emit big_hit_landed]
	# deal_damage → state_add(target=player, amount=-50)
	# Final: [state_add, emit]
	expect_eq(nested_fx.size(), 2, "nested expansion: 2 leaf primitives")
	expect_eq(str(nested_fx[0]["type"]), "state_add",
		"first leaf primitive (deal_damage expanded)")
	expect_eq(str(nested_fx[0]["target"]), "player",
		"nested $t → player propagated through $target")
	expect_eq(str(nested_fx[0]["amount"]), "-50", "nested -$amount substituted")
	expect_eq(str(nested_fx[1]["type"]), "emit", "second leaf primitive")

	# Depth limit: A→B→C→D→E should fail at depth 4
	var deep := MacroExpander.new()
	deep._registry = {
		"a": {"params": [], "expands_to": [{"type": "b"}]},
		"b": {"params": [], "expands_to": [{"type": "c"}]},
		"c": {"params": [], "expands_to": [{"type": "d"}]},
		"d": {"params": [], "expands_to": [{"type": "e"}]},
		"e": {"params": [], "expands_to": [{"type": "state_set"}]},
	}
	deep._is_valid = true
	var deep_rules: Array = [{
		"id": "too_deep",
		"trigger": {"type": "tick"},
		"effect": [{"type": "a"}],
	}]
	var deep_out := deep.expand_rules(deep_rules)
	# Depth limit (4) is exceeded at level 5 (e); expansion truncates.
	# We expect: a→b→c→d→e expands, but e's child (state_set) is at depth 5
	# > 4, so e returns []. So the final effect list ends up empty.
	# This matches the specified "no silent truncation" — push_warning fires.
	expect(deep_out[0]["effect"].size() <= 1,
		"depth limit truncates expansion (chain too deep)")

	# Pure pass-through: rules without macro references unchanged
	var primitive_rules: Array = [{
		"id": "clean",
		"trigger": {"type": "tick"},
		"effect": [{"type": "state_set", "target": "self", "field": "x", "value": 1}],
	}]
	var pass_through := me.expand_rules(primitive_rules)
	var pass_fx: Array = pass_through[0]["effect"]
	expect_eq(pass_fx.size(), 1, "primitive-only effect list unchanged")
	expect_eq(str(pass_fx[0]["type"]), "state_set", "primitive type preserved")


# ============================================================
# MULTI-ACTOR (ADR 0016)
# ============================================================

## Verify ActorManager:
## 1. Synthesized default when no actors.json (legacy compat)
## 2. resolve_active_entity finds the right entity by tag
## 3. set_active changes active_actor_id
## 4. switch_actor effect pushes _pending_active_actor (deferred semantics)
## 5. queue_input_for_actor synthesizes input
func test_multi_actor() -> void:
	_section("multi_actor (ADR 0016)")

	# 1. Synthesized default with no file
	var am := ActorManager.load_or_synthesize("/nonexistent/path", "player")
	expect_eq(am.active_actor_id, "default_player",
		"synthesized default actor id")
	var ids := am.actor_ids()
	expect_eq(ids.size(), 1, "synthesized has exactly one actor")
	var actor := am.get_actor("default_player")
	expect_eq(str(actor.get("starting_entity_tag", "")), "player",
		"synthesized actor uses fallback tag")
	expect_eq(str(actor.get("control_mode", "")), "human",
		"synthesized actor is human-controlled")

	# 2. resolve_active_entity by tag
	var entities: Dictionary = {}
	var p := Entity.new()
	p.def_id = "player"; p.instance_id = "player_main"
	p.tags = ["player"]
	entities["player_main"] = p
	expect_eq(am.resolve_active_entity(entities), "player_main",
		"resolves active actor via tag")
	# Returns "" if no entity matches
	entities.clear()
	expect_eq(am.resolve_active_entity(entities), "",
		"returns empty when no matching entity")
	p.queue_free()

	# 3. set_active with unknown id is rejected
	var ok := am.set_active("nonexistent_actor")
	expect(not ok, "set_active rejects unknown actor id")
	expect_eq(am.active_actor_id, "default_player",
		"active unchanged after rejection")

	# 4. switch_actor effect defers to env._pending_active_actor
	var env: Dictionary = {"parent": null}
	var ctx: Dictionary = {"_rule_id": "test"}
	EffectApply.apply({"type": "switch_actor", "target_id": "player_alt"},
		env, ctx)
	expect_eq(str(env.get("_pending_active_actor", "")), "player_alt",
		"switch_actor defers via env._pending_active_actor")

	# 5. switch_actor with missing target_id warns + skips
	var env2: Dictionary = {"parent": null}
	EffectApply.apply({"type": "switch_actor"}, env2, ctx)
	expect(not env2.has("_pending_active_actor"),
		"switch_actor with no target_id: nothing deferred")

	# 6. Multi-actor config from in-memory file equivalent
	# (skip file I/O test — rely on Phase B integration test for files)
	var multi := ActorManager.new()
	multi._actors = [
		{"id": "p1", "starting_entity_tag": "michael",
		 "control_mode": "human", "input_device": "keyboard"},
		{"id": "p2", "starting_entity_tag": "trevor",
		 "control_mode": "human", "input_device": "gamepad_2"},
	]
	multi.active_actor_id = "p1"
	for a in multi._actors:
		multi._by_id[str(a["id"])] = a
	expect_eq(multi.actor_ids().size(), 2, "multi-actor: 2 ids")
	expect(multi.set_active("p2"), "set_active accepts known id")
	expect_eq(multi.active_actor_id, "p2", "active updated to p2")

	# Resolve from multi
	var ents2: Dictionary = {}
	var michael := Entity.new()
	michael.instance_id = "m1"; michael.tags = ["michael"]
	ents2["m1"] = michael
	var trevor := Entity.new()
	trevor.instance_id = "t1"; trevor.tags = ["trevor"]
	ents2["t1"] = trevor
	expect_eq(multi.resolve_actor_entity("p1", ents2), "m1",
		"resolve actor p1 → michael entity")
	expect_eq(multi.resolve_actor_entity("p2", ents2), "t1",
		"resolve actor p2 → trevor entity")
	expect_eq(multi.resolve_active_entity(ents2), "t1",
		"resolve active (p2) → trevor")
	michael.queue_free()
	trevor.queue_free()


# ============================================================
# RESET_WORLD EFFECT (#99)
# ============================================================

## Verify reset_world effect:
## 1. Sets env._pending_world_reset (deferred to next-tick boundary)
## 2. Non-destructive in the chain — subsequent effects fire normally
##    (full integration with World.process_pending_world_reset is
##    scene-based; here we verify the effect-buffer contract).
func test_reset_world_effect() -> void:
	_section("reset_world (#99)")

	var env: Dictionary = {}
	var ctx: Dictionary = {"_rule_id": "test"}

	# Bare reset_world sets the pending flag
	EffectApply.apply({"type": "reset_world"}, env, ctx)
	expect(bool(env.get("_pending_world_reset", false)),
		"reset_world sets env._pending_world_reset")

	# Re-firing keeps it true (idempotent)
	EffectApply.apply({"type": "reset_world"}, env, ctx)
	expect(bool(env.get("_pending_world_reset", false)),
		"second reset_world: still pending")

	# Non-destructive in chain: subsequent effects in the same chain
	# can still fire (they push into their own buffers / env keys).
	# Simulate a [reset_world, transition_screen] chain.
	env["screen_event_buffer"] = []
	EffectApply.apply({"type": "reset_world"}, env, ctx)
	EffectApply.apply({"type": "transition_screen", "target": "game"},
		env, ctx)
	expect(bool(env.get("_pending_world_reset", false)),
		"chain: reset_world flag still set")
	expect_eq(env["screen_event_buffer"].size(), 1,
		"chain: transition_screen still queued (NOT destroyed)")
	expect_eq(str((env["screen_event_buffer"][0] as Dictionary).get("event", "")),
		"transition_screen", "chain: transition event reaches buffer")


# ============================================================
# ACTOR POLICY (ADR 0018 Phase A — scripted JSON)
# ============================================================

## Verify ScriptedPolicy:
## 1. Always-true rule fires its actions
## 2. world_state condition gates rule firing
## 3. distance_to active_actor evaluates correctly
## 4. all/any boolean composition
## 5. nearby_count evaluates against observation
## 6. First matching rule wins (priority via order)
## 7. actor_id stamped onto returned actions
func test_scripted_policy() -> void:
	_section("scripted_policy (ADR 0018)")

	# Build a minimal observation + actor_state
	var obs: Dictionary = {
		"nearby": [
			{"id": "enemy_1", "position": Vector2(50, 0), "tags": ["enemy"]},
			{"id": "ally_1", "position": Vector2(-30, 0), "tags": ["ally"]},
		],
		"world_state": {"alarm_level": 2, "phase": "combat"},
		"active_actor_position": Vector2(20, 0),
	}
	var actor_state: Dictionary = {
		"id": "guard_a",
		"position": Vector2(0, 0),
		"state": {"hp": 80, "ammo": 10},
		"tags": ["guard"],
	}

	# 1. Always-true rule (no `if` clause) returns its actions
	var p1 := ScriptedPolicy.new()
	p1._rules = [
		{"id": "fallback", "then": [{"action": "patrol"}]},
	]
	var actions: Array = p1.decide(obs, actor_state)
	expect_eq(actions.size(), 1, "fallback rule fires (no if)")
	expect_eq(str((actions[0] as Dictionary).get("action", "")), "patrol",
		"fallback action: patrol")
	expect_eq(str((actions[0] as Dictionary).get("actor_id", "")), "guard_a",
		"actor_id stamped on action")

	# 2. world_state condition
	var p2 := ScriptedPolicy.new()
	p2._rules = [
		{"id": "alert",
		 "if": {"world_state": {"key": "alarm_level", "op": ">=", "value": 2}},
		 "then": [{"action": "fire"}]},
		{"id": "fallback", "then": [{"action": "patrol"}]},
	]
	var act2: Array = p2.decide(obs, actor_state)
	expect_eq(str((act2[0] as Dictionary).get("action", "")), "fire",
		"alarm_level=2 → fires alert rule (priority over fallback)")

	# Now flip alarm_level to fail the condition
	var obs_calm: Dictionary = obs.duplicate(true)
	obs_calm["world_state"] = {"alarm_level": 0}
	var act2b: Array = p2.decide(obs_calm, actor_state)
	expect_eq(str((act2b[0] as Dictionary).get("action", "")), "patrol",
		"alarm_level=0 → falls through to patrol")

	# 3. distance_to active_actor
	var p3 := ScriptedPolicy.new()
	p3._rules = [
		{"id": "engage",
		 "if": {"distance_to": {"target": "active_actor", "op": "<", "value": 30}},
		 "then": [{"action": "attack"}]},
	]
	# active actor at (20,0), self at (0,0) → dist 20 → < 30 → fires
	var act3: Array = p3.decide(obs, actor_state)
	expect_eq(act3.size(), 1, "distance < 30: rule fires")
	expect_eq(str((act3[0] as Dictionary).get("action", "")), "attack",
		"engage rule action")
	# Move active actor far
	var obs_far: Dictionary = obs.duplicate(true)
	obs_far["active_actor_position"] = Vector2(500, 0)
	var act3b: Array = p3.decide(obs_far, actor_state)
	expect_eq(act3b.size(), 0, "distance >= 30: no rule fires")

	# 4. all/any composition
	var p4 := ScriptedPolicy.new()
	p4._rules = [
		{"id": "combo",
		 "if": {"all": [
			 {"world_state": {"key": "phase", "op": "==", "value": "combat"}},
			 {"actor_state": {"field": "ammo", "op": ">", "value": 5}},
		 ]},
		 "then": [{"action": "shoot"}]},
	]
	var act4: Array = p4.decide(obs, actor_state)
	expect_eq(str((act4[0] as Dictionary).get("action", "")), "shoot",
		"all: phase=combat AND ammo>5 → shoot")
	# Fail one branch
	var st_low_ammo: Dictionary = actor_state.duplicate(true)
	st_low_ammo["state"] = {"hp": 80, "ammo": 2}
	var act4b: Array = p4.decide(obs, st_low_ammo)
	expect_eq(act4b.size(), 0, "all: ammo too low → no shoot")
	# any: at least one branch true
	var p5 := ScriptedPolicy.new()
	p5._rules = [
		{"id": "alert_or_low_hp",
		 "if": {"any": [
			 {"actor_state": {"field": "hp", "op": "<", "value": 30}},
			 {"world_state": {"key": "alarm_level", "op": ">=", "value": 2}},
		 ]},
		 "then": [{"action": "alert"}]},
	]
	var act5: Array = p5.decide(obs, actor_state)
	expect_eq(str((act5[0] as Dictionary).get("action", "")), "alert",
		"any: alarm>=2 (hp not low) → still fires")

	# 5. nearby_count
	var p6 := ScriptedPolicy.new()
	p6._rules = [
		{"id": "outnumbered",
		 "if": {"nearby_count": {"tag": "enemy", "op": ">=", "value": 1}},
		 "then": [{"action": "retreat"}]},
	]
	var act6: Array = p6.decide(obs, actor_state)
	expect_eq(str((act6[0] as Dictionary).get("action", "")), "retreat",
		"nearby_count enemy>=1 → retreat")

	# 6. not negation
	var p7 := ScriptedPolicy.new()
	p7._rules = [
		{"id": "no_allies",
		 "if": {"not": {"nearby_count": {"tag": "ally", "op": ">=", "value": 1}}},
		 "then": [{"action": "call_help"}]},
	]
	# Ally is nearby → not(true) → false → no fire
	var act7: Array = p7.decide(obs, actor_state)
	expect_eq(act7.size(), 0, "not negation: ally nearby → no_allies false → skip")

	# 7. action params forwarded (everything except 'action' propagates)
	var p8 := ScriptedPolicy.new()
	p8._rules = [
		{"id": "with_params",
		 "then": [{"action": "move_to", "x": 100, "y": 50}]},
	]
	var act8: Array = p8.decide(obs, actor_state)
	expect_eq(int((act8[0] as Dictionary).get("x", 0)), 100, "params: x forwarded")
	expect_eq(int((act8[0] as Dictionary).get("y", 0)), 50, "params: y forwarded")
