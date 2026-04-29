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
	expect_eq(t.position, Vector2(3, 4), "position override")
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
	var t1 := Entity.create(defs.tree, "t1"); t1.position = Vector2(0, 0); t1.set_state("wet", 0.1)
	var t2 := Entity.create(defs.tree, "t2"); t2.position = Vector2(2, 0); t2.set_state("wet", 0.8)
	var f1 := Entity.create(defs.fire, "f1"); f1.position = Vector2(0.5, 0)
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
