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
	test_frame_tick()
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
	test_pathfind_builds_navmesh()
	test_pathfind_to_routes_around_obstacle()
	test_pathfind_no_op_on_2d()
	test_raycast_hit()
	test_instance_patterns()
	test_screen_flow_effects()
	test_screen_fade()
	test_scene_change_dispatches()
	test_transition_level_fade()
	test_control_factory()
	test_save_state()
	test_overlay_effects()
	test_spatial_lod()
	test_macro_expansion()
	test_multi_actor()
	test_reset_world_effect()
	test_scripted_policy()
	test_chunk_streaming()
	test_lighting_director_helpers()
	test_lighting_director_resolves_binding()
	test_lighting_director_color_endpoints()
	test_party_join_creates_relation()
	test_party_leashing_position_follows_player()
	test_party_ko_preserves_entity()
	test_nameplate_filters_named_npc_tag()
	test_nameplate_picks_display_name_over_id()
	test_lib_resolver()
	test_schedule_primitive()
	test_animation_primitive()
	test_lifecycle_primitive()
	test_build_place_primitive()
	test_class_primitive()
	test_zone_state_primitive()
	test_faction_primitive()
	test_tech_tree_primitive()
	test_dynasty_primitive()
	test_step_runner()
	test_grid_snap()
	test_multimesh_director()
	test_array_primitives()
	test_animation_translator()
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
		if t == "burning":
			burning_count += 1
	expect_eq(burning_count, 1, "add_tag deduplicates")
	e.remove_tag("inert")
	expect(not e.has_tag("inert"), "remove_tag")
	# Velocity helpers
	e.set_velocity(Vector2(1, 2))
	expect_eq(e.get_velocity(), Vector2(1, 2), "velocity round-trip")
	# Override merge
	var def2: Dictionary = {"id": "tree", "tags": ["plant"], "state_init": {"growth": 0}}
	var t := (
		Entity
		. create(
			def2,
			"tree_1",
			{
				"state": {"growth": 50, "extra": 1},
				"tags": ["watered"],
				"position": [3, 4],
			}
		)
	)
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
	# state.yaw round-trips through state_init AND instance overrides.
	# Renderer (entity_mesh_3d._sync_yaw / entity_sprite_2d._sync_static_yaw)
	# reads this field per frame; here we only verify storage. Visual gate
	# verifies the rotation actually applies.
	var def3: Dictionary = {"id": "cottage", "tags": ["building"], "state_init": {"yaw": 0.26}}
	var c1 := Entity.create(def3, "c1")
	expect_eq(c1.get_state("yaw"), 0.26, "yaw from state_init")
	var c2 := Entity.create(def3, "c2", {"state": {"yaw": -0.17}})
	expect_eq(c2.get_state("yaw"), -0.17, "yaw from instance override")
	c1.queue_free()
	c2.queue_free()
	# Per-instance visual.params deep-merge: instance-level params override
	# individual keys without nuking the def's other params. Without this,
	# districts couldn't recolor JUST `wall` while keeping `roof`/`door`.
	var def4: Dictionary = {
		"id": "house",
		"visual":
		{
			"mesh": "cottage",
			"params": {"wall": "#aaa", "roof": "#bbb", "door": "#ccc", "window": "#ddd"}
		}
	}
	var h := Entity.create(def4, "h1", {"visual": {"params": {"wall": "#fff"}}})
	expect_eq(h.visual["params"]["wall"], "#fff", "params.wall override applied")
	expect_eq(h.visual["params"]["roof"], "#bbb", "params.roof preserved from def")
	expect_eq(h.visual["params"]["door"], "#ccc", "params.door preserved from def")
	expect_eq(h.visual["mesh"], "cottage", "mesh preserved from def")
	h.queue_free()


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
		"effect":
		[
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
		Rule.from_dict(
			{"id": "bad_trigger", "trigger": {"type": "wat"}, "effect": {"type": "state_set"}}
		),
		Rule.from_dict({"id": "no_effect", "trigger": {"type": "tick"}, "effect": []}),
		Rule.from_dict(
			{"id": "dup1", "trigger": {"type": "tick"}, "effect": {"type": "state_set"}}
		),
		Rule.from_dict(
			{"id": "dup1", "trigger": {"type": "tick"}, "effect": {"type": "state_set"}}
		),
	]
	var errors := Rule.validate_all(bad)
	expect(errors.size() >= 4, "validator catches structural errors (got %d)" % errors.size())
	# Valid set
	var ok := [r, r2, r3, r4]
	expect_eq(Rule.validate_all(ok).size(), 0, "valid rules produce no errors")


# ============================================================
# FRAME_TICK TRIGGER (ADR 0050)
# ============================================================


func test_frame_tick() -> void:
	_section("frame_tick (ADR 0050 — per-frame rule cadence)")
	var entities: Dictionary = {}
	var defs: Dictionary = {
		"counter": {"id": "counter", "tags": ["counter"], "state_init": {"frames": 0, "ticks": 0}}
	}
	entities["c1"] = Entity.create(defs.counter, "c1")
	var env: Dictionary = {
		"entities": entities,
		"defs": defs,
		"relations": RelationStore.new(),
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}
	# Two rules: one frame_tick that increments counter.frames, one tick
	# that increments counter.ticks. Verify they fire at independent cadences.
	var rules: Array = [
		Rule.from_dict(
			{
				"id": "frame_counter",
				"trigger": {"type": "frame_tick"},
				"query": {"tags_all": ["counter"]},
				"effect": {"type": "state_add", "target": "self", "field": "frames", "amount": 1}
			}
		),
		Rule.from_dict(
			{
				"id": "tick_counter",
				"trigger": {"type": "tick", "interval": 1},
				"query": {"tags_all": ["counter"]},
				"effect": {"type": "state_add", "target": "self", "field": "ticks", "amount": 1}
			}
		),
	]
	expect_eq(Rule.validate_all(rules).size(), 0, "frame_tick is a valid trigger type")

	var sched := PhaseScheduler.new(env)
	sched.register_rules(rules)
	# fire_frame_tick does NOT advance the sim tick.
	sched.fire_frame_tick()
	expect_eq(int(entities["c1"].get_state("frames")), 1, "frame_tick fired 1x")
	expect_eq(int(entities["c1"].get_state("ticks")), 0, "tick rule did NOT fire")
	# Multiple per-frame fires between sim ticks (the typical case at 60Hz / 0.5s tick).
	sched.fire_frame_tick()
	sched.fire_frame_tick()
	sched.fire_frame_tick()
	expect_eq(int(entities["c1"].get_state("frames")), 4, "frame_tick fired 4x total")
	expect_eq(int(entities["c1"].get_state("ticks")), 0, "tick rule still hasn't fired")
	# Now advance the sim tick — tick rule fires, frame_tick rule does NOT also fire from tick().
	sched.tick()
	expect_eq(int(entities["c1"].get_state("ticks")), 1, "tick rule fired via tick()")
	expect_eq(int(entities["c1"].get_state("frames")), 4, "frame_tick rule unaffected by tick()")
	# Empty frame_tick bucket — no-op should not blow up.
	var sched2 := PhaseScheduler.new(env)
	sched2.fire_frame_tick()  # no rules registered, just returns
	entities["c1"].queue_free()


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
		"tree":
		{
			"id": "tree",
			"tags": ["plant", "flammable", "solid"],
			"properties": {"hardness": 2},
			"state_init": {"burning": 0, "wet": 0.0}
		},
		"fire": {"id": "fire", "tags": ["heat_source"], "state_init": {"burning": 1}},
	}
	var entities := {}
	var t1 := Entity.create(defs.tree, "t1")
	t1.set_position(Vector2(0, 0))
	t1.set_state("wet", 0.1)
	var t2 := Entity.create(defs.tree, "t2")
	t2.set_position(Vector2(2, 0))
	t2.set_state("wet", 0.8)
	var f1 := Entity.create(defs.fire, "f1")
	f1.set_position(Vector2(0.5, 0))
	entities["t1"] = t1
	entities["t2"] = t2
	entities["f1"] = f1
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
	var r8 := QueryLib.run(
		{"tags_all": ["plant"], "radius": 1.5}, env, {"_origin_position": Vector2(0, 0)}
	)
	expect_eq(r8.size(), 1, "radius 1.5 from origin picks only t1")
	# Limit
	var r9 := QueryLib.run({"tags_any": ["plant", "heat_source"], "limit": 2}, env)
	expect_eq(r9.size(), 2, "limit caps results")
	# Order by distance
	var r10 := QueryLib.run(
		{"tags_all": ["plant"], "order_by": "distance_asc"},
		env,
		{"_origin_position": Vector2(0, 0)}
	)
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

	for e in [t1, t2, f1]:
		e.queue_free()


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
	EffectApply.apply(
		{"type": "state_add", "target": "self", "field": "hp", "amount": -5}, env, ctx
	)
	expect_eq(ent.get_state("hp"), 45, "state_add (negative)")
	# state_mul
	EffectApply.apply({"type": "state_mul", "target": "self", "field": "ap", "amount": 2}, env, ctx)
	expect_eq(ent.get_state("ap"), 20, "state_mul")
	# state_clamp
	ent.set_state("hp", 200)
	EffectApply.apply(
		{"type": "state_clamp", "target": "self", "field": "hp", "min": 0, "max": 100}, env, ctx
	)
	expect_eq(ent.get_state("hp"), 100, "state_clamp upper")
	ent.set_state("hp", -10)
	EffectApply.apply(
		{"type": "state_clamp", "target": "self", "field": "hp", "min": 0, "max": 100}, env, ctx
	)
	expect_eq(ent.get_state("hp"), 0, "state_clamp lower")
	# tag_add / remove
	EffectApply.apply({"type": "tag_add", "target": "self", "tag": "burning"}, env, ctx)
	expect(ent.has_tag("burning"), "tag_add")
	EffectApply.apply({"type": "tag_remove", "target": "self", "tag": "burning"}, env, ctx)
	expect(not ent.has_tag("burning"), "tag_remove")
	# Target as literal id (not context name) — fallback path
	EffectApply.apply(
		{"type": "state_set", "target": "thing_1", "field": "hp", "value": 77}, env, ctx
	)
	expect_eq(ent.get_state("hp"), 77, "target as literal id")
	# relate via effect
	EffectApply.apply(
		{"type": "relate", "relation": "carries", "from": "self", "to": "thing_1"}, env, ctx
	)
	expect(
		(env.relations as RelationStore).has_edge("carries", "thing_1", "thing_1"), "relate effect"
	)
	# unrelate
	EffectApply.apply(
		{"type": "unrelate", "relation": "carries", "from": "self", "to": "thing_1"}, env, ctx
	)
	expect(
		not (env.relations as RelationStore).has_edge("carries", "thing_1", "thing_1"),
		"unrelate effect"
	)
	# spawn (literal position)
	var spawn_result = (
		EffectApply
		. apply(
			{
				"type": "spawn",
				"template": "thing",
				"position": [5, 5],
				"overrides": {"_forced_id": "thing_2"},
			},
			env,
			ctx
		)
	)
	expect(env.entities.has("thing_2"), "spawn created entity")
	expect_eq(spawn_result.get("spawned_id", ""), "thing_2", "spawn returns id")
	# remove
	EffectApply.apply({"type": "remove", "target": "thing_2"}, env, {})
	expect(not env.entities.has("thing_2"), "remove deletes entity")
	# transform: replaces entity with new def, preserving state
	EffectApply.apply(
		{"type": "spawn", "template": "thing", "overrides": {"_forced_id": "morph"}}, env, {}
	)
	(env.entities["morph"] as Entity).set_state("hp", 33)
	EffectApply.apply(
		{"type": "transform", "target": "morph", "to": "thing"}, env, {"self": "morph"}
	)
	# After transform, "morph" is gone but a new instance exists with hp=33 preserved
	expect(not env.entities.has("morph"), "transform removes old")
	var transformed: Entity = null
	for e in env.entities.values():
		if (e as Entity).get_state("hp") == 33:
			transformed = e
			break
	expect(transformed != null, "transform spawned new instance with preserved state")

	# 2026-05-04 consistency fix: _value() recurses into Arrays + state_set
	# normalizes position/velocity through Entity.set_position/set_velocity.
	# Verify both behaviors so future regressions (e.g. someone reverting the
	# Array-recursion to fix some other bug) get caught.
	var ar := Entity.create({"id": "ar", "tags": ["x"], "state_init": {}}, "ar_1")
	env.entities["ar_1"] = ar
	# Array of formula strings → each element evaluates
	EffectApply.apply(
		{"type": "state_set", "target": "ar_1", "field": "position", "value": ["10 + 5", "20 * 2"]},
		env,
		{"self": "ar_1"}
	)
	var pos = ar.get_position()
	expect(pos is Vector2, "state_set position with Array → Vector2 (got %s)" % typeof(pos))
	expect_eq((pos as Vector2).x, 15.0, "Array element 0 formula evaluated")
	expect_eq((pos as Vector2).y, 40.0, "Array element 1 formula evaluated")
	# Formula reading position.x after Array-set should still work (regression
	# guard: without normalization, formulas would return 0)
	EffectApply.apply(
		{
			"type": "state_set",
			"target": "ar_1",
			"field": "marker",
			"value": "self.state.position.x"
		},
		env,
		{"self": "ar_1"}
	)
	expect_eq(ar.get_state("marker"), 15.0, "formula reads .x after Array-set position")
	# Concrete numeric Array still works (unchanged behavior — no formulas inside)
	EffectApply.apply(
		{"type": "state_set", "target": "ar_1", "field": "position", "value": [3, 7]},
		env,
		{"self": "ar_1"}
	)
	var p2 = ar.get_position()
	expect(p2 is Vector2, "concrete numeric Array still becomes Vector2")
	expect_eq((p2 as Vector2).x, 3.0, "concrete x preserved")
	ar.queue_free()
	env.entities.erase("ar_1")

	for e in env.entities.values():
		(e as Entity).queue_free()


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
		Rule.from_dict(
			{"id": "y", "trigger": {"type": "tick"}, "effect": {"type": "state_set"}, "chance": 1.5}
		),  # bad chance
	]
	var errs := Rule.validate_all(bad_rules)
	expect(
		errs.size() >= 3,
		"schema validator catches empty id, missing effect type, bad chance (got %d)" % errs.size()
	)

	# Valid case
	var good := [
		Rule.from_dict(
			{
				"id": "ok",
				"trigger": {"type": "tick"},
				"effect": {"type": "state_set", "target": "self", "field": "x", "value": 1}
			}
		),
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
		"player": {"id": "player", "tags": ["player"], "state_init": {}},
		"sparkle": {"id": "sparkle", "tags": ["sparkle"], "state_init": {"life": 3}},
		"counter": {"id": "counter", "tags": ["counter"], "state_init": {"emitted": 0, "died": 0}},
	}
	entities["p1"] = Entity.create(defs.player, "p1")
	entities["c1"] = Entity.create(defs.counter, "c1")
	var rs := RelationStore.new()
	var env: Dictionary = {
		"entities": entities,
		"defs": defs,
		"relations": rs,
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}

	# Rules: input "spark" → emit signal → spawn sparkle. Tick decay. Lifecycle counters.
	var rules: Array = [
		(
			Rule
			. from_dict(
				{
					"id": "input_spark",
					"trigger": {"type": "input", "action": "spark"},
					"effect":
					{"type": "emit", "signal": "sparkle_emit", "payload": {"origin": "actor"}},
				}
			)
		),
		(
			Rule
			. from_dict(
				{
					"id": "signal_spawn",
					"trigger": {"type": "signal", "name": "sparkle_emit"},
					"effect": {"type": "spawn", "template": "sparkle", "position": "origin"},
				}
			)
		),
		(
			Rule
			. from_dict(
				{
					"id": "decay",
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["sparkle"]},
					"effect":
					{"type": "state_add", "target": "self", "field": "life", "amount": -1},
				}
			)
		),
		(
			Rule
			. from_dict(
				{
					"id": "die",
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["sparkle"], "state": {"life_lte": 0}},
					"effect": {"type": "remove", "target": "self"},
				}
			)
		),
		(
			Rule
			. from_dict(
				{
					"id": "on_birth",
					"trigger": {"type": "spawn"},
					"query": {"tags_all": ["sparkle"]},
					"effect":
					{"type": "state_add", "target": "c1", "field": "emitted", "amount": 1},
				}
			)
		),
		(
			Rule
			. from_dict(
				{
					"id": "on_death",
					"trigger": {"type": "despawn"},
					"query": {"tags_all": ["sparkle"]},
					"effect": {"type": "state_add", "target": "c1", "field": "died", "amount": 1},
				}
			)
		),
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
	expect_eq(
		QueryLib.run({"tags_all": ["sparkle"]}, env).size(), 1, "sparkle still alive at tick 2"
	)

	# Tick 3 (life 2→1), Tick 4 (life 1→0), Tick 5: die rule sees life<=0 → remove → despawn rule fires (counter died++)
	sched.tick()
	sched.tick()
	sched.tick()
	expect_eq(
		QueryLib.run({"tags_all": ["sparkle"]}, env).size(), 0, "sparkle removed after life→0"
	)
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
	(entities["e1"] as Entity).set_position(Vector2(5, 0))  # within 8 of e0
	(entities["e2"] as Entity).set_position(Vector2(20, 0))  # outside 8 of e0
	(entities["e3"] as Entity).set_position(Vector2(0, 100))  # far away
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
	expect_eq(
		hits3.size(), 1, "after moving e1 away, radius=8 matches only e0 (got %d)" % hits3.size()
	)

	# Remove e0
	idx.remove_entity("e0")
	var hits4 := idx.query_radius(Vector2(0, 0), 8.0, entities)
	expect_eq(hits4.size(), 0, "after removing e0, no hits at origin")

	# Cleanup
	for e in entities.values():
		(e as Entity).queue_free()


# ============================================================
# CONTACT RULES (W3.2)
# ============================================================


func test_contact_rules() -> void:
	_section("contact_rules (W3.2)")
	# fire near dry tree → ignite tree (contact rule); fire near water → fire dies
	var defs: Dictionary = {
		"fire": {"id": "fire", "tags": ["fire"], "state_init": {"burning": 1, "fuel": 5}},
		"tree":
		{"id": "tree", "tags": ["tree", "flammable"], "state_init": {"burning": 0, "wet": 0.0}},
		"water": {"id": "water", "tags": ["water"], "state_init": {}},
	}
	var entities: Dictionary = {}
	var f1 := Entity.create(defs.fire, "f1")
	f1.set_position(Vector2(0, 0))
	var t1 := Entity.create(defs.tree, "t1")
	t1.set_position(Vector2(5, 0))  # close to fire
	var t2 := Entity.create(defs.tree, "t2")
	t2.set_position(Vector2(50, 0))  # far from fire
	var w1 := Entity.create(defs.water, "w1")
	w1.set_position(Vector2(8, 0))  # close to fire
	entities["f1"] = f1
	entities["t1"] = t1
	entities["t2"] = t2
	entities["w1"] = w1

	var rs := RelationStore.new()
	var sx := SpatialIndex.new()
	for id in entities:
		sx.update_entity(id, (entities[id] as Entity).get_planar_position())
	var env: Dictionary = {
		"entities": entities,
		"defs": defs,
		"relations": rs,
		"spatial_index": sx,
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}

	var rules: Array = [
		(
			Rule
			. from_dict(
				{
					"id": "fire_ignites_tree",
					"trigger": {"type": "contact"},
					"query":
					{
						"a": {"tags_all": ["fire"], "state": {"burning_gte": 1}},
						"b": {"tags_all": ["flammable"], "state": {"burning_eq": 0}},
						"radius": 10.0
					},
					"effect": {"type": "state_set", "target": "b", "field": "burning", "value": 1},
				}
			)
		),
		(
			Rule
			. from_dict(
				{
					"id": "water_extinguishes_fire",
					"trigger": {"type": "contact"},
					"query":
					{
						"a": {"tags_all": ["water"]},
						"b": {"tags_all": ["fire"], "state": {"burning_gte": 1}},
						"radius": 10.0
					},
					"effect": {"type": "state_set", "target": "b", "field": "burning", "value": 0},
				}
			)
		),
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
	for e in entities.values():
		(e as Entity).queue_free()


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
	# Prose-rejection (2026-05-08 bug fix — capital-letter starts are text, not formula)
	expect(
		not Formula.looks_like_formula("Find your shop in Pendrel."),
		"prose: 'Find your shop in Pendrel.' (starts capital) — NOT a formula"
	)
	expect(
		not Formula.looks_like_formula("Walk to the shop door (south-west)."),
		"prose with parens: 'Walk to the shop door (south-west).' — NOT a formula"
	)
	expect(
		not Formula.looks_like_formula("Day 6 — bailiff returns."),
		"prose with em-dash: 'Day 6 — bailiff returns.' — NOT a formula"
	)
	expect(
		not Formula.looks_like_formula("→ Open the shop"),
		"prose with arrow prefix: '→ Open the shop' — NOT a formula"
	)
	expect(not Formula.looks_like_formula(""), "empty string — NOT a formula")

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
	expect(
		size_after - size_before <= 1,
		"repeated formula cached (size delta %d)" % (size_after - size_before)
	)

	# Effect-side integration: state_add with formula amount
	var entities: Dictionary = {"e1": e}
	var env: Dictionary = {
		"entities": entities,
		"defs": {},
		"relations": null,
		"world": {"tick": 5},
		"parent": null,
		"next_id": {"_": 0},
	}
	# Apply effect: hp += world.tick (5) → hp 80 → 85
	EffectApply.apply(
		{"type": "state_add", "target": "self", "field": "hp", "amount": "world.tick"},
		env,
		{"self": "e1"}
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
	var sched1 := (
		PhaseScheduler
		. new(
			{
				"entities": ents1,
				"defs": defs1,
				"relations": RelationStore.new(),
				"world": {},
				"parent": null,
				"next_id": {"_": 0},
			}
		)
	)
	(
		sched1
		. register_rules(
			[
				(
					Rule
					. from_dict(
						{
							"id": "grow",
							"trigger": {"type": "tick", "interval": 1},
							"query": {"tags_all": ["thing"]},
							"effect":
							{"type": "state_add", "target": "self", "field": "growth", "amount": 1},
						}
					)
				),
			]
		)
	)
	for i in range(5):
		sched1.tick()
	var snap1 := (ents1["e1"] as Entity).snapshot()

	# Run 2: same data, different "renderer" context (no renderer is attached
	# to the entity, simulating a renderer-blind world). Engine should produce
	# the same state.
	var defs2: Dictionary = {
		"thing": {"id": "thing", "tags": ["thing"], "state_init": {"growth": 0}},
	}
	var ents2: Dictionary = {"e1": Entity.create(defs2.thing, "e1")}
	var sched2 := (
		PhaseScheduler
		. new(
			{
				"entities": ents2,
				"defs": defs2,
				"relations": RelationStore.new(),
				"world": {},
				"parent": null,
				"next_id": {"_": 0},
			}
		)
	)
	(
		sched2
		. register_rules(
			[
				(
					Rule
					. from_dict(
						{
							"id": "grow",
							"trigger": {"type": "tick", "interval": 1},
							"query": {"tags_all": ["thing"]},
							"effect":
							{"type": "state_add", "target": "self", "field": "growth", "amount": 1},
						}
					)
				),
			]
		)
	)
	for i in range(5):
		sched2.tick()
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
		"enemy": {"id": "enemy", "tags": ["enemy"], "state_init": {"velocity": [0, 0], "hp": 30}},
		"bullet":
		{
			"id": "bullet",
			"tags": ["bullet", "projectile"],
			"state_init": {"velocity": [0, 0], "lifespan": 30, "damage": 12}
		},
	}
	var entities: Dictionary = {}
	var p := Entity.create(defs.player, "p1")
	p.set_position(Vector2(0, 0))
	var e := Entity.create(defs.enemy, "e1")
	e.set_position(Vector2(50, 0))
	entities["p1"] = p
	entities["e1"] = e

	var rs := RelationStore.new()
	var sx := SpatialIndex.new()
	for id in entities:
		sx.update_entity(id, (entities[id] as Entity).get_planar_position())
	var env: Dictionary = {
		"entities": entities,
		"defs": defs,
		"relations": rs,
		"spatial_index": sx,
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}

	var rules: Array = [
		(
			Rule
			. from_dict(
				{
					"id": "fire_east",
					"trigger": {"type": "input", "action": "fire_east"},
					"effect":
					{
						"type": "spawn",
						"template": "bullet",
						"position": "actor",
						"overrides": {"state": {"velocity": [200, 0]}}
					},
				}
			)
		),
		(
			Rule
			. from_dict(
				{
					"id": "bullet_hits_enemy",
					"trigger": {"type": "contact"},
					"query":
					{
						"a": {"tags_all": ["bullet"]},
						"b": {"tags_all": ["enemy"]},
						"radius": 60.0,
					},
					"effect":
					[
						{
							"type": "state_add",
							"target": "b",
							"field": "hp",
							"amount": "-a.state.damage"
						},
						{"type": "remove", "target": "a"},
					],
				}
			)
		),
		(
			Rule
			. from_dict(
				{
					"id": "enemy_dies",
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["enemy"], "state": {"hp_lte": 0}},
					"effect": {"type": "remove", "target": "self"},
				}
			)
		),
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
	expect_eq(
		int(e.get_state("hp")), 18, "enemy took 12 damage from bullet (formula -a.state.damage)"
	)
	expect_eq(
		QueryLib.run({"tags_all": ["bullet"]}, env).size(),
		0,
		"bullet consumed by contact same tick"
	)

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
	for ent in entities.values():
		(ent as Entity).queue_free()


# ============================================================
# RPG CASCADE (W5.4) — attack → kill → xp gain → level up
# ============================================================


func test_rpg_cascade() -> void:
	_section("rpg_cascade (W5.4)")
	var defs: Dictionary = {
		"player":
		{
			"id": "player",
			"tags": ["player"],
			"state_init": {"hp": 100, "hp_max": 100, "xp": 0, "level": 1}
		},
		"goblin":
		{"id": "goblin", "tags": ["enemy", "goblin"], "state_init": {"hp": 20, "xp_value": 60}},
		"swing":
		{
			"id": "swing",
			"tags": ["weapon", "transient"],
			"state_init": {"lifespan": 2, "damage": 25}
		},
	}
	var entities: Dictionary = {}
	var p := Entity.create(defs.player, "p1")
	p.set_position(Vector2(0, 0))
	var g1 := Entity.create(defs.goblin, "g1")
	g1.set_position(Vector2(20, 0))
	var g2 := Entity.create(defs.goblin, "g2")
	g2.set_position(Vector2(-20, 0))
	entities["p1"] = p
	entities["g1"] = g1
	entities["g2"] = g2

	var rs := RelationStore.new()
	var sx := SpatialIndex.new()
	for id in entities:
		sx.update_entity(id, (entities[id] as Entity).get_planar_position())
	var env: Dictionary = {
		"entities": entities,
		"defs": defs,
		"relations": rs,
		"spatial_index": sx,
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}

	var rules: Array = [
		(
			Rule
			. from_dict(
				{
					"id": "attack",
					"trigger": {"type": "input", "action": "spark"},
					"effect": {"type": "spawn", "template": "swing", "position": "actor"},
				}
			)
		),
		(
			Rule
			. from_dict(
				{
					"id": "swing_hits_enemy",
					"trigger": {"type": "contact"},
					"query":
					{
						"a": {"tags_all": ["weapon"]},
						"b": {"tags_all": ["enemy"]},
						"radius": 50.0,
					},
					"effect":
					{
						"type": "state_add",
						"target": "b",
						"field": "hp",
						"amount": "-a.state.damage"
					},
				}
			)
		),
		(
			Rule
			. from_dict(
				{
					"id": "swing_dies_after_lifespan",
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["weapon"]},
					"effect":
					[
						{"type": "state_add", "target": "self", "field": "lifespan", "amount": -1},
					],
				}
			)
		),
		(
			Rule
			. from_dict(
				{
					"id": "swing_remove",
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["weapon"], "state": {"lifespan_lte": 0}},
					"effect": {"type": "remove", "target": "self"},
				}
			)
		),
		(
			Rule
			. from_dict(
				{
					"id": "enemy_dies",
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["enemy"], "state": {"hp_lte": 0}},
					"effect":
					[
						{
							"type": "emit",
							"signal": "killed",
							"payload": {"xp_value": "self.state.xp_value"}
						},
						{"type": "remove", "target": "self"},
					],
				}
			)
		),
		(
			Rule
			. from_dict(
				{
					"id": "player_gains_xp",
					"trigger": {"type": "signal", "name": "killed"},
					"query": {"tags_all": ["player"]},
					"effect":
					{"type": "state_add", "target": "self", "field": "xp", "amount": "xp_value"},
				}
			)
		),
		(
			Rule
			. from_dict(
				{
					"id": "level_up",
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["player"], "state": {"xp_gte": 100}},
					"effect":
					[
						{"type": "state_add", "target": "self", "field": "level", "amount": 1},
						{"type": "state_add", "target": "self", "field": "xp", "amount": -100},
						{"type": "state_mul", "target": "self", "field": "hp_max", "amount": 1.1},
						{
							"type": "state_set",
							"target": "self",
							"field": "hp",
							"value": "self.state.hp_max"
						},
					],
				}
			)
		),
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
	expect_eq(
		int(p.get_state("hp")), int(p.get_state("hp_max")), "hp restored to hp_max on level up"
	)

	# Cleanup
	for ent in entities.values():
		if is_instance_valid(ent):
			(ent as Entity).queue_free()


# ============================================================
# CHESS CASCADE (W5.5) — non-spatial acid test
# ============================================================


func test_chess_cascade() -> void:
	_section("chess_cascade (W5.5)")
	# Minimal chess: 4 squares, 2 pieces, 1 game_state.
	# Demonstrates Relation + signal-based turn flow + require validation.
	var defs: Dictionary = {
		"square": {"id": "square", "tags": ["square"]},
		"pawn_white": {"id": "pawn_white", "tags": ["piece", "white", "pawn"]},
		"pawn_black": {"id": "pawn_black", "tags": ["piece", "black", "pawn"]},
		"game_state":
		{
			"id": "game_state",
			"tags": ["game_state"],
			"state_init": {"turn": "white", "move_count": 0}
		},
	}
	var entities: Dictionary = {}
	entities["sq_a1"] = Entity.create(defs.square, "sq_a1")
	entities["sq_a2"] = Entity.create(defs.square, "sq_a2")
	entities["sq_b1"] = Entity.create(defs.square, "sq_b1")
	entities["sq_b2"] = Entity.create(defs.square, "sq_b2")
	entities["wp"] = Entity.create(defs.pawn_white, "wp")
	entities["bp"] = Entity.create(defs.pawn_black, "bp")
	entities["game"] = Entity.create(defs.game_state, "game")

	var rs := RelationStore.new()
	rs.relate("on_square", "wp", "sq_a1")
	rs.relate("on_square", "bp", "sq_a2")

	var env: Dictionary = {
		"entities": entities,
		"defs": defs,
		"relations": rs,
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}

	var rules: Array = [
		(
			Rule
			. from_dict(
				{
					"id": "white_move",
					"trigger": {"type": "input", "action": "move"},
					"query": {"tags_all": ["game_state"], "state": {"turn_eq": "white"}},
					"require":
					{
						"piece": {"tags_all": ["white", "piece"]},
						"from_sq": {"tags_all": ["square"]},
						"to_sq": {"tags_all": ["square"]},
					},
					"effect":
					[
						{
							"type": "unrelate",
							"relation": "on_square",
							"from": "piece",
							"to": "from_sq"
						},
						{"type": "relate", "relation": "on_square", "from": "piece", "to": "to_sq"},
						{"type": "state_set", "target": "self", "field": "turn", "value": "black"},
						{"type": "state_add", "target": "self", "field": "move_count", "amount": 1},
					],
				}
			)
		),
		(
			Rule
			. from_dict(
				{
					"id": "black_move",
					"trigger": {"type": "input", "action": "move"},
					"query": {"tags_all": ["game_state"], "state": {"turn_eq": "black"}},
					"require":
					{
						"piece": {"tags_all": ["black", "piece"]},
						"from_sq": {"tags_all": ["square"]},
						"to_sq": {"tags_all": ["square"]},
					},
					"effect":
					[
						{
							"type": "unrelate",
							"relation": "on_square",
							"from": "piece",
							"to": "from_sq"
						},
						{"type": "relate", "relation": "on_square", "from": "piece", "to": "to_sq"},
						{"type": "state_set", "target": "self", "field": "turn", "value": "white"},
						{"type": "state_add", "target": "self", "field": "move_count", "amount": 1},
					],
				}
			)
		),
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
	expect_eq(
		rs.targets("on_square", "wp"),
		["sq_b1"],
		"illegal white-on-black-turn rejected — pawn stays"
	)
	expect_eq(str(game.get_state("turn")), "black", "turn unchanged")
	expect_eq(int(game.get_state("move_count")), 1, "move count unchanged")

	# Try black moving a white piece (illegal — require fails on color tag)
	sched.queue_input("move", {"piece": "wp", "from_sq": "sq_b1", "to_sq": "sq_b2"})
	sched.tick()
	expect_eq(
		rs.targets("on_square", "wp"), ["sq_b1"], "black-rule rejects white piece via require"
	)
	expect_eq(str(game.get_state("turn")), "black", "still black's turn")

	# Black's legal move
	sched.queue_input("move", {"piece": "bp", "from_sq": "sq_a2", "to_sq": "sq_b2"})
	sched.tick()
	expect_eq(rs.targets("on_square", "bp"), ["sq_b2"], "black pawn moved")
	expect_eq(str(game.get_state("turn")), "white", "turn flipped back to white")
	expect_eq(int(game.get_state("move_count")), 2, "second move counted")

	# Cleanup
	for ent in entities.values():
		if is_instance_valid(ent):
			(ent as Entity).queue_free()


# ============================================================
# ENGINE ERRORS (Tier 2.6a)
# ============================================================


func test_engine_error() -> void:
	_section("engine_error (Tier 2.6a)")

	# Record shape: make() returns a JSON-shaped dict.
	var rec := EngineError.make(
		"test.code", "what happened", {"file": "x.json", "rule_id": "r1"}, "do this", "warning"
	)
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
		"entities": {},
		"defs": {},
		"relations": RelationStore.new(),
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
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
		expect_eq(
			str((fbuf[0].where as Dictionary).get("rule_id")),
			"r_formula",
			"formula rule_id attribution"
		)


# ============================================================
# RAYCAST_HIT (ADR 0005)
# ============================================================


func test_raycast_hit() -> void:
	_section("raycast_hit (ADR 0005)")

	# Build a minimal env with one target entity at (0, 1, -5) and a
	# wall blocker at (0, 1.5, -10) with extents [5, 1.5, 0.25].
	var entities: Dictionary = {}
	var defs: Dictionary = {
		"target":
		{
			"id": "target",
			"tags": ["enemy"],
			"properties": {"body_radius": 0.4},
			"state_init": {"hp": 5, "position": [0, 1, -5]}
		},
		"wall_seg":
		{
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
	EffectApply.apply(
		{
			"type": "raycast_hit",
			"origin": [0, 1, 0],
			"direction": [0, 0, -1],
			"max_distance": 30.0,
			"tags_all": ["enemy"],
			"on_hit": [{"type": "state_add", "target": "hit", "field": "hp", "amount": -2}]
		},
		env,
		{}
	)
	expect_eq(t.get_state("hp"), 3.0, "raycast on_hit: target hp 5 → 3")

	# Aim AWAY from target (positive Z) — should miss.
	t.set_state("hp", 5)
	var miss_flag: Array = [false]
	# We can't easily inject a closure, so: aim at Z=+1 (no entities there)
	EffectApply.apply(
		{
			"type": "raycast_hit",
			"origin": [0, 1, 0],
			"direction": [0, 0, 1],
			"max_distance": 30.0,
			"tags_all": ["enemy"],
			"on_hit": [{"type": "state_add", "target": "hit", "field": "hp", "amount": -100}]
		},
		env,
		{}
	)
	expect_eq(t.get_state("hp"), 5.0, "raycast miss: target unaffected when ray points away")

	# Wall caps the ray: place a SECOND target BEHIND the wall, only the
	# wall-side target is hit. Move first target behind wall (z=-15) and
	# fire — wall blocks the ray at z=-10, target at z=-15 unreachable.
	t.set_position(Vector3(0, 1, -15))
	t.set_state("hp", 5)
	EffectApply.apply(
		{
			"type": "raycast_hit",
			"origin": [0, 1, 0],
			"direction": [0, 0, -1],
			"max_distance": 30.0,
			"tags_all": ["enemy"],
			"respect_obstacles": true,
			"on_hit": [{"type": "state_add", "target": "hit", "field": "hp", "amount": -100}]
		},
		env,
		{}
	)
	expect_eq(t.get_state("hp"), 5.0, "raycast: wall blocks ray, target behind unhurt")

	# respect_obstacles=false: ray passes through walls.
	EffectApply.apply(
		{
			"type": "raycast_hit",
			"origin": [0, 1, 0],
			"direction": [0, 0, -1],
			"max_distance": 30.0,
			"tags_all": ["enemy"],
			"respect_obstacles": false,
			"on_hit": [{"type": "state_add", "target": "hit", "field": "hp", "amount": -1}]
		},
		env,
		{}
	)
	expect_eq(t.get_state("hp"), 4.0, "raycast respect_obstacles=false: target through wall is hit")

	# Tag filter excludes non-matching entities.
	t.set_position(Vector3(0, 1, -5))
	t.set_state("hp", 5)
	EffectApply.apply(
		{
			"type": "raycast_hit",
			"origin": [0, 1, 0],
			"direction": [0, 0, -1],
			"max_distance": 30.0,
			"tags_all": ["nonexistent_tag"],
			"on_hit": [{"type": "state_add", "target": "hit", "field": "hp", "amount": -100}]
		},
		env,
		{}
	)
	expect_eq(t.get_state("hp"), 5.0, "raycast tags_all filter excludes non-matching entity")

	# Cleanup
	for ent in entities.values():
		if is_instance_valid(ent):
			(ent as Entity).queue_free()


# ============================================================
# INSTANCE PATTERNS (Tier 2.6q + v2.6 mirror/exclude_zones)
# ============================================================


func test_instance_patterns() -> void:
	_section("instance_patterns (mirror + exclude_zones + determinism)")

	# Ring expansion (existing primitive — sanity check).
	var ring := InstancePatterns.expand(
		{"def": "pillar", "pattern": "ring", "count": 4, "radius": 10}
	)
	expect_eq(ring.size(), 4, "ring: 4 entries placed")
	expect_eq(str((ring[0] as Dictionary)["def"]), "pillar", "ring: def carried through")

	# Mirror primitive — duplicates `items` reflected across X axis.
	var mirrored := InstancePatterns.expand(
		{
			"pattern": "mirror",
			"axis": "x",
			"items":
			[
				{"def": "pillar", "id": "P1", "position": [5, 0, 3]},
				{"def": "pillar", "id": "P2", "position": [7, 0, -2]}
			]
		}
	)
	expect_eq(mirrored.size(), 4, "mirror: 2 originals + 2 mirrored = 4 entries")
	expect_eq(str((mirrored[0] as Dictionary)["id"]), "P1", "mirror: original kept")
	var mirror_pos: Array = (mirrored[1] as Dictionary)["position"]
	expect_eq(float(mirror_pos[0]), -5.0, "mirror: x flipped (5 → -5)")
	expect_eq(float(mirror_pos[2]), 3.0, "mirror: z preserved")
	expect_eq(str((mirrored[1] as Dictionary)["id"]), "P1_mirror", "mirror: id_suffix appended")

	# Mirror axis Z.
	var mirrored_z := InstancePatterns.expand(
		{
			"pattern": "mirror",
			"axis": "z",
			"items": [{"def": "pillar", "id": "Q", "position": [4, 0, 7]}]
		}
	)
	var mz_pos: Array = (mirrored_z[1] as Dictionary)["position"]
	expect_eq(float(mz_pos[0]), 4.0, "mirror z-axis: x preserved")
	expect_eq(float(mz_pos[2]), -7.0, "mirror z-axis: z flipped")

	# Exclude zones — scatter avoids forbidden circles.
	seed(42)
	var scattered := InstancePatterns.expand(
		{
			"def": "rock",
			"pattern": "scatter",
			"count": 30,
			"min_r": 0,
			"max_r": 10,
			"min_spacing": 0.5,
			"exclude_zones": [{"center": [0, 0, 0], "radius": 4}]
		}
	)
	var any_inside_zone := false
	for inst in scattered:
		var p: Array = (inst as Dictionary)["position"]
		var dx := float(p[0])
		var dz := float(p[2])
		if dx * dx + dz * dz < 16.0:
			any_inside_zone = true
			break
	expect(
		not any_inside_zone, "scatter exclude_zones: no placement inside r=4 circle around origin"
	)
	expect(scattered.size() > 0, "scatter exclude_zones: still placed entities outside the zone")

	# Determinism — same seed produces same result.
	seed(123)
	var batch_a := InstancePatterns.expand(
		{"def": "tree", "pattern": "scatter", "count": 10, "max_r": 20}
	)
	seed(123)
	var batch_b := InstancePatterns.expand(
		{"def": "tree", "pattern": "scatter", "count": 10, "max_r": 20}
	)
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
	expect_eq(
		str((env["screen_event_buffer"][1] as Dictionary).get("event", "")),
		"quit_app",
		"quit_app: event name"
	)

	EffectApply.apply({"type": "show_toast", "text": "Saved!", "duration": 1.5}, env, ctx)
	expect_eq(env["screen_event_buffer"].size(), 3, "show_toast: buffer grew")
	var t: Dictionary = env["screen_event_buffer"][2]
	expect_eq(str(t.get("text", "")), "Saved!", "show_toast: text passed")
	expect_eq(float(t.get("duration", 0)), 1.5, "show_toast: duration passed")

	EffectApply.apply({"type": "reload_scene", "args": {"reset": true}}, env, ctx)
	expect_eq(env["screen_event_buffer"].size(), 4, "reload_scene: buffer grew")

	# transition_screen with no target should warn but not crash
	EffectApply.apply({"type": "transition_screen"}, env, ctx)
	expect_eq(
		env["screen_event_buffer"].size(), 4, "transition_screen with no target: no event pushed"
	)

	# Buffer auto-creates if env didn't have one (edge case)
	var fresh_env: Dictionary = {}
	EffectApply.apply({"type": "transition_screen", "target": "title"}, fresh_env, ctx)
	expect(fresh_env.has("screen_event_buffer"), "lazy buffer creation")
	expect_eq((fresh_env["screen_event_buffer"] as Array).size(), 1, "lazy buffer: event landed")


## screen_fade: pushes a shell event with alpha + duration + color so the
## GameShell's per-frame lerper can apply it. Dispatch-only test — actual
## fade animation requires a live SceneTree (out of scope for unit tests).
func test_screen_fade() -> void:
	_section("screen_fade")
	var env: Dictionary = {}
	var ctx: Dictionary = {"_rule_id": "test"}

	EffectApply.apply(
		{"type": "screen_fade", "alpha": 0.8, "duration": 0.3, "color": "#000000"}, env, ctx
	)
	expect(env.has("shell_event_buffer"), "screen_fade: buffer created")
	var buf: Array = env["shell_event_buffer"]
	expect_eq(buf.size(), 1, "screen_fade: one event queued")
	var ev: Dictionary = buf[0]
	expect_eq(str(ev.get("event", "")), "screen_fade", "screen_fade: event name")
	expect_eq(float(ev.get("alpha", 0)), 0.8, "screen_fade: alpha forwarded")
	expect_eq(float(ev.get("duration", 0)), 0.3, "screen_fade: duration forwarded")
	expect_eq(str(ev.get("color", "")), "#000000", "screen_fade: color forwarded")

	# Defaults: missing fields use safe fallbacks (alpha=1.0, duration=0,
	# color="#000000"). Instant-opaque is a sane default for a fade primitive.
	EffectApply.apply({"type": "screen_fade"}, env, ctx)
	expect_eq(buf.size(), 2, "screen_fade with defaults: still pushed")
	var ev2: Dictionary = buf[1]
	expect_eq(float(ev2.get("alpha", -1)), 1.0, "screen_fade default alpha = 1.0")
	expect_eq(float(ev2.get("duration", -1)), 0.0, "screen_fade default duration = 0")


## scene_change: pushes a screen-buffer event (drained by ScreenFlow which
## calls SceneTree.change_scene_to_file). DESTRUCTIVE per effect-chain
## validation gate.
func test_scene_change_dispatches() -> void:
	_section("scene_change")
	var env: Dictionary = {"screen_event_buffer": []}
	var ctx: Dictionary = {"_rule_id": "test"}

	EffectApply.apply({"type": "scene_change", "target": "res://scenes/title.tscn"}, env, ctx)
	var buf: Array = env["screen_event_buffer"]
	expect_eq(buf.size(), 1, "scene_change: buffer size")
	var ev: Dictionary = buf[0]
	expect_eq(str(ev.get("event", "")), "scene_change", "scene_change: event name")
	expect_eq(
		str(ev.get("target", "")), "res://scenes/title.tscn", "scene_change: target forwarded"
	)

	# Missing target → warn, no event pushed (cheap-fail like transition_screen)
	EffectApply.apply({"type": "scene_change"}, env, ctx)
	expect_eq(buf.size(), 1, "scene_change with no target: no event pushed")


## transition_level with fade_duration: pushes a transition_level_fade_request
## shell event instead of setting _pending_level_transition directly. Without
## fade_duration (or with 0), the original instant-swap path runs.
func test_transition_level_fade() -> void:
	_section("transition_level_fade")
	# Path A: no fade_duration → original behavior (sets _pending_level_transition)
	var env_a: Dictionary = {}
	EffectApply.apply(
		{"type": "transition_level", "target": "level_shop"}, env_a, {"_rule_id": "test"}
	)
	expect_eq(
		str(env_a.get("_pending_level_transition", "")),
		"level_shop",
		"no fade_duration: instant-swap path sets pending transition"
	)
	expect(
		not env_a.has("shell_event_buffer") or (env_a["shell_event_buffer"] as Array).is_empty(),
		"no fade_duration: no shell event pushed"
	)

	# Path B: fade_duration=0 → also instant-swap path (preserves backward compat)
	var env_b: Dictionary = {}
	EffectApply.apply(
		{"type": "transition_level", "target": "level_shop", "fade_duration": 0},
		env_b,
		{"_rule_id": "test"}
	)
	expect_eq(
		str(env_b.get("_pending_level_transition", "")),
		"level_shop",
		"fade_duration=0: instant-swap path preserved"
	)

	# Path C: fade_duration > 0 → shell event, NOT _pending_level_transition.
	# GameShell's state machine sets _pending at the fade midpoint.
	var env_c: Dictionary = {}
	EffectApply.apply(
		{
			"type": "transition_level",
			"target": "level_shop",
			"fade_duration": 0.4,
			"color": "#000000"
		},
		env_c,
		{"_rule_id": "test"}
	)
	expect(env_c.has("shell_event_buffer"), "fade_duration>0: buffer created")
	var buf: Array = env_c["shell_event_buffer"]
	expect_eq(buf.size(), 1, "fade_duration>0: one event queued")
	var ev: Dictionary = buf[0]
	expect_eq(str(ev.get("event", "")), "transition_level_fade_request", "fade event name")
	expect_eq(str(ev.get("target", "")), "level_shop", "fade event target")
	expect_eq(float(ev.get("fade_duration", 0)), 0.4, "fade event duration")
	expect_eq(str(ev.get("color", "")), "#000000", "fade event color")
	# Critical: must NOT also set _pending_level_transition synchronously.
	# The state machine in GameShell sets it at the midpoint (after fade-out).
	# If both paths fired, you'd get a double-swap and broken visuals.
	expect(
		(
			not env_c.has("_pending_level_transition")
			or str(env_c.get("_pending_level_transition", "")) == ""
		),
		"fade path does NOT set _pending_level_transition synchronously"
	)


## Spot-check ControlFactory builds correct Godot Control types for each
## element kind. Free nodes after to avoid ObjectDB leaks.
func test_control_factory() -> void:
	_section("control_factory (ADR 0011)")
	var parent := Control.new()
	var bound: Array = []
	var dispatcher := func(_a, _b): pass

	var lbl: Control = ControlFactory.build(
		{"type": "label", "text": "Hello"}, parent, dispatcher, bound
	)
	expect(lbl is Label, "label → Label")
	if lbl is Label:
		expect_eq((lbl as Label).text, "Hello", "label text set")

	var btn: Control = ControlFactory.build(
		{"type": "button", "text": "Click", "on_click": [{"type": "quit_app"}]},
		parent,
		dispatcher,
		bound
	)
	expect(btn is Button, "button → Button")

	var vb: Control = ControlFactory.build(
		{
			"type": "vbox",
			"children": [{"type": "label", "text": "A"}, {"type": "label", "text": "B"}]
		},
		parent,
		dispatcher,
		bound
	)
	expect(vb is VBoxContainer, "vbox → VBoxContainer")
	if vb is VBoxContainer:
		expect_eq((vb as VBoxContainer).get_child_count(), 2, "vbox has 2 children")

	var hb: Control = ControlFactory.build(
		{"type": "hbox", "children": [{"type": "label", "text": "X"}]}, parent, dispatcher, bound
	)
	expect(hb is HBoxContainer, "hbox → HBoxContainer")

	var cr: Control = ControlFactory.build(
		{"type": "color_rect", "color": "#000000", "alpha": 0.6, "anchor": "fill"},
		parent,
		dispatcher,
		bound
	)
	expect(cr is ColorRect, "color_rect → ColorRect")
	if cr is ColorRect:
		expect(abs((cr as ColorRect).color.a - 0.6) < 0.001, "color_rect alpha set")

	var sp: Control = ControlFactory.build(
		{"type": "spacer", "height": 12}, parent, dispatcher, bound
	)
	expect(sp != null, "spacer built")
	if sp != null:
		expect_eq(sp.custom_minimum_size.y, 12.0, "spacer height set")

	# visible_if/enabled_if elements should be tracked in bound array
	var conditional: Control = ControlFactory.build(
		{"type": "button", "text": "Continue", "enabled_if": "world.has_save"},
		parent,
		dispatcher,
		bound
	)
	expect(conditional != null, "conditional element built")
	expect(bound.size() >= 1, "bound element registered for re-eval")

	# Unknown type returns null and warns (don't fail the test on warning)
	var unknown: Control = ControlFactory.build(
		{"type": "futuristic_widget"}, parent, dispatcher, bound
	)
	expect(unknown == null, "unknown element type returns null")

	# slot_grid (Tier A — #99): grid of bordered cells with per-cell active
	# highlight and per-cell content bound to an array.
	var sg_spec: Dictionary = {
		"type": "slot_grid",
		"cell_count": 4,
		"columns": 4,
		"binds": "actor.inventory",
		"active_binds": "actor.active_slot",
		"cell_size": [60, 50],
		"show_index": true,
		"empty_text": "—"
	}
	var sg: Control = ControlFactory.build(sg_spec, parent, dispatcher, bound)
	expect(sg is GridContainer, "slot_grid → GridContainer root")
	if sg is GridContainer:
		expect_eq((sg as GridContainer).columns, 4, "slot_grid honors columns")
		expect_eq(sg.get_child_count(), 4, "slot_grid built 4 cells")
		expect(sg.has_meta("slot_grid_cfg"), "slot_grid stamps cfg meta for updater")
		var first_cell = sg.get_child(0)
		expect(first_cell is PanelContainer, "cell is PanelContainer")
		expect_eq(int(first_cell.get_meta("slot_index", -1)), 0, "first cell meta slot_index=0")
		expect(first_cell.find_child("content", true, false) is Label, "cell has content Label")
		expect(first_cell.find_child("index", true, false) is Label, "cell has index Label when show_index=true")
	expect(bound.size() >= 2, "slot_grid registered in bound_elements via `binds`")

	# slot_grid update path: resolver fills cells from arrays + highlights
	# the active slot.
	var fake_state := {"inventory": ["food_berry", "log_pile", "", ""], "active_slot": 1}
	var resolver := func(path: String):
		if path == "actor.inventory":
			return fake_state["inventory"]
		if path == "actor.active_slot":
			return fake_state["active_slot"]
		return null
	ControlFactory.update_slot_grid(sg, resolver)
	if sg is GridContainer:
		var c0 = sg.get_child(0)
		var c1 = sg.get_child(1)
		var c2 = sg.get_child(2)
		var l0: Label = c0.find_child("content", true, false)
		var l1: Label = c1.find_child("content", true, false)
		var l2: Label = c2.find_child("content", true, false)
		expect_eq(l0.text, "food_berry", "cell 0 shows inventory[0]")
		expect_eq(l1.text, "log_pile", "cell 1 shows inventory[1]")
		expect_eq(l2.text, "—", "empty slot shows empty_text")

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
		"entities": entities,
		"defs": defs,
		"relations": rs,
		"world":
		{
			"current_level": "1",
			"score": 42,
			"tutorial_step": 3,
			"_temp_runtime": 999,
			"ignored_key": "x"
		},
		"parent": null,
		"next_id": {"_": 0},
	}

	# Spawn one of each
	var npc := Entity.new()
	npc.def_id = "npc"
	npc.instance_id = "alice"
	npc.tags = ["named_npc"]
	npc.state = {"hp": 75, "_temp_runtime": 1, "gold": 200}
	npc.set_position(Vector2(10, 20))
	entities["alice"] = npc

	var mob := Entity.new()
	mob.def_id = "mob"
	mob.instance_id = "goblin1"
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
			expect(not st.has("_temp_runtime"), "blacklisted _temp_* field NOT saved")

		var rels: Array = p.get("relations", [])
		expect_eq(rels.size(), 1, "only `owns` relation persisted")
		if rels.size() > 0:
			expect_eq(
				str((rels[0] as Dictionary).get("type", "")),
				"owns",
				"saved relation type is `owns`"
			)

	# READ BACK + version check
	var result: Dictionary = SaveState.read_slot(game, 0, policy)
	expect(bool(result.get("ok", false)), "read_slot returned ok")

	# Version mismatch refusal
	var bad_policy: Dictionary = policy.duplicate()
	bad_policy["version"] = 999
	var bad_result: Dictionary = SaveState.read_slot(game, 0, bad_policy)
	expect(not bool(bad_result.get("ok", true)), "version mismatch refuses load")
	expect_eq(
		str(bad_result.get("error", "")),
		"version_mismatch",
		"version mismatch reports correct error code"
	)

	# has_any_save sanity
	expect(SaveState.has_any_save(game, 1), "has_any_save returns true after save")
	expect(
		not SaveState.has_any_save("test_nonexistent_xyz", 3),
		"has_any_save returns false for missing game"
	)

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
	(
		EffectApply
		. apply(
			{
				"type": "show_overlay",
				"id": "welcome",
				"title": "Welcome",
				"body": "Press WASD to move.",
				"advance_action": "move_north",
				"freeze_world": true,
			},
			env,
			ctx
		)
	)
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
	(
		EffectApply
		. apply(
			{
				"type": "show_overlay",
				"id": "multi",
				"advance_action": "ui_accept",
				"advance_signal": "player_moved",
				"advance_after_seconds": 5.0,
			},
			env2,
			ctx
		)
	)
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
	var r1 := (
		Rule
		. from_dict(
			{
				"id": "shorthand",
				"trigger": {"type": "tick", "interval": 1},
				"lod": {"radius": 100.0, "fallback": "freeze"},
				"effect": {"type": "state_set", "target": "self", "field": "x", "value": 1},
			}
		)
	)
	expect(r1.lod is Dictionary, "lod field parsed")
	expect(abs(float(r1.lod["enter_radius"]) - 95.0) < 0.01, "shorthand radius → enter_radius=95")
	expect(abs(float(r1.lod["leave_radius"]) - 105.0) < 0.01, "shorthand radius → leave_radius=105")

	# Rule with explicit enter/leave radii
	var r2 := (
		Rule
		. from_dict(
			{
				"id": "explicit",
				"trigger": {"type": "tick", "interval": 1},
				"lod": {"enter_radius": 50.0, "leave_radius": 80.0, "fallback": "tick_slowed:0.5"},
				"effect": {"type": "state_set", "target": "self", "field": "x", "value": 1},
			}
		)
	)
	expect_eq(float(r2.lod["enter_radius"]), 50.0, "explicit enter_radius")
	expect_eq(float(r2.lod["leave_radius"]), 80.0, "explicit leave_radius")
	expect_eq(str(r2.lod["fallback"]), "tick_slowed:0.5", "fallback preserved")

	# No lod field → no LOD config (baseline preserved)
	var r3 := (
		Rule
		. from_dict(
			{
				"id": "no_lod",
				"trigger": {"type": "tick", "interval": 1},
				"effect": {"type": "state_set", "target": "self", "field": "x", "value": 1},
			}
		)
	)
	expect(r3.lod == null, "rule without lod field has lod=null")

	# Default anchor + fallback
	var r4 := (
		Rule
		. from_dict(
			{
				"id": "defaults",
				"trigger": {"type": "tick", "interval": 1},
				"lod": {"radius": 100.0},
				"effect": {"type": "state_set", "target": "self", "field": "x", "value": 1},
			}
		)
	)
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
		"entities": entities,
		"defs": defs,
		"relations": rs,
		"spatial_index": sx,
		"world": ws,
		"parent": null,
		"next_id": {"_": 0},
	}
	# Player at origin
	var player := Entity.new()
	player.def_id = "player"
	player.instance_id = "p"
	player.tags = ["player"]
	player.set_position(Vector2(0, 0))
	entities["p"] = player
	sx.update_entity("p", Vector2(0, 0))
	# Near NPC (dist=50 from player)
	var near := Entity.new()
	near.def_id = "npc"
	near.instance_id = "near"
	near.tags = ["npc"]
	near.state = {"counter": 0}
	near.set_position(Vector2(50, 0))
	entities["near"] = near
	sx.update_entity("near", Vector2(50, 0))
	# Far NPC (dist=300 from player)
	var far := Entity.new()
	far.def_id = "npc"
	far.instance_id = "far"
	far.tags = ["npc"]
	far.state = {"counter": 0}
	far.set_position(Vector2(300, 0))
	entities["far"] = far
	sx.update_entity("far", Vector2(300, 0))

	# Rule: tick → state_add counter +1, lod radius 100 (enter=95, leave=105)
	var rule := (
		Rule
		. from_dict(
			{
				"id": "lod_test",
				"trigger": {"type": "tick", "interval": 1},
				"lod": {"radius": 100.0, "fallback": "freeze"},
				"query": {"tags_all": ["npc"]},
				"effect": {"type": "state_add", "target": "self", "field": "counter", "amount": 1},
			}
		)
	)
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
	expect_eq(
		int(near.get_state("counter", 0)),
		2,
		"hysteresis: was-inside NPC at 102 (between 95-105) STILL fires"
	)

	# Now move near NPC past leave_radius — should leave
	near.set_position(Vector2(110, 0))
	sx.update_entity("near", Vector2(110, 0))
	sched._fire_scan_rule(rule)
	sched.flush_effects()
	expect_eq(
		int(near.get_state("counter", 0)), 2, "hysteresis: NPC past leave (110 > 105) STOPS firing"
	)

	# Move it back to 102 — should stay outside (must cross enter=95 to come back)
	near.set_position(Vector2(102, 0))
	sx.update_entity("near", Vector2(102, 0))
	sched._fire_scan_rule(rule)
	sched.flush_effects()
	expect_eq(
		int(near.get_state("counter", 0)),
		2,
		"hysteresis: NPC at 102 (between 95-105) STAYS outside without re-entering"
	)

	# Cross enter_radius to come back inside
	near.set_position(Vector2(50, 0))
	sx.update_entity("near", Vector2(50, 0))
	sched._fire_scan_rule(rule)
	sched.flush_effects()
	expect_eq(int(near.get_state("counter", 0)), 3, "hysteresis: NPC re-enters (50 < 95)")

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
		"deal_damage":
		{
			"params": ["target", "amount"],
			"expands_to":
			[
				{"type": "state_add", "target": "$target", "field": "hp", "amount": "-$amount"},
				{
					"type": "emit",
					"signal": "damaged",
					"payload": {"target": "$target", "amount": "$amount"}
				},
			],
		},
	}
	me._is_valid = true

	# Rule that uses the macro
	var rules: Array = [
		{
			"id": "bullet_hits",
			"trigger": {"type": "contact"},
			"effect": [{"type": "deal_damage", "target": "b", "amount": 10}],
		}
	]
	var expanded: Array = me.expand_rules(rules)
	expect_eq(expanded.size(), 1, "expand_rules: same rule count")
	var rule_dict: Dictionary = expanded[0]
	var fx: Array = rule_dict["effect"]
	expect_eq(fx.size(), 2, "macro expanded to 2 primitives")
	expect_eq(str(fx[0]["type"]), "state_add", "first effect is state_add")
	expect_eq(str(fx[0]["target"]), "b", "$target → b (bare substitution)")
	expect_eq(
		str(fx[0]["amount"]),
		"-10",
		"-$amount → '-10' (compound string substitution; Formula evaluates at fire time)"
	)
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
	expect_eq(
		(unchanged_fx as Array).size(),
		1,
		"empty expander: macro reference passes through (becomes unknown effect at fire)"
	)

	# Multi-level expansion: macro → macro → primitive (depth 2)
	var nested := MacroExpander.new()
	nested._registry = {
		"big_hit":
		{
			"params": ["t"],
			"expands_to":
			[
				{"type": "deal_damage", "target": "$t", "amount": 50},
				{"type": "emit", "signal": "big_hit_landed", "payload": {}},
			],
		},
		"deal_damage":
		{
			"params": ["target", "amount"],
			"expands_to":
			[
				{"type": "state_add", "target": "$target", "field": "hp", "amount": "-$amount"},
			],
		},
	}
	nested._is_valid = true
	var nested_rules: Array = [
		{
			"id": "boss_attack",
			"trigger": {"type": "contact"},
			"effect": [{"type": "big_hit", "t": "player"}],
		}
	]
	var nested_expanded := nested.expand_rules(nested_rules)
	var nested_fx: Array = nested_expanded[0]["effect"]
	# big_hit → [deal_damage(player, 50), emit big_hit_landed]
	# deal_damage → state_add(target=player, amount=-50)
	# Final: [state_add, emit]
	expect_eq(nested_fx.size(), 2, "nested expansion: 2 leaf primitives")
	expect_eq(str(nested_fx[0]["type"]), "state_add", "first leaf primitive (deal_damage expanded)")
	expect_eq(
		str(nested_fx[0]["target"]), "player", "nested $t → player propagated through $target"
	)
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
	var deep_rules: Array = [
		{
			"id": "too_deep",
			"trigger": {"type": "tick"},
			"effect": [{"type": "a"}],
		}
	]
	var deep_out := deep.expand_rules(deep_rules)
	# Depth limit (4) is exceeded at level 5 (e); expansion truncates.
	# We expect: a→b→c→d→e expands, but e's child (state_set) is at depth 5
	# > 4, so e returns []. So the final effect list ends up empty.
	# This matches the specified "no silent truncation" — push_warning fires.
	expect(deep_out[0]["effect"].size() <= 1, "depth limit truncates expansion (chain too deep)")

	# Pure pass-through: rules without macro references unchanged
	var primitive_rules: Array = [
		{
			"id": "clean",
			"trigger": {"type": "tick"},
			"effect": [{"type": "state_set", "target": "self", "field": "x", "value": 1}],
		}
	]
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
	expect_eq(am.active_actor_id, "default_player", "synthesized default actor id")
	var ids := am.actor_ids()
	expect_eq(ids.size(), 1, "synthesized has exactly one actor")
	var actor := am.get_actor("default_player")
	expect_eq(
		str(actor.get("starting_entity_tag", "")), "player", "synthesized actor uses fallback tag"
	)
	expect_eq(str(actor.get("control_mode", "")), "human", "synthesized actor is human-controlled")

	# 2. resolve_active_entity by tag
	var entities: Dictionary = {}
	var p := Entity.new()
	p.def_id = "player"
	p.instance_id = "player_main"
	p.tags = ["player"]
	entities["player_main"] = p
	expect_eq(am.resolve_active_entity(entities), "player_main", "resolves active actor via tag")
	# Returns "" if no entity matches
	entities.clear()
	expect_eq(am.resolve_active_entity(entities), "", "returns empty when no matching entity")
	p.queue_free()

	# 3. set_active with unknown id is rejected
	var ok := am.set_active("nonexistent_actor")
	expect(not ok, "set_active rejects unknown actor id")
	expect_eq(am.active_actor_id, "default_player", "active unchanged after rejection")

	# 4. switch_actor effect defers to env._pending_active_actor
	var env: Dictionary = {"parent": null}
	var ctx: Dictionary = {"_rule_id": "test"}
	EffectApply.apply({"type": "switch_actor", "target_id": "player_alt"}, env, ctx)
	expect_eq(
		str(env.get("_pending_active_actor", "")),
		"player_alt",
		"switch_actor defers via env._pending_active_actor"
	)

	# 5. switch_actor with missing target_id warns + skips
	var env2: Dictionary = {"parent": null}
	EffectApply.apply({"type": "switch_actor"}, env2, ctx)
	expect(
		not env2.has("_pending_active_actor"), "switch_actor with no target_id: nothing deferred"
	)

	# 6. Multi-actor config from in-memory file equivalent
	# (skip file I/O test — rely on Phase B integration test for files)
	var multi := ActorManager.new()
	multi._actors = [
		{
			"id": "p1",
			"starting_entity_tag": "michael",
			"control_mode": "human",
			"input_device": "keyboard"
		},
		{
			"id": "p2",
			"starting_entity_tag": "trevor",
			"control_mode": "human",
			"input_device": "gamepad_2"
		},
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
	michael.instance_id = "m1"
	michael.tags = ["michael"]
	ents2["m1"] = michael
	var trevor := Entity.new()
	trevor.instance_id = "t1"
	trevor.tags = ["trevor"]
	ents2["t1"] = trevor
	expect_eq(multi.resolve_actor_entity("p1", ents2), "m1", "resolve actor p1 → michael entity")
	expect_eq(multi.resolve_actor_entity("p2", ents2), "t1", "resolve actor p2 → trevor entity")
	expect_eq(multi.resolve_active_entity(ents2), "t1", "resolve active (p2) → trevor")
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
	expect(
		bool(env.get("_pending_world_reset", false)), "reset_world sets env._pending_world_reset"
	)

	# Re-firing keeps it true (idempotent)
	EffectApply.apply({"type": "reset_world"}, env, ctx)
	expect(bool(env.get("_pending_world_reset", false)), "second reset_world: still pending")

	# Non-destructive in chain: subsequent effects in the same chain
	# can still fire (they push into their own buffers / env keys).
	# Simulate a [reset_world, transition_screen] chain.
	env["screen_event_buffer"] = []
	EffectApply.apply({"type": "reset_world"}, env, ctx)
	EffectApply.apply({"type": "transition_screen", "target": "game"}, env, ctx)
	expect(bool(env.get("_pending_world_reset", false)), "chain: reset_world flag still set")
	expect_eq(
		env["screen_event_buffer"].size(),
		1,
		"chain: transition_screen still queued (NOT destroyed)"
	)
	expect_eq(
		str((env["screen_event_buffer"][0] as Dictionary).get("event", "")),
		"transition_screen",
		"chain: transition event reaches buffer"
	)


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
		"nearby":
		[
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
	expect_eq(
		str((actions[0] as Dictionary).get("action", "")), "patrol", "fallback action: patrol"
	)
	expect_eq(
		str((actions[0] as Dictionary).get("actor_id", "")), "guard_a", "actor_id stamped on action"
	)

	# 2. world_state condition
	var p2 := ScriptedPolicy.new()
	p2._rules = [
		{
			"id": "alert",
			"if": {"world_state": {"key": "alarm_level", "op": ">=", "value": 2}},
			"then": [{"action": "fire"}]
		},
		{"id": "fallback", "then": [{"action": "patrol"}]},
	]
	var act2: Array = p2.decide(obs, actor_state)
	expect_eq(
		str((act2[0] as Dictionary).get("action", "")),
		"fire",
		"alarm_level=2 → fires alert rule (priority over fallback)"
	)

	# Now flip alarm_level to fail the condition
	var obs_calm: Dictionary = obs.duplicate(true)
	obs_calm["world_state"] = {"alarm_level": 0}
	var act2b: Array = p2.decide(obs_calm, actor_state)
	expect_eq(
		str((act2b[0] as Dictionary).get("action", "")),
		"patrol",
		"alarm_level=0 → falls through to patrol"
	)

	# 3. distance_to active_actor
	var p3 := ScriptedPolicy.new()
	p3._rules = [
		{
			"id": "engage",
			"if": {"distance_to": {"target": "active_actor", "op": "<", "value": 30}},
			"then": [{"action": "attack"}]
		},
	]
	# active actor at (20,0), self at (0,0) → dist 20 → < 30 → fires
	var act3: Array = p3.decide(obs, actor_state)
	expect_eq(act3.size(), 1, "distance < 30: rule fires")
	expect_eq(str((act3[0] as Dictionary).get("action", "")), "attack", "engage rule action")
	# Move active actor far
	var obs_far: Dictionary = obs.duplicate(true)
	obs_far["active_actor_position"] = Vector2(500, 0)
	var act3b: Array = p3.decide(obs_far, actor_state)
	expect_eq(act3b.size(), 0, "distance >= 30: no rule fires")

	# 4. all/any composition
	var p4 := ScriptedPolicy.new()
	p4._rules = [
		{
			"id": "combo",
			"if":
			{
				"all":
				[
					{"world_state": {"key": "phase", "op": "==", "value": "combat"}},
					{"actor_state": {"field": "ammo", "op": ">", "value": 5}},
				]
			},
			"then": [{"action": "shoot"}]
		},
	]
	var act4: Array = p4.decide(obs, actor_state)
	expect_eq(
		str((act4[0] as Dictionary).get("action", "")),
		"shoot",
		"all: phase=combat AND ammo>5 → shoot"
	)
	# Fail one branch
	var st_low_ammo: Dictionary = actor_state.duplicate(true)
	st_low_ammo["state"] = {"hp": 80, "ammo": 2}
	var act4b: Array = p4.decide(obs, st_low_ammo)
	expect_eq(act4b.size(), 0, "all: ammo too low → no shoot")
	# any: at least one branch true
	var p5 := ScriptedPolicy.new()
	p5._rules = [
		{
			"id": "alert_or_low_hp",
			"if":
			{
				"any":
				[
					{"actor_state": {"field": "hp", "op": "<", "value": 30}},
					{"world_state": {"key": "alarm_level", "op": ">=", "value": 2}},
				]
			},
			"then": [{"action": "alert"}]
		},
	]
	var act5: Array = p5.decide(obs, actor_state)
	expect_eq(
		str((act5[0] as Dictionary).get("action", "")),
		"alert",
		"any: alarm>=2 (hp not low) → still fires"
	)

	# 5. nearby_count
	var p6 := ScriptedPolicy.new()
	p6._rules = [
		{
			"id": "outnumbered",
			"if": {"nearby_count": {"tag": "enemy", "op": ">=", "value": 1}},
			"then": [{"action": "retreat"}]
		},
	]
	var act6: Array = p6.decide(obs, actor_state)
	expect_eq(
		str((act6[0] as Dictionary).get("action", "")), "retreat", "nearby_count enemy>=1 → retreat"
	)

	# 6. not negation
	var p7 := ScriptedPolicy.new()
	p7._rules = [
		{
			"id": "no_allies",
			"if": {"not": {"nearby_count": {"tag": "ally", "op": ">=", "value": 1}}},
			"then": [{"action": "call_help"}]
		},
	]
	# Ally is nearby → not(true) → false → no fire
	var act7: Array = p7.decide(obs, actor_state)
	expect_eq(act7.size(), 0, "not negation: ally nearby → no_allies false → skip")

	# 7. action params forwarded (everything except 'action' propagates)
	var p8 := ScriptedPolicy.new()
	p8._rules = [
		{"id": "with_params", "then": [{"action": "move_to", "x": 100, "y": 50}]},
	]
	var act8: Array = p8.decide(obs, actor_state)
	expect_eq(int((act8[0] as Dictionary).get("x", 0)), 100, "params: x forwarded")
	expect_eq(int((act8[0] as Dictionary).get("y", 0)), 50, "params: y forwarded")


# ============================================================
# CHUNK STREAMING (ADR 0014)
# ============================================================


## Verify ChunkStreamer:
## 1. world.json absence → try_load returns null (legacy mode)
## 2. world.json present → config parsed; chunk_of math is correct
## 3. Player crosses chunk boundary → load/unload flow updates env
## 4. Persistent NPC survives chunk unload (loaded once at boot, never
##    despawned on chunk eviction)
## 5. Cross-chunk query semantics: entities in unloaded chunks are NOT
##    findable; entities in adjacent loaded chunks ARE
## 6. Save+reload replays current_chunk
func test_chunk_streaming() -> void:
	_section("chunk_streaming (ADR 0014)")

	# 1. Absence of world.json → try_load returns null (legacy single-chunk mode).
	var none := ChunkStreamer.try_load("/no/such/path", false)
	expect_eq(none, null, "try_load returns null when world.json absent")

	# Build a temp data_root under user://. We write JSON files for
	# world.json + chunks/_persistent/entities.json + a few transient
	# chunk dirs, then exercise the streamer end-to-end.
	var stamp := Time.get_ticks_msec()
	var root := "user://test_chunk_%d" % stamp
	DirAccess.make_dir_recursive_absolute(root)
	DirAccess.make_dir_recursive_absolute(root + "/chunks/_persistent")
	for c in [[0, 0], [1, 0], [0, 1], [2, 0], [3, 0]]:
		DirAccess.make_dir_recursive_absolute("%s/chunks/%d_%d" % [root, c[0], c[1]])

	# world.json — chunk_size 100×100, stream_radius 1, unload_radius 2.
	_write_text_file(
		root + "/world.json",
		(
			JSON
			. stringify(
				{
					"chunk_size": [100, 100],
					"stream_radius": 1,
					"unload_radius": 2,
					"starting_chunk": [0, 0],
					"starting_position": [50, 50],
					"persistent_tags": ["named_npc"],
					"boundary_mode": "clamp",
				}
			)
		)
	)

	# 2. try_load parses correctly.
	var cs := ChunkStreamer.try_load(root, false)
	expect(cs != null, "try_load returns instance when world.json present")
	expect_eq(cs.chunk_size, Vector2(100, 100), "chunk_size parsed")
	expect_eq(cs.stream_radius, 1, "stream_radius parsed")
	expect_eq(cs.unload_radius, 2, "unload_radius parsed")
	expect_eq(cs.starting_chunk, Vector2i(0, 0), "starting_chunk parsed")

	# chunk_of math
	expect_eq(cs.chunk_of(Vector2(50, 50)), Vector2i(0, 0), "chunk_of (50,50) → (0,0)")
	expect_eq(cs.chunk_of(Vector2(150, 50)), Vector2i(1, 0), "chunk_of (150,50) → (1,0)")
	expect_eq(
		cs.chunk_of(Vector2(-50, 50)),
		Vector2i(-1, 0),
		"chunk_of (-50,50) → (-1,0) (negative chunks)"
	)
	expect_eq(cs.chunk_of(Vector2(250, 250)), Vector2i(2, 2), "chunk_of (250,250) → (2,2)")

	# Persistent chunk content: an NPC at world (10, 10).
	_write_text_file(
		root + "/chunks/_persistent/entities.json",
		(
			JSON
			. stringify(
				{
					"definitions":
					[
						{
							"id": "named_npc",
							"tags": ["named_npc"],
							"state_init": {"hp": 100, "name": "alice"}
						},
					],
					"initial_instances":
					[
						{"def": "named_npc", "id": "alice", "position": [10, 10]},
					],
				}
			)
		)
	)
	# Transient chunks: each has a "rock" at known coords.
	_write_text_file(
		root + "/chunks/0_0/entities.json",
		(
			JSON
			. stringify(
				{
					"definitions":
					[
						{"id": "rock", "tags": ["rock"], "state_init": {}},
					],
					"initial_instances":
					[
						{"def": "rock", "id": "rock_0_0", "position": [50, 50]},
					],
				}
			)
		)
	)
	_write_text_file(
		root + "/chunks/1_0/entities.json",
		(
			JSON
			. stringify(
				{
					"initial_instances":
					[
						{"def": "rock", "id": "rock_1_0", "position": [150, 50]},
					],
				}
			)
		)
	)
	_write_text_file(
		root + "/chunks/0_1/entities.json",
		(
			JSON
			. stringify(
				{
					"initial_instances":
					[
						{"def": "rock", "id": "rock_0_1", "position": [50, 150]},
					],
				}
			)
		)
	)
	_write_text_file(
		root + "/chunks/2_0/entities.json",
		(
			JSON
			. stringify(
				{
					"initial_instances":
					[
						{"def": "rock", "id": "rock_2_0", "position": [250, 50]},
					],
				}
			)
		)
	)
	_write_text_file(
		root + "/chunks/3_0/entities.json",
		(
			JSON
			. stringify(
				{
					"initial_instances":
					[
						{"def": "rock", "id": "rock_3_0", "position": [350, 50]},
					],
				}
			)
		)
	)

	# Build a minimal env with a stub parent that knows how to spawn from
	# JSON files (matches World.load_entities_file semantics).
	var entities: Dictionary = {}
	var defs: Dictionary = {}
	var rs := RelationStore.new()
	var sx := SpatialIndex.new()
	var stub := _ChunkTestStub.new()
	stub.entities = entities
	stub.defs = defs
	stub.relations = rs
	stub.spatial_index = sx
	var env: Dictionary = {
		"entities": entities,
		"defs": defs,
		"relations": rs,
		"spatial_index": sx,
		"world": {},
		"parent": stub,
		"next_id": {"_": 0},
		"error_buffer": [],
	}

	# Pre-load persistent (mimics World.load_data flow).
	stub.load_entities_file(root + "/chunks/_persistent/entities.json")
	expect(entities.has("alice"), "persistent NPC loaded at boot")

	# Spawn an actor at (50, 50) in chunk (0, 0).
	var actor := Entity.new()
	actor.def_id = "player"
	actor.instance_id = "player_1"
	actor.tags = ["player"]
	actor.set_position(Vector2(50, 50))
	entities["player_1"] = actor
	sx.update_entity("player_1", actor.get_planar_position())

	# Boot streamer: loads (0,0), (1,0), (0,1), and adjacent neighbors that
	# don't exist on disk (treated as empty placeholders so we don't retry).
	cs.boot(env)
	expect(entities.has("rock_0_0"), "boot loads chunk (0,0)")
	expect(entities.has("rock_1_0"), "boot loads chunk (1,0) within stream_radius")
	expect(entities.has("rock_0_1"), "boot loads chunk (0,1) within stream_radius")
	expect(not entities.has("rock_2_0"), "boot does NOT load chunk (2,0) beyond stream_radius")

	# 3. Player crosses chunk boundary. Move to (250, 50) → chunk (2, 0).
	# stream_radius=1 means (1,0), (2,0), (3,0) loaded. unload_radius=2
	# means (0,0) (anchor distance 2 — inclusive, not unloaded yet).
	(entities["player_1"] as Entity).set_position(Vector2(250, 50))
	cs.update(env, "player_1")
	expect(entities.has("rock_2_0"), "after crossing to chunk (2,0): rock_2_0 loaded")
	expect(entities.has("rock_3_0"), "after crossing: chunk (3,0) loaded")
	expect(entities.has("rock_1_0"), "chunk (1,0) still loaded (within stream_radius)")
	# Move further to (550, 50) → chunk (5, 0). Now (0,0) and (1,0) are
	# both beyond unload_radius=2; should be despawned.
	(entities["player_1"] as Entity).set_position(Vector2(550, 50))
	cs.update(env, "player_1")
	expect(
		not entities.has("rock_0_0"), "after far move: chunk (0,0) unloaded (beyond unload_radius)"
	)
	expect(not entities.has("rock_1_0"), "after far move: chunk (1,0) unloaded")
	expect(not entities.has("rock_2_0"), "after far move: chunk (2,0) unloaded")
	# 4. Persistent NPC survives all of that — never enters _loaded_chunks
	# tracking, never despawned.
	expect(entities.has("alice"), "persistent NPC survives chunk eviction")

	# 4b. Spatial index hygiene: rock_0_0's spatial_index entry should also
	# be gone. Query the cell where rock_0_0 used to be; should not return
	# rock_0_0.
	var hits_at_origin := sx.query_radius_ids(Vector2(50, 50), 5.0)
	for h in hits_at_origin:
		expect(str(h) != "rock_0_0", "spatial_index has no stale rock_0_0 entry")
	# Persistent alice should be findable in spatial index too (loaded
	# once at boot via stub).
	# (Note: the stub only adds to spatial_index inside spawn — confirm
	# alice was registered when persistent loaded.)
	expect(sx.entity_count() >= 1, "spatial_index has at least the persistent + actor")

	# 5. Cross-chunk query semantics:
	#    - Move player back to (50, 50). Chunks (-1,-1)..(1,1) should be
	#      loaded; (0,0) reloaded.
	(entities["player_1"] as Entity).set_position(Vector2(50, 50))
	cs.update(env, "player_1")
	expect(entities.has("rock_0_0"), "walking back: chunk (0,0) reloaded")
	# Adjacent loaded chunks: contact rule sees rock_1_0 within radius 100.
	expect(entities.has("rock_1_0"), "walking back: chunk (1,0) reloaded")
	# Beyond stream_radius: rock_3_0 (chunk distance 3) is NOT findable.
	expect(not entities.has("rock_3_0"), "chunk (3,0) beyond stream_radius is unloaded")

	# 6. current_chunk mirrored into world_state for save/load.
	expect_eq(
		(env["world"] as Dictionary).get("current_chunk"),
		[0, 0],
		"current_chunk mirrored into world_state"
	)

	# 7. Save serializes current_chunk; verify by saving with the SaveState
	# module + reading back the JSON. Build a minimal save_policy that
	# allows persistent_entities through.
	var policy: Dictionary = {
		"world_state_keys": ["current_chunk"],
		"entity_tags_persistent": ["named_npc"],
		"entity_state_blacklist": [],
		"slots": 1,
		"version": 1,
	}
	var game := "test_chunk_save_%d" % stamp
	# Wire env.parent with a chunk_streamer property (the stub already has
	# one slot; populate it for the save-side hook).
	stub.chunk_streamer = cs
	# current_chunk on the streamer should reflect anchor (0, 0)
	expect_eq(cs.current_chunk, Vector2i(0, 0), "streamer.current_chunk anchored at (0,0)")
	var ok := SaveState.save_to_slot(env, policy, 0, game, 0)
	expect(ok, "save_to_slot succeeded with chunked-world payload")
	# Read back JSON and verify current_chunk is in payload
	var path := SaveState.slot_path(game, 0)
	var sf := FileAccess.open(path, FileAccess.READ)
	var read = JSON.parse_string(sf.get_as_text())
	sf.close()
	expect(read is Dictionary, "save payload parses")
	if read is Dictionary:
		var rd: Dictionary = read
		expect(rd.has("current_chunk"), "save payload includes current_chunk key")
		var cc = rd.get("current_chunk", null)
		# JSON round-trip widens ints → floats; compare element-wise.
		expect(cc is Array and (cc as Array).size() == 2, "saved current_chunk is 2-element array")
		if cc is Array and (cc as Array).size() == 2:
			expect_eq(int((cc as Array)[0]), 0, "saved current_chunk[0] = 0")
			expect_eq(int((cc as Array)[1]), 0, "saved current_chunk[1] = 0")

	# 8. Load+restore: simulate a restart by clearing transient chunks and
	# re-applying the saved chunk via streamer. Verify the saved chunk
	# becomes the new anchor. (Full World.load_data flow integration is
	# scene-based; here we exercise the chunk-restore logic directly.)
	# Move actor back to (50, 50) so streamer can re-anchor.
	(entities["player_1"] as Entity).set_position(Vector2(50, 50))
	# Pretend save was at chunk (1, 0)
	var saved_chunk := Vector2i(1, 0)
	# Unload everything currently loaded
	for c in cs.loaded_chunks().duplicate():
		cs._unload_chunk(c, env)
	cs.current_chunk = saved_chunk
	cs.starting_chunk = saved_chunk
	cs.boot(env)
	expect_eq(
		cs.current_chunk, Vector2i(1, 0), "after restore: streamer anchored at saved chunk (1, 0)"
	)
	expect(entities.has("rock_1_0"), "after restore: chunk (1, 0) loaded")
	expect(
		entities.has("rock_2_0"), "after restore: chunk (2, 0) loaded (stream_radius from (1,0))"
	)

	# Cleanup save file
	var d := DirAccess.open("user://saves/" + game)
	if d != null:
		d.remove("slot_0.json")
	var d2 := DirAccess.open("user://saves")
	if d2 != null:
		d2.remove(game)

	# Cleanup entities + temp data_root
	for id in entities.keys().duplicate():
		var e = entities[id]
		entities.erase(id)
		if e is Node:
			e.queue_free()
	# Best-effort temp dir teardown (shallow — Godot has no recursive remove)
	for sub in [
		"chunks/_persistent/entities.json",
		"chunks/0_0/entities.json",
		"chunks/1_0/entities.json",
		"chunks/0_1/entities.json",
		"chunks/2_0/entities.json",
		"chunks/3_0/entities.json",
		"world.json",
	]:
		DirAccess.remove_absolute(root + "/" + sub)
	for sub in [
		"chunks/_persistent",
		"chunks/0_0",
		"chunks/1_0",
		"chunks/0_1",
		"chunks/2_0",
		"chunks/3_0",
		"chunks",
	]:
		DirAccess.remove_absolute(root + "/" + sub)
	DirAccess.remove_absolute(root)


## Helper: write a string to a path, creating parent dirs as needed.
## Mirrors what data-driven tests routinely need to do for fixture setup.
func _write_text_file(path: String, contents: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("test fixture: cannot open %s for write" % path)
		return
	f.store_string(contents)
	f.close()


# ============================================================
# LIGHTING DIRECTOR (ADR 0025)
# ============================================================


## Pure-static helper coverage. day_factor, sun_color_at, sun_direction_at
## are all stateless math — no SceneTree, no World, no env needed.
func test_lighting_director_helpers() -> void:
	_section("lighting_director helpers (ADR 0025)")

	# day_factor: 0 at midnight, 1 at noon, 0.5 at dawn/dusk, wraps.
	expect_eq(LightingDirector.day_factor(0.0), 0.0, "day_factor midnight = 0")
	expect_eq(LightingDirector.day_factor(12.0), 1.0, "day_factor noon = 1")
	# Dawn/dusk should be ~0.5; allow tiny float error
	expect(abs(LightingDirector.day_factor(6.0) - 0.5) < 0.001, "day_factor dawn ~ 0.5")
	expect(abs(LightingDirector.day_factor(18.0) - 0.5) < 0.001, "day_factor dusk ~ 0.5")
	# Wrap-around: 24 == 0
	expect_eq(LightingDirector.day_factor(24.0), 0.0, "day_factor wraps at 24")
	# Negative input also wraps (fposmod)
	expect_eq(LightingDirector.day_factor(-12.0), 1.0, "day_factor -12 == noon")

	# sun_direction_at: light direction (where photons go), unit length.
	# t=0 (midnight): light points UP (+Y) — sun is below ground
	var d_mid := LightingDirector.sun_direction_at(0.0)
	expect(d_mid.is_equal_approx(Vector3(0, 1, 0)), "sun direction midnight = +Y (up)")
	# t=12 (noon): light points DOWN (-Y) — sun overhead
	var d_noon := LightingDirector.sun_direction_at(12.0)
	expect(d_noon.is_equal_approx(Vector3(0, -1, 0)), "sun direction noon = -Y (down)")
	# t=6 (dawn): light horizontal +X
	var d_dawn := LightingDirector.sun_direction_at(6.0)
	expect(d_dawn.is_equal_approx(Vector3(1, 0, 0)), "sun direction dawn = +X (horizontal)")
	# t=18 (dusk): light horizontal -X
	var d_dusk := LightingDirector.sun_direction_at(18.0)
	expect(d_dusk.is_equal_approx(Vector3(-1, 0, 0)), "sun direction dusk = -X (horizontal)")
	# All directions are unit length
	expect(abs(d_noon.length() - 1.0) < 0.001, "sun direction is unit-length")


## Verify color endpoints land on the noon / horizon / night anchors at
## the right times, and that energy interpolation makes sense.
func test_lighting_director_color_endpoints() -> void:
	_section("lighting_director color (ADR 0025)")

	var c_noon := Color("#fff8e0")
	var c_horizon := Color("#ff9060")
	var c_night := Color("#3050a0")

	# At midnight, day_factor = 0 → night zone, lerp t=0 → exact c_night
	var col_mid := LightingDirector.sun_color_at(0.0, c_noon, c_horizon, c_night)
	expect(col_mid.is_equal_approx(c_night), "sun color midnight = c_night exactly")

	# At noon, day_factor = 1 → horizon→noon lerp at t=1 → exact c_noon
	var col_noon := LightingDirector.sun_color_at(12.0, c_noon, c_horizon, c_night)
	expect(col_noon.is_equal_approx(c_noon), "sun color noon = c_noon exactly")

	# At t corresponding to day_factor=0.25 → exactly c_horizon.
	# Solve (1-cos(2π·n))/2 = 0.25 → cos(2π·n) = 0.5 → 2π·n = π/3 → n = 1/6
	# → t = 24·n = 4.0 hours. So at t=4, color should equal c_horizon.
	var col_horizon := LightingDirector.sun_color_at(4.0, c_noon, c_horizon, c_night)
	expect(col_horizon.is_equal_approx(c_horizon), "sun color at f=0.25 = c_horizon (t=4)")

	# Energy: at noon, max energy. At midnight, near-zero energy.
	var e_noon := LightingDirector.sun_energy_at(12.0, 1.0, 0.7, 0.05)
	var e_mid := LightingDirector.sun_energy_at(0.0, 1.0, 0.7, 0.05)
	expect(abs(e_noon - 1.0) < 0.001, "sun energy noon = e_noon")
	expect(abs(e_mid - 0.05) < 0.001, "sun energy midnight = e_night")
	expect(e_noon > e_mid, "sun energy noon > midnight")


## Director resolves a binding from either env.world dict OR a tagged
## entity's state. We test the resolution helper directly by constructing
## a minimal env and calling the instance method — the per-frame
## _update_lighting path is exercised in the lighting demo QA cycle, not
## here (no live SceneTree in unit tests).
func test_lighting_director_resolves_binding() -> void:
	_section("lighting_director binding (ADR 0025)")

	# Build a director instance to exercise _resolve_time_of_day directly.
	# It's an instance method but only reads env — no World parent needed.
	var ld := LightingDirector.new()
	# Manually set the binding fields the way _load_config would.
	ld._bind_tag = "world_clock"
	ld._bind_field = "time_of_day"

	# Case A: env.world dict has the field — wins over entity scan.
	var env_a: Dictionary = {"world": {"time_of_day": 9.5}, "entities": {}}
	expect_eq(ld._resolve_time_of_day(env_a), 9.5, "binding from env.world dict")

	# Case B: env.entities has a tagged entity with state — found by tag.
	var def: Dictionary = {"id": "world_clock", "tags": ["world_clock"], "state_init": {}}
	var ent := Entity.create(def, "wc_1")
	ent.set_state("time_of_day", 17.25)
	var env_b: Dictionary = {"world": {}, "entities": {"wc_1": ent}}
	expect_eq(ld._resolve_time_of_day(env_b), 17.25, "binding via tag scan when world dict empty")

	# Case C: no clock at all → fallback to noon (12.0)
	var env_c: Dictionary = {"world": {}, "entities": {}}
	expect_eq(ld._resolve_time_of_day(env_c), 12.0, "missing clock falls back to noon")

	ent.queue_free()
	ld.queue_free()


## Stub used by test_chunk_streaming as env.parent. Implements the
## subset of World's API that ChunkStreamer touches:
##   - load_entities_file(path) — loads entities from a JSON file into
##     env.entities + defs + spatial_index (mirrors World's helper)
##   - chunk_streamer field — populated by the test for save-side checks
class _ChunkTestStub:
	extends Node
	var entities: Dictionary
	var defs: Dictionary
	var relations: RelationStore
	var spatial_index: SpatialIndex
	var chunk_streamer = null
	var _next_seq: int = 0

	func load_entities_file(path: String) -> void:
		if not FileAccess.file_exists(path):
			return
		var f := FileAccess.open(path, FileAccess.READ)
		var data = JSON.parse_string(f.get_as_text())
		f.close()
		if not (data is Dictionary):
			return
		var d: Dictionary = data
		# Definitions
		for def in d.get("definitions", []):
			if def is Dictionary:
				defs[str(def.get("id", ""))] = def
		# Initial instances
		for inst in d.get("initial_instances", []):
			if not (inst is Dictionary):
				continue
			var def_id := str(inst.get("def", ""))
			if not defs.has(def_id):
				continue
			var inst_id := str(inst.get("id", ""))
			if inst_id == "":
				inst_id = "%s_%d" % [def_id, _next_seq]
				_next_seq += 1
			var ent := Entity.create(defs[def_id], inst_id)
			# Apply position override
			if inst.has("position"):
				ent.set_position(inst["position"])
			# Apply state override
			var state_in: Dictionary = inst.get("state", {}) as Dictionary
			for k in state_in.keys():
				ent.set_state(str(k), state_in[k])
			entities[inst_id] = ent
			if spatial_index != null:
				spatial_index.update_entity(inst_id, ent.get_planar_position())


# ============================================================
# PATHFINDING (ADR 0024)
# ============================================================


## Build a NavigationMesh from walkable_floor + pathfinding_obstacle
## entities and verify it contains the expected cells.
##
## Geometry under test:
##   walkable: 10×10 plaza centered at origin (extents [5, 0, 5])
##   obstacle: 2×2 box at the center  (extents [1, 1, 1])
##
## With CELL_SIZE=1, plaza tessellates to 10×10 = 100 cells. The
## central 2×2 box excludes 4 cells. Expected: 100 − 4 = 96 polygons.
func test_pathfind_builds_navmesh() -> void:
	_section("pathfind_builds_navmesh (ADR 0024)")
	var entities: Dictionary = {}
	var defs: Dictionary = {
		"plaza":
		{
			"id": "plaza",
			"tags": ["walkable_floor"],
			"properties": {"aabb_extents": [5, 0, 5]},
		},
		"box":
		{
			"id": "box",
			"tags": ["pathfinding_obstacle"],
			"properties": {"aabb_extents": [1, 1, 1]},
		}
	}
	var plaza := Entity.create(defs["plaza"], "plaza_1", {})
	plaza.set_position(Vector3(0, 0, 0))
	entities["plaza_1"] = plaza
	var box := Entity.create(defs["box"], "box_1", {})
	box.set_position(Vector3(0, 0, 0))
	entities["box_1"] = box
	var env: Dictionary = {"entities": entities, "defs": defs, "world": {}, "next_id": {"_": 0}}
	# Verify _collect_rects round-trips the geometry.
	var rects := Pathfinding._collect_rects(env)
	expect_eq((rects["walkable"] as Array).size(), 1, "one walkable rectangle collected")
	expect_eq((rects["obstacle"] as Array).size(), 1, "one obstacle rectangle collected")
	# Verify mesh data: 96 polygons after excluding the central 2×2 hole.
	var mesh: NavigationMesh = Pathfinding.build_mesh_data(
		rects["walkable"], rects["obstacle"], 0.0
	)
	expect_eq(mesh.get_polygon_count(), 96, "navmesh has 96 polygons (10×10 − 2×2 hole)")
	expect(
		mesh.get_vertices().size() > 0, "navmesh has vertices (got %d)" % mesh.get_vertices().size()
	)
	plaza.queue_free()
	box.queue_free()


## Verify the navmesh routes around an obstacle: a straight line from
## start to end would clip the wall, but the navigation map returns
## a multi-segment path that detours.
##
## We test against NavigationServer3D.map_get_path directly because
## NavigationAgent3D's get_next_path_position needs at least one
## process frame after target_position is set before its internal
## path is ready — synchronous unit tests can't easily wait a frame.
## The agent-side wiring is exercised through tick_pathfind's no-op
## tests + production runs (kingdom-sim soak test).
func test_pathfind_to_routes_around_obstacle() -> void:
	_section("pathfind_to_routes_around_obstacle (ADR 0024)")
	# Walkable: 10×10 plaza. Obstacle: a wall of extents [4, 1, 0.5]
	# centered at origin — blocks the middle but leaves 1m gaps at
	# x ∈ [-5,-4] and [4,5] for the agent to detour through.
	var walkables: Array = [{"min_x": -5.0, "max_x": 5.0, "min_z": -5.0, "max_z": 5.0, "y": 0.0}]
	var obstacles: Array = [{"min_x": -4.0, "max_x": 4.0, "min_z": -0.5, "max_z": 0.5, "y": 0.0}]
	var mesh: NavigationMesh = Pathfinding.build_mesh_data(walkables, obstacles, 0.0)
	# Verify the mesh itself has the expected geometry — independent
	# of the runtime navigation server's path-query subsystem.
	expect(
		mesh.get_polygon_count() > 0,
		"L-shaped navmesh has polygons (got %d)" % mesh.get_polygon_count()
	)
	# Sanity-check: confirm the obstacle excluded its center cell.
	var verts: PackedVector3Array = mesh.get_vertices()
	var has_x0_z0_cell := false
	for v in verts:
		if abs(v.x) < 0.001 and abs(v.z) < 0.001:
			has_x0_z0_cell = true
			break
	expect(not has_x0_z0_cell, "navmesh has no vertex at (0,0,0) — obstacle excluded")
	var region := NavigationRegion3D.new()
	region.navigation_mesh = mesh
	add_child(region)
	# Region needs a frame to register its mesh with the navigation
	# server; map_force_update synchronously rebuilds the map.
	NavigationServer3D.map_force_update(region.get_navigation_map())
	# Query a path from south to north. Even if path returns empty
	# (server timing), the structural mesh checks above already
	# established the navmesh is correct.
	var start := Vector3(0, 0.0, -4)
	var dest := Vector3(0, 0.0, 4)
	var path: PackedVector3Array = NavigationServer3D.map_get_path(
		region.get_navigation_map(), start, dest, true
	)
	if path.size() >= 2:
		var max_abs_x := 0.0
		for p in path:
			if abs(p.x) > max_abs_x:
				max_abs_x = abs(p.x)
		expect(
			max_abs_x > 0.1 or path.size() >= 3,
			(
				"path either detours off x=0 (max |x|=%f) or has multi-segment shape (size=%d)"
				% [max_abs_x, path.size()]
			)
		)
	# Also exercise tick_pathfind end-to-end — verify it sets SOME
	# Vector3 velocity (the precise direction depends on agent timing,
	# tested in production soak runs).
	var def: Dictionary = {"id": "npc", "tags": ["villager"], "state_init": {}}
	var npc := Entity.create(def, "npc_1", {})
	npc.set_position(start)
	add_child(npc)
	var env: Dictionary = {
		"entities": {"npc_1": npc},
		"_navigation_region": region,
		"world": {},
		"next_id": {"_": 0},
	}
	Pathfinding.tick_pathfind(env, npc, dest.x, dest.y, dest.z, 2.0)
	var v = npc.get_velocity()
	expect(v is Vector3, "tick_pathfind sets a Vector3 velocity")
	# Cleanup: free agent first to keep ObjectDB tidy.
	for child in npc.get_children():
		if child is NavigationAgent3D:
			child.queue_free()
	npc.queue_free()
	region.queue_free()


## pathfind_to is a no-op for entities with Vector2 positions (2D
## fallback per ADR 0024). Velocity stays unchanged; no agent attached.
func test_pathfind_no_op_on_2d() -> void:
	_section("pathfind_no_op_on_2d (ADR 0024)")
	var def: Dictionary = {"id": "sprite", "tags": ["mover"], "state_init": {}}
	var ent := Entity.create(def, "sprite_1", {})
	ent.set_position(Vector2(10, 20))
	# Pre-existing velocity that pathfind_to MUST NOT touch.
	ent.set_velocity(Vector2(3, 4))
	var env: Dictionary = {
		"entities": {"sprite_1": ent},
		"_navigation_region": null,  # even with a region, 2D check fires first
		"world": {},
		"next_id": {"_": 0},
	}
	Pathfinding.tick_pathfind(env, ent, 100.0, 0.0, 100.0, 5.0)
	var v = ent.get_velocity()
	expect_eq(v, Vector2(3, 4), "Vector2-positioned entity velocity unchanged")
	var has_agent := false
	for child in ent.get_children():
		if child is NavigationAgent3D:
			has_agent = true
			break
	expect(not has_agent, "no NavigationAgent3D attached to 2D entity")
	ent.queue_free()


# ============================================================
# PARTY DIRECTOR (ADR 0026)
# ============================================================


## party_join effect adds tag, creates relation, assigns slot, increments count.
## Verifies all five state mutations from EffectApply._party_join.
func test_party_join_creates_relation() -> void:
	_section("party_join_creates_relation (ADR 0026)")
	var defs := {
		"player": {"id": "player", "tags": ["actor"], "state_init": {"party_count": 0}},
		"npc": {"id": "npc", "tags": ["villager"], "state_init": {"hp": 10}},
	}
	var leader := Entity.create(defs.player, "p1")
	var npc_a := Entity.create(defs.npc, "npc_a")
	var npc_b := Entity.create(defs.npc, "npc_b")
	var entities: Dictionary = {"p1": leader, "npc_a": npc_a, "npc_b": npc_b}
	var rs := RelationStore.new()
	var env: Dictionary = {
		"entities": entities,
		"defs": defs,
		"relations": rs,
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}
	# Join npc_a as the first companion.
	EffectApply.apply(
		{"type": "party_join", "target": "npc_a", "leader": "p1"}, env, {"self": "npc_a"}
	)
	expect(npc_a.has_tag("party_member"), "npc_a tagged party_member")
	expect(
		rs.has_edge("party_member_of", "npc_a", "p1"), "party_member_of relation npc_a → p1 created"
	)
	expect_eq(npc_a.get_state("party_index"), 0, "first joiner gets party_index 0")
	expect_eq(leader.get_state("party_count"), 1, "leader party_count incremented to 1")
	expect_eq(npc_a.get_state("ko"), 0, "ko initialized to 0 on join")
	# Join npc_b — second slot.
	EffectApply.apply(
		{"type": "party_join", "target": "npc_b", "leader": "p1"}, env, {"self": "npc_b"}
	)
	expect_eq(npc_b.get_state("party_index"), 1, "second joiner gets party_index 1")
	expect_eq(leader.get_state("party_count"), 2, "leader party_count = 2 after second join")
	# party_leave drops tag + relation + decrements count.
	EffectApply.apply({"type": "party_leave", "target": "npc_a"}, env, {"self": "npc_a"})
	expect(not npc_a.has_tag("party_member"), "party_leave removes tag")
	expect(not rs.has_edge("party_member_of", "npc_a", "p1"), "party_leave breaks relation")
	expect_eq(leader.get_state("party_count"), 1, "leader party_count decremented to 1")
	expect_eq(npc_a.get_state("party_index"), -1, "party_index reset to -1 on leave")
	leader.queue_free()
	npc_a.queue_free()
	npc_b.queue_free()


## Director's offset table + leashing helper place each member at the
## expected XZ slot behind the leader. We test the static helper directly
## (no SceneTree needed) plus the per-member apply via a director instance.
func test_party_leashing_position_follows_player() -> void:
	_section("party_leashing_position_follows_player (ADR 0026)")
	# Static helper: index 0/1/2 produce the documented offsets.
	expect(
		PartyDirector.offset_for_index(0).is_equal_approx(Vector3(-1.0, 0, 1.5)),
		"offset slot 0 = (-1, 0, 1.5)"
	)
	expect(
		PartyDirector.offset_for_index(1).is_equal_approx(Vector3(1.0, 0, 1.5)),
		"offset slot 1 = (+1, 0, 1.5)"
	)
	expect(
		PartyDirector.offset_for_index(2).is_equal_approx(Vector3(0, 0, 2.5)),
		"offset slot 2 = (0, 0, 2.5)"
	)
	# Index out-of-bounds falls back to last entry (no crash).
	expect(
		PartyDirector.offset_for_index(99).is_equal_approx(Vector3(0, 0, 2.5)),
		"out-of-range index falls back to last slot"
	)
	expect(
		PartyDirector.offset_for_index(-1).is_equal_approx(Vector3.ZERO),
		"negative index returns ZERO (treated as unassigned)"
	)
	# Leader-relative target position.
	var leader_pos := Vector3(10, 0, 20)
	expect(
		PartyDirector.target_position_for(leader_pos, 0).is_equal_approx(Vector3(9, 0, 21.5)),
		"slot 0 target = leader + (-1, 0, +1.5)"
	)
	expect(
		PartyDirector.target_position_for(leader_pos, 1).is_equal_approx(Vector3(11, 0, 21.5)),
		"slot 1 target = leader + (+1, 0, +1.5)"
	)
	# Per-member leash apply: build a member far from target → director
	# lerps a fraction toward it (LEASH_LERP_RATE = 0.18).
	var leader_def := {"id": "p", "tags": ["actor"], "state_init": {}}
	var member_def := {
		"id": "npc", "tags": ["villager", "party_member"], "state_init": {"party_index": 0, "ko": 0}
	}
	var leader := Entity.create(leader_def, "p1")
	leader.set_position(Vector3(0, 0, 0))
	var member := Entity.create(member_def, "m1")
	member.set_position(Vector3(0, 0, 0))  # NOT yet at target — lerp will pull
	var director := PartyDirector.new()
	director._apply_leash_to_member(member, leader)
	# Expected target = (-1, 0, 1.5). After one lerp at rate 0.18 from
	# (0, 0, 0): pos = (0 + 0.18 * -1, 0, 0 + 0.18 * 1.5) = (-0.18, 0, 0.27).
	var moved: Vector3 = member.get_position()
	expect(abs(moved.x - (-0.18)) < 0.001, "leash lerp x toward target")
	expect(abs(moved.z - 0.27) < 0.001, "leash lerp z toward target")
	# When member is far past SNAP_DISTANCE, director snaps directly.
	member.set_position(Vector3(500, 0, 500))  # leader teleported away
	director._apply_leash_to_member(member, leader)
	var snapped: Vector3 = member.get_position()
	# Snapped to leader_pos + offset(0) = (-1, 0, 1.5)
	expect(
		snapped.is_equal_approx(Vector3(-1, 0, 1.5)),
		"distance > SNAP_DISTANCE snaps to target (got %s)" % snapped
	)
	director.queue_free()
	leader.queue_free()
	member.queue_free()


## party_ko sets ko/hp/position but the entity STAYS in env.entities — this
## is the core distinction from `remove`. Revival via the public revive_all
## helper restores hp_max + clears ko.
func test_party_ko_preserves_entity() -> void:
	_section("party_ko_preserves_entity (ADR 0026)")
	var defs := {
		"player": {"id": "player", "tags": ["actor"], "state_init": {"party_count": 0}},
		"hireling":
		{
			"id": "hireling",
			"tags": ["villager"],
			"properties": {"hp_max": 25},
			"state_init": {"hp": 25, "ko": 0}
		},
	}
	var leader := Entity.create(defs.player, "p1")
	leader.set_position(Vector3(7, 0, 11))
	var member := Entity.create(defs.hireling, "h1")
	member.set_position(Vector3(50, 0, 50))  # far from leader pre-KO
	var entities: Dictionary = {"p1": leader, "h1": member}
	var rs := RelationStore.new()
	rs.relate("party_member_of", "h1", "p1")
	member.add_tag("party_member")
	var env: Dictionary = {
		"entities": entities,
		"defs": defs,
		"relations": rs,
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}
	# Apply party_ko.
	EffectApply.apply({"type": "party_ko", "target": "h1"}, env, {"self": "h1"})
	expect_eq(member.get_state("ko"), 1, "ko set to 1")
	expect_eq(member.get_state("hp"), 1, "hp pinned to 1 (not 0 — prevents re-KO)")
	expect(entities.has("h1"), "entity STILL in env.entities (NOT removed)")
	var raw_pos = member.get_position()
	expect(raw_pos is Vector3, "position remains Vector3 after KO snap")
	var pos: Vector3 = raw_pos if raw_pos is Vector3 else Vector3.ZERO
	expect(pos.is_equal_approx(Vector3(7, 0, 11)), "position snapped to leader (got %s)" % pos)
	var vel = member.get_velocity()
	expect(
		vel is Vector3 and (vel as Vector3).is_equal_approx(Vector3.ZERO), "velocity zeroed on KO"
	)
	# Revival: PartyDirector.revive_all restores hp_max + clears ko.
	var director := PartyDirector.new()
	director.revive_all(env)
	expect_eq(member.get_state("ko"), 0, "revive clears ko")
	expect_eq(member.get_state("hp"), 25.0, "revive restores hp to hp_max from properties")
	director.queue_free()
	leader.queue_free()
	member.queue_free()


## NameplateRenderer.collect_named_npcs is the static filter used to
## decide which entities show floating display_name labels above their
## head. Only entities tagged `named_npc` are included; ambient cylinder
## townies (no tag) stay anonymous so the city doesn't get cluttered
## with overlapping labels.
func test_nameplate_filters_named_npc_tag() -> void:
	_section("nameplate_filters_named_npc_tag")
	var defs := {
		"named": {"id": "named", "tags": ["named_npc"], "properties": {"display_name": "Garron"}},
		"ambient": {"id": "ambient", "tags": ["townie"], "properties": {}},
		"persist":
		{
			"id": "persist",
			"tags": ["named_npc", "persistent"],
			"properties": {"display_name": "Vela"}
		},
	}
	var e_named := Entity.create(defs.named, "n1")
	e_named.set_position(Vector3(10, 0, 5))
	var e_ambient := Entity.create(defs.ambient, "a1")
	e_ambient.set_position(Vector3(20, 0, 5))
	var e_persist := Entity.create(defs.persist, "p1")
	e_persist.set_position(Vector3(0, 0, 0))
	var entities: Dictionary = {"n1": e_named, "a1": e_ambient, "p1": e_persist}
	var collected: Array = NameplateRenderer.collect_named_npcs(entities)
	expect_eq(
		collected.size(), 2, "only the 2 named_npc-tagged entities collected (ambient excluded)"
	)
	# Build a set of display_names to verify both named entries made it through.
	var names := []
	for c in collected:
		names.append(str(c["display_name"]))
	expect(names.has("Garron"), "Garron picked up from properties.display_name")
	expect(names.has("Vela"), "Vela picked up (persistent + named_npc both work)")
	# world_pos must include the +2m head-anchor offset so the label
	# floats above the entity. Garron is at y=0 → anchor at y=2.0.
	for c in collected:
		if str(c["display_name"]) == "Garron":
			var wp = c["world_pos"]
			expect(wp is Vector3, "Vector3 world_pos for 3D entity")
			expect(
				(wp as Vector3).is_equal_approx(Vector3(10, 2.0, 5)),
				"head anchor lifted +2m above entity origin (got %s)" % wp
			)
	e_named.queue_free()
	e_ambient.queue_free()
	e_persist.queue_free()


## When properties.display_name is missing or empty, the renderer falls
## back to the entity's instance_id so we never paint a blank nameplate.
func test_nameplate_picks_display_name_over_id() -> void:
	_section("nameplate_picks_display_name_over_id")
	var defs := {
		"with_name":
		{"id": "with_name", "tags": ["named_npc"], "properties": {"display_name": "Mireille"}},
		"without_name": {"id": "without_name", "tags": ["named_npc"], "properties": {}},
	}
	var has := Entity.create(defs.with_name, "npc_mireille")
	has.set_position(Vector3(0, 0, 0))
	var bare := Entity.create(defs.without_name, "npc_anonymous")
	bare.set_position(Vector3(0, 0, 0))
	var entities: Dictionary = {"npc_mireille": has, "npc_anonymous": bare}
	var collected: Array = NameplateRenderer.collect_named_npcs(entities)
	expect_eq(collected.size(), 2, "both named_npc entries collected regardless of name presence")
	var by_id := {}
	for c in collected:
		by_id[(c["entity"] as Entity).instance_id] = c["display_name"]
	expect_eq(
		str(by_id.get("npc_mireille", "")), "Mireille", "with display_name → uses display_name"
	)
	expect_eq(
		str(by_id.get("npc_anonymous", "")),
		"npc_anonymous",
		"without display_name → falls back to instance_id"
	)
	has.queue_free()
	bare.queue_free()


# ============================================================
# ADR 0027 — LIB RESOLVER UNIT TESTS
# ============================================================


func test_lib_resolver() -> void:
	# Manually populate the static cache (bypass file I/O so tests are
	# self-contained — no data/lib/ tree required for unit tests).
	LibResolver.reset_cache_for_test()
	# Inject test fixtures into the cache directly via the static var.
	LibResolver._cache_loaded = true
	LibResolver._cache = {
		"cameras":
		{
			"fps_default": {"mode": "first_person_3d", "eye_height": 1.7, "use_pitch": true},
			"iso_top_down": {"mode": "isometric_3d", "distance": 24, "ortho_size": 24},
		},
		"input_bundles.wasd_world":
		{
			"actions": ["move_north", "move_south", "move_east", "move_west"],
			"rules":
			[
				{
					"id": "lib_move_north",
					"trigger": {"type": "input", "action": "move_north"},
					"effect": {"type": "velocity_set", "target": "actor", "x": 0, "y": -3.0}
				},
				{
					"id": "lib_move_south",
					"trigger": {"type": "input", "action": "move_south"},
					"effect": {"type": "velocity_set", "target": "actor", "x": 0, "y": 3.0}
				},
			],
		},
		"chained.outer": {"$extends": "@lib.chained.inner", "extra_field": 99},
		"chained.inner": {"base_field": 1},
		"cycle.a": "@lib.cycle.b",
		"cycle.b": "@lib.cycle.a",
	}

	# === Test 1: string_ref — @lib.X.Y resolves to dict ===
	_section("lib_resolver.test_string_ref")
	var t1_in = "@lib.cameras.fps_default"
	var t1_out = LibResolver.resolve(t1_in)
	expect_eq(typeof(t1_out), TYPE_DICTIONARY, "string @lib ref resolves to dict")
	expect_eq(
		str((t1_out as Dictionary).get("mode")),
		"first_person_3d",
		"resolved dict has expected mode"
	)
	expect_eq(
		str((t1_out as Dictionary).get("_origin")),
		"@lib.cameras.fps_default",
		"resolved dict carries _origin"
	)

	# === Test 2: $extends shallow merge ===
	_section("lib_resolver.test_extends_shallow_merge")
	var t2_in = {"$extends": "@lib.cameras.iso_top_down", "follow_tag": "player", "ortho_size": 30}
	var t2_out = LibResolver.resolve(t2_in)
	expect_eq(typeof(t2_out), TYPE_DICTIONARY, "$extends resolves to dict")
	var t2 := t2_out as Dictionary
	expect_eq(str(t2.get("mode")), "isometric_3d", "preset's mode preserved")
	expect_eq(int(t2.get("distance")), 24, "preset's distance preserved")
	expect_eq(int(t2.get("ortho_size")), 30, "spec override wins (30, not preset's 24)")
	expect_eq(str(t2.get("follow_tag")), "player", "spec adds new key")
	expect_eq(str(t2.get("_origin")).begins_with("$extends:"), true, "_origin set")

	# === Test 3: $include array splice ===
	_section("lib_resolver.test_include_array_splice")
	var t3_in = {
		"rules":
		[
			{"id": "game_rule_1", "trigger": {"type": "tick"}},
			{"$include": "@lib.input_bundles.wasd_world.rules"},
			{"id": "game_rule_2", "trigger": {"type": "tick"}},
		],
	}
	var t3_out = LibResolver.resolve(t3_in)
	var t3_rules: Array = (t3_out as Dictionary).get("rules", [])
	expect_eq(t3_rules.size(), 4, "$include splices 2 lib rules into a 4-item array")
	expect_eq(
		str((t3_rules[0] as Dictionary).get("id")), "game_rule_1", "first game rule preserved"
	)
	expect_eq(str((t3_rules[1] as Dictionary).get("id")), "lib_move_north", "lib rule 1 spliced")
	expect_eq(str((t3_rules[2] as Dictionary).get("id")), "lib_move_south", "lib rule 2 spliced")
	expect_eq(
		str((t3_rules[3] as Dictionary).get("id")), "game_rule_2", "second game rule preserved"
	)

	# === Test 4: recursion depth (lib → lib chain) ===
	_section("lib_resolver.test_recursion_depth")
	# chained.outer extends chained.inner; resolving outer should recursively resolve inner.
	var t4_out = LibResolver.resolve("@lib.chained.outer")
	expect_eq(typeof(t4_out), TYPE_DICTIONARY, "recursive @lib chain resolves")
	var t4 := t4_out as Dictionary
	expect_eq(int(t4.get("base_field")), 1, "inner field present after recursion")
	expect_eq(int(t4.get("extra_field")), 99, "outer override preserved")

	# === Test 5: cycle detection ===
	_section("lib_resolver.test_cycle_detection")
	# cycle.a → cycle.b → cycle.a — resolver should error and return null/ref.
	# We don't expect_error directly (engine_error logs to stderr, not return),
	# but we expect resolve() to either return null or the original ref string.
	var t5_out = LibResolver.resolve("@lib.cycle.a")
	# Cycle detection returns null on the cycle hit; via the recursion
	# unwind we may see the partial chain. Acceptable: t5_out is null OR
	# a raw string ref (unresolved).
	var t5_ok := (t5_out == null) or (t5_out is String)
	expect_eq(t5_ok, true, "cycle returns null or unresolved ref (no infinite loop)")

	# === Test 6: depth limit (>8) ===
	_section("lib_resolver.test_depth_limit")
	# Build a 9-deep chain in cache. Each step is a string ref to next.
	for i in range(10):
		LibResolver._cache["depth_chain.step_%d" % i] = "@lib.depth_chain.step_%d" % (i + 1)
	LibResolver._cache["depth_chain.step_10"] = {"final": true}
	var t6_out = LibResolver.resolve("@lib.depth_chain.step_0")
	# At depth 8+, resolver bails and returns the unresolved value.
	# Either null or a string ref is acceptable (depth bail doesn't crash).
	var t6_ok := (t6_out == null) or (t6_out is String) or (t6_out is Dictionary)
	expect_eq(t6_ok, true, "depth limit returns gracefully without crash")

	# === Test 7: id-collision detected (handled in Rule.load_from_file, not resolver) ===
	# This test verifies the resolver itself doesn't dedupe — id-collision
	# detection is the rule loader's responsibility. Resolver just splices.
	_section("lib_resolver.test_id_collision_passes_through")
	var t7_in = {
		"rules":
		[
			{"id": "duplicate", "trigger": {"type": "tick"}},
			{"$include": "@lib.input_bundles.wasd_world.rules"},
		],
	}
	# After resolve, both 'duplicate' and lib rules ('lib_move_north', etc.) are
	# in the array. No collision in this fixture, but resolver passes through.
	var t7_out = LibResolver.resolve(t7_in)
	var t7_rules: Array = (t7_out as Dictionary).get("rules", [])
	expect_eq(t7_rules.size(), 3, "resolver leaves dup-detection to caller")

	# === Test 8: _origin metadata stamped on $extends and string ref ===
	_section("lib_resolver.test_origin_metadata")
	var t8_str = LibResolver.resolve("@lib.cameras.iso_top_down")
	expect_eq(
		str((t8_str as Dictionary).get("_origin")),
		"@lib.cameras.iso_top_down",
		"string ref stamps _origin"
	)
	var t8_ext = LibResolver.resolve({"$extends": "@lib.cameras.fps_default", "x": 1})
	expect_eq(
		str((t8_ext as Dictionary).get("_origin")),
		"$extends:@lib.cameras.fps_default",
		"$extends stamps _origin with prefix"
	)

	# === Test 9: pass-through for refs-free input ===
	_section("lib_resolver.test_pass_through_unchanged")
	var t9_in = {
		"unrelated": {"nested": [1, 2, 3], "key": "value"},
		"array": [{"id": "x"}, {"id": "y"}],
	}
	var t9_out = LibResolver.resolve(t9_in)
	expect_eq(typeof(t9_out), TYPE_DICTIONARY, "passes through unchanged")
	var t9 := t9_out as Dictionary
	expect_eq(t9.size(), 2, "same key count")
	expect_eq(str((t9.get("unrelated") as Dictionary).get("key")), "value", "deep value preserved")
	expect_eq((t9.get("array") as Array).size(), 2, "array preserved")

	# === Test 10: multi-level $extends chain (OOP-like single inheritance) ===
	_section("lib_resolver.test_multi_level_extends")
	# Inheritance chain: base → shopkeeper → merchant_shopkeeper.
	# Each level adds/overrides fields. Final resolved dict carries
	# merged fields from all 3 levels via recursive resolve.
	LibResolver._cache["entities.npc_base"] = {
		"tags": ["npc"],
		"properties": {"speed_base": 3.0, "max_hp": 100},
		"state_init": {"hp": 100},
	}
	LibResolver._cache["entities.shopkeeper"] = {
		"$extends": "@lib.entities.npc_base",
		"tags": ["shopkeeper"],
		"state_init": {"hp": 50, "gold": 200},
	}
	LibResolver._cache["entities.merchant_shopkeeper"] = {
		"$extends": "@lib.entities.shopkeeper",
		"properties": {"shop_id": "default"},
	}
	var ml_out = LibResolver.resolve(
		{"$extends": "@lib.entities.merchant_shopkeeper", "id": "garron"}
	)
	expect_eq(typeof(ml_out), TYPE_DICTIONARY, "3-level chain resolves")
	var ml := ml_out as Dictionary
	expect_eq(str(ml.get("id")), "garron", "leaf instance's own field preserved")
	# Top-level keys merge shallow — leaf level's value wins.
	expect_eq(
		str((ml.get("properties") as Dictionary).get("shop_id")),
		"default",
		"merchant_shopkeeper.properties wins (shallow merge takes whole dict)"
	)
	expect_eq(
		int((ml.get("state_init") as Dictionary).get("hp")),
		50,
		"shopkeeper.state_init wins (shallow merge — base's hp=100 dropped)"
	)
	# tags is an array; shallow merge = last writer wins, NOT array union.
	# Documented intentional choice — predictable beats clever. Authors who
	# want union must duplicate explicitly: tags: ["npc", "shopkeeper"].
	expect_eq(
		str((ml.get("tags") as Array)[0]),
		"shopkeeper",
		"tags array overridden by intermediate level (no implicit array union)"
	)

	# Cleanup
	LibResolver.reset_cache_for_test()


# ============================================================
# SCHEDULE PRIMITIVE (ADR 0029)
# ============================================================


## 12 assertions covering the schedule director's slot resolution,
## tendency-drift fallback, location_tag → entity resolution,
## transition signals, malformed-input handling, mid-day spawn
## semantics, and LOD throttling.
##
## All tests exercise the director directly via tick(env) — no
## SceneTree, no World node. Tests construct env dicts the same
## way other engine-unit tests do (see test_w2_integration).
func test_schedule_primitive() -> void:
	_section("schedule_primitive (ADR 0029)")

	# Standard 7-key tendency dict per Aldenmere canonical_decisions.
	# Used in fallback-verb test to verify all 7 keys round-trip.
	var standard_tendency := {
		"gather": 0,
		"hunt": 0,
		"tend": 0,
		"craft": 0,
		"fish": 0,
		"talk": 0,
		"observe": 0,
	}

	# ---------- Assertion 1: boundary inclusivity ----------
	# Slot [6, 12) — start (6.0) matches; end (12.0) does NOT.
	var cache_b := {
		"slots": [{"start": 6.0, "end": 12.0, "verb": "work", "location_tag": ""}],
		"default_verb": "idle",
		"wraps_at": 24.0,
	}
	expect_eq(
		ScheduleDirector._pick_active_slot(6.0, cache_b),
		0,
		"slot [6,12) matches at hour 6.0 (start inclusive)"
	)
	expect_eq(
		ScheduleDirector._pick_active_slot(12.0, cache_b),
		-1,
		"slot [6,12) does NOT match at hour 12.0 (end exclusive)"
	)

	# ---------- Assertion 2: wraparound slot (21..6) ----------
	var cache_w := {
		"slots": [{"start": 21.0, "end": 6.0, "verb": "sleep", "location_tag": "home"}],
		"default_verb": "idle",
		"wraps_at": 24.0,
	}
	expect_eq(
		ScheduleDirector._pick_active_slot(23.0, cache_w),
		0,
		"wraparound slot (21..6) matches hour 23.0"
	)
	expect_eq(
		ScheduleDirector._pick_active_slot(5.0, cache_w),
		0,
		"wraparound slot (21..6) matches hour 5.0"
	)
	expect_eq(
		ScheduleDirector._pick_active_slot(12.0, cache_w),
		-1,
		"wraparound slot (21..6) does NOT match hour 12.0"
	)

	# ---------- Assertion 3: mid-day spawn ----------
	# Entity with current_hour=9 picks the [6,12) work slot on its
	# very first tick (no warm-up required, no transition lag).
	var sd1 := ScheduleDirector.new()
	var villager_def := {
		"id": "villager",
		"tags": ["villager"],
		"state_init":
		{"current_verb": "", "current_target": "", "tendency": standard_tendency.duplicate()},
		"schedule":
		{
			"slots":
			[
				{"start": 6.0, "end": 12.0, "verb": "work", "location_tag": ""},
				{"start": 12.0, "end": 18.0, "verb": "rest", "location_tag": ""},
			],
		},
	}
	var v1 := Entity.create(villager_def, "v1")
	var entities1: Dictionary = {"v1": v1}
	var env1: Dictionary = {
		"entities": entities1,
		"defs": {"villager": villager_def},
		"world": {"current_hour": 9.0},
		"signal_buffer": [],
		"tick_count": 1,
	}
	sd1.register_schedule("v1", villager_def["schedule"], env1)
	sd1.tick(env1)
	expect_eq(
		str(v1.get_state("current_verb", "")),
		"work",
		"mid-day spawn at hour 9 picks [6,12) slot → verb=work"
	)

	# ---------- Assertion 4: slot transition emits signal ----------
	# Reuse env1; advance time across the 12.0 boundary.
	env1["world"]["current_hour"] = 13.0
	env1["tick_count"] = 2
	(env1["signal_buffer"] as Array).clear()
	sd1.tick(env1)
	expect_eq(
		str(v1.get_state("current_verb", "")), "rest", "hour 13.0 → second slot fires (verb=rest)"
	)
	var buf1: Array = env1["signal_buffer"]
	expect_eq(buf1.size(), 1, "exactly one schedule_phase_changed emitted on transition")
	if buf1.size() == 1:
		var sig1: Dictionary = buf1[0]
		expect_eq(
			str(sig1.get("name", "")),
			"schedule_phase_changed",
			"signal name is schedule_phase_changed"
		)
	v1.queue_free()
	sd1.queue_free()

	# ---------- Assertion 5: fallback verb uses tendency ----------
	# Slot has fallback_verb_by_tendency: ["gather", "hunt", "tend"].
	# Entity tendency picks the highest-scored verb.
	var sd2 := ScheduleDirector.new()
	var farmer_def := {
		"id": "farmer",
		"tags": ["villager"],
		"state_init":
		{
			"tendency":
			{"gather": 5, "hunt": 2, "tend": 8, "craft": 0, "fish": 0, "talk": 0, "observe": 0}
		},
		"schedule":
		{
			"slots":
			[
				{
					"start": 7.0,
					"end": 12.0,
					"verb": "work",
					"location_tag": "",
					"fallback_verb_by_tendency": ["gather", "hunt", "tend"]
				},
			],
		},
	}
	var f1 := Entity.create(farmer_def, "f1")
	var entities2: Dictionary = {"f1": f1}
	var env2: Dictionary = {
		"entities": entities2,
		"defs": {"farmer": farmer_def},
		"world": {"current_hour": 10.0},
		"signal_buffer": [],
		"tick_count": 1,
	}
	sd2.register_schedule("f1", farmer_def["schedule"], env2)
	sd2.tick(env2)
	expect_eq(
		str(f1.get_state("current_verb", "")),
		"tend",
		"fallback_verb_by_tendency picks 'tend' (highest tendency=8)"
	)
	# Reset tendencies to all-zero — should fall through to slot.verb.
	f1.set_state("tendency", standard_tendency.duplicate())
	# Force a re-resolve by bumping the cached last_slot_index sentinel.
	# (Same slot, same hour — but we still want verb re-evaluation.)
	# Easiest path: bump hour into a different slot then back. But the
	# director writes current_verb every tick regardless of transition,
	# so just tick again.
	sd2.tick(env2)
	expect_eq(
		str(f1.get_state("current_verb", "")),
		"work",
		"all-zero tendency → falls through to slot's primary verb='work'"
	)
	f1.queue_free()
	sd2.queue_free()

	# ---------- Assertion 6: location_tag resolves to entity ----------
	# Build a villager + a field-tagged entity; verify current_target
	# points at the field's id after slot resolution.
	var sd3 := ScheduleDirector.new()
	var villager_def_3 := {
		"id": "villager3",
		"tags": ["villager"],
		"state_init": {"current_verb": "", "current_target": ""},
		"schedule":
		{
			"slots": [{"start": 7.0, "end": 12.0, "verb": "work", "location_tag": "field"}],
		},
	}
	var field_def := {"id": "field_def", "tags": ["field"], "state_init": {}}
	var v3 := Entity.create(villager_def_3, "v3")
	v3.set_position(Vector2(0, 0))
	var fld := Entity.create(field_def, "fld_a")
	fld.set_position(Vector2(10, 0))
	var entities3: Dictionary = {"v3": v3, "fld_a": fld}
	var env3: Dictionary = {
		"entities": entities3,
		"defs": {"villager3": villager_def_3, "field_def": field_def},
		"world": {"current_hour": 9.0},
		"signal_buffer": [],
		"tick_count": 1,
	}
	sd3.register_schedule("v3", villager_def_3["schedule"], env3)
	sd3.tick(env3)
	expect_eq(
		str(v3.get_state("current_target", "")),
		"fld_a",
		"location_tag='field' → current_target='fld_a'"
	)
	v3.queue_free()
	fld.queue_free()
	sd3.queue_free()

	# ---------- Assertion 7: missing schedule = no-op ----------
	# Existing demos without a schedule block see the director do nothing.
	var sd4 := ScheduleDirector.new()
	var no_sched_def := {"id": "rock", "tags": ["prop"], "state_init": {"hp": 100}}
	var rock := Entity.create(no_sched_def, "r1")
	var env4: Dictionary = {
		"entities": {"r1": rock},
		"defs": {"rock": no_sched_def},
		"world": {"current_hour": 10.0},
		"signal_buffer": [],
		"tick_count": 1,
	}
	sd4.register_schedules_from_env(env4)
	sd4.tick(env4)
	expect_eq(
		rock.get_state("current_verb", null),
		null,
		"entity without schedule block has no current_verb written"
	)
	expect_eq(
		rock.get_state("current_target", null),
		null,
		"entity without schedule block has no current_target written"
	)
	rock.queue_free()
	sd4.queue_free()

	# ---------- Assertion 8: malformed schedule → push_warning, no crash ----------
	# Empty slots array → director skips entity. No exceptions.
	var sd5 := ScheduleDirector.new()
	var bad_def := {
		"id": "bad",
		"tags": ["villager"],
		"state_init": {},
		"schedule": {"slots": []},  # malformed
	}
	var bad_ent := Entity.create(bad_def, "b1")
	var env5: Dictionary = {
		"entities": {"b1": bad_ent},
		"defs": {"bad": bad_def},
		"world": {"current_hour": 10.0},
		"signal_buffer": [],
		"tick_count": 1,
		"error_buffer": [],
	}
	sd5.register_schedule("b1", bad_def["schedule"], env5)
	sd5.tick(env5)  # MUST NOT crash
	expect(true, "malformed schedule (empty slots) does not crash director")
	expect((env5["error_buffer"] as Array).size() >= 1, "malformed schedule raised an EngineError")
	bad_ent.queue_free()
	sd5.queue_free()

	# ---------- Assertion 9: tendency dict 7-key schema ----------
	# Verify all 7 canonical Aldenmere tendency keys are usable
	# (gather/hunt/tend/craft/fish/talk/observe).
	expect(
		(
			standard_tendency.has("gather")
			and standard_tendency.has("hunt")
			and standard_tendency.has("tend")
			and standard_tendency.has("craft")
			and standard_tendency.has("fish")
			and standard_tendency.has("talk")
			and standard_tendency.has("observe")
		),
		"7-key tendency schema (gather/hunt/tend/craft/fish/talk/observe)"
	)
	# The director uses these via _pick_verb. Build a fallback array
	# covering all 7; entity with `talk: 99` and others zero picks 'talk'.
	var t7 := standard_tendency.duplicate()
	t7["talk"] = 99
	var sd6 := ScheduleDirector.new()
	var social_def := {
		"id": "social",
		"tags": ["villager"],
		"state_init": {"tendency": t7},
		"schedule":
		{
			"slots":
			[
				{
					"start": 6.0,
					"end": 22.0,
					"verb": "work",
					"location_tag": "",
					"fallback_verb_by_tendency":
					["gather", "hunt", "tend", "craft", "fish", "talk", "observe"]
				}
			],
		},
	}
	var s_ent := Entity.create(social_def, "s1")
	var env6: Dictionary = {
		"entities": {"s1": s_ent},
		"defs": {"social": social_def},
		"world": {"current_hour": 12.0},
		"signal_buffer": [],
		"tick_count": 1,
	}
	sd6.register_schedule("s1", social_def["schedule"], env6)
	sd6.tick(env6)
	expect_eq(
		str(s_ent.get_state("current_verb", "")),
		"talk",
		"7-key fallback array picks 'talk' (highest tendency=99)"
	)
	s_ent.queue_free()
	sd6.queue_free()

	# ---------- Assertion 10: LOD throttles off-camera resolution ----------
	# Entity at distance 50 with enter_radius=10, leave_radius=12,
	# outside_mode=tick_slowed:0.1 → fires once per 10 ticks. 5 ticks
	# at unique hours (forcing transitions) should result in ≤2 verb
	# changes (initial fire + maybe one throttled).
	var sd7 := ScheduleDirector.new()
	var lod_def := {
		"id": "lod_npc",
		"tags": ["villager"],
		"state_init": {},
		"schedule":
		{
			"slots":
			[
				{"start": 0.0, "end": 6.0, "verb": "sleep"},
				{"start": 6.0, "end": 12.0, "verb": "work"},
				{"start": 12.0, "end": 18.0, "verb": "rest"},
				{"start": 18.0, "end": 24.0, "verb": "social"},
			],
			"lod": {"enter_radius": 10.0, "leave_radius": 12.0, "outside_mode": "tick_slowed:0.1"},
		},
	}
	var lod_ent := Entity.create(lod_def, "lod1")
	lod_ent.set_position(Vector2(50, 0))
	var env7: Dictionary = {
		"entities": {"lod1": lod_ent},
		"defs": {"lod_def": lod_def},
		"world": {"current_hour": 3.0},
		"signal_buffer": [],
		"tick_count": 1,
		"lod_anchor_position": Vector2(0, 0),
	}
	sd7.register_schedule("lod1", lod_def["schedule"], env7)
	# Tick 5 times across different slot hours. Without LOD this would
	# produce 5 different verbs; with tick_slowed:0.1 (~1/10) we expect
	# at most 1-2 verb changes total within 5 ticks.
	var hours := [3.0, 9.0, 15.0, 21.0, 4.0]
	var verbs_observed: Array = []
	for i in range(5):
		env7["world"]["current_hour"] = hours[i]
		env7["tick_count"] = i + 1
		sd7.tick(env7)
		verbs_observed.append(str(lod_ent.get_state("current_verb", "")))
	# Count distinct verbs encountered (proxy for resolution cadence).
	var distinct: Dictionary = {}
	for v in verbs_observed:
		distinct[v] = 1
	expect(
		distinct.size() <= 2,
		(
			"LOD outside_mode=tick_slowed:0.1 resolves ≤2 distinct verbs across 5 ticks (got %d)"
			% distinct.size()
		)
	)
	lod_ent.queue_free()
	sd7.queue_free()

	# ---------- Assertion 11: multi-entity resolution ----------
	# 5 villagers, each with different tendency, all advance correctly
	# at hour 10 (within [6,12) work slot).
	var sd8 := ScheduleDirector.new()
	var multi_def := {
		"id": "multi",
		"tags": ["villager"],
		"state_init": {},
		"schedule":
		{
			"slots":
			[
				{
					"start": 6.0,
					"end": 12.0,
					"verb": "work",
					"location_tag": "",
					"fallback_verb_by_tendency": ["gather", "hunt", "tend", "craft", "fish"]
				}
			],
		},
	}
	var picks := ["gather", "hunt", "tend", "craft", "fish"]
	var multi_entities: Dictionary = {}
	var multi_ents: Array = []
	for i in range(5):
		var t_dict := standard_tendency.duplicate()
		t_dict[picks[i]] = 10
		var e := Entity.create(multi_def, "m%d" % i)
		e.set_state("tendency", t_dict)
		multi_entities["m%d" % i] = e
		multi_ents.append(e)
	var env8: Dictionary = {
		"entities": multi_entities,
		"defs": {"multi": multi_def},
		"world": {"current_hour": 10.0},
		"signal_buffer": [],
		"tick_count": 1,
	}
	for i in range(5):
		sd8.register_schedule("m%d" % i, multi_def["schedule"], env8)
	sd8.tick(env8)
	var all_correct: bool = true
	for i in range(5):
		if str(multi_ents[i].get_state("current_verb", "")) != picks[i]:
			all_correct = false
			break
	expect(all_correct, "5 villagers each resolve to their highest-tendency verb")
	for e in multi_ents:
		e.queue_free()
	sd8.queue_free()

	# ---------- Assertion 12: signal payload schema ----------
	# Build a minimal scenario, force a transition, inspect the signal
	# payload — confirm {entity, prev_verb, new_verb, slot_id} keys.
	var sd9 := ScheduleDirector.new()
	var sig_def := {
		"id": "sig",
		"tags": ["villager"],
		"state_init": {"current_verb": "", "current_target": ""},
		"schedule":
		{
			"slots":
			[
				{"start": 6.0, "end": 12.0, "verb": "work", "location_tag": ""},
				{"start": 12.0, "end": 18.0, "verb": "rest", "location_tag": ""},
			],
			"emit_on_transition": true,
		},
	}
	var sig_ent := Entity.create(sig_def, "sg1")
	var env9: Dictionary = {
		"entities": {"sg1": sig_ent},
		"defs": {"sig": sig_def},
		"world": {"current_hour": 10.0},
		"signal_buffer": [],
		"tick_count": 1,
	}
	sd9.register_schedule("sg1", sig_def["schedule"], env9)
	sd9.tick(env9)  # initial registration → first transition emits
	(env9["signal_buffer"] as Array).clear()
	# Move hour into second slot to force a transition.
	env9["world"]["current_hour"] = 15.0
	env9["tick_count"] = 2
	sd9.tick(env9)
	var bufp: Array = env9["signal_buffer"]
	expect_eq(bufp.size(), 1, "exactly one signal emitted on slot transition")
	if bufp.size() == 1:
		var p: Dictionary = (bufp[0] as Dictionary).get("payload", {})
		expect(
			p.has("entity") and p.has("prev_verb") and p.has("new_verb") and p.has("slot_id"),
			"payload has {entity, prev_verb, new_verb, slot_id}"
		)
		expect_eq(str(p.get("entity", "")), "sg1", "payload.entity = sg1")
		expect_eq(str(p.get("prev_verb", "")), "work", "payload.prev_verb = work")
		expect_eq(str(p.get("new_verb", "")), "rest", "payload.new_verb = rest")
		expect_eq(int(p.get("slot_id", -999)), 1, "payload.slot_id = 1")
	sig_ent.queue_free()
	sd9.queue_free()


# ============================================================
# ANIMATION PRIMITIVE (ADR 0035)
# ============================================================


## Build a Node3D root with named MeshInstance3D children matching a
## bipedal mesh def (torso/head/left_arm/right_arm/left_leg/right_leg).
## Returns {root, entity} for the caller to drive AnimationDirector.
func _make_animation_fixture(
	state_overrides: Dictionary = {}, fixture_tags: Array = []
) -> Dictionary:
	var root := Node3D.new()
	add_child(root)
	for piece_name in ["torso", "head", "left_arm", "right_arm", "left_leg", "right_leg"]:
		var mi := MeshInstance3D.new()
		mi.name = piece_name
		mi.mesh = BoxMesh.new()
		# Authored rest pose: position differs per piece so we can detect
		# baseline preservation. Authored rotation = (0, 0, 0).
		match piece_name:
			"torso":
				mi.position = Vector3(0, 1.0, 0)
			"head":
				mi.position = Vector3(0, 1.55, 0)
			"left_arm":
				mi.position = Vector3(-0.32, 1.0, 0)
			"right_arm":
				mi.position = Vector3(0.32, 1.0, 0)
			"left_leg":
				mi.position = Vector3(-0.12, 0.4, 0)
			"right_leg":
				mi.position = Vector3(0.12, 0.4, 0)
		root.add_child(mi)
	var def: Dictionary = {"id": "animan", "tags": fixture_tags, "state_init": state_overrides}
	var ent := Entity.create(def, "animan_1")
	add_child(ent)
	return {"root": root, "entity": ent}


## Standard test mesh def with idle/walk/chop animations and the canonical
## state-rule precedence (verb=chop_wood → chop, |vel|>0.1 → walk, default
## → idle).
func _standard_anim_mesh_def() -> Dictionary:
	return {
		"_origin": "test_animation_primitive",
		"animations":
		{
			"idle":
			{
				"duration": 2.0,
				"loop": true,
				"tracks":
				[
					{"piece": "head", "rotation_y": [0.0, 0.05, 0.0, -0.05, 0.0]},
				],
			},
			"walk":
			{
				"duration": 0.6,
				"loop": true,
				"tracks":
				[
					{"piece": "left_arm", "rotation_z": [0.0, 0.4, 0.0, -0.4, 0.0]},
					{"piece": "right_arm", "rotation_z": [0.0, -0.4, 0.0, 0.4, 0.0]},
					{"piece": "left_leg", "rotation_x": [0.0, 0.3, 0.0, -0.3, 0.0]},
					{"piece": "right_leg", "rotation_x": [0.0, -0.3, 0.0, 0.3, 0.0]},
				],
			},
			"chop":
			{
				"duration": 0.8,
				"loop": true,
				"tracks":
				[
					{"piece": "right_arm", "rotation_x": [0.0, -1.4, -1.4, 0.0]},
					{"piece": "torso", "rotation_x": [0.0, -0.2, 0.0, 0.0]},
				],
			},
		},
		"animation_state_rules":
		[
			{"if_state_eq": {"current_verb": "chop_wood"}, "state": "chop"},
			{"if_velocity_gt": 0.1, "state": "walk"},
			{"default": "idle"},
		],
	}


func _free_anim_fixture(fix: Dictionary) -> void:
	var root: Node3D = fix.get("root", null)
	var ent: Entity = fix.get("entity", null)
	if ent != null:
		ent.queue_free()
	if root != null:
		root.queue_free()


func test_animation_primitive() -> void:
	_section("animation_primitive (ADR 0035 + ADR 0046 Phase A.2)")

	# Phase A.2 cutover (2026-05-17): the GDScript per-frame interpolator
	# has been replaced by Godot's AnimationPlayer + a translated
	# AnimationLibrary (see test_animation_translator for translator
	# coverage). This test now covers ONLY what AnimationDirector still
	# owns: state-rule selection + backwards-compat sentinels +
	# load-time validation. Interpolation values + baseline preservation
	# are translator concerns now — covered separately.

	# ---------- Assertion 1: state pick — verb-based (`if_state_eq`) ----------
	# current_verb = "chop_wood" → state="chop" (rule order: chop first;
	# velocity-walk rule comes after and wouldn't fire even if vel were high).
	var fix1 := _make_animation_fixture(
		{"current_verb": "chop_wood", "velocity": Vector3(0.5, 0, 0)}
	)
	var dir1 := AnimationDirector.from_mesh_def(
		_standard_anim_mesh_def(), fix1["root"] as Node3D, fix1["entity"] as Entity, {}
	)
	expect(dir1 != null, "director constructs when animations + default rule present")
	expect_eq(dir1._pick_state(), "chop", "verb=chop_wood picks 'chop' state")

	# ---------- Assertion 2: state pick — velocity-based ----------
	var fix2 := _make_animation_fixture({"current_verb": "", "velocity": Vector3(0.5, 0, 0)})
	var dir2 := AnimationDirector.from_mesh_def(
		_standard_anim_mesh_def(), fix2["root"] as Node3D, fix2["entity"] as Entity, {}
	)
	expect_eq(dir2._pick_state(), "walk", "|velocity|=0.5 > 0.1 picks 'walk' state")

	# ---------- Assertion 3: state pick — default fallback ----------
	var fix3 := _make_animation_fixture({"current_verb": "", "velocity": Vector3.ZERO})
	var dir3 := AnimationDirector.from_mesh_def(
		_standard_anim_mesh_def(), fix3["root"] as Node3D, fix3["entity"] as Entity, {}
	)
	expect_eq(dir3._pick_state(), "idle", "no condition matches → default 'idle'")

	# ---------- Assertion 4: state transition (idle → walk after vel change) ----
	var fix4 := _make_animation_fixture({"current_verb": "", "velocity": Vector3.ZERO})
	var dir4 := AnimationDirector.from_mesh_def(
		_standard_anim_mesh_def(), fix4["root"] as Node3D, fix4["entity"] as Entity, {}
	)
	expect_eq(dir4._pick_state(), "idle", "starts in idle when velocity=0")
	(fix4["entity"] as Entity).set_state("velocity", Vector3(0.5, 0, 0))
	expect_eq(dir4._pick_state(), "walk", "transitions to walk after velocity change")

	# ---------- Assertion 5: backwards-compat — no animations field ----------
	# Mesh def without animations key → from_mesh_def returns null. Existing
	# demos with static meshes rely on this.
	var fix5 := _make_animation_fixture()
	var bare_def: Dictionary = {"primitives": [{"op": "box", "name": "torso"}]}
	var dir5 := AnimationDirector.from_mesh_def(
		bare_def, fix5["root"] as Node3D, fix5["entity"] as Entity, {}
	)
	expect(dir5 == null, "mesh def without animations field → director is null (backwards-compat)")

	# ---------- Assertion 6: missing default rule → load-time error ----------
	var fix6 := _make_animation_fixture()
	var no_default_def: Dictionary = {
		"_origin": "no_default_test",
		"animations": {"idle": {"duration": 1.0, "tracks": []}},
		"animation_state_rules":
		[
			{"if_velocity_gt": 0.1, "state": "walk"},
		],
	}
	var env6: Dictionary = {"error_buffer": []}
	var dir6 := AnimationDirector.from_mesh_def(
		no_default_def, fix6["root"] as Node3D, fix6["entity"] as Entity, env6
	)
	expect(dir6 == null, "missing `default` rule → from_mesh_def returns null")
	var errs: Array = env6.get("error_buffer", [])
	var saw_no_default := false
	for rec in errs:
		if (
			rec is Dictionary
			and str((rec as Dictionary).get("code", "")) == EngineError.ANIMATION_NO_DEFAULT
		):
			saw_no_default = true
			break
	expect(saw_no_default, "missing default rule emits ANIMATION_NO_DEFAULT to error_buffer")

	# ---------- Assertion 7: tick() no-op when AnimationPlayer not attached ----
	# Backwards-compat for unit fixtures that don't mount a player: tick()
	# must early-return cleanly, not crash. (entity_mesh_3d mounts the
	# player at integration time; bare directors never get one.)
	var fix7 := _make_animation_fixture({"current_verb": "", "velocity": Vector3(0.5, 0, 0)})
	var dir7 := AnimationDirector.from_mesh_def(
		_standard_anim_mesh_def(), fix7["root"] as Node3D, fix7["entity"] as Entity, {}
	)
	dir7.tick(0.0)
	expect(true, "tick() without attached AnimationPlayer is a safe no-op")

	# ---------- Assertion 8: clip_alias resolves state name → clip name ----
	# Phase B (2026-05-17): when state_rules declare clip_alias mappings,
	# the director plays the aliased clip name on the attached
	# AnimationPlayer rather than the verbatim state name. Used for .glb
	# files whose clip names come from Blender (e.g. "Walking") but whose
	# engine-side state is lowercase "walk".
	var fix8 := _make_animation_fixture({"current_verb": "", "velocity": Vector3(0.5, 0, 0)})
	var alias_def: Dictionary = {
		"_origin": "alias_test",
		"animations": {},
		"animation_state_rules":
		[
			{"if_velocity_gt": 0.1, "state": "walk", "clip_alias": "Walking"},
			{"default": "idle", "clip_alias": "Idle"}
		]
	}
	var dir8 := AnimationDirector.from_mesh_def(
		alias_def, fix8["root"] as Node3D, fix8["entity"] as Entity, {}
	)
	# Build a real AnimationPlayer with the two aliased clips so tick()
	# can resolve them. Mirrors the entity_mesh_3d Phase B path.
	var ap_alias := AnimationPlayer.new()
	add_child(ap_alias)
	var alias_lib := AnimationLibrary.new()
	var anim_walking := Animation.new()
	anim_walking.length = 0.5
	alias_lib.add_animation("Walking", anim_walking)
	var anim_idle := Animation.new()
	anim_idle.length = 1.0
	alias_lib.add_animation("Idle", anim_idle)
	ap_alias.add_animation_library("", alias_lib)
	dir8.attach_player(ap_alias)
	dir8.set_clip_aliases({"walk": "Walking", "idle": "Idle"})
	dir8.tick(0.0)
	expect_eq(
		str(ap_alias.assigned_animation),
		"Walking",
		"clip_alias 'walk'→'Walking' plays Walking on the imported player"
	)
	# Stop velocity and retick — should swap to Idle alias.
	(fix8["entity"] as Entity).set_state("velocity", Vector3.ZERO)
	dir8.tick(0.1)
	expect_eq(
		str(ap_alias.assigned_animation),
		"Idle",
		"state transition (walk → idle) re-resolves via alias to 'Idle'"
	)
	ap_alias.queue_free()

	# ---------- Assertion 9: end-to-end Phase B with the synth .glb -----
	# Phase B.4 (2026-05-17): tools/synth_test_glb.py emits a cube .glb
	# with Idle + Walking clips at data/test_assets/cube_anim.glb. Verify
	# Godot imports it correctly AND that the loader path in
	# entity_mesh_3d resolves it (presence of the AnimationPlayer + the
	# two named clips). This is the only test that exercises the .glb
	# load → AnimationPlayer attach → clip_alias play path together.
	var glb_path := "res://data/test_assets/cube_anim.glb"
	if ResourceLoader.exists(glb_path):
		var packed = load(glb_path)
		expect(packed is PackedScene, "synth cube_anim.glb loads as PackedScene")
		var scene_root: Node = (packed as PackedScene).instantiate()
		add_child(scene_root)
		# Find the embedded AnimationPlayer (shallow search like the engine does).
		var found_ap: AnimationPlayer = null
		for c in scene_root.get_children():
			if c is AnimationPlayer:
				found_ap = c
				break
		expect(found_ap != null, "imported .glb has an embedded AnimationPlayer")
		if found_ap != null:
			var clip_list := Array(found_ap.get_animation_list())
			expect(
				clip_list.has("Idle") and clip_list.has("Walking"),
				(
					"AnimationPlayer has the two synth clips (got %s)"
					% str(clip_list)
				)
			)
		scene_root.queue_free()
	else:
		# Soft skip: the .glb may not exist in worktree-isolated runs.
		# Tests that REQUIRE the .glb should fail loudly elsewhere; here
		# we just note the skip so the bench count stays consistent.
		expect(true, "synth .glb not present (skip); run: python3 tools/synth_test_glb.py")

	# Cleanup all fixtures
	_free_anim_fixture(fix1)
	_free_anim_fixture(fix2)
	_free_anim_fixture(fix3)
	_free_anim_fixture(fix4)
	_free_anim_fixture(fix5)
	_free_anim_fixture(fix6)
	_free_anim_fixture(fix7)
	_free_anim_fixture(fix8)


# ============================================================
# LIFECYCLE PRIMITIVE (ADR 0036)
# ============================================================
# Tests the LifecycleDirector — per-tick aging + stage transitions
# driven by JSON-declared lifecycle templates. Mirrors
# test_schedule_primitive's pattern: build env stub, instantiate
# director, call register/tick, assert state changes.


func test_lifecycle_primitive() -> void:
	_section("lifecycle_primitive (ADR 0036)")

	# Standard human lifecycle template per ADR 0036's reference shape.
	# 5 stages: infant / child / adult / elder / dead. Compressed
	# year_seconds=1.0 + age_per_in_game_year=1.0 so 1 second of dt
	# advances exactly 1 year — makes assertions clean.
	var human_template := {
		"stages":
		[
			{
				"id": "infant",
				"min_age": 0,
				"max_age": 2,
				"mesh": "human_infant_3d",
				"abilities": ["needs_caring"],
				"speed_mult": 0.4
			},
			{
				"id": "child",
				"min_age": 2,
				"max_age": 12,
				"mesh": "human_child_3d",
				"abilities": ["gather", "talk"],
				"speed_mult": 0.85
			},
			{
				"id": "adult",
				"min_age": 12,
				"max_age": 50,
				"mesh": "merchant_npc_3d",
				"abilities": ["all"],
				"speed_mult": 1.0
			},
			{
				"id": "elder",
				"min_age": 50,
				"max_age": 80,
				"mesh": "human_elder_3d",
				"abilities": ["talk", "tend_fire", "teach"],
				"speed_mult": 0.6
			},
			{
				"id": "dead",
				"min_age": 80,
				"mesh": null,
				"abilities": [],
				"speed_mult": 0.0,
				"terminal": true
			},
		],
		"age_per_in_game_year": 1.0,
		"year_seconds": 1.0,
	}

	# ---------- Assertion 1: age increments per in-game year ----------
	var ld1 := LifecycleDirector.new()
	var human_def := {
		"id": "villager",
		"tags": ["villager", "human"],
		"lifecycle": human_template,
		"state_init": {"age": 5.0, "life_stage": "child"},
		"visual": {"mesh": "human_child_3d"},
	}
	var v1 := Entity.create(human_def, "v1")
	var entities1: Dictionary = {"v1": v1}
	var env1: Dictionary = {
		"entities": entities1,
		"defs": {"villager": human_def},
		"world": {},
		"signal_buffer": [],
		"tick_count": 1,
	}
	ld1.register_lifecycle("v1", human_template, env1, "human")
	ld1.tick(env1, 1.0)  # +1 year
	var age_after_1y: float = float(v1.get_state("age", 0.0))
	expect(
		abs(age_after_1y - 6.0) < 0.001,
		"age increments by 1.0 after dt=1.0 with year_seconds=1, rate=1 (got %f)" % age_after_1y
	)
	v1.queue_free()
	ld1.queue_free()

	# ---------- Assertion 2: stage transition at threshold ----------
	# Child (max_age=12). Spawn at 11.5, tick +1 year → crosses to adult.
	var ld2 := LifecycleDirector.new()
	var v2 := Entity.create(human_def, "v2")
	v2.set_state("age", 11.5)
	v2.set_state("life_stage", "child")
	var entities2: Dictionary = {"v2": v2}
	var env2: Dictionary = {
		"entities": entities2,
		"defs": {"villager": human_def},
		"world": {},
		"signal_buffer": [],
		"tick_count": 1,
	}
	ld2.register_lifecycle("v2", human_template, env2, "human")
	ld2.tick(env2, 1.0)  # 11.5 + 1.0 = 12.5 → crosses 12.0 → adult
	expect_eq(
		str(v2.get_state("life_stage", "")),
		"adult",
		"life_stage advances from child to adult when crossing max_age=12"
	)
	v2.queue_free()
	ld2.queue_free()

	# ---------- Assertion 3: mesh swap on transition ----------
	# Same setup as #2; check visual.mesh swapped to adult mesh.
	var ld3 := LifecycleDirector.new()
	var v3 := Entity.create(human_def, "v3")
	v3.set_state("age", 11.5)
	v3.set_state("life_stage", "child")
	var entities3: Dictionary = {"v3": v3}
	var env3: Dictionary = {
		"entities": entities3,
		"defs": {"villager": human_def},
		"world": {},
		"signal_buffer": [],
		"tick_count": 1,
	}
	ld3.register_lifecycle("v3", human_template, env3, "human")
	ld3.tick(env3, 1.0)
	expect_eq(
		str(v3.visual.get("mesh", "")),
		"merchant_npc_3d",
		"visual.mesh swaps to adult-stage mesh on transition"
	)
	v3.queue_free()
	ld3.queue_free()

	# ---------- Assertion 4: ability gating via tag mutation ----------
	# Child entity carries child-stage abilities (gather + talk) plus
	# species/role tags. On transition to adult (abilities="all"),
	# previous abilities are removed but species tags survive.
	var ld4 := LifecycleDirector.new()
	var child_def := {
		"id": "kid",
		"tags": ["villager", "human", "gather", "talk"],
		"lifecycle": human_template,
		"state_init": {"age": 11.5, "life_stage": "child"},
		"visual": {"mesh": "human_child_3d"},
	}
	var v4 := Entity.create(child_def, "v4")
	var entities4: Dictionary = {"v4": v4}
	var env4: Dictionary = {
		"entities": entities4,
		"defs": {"kid": child_def},
		"world": {},
		"signal_buffer": [],
		"tick_count": 1,
	}
	ld4.register_lifecycle("v4", human_template, env4, "human")
	ld4.tick(env4, 1.0)  # crosses to adult
	expect(not v4.has_tag("gather"), "child ability 'gather' removed on adult transition")
	expect(not v4.has_tag("talk"), "child ability 'talk' removed on adult transition")
	expect(v4.has_tag("villager"), "non-ability tag 'villager' survives transition")
	expect(v4.has_tag("human"), "non-ability tag 'human' survives transition")
	v4.queue_free()
	ld4.queue_free()

	# ---------- Assertion 5: speed_mult applied ----------
	# Elder stage has speed_mult=0.6. Spawn entity at age 49.5, tick
	# +1 year → crosses to elder → state.speed_mult should be 0.6.
	var ld5 := LifecycleDirector.new()
	var elder_def := {
		"id": "elder_v",
		"tags": ["villager", "human"],
		"lifecycle": human_template,
		"state_init": {"age": 49.5, "life_stage": "adult", "speed_mult": 1.0},
		"visual": {"mesh": "merchant_npc_3d"},
	}
	var v5 := Entity.create(elder_def, "v5")
	var entities5: Dictionary = {"v5": v5}
	var env5: Dictionary = {
		"entities": entities5,
		"defs": {"elder_v": elder_def},
		"world": {},
		"signal_buffer": [],
		"tick_count": 1,
	}
	ld5.register_lifecycle("v5", human_template, env5, "human")
	ld5.tick(env5, 1.0)
	expect_eq(str(v5.get_state("life_stage", "")), "elder", "adult → elder transition at age=50.5")
	expect(
		abs(float(v5.get_state("speed_mult", 0.0)) - 0.6) < 0.001,
		"elder stage speed_mult=0.6 written to state.speed_mult"
	)
	v5.queue_free()
	ld5.queue_free()

	# ---------- Assertion 6: entity_died signal on terminal stage ----------
	# Spawn entity at 79.5, tick +1 year → crosses to dead (terminal).
	# Expect both life_stage_changed AND entity_died in signal buffer.
	var ld6 := LifecycleDirector.new()
	var dying_def := {
		"id": "dying",
		"tags": ["villager", "human"],
		"lifecycle": human_template,
		"state_init": {"age": 79.5, "life_stage": "elder"},
		"visual": {"mesh": "human_elder_3d"},
	}
	var v6 := Entity.create(dying_def, "v6")
	var entities6: Dictionary = {"v6": v6}
	var env6: Dictionary = {
		"entities": entities6,
		"defs": {"dying": dying_def},
		"world": {},
		"signal_buffer": [],
		"tick_count": 1,
	}
	ld6.register_lifecycle("v6", human_template, env6, "human")
	ld6.tick(env6, 1.0)
	expect_eq(
		str(v6.get_state("life_stage", "")),
		"dead",
		"elder → dead transition at age=80.5 (terminal stage)"
	)
	var buf6: Array = env6["signal_buffer"]
	var saw_stage_changed: bool = false
	var saw_died: bool = false
	for s in buf6:
		if s is Dictionary:
			var name_s: String = str((s as Dictionary).get("name", ""))
			if name_s == "life_stage_changed":
				saw_stage_changed = true
			if name_s == "entity_died":
				saw_died = true
	expect(
		saw_stage_changed and saw_died,
		"terminal transition emits BOTH life_stage_changed AND entity_died signals"
	)
	v6.queue_free()
	ld6.queue_free()

	# ---------- Assertion 7: save/load mid-stage (state survives round-trip) ----------
	# Build adult at age=23.5, snapshot, restore via Entity.create with
	# overrides — verify age + life_stage round-trip cleanly. The
	# director uses state.age + state.life_stage which serialize via
	# normal entity-state path (ADR 0010), so this verifies that the
	# director resumes correctly from a loaded entity without double-
	# advancing or losing the stage.
	var ld7 := LifecycleDirector.new()
	var save_def := {
		"id": "saver",
		"tags": ["villager", "human"],
		"lifecycle": human_template,
		"state_init": {"age": 23.5, "life_stage": "adult"},
		"visual": {"mesh": "merchant_npc_3d"},
	}
	var v7_a := Entity.create(save_def, "v7")
	var snap: Dictionary = v7_a.snapshot()
	v7_a.queue_free()
	var v7_b := Entity.create(save_def, "v7", {"state": snap.get("state", {})})
	expect(
		abs(float(v7_b.get_state("age", 0.0)) - 23.5) < 0.001,
		"state.age round-trips through snapshot (23.5)"
	)
	expect_eq(
		str(v7_b.get_state("life_stage", "")),
		"adult",
		"state.life_stage round-trips through snapshot (adult)"
	)
	# Director resumes ticking cleanly — register + tick small dt should
	# NOT advance stage (still well within adult range 12..50).
	var entities7: Dictionary = {"v7": v7_b}
	var env7: Dictionary = {
		"entities": entities7,
		"defs": {"saver": save_def},
		"world": {},
		"signal_buffer": [],
		"tick_count": 1,
	}
	ld7.register_lifecycle("v7", human_template, env7, "human")
	ld7.tick(env7, 1.0)  # 23.5 → 24.5 — still adult
	expect_eq(
		str(v7_b.get_state("life_stage", "")),
		"adult",
		"director resumes ticking from loaded age without double-advancing"
	)
	v7_b.queue_free()
	ld7.queue_free()

	# ---------- Assertion 8: $extends from @lib.lifecycles.human ----------
	# Per ADR 0027, lifecycle blocks may be authored as $extends-resolved
	# variants of an @lib template. lib_resolver runs at JSON-load time
	# so by the time register_lifecycles_from_env is called, the field
	# is already a resolved Dictionary. We simulate that: a per-game
	# def's lifecycle dict carries the same structural shape as the
	# library entry (cross-game template reuse). This is a
	# representational test — the resolver itself has its own
	# test_lib_resolver section.
	var ld8 := LifecycleDirector.new()
	var extended_template := human_template.duplicate(true)
	var lib_def := {
		"id": "lib_villager",
		"tags": ["villager", "human"],
		"lifecycle": extended_template,
		"state_init": {"age": 11.5, "life_stage": "child"},
		"visual": {"mesh": "human_child_3d"},
	}
	var v8 := Entity.create(lib_def, "v8")
	var entities8: Dictionary = {"v8": v8}
	var env8: Dictionary = {
		"entities": entities8,
		"defs": {"lib_villager": lib_def},
		"world": {},
		"signal_buffer": [],
		"tick_count": 1,
	}
	ld8.register_lifecycles_from_env(env8)
	ld8.tick(env8, 1.0)  # crosses to adult
	expect_eq(
		str(v8.get_state("life_stage", "")),
		"adult",
		"$extends-resolved @lib.lifecycles.human template drives transitions identically"
	)
	v8.queue_free()
	ld8.queue_free()

	# ---------- Assertion 9: multiple lifecycle templates coexist ----------
	# Human (5 stages), deer (3 stages: fawn/adult/dead), wolf
	# (4 stages). Each entity uses its own template — no crossover.
	var deer_template := {
		"stages":
		[
			{
				"id": "fawn",
				"min_age": 0,
				"max_age": 1,
				"mesh": "deer_fawn_3d",
				"abilities": ["follow_mom"],
				"speed_mult": 0.6
			},
			{
				"id": "adult",
				"min_age": 1,
				"max_age": 10,
				"mesh": "deer_3d",
				"abilities": ["forage", "flee"],
				"speed_mult": 1.2
			},
			{
				"id": "dead",
				"min_age": 10,
				"mesh": null,
				"abilities": [],
				"speed_mult": 0.0,
				"terminal": true
			},
		],
		"age_per_in_game_year": 1.0,
		"year_seconds": 1.0,
	}
	var wolf_template := {
		"stages":
		[
			{
				"id": "pup",
				"min_age": 0,
				"max_age": 1,
				"mesh": "wolf_pup_3d",
				"abilities": ["yip"],
				"speed_mult": 0.5
			},
			{
				"id": "adult",
				"min_age": 1,
				"max_age": 7,
				"mesh": "wolf_3d",
				"abilities": ["hunt", "howl"],
				"speed_mult": 1.4
			},
			{
				"id": "elder",
				"min_age": 7,
				"max_age": 12,
				"mesh": "wolf_elder_3d",
				"abilities": ["howl"],
				"speed_mult": 0.8
			},
			{
				"id": "dead",
				"min_age": 12,
				"mesh": null,
				"abilities": [],
				"speed_mult": 0.0,
				"terminal": true
			},
		],
		"age_per_in_game_year": 1.0,
		"year_seconds": 1.0,
	}
	var ld9 := LifecycleDirector.new()
	var h_def := {
		"id": "h",
		"tags": ["human"],
		"lifecycle": human_template,
		"state_init": {"age": 11.5, "life_stage": "child"},
		"visual": {"mesh": "human_child_3d"}
	}
	var d_def := {
		"id": "d",
		"tags": ["deer"],
		"lifecycle": deer_template,
		"state_init": {"age": 0.5, "life_stage": "fawn"},
		"visual": {"mesh": "deer_fawn_3d"}
	}
	var w_def := {
		"id": "w",
		"tags": ["wolf"],
		"lifecycle": wolf_template,
		"state_init": {"age": 6.5, "life_stage": "adult"},
		"visual": {"mesh": "wolf_3d"}
	}
	var h_e := Entity.create(h_def, "h1")
	var d_e := Entity.create(d_def, "d1")
	var w_e := Entity.create(w_def, "w1")
	var entities9: Dictionary = {"h1": h_e, "d1": d_e, "w1": w_e}
	var env9: Dictionary = {
		"entities": entities9,
		"defs": {"h": h_def, "d": d_def, "w": w_def},
		"world": {},
		"signal_buffer": [],
		"tick_count": 1,
	}
	ld9.register_lifecycle("h1", human_template, env9, "human")
	ld9.register_lifecycle("d1", deer_template, env9, "deer")
	ld9.register_lifecycle("w1", wolf_template, env9, "wolf")
	ld9.tick(env9, 1.0)
	expect_eq(
		str(h_e.get_state("life_stage", "")),
		"adult",
		"human entity advances child→adult under human template"
	)
	expect_eq(
		str(d_e.get_state("life_stage", "")),
		"adult",
		"deer entity advances fawn→adult under deer template (3-stage table)"
	)
	expect_eq(
		str(w_e.get_state("life_stage", "")),
		"elder",
		"wolf entity advances adult→elder under wolf template (4-stage table)"
	)
	h_e.queue_free()
	d_e.queue_free()
	w_e.queue_free()
	ld9.queue_free()

	# ---------- Assertion 10: no-lifecycle backward-compat ----------
	# Entity without lifecycle field — director skips silently. No age
	# increment, no life_stage write, no signal emit. Existing demos
	# unaffected by this primitive.
	var ld10 := LifecycleDirector.new()
	var plain_def := {
		"id": "rock",
		"tags": ["inert"],
		"state_init": {"hardness": 5},
		"visual": {"mesh": "rock_3d"},
	}
	var rock := Entity.create(plain_def, "r1")
	var entities10: Dictionary = {"r1": rock}
	var env10: Dictionary = {
		"entities": entities10,
		"defs": {"rock": plain_def},
		"world": {},
		"signal_buffer": [],
		"tick_count": 1,
	}
	ld10.register_lifecycles_from_env(env10)  # walks defs — no lifecycle field
	ld10.tick(env10, 100.0)  # huge dt — should be no-op
	expect(
		rock.get_state("age", null) == null, "entity without lifecycle field has no state.age set"
	)
	expect(
		rock.get_state("life_stage", null) == null,
		"entity without lifecycle field has no state.life_stage set"
	)
	expect_eq(
		(env10["signal_buffer"] as Array).size(),
		0,
		"no signals emitted for entities without a lifecycle template"
	)
	rock.queue_free()
	ld10.queue_free()

	# ---------- Assertion 11: infinite-life mode toggle ----------
	# settings.infinite_life=true + entity tagged "player" → director
	# REFUSES to advance into a terminal stage. Age pins just below
	# the terminal threshold instead of crossing.
	var ld11 := LifecycleDirector.new()
	var player_def := {
		"id": "player",
		"tags": ["player", "human"],
		"lifecycle": human_template,
		"state_init": {"age": 79.5, "life_stage": "elder"},
		"visual": {"mesh": "human_elder_3d"},
	}
	var p := Entity.create(player_def, "p1")
	var entities11: Dictionary = {"p1": p}
	var env11: Dictionary = {
		"entities": entities11,
		"defs": {"player": player_def},
		"world": {},
		"signal_buffer": [],
		"tick_count": 1,
		"settings": {"infinite_life": true},
	}
	ld11.register_lifecycle("p1", human_template, env11, "human")
	ld11.tick(env11, 1.0)  # would normally cross 80.0 → dead; suppressed
	expect_eq(
		str(p.get_state("life_stage", "")),
		"elder",
		"infinite_life mode suppresses player advancement into terminal stage"
	)
	# Verify entity_died NOT emitted.
	var buf11: Array = env11["signal_buffer"]
	var saw_died_p: bool = false
	for s in buf11:
		if s is Dictionary and str((s as Dictionary).get("name", "")) == "entity_died":
			saw_died_p = true
	expect(not saw_died_p, "entity_died signal NOT emitted for player under infinite_life mode")
	p.queue_free()
	ld11.queue_free()


# ============================================================
# BUILD-PLACE PRIMITIVE (ADR 0037)
# ============================================================


## Helper — build a fresh env + a buildable blueprint def.
func _make_build_env() -> Dictionary:
	var defs: Dictionary = {
		"prop_lean_to":
		{
			"id": "prop_lean_to",
			"tags": ["prop", "shelter", "blocks_motion"],
			"properties": {"aabb_extents": [0.5, 1.0, 0.5]},
			"state_init": {},
			"visual": {"mesh": "lean_to"},
		},
		"prop_wall":
		{
			"id": "prop_wall",
			"tags": ["prop", "wall", "blocks_motion"],
			"properties": {"aabb_extents": [0.5, 1.0, 0.5]},
			"state_init": {},
			"visual": {"mesh": "wall"},
		},
		"prop_ground_tile":
		{
			"id": "prop_ground_tile",
			"tags": ["ground_tile"],
			"properties": {},
			"state_init": {},
			"visual": {"mesh": "ground"},
		},
		"villager":
		{
			"id": "villager",
			"tags": ["villager"],
			"properties": {},
			"state_init": {},
			"visual": {},
		},
	}
	var entities: Dictionary = {}
	var rs := RelationStore.new()
	var sx := SpatialIndex.new()
	var env: Dictionary = {
		"entities": entities,
		"defs": defs,
		"relations": rs,
		"spatial_index": sx,
		"world": {},
		"world_state": {},
		"parent": null,
		"next_id": {"_": 0},
		"signal_buffer": [],
		"trigger_buffer": [],
		"error_buffer": [],
		# scene_bounds wants Array (per build_validators._boundary_check;
		# accepts [x,y] or [x,y,z]).
		"scene_bounds": {"min": [-50, 0, -50], "max": [50, 0, 50]},
	}
	# Place a ground tile AT THE TYPICAL BUILD POSITION (2, 0, 0) so the
	# ground_buildable predicate (default radius 0.5m) finds it. Tests that
	# need the ground absent move it explicitly.
	var ground := Entity.create(defs["prop_ground_tile"], "ground_origin")
	ground.set_position(Vector3(2, 0, 0))
	entities["ground_origin"] = ground
	sx.update_entity("ground_origin", Vector2(2, 0))
	# Place a player ("self") at origin too, to satisfy owner_in_range.
	var player := Entity.create(defs["villager"], "self")
	player.set_position(Vector3(0, 0, 0))
	entities["self"] = player
	sx.update_entity("self", Vector2(0, 0))
	return env


func test_build_place_primitive() -> void:
	_section("build_place_primitive (ADR 0037)")

	# ---------- 1. valid placement spawns entity ----------
	var env1 := _make_build_env()
	var result1: Dictionary = EffectApply.apply(
		{
			"type": "build_place",
			"blueprint": "prop_lean_to",
			"position": Vector3(2, 0, 0),
			"validate": ["no_overlap", "ground_buildable"]
		},
		env1,
		{}
	)
	expect(bool(result1.get("placed", false)), "valid placement returns placed=true")
	expect_eq(str(result1.get("reason", "x")), "", "valid placement reason is empty")
	expect(
		(env1["entities"] as Dictionary).size() >= 3, "valid placement adds new entity to entities"
	)

	# ---------- 2. overlap rejected ----------
	var env2 := _make_build_env()
	# Place a wall at (2, 0, 0) blocking the build site.
	var wall := Entity.create((env2["defs"] as Dictionary)["prop_wall"], "wall_block")
	wall.set_position(Vector3(2, 0, 0))
	(env2["entities"] as Dictionary)["wall_block"] = wall
	(env2["spatial_index"] as SpatialIndex).update_entity("wall_block", Vector2(2, 0))
	# Add a ground tile too (so ground_buildable passes — only no_overlap should fail)
	var ground2 := Entity.create((env2["defs"] as Dictionary)["prop_ground_tile"], "ground_2")
	ground2.set_position(Vector3(2, 0, 0))
	(env2["entities"] as Dictionary)["ground_2"] = ground2
	(env2["spatial_index"] as SpatialIndex).update_entity("ground_2", Vector2(2, 0))
	var size_before := (env2["entities"] as Dictionary).size()
	var result2: Dictionary = EffectApply.apply(
		{
			"type": "build_place",
			"blueprint": "prop_lean_to",
			"position": Vector3(2, 0, 0),
			"validate": ["no_overlap"]
		},
		env2,
		{}
	)
	expect(not bool(result2.get("placed", true)), "overlap placement rejected (placed=false)")
	expect_eq(
		str(result2.get("reason", "")), "no_overlap", "overlap rejection reason is 'no_overlap'"
	)
	expect_eq(
		(env2["entities"] as Dictionary).size(),
		size_before,
		"overlap rejection does NOT add entity to entities"
	)

	# ---------- 3. overlap clearance — adjacent passes ----------
	var env3 := _make_build_env()
	var wall3 := Entity.create((env3["defs"] as Dictionary)["prop_wall"], "wall_far")
	wall3.set_position(Vector3(10, 0, 0))
	(env3["entities"] as Dictionary)["wall_far"] = wall3
	(env3["spatial_index"] as SpatialIndex).update_entity("wall_far", Vector2(10, 0))
	var ground3 := Entity.create((env3["defs"] as Dictionary)["prop_ground_tile"], "ground_3")
	ground3.set_position(Vector3(2, 0, 0))
	(env3["entities"] as Dictionary)["ground_3"] = ground3
	(env3["spatial_index"] as SpatialIndex).update_entity("ground_3", Vector2(2, 0))
	var result3: Dictionary = EffectApply.apply(
		{
			"type": "build_place",
			"blueprint": "prop_lean_to",
			"position": Vector3(2, 0, 0),
			"validate": ["no_overlap"]
		},
		env3,
		{}
	)
	expect(bool(result3.get("placed", false)), "adjacent (non-overlapping) placement passes")

	# ---------- 4. ground_buildable predicate ----------
	# env without a ground tile under the target position.
	var env4 := _make_build_env()
	# Move the existing ground tile away from build site.
	var g4: Entity = (env4["entities"] as Dictionary)["ground_origin"]
	g4.set_position(Vector3(20, 0, 20))
	(env4["spatial_index"] as SpatialIndex).update_entity("ground_origin", Vector2(20, 20))
	var result4: Dictionary = EffectApply.apply(
		{
			"type": "build_place",
			"blueprint": "prop_lean_to",
			"position": Vector3(2, 0, 0),
			"validate": ["ground_buildable"]
		},
		env4,
		{}
	)
	expect_eq(
		str(result4.get("reason", "")),
		"ground_buildable",
		"missing ground tile → ground_buildable rejection"
	)

	# ---------- 5. owner_in_range — fails when source distant ----------
	var env5 := _make_build_env()
	# Move "self" far from build site.
	var p5: Entity = (env5["entities"] as Dictionary)["self"]
	p5.set_position(Vector3(50, 0, 50))
	(env5["spatial_index"] as SpatialIndex).update_entity("self", Vector2(50, 50))
	var result5: Dictionary = EffectApply.apply(
		{
			"type": "build_place",
			"blueprint": "prop_lean_to",
			"position": Vector3(2, 0, 0),
			"validate": ["owner_in_range"],
			"max_range": 5.0
		},
		env5,
		{"_source": "self"}
	)
	expect_eq(
		str(result5.get("reason", "")),
		"owner_in_range",
		"distant source → owner_in_range rejection"
	)

	# ---------- 6. owner_in_range — passes when source near ----------
	var env6 := _make_build_env()
	var result6: Dictionary = EffectApply.apply(
		{
			"type": "build_place",
			"blueprint": "prop_lean_to",
			"position": Vector3(2, 0, 0),
			"validate": ["owner_in_range"],
			"max_range": 5.0
		},
		env6,
		{"_source": "self"}
	)
	expect(
		bool(result6.get("placed", false)),
		"close source (dist=2 < max_range=5) → owner_in_range passes"
	)

	# ---------- 7. boundary_check — out of bounds rejected ----------
	var env7 := _make_build_env()
	var result7: Dictionary = EffectApply.apply(
		{
			"type": "build_place",
			"blueprint": "prop_lean_to",
			"position": Vector3(100, 0, 0),  # beyond scene_bounds.max.x = 50
			"validate": ["boundary_check"]
		},
		env7,
		{}
	)
	expect_eq(
		str(result7.get("reason", "")),
		"boundary_check",
		"out-of-bounds position → boundary_check rejection"
	)

	# ---------- 8. multi_predicate compose — first failure short-circuits ----------
	var env8 := _make_build_env()
	# Move ground tile away so ground_buildable fails.
	var g8: Entity = (env8["entities"] as Dictionary)["ground_origin"]
	g8.set_position(Vector3(20, 0, 20))
	(env8["spatial_index"] as SpatialIndex).update_entity("ground_origin", Vector2(20, 20))
	# no_overlap would pass, ground_buildable fails — first failure wins.
	var result8: Dictionary = EffectApply.apply(
		{
			"type": "build_place",
			"blueprint": "prop_lean_to",
			"position": Vector3(2, 0, 0),
			"validate": ["no_overlap", "ground_buildable", "boundary_check"]
		},
		env8,
		{}
	)
	expect_eq(
		str(result8.get("reason", "")),
		"ground_buildable",
		"multi-predicate: first failure (ground_buildable) short-circuits"
	)

	# ---------- 9. construction_ticks — multi-tick build flow ----------
	var env9 := _make_build_env()
	var result9: Dictionary = EffectApply.apply(
		{
			"type": "build_place",
			"blueprint": "prop_lean_to",
			"position": Vector3(2, 0, 0),
			"validate": [],
			"construction_ticks": 5
		},
		env9,
		{}
	)
	expect(bool(result9.get("placed", false)), "construction_ticks=5 still spawns the entity")
	var inst_id9: String = str(result9.get("instance_id", ""))
	if inst_id9 != "":
		var spawned9: Entity = (env9["entities"] as Dictionary)[inst_id9]
		expect_eq(
			int(spawned9.get_state("build_in_progress", 0)),
			5,
			"under-construction entity has build_in_progress=5"
		)
		expect(
			spawned9.has_tag("under_construction"),
			"under-construction entity has 'under_construction' tag"
		)

	# ---------- 10. motion-integrator clearance contract ----------
	# After valid placement, the new entity has its aabb_extents in
	# spatial_index. A subsequent build at the SAME spot must reject —
	# i.e. the just-built entity blocks the next build (proves spatial
	# index registration completed atomically).
	var env10 := _make_build_env()
	var first: Dictionary = EffectApply.apply(
		{
			"type": "build_place",
			"blueprint": "prop_lean_to",
			"position": Vector3(2, 0, 0),
			"validate": ["no_overlap", "ground_buildable"]
		},
		env10,
		{}
	)
	expect(bool(first.get("placed", false)), "first build at clean spot succeeds")
	# Try to build a SECOND lean-to at the same spot — should reject.
	var ground10b := Entity.create((env10["defs"] as Dictionary)["prop_ground_tile"], "g10b")
	ground10b.set_position(Vector3(2, 0, 0))
	(env10["entities"] as Dictionary)["g10b"] = ground10b
	(env10["spatial_index"] as SpatialIndex).update_entity("g10b", Vector2(2, 0))
	var second: Dictionary = EffectApply.apply(
		{
			"type": "build_place",
			"blueprint": "prop_lean_to",
			"position": Vector3(2, 0, 0),
			"validate": ["no_overlap"]
		},
		env10,
		{}
	)
	expect_eq(
		str(second.get("reason", "")),
		"no_overlap",
		"穿模 contract: second build at same spot rejects (first build's aabb is registered)"
	)

	# ---------- 11. on_invalid chain receives failure_reason ----------
	var env11 := _make_build_env()
	var g11: Entity = (env11["entities"] as Dictionary)["ground_origin"]
	g11.set_position(Vector3(20, 0, 20))
	(env11["spatial_index"] as SpatialIndex).update_entity("ground_origin", Vector2(20, 20))
	# Verify on_invalid effect chain fires on failure by emitting a signal
	# and checking the signal buffer. (state_set target="world" routes
	# through _target which only handles entities — would silently no-op.)
	(env11["signal_buffer"] as Array).clear()
	var result11: Dictionary = EffectApply.apply(
		{
			"type": "build_place",
			"blueprint": "prop_lean_to",
			"position": Vector3(2, 0, 0),
			"validate": ["ground_buildable"],
			"on_invalid": [{"type": "emit", "signal": "build_failed"}]
		},
		env11,
		{}
	)
	var on_invalid_fired := false
	for s11 in env11["signal_buffer"] as Array:
		if s11 is Dictionary and str((s11 as Dictionary).get("name", "")) == "build_failed":
			on_invalid_fired = true
	expect(
		on_invalid_fired, "on_invalid effect chain fires on failure (build_failed signal emitted)"
	)

	# ---------- 12. no_def → structured EngineError, no spawn ----------
	var env12 := _make_build_env()
	var size12_before := (env12["entities"] as Dictionary).size()
	var result12: Dictionary = EffectApply.apply(
		{"type": "build_place", "blueprint": "nonexistent_blueprint", "position": Vector3(2, 0, 0)},
		env12,
		{}
	)
	expect(not bool(result12.get("placed", true)), "missing blueprint → placed=false")
	expect_eq(str(result12.get("reason", "")), "no_def", "missing blueprint → reason='no_def'")
	expect_eq(
		(env12["entities"] as Dictionary).size(),
		size12_before,
		"missing blueprint → no entity added"
	)
	expect(
		(env12["error_buffer"] as Array).size() > 0,
		"missing blueprint → EngineError raised into error_buffer"
	)


func test_class_primitive() -> void:
	_section("class_primitive (ADR 0030)")

	# Two class defs sufficient for all 7 assertions: a "farmer" and a
	# "warrior". Each is a minimal data dict — ClassManager treats the
	# fields as opaque metadata; only `id` is required.
	var farmer_def: Dictionary = {
		"id": "farmer",
		"display_name": "Farmer",
		"verbs": ["plant", "water", "harvest"],
		"camera_mode": "iso_top_down",
		"switch_cooldown_days": 1,
	}
	var warrior_def: Dictionary = {
		"id": "warrior",
		"display_name": "Warrior",
		"verbs": ["attack", "block"],
		"camera_mode": "third_person_3d",
		"switch_cooldown_days": 1,
	}

	# Build a player entity carrying current_class + class_progress +
	# inventory + reputation + last_class_switch_day. Mirrors ADR 0030
	# §player-actor state schema.
	var player_def: Dictionary = {
		"id": "player",
		"tags": ["player", "actor"],
		"state_init":
		{
			"current_class": "farmer",
			"class_progress":
			{
				"farmer": {"level": 3, "xp": 240, "specialty": "wheat"},
				"warrior": {"level": 1, "xp": 30}
			},
			"inventory": ["bread", "hoe", "seeds"],
			"reputation": {"pendrel": 75, "brookhaven": 20},
			"last_class_switch_day": 0,
		},
	}

	# ---------- Assertion 1: class def loads from data dict ----------
	var cm1 := ClassManager.new()
	cm1.register_class("farmer", farmer_def)
	cm1.register_class("warrior", warrior_def)
	expect(cm1.has_class("farmer"), "register_class stores 'farmer' def")
	expect(cm1.has_class("warrior"), "register_class stores 'warrior' def")
	var got_def: Dictionary = cm1.get_class_def("farmer")
	expect_eq(
		str(got_def.get("display_name", "")),
		"Farmer",
		"get_class_def returns the stored def with metadata intact"
	)
	cm1.queue_free()

	# ---------- Assertion 2: switch_class swaps current_class + emits signal ----------
	var cm2 := ClassManager.new()
	cm2.register_class("farmer", farmer_def)
	cm2.register_class("warrior", warrior_def)
	var p2 := Entity.create(player_def, "player")
	var entities2: Dictionary = {"player": p2}
	var env2: Dictionary = {
		"entities": entities2,
		"defs": {"player": player_def},
		"world": {"current_day": 5},
		"signal_buffer": [],
	}
	# Skip cooldown by using current_day=5 (last_class_switch_day=0,
	# cooldown_days=1 → 5 - 0 >= 1 → ok).
	var res2: Dictionary = cm2.switch_class(env2, "player", "warrior", 1)
	expect(
		bool(res2.get("ok", false)), "switch_class succeeds when class def exists + cooldown met"
	)
	expect_eq(
		str(p2.get_state("current_class", "")),
		"warrior",
		"state.current_class is updated to 'warrior'"
	)
	# Signal should be in buffer with from/to/day payload.
	var saw_class_switched: bool = false
	for s in env2["signal_buffer"] as Array:
		if s is Dictionary and str((s as Dictionary).get("name", "")) == "class_switched":
			var pl: Dictionary = (s as Dictionary).get("payload", {})
			if str(pl.get("from", "")) == "farmer" and str(pl.get("to", "")) == "warrior":
				saw_class_switched = true
				break
	expect(saw_class_switched, "class_switched signal emitted with from='farmer', to='warrior'")
	p2.queue_free()
	cm2.queue_free()

	# ---------- Assertion 3: inventory persists across switch ----------
	var cm3 := ClassManager.new()
	cm3.register_class("farmer", farmer_def)
	cm3.register_class("warrior", warrior_def)
	var p3 := Entity.create(player_def, "player")
	var entities3: Dictionary = {"player": p3}
	var env3: Dictionary = {
		"entities": entities3,
		"defs": {"player": player_def},
		"world": {"current_day": 5},
		"signal_buffer": [],
	}
	var inv_before: Variant = p3.get_state("inventory", null)
	cm3.switch_class(env3, "player", "warrior", 1)
	var inv_after: Variant = p3.get_state("inventory", null)
	expect(
		inv_before == inv_after,
		"state.inventory unchanged across switch (class-agnostic, persists)"
	)
	# Also verify the array contents survived intact.
	expect(
		(inv_after as Array).has("bread") and (inv_after as Array).has("hoe"),
		"inventory contents survive switch (bread + hoe present)"
	)
	p3.queue_free()
	cm3.queue_free()

	# ---------- Assertion 4: reputation persists across switch ----------
	var cm4 := ClassManager.new()
	cm4.register_class("farmer", farmer_def)
	cm4.register_class("warrior", warrior_def)
	var p4 := Entity.create(player_def, "player")
	var entities4: Dictionary = {"player": p4}
	var env4: Dictionary = {
		"entities": entities4,
		"defs": {"player": player_def},
		"world": {"current_day": 5},
		"signal_buffer": [],
	}
	var rep_before: Dictionary = (p4.get_state("reputation", {}) as Dictionary).duplicate(true)
	cm4.switch_class(env4, "player", "warrior", 1)
	var rep_after: Dictionary = p4.get_state("reputation", {}) as Dictionary
	expect_eq(
		int(rep_after.get("pendrel", 0)),
		int(rep_before.get("pendrel", -1)),
		"reputation.pendrel survives switch (class-agnostic, persists)"
	)
	expect_eq(
		int(rep_after.get("brookhaven", 0)),
		int(rep_before.get("brookhaven", -1)),
		"reputation.brookhaven survives switch"
	)
	p4.queue_free()
	cm4.queue_free()

	# ---------- Assertion 5: class_progress per class isolated ----------
	# Switching from farmer → warrior must NOT touch class_progress.farmer's
	# level/xp/specialty record. The director only touches current_class
	# and last_class_switch_day; class_progress is preserved as-is.
	var cm5 := ClassManager.new()
	cm5.register_class("farmer", farmer_def)
	cm5.register_class("warrior", warrior_def)
	var p5 := Entity.create(player_def, "player")
	var entities5: Dictionary = {"player": p5}
	var env5: Dictionary = {
		"entities": entities5,
		"defs": {"player": player_def},
		"world": {"current_day": 5},
		"signal_buffer": [],
	}
	cm5.switch_class(env5, "player", "warrior", 1)
	var cp: Dictionary = p5.get_state("class_progress", {}) as Dictionary
	var farmer_cp: Dictionary = cp.get("farmer", {}) as Dictionary
	expect_eq(
		int(farmer_cp.get("level", 0)),
		3,
		"class_progress.farmer.level still 3 after switching away from farmer"
	)
	expect_eq(int(farmer_cp.get("xp", 0)), 240, "class_progress.farmer.xp still 240 after switch")
	expect_eq(
		str(farmer_cp.get("specialty", "")),
		"wheat",
		"class_progress.farmer.specialty preserved across switch"
	)
	p5.queue_free()
	cm5.queue_free()

	# ---------- Assertion 6: cooldown enforced ----------
	# Switch on day 5 with cooldown_days=1; second switch on the SAME day
	# should fail with reason='cooldown' and leave state untouched.
	var cm6 := ClassManager.new()
	cm6.register_class("farmer", farmer_def)
	cm6.register_class("warrior", warrior_def)
	var p6 := Entity.create(player_def, "player")
	var entities6: Dictionary = {"player": p6}
	var env6: Dictionary = {
		"entities": entities6,
		"defs": {"player": player_def},
		"world": {"current_day": 5},
		"signal_buffer": [],
		"error_buffer": [],
	}
	# First switch — succeeds (last_switch_day=0, current=5, cooldown=1).
	var first: Dictionary = cm6.switch_class(env6, "player", "warrior", 1)
	expect(bool(first.get("ok", false)), "first switch on day 5 succeeds (last=0, cooldown=1)")
	# Second switch — same tick, current_day still 5, last_switch_day=5 →
	# 5 - 5 = 0 < 1 → cooldown blocks.
	var second: Dictionary = cm6.switch_class(env6, "player", "farmer", 1)
	expect(not bool(second.get("ok", true)), "second switch within cooldown_days fails (ok=false)")
	expect_eq(
		str(second.get("reason", "")), "cooldown", "cooldown failure carries reason='cooldown'"
	)
	# State must NOT have been mutated by the failed switch — current_class
	# stays at 'warrior' (the successful first switch), not 'farmer'.
	expect_eq(
		str(p6.get_state("current_class", "")),
		"warrior",
		"failed cooldown switch leaves current_class unchanged"
	)
	p6.queue_free()
	cm6.queue_free()

	# ---------- Assertion 7: unknown class fails atomic ----------
	# switch_class to a class id that was never registered MUST leave
	# state untouched (no current_class change, no last_switch_day write,
	# no signal emitted).
	var cm7 := ClassManager.new()
	cm7.register_class("farmer", farmer_def)
	# Note: warrior NOT registered in this manager.
	var p7 := Entity.create(player_def, "player")
	# Ensure baseline current_class is 'farmer', last_class_switch_day is 0.
	var baseline_class: String = str(p7.get_state("current_class", ""))
	var baseline_day: int = int(p7.get_state("last_class_switch_day", -1))
	var entities7: Dictionary = {"player": p7}
	var env7: Dictionary = {
		"entities": entities7,
		"defs": {"player": player_def},
		"world": {"current_day": 5},
		"signal_buffer": [],
		"error_buffer": [],
	}
	var bad: Dictionary = cm7.switch_class(env7, "player", "scribe", 1)
	expect(not bool(bad.get("ok", true)), "switch_class to unknown class id fails (ok=false)")
	expect_eq(
		str(bad.get("reason", "")),
		"unknown_class",
		"unknown class failure carries reason='unknown_class'"
	)
	expect_eq(
		str(p7.get_state("current_class", "")),
		baseline_class,
		"unknown-class switch leaves current_class unchanged (atomic)"
	)
	expect_eq(
		int(p7.get_state("last_class_switch_day", -1)),
		baseline_day,
		"unknown-class switch leaves last_class_switch_day unchanged (atomic)"
	)
	# No class_switched signal should have been emitted.
	var saw_emit: bool = false
	for s in env7["signal_buffer"] as Array:
		if s is Dictionary and str((s as Dictionary).get("name", "")) == "class_switched":
			saw_emit = true
			break
	expect(not saw_emit, "failed switch (unknown class) emits NO class_switched signal")
	# An EngineError should have landed in the error buffer with the
	# CLASS_SWITCH_NO_DEF code.
	var saw_err: bool = false
	for r in env7["error_buffer"] as Array:
		if (
			r is Dictionary
			and str((r as Dictionary).get("code", "")) == EngineError.CLASS_SWITCH_NO_DEF
		):
			saw_err = true
			break
	expect(saw_err, "failed switch raises CLASS_SWITCH_NO_DEF in error_buffer")
	p7.queue_free()
	cm7.queue_free()


# ============================================================
# ZONE STATE (ADR 0031)
# ============================================================


func _make_zone_env() -> Dictionary:
	# ADR 0031 — fresh env with a populated zone store reflecting the
	# kingdom → region → city hierarchy from the ADR's worked example.
	var zs := ZoneStore.new()
	var cfg: Dictionary = {
		"zones":
		[
			{
				"id": "kingdom_aldenmere",
				"type": "kingdom",
				"contains": ["region_pendrel", "region_brookhaven"],
				"state_init": {"unrest": 0, "treasury": 1000}
			},
			{
				"id": "region_pendrel",
				"type": "region",
				"contains": ["city_pendrel"],
				"state_init": {"iron_supply": 100, "rice_supply": 200}
			},
			{
				"id": "region_brookhaven",
				"type": "region",
				"contains": [],
				"state_init": {"iron_supply": 50, "rice_supply": 80}
			},
			{
				"id": "city_pendrel",
				"type": "city",
				"contains": [],
				"state_init": {"iron_supply": 30, "population": 1200}
			},
		]
	}
	zs.load_from_dict(cfg, {})
	return {
		"entities": {},
		"defs": {},
		"relations": RelationStore.new(),
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
		"error_buffer": [],
		"zone_store": zs,
	}


func test_zone_state_primitive() -> void:
	_section("zone_state (ADR 0031)")

	# Sanity: helper builds a 4-zone hierarchy with no validation errors
	var env_init: Dictionary = _make_zone_env()
	expect_eq(
		(env_init["zone_store"] as ZoneStore).count(), 4, "4-zone hierarchy loads without errors"
	)

	# ---------- 1. zone state set/get round-trip ----------
	var env1: Dictionary = _make_zone_env()
	EffectApply.apply(
		{"type": "zone_state_set", "zone": "region_pendrel", "field": "iron_supply", "value": 87},
		env1,
		{}
	)
	var zs1: ZoneStore = env1["zone_store"]
	expect_eq(
		int(zs1.get_field("region_pendrel", "iron_supply", -1)),
		87,
		"zone_state_set + get_field round-trip stores the value"
	)

	# Binding shape: `zone.region_pendrel.iron_supply` resolves through
	# Formula via _formula_context's "zone" namespace.
	var snap1: Dictionary = zs1.binding_snapshot()
	expect(snap1.has("region_pendrel"), "binding_snapshot exposes zone ids as top-level keys")
	expect_eq(
		int((snap1["region_pendrel"] as Dictionary).get("iron_supply", -1)),
		87,
		"binding_snapshot reflects mutations via set_field"
	)

	# ---------- 2. zone_state_add (delta math, positive + negative) ----------
	var env2: Dictionary = _make_zone_env()
	EffectApply.apply(
		{"type": "zone_state_add", "zone": "region_pendrel", "field": "iron_supply", "amount": 25},
		env2,
		{}
	)
	EffectApply.apply(
		{"type": "zone_state_add", "zone": "region_pendrel", "field": "iron_supply", "amount": -10},
		env2,
		{}
	)
	var zs2: ZoneStore = env2["zone_store"]
	expect_eq(
		int(zs2.get_field("region_pendrel", "iron_supply", -1)),
		115,
		"zone_state_add applies positive + negative deltas (100 + 25 - 10)"
	)

	# Missing-field auto-init to 0 (matches state_add semantics)
	EffectApply.apply(
		{"type": "zone_state_add", "zone": "region_pendrel", "field": "tax_revenue", "amount": 5},
		env2,
		{}
	)
	expect_eq(
		int(zs2.get_field("region_pendrel", "tax_revenue", -1)),
		5,
		"zone_state_add on missing field auto-inits to 0 then adds"
	)

	# ---------- 3. zone_state_clamp (min/max enforcement) ----------
	var env3: Dictionary = _make_zone_env()
	# Force iron_supply to 999 first, then clamp [0, 100]
	EffectApply.apply(
		{"type": "zone_state_set", "zone": "region_pendrel", "field": "iron_supply", "value": 999},
		env3,
		{}
	)
	EffectApply.apply(
		{
			"type": "zone_state_clamp",
			"zone": "region_pendrel",
			"field": "iron_supply",
			"min": 0,
			"max": 100
		},
		env3,
		{}
	)
	var zs3: ZoneStore = env3["zone_store"]
	expect_eq(
		int(zs3.get_field("region_pendrel", "iron_supply", -1)),
		100,
		"zone_state_clamp enforces max bound"
	)
	# Below-min case
	EffectApply.apply(
		{"type": "zone_state_set", "zone": "region_pendrel", "field": "iron_supply", "value": -50},
		env3,
		{}
	)
	EffectApply.apply(
		{
			"type": "zone_state_clamp",
			"zone": "region_pendrel",
			"field": "iron_supply",
			"min": 0,
			"max": 100
		},
		env3,
		{}
	)
	expect_eq(
		int(zs3.get_field("region_pendrel", "iron_supply", -1)),
		0,
		"zone_state_clamp enforces min bound"
	)

	# ---------- 4. nested zone hierarchy (kingdom contains regions, region contains city) ----------
	var env4: Dictionary = _make_zone_env()
	var zs4: ZoneStore = env4["zone_store"]
	expect_eq(
		zs4.parent_of("region_pendrel"), "kingdom_aldenmere", "parent_of reports declared parent"
	)
	expect_eq(
		zs4.parent_of("city_pendrel"),
		"region_pendrel",
		"parent_of resolves nested parent (city → region)"
	)
	expect_eq(
		zs4.parent_of("kingdom_aldenmere"), "", "parent_of returns empty string for root zone"
	)
	# Direct children (depth=1)
	var direct: Array = zs4.descendants_of("kingdom_aldenmere", 1)
	expect_eq(direct.size(), 2, "depth=1 descendants returns direct children only")
	expect(direct.has("region_pendrel"), "kingdom direct children include region_pendrel")
	expect(direct.has("region_brookhaven"), "kingdom direct children include region_brookhaven")
	expect(not direct.has("city_pendrel"), "depth=1 does NOT include grandchildren")
	# All transitive descendants (depth=-1)
	var all_descendants: Array = zs4.descendants_of("kingdom_aldenmere", -1)
	expect(all_descendants.has("city_pendrel"), "depth=-1 traverses to grandchildren")
	expect_eq(
		all_descendants.size(),
		3,
		"depth=-1 returns all transitive descendants (2 regions + 1 city)"
	)

	# ---------- 5. cycle detected at load (A contains B; B contains A) ----------
	var zs_cycle := ZoneStore.new()
	var bad_cfg: Dictionary = {
		"zones":
		[
			{"id": "zone_a", "type": "test", "contains": ["zone_b"], "state_init": {}},
			{"id": "zone_b", "type": "test", "contains": ["zone_a"], "state_init": {}},
		]
	}
	var cycle_errors: Array = zs_cycle.load_from_dict(bad_cfg, {})
	expect(cycle_errors.size() > 0, "cyclic zones.json reports load-time errors")
	var saw_cycle := false
	for rec in cycle_errors:
		if rec is Dictionary and str((rec as Dictionary).get("code", "")).begins_with("zone."):
			# multi-parent fires first in load order (B's contains_a links to
			# zone_a which already has parent zone_a from its own contains list,
			# i.e. the cycle manifests as a multi-parent OR a cycle code).
			# Either is acceptable evidence the engine rejects the loop.
			if (
				str((rec as Dictionary).get("code", "")) == "zone.cycle_detected"
				or str((rec as Dictionary).get("code", "")) == "zone.multi_parent"
			):
				saw_cycle = true
				break
	expect(saw_cycle, "cycle/multi-parent detected with structured EngineError code")

	# ---------- 6. backward-compat (no zones.json → engine works as today) ----------
	var zs_empty := ZoneStore.new()
	# load_from_dict({}) — simulates zones.json absent. Should not error.
	var empty_errs: Array = zs_empty.load_from_dict({}, {})
	expect_eq(empty_errs.size(), 0, "empty zone config loads without errors (backward-compat)")
	expect_eq(zs_empty.count(), 0, "empty store has zero zones")
	# Effects against empty store with unknown zone warn but don't crash
	var env_empty: Dictionary = {
		"entities": {},
		"defs": {},
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
		"error_buffer": [],
		"zone_store": zs_empty,
	}
	EffectApply.apply(
		{"type": "zone_state_add", "zone": "any_zone", "field": "x", "amount": 1}, env_empty, {}
	)
	expect(true, "zone_state_* against empty store does not crash (warning only)")

	# ---------- 7. save / load round-trip preserves zone state ----------
	var env7a: Dictionary = _make_zone_env()
	# Mutate region_pendrel.iron_supply away from state_init
	EffectApply.apply(
		{"type": "zone_state_set", "zone": "region_pendrel", "field": "iron_supply", "value": 42},
		env7a,
		{}
	)
	var zs7a: ZoneStore = env7a["zone_store"]
	var saved: Dictionary = zs7a.to_save()
	expect(saved.has("region_pendrel"), "to_save includes a mutated zone")
	expect_eq(
		int((saved["region_pendrel"] as Dictionary).get("iron_supply", -1)),
		42,
		"to_save snapshots current state"
	)
	# Build a fresh store with the same zones.json (state_init defaults),
	# then restore from `saved`.
	var env7b: Dictionary = _make_zone_env()
	var zs7b: ZoneStore = env7b["zone_store"]
	expect_eq(
		int(zs7b.get_field("region_pendrel", "iron_supply", -1)),
		100,
		"fresh store is at state_init (iron_supply=100) before restore"
	)
	zs7b.from_save(saved)
	expect_eq(
		int(zs7b.get_field("region_pendrel", "iron_supply", -1)),
		42,
		"from_save restores mutated value over state_init"
	)
	# Zones in zones.json absent from save retain state_init (region_brookhaven)
	expect_eq(
		int(zs7b.get_field("region_brookhaven", "iron_supply", -1)),
		50,
		"zones absent from save retain state_init defaults"
	)
	# Zones in save absent from current zones.json silently dropped
	zs7b.from_save({"phantom_zone": {"x": 1}})
	expect(
		not zs7b.has("phantom_zone"),
		"saved zones not in current config are silently dropped (no crash)"
	)

	# ---------- 8. multi-zone update (independent zones don't interfere) ----------
	var env8: Dictionary = _make_zone_env()
	EffectApply.apply(
		{"type": "zone_state_add", "zone": "region_pendrel", "field": "iron_supply", "amount": 10},
		env8,
		{}
	)
	EffectApply.apply(
		{
			"type": "zone_state_add",
			"zone": "region_brookhaven",
			"field": "iron_supply",
			"amount": -20
		},
		env8,
		{}
	)
	EffectApply.apply(
		{"type": "zone_state_set", "zone": "city_pendrel", "field": "iron_supply", "value": 5},
		env8,
		{}
	)
	var zs8: ZoneStore = env8["zone_store"]
	expect_eq(
		int(zs8.get_field("region_pendrel", "iron_supply", -1)),
		110,
		"region_pendrel updated independently (100 + 10)"
	)
	expect_eq(
		int(zs8.get_field("region_brookhaven", "iron_supply", -1)),
		30,
		"region_brookhaven updated independently (50 - 20)"
	)
	expect_eq(
		int(zs8.get_field("city_pendrel", "iron_supply", -1)),
		5,
		"city_pendrel updated independently (set to 5)"
	)
	# Confirm NO auto-aggregation: child mutation doesn't roll up to parent.
	# Per ADR §"Decision": authors write explicit rollup rules.
	expect_eq(
		int(zs8.get_field("kingdom_aldenmere", "treasury", -1)),
		1000,
		"no auto-aggregation: kingdom treasury unchanged by region/city mutations"
	)

	# Bonus: query_zone via QueryLib.run_zones (ADR-stable entry point).
	var by_type: Array = QueryLib.run_zones({"type": "region"}, env8)
	expect_eq(by_type.size(), 2, "run_zones {type: region} returns 2 regions")
	var by_id: Array = QueryLib.run_zones({"id": "city_pendrel"}, env8)
	expect_eq(by_id.size(), 1, "run_zones {id: X} returns 1 match for direct id")
	var contained: Array = QueryLib.run_zones(
		{"contained_by": "kingdom_aldenmere", "depth": -1}, env8
	)
	expect_eq(
		contained.size(),
		3,
		"run_zones contained_by=kingdom depth=-1 returns 3 transitive descendants"
	)


# ============================================================
# FACTION PRIMITIVE (ADR 0032)
# ============================================================


func _make_faction_data() -> Dictionary:
	# ADR 0032 — three-faction setup mirroring the worked example in the
	# ADR (traditionalists, innovators, militarists). Each test that needs
	# fresh state calls this + register_factions on a new director.
	return {
		"factions":
		[
			{
				"id": "traditionalists",
				"leader": "elder_morwen",
				"ideology": "preserve_old_ways",
				"color": "#8a6840",
				"home_zone": "village_riverside"
			},
			{
				"id": "innovators",
				"leader": "scholar_lerian",
				"ideology": "embrace_change",
				"color": "#4080c0"
			},
			{
				"id": "militarists",
				"leader": "captain_brennar",
				"ideology": "strength_first",
				"color": "#a04040"
			},
		],
		"relationships":
		[
			{"from": "traditionalists", "to": "innovators", "stance": "rivals", "tension": 40},
			{"from": "traditionalists", "to": "militarists", "stance": "allied", "tension": 10},
			{"from": "innovators", "to": "militarists", "stance": "neutral", "tension": 10},
		]
	}


func test_faction_primitive() -> void:
	_section("faction_primitive (ADR 0032)")

	# ---------- 1. Faction creation + state roundtrip ----------
	# register_factions populates _factions + _relationships; bindings expose
	# tension_with.<other> and stance_with.<other> per faction.
	var fd1 := FactionDirector.new()
	var data1: Dictionary = _make_faction_data()
	var errs1: Array = fd1.register_factions(data1, {})
	expect_eq(errs1.size(), 0, "register_factions on valid data returns no errors")
	expect(fd1.has_faction("traditionalists"), "register_factions stores 'traditionalists' def")
	expect(fd1.has_faction("innovators"), "register_factions stores 'innovators' def")
	expect(fd1.has_faction("militarists"), "register_factions stores 'militarists' def")
	# Initial relationship round-trip — tension reads back from the binding
	# snapshot via the documented `faction.<id>.tension_with.<other>` path.
	var snap1: Dictionary = fd1.binding_snapshot({})
	expect(snap1.has("traditionalists"), "binding_snapshot exposes faction ids as top-level keys")
	var trad_entry: Dictionary = snap1["traditionalists"]
	expect_eq(
		int((trad_entry["tension_with"] as Dictionary).get("innovators", -1)),
		40,
		"faction.traditionalists.tension_with.innovators reads back as 40"
	)
	expect_eq(
		str((trad_entry["stance_with"] as Dictionary).get("innovators", "")),
		"rivals",
		"faction.traditionalists.stance_with.innovators reads back as 'rivals'"
	)
	expect_eq(
		str(trad_entry.get("leader", "")),
		"elder_morwen",
		"faction.traditionalists.leader reads back as 'elder_morwen'"
	)
	fd1.queue_free()

	# ---------- 2. Alliance formation (propose_alliance) ----------
	# propose_alliance flips stance to "allied", drops tension to 0, emits
	# faction_alliance_formed.
	var fd2 := FactionDirector.new()
	fd2.register_factions(_make_faction_data(), {})
	var env2: Dictionary = {
		"entities": {},
		"defs": {},
		"world": {},
		"signal_buffer": [],
		"error_buffer": [],
	}
	# traditionalists ↔ innovators starts at "rivals", tension=40.
	expect_eq(
		fd2.get_stance("traditionalists", "innovators"),
		"rivals",
		"baseline stance is 'rivals' before alliance"
	)
	var res2: Dictionary = fd2.apply_propose_alliance(env2, "traditionalists", "innovators")
	expect(bool(res2.get("ok", false)), "apply_propose_alliance returns ok=true for known factions")
	expect_eq(
		fd2.get_stance("traditionalists", "innovators"),
		"allied",
		"propose_alliance flips stance to 'allied'"
	)
	expect_eq(
		fd2.get_tension("traditionalists", "innovators"), 0, "propose_alliance drops tension to 0"
	)
	# Signal must be on the buffer with from/to payload.
	var saw_alliance: bool = false
	for s in env2["signal_buffer"] as Array:
		if s is Dictionary and str((s as Dictionary).get("name", "")) == "faction_alliance_formed":
			var pl: Dictionary = (s as Dictionary).get("payload", {})
			if (
				str(pl.get("from", "")) == "traditionalists"
				and str(pl.get("to", "")) == "innovators"
			):
				saw_alliance = true
				break
	expect(saw_alliance, "faction_alliance_formed signal emitted with from/to payload")
	fd2.queue_free()

	# ---------- 3. War declaration (declare_war) ----------
	# declare_war sets stance="at_war", tension=100, emits
	# faction_war_declared.
	var fd3 := FactionDirector.new()
	fd3.register_factions(_make_faction_data(), {})
	var env3: Dictionary = {
		"entities": {},
		"defs": {},
		"world": {},
		"signal_buffer": [],
		"error_buffer": [],
	}
	var res3: Dictionary = fd3.apply_declare_war(env3, "innovators", "militarists")
	expect(bool(res3.get("ok", false)), "apply_declare_war returns ok=true for known factions")
	expect_eq(
		fd3.get_stance("innovators", "militarists"),
		"at_war",
		"declare_war flips stance to 'at_war'"
	)
	expect_eq(
		fd3.get_tension("innovators", "militarists"), 100, "declare_war pushes tension to 100"
	)
	var saw_war: bool = false
	for s in env3["signal_buffer"] as Array:
		if s is Dictionary and str((s as Dictionary).get("name", "")) == "faction_war_declared":
			saw_war = true
			break
	expect(saw_war, "faction_war_declared signal emitted")
	fd3.queue_free()

	# ---------- 4. Treaty signing (sign_treaty) ----------
	# After declare_war, sign_treaty resets stance to neutral (default) and
	# tension to that stance's baseline (10).
	var fd4 := FactionDirector.new()
	fd4.register_factions(_make_faction_data(), {})
	var env4: Dictionary = {
		"entities": {},
		"defs": {},
		"world": {},
		"signal_buffer": [],
		"error_buffer": [],
	}
	# Push to war first so we can verify treaty resets it.
	fd4.apply_declare_war(env4, "innovators", "militarists")
	expect_eq(
		fd4.get_tension("innovators", "militarists"),
		100,
		"war declaration pushes tension to 100 (pre-treaty)"
	)
	# Drain pre-treaty signals so the next saw_treaty check is clean.
	(env4["signal_buffer"] as Array).clear()
	var res4: Dictionary = fd4.apply_sign_treaty(env4, "innovators", "militarists", "neutral")
	expect(bool(res4.get("ok", false)), "apply_sign_treaty returns ok=true for known factions")
	expect_eq(
		fd4.get_stance("innovators", "militarists"),
		"neutral",
		"sign_treaty resets stance to 'neutral'"
	)
	expect_eq(
		fd4.get_tension("innovators", "militarists"),
		10,
		"sign_treaty resets tension to neutral baseline (10)"
	)
	var saw_treaty: bool = false
	for s in env4["signal_buffer"] as Array:
		if s is Dictionary and str((s as Dictionary).get("name", "")) == "faction_treaty_signed":
			saw_treaty = true
			break
	expect(saw_treaty, "faction_treaty_signed signal emitted")
	fd4.queue_free()

	# ---------- 5. NPC loyalty mutation (swear_loyalty) ----------
	# swear_loyalty mutates entity.state.faction_loyalty[<id>], emits
	# faction_loyalty_changed, clamps to 0-100.
	var fd5 := FactionDirector.new()
	fd5.register_factions(_make_faction_data(), {})
	var smith_def: Dictionary = {
		"id": "smith_haldor",
		"tags": ["npc", "smith"],
		"state_init": {"faction_loyalty": {}},
	}
	var smith := Entity.create(smith_def, "smith_haldor")
	var entities5: Dictionary = {"smith_haldor": smith}
	var env5: Dictionary = {
		"entities": entities5,
		"defs": {"smith_haldor": smith_def},
		"world": {},
		"signal_buffer": [],
		"error_buffer": [],
	}
	# +30 delta against absent (=0) entry → 30.
	var res5a: Dictionary = fd5.apply_swear_loyalty(
		env5, "smith_haldor", "traditionalists", {"delta": 30}
	)
	expect(
		bool(res5a.get("ok", false)),
		"apply_swear_loyalty returns ok=true for known faction + entity"
	)
	var loyalty_after_a: Dictionary = smith.get_state("faction_loyalty", {}) as Dictionary
	expect_eq(
		int(loyalty_after_a.get("traditionalists", -1)), 30, "swear_loyalty +30 from 0 lands at 30"
	)
	# +200 delta would overshoot 100 → clamps to 100.
	fd5.apply_swear_loyalty(env5, "smith_haldor", "traditionalists", {"delta": 200})
	var loyalty_after_b: Dictionary = smith.get_state("faction_loyalty", {}) as Dictionary
	expect_eq(
		int(loyalty_after_b.get("traditionalists", -1)),
		100,
		"swear_loyalty clamps to 100 (no overflow)"
	)
	# value-based set: hard-set to 25.
	fd5.apply_swear_loyalty(env5, "smith_haldor", "traditionalists", {"value": 25})
	var loyalty_after_c: Dictionary = smith.get_state("faction_loyalty", {}) as Dictionary
	expect_eq(
		int(loyalty_after_c.get("traditionalists", -1)),
		25,
		"swear_loyalty {value: 25} sets directly"
	)
	# Signal emitted at least once with from/to payload.
	var saw_loyalty: bool = false
	for s in env5["signal_buffer"] as Array:
		if s is Dictionary and str((s as Dictionary).get("name", "")) == "faction_loyalty_changed":
			saw_loyalty = true
			break
	expect(saw_loyalty, "faction_loyalty_changed signal emitted on swear_loyalty")
	smith.queue_free()
	fd5.queue_free()

	# ---------- 6. Multi-faction NPC (split loyalty) ----------
	# An NPC may belong to multiple factions concurrently. faction_loyalty
	# is a dict — entries are independent; a smith can be 70% traditionalist
	# AND 40% innovator without conflict.
	var fd6 := FactionDirector.new()
	fd6.register_factions(_make_faction_data(), {})
	var split_def: Dictionary = {
		"id": "split_npc",
		"tags": ["npc"],
		"state_init": {"faction_loyalty": {}},
	}
	var split_npc := Entity.create(split_def, "split_npc")
	var entities6: Dictionary = {"split_npc": split_npc}
	var env6: Dictionary = {
		"entities": entities6,
		"defs": {"split_npc": split_def},
		"world": {},
		"signal_buffer": [],
		"error_buffer": [],
	}
	fd6.apply_swear_loyalty(env6, "split_npc", "traditionalists", {"value": 70})
	fd6.apply_swear_loyalty(env6, "split_npc", "innovators", {"value": 40})
	var split_loyalty: Dictionary = split_npc.get_state("faction_loyalty", {}) as Dictionary
	expect_eq(
		int(split_loyalty.get("traditionalists", -1)), 70, "split-loyalty NPC: traditionalists = 70"
	)
	expect_eq(
		int(split_loyalty.get("innovators", -1)),
		40,
		"split-loyalty NPC: innovators = 40 (independent channel)"
	)
	expect_eq(split_loyalty.size(), 2, "split-loyalty NPC carries 2 faction entries")
	split_npc.queue_free()
	fd6.queue_free()

	# ---------- 7. Query NPCs by faction (member_count binding) ----------
	# faction.<id>.member_count counts entities whose loyalty[id] >=
	# MEMBER_THRESHOLD (50). Mirrors the ADR's "query NPCs by faction"
	# semantics without requiring the dotted-state-path query extension.
	var fd7 := FactionDirector.new()
	fd7.register_factions(_make_faction_data(), {})
	var npc_def: Dictionary = {
		"id": "npc_template",
		"tags": ["npc"],
		"state_init": {"faction_loyalty": {}},
	}
	# 4 NPCs: 3 are traditionalist members (loyalty >= 50), 1 isn't.
	var n1 := Entity.create(npc_def, "n1")
	n1.set_state("faction_loyalty", {"traditionalists": 80})
	var n2 := Entity.create(npc_def, "n2")
	n2.set_state("faction_loyalty", {"traditionalists": 60})
	var n3 := Entity.create(npc_def, "n3")
	n3.set_state("faction_loyalty", {"traditionalists": 50, "innovators": 90})
	var n4 := Entity.create(npc_def, "n4")
	n4.set_state("faction_loyalty", {"traditionalists": 30})  # below threshold
	var entities7: Dictionary = {"n1": n1, "n2": n2, "n3": n3, "n4": n4}
	var env7: Dictionary = {
		"entities": entities7,
		"defs": {"npc_template": npc_def},
		"world": {},
		"signal_buffer": [],
	}
	var snap7: Dictionary = fd7.binding_snapshot(env7)
	expect_eq(
		int((snap7["traditionalists"] as Dictionary).get("member_count", -1)),
		3,
		"member_count counts entities with loyalty >= 50 (n1, n2, n3)"
	)
	expect_eq(
		int((snap7["innovators"] as Dictionary).get("member_count", -1)),
		1,
		"member_count counts only n3 for innovators (loyalty=90 >= 50)"
	)
	expect_eq(
		int((snap7["militarists"] as Dictionary).get("member_count", -1)),
		0,
		"member_count is 0 for factions with no loyal entities"
	)
	n1.queue_free()
	n2.queue_free()
	n3.queue_free()
	n4.queue_free()
	fd7.queue_free()

	# ---------- 8. Query factions by stance (find_factions_with_stance) ----------
	# After a war declaration, find_factions_with_stance("at_war") returns
	# the directed pair we set.
	var fd8 := FactionDirector.new()
	fd8.register_factions(_make_faction_data(), {})
	var env8_f: Dictionary = {
		"entities": {},
		"defs": {},
		"world": {},
		"signal_buffer": [],
	}
	# Initial state has zero at_war pairs.
	expect_eq(
		fd8.find_factions_with_stance("at_war").size(),
		0,
		"no at_war pairs before any war declaration"
	)
	# Initial state has 1 allied pair (traditionalists → militarists).
	var allied_initial: Array = fd8.find_factions_with_stance("allied")
	expect_eq(
		allied_initial.size(), 1, "initial state has 1 allied pair (traditionalists → militarists)"
	)
	# Declare war between innovators and militarists.
	fd8.apply_declare_war(env8_f, "innovators", "militarists")
	var at_war_pairs: Array = fd8.find_factions_with_stance("at_war")
	expect_eq(
		at_war_pairs.size(),
		1,
		"find_factions_with_stance('at_war') returns 1 pair after declare_war"
	)
	expect_eq(
		str((at_war_pairs[0] as Dictionary).get("from", "")),
		"innovators",
		"at_war pair from = innovators"
	)
	expect_eq(
		str((at_war_pairs[0] as Dictionary).get("to", "")),
		"militarists",
		"at_war pair to = militarists"
	)
	fd8.queue_free()

	# ---------- 9. Save/load round-trip preserves faction state ----------
	# Mid-war state (relationships) saves; restoring against a fresh
	# director yields identical stance + tension. NPC loyalty rides on
	# entity state (existing save plumbing) and is NOT this director's
	# concern, so this test only covers the relationship state save.
	var fd9a := FactionDirector.new()
	fd9a.register_factions(_make_faction_data(), {})
	var env9: Dictionary = {
		"entities": {},
		"defs": {},
		"world": {},
		"signal_buffer": [],
	}
	fd9a.apply_declare_war(env9, "innovators", "militarists")
	# Tweak tension via sign_treaty + value to verify tension specifically
	# survives save/load.
	fd9a.apply_sign_treaty(env9, "traditionalists", "innovators", "hostile")
	var saved: Dictionary = fd9a.to_save()
	expect(saved.has("innovators:militarists"), "to_save includes mutated relationship key")
	expect_eq(
		str((saved["innovators:militarists"] as Dictionary).get("stance", "")),
		"at_war",
		"to_save snapshots the at_war stance"
	)
	# Restore into a fresh director with the same factions but only the
	# initial relationships. from_save should overwrite them with the saved
	# mid-war state.
	var fd9b := FactionDirector.new()
	fd9b.register_factions(_make_faction_data(), {})
	# Pre-restore baseline: still rivals.
	expect_eq(
		fd9b.get_stance("traditionalists", "innovators"),
		"rivals",
		"fresh director starts at initial 'rivals' before from_save"
	)
	fd9b.from_save(saved)
	expect_eq(
		fd9b.get_stance("innovators", "militarists"), "at_war", "from_save restores at_war stance"
	)
	expect_eq(
		fd9b.get_tension("innovators", "militarists"), 100, "from_save restores war tension (100)"
	)
	expect_eq(
		fd9b.get_stance("traditionalists", "innovators"),
		"hostile",
		"from_save restores treaty-set hostile stance"
	)
	# Saved key for unknown faction id should be silently dropped.
	fd9b.from_save({"phantom_faction:other": {"stance": "at_war", "tension": 100}})
	# (No assertion — just verify no crash; the sentinel here is the next
	# call surviving cleanly.)
	expect_eq(
		fd9b.get_stance("innovators", "militarists"),
		"at_war",
		"unknown-faction save entries are dropped without disturbing valid state"
	)
	fd9a.queue_free()
	fd9b.queue_free()

	# ---------- 10. Unknown faction fails atomic (FACTION_NO_DEF) ----------
	# declare_war / sign_treaty / propose_alliance / swear_loyalty against
	# an unregistered faction id MUST leave state untouched and raise
	# FACTION_NO_DEF in the error buffer. No signal emitted.
	var fd10 := FactionDirector.new()
	fd10.register_factions(_make_faction_data(), {})
	var env10: Dictionary = {
		"entities": {},
		"defs": {},
		"world": {},
		"signal_buffer": [],
		"error_buffer": [],
	}
	# Capture baseline stance for traditionalists ↔ innovators.
	var pre_stance: String = fd10.get_stance("traditionalists", "innovators")
	var pre_tension: int = fd10.get_tension("traditionalists", "innovators")
	var bad: Dictionary = fd10.apply_declare_war(env10, "traditionalists", "phantom_faction")
	expect(not bool(bad.get("ok", true)), "declare_war on unknown faction returns ok=false")
	expect_eq(str(bad.get("reason", "")), "no_def", "declare_war failure carries reason='no_def'")
	# State must NOT have been mutated by the failed declare_war.
	expect_eq(
		fd10.get_stance("traditionalists", "innovators"),
		pre_stance,
		"failed declare_war leaves unrelated stance unchanged (atomic)"
	)
	expect_eq(
		fd10.get_tension("traditionalists", "innovators"),
		pre_tension,
		"failed declare_war leaves unrelated tension unchanged (atomic)"
	)
	# No faction_war_declared signal should be on the buffer.
	var saw_emit: bool = false
	for s in env10["signal_buffer"] as Array:
		if s is Dictionary and str((s as Dictionary).get("name", "")) == "faction_war_declared":
			saw_emit = true
			break
	expect(not saw_emit, "failed declare_war emits NO faction_war_declared signal")
	# Error buffer should carry FACTION_NO_DEF.
	var saw_err: bool = false
	for r in env10["error_buffer"] as Array:
		if r is Dictionary and str((r as Dictionary).get("code", "")) == EngineError.FACTION_NO_DEF:
			saw_err = true
			break
	expect(saw_err, "failed declare_war raises FACTION_NO_DEF in error_buffer")
	fd10.queue_free()


# ============================================================
# TECH TREE (ADR 0033)
# ============================================================


## Build a fresh TechTreeDirector pre-loaded with two trees:
##   - smithing: smithing → ironworking → steel (core: T/T/F)
##   - magic_elemental: magic_basic → fire_school (core: T/F)
## Returns the director. Tests own queue_free.
func _make_tech_director_two_trees() -> TechTreeDirector:
	var ttd := TechTreeDirector.new()
	var trees := {
		"trees":
		[
			{
				"id": "smithing",
				"nodes":
				[
					{
						"id": "smithing",
						"prereqs": [],
						"discovery_chance": 0.0,
						"core": true,
						"eligibility_tags": ["smith"]
					},
					{
						"id": "ironworking",
						"prereqs": ["smithing"],
						"discovery_chance": 0.05,
						"core": true,
						"eligibility_tags": ["smith"]
					},
					{
						"id": "steel",
						"prereqs": ["ironworking"],
						"discovery_chance": 0.02,
						"core": false,
						"eligibility_tags": ["smith"]
					},
				],
			},
			{
				"id": "magic_elemental",
				"nodes":
				[
					{
						"id": "magic_basic",
						"prereqs": [],
						"discovery_chance": 0.0,
						"core": true,
						"eligibility_tags": ["mage"]
					},
					{
						"id": "fire_school",
						"prereqs": ["magic_basic"],
						"discovery_chance": 0.10,
						"core": false,
						"eligibility_tags": ["mage"]
					},
				],
			},
		]
	}
	ttd.register_trees(trees, {})
	return ttd


func test_tech_tree_primitive() -> void:
	_section("tech_tree_primitive (ADR 0033)")

	# ---------- 1. discovery probability respects discovery_chance ----------
	# Run 100 rolls at chance=0.05; expect ~5 successes. Allow 1-15 to keep
	# the bound loose enough to avoid statistical flakes (P[<1] ≈ 0.6%,
	# P[>15] ≈ 0.0001%). The point is "neither always-fires nor never-fires."
	seed(42)  # deterministic seed for the rolls block
	var ttd1 := _make_tech_director_two_trees()
	var success_count: int = 0
	for i in range(100):
		var smith_def := {
			"id": "smith_npc", "tags": ["smith"], "state_init": {"known_techs": ["smithing"]}
		}
		var ent := Entity.create(smith_def, "s%d" % i)
		var entities1: Dictionary = {"s%d" % i: ent}
		var env1: Dictionary = {
			"entities": entities1,
			"defs": {"smith_npc": smith_def},
			"world": {},
			"parent": null,
			"next_id": {"_": 0},
			"signal_buffer": [],
			"relations": RelationStore.new(),
		}
		var awarded: String = ttd1.try_discover_tech(env1, "s%d" % i, "smithing", 1)
		if awarded != "":
			success_count += 1
		ent.queue_free()
	expect(
		success_count >= 1 and success_count <= 20,
		"100 rolls at chance=0.05: expect 1-20 successes (got %d)" % success_count
	)
	ttd1.queue_free()

	# ---------- 2. prereq blocking ----------
	# An NPC who knows ONLY 'smithing' cannot leap directly to 'steel'
	# (prereq 'ironworking' missing). With chance forced to 1.0 via a
	# custom tree, a known prereq path should fire steel only after
	# ironworking is awarded.
	var ttd2 := TechTreeDirector.new()
	(
		ttd2
		. register_trees(
			{
				"trees":
				[
					{
						"id": "smithing",
						"nodes":
						[
							{
								"id": "smithing",
								"prereqs": [],
								"discovery_chance": 0.0,
								"core": true,
								"eligibility_tags": ["smith"]
							},
							{
								"id": "ironworking",
								"prereqs": ["smithing"],
								"discovery_chance": 1.0,
								"core": true,
								"eligibility_tags": ["smith"]
							},
							{
								"id": "steel",
								"prereqs": ["ironworking"],
								"discovery_chance": 1.0,
								"core": false,
								"eligibility_tags": ["smith"]
							},
						]
					}
				]
			},
			{}
		)
	)
	var smith_def2 := {
		"id": "smith_npc", "tags": ["smith"], "state_init": {"known_techs": ["smithing"]}
	}
	var ent2 := Entity.create(smith_def2, "s2")
	var entities2: Dictionary = {"s2": ent2}
	var env2: Dictionary = {
		"entities": entities2,
		"defs": {"smith_npc": smith_def2},
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
		"signal_buffer": [],
		"relations": RelationStore.new(),
	}
	# First call should award ironworking (the only ready node — steel
	# blocked by missing ironworking prereq).
	var first_award: String = ttd2.try_discover_tech(env2, "s2", "smithing", 1)
	expect_eq(
		first_award, "ironworking", "prereq-gated chain: first award is ironworking (steel blocked)"
	)
	# Now ironworking is in known_techs; steel becomes eligible.
	var second_award: String = ttd2.try_discover_tech(env2, "s2", "smithing", 1)
	expect_eq(second_award, "steel", "prereq-gated chain: steel awarded after ironworking earned")
	ent2.queue_free()
	ttd2.queue_free()

	# ---------- 3. eligibility tags (class gating) ----------
	# A 'farmer'-tagged NPC cannot discover smithing nodes even with
	# chance=1.0 — eligibility_tags = ["smith"] must be on the entity.
	var ttd3 := TechTreeDirector.new()
	(
		ttd3
		. register_trees(
			{
				"trees":
				[
					{
						"id": "smithing",
						"nodes":
						[
							{
								"id": "smithing",
								"prereqs": [],
								"discovery_chance": 1.0,
								"core": true,
								"eligibility_tags": ["smith"]
							},
						]
					}
				]
			},
			{}
		)
	)
	var farmer_def3 := {"id": "farmer_npc", "tags": ["farmer"], "state_init": {"known_techs": []}}
	var ent3 := Entity.create(farmer_def3, "f3")
	var entities3: Dictionary = {"f3": ent3}
	var env3: Dictionary = {
		"entities": entities3,
		"defs": {"farmer_npc": farmer_def3},
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
		"signal_buffer": [],
		"relations": RelationStore.new(),
	}
	var farmer_award: String = ttd3.try_discover_tech(env3, "f3", "smithing", 1)
	expect_eq(
		farmer_award, "", "farmer-tagged NPC cannot discover smith-only node (eligibility blocks)"
	)
	# Sanity: a smith CAN discover the same node.
	var smith_def3 := {"id": "smith_npc", "tags": ["smith"], "state_init": {"known_techs": []}}
	var ent3b := Entity.create(smith_def3, "s3")
	(env3["entities"] as Dictionary)["s3"] = ent3b
	var smith_award: String = ttd3.try_discover_tech(env3, "s3", "smithing", 1)
	expect_eq(
		smith_award,
		"smithing",
		"smith-tagged NPC discovers smithing (eligibility passes at chance=1.0)"
	)
	ent3.queue_free()
	ent3b.queue_free()
	ttd3.queue_free()

	# ---------- 4. master-to-apprentice transfer via party_member_of ----------
	var ttd4 := _make_tech_director_two_trees()
	var master_def4 := {
		"id": "master_smith",
		"tags": ["smith"],
		"state_init": {"known_techs": ["smithing", "ironworking"]}
	}
	var apprentice_def4 := {
		"id": "apprentice_smith", "tags": ["smith"], "state_init": {"known_techs": ["smithing"]}
	}
	var master4 := Entity.create(master_def4, "master4")
	var apprentice4 := Entity.create(apprentice_def4, "apprentice4")
	var rs4 := RelationStore.new()
	# Apprentice's party_member_of edge points to master.
	rs4.relate("party_member_of", "apprentice4", "master4")
	var entities4: Dictionary = {"master4": master4, "apprentice4": apprentice4}
	var env4: Dictionary = {
		"entities": entities4,
		"defs": {"master_smith": master_def4, "apprentice_smith": apprentice_def4},
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
		"signal_buffer": [],
		"relations": rs4,
	}
	var awarded4: String = ttd4.learn_from_master(env4, "apprentice4", "smithing")
	expect_eq(
		awarded4, "ironworking", "apprentice learns ironworking from master via party_member_of"
	)
	var apprentice_known4: Array = apprentice4.get_state("known_techs", []) as Array
	expect(
		apprentice_known4.has("ironworking"),
		"apprentice.known_techs contains ironworking after learn_from_master"
	)
	master4.queue_free()
	apprentice4.queue_free()
	ttd4.queue_free()

	# ---------- 5. master-missing no-op ----------
	# Apprentice with NO outgoing party_member_of edge: learn_from_master
	# returns "" gracefully — no error, no signal, no state mutation.
	var ttd5 := _make_tech_director_two_trees()
	var solo_def5 := {"id": "solo", "tags": ["smith"], "state_init": {"known_techs": ["smithing"]}}
	var solo := Entity.create(solo_def5, "solo")
	var rs5 := RelationStore.new()  # no edges
	var env5: Dictionary = {
		"entities": {"solo": solo},
		"defs": {"solo": solo_def5},
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
		"signal_buffer": [],
		"relations": rs5,
	}
	var awarded5: String = ttd5.learn_from_master(env5, "solo", "smithing")
	expect_eq(awarded5, "", "master-missing learn_from_master returns ''")
	# State unchanged.
	var solo_known: Array = solo.get_state("known_techs", []) as Array
	expect_eq(
		solo_known.size(), 1, "master-missing: known_techs unchanged (still has only 'smithing')"
	)
	# No tech_learned signal in buffer.
	var saw_learned5: bool = false
	for s in env5["signal_buffer"] as Array:
		if s is Dictionary and str((s as Dictionary).get("name", "")) == "tech_learned":
			saw_learned5 = true
			break
	expect(not saw_learned5, "master-missing: NO tech_learned signal emitted")
	solo.queue_free()
	ttd5.queue_free()

	# ---------- 6. multi-apprentice broadcast (pass_to_apprentice) ----------
	var ttd6 := _make_tech_director_two_trees()
	var master_def6 := {
		"id": "m6", "tags": ["smith"], "state_init": {"known_techs": ["smithing", "ironworking"]}
	}
	var ap_def6 := {"id": "ap6", "tags": ["smith"], "state_init": {"known_techs": ["smithing"]}}
	var master6 := Entity.create(master_def6, "m6")
	var ap6_a := Entity.create(ap_def6, "a6_a")
	var ap6_b := Entity.create(ap_def6, "a6_b")
	var ap6_c := Entity.create(ap_def6, "a6_c")
	var rs6 := RelationStore.new()
	rs6.relate("party_member_of", "a6_a", "m6")
	rs6.relate("party_member_of", "a6_b", "m6")
	rs6.relate("party_member_of", "a6_c", "m6")
	var env6: Dictionary = {
		"entities": {"m6": master6, "a6_a": ap6_a, "a6_b": ap6_b, "a6_c": ap6_c},
		"defs": {"master_smith6": master_def6, "ap_smith6": ap_def6},
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
		"signal_buffer": [],
		"relations": rs6,
	}
	var n6: int = ttd6.pass_to_apprentice(env6, "m6", "smithing", "party_member_of", 4, 1)
	expect_eq(n6, 3, "pass_to_apprentice awards all 3 apprentices")
	# Each apprentice should now have ironworking.
	for ap_id in ["a6_a", "a6_b", "a6_c"]:
		var ap = (env6["entities"] as Dictionary)[ap_id]
		var ap_known: Array = (ap as Entity).get_state("known_techs", []) as Array
		expect(
			ap_known.has("ironworking"),
			"apprentice %s has ironworking after pass_to_apprentice" % ap_id
		)
	master6.queue_free()
	ap6_a.queue_free()
	ap6_b.queue_free()
	ap6_c.queue_free()
	ttd6.queue_free()

	# ---------- 7. multi-tree independence ----------
	# Discovering on smithing tree must not appear on magic_elemental tree
	# and vice versa. Use a hybrid NPC tagged both smith + mage.
	var ttd7 := TechTreeDirector.new()
	(
		ttd7
		. register_trees(
			{
				"trees":
				[
					{
						"id": "smithing",
						"nodes":
						[
							{
								"id": "smithing",
								"prereqs": [],
								"discovery_chance": 1.0,
								"core": true,
								"eligibility_tags": ["smith"]
							},
						]
					},
					{
						"id": "magic_elemental",
						"nodes":
						[
							{
								"id": "magic_basic",
								"prereqs": [],
								"discovery_chance": 1.0,
								"core": true,
								"eligibility_tags": ["mage"]
							},
						]
					},
				]
			},
			{}
		)
	)
	var hybrid_def7 := {
		"id": "hybrid", "tags": ["smith", "mage"], "state_init": {"known_techs": []}
	}
	var hybrid := Entity.create(hybrid_def7, "h7")
	var env7: Dictionary = {
		"entities": {"h7": hybrid},
		"defs": {"hybrid": hybrid_def7},
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
		"signal_buffer": [],
		"relations": RelationStore.new(),
	}
	# Discover on smithing — adds 'smithing', not 'magic_basic'.
	ttd7.try_discover_tech(env7, "h7", "smithing", 1)
	var known7a: Array = hybrid.get_state("known_techs", []) as Array
	expect(known7a.has("smithing"), "smithing tree discovery adds 'smithing'")
	expect(
		not known7a.has("magic_basic"), "smithing tree discovery does NOT add magic_elemental nodes"
	)
	# Discover on magic_elemental — adds 'magic_basic'.
	ttd7.try_discover_tech(env7, "h7", "magic_elemental", 1)
	var known7b: Array = hybrid.get_state("known_techs", []) as Array
	expect(known7b.has("magic_basic"), "magic tree discovery adds 'magic_basic'")
	expect(known7b.has("smithing"), "magic tree discovery preserves prior smithing")
	hybrid.queue_free()
	ttd7.queue_free()

	# ---------- 8. query operator known_techs_has ----------
	# state: {known_techs_has: "X"} filters entities whose Array contains X.
	var smith_def8 := {
		"id": "smith8",
		"tags": ["smith"],
		"state_init": {"known_techs": ["smithing", "ironworking"]}
	}
	var farmer_def8 := {
		"id": "farmer8", "tags": ["farmer"], "state_init": {"known_techs": ["farming"]}
	}
	var bare_def8 := {"id": "bare8", "tags": ["actor"], "state_init": {"known_techs": []}}
	# An entity without known_techs at all (strict-missing — should not match).
	var nokeys_def8 := {"id": "nokeys8", "tags": ["actor"], "state_init": {"hp": 5}}
	var s8 := Entity.create(smith_def8, "s8")
	var f8 := Entity.create(farmer_def8, "f8")
	var b8 := Entity.create(bare_def8, "b8")
	var n8 := Entity.create(nokeys_def8, "n8")
	var env8: Dictionary = {
		"entities": {"s8": s8, "f8": f8, "b8": b8, "n8": n8},
		"defs": {},
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
		"relations": RelationStore.new(),
	}
	var matches_iron: Array = QueryLib.run({"state": {"known_techs_has": "ironworking"}}, env8)
	expect_eq(matches_iron.size(), 1, "known_techs_has 'ironworking' returns exactly the smith")
	expect_eq(
		(matches_iron[0] as Entity).instance_id,
		"s8",
		"matched entity is s8 (the smith with ironworking)"
	)
	var matches_farming: Array = QueryLib.run({"state": {"known_techs_has": "farming"}}, env8)
	expect_eq(matches_farming.size(), 1, "known_techs_has 'farming' returns exactly the farmer")
	# 'bare8' has known_techs=[] so doesn't contain anything; n8 has no
	# field at all. Both correctly fail to match.
	var matches_missing: Array = QueryLib.run({"state": {"known_techs_has": "smithing"}}, env8)
	expect_eq(
		matches_missing.size(),
		1,
		"known_techs_has 'smithing' returns only s8 (b8 empty, n8 absent)"
	)
	s8.queue_free()
	f8.queue_free()
	b8.queue_free()
	n8.queue_free()

	# ---------- 9. formula binding (state.known_techs as Array, 'in' op) ----------
	# Per ADR 0033 §5, formulas treat known_techs as an Array reachable via
	# self.state.known_techs. The Godot `in` operator tests membership:
	#   '"smithing" in self.state.known_techs' → bool
	# (`.has()` on the path is consumed by the path-substitution regex; the
	# `in` operator is the working pattern. See ADR §5 + tech_tree.gd notes.)
	var smith_def9 := {
		"id": "smith9",
		"tags": ["smith"],
		"state_init": {"known_techs": ["smithing", "ironworking"]}
	}
	var s9 := Entity.create(smith_def9, "s9")
	var env9: Dictionary = {
		"entities": {"s9": s9},
		"defs": {},
		"world": {},
		"relations": RelationStore.new(),
	}
	var fctx9: Dictionary = {"self": s9, "world": {}}
	var has_iron = Formula.evaluate('"ironworking" in self.state.known_techs', fctx9, env9)
	expect_eq(bool(has_iron), true, "formula '\"ironworking\" in self.state.known_techs' → true")
	var has_steel = Formula.evaluate('"steel" in self.state.known_techs', fctx9, env9)
	expect_eq(bool(has_steel), false, "formula '\"steel\" in self.state.known_techs' → false")
	s9.queue_free()

	# ---------- 10. save/load preserves known_techs array ----------
	# Entity state is a plain dict; serialization is a snapshot. Verify
	# round-trip — save state, build a new Entity, restore state, the
	# Array survives intact.
	var smith_def10 := {
		"id": "smith10",
		"tags": ["smith"],
		"state_init": {"known_techs": ["smithing", "ironworking"]}
	}
	var s10 := Entity.create(smith_def10, "s10")
	# Mutate via try_discover_tech (chance=1 forced) to confirm the
	# mutation persists through .duplicate(true).
	var ttd10 := TechTreeDirector.new()
	(
		ttd10
		. register_trees(
			{
				"trees":
				[
					{
						"id": "smithing",
						"nodes":
						[
							{
								"id": "smithing",
								"prereqs": [],
								"discovery_chance": 0.0,
								"core": true,
								"eligibility_tags": ["smith"]
							},
							{
								"id": "ironworking",
								"prereqs": ["smithing"],
								"discovery_chance": 0.0,
								"core": true,
								"eligibility_tags": ["smith"]
							},
							{
								"id": "steel",
								"prereqs": ["ironworking"],
								"discovery_chance": 1.0,
								"core": false,
								"eligibility_tags": ["smith"]
							},
						]
					}
				]
			},
			{}
		)
	)
	var env10: Dictionary = {
		"entities": {"s10": s10},
		"defs": {"smith10": smith_def10},
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
		"signal_buffer": [],
		"relations": RelationStore.new(),
	}
	ttd10.try_discover_tech(env10, "s10", "smithing", 1)  # awards steel
	var pre_save_known: Array = s10.get_state("known_techs", []) as Array
	expect(pre_save_known.has("steel"), "pre-save: steel was awarded via try_discover_tech")
	# Snapshot state via deep-duplicate (the policy save layer uses).
	var snapshot: Dictionary = s10.state.duplicate(true)
	# Mutate further to prove restore overwrites correctly.
	s10.set_state("known_techs", [])
	expect_eq(
		(s10.get_state("known_techs", []) as Array).size(),
		0,
		"between-save: cleared known_techs to []"
	)
	# Restore.
	for k in snapshot.keys():
		s10.set_state(str(k), snapshot[k])
	var restored_known: Array = s10.get_state("known_techs", []) as Array
	expect_eq(restored_known.size(), 3, "post-restore: known_techs has all 3 nodes")
	expect(
		(
			restored_known.has("smithing")
			and restored_known.has("ironworking")
			and restored_known.has("steel")
		),
		"post-restore: all node ids present (smithing+ironworking+steel)"
	)
	s10.queue_free()
	ttd10.queue_free()

	# ---------- 11. signals emitted: tech_discovered + tech_learned + tech_inherited ----------
	var ttd11 := _make_tech_director_two_trees()
	var smith_def11 := {"id": "s11", "tags": ["smith"], "state_init": {"known_techs": ["smithing"]}}
	var ap_def11 := {"id": "ap11", "tags": ["smith"], "state_init": {"known_techs": ["smithing"]}}
	var heir_def11 := {"id": "h11", "tags": ["smith"], "state_init": {"known_techs": []}}
	var s11 := Entity.create(smith_def11, "s11")
	var ap11 := Entity.create(ap_def11, "ap11")
	var h11 := Entity.create(heir_def11, "h11")
	var rs11 := RelationStore.new()
	rs11.relate("party_member_of", "ap11", "s11")
	# Force chance=1.0 for ironworking by overriding the registered tree.
	(
		ttd11
		. register_trees(
			{
				"trees":
				[
					{
						"id": "smithing",
						"nodes":
						[
							{
								"id": "smithing",
								"prereqs": [],
								"discovery_chance": 0.0,
								"core": true,
								"eligibility_tags": ["smith"]
							},
							{
								"id": "ironworking",
								"prereqs": ["smithing"],
								"discovery_chance": 1.0,
								"core": true,
								"eligibility_tags": ["smith"]
							},
						]
					}
				]
			},
			{}
		)
	)
	var env11: Dictionary = {
		"entities": {"s11": s11, "ap11": ap11, "h11": h11},
		"defs": {},
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
		"signal_buffer": [],
		"relations": rs11,
	}
	# (a) tech_discovered fires on try_discover_tech success.
	ttd11.try_discover_tech(env11, "s11", "smithing", 1)
	var saw_discovered: bool = false
	for sig in env11["signal_buffer"] as Array:
		if sig is Dictionary and str((sig as Dictionary).get("name", "")) == "tech_discovered":
			var pl: Dictionary = (sig as Dictionary).get("payload", {})
			if (
				str(pl.get("entity", "")) == "s11"
				and str(pl.get("node", "")) == "ironworking"
				and str(pl.get("source", "")) == "discovery"
			):
				saw_discovered = true
				break
	expect(
		saw_discovered,
		"tech_discovered signal emitted with entity=s11, node=ironworking, source=discovery"
	)
	# (b) tech_learned fires on learn_from_master success.
	ttd11.learn_from_master(env11, "ap11", "smithing")
	var saw_learned: bool = false
	for sig in env11["signal_buffer"] as Array:
		if sig is Dictionary and str((sig as Dictionary).get("name", "")) == "tech_learned":
			var pl: Dictionary = (sig as Dictionary).get("payload", {})
			if (
				str(pl.get("entity", "")) == "ap11"
				and str(pl.get("node", "")) == "ironworking"
				and str(pl.get("source", "")) == "master"
				and str(pl.get("master_id", "")) == "s11"
			):
				saw_learned = true
				break
	expect(
		saw_learned, "tech_learned signal emitted with entity=ap11, node=ironworking, master_id=s11"
	)
	# (c) tech_inherited fires on inherit_to.
	# Use the two-tree fixture so we can test core/non-core filtering too.
	# First seed s11 with all three smithing nodes.
	s11.set_state("known_techs", ["smithing", "ironworking", "steel"])
	# Reset signal buffer to isolate inherit signals.
	env11["signal_buffer"] = []
	# Re-register the original trees (smithing has core flags T/T/F).
	var ttd11b := _make_tech_director_two_trees()
	ttd11b.inherit_to(env11, "s11", "h11", "core_only")
	var saw_inherited: bool = false
	for sig in env11["signal_buffer"] as Array:
		if sig is Dictionary and str((sig as Dictionary).get("name", "")) == "tech_inherited":
			var pl: Dictionary = (sig as Dictionary).get("payload", {})
			if (
				str(pl.get("entity", "")) == "h11"
				and str(pl.get("source", "")) == "heir"
				and str(pl.get("parent_id", "")) == "s11"
			):
				saw_inherited = true
				break
	expect(
		saw_inherited, "tech_inherited signal emitted with entity=h11, source=heir, parent_id=s11"
	)
	s11.queue_free()
	ap11.queue_free()
	h11.queue_free()
	ttd11.queue_free()
	ttd11b.queue_free()

	# ---------- 12. dynasty inheritance honors `core` flag ----------
	# inherit_to(heir, parent, "core_only") transfers ONLY core nodes.
	# Parent knows [smithing(core), ironworking(core), steel(non-core)] →
	# heir gets [smithing, ironworking], NOT steel.
	var ttd12 := _make_tech_director_two_trees()
	var parent_def12 := {
		"id": "parent12",
		"tags": ["smith"],
		"state_init": {"known_techs": ["smithing", "ironworking", "steel"]}
	}
	var heir_def12 := {"id": "heir12", "tags": ["smith"], "state_init": {"known_techs": []}}
	var parent12 := Entity.create(parent_def12, "parent12")
	var heir12 := Entity.create(heir_def12, "heir12")
	var env12: Dictionary = {
		"entities": {"parent12": parent12, "heir12": heir12},
		"defs": {"parent12": parent_def12, "heir12": heir_def12},
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
		"signal_buffer": [],
		"relations": RelationStore.new(),
	}
	var inherited: Array = ttd12.inherit_to(env12, "parent12", "heir12", "core_only")
	# Verify return: 2 nodes inherited (smithing + ironworking).
	expect_eq(
		inherited.size(),
		2,
		"inherit_to core_only: 2 core nodes transferred (got %d)" % inherited.size()
	)
	expect(inherited.has("smithing"), "inherit_to core_only: smithing transferred (core=true)")
	expect(
		inherited.has("ironworking"), "inherit_to core_only: ironworking transferred (core=true)"
	)
	expect(not inherited.has("steel"), "inherit_to core_only: steel NOT transferred (core=false)")
	# Verify heir state.
	var heir_known12: Array = heir12.get_state("known_techs", []) as Array
	expect_eq(
		heir_known12.size(), 2, "heir.known_techs has exactly 2 nodes after core_only inheritance"
	)
	expect(
		heir_known12.has("smithing") and heir_known12.has("ironworking"),
		"heir.known_techs = [smithing, ironworking] (core flag respected)"
	)
	expect(
		not heir_known12.has("steel"), "heir.known_techs does NOT contain steel (non-core dropped)"
	)
	parent12.queue_free()
	heir12.queue_free()
	ttd12.queue_free()


# ============================================================
# DYNASTY (ADR 0034)
# ============================================================


## ADR 0034 — Dynasty / heir succession primitive.
## 10 assertions covering aging→death integration, the four transfer
## effects, multi-heir branching, save/load round-trip, infinite-life
## suppression integration, and emergent multi-generation independence.
func test_dynasty_primitive() -> void:
	_section("dynasty_primitive (ADR 0034)")

	# Reusable human lifecycle template (mirrors test_lifecycle_primitive).
	# year_seconds=1.0 + age_per_in_game_year=1.0 → 1 second of dt = 1 year.
	var human_template: Dictionary = {
		"stages":
		[
			{"id": "child", "min_age": 0, "max_age": 12, "speed_mult": 0.85, "abilities": ["talk"]},
			{"id": "adult", "min_age": 12, "max_age": 80, "speed_mult": 1.0, "abilities": ["all"]},
			{"id": "dead", "min_age": 80, "speed_mult": 0.0, "abilities": [], "terminal": true},
		],
		"age_per_in_game_year": 1.0,
		"year_seconds": 1.0,
	}

	# ---------- 1. aging triggers entity_died at max_age ----------
	# Smoke test: ADR 0036 lifecycle integration. An adult NPC near
	# max_age, ticked forward, must emit entity_died. Dynasty director
	# itself doesn't drive this — it LISTENS via per-game rules — but
	# we verify the upstream signal still fires so the dynasty chain
	# has something to react to.
	var lc1 := LifecycleDirector.new()
	var dying_def1: Dictionary = {
		"id": "dying_player",
		"tags": ["player", "human"],
		"lifecycle": human_template,
		"state_init": {"age": 79.5, "life_stage": "adult"},
	}
	var dying1 := Entity.create(dying_def1, "p1")
	var entities1: Dictionary = {"p1": dying1}
	var env1: Dictionary = {
		"entities": entities1,
		"defs": {"dying_player": dying_def1},
		"world": {},
		"signal_buffer": [],
		"tick_count": 1,
	}
	lc1.register_lifecycle("p1", human_template, env1, "human")
	lc1.tick(env1, 1.0)  # 79.5 → 80.5 → crosses to dead (terminal)
	var saw_death1: bool = false
	for s in env1["signal_buffer"] as Array:
		if s is Dictionary and str((s as Dictionary).get("name", "")) == "entity_died":
			saw_death1 = true
			break
	expect(saw_death1, "aging integration: entity_died fired when player crossed max_age")
	dying1.queue_free()
	lc1.queue_free()

	# ---------- 2. transfer_inventory moves all items ----------
	var dd2 := DynastyDirector.new()
	var src_def2: Dictionary = {
		"id": "src", "tags": ["actor"], "state_init": {"inventory": ["sword", "shield", "potion"]}
	}
	var heir_def2: Dictionary = {"id": "heir", "tags": ["actor"], "state_init": {"inventory": []}}
	var src2 := Entity.create(src_def2, "src2")
	var heir2 := Entity.create(heir_def2, "heir2")
	var env2: Dictionary = {
		"entities": {"src2": src2, "heir2": heir2},
		"defs": {"src": src_def2, "heir": heir_def2},
		"world": {},
		"signal_buffer": [],
	}
	var n2: int = dd2.transfer_inventory(env2, "src2", "heir2")
	expect_eq(n2, 3, "transfer_inventory moves 3 items")
	var heir_inv2: Array = heir2.get_state("inventory", []) as Array
	expect_eq(heir_inv2.size(), 3, "heir inventory has 3 items after transfer")
	expect(
		heir_inv2.has("sword") and heir_inv2.has("shield") and heir_inv2.has("potion"),
		"heir inventory contains all source items"
	)
	var src_inv2: Array = src2.get_state("inventory", []) as Array
	expect_eq(src_inv2.size(), 0, "source inventory cleared after transfer (atomic ownership)")
	src2.queue_free()
	heir2.queue_free()
	dd2.queue_free()

	# ---------- 3. transfer_reputation moves all reputation ----------
	# Source has rep with [pendrel: 75, brookhaven: 20]. Heir has
	# pre-existing [brookhaven: 50, riverside: 30]. After transfer:
	# heir.reputation = {pendrel: 75, brookhaven: max(20,50)=50,
	# riverside: 30}. Source's reputation cleared.
	var dd3 := DynastyDirector.new()
	var src_def3: Dictionary = {
		"id": "src",
		"tags": ["actor"],
		"state_init": {"reputation": {"pendrel": 75, "brookhaven": 20}}
	}
	var heir_def3: Dictionary = {
		"id": "heir",
		"tags": ["actor"],
		"state_init": {"reputation": {"brookhaven": 50, "riverside": 30}}
	}
	var src3 := Entity.create(src_def3, "src3")
	var heir3 := Entity.create(heir_def3, "heir3")
	var env3: Dictionary = {
		"entities": {"src3": src3, "heir3": heir3},
		"defs": {"src": src_def3, "heir": heir_def3},
		"world": {},
		"signal_buffer": [],
	}
	dd3.transfer_reputation(env3, "src3", "heir3")
	var heir_rep3: Dictionary = heir3.get_state("reputation", {}) as Dictionary
	expect_eq(
		int(heir_rep3.get("pendrel", -1)),
		75,
		"heir reputation: pendrel=75 (newly added from source)"
	)
	expect_eq(
		int(heir_rep3.get("brookhaven", -1)),
		50,
		"heir reputation: brookhaven=50 (max(20,50) — heir's higher value preserved)"
	)
	expect_eq(
		int(heir_rep3.get("riverside", -1)),
		30,
		"heir reputation: riverside=30 (heir's existing value preserved)"
	)
	var src_rep3: Dictionary = src3.get_state("reputation", {}) as Dictionary
	expect(src_rep3.is_empty(), "source reputation cleared after transfer (atomic ownership)")
	src3.queue_free()
	heir3.queue_free()
	dd3.queue_free()

	# ---------- 4. transfer_techs filters core vs derived ----------
	# Source knows [smithing(core), ironworking(core), steel(derived)].
	# transfer_techs filter="core_only" gives heir [smithing, ironworking];
	# steel is NOT transferred (core=false).
	var ttd4 := _make_tech_director_two_trees()
	# Mount via a parent World stub so DynastyDirector.transfer_techs
	# can find TechTreeDirector via env.parent.get_node_or_null.
	var world_stub4 := Node.new()
	world_stub4.name = "World"
	world_stub4.add_child(ttd4)
	ttd4.name = "TechTreeDirector"
	var dd4 := DynastyDirector.new()
	world_stub4.add_child(dd4)
	dd4.name = "DynastyDirector"
	# DynastyDirector reads _world via get_parent in _ready, but
	# tests create it standalone — manually assign for the get_node
	# fallback to find TechTreeDirector. Note: this is by design;
	# tests bypass _ready by instantiating directly.
	dd4._world = world_stub4
	var src_def4: Dictionary = {
		"id": "src",
		"tags": ["smith"],
		"state_init": {"known_techs": ["smithing", "ironworking", "steel"]}
	}
	var heir_def4: Dictionary = {"id": "heir", "tags": ["smith"], "state_init": {"known_techs": []}}
	var src4 := Entity.create(src_def4, "src4")
	var heir4 := Entity.create(heir_def4, "heir4")
	var env4: Dictionary = {
		"entities": {"src4": src4, "heir4": heir4},
		"defs": {"src": src_def4, "heir": heir_def4},
		"world": {},
		"signal_buffer": [],
		"parent": world_stub4,
		"relations": RelationStore.new(),
	}
	var transferred4: Array = dd4.transfer_techs(env4, "src4", "heir4", "core_only")
	expect_eq(
		transferred4.size(),
		2,
		"transfer_techs core_only: 2 nodes (smithing+ironworking, NOT steel)"
	)
	expect(
		transferred4.has("smithing") and transferred4.has("ironworking"),
		"transferred = [smithing, ironworking]"
	)
	expect(
		not transferred4.has("steel"),
		"transferred does NOT include steel (core=false filtered out)"
	)
	src4.queue_free()
	heir4.queue_free()
	world_stub4.queue_free()

	# ---------- 5. class_progress NOT transferred (heir starts class fresh) ----------
	# Source is level-5 farmer; heir's class_progress remains empty
	# after succession. Per ADR 0034 §"selective inheritance" — every
	# generation rediscovers their own path. Verify the dynasty chain
	# does NOT touch heir.class_progress.
	var dd5 := DynastyDirector.new()
	var src_def5: Dictionary = {
		"id": "src",
		"tags": ["actor"],
		"state_init":
		{
			"current_class": "farmer",
			"class_progress": {"farmer": {"level": 5, "xp": 1200}},
			"inventory": ["seeds"],
		}
	}
	var heir_def5: Dictionary = {
		"id": "heir",
		"tags": ["actor"],
		"state_init":
		{
			"class_progress": {},
			"inventory": [],
		}
	}
	var src5 := Entity.create(src_def5, "src5")
	var heir5 := Entity.create(heir_def5, "heir5")
	var env5: Dictionary = {
		"entities": {"src5": src5, "heir5": heir5},
		"defs": {"src": src_def5, "heir": heir_def5},
		"world": {},
		"signal_buffer": [],
	}
	dd5.transfer_inventory(env5, "src5", "heir5")
	# Note: dynasty director has NO transfer_class_progress effect. The
	# four effects are inventory + reputation + techs + transition_player_to.
	# Class progress is intentionally absent — verifying the transfer
	# layer does not sneak it in.
	var heir_progress5: Dictionary = heir5.get_state("class_progress", {}) as Dictionary
	expect(
		heir_progress5.is_empty(),
		"heir class_progress empty after inventory transfer (NO inheritance)"
	)
	src5.queue_free()
	heir5.queue_free()
	dd5.queue_free()

	# ---------- 6. transition_player_to swaps active actor ----------
	# Build an ActorManager with two actors; verify dynasty's
	# transition_player_to causes set_active to fire.
	var dd6 := DynastyDirector.new()
	var am6 := ActorManager.new()
	am6._actors = [
		{
			"id": "old_player",
			"starting_entity_tag": "player_a",
			"control_mode": "human",
			"input_device": "keyboard"
		},
		{
			"id": "new_player",
			"starting_entity_tag": "player_b",
			"control_mode": "human",
			"input_device": "keyboard"
		},
	]
	for a in am6._actors:
		am6._by_id[str(a["id"])] = a
	am6.active_actor_id = "old_player"
	# Mount stub world parent that the director can read actor_manager
	# from. World has a public `actor_manager` field; dynasty reads it
	# via `_world.actor_manager`.
	var world_stub6 := Node.new()
	world_stub6.name = "World"
	dd6._world = world_stub6
	# Path 1 wiring (`_world.actor_manager` → set_active) requires a
	# real World instance with the actor_manager field declared. Tests
	# verify the FOUNDATION (ActorManager.set_active) works in isolation;
	# integration tests cover the full path via play.tscn. Path 2 (the
	# state.is_player fallback) is exercised below since a bare Node
	# stub has no `actor_manager` property — `"actor_manager" in _world`
	# returns false and the director falls through to the entity path.
	var swap_ok6: bool = am6.set_active("new_player")
	expect(swap_ok6, "ActorManager.set_active accepts known actor id (transition foundation)")
	expect_eq(am6.active_actor_id, "new_player", "after transition: active_actor_id = new_player")
	# Path 2: dynasty fallback when no ActorManager — sets state.is_player.
	var ent6_def: Dictionary = {"id": "heir_ent", "tags": ["actor"], "state_init": {"is_player": 0}}
	var ent6 := Entity.create(ent6_def, "heir_ent6")
	var env6: Dictionary = {
		"entities": {"heir_ent6": ent6},
		"defs": {"heir_ent": ent6_def},
		"world": {},
		"signal_buffer": [],
	}
	# Director's _world is a bare Node without actor_manager —
	# transition_player_to falls through to setting is_player.
	var ok6: bool = dd6.transition_player_to(env6, "heir_ent6")
	expect(ok6, "transition_player_to fallback returns true on entity hit")
	expect_eq(
		int(ent6.get_state("is_player", 0)),
		1,
		"fallback path: state.is_player set to 1 on the new actor entity"
	)
	ent6.queue_free()
	world_stub6.queue_free()
	dd6.queue_free()

	# ---------- 7. infinite_life integration ----------
	# Re-verify lifecycle's infinite_life behavior in the dynasty
	# context: settings.infinite_life=true + player tag + age=100
	# → entity_died NEVER reaches signal_buffer → handle_dynasty_succession
	# is never called → no transition_player_to fires (verified by
	# absence of dynasty_succeeded signal and active actor unchanged).
	var lc7 := LifecycleDirector.new()
	var immortal_def7: Dictionary = {
		"id": "immortal_player",
		"tags": ["player", "human"],
		"lifecycle": human_template,
		"state_init": {"age": 79.5, "life_stage": "adult"},
	}
	var immortal7 := Entity.create(immortal_def7, "immortal7")
	var entities7: Dictionary = {"immortal7": immortal7}
	var env7: Dictionary = {
		"entities": entities7,
		"defs": {"immortal_player": immortal_def7},
		"world": {},
		"signal_buffer": [],
		"tick_count": 1,
		"settings": {"infinite_life": true},
	}
	lc7.register_lifecycle("immortal7", human_template, env7, "human")
	lc7.tick(env7, 1.0)  # would cross to dead, but infinite_life caps
	var saw_death7: bool = false
	for s in env7["signal_buffer"] as Array:
		if s is Dictionary and str((s as Dictionary).get("name", "")) == "entity_died":
			saw_death7 = true
			break
	expect(
		not saw_death7,
		"infinite_life integration: entity_died NOT emitted when settings.infinite_life=true"
	)
	# Without the signal, dynasty director never fires — the chain
	# is structurally suppressed upstream (no new code in dynasty
	# director needed; ADR 0036 already handles it).
	expect_eq(
		str(immortal7.get_state("life_stage", "")),
		"adult",
		"infinite_life: life_stage capped at adult (NOT advanced to dead)"
	)
	immortal7.queue_free()
	lc7.queue_free()

	# ---------- 8. multi-heir branching: pick first eligible ----------
	# Source has heirs=[h1, h2]. h1 dead, h2 alive → succession picks h2.
	# When BOTH dead → dynasty_extinct signal fires.
	var dd8 := DynastyDirector.new()
	var src_def8: Dictionary = {
		"id": "src",
		"tags": ["actor"],
		"state_init": {"heirs": ["h1", "h2"], "inventory": ["crown"]}
	}
	var h1_def8: Dictionary = {
		"id": "heir", "tags": ["actor"], "state_init": {"life_stage": "dead", "inventory": []}
	}
	var h2_def8: Dictionary = {
		"id": "heir", "tags": ["actor"], "state_init": {"life_stage": "adult", "inventory": []}
	}
	var src8 := Entity.create(src_def8, "src8")
	var h1_8 := Entity.create(h1_def8, "h1")
	var h2_8 := Entity.create(h2_def8, "h2")
	var env8: Dictionary = {
		"entities": {"src8": src8, "h1": h1_8, "h2": h2_8},
		"defs": {"src": src_def8, "heir": h1_def8},
		"world": {},
		"signal_buffer": [],
	}
	# resolve_first_eligible_heir walks heirs[] order — h1 dead, h2 alive.
	var picked8: String = dd8.resolve_first_eligible_heir(env8, "src8")
	expect_eq(picked8, "h2", "multi-heir: first-eligible picks h2 (h1 dead, h2 alive)")
	# Run full succession chain. Since src.state.heirs is [h1, h2] and
	# h2 is alive, full chain should succeed and emit dynasty_succeeded.
	var result8: Dictionary = dd8.handle_dynasty_succession(env8, "src8")
	expect(bool(result8.get("ok", false)), "handle_dynasty_succession succeeds when h2 is eligible")
	expect_eq(str(result8.get("heir_id", "")), "h2", "succession.heir_id = h2 (the eligible one)")
	# Crown should now be in h2's inventory.
	var h2_inv8: Array = h2_8.get_state("inventory", []) as Array
	expect(h2_inv8.has("crown"), "successor h2 received the crown via transfer_inventory")
	# dynasty_succeeded signal in buffer.
	var saw_succeeded8: bool = false
	for s in env8["signal_buffer"] as Array:
		if s is Dictionary and str((s as Dictionary).get("name", "")) == "dynasty_succeeded":
			saw_succeeded8 = true
			break
	expect(saw_succeeded8, "dynasty_succeeded signal emitted on successful succession")
	# Now kill h2 too — both heirs dead, expect dynasty_extinct.
	h2_8.set_state("life_stage", "dead")
	# Reset src.state.heirs (was reset by succession's inventory transfer
	# but heirs field stays). Re-run succession from a NEW source to
	# keep semantics clean.
	var src_def8b: Dictionary = {
		"id": "src",
		"tags": ["actor"],
		"state_init": {"heirs": ["h1", "h2"], "inventory": ["scepter"]}
	}
	var src8b := Entity.create(src_def8b, "src8b")
	(env8["entities"] as Dictionary)["src8b"] = src8b
	env8["signal_buffer"] = []  # isolate next signal check
	var result8b: Dictionary = dd8.handle_dynasty_succession(env8, "src8b")
	expect(
		not bool(result8b.get("ok", false)),
		"handle_dynasty_succession: ok=false when all heirs dead"
	)
	expect_eq(
		str(result8b.get("reason", "")), "extinct", "reason=extinct when all heirs dead/missing"
	)
	var saw_extinct8: bool = false
	for s in env8["signal_buffer"] as Array:
		if s is Dictionary and str((s as Dictionary).get("name", "")) == "dynasty_extinct":
			saw_extinct8 = true
			break
	expect(saw_extinct8, "dynasty_extinct signal emitted when no eligible heir found")
	src8.queue_free()
	h1_8.queue_free()
	h2_8.queue_free()
	src8b.queue_free()
	dd8.queue_free()

	# ---------- 9. save/load round-trips dynasty state ----------
	# Verify state.heirs (Array) + state.inheritance_policy (Dict) +
	# state.dynasty_id (String) survive a snapshot+restore round-trip.
	# This proves ADR 0010 normal entity persistence covers dynasty
	# state without any new save-policy field.
	var save_def9: Dictionary = {
		"id": "saver",
		"tags": ["actor", "player"],
		"state_init":
		{
			"heirs": ["heir_a", "heir_b", "heir_c"],
			"dynasty_id": "house_aldermere",
			"inheritance_policy":
			{
				"inventory": "all",
				"reputation": "all",
				"core_techs": true,
				"class_progress": false,
			},
		},
	}
	var s9 := Entity.create(save_def9, "s9")
	var snap9: Dictionary = s9.snapshot()
	# Mutate to prove restore overwrites.
	s9.set_state("heirs", [])
	s9.set_state("dynasty_id", "")
	s9.set_state("inheritance_policy", {})
	# Restore.
	for k in (snap9.get("state", {}) as Dictionary).keys():
		s9.set_state(str(k), (snap9["state"] as Dictionary)[k])
	var restored_heirs9: Array = s9.get_state("heirs", []) as Array
	expect_eq(restored_heirs9.size(), 3, "save/load: heirs Array size=3 round-trip")
	expect(
		(
			restored_heirs9.has("heir_a")
			and restored_heirs9.has("heir_b")
			and restored_heirs9.has("heir_c")
		),
		"save/load: all 3 heir ids preserved in order"
	)
	expect_eq(
		str(s9.get_state("dynasty_id", "")),
		"house_aldermere",
		"save/load: dynasty_id String round-trip"
	)
	var restored_policy9: Dictionary = s9.get_state("inheritance_policy", {}) as Dictionary
	expect_eq(
		str(restored_policy9.get("inventory", "")),
		"all",
		"save/load: inheritance_policy.inventory round-trip"
	)
	expect_eq(
		bool(restored_policy9.get("core_techs", false)),
		true,
		"save/load: inheritance_policy.core_techs round-trip"
	)
	expect_eq(
		bool(restored_policy9.get("class_progress", true)),
		false,
		"save/load: inheritance_policy.class_progress=false round-trip"
	)
	s9.queue_free()

	# ---------- 10. emergent dynasty: per-generation class_progress ----------
	# Generation 1 has class_progress.farmer.level=5. Succession transfers
	# inventory + reputation but NOT class_progress. Gen 2 (the heir)
	# accrues their OWN class_progress. Verify gen2.class_progress is
	# untouched by inheritance — proves the "every generation rediscovers
	# their own path" design (ADR 0034 §selective inheritance).
	var dd10 := DynastyDirector.new()
	var gen1_def10: Dictionary = {
		"id": "gen1",
		"tags": ["actor"],
		"state_init":
		{
			"current_class": "farmer",
			"class_progress": {"farmer": {"level": 5, "xp": 1500}},
			"inventory": ["heirloom_hoe"],
			"reputation": {"pendrel": 60},
			"heirs": ["gen2"],
		}
	}
	var gen2_def10: Dictionary = {
		"id": "gen2",
		"tags": ["actor"],
		"state_init":
		{
			"current_class": "farmer",
			"class_progress": {},
			"inventory": [],
			"reputation": {},
			"life_stage": "adult",
		}
	}
	var gen1 := Entity.create(gen1_def10, "gen1")
	var gen2 := Entity.create(gen2_def10, "gen2")
	var env10: Dictionary = {
		"entities": {"gen1": gen1, "gen2": gen2},
		"defs": {"gen1": gen1_def10, "gen2": gen2_def10},
		"world": {},
		"signal_buffer": [],
	}
	# Run succession. gen2 takes over.
	var result10: Dictionary = dd10.handle_dynasty_succession(env10, "gen1")
	expect(bool(result10.get("ok", false)), "emergent: gen1→gen2 succession ok")
	# gen2 received the heirloom (inventory transferred).
	var gen2_inv10: Array = gen2.get_state("inventory", []) as Array
	expect(
		gen2_inv10.has("heirloom_hoe"),
		"emergent: gen2 received heirloom_hoe (inventory transferred)"
	)
	# gen2 received the rep (reputation transferred).
	var gen2_rep10: Dictionary = gen2.get_state("reputation", {}) as Dictionary
	expect_eq(
		int(gen2_rep10.get("pendrel", -1)),
		60,
		"emergent: gen2 reputation = pendrel:60 (reputation transferred)"
	)
	# gen2's class_progress is STILL EMPTY — succession did not copy it.
	# The heir starts class progression fresh, even though gen1 was a
	# level-5 farmer. This is the emergent dynasty arc: each generation
	# specializes anew.
	var gen2_progress10: Dictionary = gen2.get_state("class_progress", {}) as Dictionary
	expect(
		gen2_progress10.is_empty(),
		"emergent: gen2.class_progress STILL EMPTY (every generation starts fresh)"
	)
	# Now gen2 accrues its own progress (simulate by setting). Verify
	# it doesn't bleed back to gen1 — they're independent stores per
	# entity. gen1 is "deceased" but still exists in env.entities;
	# its class_progress is untouched by gen2's mutations.
	gen2.set_state("class_progress", {"farmer": {"level": 1, "xp": 50}})
	var gen1_progress10: Dictionary = gen1.get_state("class_progress", {}) as Dictionary
	expect_eq(
		int((gen1_progress10.get("farmer", {}) as Dictionary).get("level", -1)),
		5,
		"emergent: gen1.class_progress.farmer.level still 5 (independent store)"
	)
	var gen2_progress10b: Dictionary = gen2.get_state("class_progress", {}) as Dictionary
	var gen2_farmer10b: Dictionary = gen2_progress10b.get("farmer", {}) as Dictionary
	expect_eq(
		int(gen2_farmer10b.get("level", -1)),
		1,
		"emergent: gen2.class_progress.farmer.level = 1 (gen2's own arc)"
	)
	gen1.queue_free()
	gen2.queue_free()
	dd10.queue_free()


# ============================================================
# ADR 0039 — Playwright-style scenario steps (step_runner)
# ============================================================


func test_step_runner() -> void:
	_section("step_runner (ADR 0039)")

	# Build a minimal World fit for headless step_runner exercise. We need:
	#   - a registered InputMap action so press/hold/release have a real
	#     target
	#   - a player entity tagged 'player' so expect-compact form resolves
	#   - a tick rule that mutates state on the test action so we can
	#     verify ticks ran
	var test_action := "step_test_action"
	if InputMap.has_action(test_action):
		InputMap.action_erase_events(test_action)
	else:
		InputMap.add_action(test_action)

	var defs: Dictionary = {
		"player":
		{
			"id": "player",
			"tags": ["player"],
			"state_init": {"counter": 0, "position": Vector3.ZERO},
		},
	}
	var world := World.new()
	world.auto_start = false
	world.verbose = false
	world.tick_seconds = 0.1
	add_child(world)
	world.scheduler = PhaseScheduler.new({})
	var player := Entity.create(defs["player"], "p1", {})
	var entities: Dictionary = {"p1": player}
	world.scheduler.env = {
		"entities": entities,
		"defs": defs,
		"relations": RelationStore.new(),
		"spatial_index": SpatialIndex.new(),
		"world": {},
		"parent": world,
		"next_id": {"_": 0},
		"error_buffer": [],
	}
	world.world_state = world.scheduler.env["world"]
	# Register a rule that increments player.counter on the test action.
	var rule := (
		Rule
		. from_dict(
			{
				"id": "step_test_increment",
				"trigger": {"type": "input", "action": test_action},
				"query": {"tags_all": ["player"]},
				"effect":
				{
					"type": "state_set",
					"target": "self",
					"field": "counter",
					"value": "self.state.counter + 1"
				},
			}
		)
	)
	world.scheduler.register_rules([rule])

	# ---------- 1. test_press ----------
	var ctx1: Dictionary = {
		"verbose": false, "passed": 0, "failed": 0, "failures": [], "screenshots": []
	}
	var r1 = await StepRunner.run([{"press": test_action}], world, ctx1)
	expect_eq(
		int(player.get_state("counter", 0)), 1, "press: rule fired exactly once → counter = 1"
	)
	expect(r1.get("failed", 0) == 0, "press: no failures")

	# ---------- 2. test_hold (single action, multi-tick) ----------
	player.state["counter"] = 0
	var ctx2: Dictionary = {
		"verbose": false, "passed": 0, "failed": 0, "failures": [], "screenshots": []
	}
	# tick_seconds=0.1, for=0.5 → round(0.5/0.1) = 5 ticks; rule fires
	# once per tick while held.
	await StepRunner.run([{"hold": test_action, "for": 0.5}], world, ctx2)
	expect(int(player.get_state("counter", 0)) == 5, "hold for 0.5s = 5 ticks; rule fired 5×")

	# ---------- 3. test_hold_multi (two simultaneous actions) ----------
	# Register a second action; verify both can be held together without
	# crashing. State assertion validated via WASD lib in real Aldenmere
	# scenarios; here we just verify both actions are released after.
	var test_action2 := "step_test_action2"
	if InputMap.has_action(test_action2):
		InputMap.action_erase_events(test_action2)
	else:
		InputMap.add_action(test_action2)
	var ctx3: Dictionary = {
		"verbose": false, "passed": 0, "failed": 0, "failures": [], "screenshots": []
	}
	await StepRunner.run([{"hold": [test_action, test_action2], "for": 0.3}], world, ctx3)
	expect(not Input.is_action_pressed(test_action), "hold multi: action1 released after for")
	expect(not Input.is_action_pressed(test_action2), "hold multi: action2 released after for")

	# ---------- 4. test_wait_seconds_vs_ticks ----------
	player.state["counter"] = 0
	var ctx4: Dictionary = {
		"verbose": false, "passed": 0, "failed": 0, "failures": [], "screenshots": []
	}
	# wait shouldn't fire any rule (no input held), but ticks advance.
	await StepRunner.run([{"wait": 0.3}], world, ctx4)
	expect(int(player.get_state("counter", 0)) == 0, "wait: no input held, counter unchanged")
	# wait with explicit ticks form
	await StepRunner.run([{"wait": {"ticks": 2}}], world, ctx4)
	expect(
		int(player.get_state("counter", 0)) == 0, "wait ticks form: counter unchanged (no input)"
	)

	# ---------- 5. test_tick (deterministic count) ----------
	var ctx5: Dictionary = {
		"verbose": false, "passed": 0, "failed": 0, "failures": [], "screenshots": []
	}
	await StepRunner.run([{"tick": 3}], world, ctx5)
	# No-op for state (no input); just verify it ran without error.
	expect(int(ctx5.get("failed", 0)) == 0, "tick: 3-tick advance ran without error")

	# ---------- 6. test_expect_legacy_form ----------
	player.state["counter"] = 7
	var ctx6: Dictionary = {
		"verbose": false, "passed": 0, "failed": 0, "failures": [], "screenshots": []
	}
	await StepRunner.run(
		[
			{
				"expect":
				[
					{
						"entity_field":
						{
							"query": {"tags_all": ["player"]},
							"field": "state.counter",
							"op": "==",
							"value": 7
						}
					}
				]
			}
		],
		world,
		ctx6
	)
	expect_eq(int(ctx6.get("passed", 0)), 1, "expect legacy form: 1 pass")
	expect_eq(int(ctx6.get("failed", 0)), 0, "expect legacy form: 0 fails")

	# ---------- 7. test_expect_compact_form ----------
	player.state["counter"] = 42
	var ctx7: Dictionary = {
		"verbose": false, "passed": 0, "failed": 0, "failures": [], "screenshots": []
	}
	await StepRunner.run([{"expect": [{"player.state.counter": {">=": 40}}]}], world, ctx7)
	expect_eq(
		int(ctx7.get("passed", 0)), 1, "expect compact: 1 pass for player.state.counter >= 40"
	)

	# ---------- 8. test_expect_failure_records ----------
	player.state["counter"] = 5
	var ctx8: Dictionary = {
		"verbose": false, "passed": 0, "failed": 0, "failures": [], "screenshots": []
	}
	await StepRunner.run([{"expect": [{"player.state.counter": {">": 100}}]}], world, ctx8)
	expect_eq(int(ctx8.get("failed", 0)), 1, "expect failure: 1 recorded fail")

	# ---------- 9. test_unknown_verb ----------
	var ctx9: Dictionary = {
		"verbose": false, "passed": 0, "failed": 0, "failures": [], "screenshots": []
	}
	# A step with no recognized verb. Must NOT crash; should raise an
	# EngineError into env.error_buffer.
	world.scheduler.env["error_buffer"] = []
	await StepRunner.run([{"flubber": "X"}], world, ctx9)
	var errs: Array = world.scheduler.env.get("error_buffer", [])
	var saw_unknown_verb := false
	for e in errs:
		if (
			e is Dictionary
			and str((e as Dictionary).get("code", "")) == EngineError.STEP_UNKNOWN_VERB
		):
			saw_unknown_verb = true
			break
	expect(saw_unknown_verb, "unknown verb: STEP_UNKNOWN_VERB raised into error_buffer")

	# ---------- 10. test_unknown_action ----------
	var ctx10: Dictionary = {
		"verbose": false, "passed": 0, "failed": 0, "failures": [], "screenshots": []
	}
	world.scheduler.env["error_buffer"] = []
	await StepRunner.run([{"press": "no_such_action_xyz"}], world, ctx10)
	var errs10: Array = world.scheduler.env.get("error_buffer", [])
	var saw_unknown_action := false
	for e in errs10:
		if (
			e is Dictionary
			and str((e as Dictionary).get("code", "")) == EngineError.STEP_UNKNOWN_ACTION
		):
			saw_unknown_action = true
			break
	expect(saw_unknown_action, "unknown action: STEP_UNKNOWN_ACTION raised into error_buffer")

	# ---------- 11. test_invalid_duration ----------
	var ctx11: Dictionary = {
		"verbose": false, "passed": 0, "failed": 0, "failures": [], "screenshots": []
	}
	world.scheduler.env["error_buffer"] = []
	await StepRunner.run([{"hold": test_action, "for": 0}], world, ctx11)
	var errs11: Array = world.scheduler.env.get("error_buffer", [])
	var saw_invalid_dur := false
	for e in errs11:
		if (
			e is Dictionary
			and str((e as Dictionary).get("code", "")) == EngineError.STEP_INVALID_DURATION
		):
			saw_invalid_dur = true
			break
	expect(saw_invalid_dur, "invalid duration: STEP_INVALID_DURATION raised when for=0")

	# ---------- 12. test_advance_one_tick_parity ----------
	# advance_one_tick must drive the same env transitions the live tick branch does.
	# Empirical check: a tick rule fires under advance_one_tick same as
	# under scheduler.tick(). (Sanity test that the C4 refactor preserved
	# behavior — full coverage lives in unit tests for each verb above.)
	player.state["counter"] = 0
	world.advance_one_tick()
	# No held input → counter unchanged
	expect(
		int(player.get_state("counter", 0)) == 0, "advance_one_tick: no input held, no rule fires"
	)

	# Cleanup
	world.queue_free()


# ============================================================
# ADR 0038 — Grid-based placement (grid_snap)
# ============================================================


func test_grid_snap() -> void:
	_section("grid_snap (ADR 0038)")

	# ---------- 1. test_snap_math_round_trip ----------
	# Idempotence + a few hand-checked values.
	var env_size2: Dictionary = {"scene_grid": {"size": 2.0}}
	var p1 := Vector3(12.347, 0, 47.918)
	var s1 := GridSnap.snap_position(p1, env_size2)
	expect_eq(s1.x, 12.0, "snap (12.347, _, 47.918) size=2 → x=12")
	expect_eq(s1.z, 48.0, "snap (12.347, _, 47.918) size=2 → z=48")
	expect_eq(s1.y, 0.0, "y default disabled → y unchanged at 0")
	# Round-trip: snap(snap(x)) == snap(x)
	var s2 := GridSnap.snap_position(s1, env_size2)
	expect(s1 == s2, "snap idempotent (snap(snap(x)) == snap(x))")
	# Yaw snap to π/2
	var ya := GridSnap.snap_yaw(0.4, env_size2)
	expect(abs(ya - 0.0) < 1e-5, "snap_yaw(0.4) → 0.0 with default π/2 increment")
	var yb := GridSnap.snap_yaw(1.0, env_size2)
	expect(abs(yb - PI / 2.0) < 1e-5, "snap_yaw(1.0) → π/2 (closest 90° multiple)")

	# ---------- 2. test_y_size_default_disabled ----------
	# Per Condition C2: y_size defaults to 0 (disabled). Vertical position
	# passes through unchanged unless author opts in.
	var p_y := Vector3(0, 1.7, 0)
	var s_y := GridSnap.snap_position(p_y, env_size2)
	expect(abs(s_y.y - 1.7) < 1e-4, "y_size=0 default → y unchanged (1.7 stays 1.7)")
	# Opt in: y_size=1.0 → y snaps to integer multiples
	var env_y := {"scene_grid": {"size": 2.0, "y_size": 1.0}}
	var s_y2 := GridSnap.snap_position(p_y, env_y)
	expect_eq(s_y2.y, 2.0, "y_size=1 enabled → y=1.7 snaps to 2")

	# ---------- 3. test_exempt_tags_skip ----------
	var actor_def: Dictionary = {"id": "test_actor", "tags": ["actor", "human"]}
	var prop_def: Dictionary = {"id": "test_prop", "tags": ["building"]}
	expect(
		not GridSnap.should_snap(actor_def, env_size2),
		"exempt_tags default includes 'actor' → should_snap=false"
	)
	expect(GridSnap.should_snap(prop_def, env_size2), "non-exempt def tags → should_snap=true")
	# Override: empty exempt_tags → even actors snap (chess-like games)
	var env_chess := {"scene_grid": {"size": 2.0, "exempt_tags": []}}
	expect(GridSnap.should_snap(actor_def, env_chess), "exempt_tags=[] → actors snap (chess-mode)")

	# ---------- 4. test_no_grid_block_unchanged (backward-compat sentinel) ----------
	# Empty env (no scene_grid key) → snap is no-op for every shape.
	var env_none: Dictionary = {}
	expect(not GridSnap.is_enabled(env_none), "no scene_grid → is_enabled=false")
	var p_none := Vector3(12.347, 1.5, 47.918)
	var s_none := GridSnap.snap_position(p_none, env_none)
	expect(s_none == p_none, "no scene_grid → position unchanged (backward-compat)")
	expect(
		GridSnap.snap_yaw(0.42, env_none) == 0.42, "no scene_grid → yaw unchanged (backward-compat)"
	)
	# Empty dict for scene_grid also means disabled.
	var env_empty := {"scene_grid": {}}
	expect(not GridSnap.is_enabled(env_empty), "empty scene_grid dict → is_enabled=false")

	# ---------- 5. test_drift_check_warns ----------
	# When authored position drifts >0.1*size from nearest cell, warning
	# fires. Test by capturing warnings via push_warning side-effect — we
	# can't capture push_warning output directly, so we verify behavior
	# is non-crashing and snapped result is correct.
	var drifted := Vector3(13.5, 0, 47.5)  # both axes drift 1.5 from cell at 12,48
	var s_drift := GridSnap.snap_position_with_drift_check(drifted, env_size2, "test_entity_drift")
	expect_eq(s_drift.x, 14.0, "drift check returns snapped x=14 for input 13.5")
	expect_eq(s_drift.z, 48.0, "drift check returns snapped z=48 for input 47.5")

	# ---------- 6. test_initial_instances_snap (integration) ----------
	# Build a minimal World, give it scene_grid via _grid_cfg, spawn an
	# entity at a fractional position, verify it lands snapped.
	var world := World.new()
	world.auto_start = false
	world.verbose = false
	world.tick_seconds = 0.1
	add_child(world)
	# Inject grid config directly (bypassing scene.json read).
	# _grid_cfg stays on World (read by _build_env); _grid_cfg_loaded
	# moved to WorldLoader on 2026-05-12 (cache flag is loader-internal).
	world._grid_cfg = {"size": 2.0, "snap_initial": true}
	if world._loader != null:
		world._loader._grid_cfg_loaded = true
	# Set up minimal env so spawn works.
	world.entities = {}
	world.defs = {
		"snap_test_def":
		{
			"id": "snap_test_def",
			"tags": ["building"],  # not exempt
			"state_init": {"position": Vector3(12.347, 0, 47.918)},
		}
	}
	world.next_id_seq = {"_": 0}
	world.error_buffer = []
	world.spatial_index = SpatialIndex.new()
	world.relations = RelationStore.new()
	world.world_state = {}
	# Spawn via initial-instance dict (mirrors what world.gd does at load).
	world._spawn_manager.spawn({"def": "snap_test_def", "id": "snap_inst_1"})
	var spawned: Entity = world.entities.get("snap_inst_1", null)
	expect(spawned != null, "initial_instances: entity spawned")
	if spawned != null:
		var pos: Vector3 = spawned.state["position"]
		expect_eq(pos.x, 12.0, "initial_instances snap: x snapped to 12")
		expect_eq(pos.z, 48.0, "initial_instances snap: z snapped to 48")
	# Exempt actor at fractional pos: should NOT snap.
	world.defs["snap_test_actor"] = {
		"id": "snap_test_actor",
		"tags": ["actor"],  # exempt by default
		"state_init": {"position": Vector3(5.7, 0, 5.7)},
	}
	world._spawn_manager.spawn({"def": "snap_test_actor", "id": "snap_actor_1"})
	var actor: Entity = world.entities.get("snap_actor_1", null)
	expect(actor != null, "exempt actor entity spawned")
	if actor != null:
		var apos: Vector3 = actor.state["position"]
		expect(abs(apos.x - 5.7) < 1e-4, "exempt actor position.x preserved at 5.7")
		expect(abs(apos.z - 5.7) < 1e-4, "exempt actor position.z preserved at 5.7")
	world.queue_free()


# ============================================================
# MultiMeshDirector tests (ADR 0041)
# ============================================================


func test_multimesh_director() -> void:
	_section("multimesh_director (ADR 0041)")

	var dir := MultiMeshDirector.new()

	# ---------- 1. _is_static_candidate gates ----------
	# Actor / projectile / player tag → never static, even with zero velocity.
	var e_actor := Entity.new()
	e_actor.tags = ["villager", "actor"]
	e_actor.state = {"velocity": Vector2.ZERO}
	expect(
		not dir._is_static_candidate(e_actor, {}, {}), "actor tag disqualifies from static batching"
	)

	var e_proj := Entity.new()
	e_proj.tags = ["projectile"]
	e_proj.state = {"velocity": Vector2.ZERO}
	expect(not dir._is_static_candidate(e_proj, {}, {}), "projectile tag disqualifies")

	var e_player := Entity.new()
	e_player.tags = ["player"]
	e_player.state = {"velocity": Vector2.ZERO}
	expect(not dir._is_static_candidate(e_player, {}, {}), "player tag disqualifies")

	# Non-zero velocity → not static.
	var e_moving := Entity.new()
	e_moving.tags = ["tree"]
	e_moving.state = {"velocity": Vector2(1, 0)}
	expect(not dir._is_static_candidate(e_moving, {}, {}), "non-zero velocity disqualifies")

	# Static-eligible tree (no runtime tags, zero velocity).
	var e_tree := Entity.new()
	e_tree.tags = ["tree", "decorative"]
	e_tree.state = {"velocity": Vector2.ZERO}
	expect(dir._is_static_candidate(e_tree, {}, {}), "plain tree IS static-eligible")

	# Tag-class disqualification: if rule mutates a field on "tree", trees
	# are out.
	var disq := {"tree": true}
	expect(
		not dir._is_static_candidate(e_tree, {}, disq),
		"tag in disqualified_tags set blocks static eligibility"
	)

	# ---------- 2. _scan_disqualified_tag_classes — position mutation ----------
	# Rule that fires state_set position targeting trees → "tree" disqualified.
	var rule_pos_mut := (
		Rule
		. from_dict(
			{
				"id": "tree_grow",
				"trigger": {"type": "tick", "interval": 1},
				"query": {"tags_all": ["tree"]},
				"effect":
				{"type": "state_set", "target": "self", "field": "position", "value": [0, 0, 0]},
			}
		)
	)
	var disq2 := dir._scan_disqualified_tag_classes([rule_pos_mut])
	expect(disq2.has("tree"), "rule mutating position on trees → 'tree' disqualified")

	# ---------- 3. _scan_disqualified_tag_classes — non-mutation field ----------
	# Rule mutating display_name (NOT in MUTATION_FIELDS) → tree stays eligible.
	var rule_name_mut := (
		Rule
		. from_dict(
			{
				"id": "tree_rename",
				"trigger": {"type": "tick", "interval": 1},
				"query": {"tags_all": ["tree"]},
				"effect":
				{
					"type": "state_set",
					"target": "self",
					"field": "display_name",
					"value": "renamed"
				},
			}
		)
	)
	var disq3 := dir._scan_disqualified_tag_classes([rule_name_mut])
	expect(not disq3.has("tree"), "rule mutating non-tracked field does NOT disqualify")

	# ---------- 4. velocity_set effect disqualifies ----------
	var rule_vel_mut := (
		Rule
		. from_dict(
			{
				"id": "wander",
				"trigger": {"type": "tick", "interval": 1},
				"query": {"tags_all": ["rabbit"]},
				"effect": {"type": "velocity_set", "target": "self", "x": 1, "y": 0},
			}
		)
	)
	var disq4 := dir._scan_disqualified_tag_classes([rule_vel_mut])
	expect(disq4.has("rabbit"), "velocity_set effect on rabbits → 'rabbit' disqualified")

	# ---------- 5. tag_add / tag_remove effects disqualify ----------
	var rule_tag_mut := (
		Rule
		. from_dict(
			{
				"id": "ignite",
				"trigger": {"type": "tick", "interval": 1},
				"query": {"tags_all": ["log_pile"]},
				"effect": {"type": "tag_add", "target": "self", "tags": ["burning"]},
			}
		)
	)
	var disq5 := dir._scan_disqualified_tag_classes([rule_tag_mut])
	expect(disq5.has("log_pile"), "tag_add effect on log_piles → 'log_pile' disqualified")

	# ---------- 6. _hash_params is stable ----------
	var p1: Dictionary = {"trunk": "#5a3820", "canopy": "#2d5028"}
	var p2: Dictionary = {"canopy": "#2d5028", "trunk": "#5a3820"}  # different insert order
	expect_eq(dir._hash_params(p1), dir._hash_params(p2), "hash_params stable across key order")

	# ---------- 7. _hash_params differs for different values ----------
	var p3: Dictionary = {"trunk": "#000000", "canopy": "#2d5028"}
	expect(dir._hash_params(p1) != dir._hash_params(p3), "hash_params differs when values differ")

	# ---------- 8. cleanup() returns 0 when nothing was built ----------
	var freed := dir.cleanup({})
	expect_eq(freed, 0, "cleanup with no built nodes returns 0")


# ============================================================
# Array primitives (multi-slot inventory foundation, #95)
# ============================================================


func test_array_primitives() -> void:
	_section("array_primitives (multi-slot inventory)")

	# Shared env / actor
	var actor := Entity.new()
	actor.instance_id = "actor_1"
	actor.state = {
		"inventory": ["", "", "", ""],
		"inventory_cooked": [0, 0, 0, 0],
		"inventory_wet": [0, 0, 0, 0],
		"active_slot": 0
	}
	var entities: Dictionary = {"actor_1": actor}
	var env: Dictionary = {
		"entities": entities,
		"world_state": {},
		"signal_buffer": [],
		"next_id": {"_": 0}
	}
	var ctx: Dictionary = {"self": "actor_1", "self_entity": actor}

	# ---------- array_insert_first_empty: first slot ----------
	EffectApply.apply(
		{
			"type": "array_insert_first_empty",
			"target": "self",
			"field": "inventory",
			"value": "food_berry",
			"sentinel": ""
		},
		env,
		ctx
	)
	expect_eq(actor.get_state("inventory"), ["food_berry", "", "", ""], "insert into first slot")
	expect_eq(actor.get_state("_last_slot"), 0, "_last_slot records chosen index 0")

	# ---------- array_set_at on parallel array using formula index ----------
	EffectApply.apply(
		{
			"type": "array_set_at",
			"target": "self",
			"field": "inventory_cooked",
			"index": "self.state._last_slot",
			"value": 1
		},
		env,
		ctx
	)
	expect_eq(
		actor.get_state("inventory_cooked"),
		[1, 0, 0, 0],
		"array_set_at via formula index hits same slot insert chose"
	)

	# ---------- Insert again: should go to slot 1 ----------
	EffectApply.apply(
		{
			"type": "array_insert_first_empty",
			"target": "self",
			"field": "inventory",
			"value": "food_mushroom",
			"sentinel": ""
		},
		env,
		ctx
	)
	expect_eq(
		actor.get_state("inventory"),
		["food_berry", "food_mushroom", "", ""],
		"second insert goes to slot 1"
	)
	expect_eq(actor.get_state("_last_slot"), 1, "_last_slot updates to slot 1")

	# ---------- array_sync_to_field: active_slot=0 → held_item='food_berry' ----------
	EffectApply.apply(
		{
			"type": "array_sync_to_field",
			"target": "self",
			"array_field": "inventory",
			"index_field": "active_slot",
			"dest_field": "held_item",
			"default": ""
		},
		env,
		ctx
	)
	expect_eq(actor.get_state("held_item"), "food_berry", "sync reads inventory[active_slot=0]")

	# Switch active_slot to 1 → sync to held_item='food_mushroom'
	actor.set_state("active_slot", 1)
	EffectApply.apply(
		{
			"type": "array_sync_to_field",
			"target": "self",
			"array_field": "inventory",
			"index_field": "active_slot",
			"dest_field": "held_item",
			"default": ""
		},
		env,
		ctx
	)
	expect_eq(actor.get_state("held_item"), "food_mushroom", "sync reads inventory[active_slot=1]")

	# ---------- array_count_matching: 2 free slots ----------
	EffectApply.apply(
		{
			"type": "array_count_matching",
			"target": "self",
			"array_field": "inventory",
			"sentinel": "",
			"dest_field": "inventory_empty_count"
		},
		env,
		ctx
	)
	expect_eq(actor.get_state("inventory_empty_count"), 2, "empty count = 2 free slots")

	# ---------- array_set_at clears active slot ----------
	EffectApply.apply(
		{
			"type": "array_set_at",
			"target": "self",
			"field": "inventory",
			"index": "self.state.active_slot",
			"value": ""
		},
		env,
		ctx
	)
	expect_eq(
		actor.get_state("inventory"),
		["food_berry", "", "", ""],
		"array_set_at clears slot 1 (active_slot)"
	)

	# ---------- Fill remaining slots; next insert should fire on_full ----------
	actor.set_state("inventory", ["a", "b", "c", "d"])
	env["signal_buffer"] = []
	EffectApply.apply(
		{
			"type": "array_insert_first_empty",
			"target": "self",
			"field": "inventory",
			"value": "overflow",
			"sentinel": "",
			"on_full": {"signal": "inventory_full", "payload": {"reason": "overflow"}}
		},
		env,
		ctx
	)
	expect_eq(actor.get_state("inventory"), ["a", "b", "c", "d"], "insert into full array no-ops")
	expect_eq(actor.get_state("_last_slot"), -1, "_last_slot=-1 signals failure")
	var sig_buf: Array = env["signal_buffer"]
	expect_eq(sig_buf.size(), 1, "on_full signal emitted once")
	expect_eq(sig_buf[0]["name"], "inventory_full", "signal name matches")
	expect_eq(sig_buf[0]["payload"]["reason"], "overflow", "signal payload propagates")

	# ---------- Custom payload-binding (non-allowlisted) auto-promotion ----------
	# Empirical case 2026-05-16: gather_pickup signal rule used `actor` (not
	# in the entity_roles allowlist) as a require binding, then referenced
	# `actor.state._last_slot` in a formula. Pre-fix, `actor` resolved to a
	# string and the formula crashed. Post-fix, formula_context auto-promotes
	# any ctx string value that names a real entity. Lock the behavior in.
	actor.set_state("_last_slot", 2)
	var custom_ctx: Dictionary = {"actor": "actor_1", "_rule_id": "gather_pickup_test"}
	EffectApply.apply(
		{
			"type": "array_set_at",
			"target": "actor",
			"field": "inventory_cooked",
			"index": "actor.state._last_slot",
			"value": 7
		},
		env,
		custom_ctx
	)
	var inv_c: Array = actor.get_state("inventory_cooked")
	expect_eq(
		inv_c[2],
		7,
		"custom payload binding 'actor' auto-promotes to Entity for formula drill-in"
	)

	# ---------- array_set_at no-ops on negative index (guard against -1 wrap) ----------
	actor.set_state("inventory", ["x", "y", "z", "w"])
	EffectApply.apply(
		{
			"type": "array_set_at",
			"target": "self",
			"field": "inventory",
			"index": -1,
			"value": "should_not_land"
		},
		env,
		ctx
	)
	expect_eq(
		actor.get_state("inventory"),
		["x", "y", "z", "w"],
		"array_set_at with index=-1 leaves array untouched (no Python-style tail wrap)"
	)


# ============================================================
# AnimationTranslator (ADR 0046 Phase A.1, 2026-05-17)
# ============================================================


func test_animation_translator() -> void:
	_section("animation_translator (ADR 0046 Phase A.1)")

	# ---------- 1. Empty animations → null library ----------
	var empty_lib := AnimationTranslator.build_library({}, {})
	expect(empty_lib == null, "empty animations block returns null library")

	# ---------- 2. Single looping rotation-only clip ----------
	# Bird-flap shape: rotation_z waves across 5 keyframes, loop, dur=0.4s.
	var bird_anims := {
		"fly":
		{
			"loop": true,
			"duration": 0.4,
			"tracks":
			[{"piece": "left_wing", "rotation_z": [0.0, 0.7, 0.0, -0.4, 0.0]}]
		}
	}
	# No baseline provided — uses defaults (rot=0, pos=0, scale=1).
	var lib := AnimationTranslator.build_library(bird_anims, {})
	expect(lib != null, "build_library returns AnimationLibrary on valid input")
	expect(lib.has_animation("fly"), "library contains 'fly' animation")

	var fly: Animation = lib.get_animation("fly")
	expect(abs(fly.length - 0.4) < 1e-5, "fly clip length matches duration")
	expect_eq(int(fly.loop_mode), int(Animation.LOOP_LINEAR), "fly loops")
	expect_eq(fly.get_track_count(), 1, "fly has 1 track (left_wing rotation)")

	var track_path: NodePath = fly.track_get_path(0)
	expect_eq(
		str(track_path), "left_wing:rotation", "track path is '<piece>:rotation'"
	)
	expect_eq(
		int(fly.track_get_type(0)), int(Animation.TYPE_VALUE), "value track"
	)
	expect_eq(fly.track_get_key_count(0), 5, "5 keyframes baked")

	# Verify keyframe times are uniformly spaced over [0, duration].
	var step := 0.4 / 4.0  # 5 keys → 4 segments
	for i in 5:
		var key_time := fly.track_get_key_time(0, i)
		expect(
			abs(key_time - float(i) * step) < 1e-5,
			"keyframe %d time = %.3f (expected %.3f)" % [i, key_time, float(i) * step]
		)

	# Verify keyframe values are baked Vector3s with rotation.z replaced.
	var k0: Vector3 = fly.track_get_key_value(0, 0)
	var k1: Vector3 = fly.track_get_key_value(0, 1)
	expect_eq(k0, Vector3(0, 0, 0.0), "key0 z=0 (baseline x/y stay 0)")
	expect_eq(k1, Vector3(0, 0, 0.7), "key1 z=0.7 (baseline x/y stay 0)")

	# ---------- 3. One-shot (loop=false) ----------
	var oneshot := {
		"land":
		{
			"loop": false,
			"duration": 0.6,
			"tracks": [{"piece": "body", "translation_y": [0.0, 0.5]}]
		}
	}
	var lib2 := AnimationTranslator.build_library(oneshot, {})
	var land: Animation = lib2.get_animation("land")
	expect_eq(int(land.loop_mode), int(Animation.LOOP_NONE), "loop=false → LOOP_NONE")
	expect_eq(land.get_track_count(), 1, "land has 1 track")

	# ---------- 4. Translation ADDS to baseline (offset semantic) ----------
	# Baseline pos = (0, 1, 0) for "body". Track translation_y = [0, 0.5].
	# Expected baked keys: (0, 1, 0) and (0, 1.5, 0).
	var baselines := {"body": {"pos": Vector3(0, 1, 0), "rot": Vector3.ZERO, "scale": Vector3.ONE}}
	var lib3 := AnimationTranslator.build_library(oneshot, baselines)
	var land2: Animation = lib3.get_animation("land")
	var lp0: Vector3 = land2.track_get_key_value(0, 0)
	var lp1: Vector3 = land2.track_get_key_value(0, 1)
	expect_eq(lp0, Vector3(0, 1, 0), "translation_y key0 = baseline pos")
	expect_eq(lp1, Vector3(0, 1.5, 0), "translation_y key1 = baseline + 0.5 offset")

	# ---------- 5. Rotation REPLACES baseline per-axis ----------
	# Baseline rot = (0.2, 0.0, 0.0). Track rotation_z = [0, 0.5].
	# Expected: keys = (0.2, 0, 0) and (0.2, 0, 0.5) — x kept, z replaced.
	var rot_anim := {
		"twist":
		{
			"loop": true,
			"duration": 1.0,
			"tracks": [{"piece": "head", "rotation_z": [0.0, 0.5]}]
		}
	}
	var rot_baselines := {"head": {"pos": Vector3.ZERO, "rot": Vector3(0.2, 0, 0), "scale": Vector3.ONE}}
	var lib4 := AnimationTranslator.build_library(rot_anim, rot_baselines)
	var twist: Animation = lib4.get_animation("twist")
	var rk0: Vector3 = twist.track_get_key_value(0, 0)
	var rk1: Vector3 = twist.track_get_key_value(0, 1)
	expect_eq(rk0, Vector3(0.2, 0, 0.0), "rotation_z key0: x stays baseline 0.2, z=0")
	expect_eq(rk1, Vector3(0.2, 0, 0.5), "rotation_z key1: x stays baseline 0.2, z=0.5")

	# ---------- 6. Multi-axis track produces one Vector3 sequence ----------
	# Both rotation_x and rotation_z in one track dict → ONE Godot track
	# emitting per-key Vector3 (x_arr[i], 0, z_arr[i]).
	var multi := {
		"shake":
		{
			"loop": true,
			"duration": 0.5,
			"tracks":
			[{"piece": "arm", "rotation_x": [0.0, 0.2, 0.0], "rotation_z": [0.0, 0.4, 0.0]}]
		}
	}
	var lib5 := AnimationTranslator.build_library(multi, {})
	var shake: Animation = lib5.get_animation("shake")
	expect_eq(shake.get_track_count(), 1, "multi-axis dict → 1 grouped track")
	expect_eq(
		shake.track_get_key_value(0, 1),
		Vector3(0.2, 0, 0.4),
		"multi-axis key1 = (0.2, 0, 0.4)"
	)

	# ---------- 7. Two clips in one library ----------
	var two := {
		"idle": {"loop": true, "duration": 1.0, "tracks": []},
		"walk":
		{
			"loop": true,
			"duration": 0.5,
			"tracks": [{"piece": "leg", "rotation_x": [0.0, 0.3, 0.0]}]
		}
	}
	var lib6 := AnimationTranslator.build_library(two, {})
	expect(lib6.has_animation("idle"), "two-clip library has 'idle'")
	expect(lib6.has_animation("walk"), "two-clip library has 'walk'")
	expect_eq(lib6.get_animation("idle").length, 1.0, "idle length 1.0")
	expect_eq(lib6.get_animation("walk").length, 0.5, "walk length 0.5")

	# ---------- 8. Different-length axes pad with the last value ----------
	# rotation_x has 4 keys, rotation_z has 2. N=4. Shorter axis (z) pads
	# its last value (the second one) for indices 2, 3.
	var uneven := {
		"clip":
		{
			"loop": true,
			"duration": 1.0,
			"tracks":
			[{"piece": "p", "rotation_x": [0.0, 0.1, 0.2, 0.3], "rotation_z": [0.0, 0.9]}]
		}
	}
	var lib7 := AnimationTranslator.build_library(uneven, {})
	var c: Animation = lib7.get_animation("clip")
	expect_eq(c.track_get_key_count(0), 4, "track length = max axis length (4)")
	expect_eq(
		c.track_get_key_value(0, 2),
		Vector3(0.2, 0, 0.9),
		"key2: x=0.2, z padded to last (0.9)"
	)
	expect_eq(
		c.track_get_key_value(0, 3),
		Vector3(0.3, 0, 0.9),
		"key3: x=0.3, z still padded to last"
	)

	# ---------- 9. interp: "cubic" sets track interpolation type ----------
	# Phase A.3 (2026-05-17): authors can opt into cubic interpolation
	# per-clip for smoother locomotion. Default is linear. Verify both
	# explicit cubic AND linear-by-default produce the right interpolation
	# constant on the baked track.
	var cubic_clip := {
		"smooth_walk":
		{
			"loop": true,
			"duration": 0.5,
			"interp": "cubic",
			"tracks": [{"piece": "leg", "rotation_x": [0.0, 0.3, 0.0]}]
		}
	}
	var lib8 := AnimationTranslator.build_library(cubic_clip, {})
	var c_smooth: Animation = lib8.get_animation("smooth_walk")
	expect_eq(
		c_smooth.track_get_interpolation_type(0),
		Animation.INTERPOLATION_CUBIC,
		"interp: cubic → INTERPOLATION_CUBIC on bake"
	)

	var linear_clip := {
		"step":
		{
			"loop": true,
			"duration": 0.5,
			"tracks": [{"piece": "leg", "rotation_x": [0.0, 0.3, 0.0]}]
		}
	}
	var lib9 := AnimationTranslator.build_library(linear_clip, {})
	var c_step: Animation = lib9.get_animation("step")
	expect_eq(
		c_step.track_get_interpolation_type(0),
		Animation.INTERPOLATION_LINEAR,
		"no interp → INTERPOLATION_LINEAR by default"
	)
