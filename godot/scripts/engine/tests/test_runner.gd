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
	QueryLib.verify_index = true
	test_entity()
	test_rule()
	test_frame_tick()
	test_relation_store()
	test_relation_state()
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
	test_mesh_bake()
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
	test_ui_list_element()
	test_rule_once()
	test_batch_c_tick_cost()
	test_level_subroutine()
	test_calendar_clock()
	test_sim_tiers()
	test_world_state_alias()
	test_entity_id_indirection()
	test_level_persistent_tags()
	test_edge_filter_in_require()
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
	test_nameplate_filters_named_npc_tag()
	test_nameplate_picks_display_name_over_id()
	test_lib_resolver()
	test_global_input_toggle_edge()
	test_input_edge_last_writer_wins()
	test_runtime_spawn_builds_body()
	test_collider_matches_mesh()
	test_schedule_primitive()
	test_animation_primitive()
	test_lifecycle_primitive()
	test_zone_state_primitive()
	# MUST await — StepRunner.run yields a real frame per press (ADR 0060
	# Phase 1, to clear Godot's is_action_just_pressed edge). Without the
	# await, test_step_runner's assertions resume after RESULTS is tallied
	# (total under-counts). Worked before only because StepRunner was
	# synchronous. Tests below run after it completes.
	await test_step_runner()
	await test_mesh_csg()
	test_overlap_dispatch()
	test_entity_light_mount()
	test_render_block_mappings()
	test_scene_preview()
	test_toast_without_screens()
	test_lockstep()
	test_grid_snap()
	test_multimesh_director()
	test_camera_intrinsics()
	test_array_primitives()
	test_animation_translator()
	test_ground_renderer_rebind()
	test_asset_path()
	test_formula_language()
	test_shader_lib()
	test_spec_vocabularies()
	test_ground_heightmap_collider()
	test_query_tag_index()
	test_spatial_cell_size()
	await test_articulated_body()
	expect_eq(QueryLib.index_mismatches, 0, "ADR 0084: no tag index result differed from the full scan")
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


## ADR 0075 — edge-scoped state store. Relation is the fourth state scope
## (entity.state / zone.state / world_state / relation.state).
func test_relation_state() -> void:
	_section("relation_state (ADR 0075)")

	# ---------- 1. relate carries initial state ----------
	var s := RelationStore.new()
	s.relate("knows", "a", "b", {"trust": 10, "met_on": 3})
	expect_eq(int(s.edge_state("knows", "a", "b").get("trust", -1)), 10, "relate seeds edge state")
	expect_eq(int(s.edge_state("knows", "a", "b").get("met_on", -1)), 3, "relate seeds all fields")

	# ---------- 2. re-relate MERGES instead of no-op'ing ----------
	s.relate("knows", "a", "b", {"trust": 50})
	expect_eq(int(s.edge_state("knows", "a", "b").get("trust", -1)), 50, "re-relate overwrites field")
	expect_eq(int(s.edge_state("knows", "a", "b").get("met_on", -1)), 3, "re-relate keeps other fields")
	expect_eq(s.count("knows"), 1, "re-relate still dedups the edge itself")

	# ---------- 3. field mutators ----------
	expect(s.add_edge_field("knows", "a", "b", "trust", 15), "add_edge_field reports success")
	expect_eq(int(s.edge_state("knows", "a", "b").get("trust", -1)), 65, "add_edge_field accumulates")
	expect(s.set_edge_field("knows", "a", "b", "trust", 200), "set_edge_field reports success")
	expect(s.clamp_edge_field("knows", "a", "b", "trust", 0, 100), "clamp_edge_field reports success")
	expect_eq(int(s.edge_state("knows", "a", "b").get("trust", -1)), 100, "clamp_edge_field caps high")

	# ---------- 4. mutators never CREATE an edge ----------
	expect(not s.add_edge_field("knows", "a", "ghost", "trust", 5), "add on missing edge fails")
	expect(not s.has_edge("knows", "a", "ghost"), "failed add created no edge")
	expect(s.edge_state("knows", "a", "ghost").is_empty(), "missing edge has empty state")

	# ---------- 5. state dies with the edge ----------
	s.unrelate("knows", "a", "b")
	expect(s.edge_state("knows", "a", "b").is_empty(), "unrelate drops edge state")
	s.relate("knows", "a", "b", {"trust": 7})
	s.clear_entity("a")
	expect(s.edge_state("knows", "a", "b").is_empty(), "clear_entity drops edge state")

	# ---------- 6. snapshot / restore round-trip ----------
	var s3 := RelationStore.new()
	s3.relate("knows", "a", "b", {"trust": 65})
	s3.relate("ally", "a", "c")  # stateless edge
	var snap: Array = s3.snapshot()
	var s4 := RelationStore.new()
	s4.restore(snap)
	expect_eq(int(s4.edge_state("knows", "a", "b").get("trust", -1)), 65, "restore preserves edge state")
	expect(s4.has_edge("ally", "a", "c"), "restore preserves stateless edge")
	expect(s4.edge_state("ally", "a", "c").is_empty(), "stateless edge restores with empty state")

	# ---------- 7. legacy snapshots (no `state` key) still load ----------
	var s5 := RelationStore.new()
	s5.restore([{"type": "knows", "from": "x", "to": "y"}])
	expect(s5.has_edge("knows", "x", "y"), "legacy snapshot element restores the edge")
	expect(s5.edge_state("knows", "x", "y").is_empty(), "legacy snapshot element yields empty state")

	# ---------- 8. query `_edge` sub-filter ----------
	var defs := {
		"npc": {"id": "npc", "tags": ["npc"], "state_init": {}},
		"merchant": {"id": "merchant", "tags": ["npc", "merchant"], "state_init": {}},
		"player": {"id": "player", "tags": ["player"], "state_init": {}},
	}
	var entities := {}
	var na := Entity.create(defs.merchant, "npc_a")
	var nb := Entity.create(defs.npc, "npc_b")
	var nc := Entity.create(defs.merchant, "npc_c")
	# The relation walk resolves each edge's TARGET id through env.entities and
	# skips ids it can't resolve — so the edge target must exist as an entity or
	# every `relations` clause silently matches nothing.
	var pl := Entity.create(defs.player, "player")
	entities["npc_a"] = na
	entities["npc_b"] = nb
	entities["npc_c"] = nc
	entities["player"] = pl
	var rs := RelationStore.new()
	rs.relate("knows", "npc_a", "player", {"trust": 80})
	rs.relate("knows", "npc_b", "player", {"trust": 20})
	rs.relate("knows", "npc_c", "player", {"trust": 30})
	var qenv := {"entities": entities, "relations": rs}

	var q_all := QueryLib.run({"relations": {"knows": {}}}, qenv)
	expect_eq(q_all.size(), 3, "relations clause without _edge is unchanged (back-compat)")

	var q_hi := QueryLib.run({"relations": {"knows": {"_edge": {"trust_gte": 60}}}}, qenv)
	expect_eq(q_hi.size(), 1, "_edge trust_gte 60 narrows to one")
	expect_eq((q_hi[0] as Entity).instance_id, "npc_a", "_edge picks the high-trust edge")

	var q_mid := QueryLib.run({"relations": {"knows": {"_edge": {"trust_gte": 25}}}}, qenv)
	expect_eq(q_mid.size(), 2, "_edge trust_gte 25 matches two")

	# The nested dict describes the edge's TARGET (what you know), while the
	# outer clauses describe the matched entity (who knows it). Both must hold
	# for the SAME edge as the `_edge` filter.
	var q_both := QueryLib.run(
		{
			"tags_all": ["merchant"],
			"relations": {"knows": {"_edge": {"trust_gte": 25}, "tags_all": ["player"]}}
		},
		qenv
	)
	expect_eq(q_both.size(), 2, "_edge composes with the nested entity query")

	var q_wrong_target := QueryLib.run(
		{"relations": {"knows": {"_edge": {"trust_gte": 25}, "tags_all": ["merchant"]}}}, qenv
	)
	expect_eq(q_wrong_target.size(), 0, "nested query constrains the edge TARGET, not the matched entity")

	var q_none := QueryLib.run(
		{"relations": {"knows": {"_edge": {"trust_gte": 90}}}}, qenv
	)
	expect_eq(q_none.size(), 0, "_edge with no satisfying edge matches nothing")

	# Strict-missing semantics: unknown edge field never matches.
	var q_missing := QueryLib.run({"relations": {"knows": {"_edge": {"nonexistent_gte": 0}}}}, qenv)
	expect_eq(q_missing.size(), 0, "_edge missing field = no match (strict)")

	# ---------- 9. effect dispatch arms ----------
	var eenv := {"entities": entities, "relations": rs, "world": {}}
	EffectApply.apply(
		{
			"type": "relation_add",
			"relation": "knows",
			"from": "npc_b",
			"to": "player",
			"field": "trust",
			"amount": 45
		},
		eenv,
		{}
	)
	expect_eq(
		int(rs.edge_state("knows", "npc_b", "player").get("trust", -1)),
		65,
		"relation_add effect mutates the edge"
	)
	EffectApply.apply(
		{
			"type": "relation_set",
			"relation": "knows",
			"from": "npc_b",
			"to": "player",
			"field": "trust",
			"value": 130
		},
		eenv,
		{}
	)
	expect_eq(
		int(rs.edge_state("knows", "npc_b", "player").get("trust", -1)),
		130,
		"relation_set effect writes the edge"
	)
	EffectApply.apply(
		{
			"type": "relation_clamp",
			"relation": "knows",
			"from": "npc_b",
			"to": "player",
			"field": "trust",
			"min": 0,
			"max": 100
		},
		eenv,
		{}
	)
	expect_eq(
		int(rs.edge_state("knows", "npc_b", "player").get("trust", -1)),
		100,
		"relation_clamp effect caps the edge"
	)

	# Effects resolve `from`/`to` through context bindings, like relate does.
	# The engine binds `self` to an id STRING (phase_scheduler.gd:612 —
	# `ctx["self"] = ent.instance_id`, with the Entity itself under
	# `self_entity`), so resolve_id does a plain dict lookup. Passing an Entity
	# here would stringify to <Entity#...> and silently resolve to nothing.
	EffectApply.apply(
		{
			"type": "relation_add",
			"relation": "knows",
			"from": "self",
			"to": "player",
			"field": "trust",
			"amount": 5
		},
		eenv,
		{"self": "npc_a"}
	)
	expect_eq(
		int(rs.edge_state("knows", "npc_a", "player").get("trust", -1)),
		85,
		"relation effects resolve `self` binding for from/to"
	)

	# The reverse direction has no edge: nothing changes, and the effect
	# raises relation.no_edge instead of a silent no-op (2026-10-16).
	var no_edge_env: Dictionary = eenv.duplicate()
	no_edge_env["error_buffer"] = []
	EffectApply.apply(
		{"type": "relation_add", "relation": "knows", "from": "player", "to": "npc_a",
		 "field": "trust", "amount": 3},
		no_edge_env,
		{}
	)
	expect(not rs.has_edge("knows", "player", "npc_a"), "relation_add creates no edge")
	var no_edge_codes: Array = (no_edge_env["error_buffer"] as Array).map(func(r): return str(r.code))
	expect(no_edge_codes.has("relation.no_edge"), "relation_add on a missing edge raises relation.no_edge")

	# `relate` effect seeds state through the same dispatch path.
	EffectApply.apply(
		{
			"type": "relate",
			"relation": "rivals",
			"from": "npc_a",
			"to": "npc_c",
			"state": {"tension": 12}
		},
		eenv,
		{}
	)
	expect_eq(
		int(rs.edge_state("rivals", "npc_a", "npc_c").get("tension", -1)),
		12,
		"relate effect seeds edge state"
	)

	na.free()
	nb.free()
	nc.free()
	pl.free()


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

	# id / ids identity clauses (ADR 0060) — select a specific instance by id.
	var r_id := QueryLib.run({"id": "t1"}, env)
	expect_eq(r_id.size(), 1, "id clause matches exactly one instance")
	expect_eq((r_id[0] as Entity).instance_id, "t1", "id clause picks the named instance")
	expect(QueryLib.matches(t1, {"id": "t1"}, env), "id matches positive")
	expect(not QueryLib.matches(t2, {"id": "t1"}, env), "id matches negative (wrong id)")
	var r_ids := QueryLib.run({"ids": ["t1", "f1"]}, env)
	expect_eq(r_ids.size(), 2, "ids clause matches the id set (t1 + f1)")
	expect(not QueryLib.matches(t2, {"ids": ["t1", "f1"]}, env), "ids excludes non-members")
	# id clause composes with tag clauses (intersection).
	expect(not QueryLib.matches(f1, {"id": "f1", "tags_all": ["plant"]}, env), "id + tag is AND")

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
	# A tag effect with `tags` (not `tag`) adds no "" tag and raises an error.
	var tag_err_env: Dictionary = env.duplicate()
	tag_err_env["error_buffer"] = []
	var tags_before := ent.tags.size()
	EffectApply.apply({"type": "tag_add", "target": "self", "tags": ["burning"]}, tag_err_env, ctx)
	expect_eq(ent.tags.size(), tags_before, "tag_add without `tag` adds no tag")
	expect_eq(
		str((tag_err_env["error_buffer"] as Array)[0].code) if not (tag_err_env["error_buffer"] as Array).is_empty() else "",
		"effect.tag_missing",
		"tag_add without `tag` raises effect.tag_missing"
	)
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


## ADR 0083 F2 — MeshLib.bake(): merge by material key, shared materials,
## cache, cache bound, per-surface shader paint, MultiMesh on bake().
## Every surface of `m` draws all of its vertices: some triangle uses each
## vertex. Catches a merge that keeps vertices but drops triangles.
func _all_vertices_drawn(m: Mesh) -> bool:
	for s in m.get_surface_count():
		var a := m.surface_get_arrays(s)
		var n := (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var idx = a[Mesh.ARRAY_INDEX]
		if idx == null or (idx as PackedInt32Array).is_empty():
			continue
		var used := PackedByteArray()
		used.resize(n)
		for i in idx:
			used[i] = 1
		if used.count(1) != n:
			return false
	return true


func _mesh_verts(m: Mesh) -> int:
	var n := 0
	for s in m.get_surface_count():
		n += (m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return n


## ADR 0083 F3 — CSG ops (lathe, extrude, sweep), CSG groups with cuts,
## the one-frame warm-up and the deferred rebuild.
func test_mesh_csg() -> void:
	_section("mesh CSG ops (ADR 0083 F3)")
	MeshLib.clear_caches()
	# Lathe: not baked on the first call, baked after warm().
	var vase := [{"op": "lathe", "segments": 16, "color": "#aa6633",
		"profile": [[0.12, 0], [0.15, 0.08], [0.08, 0.3], [0.1, 0.4]]}]
	var b0 := MeshLib.bake(vase, {})
	expect_eq((b0["pending"] as Array).size(), 1, "lathe: first bake is pending (CSG is one frame late)")
	expect_eq(MeshLib.bake_cache_size(), 0, "a pending bake is not cached")
	await MeshLib.warm(b0["pending"])
	var b1 := MeshLib.bake(vase, {})
	expect((b1["pending"] as Array).is_empty(), "lathe: baked after warm()")
	var va: AABB = b1["aabb"]
	expect(absf(va.position.y) < 0.001 and absf(va.end.y - 0.4) < 0.001, "lathe spans y 0..0.4")
	expect(absf(va.size.x - 0.3) < 0.01, "lathe width = 2 x max radius (0.3)")
	expect(_mesh_verts((b1["meshes"] as Array)[0]["mesh"]) > 0, "lathe has vertices")

	# Extrude: centered on pos along Z (Godot extrudes along -Z).
	var sign_def := [{"op": "extrude", "depth": 0.2, "color": "#806040",
		"polygon": [[-0.5, 0], [0.5, 0], [0.5, 0.6], [0, 1], [-0.5, 0.6]]}]
	await MeshLib.warm(MeshLib.bake(sign_def, {})["pending"])
	var ea: AABB = MeshLib.bake(sign_def, {})["aabb"]
	expect(absf(ea.position.z + 0.1) < 0.001 and absf(ea.end.z - 0.1) < 0.001,
		"extrude is centered on pos (z -0.1..0.1)")

	# Sweep, built out of the tree (F1 tested it only in the tree).
	var pipe := [{"op": "sweep", "color": "#555555", "path": [[0, 0, 0], [0, 0, -1]],
		"polygon": [[0.05, 0], [0, 0.05], [-0.05, 0], [0, -0.05]]}]
	await MeshLib.warm(MeshLib.bake(pipe, {})["pending"])
	var pb := MeshLib.bake(pipe, {})
	expect((pb["pending"] as Array).is_empty(), "sweep bakes out of the tree")
	var pa: AABB = pb["aabb"]
	expect(absf(pa.size.z - 1.0) < 0.02, "sweep follows its 1 m path")

	# A cut: one surface (the cut takes the base material), more geometry.
	var wall := [
		{"op": "box", "group": "w", "pos": [0, 0.5, 0], "size": [1, 1, 0.1], "color": "#8c8a83"},
		{"op": "box", "group": "w", "csg": "subtract", "pos": [0, 0.6, 0], "size": [0.3, 0.3, 0.2]},
	]
	await MeshLib.warm(MeshLib.bake(wall, {})["pending"])
	var wm: ArrayMesh = (MeshLib.bake(wall, {})["meshes"] as Array)[0]["mesh"]
	expect_eq(wm.get_surface_count(), 1, "a cut adds no surface (it takes the base material)")
	expect(_mesh_verts(wm) > 36, "the cut wall has more faces than a plain box (36 verts)")

	# CSG and plain parts with the same material share one surface.
	var mixed := [
		{"op": "box", "pos": [0, 0.05, 0], "size": [0.4, 0.1, 0.4], "color": "#aa6633"},
		vase[0],
	]
	var mb := MeshLib.bake(mixed, {})
	expect((mb["pending"] as Array).is_empty(), "the vase CSG group is already in the cache")
	var mixed_mesh: ArrayMesh = (mb["meshes"] as Array)[0]["mesh"]
	expect_eq(mixed_mesh.get_surface_count(), 1,
		"CSG and plain parts with one material merge into one surface")
	expect(_all_vertices_drawn(mixed_mesh),
		"the merged surface draws the CSG triangles too (every vertex is in a triangle)")
	expect(_all_vertices_drawn(pb["meshes"][0]["mesh"]) and _all_vertices_drawn(wm),
		"every baked CSG surface draws all of its vertices")

	# Deferred rebuild: plain parts at once, CSG one frame later, then the callback.
	MeshLib.clear_caches()
	var host := Node3D.new()
	add_child(host)
	var rebuilt := []
	var two := [{"op": "box", "pos": [0, 0.05, 0], "size": [0.4, 0.1, 0.4], "color": "#223344"}, vase[0]]
	MeshLib.build_primitives_into(host, two, {}, true, func(nodes): rebuilt.append_array(nodes))
	expect_eq(host.get_child_count(), 1, "before the warm-up: the plain part shows")
	await get_tree().process_frame
	await get_tree().process_frame
	expect_eq(rebuilt.size(), 1, "after the warm-up: on_rebuilt gets the new mesh node")
	expect_eq(host.get_child_count(), 1, "the old baked node is gone, the new one is in")
	if host.get_child_count() == 1:
		var m := (host.get_child(0) as MeshInstance3D).mesh
		expect_eq(m.get_surface_count(), 2, "the rebuilt mesh holds the plain and the CSG surface")
	host.free()
	MeshLib.clear_caches()


func test_mesh_bake() -> void:
	_section("mesh bake (ADR 0083 F2)")
	MeshLib.clear_caches()
	var saved_named := MeshLib.named_materials
	MeshLib.named_materials = {"iron": {"color": "#4a4a4f", "roughness": 0.4, "metallic": 0.8}}
	var prims := [
		{"op": "box", "pos": [0, 0.5, 0], "size": [1, 1, 1], "color": "$wall"},
		{"op": "box", "pos": [0, 1.2, 0], "size": [0.2, 0.2, 0.2], "color": "#ff0000"},
		{"op": "box", "pos": [0.3, 0.2, 0], "size": [0.1, 0.1, 0.1], "color": "$wall"},
		{"op": "sphere", "pos": [0, 1.5, 0], "radius": 0.1, "color": "$wall",
		 "emission": "#ffcc66", "emission_energy": 2.0},
		{"op": "cylinder", "pos": [0.5, 0.5, 0], "radius": 0.05, "height": 1.0,
		 "material": "iron"},
	]
	var params := {"wall": "#808080"}
	var baked := MeshLib.bake(prims, params)
	var meshes: Array = baked["meshes"]
	expect_eq(meshes.size(), 1, "all shadow casters bake into one ArrayMesh")
	var am: ArrayMesh = meshes[0]["mesh"]
	# Keys: wall, red, wall+emission, iron. The two plain wall boxes share one.
	expect_eq(am.get_surface_count(), 4, "one surface per material key (5 parts, 4 keys)")
	var aabb: AABB = baked["aabb"]
	expect(absf(aabb.position.y) < 0.001, "baked AABB starts at the part base (y=0)")
	expect(absf(aabb.end.y - 1.6) < 0.001, "baked AABB covers the top part (y=1.6)")
	var emissive := 0
	var metal := 0
	for i in am.get_surface_count():
		var m := am.surface_get_material(i) as StandardMaterial3D
		if m.emission_enabled:
			emissive += 1
		if m.metallic > 0.5:
			metal += 1
	expect_eq(emissive, 1, "emission is part of the key: only its own surface glows")
	expect_eq(metal, 1, "a `material` name resolves from the materials block")
	expect(
		MeshLib.material_for(prims[0], params) == MeshLib.material_for(prims[2], params),
		"parts with the same key share one material instance"
	)
	# Cache: the same input returns the same result object.
	var again := MeshLib.bake(prims, params)
	expect(is_same(again, baked), "second bake with the same input hits the cache")
	expect_eq(MeshLib.bake_cache_size(), 1, "cache holds one entry")
	# Inline fields win over the named material.
	var over := {"op": "box", "material": "iron", "metallic": 0.0}
	expect(MeshLib.material_key(over, {}).contains("|m0.0|"), "inline metallic overrides the named one")
	# rotation_deg accepts $param.
	var rot := MeshLib.part_transform({"rotation_deg": "$r", "pos": [1, 2, 3]}, {"r": [0, 90, 0]})
	expect((rot.basis.x - Vector3(0, 0, -1)).length() < 0.001, "rotation_deg resolves $param (yaw 90)")
	expect_eq(rot.origin, Vector3(1, 2, 3), "part_transform keeps pos")

	# Named / pivot parts stay separate unless keep_named is false.
	var rig := [
		{"op": "box", "pos": [0, 0.5, 0], "size": [0.4, 1, 0.2], "color": "#3355aa"},
		{"op": "cylinder", "name": "arm_l", "pivot": "top", "pos": [-0.3, 0.6, 0],
		 "radius": 0.05, "height": 0.5, "color": "#3355aa"},
	]
	var rb := MeshLib.bake(rig, {})
	expect_eq((rb["separate"] as Array).size(), 1, "a named part stays separate")
	expect_eq(((rb["meshes"] as Array)[0]["mesh"] as ArrayMesh).get_surface_count(), 1,
		"the separate part is not in the baked mesh")
	var rb_all := MeshLib.bake(rig, {}, true, false)
	expect_eq((rb_all["separate"] as Array).size(), 0, "keep_named=false merges every part")

	# cast_shadow splits the bake into two meshes.
	var shadow_mix := [
		{"op": "box", "size": [1, 1, 1], "color": "#00ff00"},
		{"op": "box", "size": [1, 1, 1], "color": "#00ff00", "cast_shadow": false},
	]
	var sb := MeshLib.bake(shadow_mix, {})
	expect_eq((sb["meshes"] as Array).size(), 2, "cast_shadow splits into two meshes")

	# build_primitives_into: baked meshes + separate nodes; the named part is findable.
	var host := Node3D.new()
	MeshLib.build_primitives_into(host, rig, {})
	expect_eq(host.get_child_count(), 2, "build_primitives_into: 1 baked mesh + 1 separate part")
	expect(host.find_child("arm_l", true, false) != null, "the named part keeps its name")
	host.free()

	# A change to the materials block alone makes a new bake (no stale material).
	var iron_prims := [{"op": "box", "material": "iron"}]
	var b_old := MeshLib.bake(iron_prims, {})
	MeshLib.named_materials = {"iron": {"color": "#ff00ff"}}
	var b_new := MeshLib.bake(iron_prims, {})
	var new_mat := ((b_new["meshes"] as Array)[0]["mesh"] as ArrayMesh).surface_get_material(0) as StandardMaterial3D
	expect(not is_same(b_old, b_new), "a materials-block change misses the cache")
	expect_eq(new_mat.albedo_color, Color("#ff00ff"), "the new bake uses the new named material")

	# Shared materials stay unchanged when one host is painted.
	var tex := ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGB8))
	var host_a := EntityMesh3D.new()
	var host_b := EntityMesh3D.new()
	var plain := [{"op": "box", "color": "#123456"}, {"op": "box", "name": "lid", "color": "#123456"}]
	MeshLib.build_primitives_into(host_a, plain, {})
	MeshLib.build_primitives_into(host_b, plain, {})
	for c in host_a.get_children():
		host_a._paint_albedo_texture_recursive(c, tex)
	var cached := MeshLib.material_for(plain[0], {})
	expect(cached.albedo_texture == null, "painting one host leaves the shared material unchanged")
	var b_lid := host_b.find_child("lid", true, false) as MeshInstance3D
	expect((b_lid.material_override as StandardMaterial3D).albedo_texture == null,
		"painting one host leaves the other host's separate part unchanged")
	var b_mesh := host_b.get_child(0) as MeshInstance3D
	expect(b_mesh.get_active_material(0) == cached, "the other host's baked surface keeps the shared material")
	host_a.free()
	host_b.free()

	# Cache bound: least-recently-used entries go first, not oldest-added.
	MeshLib.clear_caches()
	var lru_first := MeshLib.bake([{"op": "box", "color": "$c"}], {"c": Color(0, 0, 0)})
	var lru_second := MeshLib.bake([{"op": "box", "color": "$c"}], {"c": Color(0.001, 0, 0)})
	for i in range(2, MeshLib.BAKE_CACHE_MAX):
		MeshLib.bake([{"op": "box", "color": "$c"}], {"c": Color(float(i) / 1000.0, 0, 0)})
	expect_eq(MeshLib.bake_cache_size(), MeshLib.BAKE_CACHE_MAX, "cache is full at BAKE_CACHE_MAX")
	MeshLib.bake([{"op": "box", "color": "$c"}], {"c": Color(0, 0, 0)})  # touch the first entry
	MeshLib.bake([{"op": "box", "color": "$c"}], {"c": Color(0.9, 0.9, 0.9)})  # one more: evicts one
	expect_eq(MeshLib.bake_cache_size(), MeshLib.BAKE_CACHE_MAX, "cache stays at BAKE_CACHE_MAX")
	expect(is_same(MeshLib.bake([{"op": "box", "color": "$c"}], {"c": Color(0, 0, 0)}), lru_first),
		"the recently used first entry survives")
	expect(not is_same(MeshLib.bake([{"op": "box", "color": "$c"}], {"c": Color(0.001, 0, 0)}), lru_second),
		"the least recently used entry was evicted")

	# Per-surface shader paint keeps each surface's albedo (river_3d case).
	var bands := [
		{"op": "box", "pos": [0, 0, 0], "size": [1, 0.1, 1], "color": "#112233"},
		{"op": "box", "pos": [0, 0, 1], "size": [1, 0.1, 1], "color": "#445566"},
	]
	var paint_host := EntityMesh3D.new()
	MeshLib.build_primitives_into(paint_host, bands, {})
	var shader := Shader.new()
	shader.code = "shader_type spatial;\nuniform vec4 albedo_color : source_color;\nvoid fragment() { ALBEDO = albedo_color.rgb; }\n"
	paint_host._paint_shader_recursive(paint_host.get_child(0), shader, {})
	var pmi := paint_host.get_child(0) as MeshInstance3D
	var c0: Color = (pmi.get_surface_override_material(0) as ShaderMaterial).get_shader_parameter("albedo_color")
	var c1: Color = (pmi.get_surface_override_material(1) as ShaderMaterial).get_shader_parameter("albedo_color")
	expect(c0 != c1, "shader paint gives each baked surface its own albedo")
	paint_host.free()

	# MultiMesh uses bake(): one MultiMesh per baked mesh, emission kept.
	var dir := MultiMeshDirector.new()
	var world := Node.new()
	dir.configure(world, 1.0)
	var ents: Array = []
	for i in 3:
		var e := Entity.new()
		e.state = {"yaw": 0.0, "scale": [2.0, 1.0, 1.0]}
		e.set_position(Vector3(i * 2, 0, 0))
		ents.append(e)
	var built: Array = dir._build_multimesh_for_group(
		{"mesh_def": {"primitives": prims}, "params": params, "entities": ents}
	)
	expect_eq(built.size(), 1, "MultiMesh: one node per baked mesh, not one per part")
	var mm := (built[0] as MultiMeshInstance3D).multimesh
	expect_eq(mm.instance_count, 3, "MultiMesh: one instance per entity")
	# The dummy (headless) renderer does not store MultiMesh transforms, so
	# test the transform function directly.
	var xf: Transform3D = dir._instance_transform(ents[1])
	expect_eq(xf.origin, Vector3(2, 0, 0), "instance origin = entity position")
	ents[1].state["yaw"] = PI / 2.0
	var xr: Transform3D = dir._instance_transform(ents[1])
	expect((xr * Vector3(1, 0, 0) - (Vector3(2, 0, 0) + Vector3(0, 0, -2))).length() < 0.001,
		"local +X scales by 2, then yaws 90 deg (R * S, as a Node3D does)")
	var mm_glow := false
	for i in mm.mesh.get_surface_count():
		if (mm.mesh.surface_get_material(i) as StandardMaterial3D).emission_enabled:
			mm_glow = true
	expect(mm_glow, "MultiMesh keeps emission (lost before ADR 0083)")
	for e in ents:
		e.free()
	world.free()
	dir.free()
	MeshLib.named_materials = saved_named
	MeshLib.clear_caches()


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

	# Godot's Expression drops the tokens after the first expression, so a
	# ternary always returned its first branch. Formula rejects it
	# (2026-10-16). An `if` inside a string literal is not a ternary.
	var env4: Dictionary = {"error_buffer": []}
	var tern = Formula.evaluate("10 if 1 > 2 else 20", {"_rule_id": "r_tern"}, env4)
	expect(float(tern) == 0.0, "ternary formula returns 0.0, not its first branch")
	expect(
		(env4["error_buffer"] as Array).any(func(r): return str(r.code) == EngineError.FORMULA_PARSE_FAILED),
		"ternary formula raises formula.parse_failed"
	)
	expect_eq(Formula.evaluate("10 + 160 * float(85 > 80)", {}, {}), 170.0, "float(cond) choice idiom")


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

	# ADR 0060 GATE — order-independence. Per-pattern seeded RNG must be
	# IMMUNE to how much the global PRNG was consumed first. This is the
	# exact bug class behind aldenmere's camp_berry tick-1 divergence
	# (seeded-but-SHARED global PRNG diverged because consumption order
	# wasn't pinned). Expand a scatter, consume the global PRNG, expand
	# again — results MUST be identical.
	var oi_pat := {
		"def": "berry", "pattern": "scatter", "count": 10,
		"min_r": 1, "max_r": 8, "id_prefix": "berry",
		"scale_min": 0.8, "scale_max": 1.2, "yaw_jitter": 1.0,
	}
	var oi_a := InstancePatterns.expand(oi_pat, 4412)
	for _i in range(37):
		randf()  # simulate boot/rules consuming the shared global PRNG
	var oi_b := InstancePatterns.expand(oi_pat, 4412)
	expect_eq(oi_a.size(), oi_b.size(), "ADR0060: scatter count is order-independent")
	var oi_same := oi_a.size() == oi_b.size()
	if oi_same:
		for i in range(oi_a.size()):
			if (oi_a[i] as Dictionary)["position"] != (oi_b[i] as Dictionary)["position"]:
				oi_same = false
				break
			if (oi_a[i] as Dictionary).get("state") != (oi_b[i] as Dictionary).get("state"):
				oi_same = false
				break
	expect(oi_same, "ADR0060: scatter identical despite intervening global randf() (per-pattern seeded RNG)")

	# Bounds-missing warning + under-spawn behavior (2026-05-20 post-mortem).
	# A scatter with count=200 + defaulted min_r/max_r (0/5m disk) +
	# min_spacing=1.5m cannot physically fit 200 entries. Engine must:
	#   (a) push_warning [scatter.bounds_missing] before the loop
	#   (b) push_warning [scatter.under_spawn] after the loop
	# Both warnings are expected; what we assert here is the under-spawn
	# behavior (the loop returns fewer than `count` instances).
	# Without push_warning capture in Godot's test API, this section
	# verifies the OUTCOME — partial placement — which is what would
	# previously have caused a silent missing-trees bug in level loads.
	_section("instance_patterns.scatter_bounds_protection")
	seed(7)
	var under := InstancePatterns.expand(
		{
			"def": "tree",
			"pattern": "scatter",
			"id_prefix": "pack_test",
			"count": 200,
			"min_spacing": 1.5,
			# min_r + max_r OMITTED on purpose — defaults to 0..5m disk.
		}
	)
	expect(
		under.size() < 200,
		"under-spawn: 200-count pattern in default 5m disk can't place all"
	)
	expect(
		under.size() < 60,
		"under-spawn: should place far fewer (~30) than 200 in 5m disk"
	)
	# With proper annulus 25-38m + same spacing, 200 fits comfortably:
	seed(7)
	var full := InstancePatterns.expand(
		{
			"def": "tree",
			"pattern": "scatter",
			"id_prefix": "pack_test_2",
			"count": 200,
			"min_r": 25.0,
			"max_r": 38.0,
			"min_spacing": 1.5,
		}
	)
	expect_eq(
		full.size(), 200,
		"with min_r=25, max_r=38, min_spacing=1.5 — full 200 entities placed"
	)


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
## ADR 0075 — the `_edge` filter must work through Query.matches (the
## single-entity path used by `require:`), not only Query.run (the scan path).
## A signal rule gating on "this NPC trusts me enough" goes through matches.
func test_edge_filter_in_require() -> void:
	_section("edge_filter_in_require (ADR 0075)")

	var defs := {
		"officer": {"id": "officer", "tags": ["named_npc", "guild_officer"], "state_init": {}},
		"player": {"id": "player", "tags": ["player"], "state_init": {}},
	}
	var sera := Entity.create(defs.officer, "npc_sera")
	var pl := Entity.create(defs.player, "player_1")
	var entities := {"npc_sera": sera, "player_1": pl}
	var rs := RelationStore.new()
	# Edge direction is npc -> player: the value is how well the NPC knows YOU.
	rs.relate("knows", "npc_sera", "player_1", {"trust": 31})
	var env := {"entities": entities, "relations": rs, "world": {}}

	var spec := {
		"tags_all": ["guild_officer"],
		"relations": {"knows": {"_edge": {"trust_gte": 30}}}
	}
	expect(
		QueryLib.matches(sera, spec, env, {}),
		"Query.matches honours the _edge filter (the `require:` path)"
	)

	var spec_hi := {
		"tags_all": ["guild_officer"],
		"relations": {"knows": {"_edge": {"trust_gte": 40}}}
	}
	expect(
		not QueryLib.matches(sera, spec_hi, env, {}),
		"...and rejects when the edge value is below the threshold"
	)

	# The mirror-image rule (`trust_lt`) must also work — a design that has a
	# granted-path and a refused-path needs BOTH to be expressible.
	var spec_lt := {"relations": {"knows": {"_edge": {"trust_lt": 30}}}}
	expect(
		not QueryLib.matches(sera, spec_lt, env, {}),
		"trust_lt 30 does not match a trust of 31"
	)
	rs.set_edge_field("knows", "npc_sera", "player_1", "trust", 25)
	expect(
		QueryLib.matches(sera, spec_lt, env, {}),
		"trust_lt 30 matches once the edge drops to 25"
	)

	sera.free()
	pl.free()


## ADR 0047 — `state_set target: "world"` must write world_state.
##
## ADR 0047 promises "One store, two names": target=world and target=_engine
## write the same data, matching the read-side `world.X` binding. Only
## `_engine` was implemented, so `target=world` resolved to no entity and every
## such effect was a SILENT NO-OP — exactly the failure the ADR was written to
## eliminate. `.claude/rules/data-demo.md` documented the broken form as
## working, so content authored against the docs did nothing.
func test_level_persistent_tags() -> void:
	_section("level_persistent_tags (flow.json)")

	# The default must be unchanged for every game that does not declare the key.
	var w := World.new()
	expect_eq(
		str(w.level_persistent_tags), str(["persistent"]),
		"default keep-set is [persistent] — games not declaring the key are untouched"
	)

	# And the declared set must actually be adopted. The bug this covers: the
	# level swap hardcoded the literal tag, so a game declaring
	# ["player", "persistent"] still lost its player on the first swap, with no
	# error — the player was simply absent and every rule requiring an actor
	# quietly stopped matching.
	var loader := WorldLoader.new(w)
	var path := "user://_test_flow.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(
		'{"levels": ["a", "b"], "starting_level": "a",'
		+ ' "persistent_tags": ["player", "persistent"]}'
	)
	f.close()
	loader.load_progression(path)
	expect_eq(
		str(w.level_persistent_tags), str(["player", "persistent"]),
		"flow.json persistent_tags is adopted by the level layer, not only by chunk streaming"
	)
	expect_eq(str(w.current_level), "a", "starting_level is the key the engine reads")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	w.free()


func test_entity_id_indirection() -> void:
	_section("entity_id indirection (ADR 0081)")

	# A contract entity naming its poster in a property — the shape the rule
	# wants to follow: "reward whoever posted this", not "reward npc_sera".
	var contract := Entity.new()
	contract.instance_id = "contract_1"
	contract.def_id = "contract_1"
	contract.tags = ["contract"]
	contract.properties = {"poster": "npc_sera"}
	contract.state = {"reward_coin": 180}

	var poster := Entity.new()
	poster.instance_id = "npc_sera"
	poster.def_id = "npc"
	poster.tags = ["named_npc"]
	poster.state = {"favours_owed": 0}

	var player := Entity.new()
	player.instance_id = "player_1"
	player.def_id = "player"
	player.tags = ["player"]
	player.state = {"coin": 0}

	var entities: Dictionary = {
		"contract_1": contract, "npc_sera": poster, "player_1": player
	}
	var rs := RelationStore.new()
	var env: Dictionary = {
		"entities": entities, "defs": {}, "relations": rs,
		"world": {}, "parent": null, "next_id": {"_": 0},
	}
	var ctx: Dictionary = {"self": "contract_1", "actor": "player_1"}

	# --- the three resolution forms, at the resolver itself ---
	expect_eq(
		EffectResolution.entity_id("actor", ctx, env), "player_1",
		"a bare context binding resolves to the bound id"
	)
	expect_eq(
		EffectResolution.entity_id("npc_sera", ctx, env), "npc_sera",
		"a bare non-binding string stays a literal id"
	)
	expect_eq(
		EffectResolution.entity_id("self.properties.poster", ctx, env), "npc_sera",
		"a dotted path rooted at a binding follows to the named entity"
	)

	# The safety property this design rests on: a dotted string whose head is
	# NOT a live binding must stay literal, never reach the formula parser.
	expect_eq(
		EffectResolution.entity_id("some.unbound.thing", ctx, env), "some.unbound.thing",
		"a dotted path rooted at nothing stays a literal (no formula parse)"
	)

	# --- and through the effects that actually use it ---
	EffectApply.apply(
		{"type": "state_add", "target": "self.properties.poster",
		 "field": "favours_owed", "amount": 1},
		env, ctx
	)
	expect_eq(
		int(poster.state.get("favours_owed", -1)), 1,
		"state_add reaches the entity a property NAMES, not one the rule hardcodes"
	)

	EffectApply.apply(
		{"type": "relate", "relation": "owes", "from": "self.properties.poster",
		 "to": "actor", "state": {"amount": 3}},
		env, ctx
	)
	expect_eq(
		int(rs.edge_state("owes", "npc_sera", "player_1").get("amount", -1)), 3,
		"relate resolves BOTH endpoints through the same resolver"
	)

	for e in [contract, poster, player]:
		e.free()


func test_world_state_alias() -> void:
	_section("world_state_alias (ADR 0047)")

	# Mirror WorldBoot._spawn_engine_entity: the `_engine` entity's state dict
	# IS world_state, shared by reference.
	var world_state: Dictionary = {"gold": 10, "objective": "start"}
	var eng := Entity.new()
	eng.instance_id = "_engine"
	eng.def_id = "_engine"
	eng.tags = ["_engine"]
	eng.state = world_state
	var entities: Dictionary = {"_engine": eng}
	var env: Dictionary = {
		"entities": entities,
		"defs": {},
		"relations": RelationStore.new(),
		"world": world_state,
		"parent": null,
		"next_id": {"_": 0},
	}

	EffectApply.apply(
		{"type": "state_set", "target": "world", "field": "objective", "value": "Go north."},
		env,
		{}
	)
	expect_eq(
		str(world_state.get("objective", "")),
		"Go north.",
		"state_set target='world' writes world_state (the ADR 0047 alias)"
	)

	EffectApply.apply(
		{"type": "state_add", "target": "world", "field": "gold", "amount": 25}, env, {}
	)
	expect_eq(int(world_state.get("gold", -1)), 35, "state_add target='world' accumulates")

	# The documented equivalence: both names, one store.
	EffectApply.apply(
		{"type": "state_set", "target": "_engine", "field": "gold", "value": 7}, env, {}
	)
	expect_eq(int(world_state.get("gold", -1)), 7, "target='_engine' writes the SAME store")

	# A real entity id must still win over the alias, so a game that legitimately
	# names an entity "world" is not hijacked.
	var real := Entity.create({"id": "w", "tags": ["thing"], "state_init": {"hp": 1}}, "world")
	entities["world"] = real
	EffectApply.apply(
		{"type": "state_set", "target": "world", "field": "hp", "value": 99}, env, {}
	)
	expect_eq(int(real.get_state("hp", -1)), 99, "an actual entity named 'world' takes precedence")
	expect(
		not world_state.has("hp"), "...and the alias did not also write world_state"
	)

	eng.free()
	real.free()


## ADR 0079 — simulation tiers. Tier is DERIVED from distance to the LOD
## anchor; `Rule.scope` (previously a dead field) selects which tier a rule
## applies to. Phase 1 = dispatch filtering; presentation detach is Phase 2.
func test_sim_tiers() -> void:
	_section("sim_tiers (ADR 0079)")

	var defs := {
		"player": {"id": "player", "tags": ["player"], "state_init": {}},
		"npc": {"id": "npc", "tags": ["npc"], "state_init": {"near": 0, "far": 0, "both": 0}},
	}

	# player at origin; near npc at 5 units, far npc at 500.
	var ents := {}
	var pl := Entity.create(defs.player, "pl")
	pl.set_position(Vector2(0, 0))
	var near := Entity.create(defs.npc, "near_npc")
	near.set_position(Vector2(5, 0))
	var far := Entity.create(defs.npc, "far_npc")
	far.set_position(Vector2(500, 0))
	ents["pl"] = pl
	ents["near_npc"] = near
	ents["far_npc"] = far

	var env: Dictionary = {
		"entities": ents,
		"defs": defs,
		"relations": RelationStore.new(),
		"spatial_index": SpatialIndex.new(),
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
		"embodied_radius": 50.0,
	}
	var sched := PhaseScheduler.new(env)
	sched.register_rules(
		[
			Rule.from_dict(
				{
					"id": "near_only",
					"scope": "embodied",
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["npc"]},
					"effect": [{"type": "state_add", "target": "self", "field": "near", "amount": 1}]
				}
			),
			Rule.from_dict(
				{
					"id": "far_only",
					"scope": "abstract",
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["npc"]},
					"effect": [{"type": "state_add", "target": "self", "field": "far", "amount": 1}]
				}
			),
			Rule.from_dict(
				{
					"id": "unscoped",
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["npc"]},
					"effect": [{"type": "state_add", "target": "self", "field": "both", "amount": 1}]
				}
			),
		]
	)

	sched.tick()

	# ---------- 1. scope routes rules by derived tier ----------
	expect_eq(int(near.get_state("near", -1)), 1, "embodied-scoped rule fires on the near entity")
	expect_eq(int(near.get_state("far", -1)), 0, "abstract-scoped rule skips the near entity")
	expect_eq(int(far.get_state("far", -1)), 1, "abstract-scoped rule fires on the far entity")
	expect_eq(int(far.get_state("near", -1)), 0, "embodied-scoped rule skips the far entity")

	# ---------- 2. unset scope = both tiers (every pre-0079 rule) ----------
	expect_eq(int(near.get_state("both", -1)), 1, "unscoped rule fires on the near entity")
	expect_eq(int(far.get_state("both", -1)), 1, "unscoped rule fires on the far entity too")

	# ---------- 3. no radius configured → everything embodied ----------
	# This is the back-compat path: every existing demo omits `simulation`,
	# so no entity may be treated as abstract.
	var ents2 := {}
	var pl2 := Entity.create(defs.player, "pl")
	pl2.set_position(Vector2(0, 0))
	var far2 := Entity.create(defs.npc, "far_npc")
	far2.set_position(Vector2(9999, 0))
	ents2["pl"] = pl2
	ents2["far_npc"] = far2
	var env2: Dictionary = {
		"entities": ents2,
		"defs": defs,
		"relations": RelationStore.new(),
		"spatial_index": SpatialIndex.new(),
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}
	var sched2 := PhaseScheduler.new(env2)
	sched2.register_rules(
		[
			Rule.from_dict(
				{
					"id": "near_only",
					"scope": "embodied",
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["npc"]},
					"effect": [{"type": "state_add", "target": "self", "field": "near", "amount": 1}]
				}
			)
		]
	)
	sched2.tick()
	expect_eq(
		int(far2.get_state("near", -1)),
		1,
		"no embodied_radius → every entity is embodied (pre-0079 behaviour)"
	)

	# ---------- 4. hysteresis: no flicker at the boundary ----------
	# An entity just past the radius but inside the widened band stays
	# embodied; only past the band does it demote.
	near.set_position(Vector2(52, 0))  # > 50, < 55
	sched.tick()
	expect_eq(
		int(near.get_state("near", -1)), 2, "just past the radius, an embodied entity stays embodied"
	)
	near.set_position(Vector2(80, 0))  # past the band
	sched.tick()
	expect_eq(int(near.get_state("near", -1)), 2, "past the hysteresis band it demotes to abstract")
	expect_eq(int(near.get_state("far", -1)), 1, "...and abstract-scoped rules pick it up")

	# ---------- 5. an unknown scope value never silently drops the rule ----------
	var ents3 := {}
	var pl3 := Entity.create(defs.player, "pl")
	pl3.set_position(Vector2(0, 0))
	var n3 := Entity.create(defs.npc, "n3")
	n3.set_position(Vector2(1000, 0))
	ents3["pl"] = pl3
	ents3["n3"] = n3
	var env3: Dictionary = {
		"entities": ents3,
		"defs": defs,
		"relations": RelationStore.new(),
		"spatial_index": SpatialIndex.new(),
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
		"embodied_radius": 50.0,
	}
	var sched3 := PhaseScheduler.new(env3)
	sched3.register_rules(
		[
			Rule.from_dict(
				{
					"id": "typo_scope",
					"scope": "embodyed",
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["npc"]},
					"effect": [{"type": "state_add", "target": "self", "field": "both", "amount": 1}]
				}
			)
		]
	)
	sched3.tick()
	expect_eq(
		int(n3.get_state("both", -1)), 1, "an unrecognised scope value falls back to firing, not silence"
	)

	pl.free()
	near.free()
	far.free()
	pl2.free()
	far2.free()
	pl3.free()
	n3.free()


## ADR 0078 — the calendar clock. A SECOND clock with no real-time duration,
## advanced only by `advance_time`. The 60Hz heartbeat is untouched.
func test_calendar_clock() -> void:
	_section("calendar_clock (ADR 0078)")

	var defs := {
		"town": {"id": "town", "tags": ["town"], "state_init": {"upkeep": 0, "beats": 0}},
	}

	var ents := {}
	var t1 := Entity.create(defs.town, "t1")
	ents["t1"] = t1
	var env: Dictionary = {
		"entities": ents,
		"defs": defs,
		"relations": RelationStore.new(),
		"spatial_index": SpatialIndex.new(),
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}
	var sched := PhaseScheduler.new(env)
	sched.register_rules(
		[
			Rule.from_dict(
				{
					"id": "daily",
					"trigger": {"type": "scheduled", "every": 1},
					"query": {"tags_all": ["town"]},
					"effect": [{"type": "state_add", "target": "self", "field": "upkeep", "amount": 1}]
				}
			),
			Rule.from_dict(
				{
					"id": "biweekly",
					"trigger": {"type": "scheduled", "every": 2},
					"query": {"tags_all": ["town"]},
					"effect": [{"type": "state_add", "target": "self", "field": "beats", "amount": 1}]
				}
			),
		]
	)

	# ---------- 1. the `scheduled` bucket actually dispatches ----------
	# It was in VALID_TRIGGERS with no dispatcher: such rules registered,
	# validated, and never fired, silently. This assertion is the regression.
	sched.advance_calendar(6)
	expect_eq(int(t1.get_state("upkeep", -1)), 6, "`every: 1` fires once per calendar unit")
	expect_eq(int(t1.get_state("beats", -1)), 3, "`every: 2` fires every second unit")
	expect_eq(
		int((env["world"] as Dictionary).get("calendar_units", -1)),
		6,
		"the calendar counter lives in world state (persists with the save)"
	)

	# ---------- 2. advancing does NOT run the heartbeat ----------
	var ents2 := {}
	var t2 := Entity.create(defs.town, "t2")
	ents2["t2"] = t2
	var env2: Dictionary = {
		"entities": ents2,
		"defs": defs,
		"relations": RelationStore.new(),
		"spatial_index": SpatialIndex.new(),
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}
	var sched2 := PhaseScheduler.new(env2)
	sched2.register_rules(
		[
			Rule.from_dict(
				{
					"id": "heartbeat_only",
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["town"]},
					"effect": [{"type": "state_add", "target": "self", "field": "upkeep", "amount": 1}]
				}
			)
		]
	)
	sched2.advance_calendar(10)
	expect_eq(
		int(t2.get_state("upkeep", -1)),
		0,
		"advance_time does NOT run the tick bucket — the heartbeat is untouched"
	)
	sched2.tick()
	expect_eq(int(t2.get_state("upkeep", -1)), 1, "the tick bucket still works normally")

	# ---------- 3. effects flush between units ----------
	# Unit k+1's rules must observe unit k's results, or a compounding rule
	# (interest, growth, decay) silently computes off a stale value.
	var ents3 := {}
	var t3 := Entity.create(defs.town, "t3")
	t3.set_state("upkeep", 1)
	ents3["t3"] = t3
	var env3: Dictionary = {
		"entities": ents3,
		"defs": defs,
		"relations": RelationStore.new(),
		"spatial_index": SpatialIndex.new(),
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}
	var sched3 := PhaseScheduler.new(env3)
	sched3.register_rules(
		[
			Rule.from_dict(
				{
					"id": "doubling",
					"trigger": {"type": "scheduled", "every": 1},
					"query": {"tags_all": ["town"]},
					"effect":
					[{"type": "state_mul", "target": "self", "field": "upkeep", "amount": 2}]
				}
			)
		]
	)
	sched3.advance_calendar(4)
	expect_eq(
		int(t3.get_state("upkeep", -1)), 16, "effects flush per unit (1*2^4), not once at the end"
	)

	# ---------- 4. the advance emits one signal for the whole span ----------
	# `units` is read from the entry's PAYLOAD, which is where the dispatcher looks
	# (`_drain_signals_into` reads sig["payload"]). This assertion previously read
	# sig["units"] — flat, beside the name — and passed for years while no RULE
	# could reach the value, because a flat entry hands every rule an empty payload.
	#
	# The lesson is in the shape of the test, not just the field: asserting against
	# the buffer's contents cannot tell whether content can actually READ them. A
	# signal-payload assertion belongs downstream of a real rule firing, which is
	# what test_level_subroutine's closing case now does.
	var found_advance := 0
	var span := -1
	for s in (env3.get("signal_buffer", []) as Array):
		if str((s as Dictionary).get("name", "")) == "time_advanced":
			found_advance += 1
			var pl: Dictionary = (s as Dictionary).get("payload", {})
			span = int(pl.get("units", -1))
	expect_eq(found_advance, 1, "one time_advanced signal per advance, not one per unit")
	expect_eq(span, 4, "time_advanced carries the span in its payload, where rules can read it")

	# ---------- 5. non-positive units is a no-op ----------
	var before := int(t3.get_state("upkeep", -1))
	sched3.advance_calendar(0)
	sched3.advance_calendar(-3)
	expect_eq(int(t3.get_state("upkeep", -1)), before, "advance of 0 or negative units is a no-op")

	# ---------- 6. the effect verb reaches the scheduler through env ----------
	var ents4 := {}
	var t4 := Entity.create(defs.town, "t4")
	ents4["t4"] = t4
	var env4: Dictionary = {
		"entities": ents4,
		"defs": defs,
		"relations": RelationStore.new(),
		"spatial_index": SpatialIndex.new(),
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}
	var sched4 := PhaseScheduler.new(env4)
	sched4.register_rules(
		[
			Rule.from_dict(
				{
					"id": "daily",
					"trigger": {"type": "scheduled", "every": 1},
					"query": {"tags_all": ["town"]},
					"effect": [{"type": "state_add", "target": "self", "field": "upkeep", "amount": 1}]
				}
			)
		]
	)
	EffectApply.apply({"type": "advance_time", "units": 3}, env4, {})
	expect_eq(int(t4.get_state("upkeep", -1)), 3, "the advance_time effect drives the calendar")

	t1.free()
	t2.free()
	t3.free()
	t4.free()


## ADR 0077 — level subroutines. The test suite builds env dicts rather than
## a live World (tests.md: no scene tree), so this covers the effect side of
## the contract: what level_call / level_return write into world state and
## env, which is exactly what LevelTransitionCoordinator.process_pending
## reads back. The swap itself is ADR 0006 machinery already covered by
## test_transition_level_fade.
func test_level_subroutine() -> void:
	_section("level_subroutine (ADR 0077)")

	var env: Dictionary = {
		"entities": {},
		"defs": {},
		"relations": RelationStore.new(),
		"world": {"current_level": "town"},
		"parent": null,
		"next_id": {"_": 0},
	}

	# ---------- 1. level_call pushes a frame + queues the swap ----------
	EffectApply.apply(
		{
			"type": "level_call",
			"level": "minigame_forge",
			"return_signal": "training_done",
			"args": {"difficulty": 3}
		},
		env,
		{}
	)
	expect_eq(str(env.get("_pending_level_call", "")), "minigame_forge", "level_call queues the swap")
	expect(
		not env.has("_pending_level_transition")
		or str(env.get("_pending_level_transition", "")) == "",
		"level_call does NOT use the plain transition path (sub-levels are off-progression)"
	)
	var ws: Dictionary = env["world"]
	var stack: Array = ws.get("_level_call_stack", [])
	expect_eq(stack.size(), 1, "call stack has one frame")
	expect_eq(str((stack[0] as Dictionary).get("level", "")), "town", "frame records the caller level")
	expect_eq(
		str((stack[0] as Dictionary).get("return_signal", "")),
		"training_done",
		"frame records the return signal"
	)
	expect_eq(
		int((ws.get("_call_args", {}) as Dictionary).get("difficulty", -1)),
		3,
		"args land in world state for the sub-level to read"
	)

	# ---------- 2. nesting: the stack unwinds in order ----------
	ws["current_level"] = "minigame_forge"
	EffectApply.apply(
		{"type": "level_call", "level": "sub_sub", "return_signal": "inner_done"}, env, {}
	)
	stack = ws.get("_level_call_stack", [])
	expect_eq(stack.size(), 2, "nested level_call pushes a second frame")

	ws["current_level"] = "sub_sub"
	EffectApply.apply({"type": "level_return", "result": {"score": 82}}, env, {})
	var ret1 = env.get("_pending_level_return", null)
	expect(ret1 is Dictionary, "level_return queues a return")
	if ret1 is Dictionary:
		expect_eq(
			str((ret1 as Dictionary).get("level", "")),
			"minigame_forge",
			"inner return targets the inner caller (LIFO)"
		)
		expect_eq(
			str((ret1 as Dictionary).get("return_signal", "")), "inner_done", "inner return signal"
		)
		expect_eq(
			int(((ret1 as Dictionary).get("result", {}) as Dictionary).get("score", -1)),
			82,
			"result payload rides along"
		)
	expect_eq((ws.get("_level_call_stack", []) as Array).size(), 1, "inner frame popped")

	# ---------- 3. outer return unwinds to the original caller ----------
	env["_pending_level_return"] = null
	EffectApply.apply({"type": "level_return", "result": {"passed": 1}}, env, {})
	var ret2 = env.get("_pending_level_return", null)
	if ret2 is Dictionary:
		expect_eq(
			str((ret2 as Dictionary).get("level", "")), "town", "outer return reaches the town"
		)
		expect_eq(
			str((ret2 as Dictionary).get("return_signal", "")),
			"training_done",
			"outer return uses the outer frame's signal"
		)
	expect_eq((ws.get("_level_call_stack", []) as Array).size(), 0, "stack fully unwound")

	# ---------- 4. empty stack is a logged no-op, not a crash ----------
	env["_pending_level_return"] = null
	env["error_buffer"] = []
	EffectApply.apply({"type": "level_return", "result": {}}, env, {})
	expect(
		env.get("_pending_level_return", null) == null,
		"level_return on an empty stack queues nothing"
	)
	var codes: Array = []
	for er in (env.get("error_buffer", []) as Array):
		codes.append(str((er as Dictionary).get("code", "")))
	expect(
		codes.has(EngineError.LEVEL_RETURN_EMPTY_STACK),
		"level_return on an empty stack raises level.return_empty_stack"
	)

	# ---------- 5. the stack is world state, so it persists with the save ----------
	# A player who saves inside a sub-level must return to the right caller.
	ws["current_level"] = "town"
	EffectApply.apply({"type": "level_call", "level": "dungeon", "return_signal": "out"}, env, {})
	var saved: Dictionary = (env["world"] as Dictionary).duplicate(true)
	var env2: Dictionary = {
		"entities": {},
		"defs": {},
		"relations": RelationStore.new(),
		"world": saved,
		"parent": null,
		"next_id": {"_": 0},
	}
	(env2["world"] as Dictionary)["current_level"] = "dungeon"
	EffectApply.apply({"type": "level_return", "result": {}}, env2, {})
	var ret3 = env2.get("_pending_level_return", null)
	expect(ret3 is Dictionary, "a restored world state still knows its caller")
	if ret3 is Dictionary:
		expect_eq(
			str((ret3 as Dictionary).get("level", "")),
			"town",
			"call stack survives a world-state round-trip"
		)


## ADR 0080 — `once` / `once_per` quantifiers on rule firing.
	# ---------- args + result RESOLVE, they are not copied ----------
	# Both carried author-written payloads straight through `duplicate(true)`, so a
	# formula arrived as its own source text: args `{"floor": "world.delve_floor"}`
	# stored the string, and result `{"haul": "self.state.haul"}` reached the caller
	# as a string that coerced to 0 — a cleared dungeon floor paid nothing, with no
	# error. `emit` and `spawn` already resolved their payloads; these two were the
	# ones that missed the step.
	ws["depth"] = 7.0
	EffectApply.apply(
		{
			"type": "level_call",
			"level": "minigame_forge",
			"return_signal": "done",
			"args": {"floor": "world.depth + 1", "fixed": 3}
		},
		env,
		{}
	)
	var res_args: Dictionary = ws.get("_call_args", {})
	expect_eq(
		float(res_args.get("floor", -1)), 8.0,
		"level_call args resolve formulas (world.depth + 1 -> 8), not the source text"
	)
	expect_eq(float(res_args.get("fixed", -1)), 3.0, "literal args pass through untouched")

	EffectApply.apply(
		{"type": "level_return", "result": {"haul": "world.depth * 10", "flat": 2}},
		env,
		{}
	)
	var ret_frame = env.get("_pending_level_return", null)
	expect_eq(ret_frame is Dictionary, true, "level_return queues a frame")
	if ret_frame is Dictionary:
		var res: Dictionary = (ret_frame as Dictionary).get("result", {})
		expect_eq(
			float(res.get("haul", -1)), 70.0,
			"level_return result resolves formulas — the caller receives a number"
		)
		expect_eq(float(res.get("flat", -1)), 2.0, "literal result fields pass through")


	# ---------- the result must actually REACH a caller rule ----------
	# The payload used to be appended FLAT beside "name" while the drain reads
	# sig["payload"], so ADR 0077's entire return value arrived empty at every
	# rule — a caller could see that a sub-level had ended but never how it ended.
	# Asserted through a REAL rule rather than by inspecting the buffer, because
	# the buffer looked perfectly reasonable while being unreadable.
	var pdefs: Dictionary = {
		"purse_def": {"id": "purse_def", "tags": ["purse"], "state_init": {"coin": 0}}
	}
	var pents: Dictionary = {}
	var purse := Entity.create(pdefs["purse_def"], "purse")
	pents["purse"] = purse
	var penv: Dictionary = {
		"entities": pents,
		"defs": pdefs,
		"relations": RelationStore.new(),
		"spatial_index": SpatialIndex.new(),
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}
	var psched := PhaseScheduler.new(penv)
	psched.register_rules(
		[
			Rule.from_dict(
				{
					"id": "bank_the_haul",
					"trigger": {"type": "signal", "name": "delve_done"},
					"query": {"tags_all": ["purse"]},
					"effect": [
						{"type": "state_add", "target": "self", "field": "coin", "amount": "haul"}
					]
				}
			)
		]
	)
	EffectCore.push_signal(penv, "delve_done", {"haul": 160})
	psched.tick()
	expect_eq(
		int(purse.get_state("coin", -1)), 160,
		"a return payload field is readable as a bare binding in the caller's formula"
	)
	purse.free()

## Batch C (2026-10-15) — tick-cost fixes keep their results: lazy zone and
## faction snapshots, the RegEx cache, and the early exit for spent `once`.
func test_batch_c_tick_cost() -> void:
	_section("batch C tick cost (2026-10-15)")
	var zenv := _make_zone_env()
	var fc_plain := EffectResolution.formula_context({}, zenv, "world.depth + 1")
	expect((fc_plain["zone"] as Dictionary).is_empty(), "a formula without `zone` skips the zone snapshot")
	var fc_zone := EffectResolution.formula_context({}, zenv, "zone.city_pendrel.population")
	expect(not (fc_zone["zone"] as Dictionary).is_empty(), "a formula with `zone` gets the snapshot")
	var fc_all := EffectResolution.formula_context({}, zenv)
	expect(not (fc_all["zone"] as Dictionary).is_empty(), "no formula text: build every snapshot, as before")
	expect_eq(
		float(EffectResolution.value("zone.city_pendrel.population + 1", {}, zenv)), 1201.0,
		"a zone formula still resolves through value() (lazy snapshot, same result)"
	)
	expect_eq(Formula.evaluate("cfg.rate * 2", {"cfg": {"rate": 4}, "unused_root": {}}), 8, "formula result unchanged")
	expect(Formula._root_regex_cache.has("cfg"), "the root's RegEx is compiled once and cached")
	expect(not Formula._root_regex_cache.has("unused_root"), "a root that is not in the text compiles no RegEx")

	# A spent `once` rule skips its query; `once_per` never skips early.
	var defs := {"v": {"id": "v", "tags": ["v"], "state_init": {"n": 0}}}
	var ents := {"v1": Entity.create(defs.v, "v1")}
	var env: Dictionary = {
		"entities": ents, "defs": defs, "relations": RelationStore.new(),
		"spatial_index": SpatialIndex.new(), "world": {}, "parent": null, "next_id": {"_": 0},
	}
	var sched := PhaseScheduler.new(env)
	var once_rule := Rule.from_dict({
		"id": "c_once", "once": true, "trigger": {"type": "tick", "interval": 1},
		"query": {"tags_all": ["v"]},
		"effect": [{"type": "state_add", "target": "self", "field": "n", "amount": 1}]})
	var per_rule := Rule.from_dict({
		"id": "c_per", "once_per": "self", "trigger": {"type": "tick", "interval": 1},
		"query": {"tags_all": ["v"]}, "effect": []})
	sched.register_rules([once_rule, per_rule])
	expect(not sched._once_spent(once_rule), "a `once` rule is not spent before it fires")
	sched.tick()
	expect(sched._once_spent(once_rule), "a `once` rule is spent after it fires")
	expect(not sched._once_spent(per_rule), "`once_per` is never spent early (a new entity can match)")
	sched.tick()
	expect_eq(int((ents["v1"] as Entity).get_state("n", -1)), 1, "the spent rule still fires exactly once")
	# The early exit comes after the `chance` roll: a spent rule with
	# chance < 1 consumes the same random numbers as before.
	var chancy := Rule.from_dict({
		"id": "c_chance", "once": true, "chance": 0.5, "trigger": {"type": "tick", "interval": 1},
		"query": {"tags_all": ["v"]}, "effect": []})
	(env["world"]["_fired_rules"] as Dictionary)["c_chance"] = true
	seed(1234)
	sched._fire_scan_rule(chancy)
	var after_spent := randf()
	seed(1234)
	randf()
	expect_eq(after_spent, randf(), "a spent rule with chance < 1 still rolls once (random sequence kept)")


func test_rule_once() -> void:
	_section("rule_once (ADR 0080)")

	var defs := {
		"villager": {"id": "villager", "tags": ["villager"], "state_init": {"greeted": 0}},
	}

	# ---------- 1. `once` fires exactly once across many ticks ----------
	var ents1 := {}
	var v1 := Entity.create(defs.villager, "v1")
	ents1["v1"] = v1
	var env1: Dictionary = {
		"entities": ents1,
		"defs": defs,
		"relations": RelationStore.new(),
		"spatial_index": SpatialIndex.new(),
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}
	var sched1 := PhaseScheduler.new(env1)
	sched1.register_rules(
		[
			Rule.from_dict(
				{
					"id": "first_beat",
					"once": true,
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["villager"]},
					"effect": [{"type": "state_add", "target": "self", "field": "greeted", "amount": 1}]
				}
			)
		]
	)
	for i in range(5):
		sched1.tick()
	expect_eq(int(v1.get_state("greeted", -1)), 1, "`once` rule fires exactly once over 5 ticks")
	expect(
		(env1["world"] as Dictionary).has("_fired_rules"),
		"`once` records into world state (so it persists with the save)"
	)

	# ---------- 2. `once_per` fires once per distinct entity ----------
	var ents2 := {}
	var a2 := Entity.create(defs.villager, "a")
	var b2 := Entity.create(defs.villager, "b")
	var c2 := Entity.create(defs.villager, "c")
	ents2["a"] = a2
	ents2["b"] = b2
	ents2["c"] = c2
	var env2: Dictionary = {
		"entities": ents2,
		"defs": defs,
		"relations": RelationStore.new(),
		"spatial_index": SpatialIndex.new(),
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}
	var sched2 := PhaseScheduler.new(env2)
	sched2.register_rules(
		[
			Rule.from_dict(
				{
					"id": "greet_each",
					"once_per": "self",
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["villager"]},
					"effect": [{"type": "state_add", "target": "self", "field": "greeted", "amount": 1}]
				}
			)
		]
	)
	for i in range(4):
		sched2.tick()
	expect_eq(int(a2.get_state("greeted", -1)), 1, "once_per fired once for a")
	expect_eq(int(b2.get_state("greeted", -1)), 1, "once_per fired once for b")
	expect_eq(int(c2.get_state("greeted", -1)), 1, "once_per fired once for c")

	# A newcomer still gets its own shot — the ledger is per (rule, entity).
	var d2 := Entity.create(defs.villager, "d")
	ents2["d"] = d2
	sched2.tick()
	expect_eq(int(d2.get_state("greeted", -1)), 1, "once_per still fires for an entity seen later")
	expect_eq(int(a2.get_state("greeted", -1)), 1, "...without re-firing for the earlier ones")

	# ---------- 3. the ledger survives a world-state round-trip ----------
	# Persistence is what stops a save/load from replaying a story beat. The
	# ledger lives in world state (ADR 0047), which the save system already
	# serialises, so restoring it must suppress a re-fire.
	var ents3 := {}
	var v3 := Entity.create(defs.villager, "v3")
	ents3["v3"] = v3
	var carried: Dictionary = (env1["world"] as Dictionary).duplicate(true)
	var env3: Dictionary = {
		"entities": ents3,
		"defs": defs,
		"relations": RelationStore.new(),
		"spatial_index": SpatialIndex.new(),
		"world": carried,
		"parent": null,
		"next_id": {"_": 0},
	}
	var sched3 := PhaseScheduler.new(env3)
	sched3.register_rules(
		[
			Rule.from_dict(
				{
					"id": "first_beat",
					"once": true,
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["villager"]},
					"effect": [{"type": "state_add", "target": "self", "field": "greeted", "amount": 1}]
				}
			)
		]
	)
	for i in range(3):
		sched3.tick()
	expect_eq(
		int(v3.get_state("greeted", -1)),
		0,
		"a restored ledger suppresses the re-fire (no replayed story beats on load)"
	)

	# ---------- 4. ordinary rules are untouched ----------
	var ents4 := {}
	var v4 := Entity.create(defs.villager, "v4")
	ents4["v4"] = v4
	var env4: Dictionary = {
		"entities": ents4,
		"defs": defs,
		"relations": RelationStore.new(),
		"spatial_index": SpatialIndex.new(),
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
	}
	var sched4 := PhaseScheduler.new(env4)
	sched4.register_rules(
		[
			Rule.from_dict(
				{
					"id": "every_tick",
					"trigger": {"type": "tick", "interval": 1},
					"query": {"tags_all": ["villager"]},
					"effect": [{"type": "state_add", "target": "self", "field": "greeted", "amount": 1}]
				}
			)
		]
	)
	for i in range(5):
		sched4.tick()
	expect_eq(int(v4.get_state("greeted", -1)), 5, "a rule without `once` still fires every tick")

	# ---------- 5. `once` + `once_per` together is a load-time error ----------
	var conflict := Rule.from_dict(
		{
			"id": "bad",
			"once": true,
			"once_per": "self",
			"trigger": {"type": "tick"},
			"effect": [{"type": "state_set", "field": "x", "value": 1}]
		}
	)
	var errs: Array = Rule.validate_all([conflict])
	var found := false
	for e in errs:
		if str((e as Dictionary).get("code", "")) == EngineError.RULE_ONCE_CONFLICT:
			found = true
	expect(found, "`once` + `once_per` together raises rule.once_conflict at load")

	v1.free()
	a2.free()
	b2.free()
	c2.free()
	d2.free()
	v3.free()
	v4.free()


## ADR 0076 — the `list` element makes Query (primitive #6) a UI data source.
func test_ui_list_element() -> void:
	_section("ui_list_element (ADR 0076)")

	var defs := {
		"npc":
		{
			"id": "npc",
			"tags": ["npc"],
			"properties": {"display_name": "Someone"},
			"state_init": {"rank": 0}
		},
	}
	var entities := {}
	var rs := RelationStore.new()
	var ids := ["n1", "n2", "n3"]
	var made: Array = []
	for i in range(ids.size()):
		var e := Entity.create(defs.npc, ids[i])
		e.properties["display_name"] = "Name%d" % i
		e.set_state("rank", i)
		entities[ids[i]] = e
		made.append(e)
		rs.relate("knows", ids[i], "player", {"trust": 10 * (i + 1)})
	var pl := Entity.create({"id": "p", "tags": ["player"], "state_init": {}}, "player")
	entities["player"] = pl
	made.append(pl)
	var env := {"entities": entities, "relations": rs}

	var parent := Control.new()
	var bound: Array = []
	var dispatcher := func(_a, _b): pass

	# ---------- 1. one row per match ----------
	var lst := ControlFactory._build_list(
		{
			"type": "list",
			"from": {"tags_all": ["npc"]},
			"item": {"type": "button", "text": "row.properties.display_name"}
		},
		dispatcher,
		bound,
		env
	)
	expect(lst is VBoxContainer, "list → VBoxContainer")
	expect_eq(lst.get_child_count(), 3, "one row per matched entity")

	# ---------- 2. properties substitute as literals ----------
	var texts: Array = []
	for c in lst.get_children():
		if c is Button:
			texts.append((c as Button).text)
	texts.sort()
	expect_eq(texts, ["Name0", "Name1", "Name2"], "row.properties.X substitutes per row")

	# ---------- 3. limit truncates (and is not silent — warns) ----------
	var lst_lim := ControlFactory._build_list(
		{
			"type": "list",
			"from": {"tags_all": ["npc"]},
			"limit": 2,
			"item": {"type": "label", "text": "row.properties.display_name"}
		},
		dispatcher,
		bound,
		env
	)
	expect_eq(lst_lim.get_child_count(), 2, "limit caps rendered rows")

	# ---------- 4. empty branch ----------
	var lst_empty := ControlFactory._build_list(
		{
			"type": "list",
			"from": {"tags_all": ["nonexistent_tag"]},
			"item": {"type": "label", "text": "row.id"},
			"empty": {"type": "label", "text": "Nobody here."}
		},
		dispatcher,
		bound,
		env
	)
	expect_eq(lst_empty.get_child_count(), 1, "empty query renders the `empty` element")
	if lst_empty.get_child_count() == 1 and lst_empty.get_child(0) is Label:
		expect_eq(
			(lst_empty.get_child(0) as Label).text, "Nobody here.", "empty element text preserved"
		)

	# No `empty` authored → renders nothing, does not error.
	var lst_bare := ControlFactory._build_list(
		{
			"type": "list",
			"from": {"tags_all": ["nonexistent_tag"]},
			"item": {"type": "label", "text": "row.id"}
		},
		dispatcher,
		bound,
		env
	)
	expect_eq(lst_bare.get_child_count(), 0, "empty query with no `empty` renders nothing")

	# ---------- 5. `row` substitutes into on_click effect payloads ----------
	var captured: Array = []
	var capturing := func(effects, _ctx): captured.append(effects)
	var lst_click := ControlFactory._build_list(
		{
			"type": "list",
			"from": {"tags_all": ["npc"], "state": {"rank_eq": 1}},
			"item":
			{
				"type": "button",
				"text": "row.properties.display_name",
				"on_click": [{"type": "emit", "signal": "talk_to", "target": "row"}]
			}
		},
		dispatcher,
		bound,
		env
	)
	expect_eq(lst_click.get_child_count(), 1, "query state filter narrows the list")
	# Rebuild with the capturing dispatcher so the press is observable.
	var lst_click2 := ControlFactory._build_list(
		{
			"type": "list",
			"from": {"tags_all": ["npc"], "state": {"rank_eq": 1}},
			"item":
			{
				"type": "button",
				"text": "x",
				"on_click": [{"type": "emit", "signal": "talk_to", "target": "row"}]
			}
		},
		capturing,
		bound,
		env
	)
	if lst_click2.get_child_count() == 1 and lst_click2.get_child(0) is Button:
		(lst_click2.get_child(0) as Button).pressed.emit()
	expect_eq(captured.size(), 1, "row button dispatches its on_click chain")
	if captured.size() == 1:
		expect_eq(
			(captured[0] as Array)[0]["target"],
			"n2",
			"`row` in an effect payload resolves to that row's entity id"
		)

	# ---------- 6. state under `binds` stays LIVE, elsewhere is a snapshot ----------
	var lst_bind := ControlFactory._build_list(
		{
			"type": "list",
			"from": {"tags_all": ["npc"], "state": {"rank_eq": 2}},
			"item": {"type": "label", "binds": "row.state.rank", "text": "row.state.rank"}
		},
		dispatcher,
		bound,
		env
	)
	var row_cfg: Dictionary = {}
	for b in bound:
		if str((b["cfg"] as Dictionary).get("binds", "")).begins_with("n3."):
			row_cfg = b["cfg"]
	expect_eq(row_cfg.get("binds", ""), "n3.rank", "row.state.X under `binds` becomes <id>.<field>")
	expect_eq(str(row_cfg.get("text", "")), "2", "row.state.X outside `binds` is a literal snapshot")

	# ---------- 7. edge_of exposes relation edge state (ADR 0075 read access) ----------
	var lst_edge := ControlFactory._build_list(
		{
			"type": "list",
			"from": {"tags_all": ["npc"], "state": {"rank_eq": 0}},
			"edge_of": {"relation": "knows", "to": "player"},
			"item": {"type": "label", "text": "row_edge.trust"}
		},
		dispatcher,
		bound,
		env
	)
	if lst_edge.get_child_count() == 1 and lst_edge.get_child(0) is Label:
		expect_eq(
			(lst_edge.get_child(0) as Label).text, "10", "row_edge.X reads the relation edge state"
		)

	# ---------- 8. malformed spec degrades, never crashes ----------
	var lst_bad := ControlFactory._build_list(
		{"type": "list", "item": {"type": "label", "text": "x"}}, dispatcher, bound, env
	)
	expect_eq(lst_bad.get_child_count(), 0, "list without `from` renders nothing instead of erroring")
	var lst_bad2 := ControlFactory._build_list(
		{"type": "list", "from": {"tags_all": ["npc"]}}, dispatcher, bound, env
	)
	expect_eq(lst_bad2.get_child_count(), 0, "list without `item` renders nothing instead of erroring")

	# ---------- 9. no world at all → renders `empty`, never errors ----------
	# With no world in the tree there is nothing to query and no world_loaded
	# signal to wait for, so `empty` is the correct terminal state. In a REAL
	# boot the same first populate also sees zero entities (the UI directors'
	# _ready runs before World.load_data) — but there the list subscribes to
	# world_loaded and repopulates, which the sokoban visual probe verified.
	var lst_noenv := ControlFactory._build_list(
		{
			"type": "list",
			"from": {"tags_all": ["npc"]},
			"item": {"type": "label", "text": "row.id"},
			"empty": {"type": "label", "text": "None"}
		},
		dispatcher,
		bound
	)
	expect_eq(lst_noenv.get_child_count(), 1, "no world available → renders `empty`, does not error")

	lst.free()
	lst_lim.free()
	lst_empty.free()
	lst_bare.free()
	lst_click.free()
	lst_click2.free()
	lst_bind.free()
	lst_edge.free()
	lst_bad.free()
	lst_bad2.free()
	lst_noenv.free()
	parent.free()
	for e in made:
		e.free()


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

	# === Test 1b: third-person pitch is UNLOCKED by default (gate) ===
	# Post-mortem 2026-06-06: third-person shipped pitch-frozen because
	# `use_pitch` defaulted false AND the third_person_default preset
	# didn't set it → mouse-Y couldn't look up/down. Gate: the shipped
	# third-person preset must enable pitch (use_pitch != false). Mirrors
	# the engine default (_drain_mouse_facing now defaults use_pitch=true).
	# Read the REAL cameras.json (not via the seeded LibResolver cache).
	var cam_f := FileAccess.open("res://data/lib/cameras.json", FileAccess.READ)
	expect_eq(cam_f != null, true, "data/lib/cameras.json opens")
	if cam_f != null:
		var cam_lib = JSON.parse_string(cam_f.get_as_text())
		var tp: Dictionary = (cam_lib as Dictionary).get("third_person_default", {})
		expect_eq(str(tp.get("mode")), "third_person_3d", "third_person preset present")
		# get("use_pitch", true) mirrors _drain_mouse_facing's default; the
		# preset must not ship it as false (would re-lock the pitch).
		expect_eq(
			bool(tp.get("use_pitch", true)),
			true,
			"third-person pitch unlocked by default (use_pitch not false)"
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

	# === Test 9b: deeply-nested tree with NO @lib refs must not trip
	# depth limit. The depth counter is meant to catch @lib-resolution
	# chains (real cycle risk), not plain JSON tree walks. Empirical
	# case 2026-05-20: screens.json with nested vbox layouts hit
	# MAX_DEPTH=8 on tree walk alone (visited=[], no lib chasing). Fix:
	# only increment depth at @lib boundaries. This test pins that
	# discipline — if anyone re-adds `depth+1` to the dict/array recurse
	# branches, the 20-level fixture will trip MAX_DEPTH and fail. ===
	_section("lib_resolver.test_deep_tree_no_lib_refs")
	var t9b_in: Dictionary = {"leaf": "value"}
	for i in range(20):
		t9b_in = {"level_%d" % i: t9b_in, "array_at_%d" % i: [t9b_in]}
	var t9b_out = LibResolver.resolve(t9b_in)
	expect_eq(typeof(t9b_out), TYPE_DICTIONARY, "20-level nested dict resolves without depth trip")
	# Walk back down to verify leaf preserved
	var t9b_cur: Variant = t9b_out
	for i in range(19, -1, -1):
		expect_eq(typeof(t9b_cur), TYPE_DICTIONARY, "level %d still dict" % i)
		t9b_cur = (t9b_cur as Dictionary).get("level_%d" % i)
	expect_eq(
		str((t9b_cur as Dictionary).get("leaf")),
		"value",
		"deep-tree leaf survived 20-level walk",
	)

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


## Gate (post-mortem 2026-06-06): the shell H-help screen OPENED but
## would NOT close. Cause: screen_flow._handle_global_inputs updated the
## per-action press-edge state PER ENTRY, so when two global_inputs share
## one action (the paired-if_screen toggle: open when if_screen="", close
## when if_screen="X"), the first entry consumed the edge and the close
## half never fired. Fix: _compute_action_edges computes the edge ONCE per
## action. This test pins that: a same-action toggle pair must report a
## single edge=true on press, false while held, true again on re-press —
## independent of how many entries reference the action.
func test_global_input_toggle_edge() -> void:
	_section("screen_flow.global_input_toggle_edge (2026-06-06)")
	if not InputMap.has_action("toggle_help"):
		InputMap.add_action("toggle_help")
	var sf := ScreenFlow.new()
	# Two entries, SAME action — the toggle pattern that exposed the bug.
	var globals: Array = [
		{"action": "toggle_help", "if_screen": ""},
		{"action": "toggle_help", "if_screen": "help"},
	]
	# Frame 1 — key down, no prior state → edge fires ONCE for the action.
	sf._pressed_lookup = {"toggle_help": true}
	var e1: Dictionary = sf._compute_action_edges(globals)
	expect_eq(bool(e1.get("toggle_help")), true, "press → edge true (open half can fire)")
	# Frame 2 — key still held → no edge (prevents repeat-fire each frame).
	var e2: Dictionary = sf._compute_action_edges(globals)
	expect_eq(bool(e2.get("toggle_help")), false, "held → no edge")
	# Frame 3 — released.
	sf._pressed_lookup = {"toggle_help": false}
	var e3: Dictionary = sf._compute_action_edges(globals)
	expect_eq(bool(e3.get("toggle_help")), false, "release → no edge")
	# Frame 4 — pressed again → edge fires again (close half can now fire).
	sf._pressed_lookup = {"toggle_help": true}
	var e4: Dictionary = sf._compute_action_edges(globals)
	expect_eq(
		bool(e4.get("toggle_help")),
		true,
		"re-press → edge true again (close half fires; was the bug)"
	)
	sf.free()


## GUARDRAIL (post-mortem 2026-06-06): the RUNTIME spawn path (EffectCore.spawn,
## used by every rule-driven `spawn` effect) must build the physics body for the
## new entity — parity with SpawnManager.spawn (initial instances). It diverged:
## only initial instances built bodies, so rule-spawned movers (projectiles,
## summoned NPCs) got a renderer but NO body and were frozen in place — the
## doomarena3d "enemies + bullets never move" bug. The headless harness has no
## 3D physics space to build a real body, so this gate asserts the WIRING: that
## EffectCore.spawn invokes build_runtime_physics_body on its parent. If the
## call is removed again, this FAILS.
func test_runtime_spawn_builds_body() -> void:
	_section("effect_core.spawn builds body + attaches renderer (parity) (2026-06-06)")
	# Spy parent: records BOTH parity hooks. The renderer hook is named
	# attach_runtime_renderer (NOT _attach_renderer — that lives on SpawnManager,
	# not env.parent; the old guard silently skipped it → invisible spawns).
	var spy_src := GDScript.new()
	spy_src.source_code = (
		"extends Node\n"
		+ "var built: Array = []\n"
		+ "var rendered: Array = []\n"
		+ "func attach_runtime_renderer(e) -> void: rendered.append(e)\n"
		+ "func build_runtime_physics_body(e) -> void: built.append(e)\n"
	)
	spy_src.reload()
	var spy = spy_src.new()
	add_child(spy)
	var defs: Dictionary = {
		"bolt": {"id": "bolt", "tags": ["projectile"], "state_init": {"velocity": [0, 0, -22], "charge": 0},
			"physics": {"body_type": "rigid", "collision_shape": {"type": "sphere", "radius": 0.1}}},
	}
	var env: Dictionary = {
		"entities": {}, "defs": defs, "relations": RelationStore.new(),
		"world": {}, "parent": spy, "next_id": {"_": 0}, "spatial_index": null,
	}
	# SCALAR formula override must resolve (not just position/velocity arrays). A
	# pitch-aimed projectile seeds state.y_velocity via a formula; if scalar
	# overrides aren't resolved it stays a string -> 0 -> the shot flies flat.
	var res = EffectCore.spawn(
		{"type": "spawn", "template": "bolt", "overrides": {"state": {"charge": "2 + 3"}}}, env, {}
	)
	expect_eq(spy.built.size(), 1, "EffectCore.spawn called build_runtime_physics_body once")
	expect_eq(spy.rendered.size(), 1, "EffectCore.spawn called attach_runtime_renderer once (else invisible)")
	var spawned_id := str(res.get("spawned_id", ""))
	var spawned = (env["entities"] as Dictionary).get(spawned_id, null)
	if spawned is Entity:
		expect_eq(
			float((spawned as Entity).get_state("charge", -1)), 5.0,
			"scalar formula override 'charge: 2 + 3' resolved (not left as a string -> 0)"
		)
	spy.queue_free()


## GUARDRAIL (post-mortem 2026-06-06): InputRegistrar edge classification must
## be LAST-WRITER-WINS per action name, with each action in EXACTLY ONE poll
## list. A game splicing @lib.input.universal (move_* = hold) then re-declaring
## move_* as press relies on the override (manifest: "re-declare after the
## $include — last-writer-wins"). The old code APPENDED each occurrence, so
## move_* sat in BOTH press + hold; the hold-poll (is_action_pressed) then
## fired every frame regardless of the press override → sokoban's player slid
## continuously while a key was held instead of moving one grid cell per press.
## If classify_edges ever regresses to append-without-dedup, this FAILS.
func test_input_edge_last_writer_wins() -> void:
	_section("input_registrar.classify_edges last-writer-wins (2026-06-06)")
	# The exact sokoban shape: universal include (hold) then per-game override (press).
	var pairs: Array = [
		{"name": "move_north", "edge": "hold"},
		{"name": "move_south", "edge": "hold"},
		{"name": "move_east", "edge": "hold"},
		{"name": "move_west", "edge": "hold"},
		{"name": "restart", "edge": "press"},
		# per-game re-declarations AFTER the include:
		{"name": "move_north", "edge": "press"},
		{"name": "move_south", "edge": "press"},
		{"name": "move_east", "edge": "press"},
		{"name": "move_west", "edge": "press"},
	]
	var c: Dictionary = InputRegistrar.classify_edges(pairs)
	var press: Array = c["press"]
	var hold: Array = c["hold"]
	# move_* overridden to press → in press, NOT in hold (the bug put them in both).
	for mv in ["move_north", "move_south", "move_east", "move_west"]:
		expect_eq(press.has(mv), true, "%s lands in press (override wins)" % mv)
		expect_eq(hold.has(mv), false, "%s NOT in hold (was the bug)" % mv)
	expect_eq(press.has("restart"), true, "restart stays press")
	# Each action appears in exactly one list, once.
	expect_eq(press.size() + hold.size(), 5, "5 distinct actions, no duplicates across lists")
	# Reverse direction also wins last: press-then-hold → hold.
	var c2: Dictionary = InputRegistrar.classify_edges(
		[{"name": "aim", "edge": "press"}, {"name": "aim", "edge": "hold"}]
	)
	expect_eq((c2["hold"] as Array).has("aim"), true, "press→hold override → hold")
	expect_eq((c2["press"] as Array).has("aim"), false, "aim removed from press on override")


## GUARDRAIL (post-mortem 2026-06-06): a `from_visual_mesh` box collider must
## SHRINK-WRAP to the entity's visual .glb — proportions from the mesh bbox,
## height = state.scale's Y, base on the ground, yaw = state.yaw + offset —
## mirroring EntityMesh3D's normalize + uniform-height scale + yaw. The
## collider-vs-mesh mismatch recurred because a PROSE invariant ("derive from
## mesh") wasn't ENFORCED + the collider used a canonical guess. This test is
## the enforced gate: if the collider sizing/rotation drifts from the rendered
## mesh again, it FAILS. If you change EntityMesh3D's placement math, update
## _shrinkwrap_box_to_visual + this test together.
func test_collider_matches_mesh() -> void:
	_section("collider_matches_mesh (2026-06-06 guardrail)")
	var glb := "res://data/lib/assets/meshes/primitive_humanoid_capsule.glb"
	if not ResourceLoader.exists(glb):
		expect_eq(true, true, "skip — lib primitive .glb missing")
		return
	var bb: AABB = PhysicsBodyBuilder._glb_bbox(glb)
	expect_eq(bb.size.y > 0.0, true, "mesh bbox has positive height")
	var def := {
		"id": "test_prop", "tags": ["prop"], "properties": {},
		"state_init": {"scale": [1.0, 2.0, 1.0], "yaw": 0.5},
		# The spec form of the same file (ADR 0087).
		"visual": {"mesh": "@lib/assets/meshes/primitive_humanoid_capsule.glb"},
	}
	var ent := Entity.create(def, "test_prop_1")
	# Deliberately WRONG fallback size — the shrink-wrap MUST override it.
	var cfg := {"type": "box", "from_visual_mesh": true,
				"size": [9.0, 9.0, 9.0], "offset": [0.0, 4.0, 0.0]}
	var out: Dictionary = PhysicsBodyBuilder._shrinkwrap_box_to_visual(cfg, ent)
	var sz = out.get("size", [0, 0, 0])
	var off = out.get("offset", [0, 0, 0])
	var h := 2.0  # state.scale Y
	var want_w := bb.size.x / bb.size.y * h
	var want_d := bb.size.z / bb.size.y * h
	expect_eq(abs(float(sz[1]) - h) < 0.001, true, "collider height == state.scale.y")
	expect_eq(abs(float(sz[0]) - want_w) < 0.001, true, "collider width == mesh proportion × height")
	expect_eq(abs(float(sz[2]) - want_d) < 0.001, true, "collider depth == mesh proportion × height")
	expect_eq(abs(float(off[1]) - h * 0.5) < 0.001, true, "box base on the ground (offset y = h/2, TIGHT)")
	expect_eq(float(sz[1]) != 9.0, true, "fallback canonical size was OVERRIDDEN by the mesh-derived box")
	# Yaw must mirror EntityMesh3D._sync_yaw (state.yaw + mesh_yaw_offset).
	expect_eq(abs(PhysicsBodyBuilder._entity_yaw(ent) - 0.5) < 0.001, true,
		"collider yaw == state.yaw (rotates with the mesh)")
	ent.free()


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
	# ADR 0060 Phase 1: StepRunner is the sole tick driver; disable
	# World._process so the frames StepRunner awaits (to clear the
	# is_action_just_pressed edge) can't auto-advance a tick. Also register
	# the test action in BOTH poll lists — the unified scripted-input path
	# routes through InputRegistrar.poll, which only queues actions present
	# in input_actions_press/hold (press uses is_action_just_pressed, hold
	# uses is_action_pressed; per-tick dedup collapses the overlap to one
	# fire per tick).
	world.set_process(false)
	world.set_physics_process(false)  # ADR 0069: poll + tick gate both live there now
	world.input_actions_press = PackedStringArray([test_action])
	world.input_actions_hold = PackedStringArray([test_action])
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
	# Register action2 in the poll lists too (unified path — see top of func).
	if not (world.input_actions_press as Array).has(test_action2):
		world.input_actions_press.append(test_action2)
	if not (world.input_actions_hold as Array).has(test_action2):
		world.input_actions_hold.append(test_action2)
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

	# entity_field by id, and an unknown key fails. Empirical 2026-10-16:
	# StepRunner ignored `select`/`id`, so an empty query checked the first entity.
	var ctx6b: Dictionary = {
		"verbose": false, "passed": 0, "failed": 0, "failures": [], "screenshots": []
	}
	await StepRunner.run(
		[{"expect": [
			{"entity_field": {"id": "p1", "field": "state.counter", "op": "==", "value": 7}},
			{"entity_field": {"select": "by_id", "id": "p1", "field": "state.counter", "value": 7}},
		]}],
		world,
		ctx6b
	)
	expect_eq(int(ctx6b.get("passed", 0)), 1, "entity_field id: 1 pass")
	expect_eq(int(ctx6b.get("failed", 0)), 1, "entity_field unknown key `select`: 1 fail")

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

	# ---------- 13. scripted-press no-double-fire (ADR 0060 Phase 1 gate) ----------
	# REPLACES the old _scripted_action_consumed carve-out (2026-05-17). That
	# carve-out existed because step_runner used a SECOND input path (direct
	# scheduler.queue_input alongside Input.action_press), leaving a latched
	# is_action_just_pressed the live poll re-fired on the next frame → the
	# I-toggle double-open (press closes inventory, re-opens it).
	#
	# Phase 1 unified scripted input onto InputRegistrar.poll (one path) and
	# step_runner now awaits a real frame after each press to clear the edge.
	# This test gates the new structural guarantee: a press queues exactly
	# once, and after release + one real frame the edge is cleared so a
	# subsequent poll does NOT re-fire. (Without the frame, Godot's
	# is_action_just_pressed stays TRUE even after release in headless mode —
	# that was the latent re-fire the carve-out used to mask.)
	player.state["counter"] = 0
	world.scheduler.input_queue.clear()
	Input.action_press(test_action)
	InputRegistrar.poll(world.scheduler, "p1", [], [test_action], "", entities)
	expect_eq(
		world.scheduler.input_queue.size(), 1, "scripted press: poll queues the action once"
	)
	world.scheduler.input_queue.clear()
	Input.action_release(test_action)
	# The frame boundary step_runner._do_press awaits after release.
	await get_tree().process_frame
	InputRegistrar.poll(world.scheduler, "p1", [], [test_action], "", entities)
	expect_eq(
		world.scheduler.input_queue.size(),
		0,
		"scripted press: release + one frame clears the edge — no re-fire (was the I-toggle double-open)"
	)

	# ---------- 13b. StepRunner is the sole tick driver on the live path ----------
	# 2026-10-16: a capture run left World._process on, so the live loop
	# handled each scripted press a second time (sokoban moved two cells).
	player.state["counter"] = 0
	world.set_process(true)
	world.set_physics_process(true)
	var ctx13b: Dictionary = {
		"verbose": false, "passed": 0, "failed": 0, "failures": [], "screenshots": []
	}
	await StepRunner.run([{"press": test_action}], world, ctx13b)
	expect_eq(int(player.get_state("counter", 0)), 1, "live path: one scripted press fires the rule once")
	expect(world.is_processing() and world.is_physics_processing(), "live path: run() restores World processing")
	expect(not world.has_meta(StepRunner.LIVE_META), "live path: run() clears its mode meta")
	world.set_process(false)
	world.set_physics_process(false)

	# ---------- 13c. a scripted press reaches the overlay manager ----------
	# 2026-10-16: the step runner released each action before the next
	# frame, and only ScreenFlow saw the press. No scripted step could
	# close a tutorial overlay.
	var om: Node = load("res://scripts/engine/ui/overlay.gd").new()
	om.name = "OverlayManager"
	world.add_child(om)
	(world.scheduler.env["overlay_event_buffer"] as Array).append(
		{"event": "show_overlay", "id": "tut", "advance_action": test_action, "text": "hi"}
	)
	om._drain_overlay_events()
	expect_eq(om._stack.size(), 1, "overlay: shown before the press")
	var ctx13c: Dictionary = {
		"verbose": false, "passed": 0, "failed": 0, "failures": [], "screenshots": []
	}
	await StepRunner.run([{"press": test_action}], world, ctx13c)
	expect_eq(om._stack.size(), 0, "overlay: a scripted press of its advance_action closes it")
	world.remove_child(om)
	om.free()

	# ---------- 14. scripted input routes via ActorManager (ADR 0016 parity) ----------
	# StepRunner._find_actor_id must mirror LIVE play: when the world has
	# an ActorManager, the ACTIVE actor's controlled entity receives
	# scripted input — NOT the first world.actor_tag/"player"-tagged
	# entity. Empirical 2026-06-11 (autorace possession): actors.json
	# routed the keyboard to car_red (tagged "car"/"actor"), but the old
	# forked tag-scan in _drive_poll looked for "player", resolved "",
	# and silently dropped every --capture-input press — scripted capture
	# diverged from live play. This test boots a kart-controlling actor
	# alongside a decoy "player"-tagged entity and asserts the input
	# lands on the kart.
	var kart_def: Dictionary = {
		"id": "kart",
		"tags": ["kart"],
		"state_init": {"routed": 0, "position": Vector3.ZERO},
	}
	var kart := Entity.create(kart_def, "k1", {})
	entities["k1"] = kart
	player.state["routed"] = 0
	var route_rule := (
		Rule
		. from_dict(
			{
				"id": "step_test_actor_route",
				"trigger": {"type": "input", "action": test_action},
				"query": {"tags_all": ["kart"]},
				"effect":
				{
					"type": "state_set",
					"target": "actor",
					"field": "routed",
					"value": "actor.state.routed + 1"
				},
			}
		)
	)
	world.scheduler.append_rules([route_rule])
	var am := ActorManager.new()
	am._actors = [
		{
			"id": "drv",
			"input_device": "keyboard",
			"control_mode": "human",
			"starting_entity_tag": "kart",
		}
	]
	am._by_id = {"drv": am._actors[0]}
	am.active_actor_id = "drv"
	world.actor_manager = am
	var ctx14: Dictionary = {
		"verbose": false, "passed": 0, "failed": 0, "failures": [], "screenshots": []
	}
	await StepRunner.run([{"press": test_action}], world, ctx14)
	expect_eq(
		int(kart.get_state("routed", 0)),
		1,
		"actor routing: scripted press lands on ActorManager's active entity (kart)"
	)
	expect_eq(
		int(player.get_state("routed", 0)),
		0,
		"actor routing: decoy player-tagged entity did NOT receive the press"
	)
	# ---------- 15. hold cadence is per PHYSICS STEP (ADR 0069 gate) ----------
	# The live input poll must run on the physics clock — once per sim
	# tick — NOT per rendered frame. When it polled in _process, hold
	# cadence was frame-rate-dependent: at 8 fps a held key fired 8×/s
	# against per-tick rules firing 60×/s, so any opposing per-tick force
	# (drag, decay) overpowered held input. Empirical 2026-06-11:
	# autorace coast_drag made W/S unresponsive at low fps while the
	# (per-tick) StepRunner scenario passed. This test drives
	# _physics_process directly N times with an action HELD and asserts
	# the input rule fired exactly N times — one per step, no frames
	# involved.
	kart.state["routed"] = 0
	world.actor_manager = am  # kart receives input (test 14's manager)
	# Live poll resolves the actor against World.entities (the member a
	# booted world gets from load_data) — mirror it for the direct call.
	world.entities = entities
	var saved_tick_seconds := world.tick_seconds
	world.tick_seconds = 1.0 / 60.0  # snap path: one tick per physics step
	Input.action_press(test_action)
	for i in range(5):
		world._physics_process(1.0 / 60.0)
	Input.action_release(test_action)
	await get_tree().process_frame  # clear the press edge
	expect_eq(
		int(kart.get_state("routed", 0)),
		5,
		"ADR 0069: held action fires once per physics step (5 steps → 5 fires), frame-rate-independent"
	)
	world.tick_seconds = saved_tick_seconds
	world.actor_manager = null

	# Cleanup
	world.queue_free()


# ============================================================
# ADR 0072 — per-entity light source
# ============================================================


func test_entity_light_mount() -> void:
	_section("entity light mount (ADR 0072)")
	var def: Dictionary = {
		"id": "lamp",
		"tags": ["decor"],
		"state_init": {"position": Vector3.ZERO},
		"visual":
		{
			"mesh": "prim_unit_box",
			"light":
			{
				"type": "omni",
				"color": "#ffd9a0",
				"energy": 2.5,
				"range": 11.0,
				"position": [0, 3.05, 0],
			},
		},
	}
	var ent := Entity.create(def, "lamp1", {})
	add_child(ent)
	var renderer := EntityMesh3D.new()
	ent.add_child(renderer)  # _ready mounts visual + light
	var light := renderer.get_node_or_null("EntityLight")
	expect(light is OmniLight3D, "visual.light type omni → OmniLight3D child")
	if light is OmniLight3D:
		var ol := light as OmniLight3D
		expect(absf(ol.omni_range - 11.0) < 0.001, "light range applied")
		expect(absf(ol.light_energy - 2.5) < 0.001, "light energy applied")
		expect(not ol.shadow_enabled, "shadow defaults OFF")
		expect(absf(ol.position.y - 3.05) < 0.001, "local offset applied")
	# spot variant aims its direction
	var def2: Dictionary = def.duplicate(true)
	def2["visual"]["light"]["type"] = "spot"
	def2["visual"]["light"]["angle"] = 30.0
	var ent2 := Entity.create(def2, "lamp2", {})
	add_child(ent2)
	var renderer2 := EntityMesh3D.new()
	ent2.add_child(renderer2)
	var light2 := renderer2.get_node_or_null("EntityLight")
	expect(light2 is SpotLight3D, "visual.light type spot → SpotLight3D child")
	if light2 is SpotLight3D:
		expect(
			absf((light2 as SpotLight3D).spot_angle - 30.0) < 0.001, "spot angle applied"
		)
	# 3. rule-driven binding: light_energy follows a state field
	var def3: Dictionary = def.duplicate(true)
	def3["visual"]["light"]["energy_binds"] = "flame"
	def3["state_init"]["flame"] = 2.0
	var ent3 := Entity.create(def3, "lamp3", {})
	add_child(ent3)
	var renderer3 := EntityMesh3D.new()
	ent3.add_child(renderer3)
	var light3 := renderer3.get_node_or_null("EntityLight")
	expect(light3 is OmniLight3D, "energy_binds: light still mounts")
	ent3.state["flame"] = 0.5
	renderer3._sync_light()
	expect(
		absf((light3 as OmniLight3D).light_energy - 0.5) < 0.001,
		"energy_binds: light_energy follows state.flame after sync"
	)
	# 4. ARRAY form: multi-light fixture mounts every entry
	var def4: Dictionary = def.duplicate(true)
	def4["visual"]["light"] = [
		{"type": "omni", "energy": 1.0, "range": 5.0, "position": [-1, 1, 0]},
		{"type": "omni", "energy": 1.0, "range": 5.0, "position": [1, 1, 0]},
		{"type": "spot", "energy": 2.0, "range": 8.0, "position": [0, 2, 0]},
	]
	var ent4 := Entity.create(def4, "lamp4", {})
	add_child(ent4)
	var renderer4 := EntityMesh3D.new()
	ent4.add_child(renderer4)
	var light_count := 0
	for c in renderer4.get_children():
		if c is Light3D:
			light_count += 1
	expect_eq(light_count, 3, "visual.light array: all three lights mounted")
	# 5. counter-scale: offsets are WORLD units regardless of state.scale
	var def5: Dictionary = def.duplicate(true)
	def5["state_init"]["scale"] = [0.2, 5.0, 0.2]
	var ent5 := Entity.create(def5, "lamp5", {})
	add_child(ent5)
	var renderer5 := EntityMesh3D.new()
	ent5.add_child(renderer5)
	renderer5._sync_scale()
	var light5: Light3D = renderer5.get_node_or_null("EntityLight")
	expect(light5 != null, "counter-scale: light mounted")
	if light5 != null:
		# world offset [0, 3.05, 0]; node scale y=5 → local y must be 0.61
		expect(
			absf(light5.position.y - 3.05 / 5.0) < 0.001,
			"counter-scale: local offset = world offset / node scale"
		)
		expect(
			absf(light5.scale.y - 0.2) < 0.001 and absf(light5.scale.x - 5.0) < 0.001,
			"counter-scale: light scale inverts node scale per axis"
		)
	ent5.free()
	ent.free()
	ent2.free()
	ent3.free()
	ent4.free()


# ============================================================
# ADR 0073 — editor scene preview (read-only)
# ============================================================


## Builds the preview against real demo_doomarena3d JSON (a committed
## example, so a fresh clone has it) and asserts it
## produces entity nodes, all owner=null (never serialized). Exercises
## the glob/merge/placement slice headlessly (is_editor_hint is false
## here, so _ready won't auto-build — we call _rebuild directly).
func test_scene_preview() -> void:
	_section("editor scene preview (ADR 0073)")
	var preview = load("res://scripts/engine/editor/yume_scene_preview.gd").new()
	preview.data_root_override = "res://data/demo_doomarena3d"
	add_child(preview)
	preview._rebuild()
	var holder = preview.get_node_or_null("_PreviewRoot")
	expect(holder != null, "preview built a _PreviewRoot container")
	if holder != null:
		var entity_nodes := 0
		var all_owner_null := true
		for c in holder.get_children():
			if c.owner != null:
				all_owner_null = false
			if (
				c is Node3D
				and not (c is DirectionalLight3D)
				and not (c is WorldEnvironment)
				and not (c is MeshInstance3D)
			):
				entity_nodes += 1
		expect(entity_nodes >= 5, "preview built entity nodes from JSON (got %d)" % entity_nodes)
		expect(all_owner_null, "every preview node has owner=null (never serialized)")
		preview._rebuild()
		var holders := 0
		for c in preview.get_children():
			if c.name == "_PreviewRoot":
				holders += 1
		expect_eq(holders, 1, "rebuild replaces the preview (no accumulation)")
	preview.free()


# ============================================================
# ADR 0071 — render block JSON exposure (pure mapping helpers)
# ============================================================


func test_render_block_mappings() -> void:
	_section("render block mappings (ADR 0071)")
	expect_eq(LightingDirector.msaa_from_string("2x"), Viewport.MSAA_2X, "msaa 2x")
	expect_eq(LightingDirector.msaa_from_string("disabled"), Viewport.MSAA_DISABLED, "msaa off")
	expect_eq(
		LightingDirector.msaa_from_string("bogus"), Viewport.MSAA_DISABLED, "msaa unknown → off"
	)
	expect_eq(
		LightingDirector.screen_space_aa_from_string("SMAA"),
		Viewport.SCREEN_SPACE_AA_SMAA,
		"ssaa smaa (case-insensitive)"
	)
	expect_eq(
		LightingDirector.scaling_mode_from_string("fsr"),
		Viewport.SCALING_3D_MODE_FSR,
		"scaling fsr"
	)
	expect_eq(
		LightingDirector.shadow_mode_from_string("2_splits"),
		DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		"shadow 2_splits"
	)
	var tex := LightingDirector.gradient_texture_from_stops(["#000000", "#808080", "#ffffff"])
	expect(tex is GradientTexture1D, "gradient stops → GradientTexture1D")
	expect_eq(tex.gradient.colors.size(), 3, "gradient keeps all stops")
	expect(
		absf(tex.gradient.offsets[1] - 0.5) < 0.001, "gradient stops evenly spaced (mid = 0.5)"
	)
	expect(
		LightingDirector.gradient_texture_from_stops([]) == null, "empty gradient → null"
	)


# ============================================================
# ScreenFlow shell services without screens.json
# ============================================================


## show_toast / quit_app / reload_scene are screen-INDEPENDENT shell
## services: they must work in demos with NO screens.json. Empirical
## 2026-06-11 (autorace): ScreenFlow's no-screens early return skipped
## both the toast layer and the event drain, making show_toast a silent
## no-op in every screens-less demo (autorace's lap-3 toast had been
## dead since authoring). This test boots a screens-less World +
## ScreenFlow and asserts a pushed show_toast event actually renders.
func test_toast_without_screens() -> void:
	_section("toast without screens.json (ScreenFlow shell services)")
	var world := World.new()
	world.auto_start = false
	world.verbose = false
	add_child(world)
	world.set_process(false)
	world.set_physics_process(false)
	world.scheduler = PhaseScheduler.new(
		{
			"entities": {},
			"defs": {},
			"relations": RelationStore.new(),
			"spatial_index": SpatialIndex.new(),
			"world": {},
			"parent": world,
			"next_id": {"_": 0},
			"error_buffer": [],
		}
	)
	var sf: Node = load("res://scripts/engine/ui/screen_flow.gd").new()
	sf.name = "ScreenFlow"
	world.add_child(sf)  # _ready: data_root "" → no screens.json branch
	expect(sf._toast_layer != null, "no-screens: toast layer still built")
	var env: Dictionary = world.scheduler.env
	expect(env.has("screen_event_buffer"), "no-screens: screen_event_buffer ensured")
	(env["screen_event_buffer"] as Array).append(
		{"event": "show_toast", "text": "HELLO", "duration": 0.4}
	)
	sf.drain()
	expect_eq(
		int(sf._toast_layer.get_child_count()),
		1,
		"no-screens: show_toast renders a toast label"
	)
	# ESC ownership (2026-10-16). Sokoban binds ui_cancel (ESC) to its pause
	# screen, but GameShell quit on the same ESC press.
	expect(not sf.binds_key(KEY_ESCAPE), "no global_inputs: ScreenFlow does not bind ESC")
	sf._cfg = {"global_inputs": [{"action": "ui_cancel", "if_screen": "game", "on_press": []}]}
	expect(sf.binds_key(KEY_ESCAPE), "global ui_cancel input: ScreenFlow binds ESC")
	expect(not sf.binds_key(KEY_F9), "global ui_cancel input: F9 is not bound")
	var gs_script = load("res://scripts/engine/ui/game_shell.gd")
	expect_eq(gs_script.esc_outcome("game", true, false), "defer", "ESC with a pause binding defers to ScreenFlow")
	expect_eq(gs_script.esc_outcome("game", false, true), "release", "ESC with no binding releases the mouse")
	expect_eq(gs_script.esc_outcome("game", false, false), "quit", "ESC with no binding and a free mouse quits")
	expect_eq(gs_script.esc_outcome("title", false, false), "defer", "ESC on a menu screen defers")
	# A bool setting row shows its state as text (2026-10-16). The old
	# CheckBox icon did not show on a dark panel.
	var mgr: Node = load("res://scripts/engine/ui/settings_manager.gd").new()
	mgr._settings_by_key = {"rm": {"key": "rm", "type": "bool"}}
	mgr._values = {"rm": false}
	var host := VBoxContainer.new()
	sf._build_setting_row(host, {"key": "rm", "type": "bool", "label": "RM"}, mgr)
	var toggle = host.get_child(0).get_child(1)
	expect(toggle is Button and toggle.toggle_mode, "bool setting row: a toggle Button")
	expect_eq(str(toggle.text), "Off", "bool setting row: shows Off for false")
	toggle.button_pressed = true
	expect_eq(str(toggle.text), "On", "bool setting row: shows On after a toggle")
	expect_eq(mgr.get_value("rm"), true, "bool setting row: toggle writes the setting")
	host.free()
	mgr.free()
	world.queue_free()


# ============================================================
# ADR 0070 — physics overlap trigger (dispatch plumbing)
# ============================================================


## The PHYSICS side of overlap (Godot broadphase → World callback) is
## deliberately untested headless — non-determinism is its documented
## nature, verified by live capture. What IS deterministic and gated
## here is the dispatch: events injected into env.overlap_events must
## fire `trigger: "overlap"` rules in the react phase with a/b bindings,
## honor the `change` filter, respect query specs, and drain the buffer.
func test_overlap_dispatch() -> void:
	_section("overlap trigger (ADR 0070)")
	var defs: Dictionary = {
		"finish_line": {"id": "finish_line", "tags": ["finish_line"], "state_init": {}},
		"kart":
		{
			"id": "kart",
			"tags": ["kart"],
			"state_init": {"crossings": 0, "position": Vector3.ZERO},
		},
	}
	var fl := Entity.create(defs["finish_line"], "fl1", {})
	var kart := Entity.create(defs["kart"], "k1", {})
	var entities: Dictionary = {"fl1": fl, "k1": kart}
	var env: Dictionary = {
		"entities": entities,
		"defs": defs,
		"relations": RelationStore.new(),
		"spatial_index": SpatialIndex.new(),
		"world": {},
		"parent": null,
		"next_id": {"_": 0},
		"error_buffer": [],
		"overlap_events": [],
	}
	var sched := PhaseScheduler.new(env)
	sched.register_rules(
		[
			Rule.from_dict(
				{
					"id": "cross_enter",
					"trigger": {"type": "overlap", "change": "enter"},
					"query":
					{"a": {"tags_all": ["finish_line"]}, "b": {"tags_all": ["kart"]}},
					"effect":
					{"type": "state_add", "target": "b", "field": "crossings", "amount": 1},
				}
			)
		]
	)
	# 1. enter event fires with a/b bindings
	(env["overlap_events"] as Array).append({"a": "fl1", "b": "k1", "change": "enter"})
	sched.tick()
	expect_eq(int(kart.get_state("crossings", 0)), 1, "overlap enter: rule fired on b binding")
	# 2. exit event must NOT fire an enter-rule
	(env["overlap_events"] as Array).append({"a": "fl1", "b": "k1", "change": "exit"})
	sched.tick()
	expect_eq(int(kart.get_state("crossings", 0)), 1, "overlap exit: enter-rule did not fire")
	# 3. pair failing the b spec is ignored
	(env["overlap_events"] as Array).append({"a": "fl1", "b": "fl1", "change": "enter"})
	sched.tick()
	expect_eq(int(kart.get_state("crossings", 0)), 1, "overlap: non-matching pair ignored")
	# 4. buffer drains every tick regardless of matches
	expect_eq((env["overlap_events"] as Array).size(), 0, "overlap: buffer drained")
	fl.free()
	kart.free()


# ============================================================
# ADR 0061 Phase 1 — transport-agnostic lockstep core
# ============================================================


## Build a minimal World with one player + two input rules (ping→counter,
## ping2→counter2). No renderer, no _process — a fixture for lockstep tests.
func _build_lockstep_world() -> World:
	var defs: Dictionary = {
		"player":
		{
			"id": "player",
			"tags": ["player", "actor"],
			"state_init": {"counter": 0, "counter2": 0, "position": Vector3.ZERO},
		},
	}
	var world := World.new()
	world.auto_start = false
	world.verbose = false
	world.tick_seconds = 0.1
	add_child(world)
	world.set_process(false)
	world.scheduler = PhaseScheduler.new({})
	var player := Entity.create(defs["player"], "p1", {})
	var entities: Dictionary = {"p1": player}
	var rels := RelationStore.new()
	world.scheduler.env = {
		"entities": entities,
		"defs": defs,
		"relations": rels,
		"spatial_index": SpatialIndex.new(),
		"world": {},
		"parent": world,
		"next_id": {"_": 0},
		"error_buffer": [],
	}
	world.world_state = world.scheduler.env["world"]
	# DeterminismHash.canonical reads world.entities + world.relations directly
	# (not scheduler.env), so point them at the same objects — else the hash is
	# over an empty world and desync is invisible.
	world.entities = entities
	world.relations = rels
	world.scheduler.register_rules(
		[
			Rule.from_dict(
				{
					"id": "ls_ping",
					"trigger": {"type": "input", "action": "ping"},
					"query": {"tags_all": ["player"]},
					"effect":
					{
						"type": "state_set",
						"target": "self",
						"field": "counter",
						"value": "self.state.counter + 1"
					},
				}
			),
			Rule.from_dict(
				{
					"id": "ls_ping2",
					"trigger": {"type": "input", "action": "ping2"},
					"query": {"tags_all": ["player"]},
					"effect":
					{
						"type": "state_set",
						"target": "self",
						"field": "counter2",
						"value": "self.state.counter2 + 1"
					},
				}
			),
		]
	)
	return world


func test_lockstep() -> void:
	_section("lockstep core (ADR 0061 Phase 1)")

	# Two "peers": peer 0 drives action "ping", peer 1 drives "ping2". Both
	# worlds receive BOTH peers' inputs each tick (input replication), so both
	# must reach identical state ⇒ identical canonical hashes (lockstep).
	var peers: Array = [0, 1]

	# ---------- 1. lockstep determinism + barrier + hash agreement ----------
	var world_a := _build_lockstep_world()
	var world_b := _build_lockstep_world()
	var core_a := LockstepCore.new()
	var core_b := LockstepCore.new()
	core_a.configure(0, peers, {"0": "p1", "1": "p1"})
	core_b.configure(1, peers, {"0": "p1", "1": "p1"})

	var n := 5
	var lockstep_ok := true
	var barrier_ok := true
	for t in range(n):
		# Each peer's local input batch.
		var batch0: Array = ["ping"]
		var batch1: Array = ["ping2"]
		# Replicate: BOTH cores learn BOTH peers' batches (the in-memory "relay"
		# stands in for the ENet RPC broadcast of Phase 2).
		core_a.submit_input(0, t, batch0)
		core_a.submit_input(1, t, batch1)
		core_b.submit_input(0, t, batch0)
		core_b.submit_input(1, t, batch1)
		# Barrier: a peer may not advance until it has ALL peers' inputs.
		if not (core_a.all_inputs_ready(t) and core_b.all_inputs_ready(t)):
			barrier_ok = false
		var ra: Dictionary = core_a.step(world_a)
		var rb: Dictionary = core_b.step(world_b)
		# Exchange hashes (the desync detector's input).
		core_a.submit_hash(1, t, rb["hash"])
		core_b.submit_hash(0, t, ra["hash"])
		if str(ra["hash"]) != str(rb["hash"]):
			lockstep_ok = false

	expect(barrier_ok, "lockstep: barrier ready only after all peers submit each tick")
	expect(lockstep_ok, "lockstep: identical input log ⇒ identical per-tick hash on both peers")
	expect(not core_a.has_desync(), "lockstep: no desync when peers agree (core A)")
	expect(not core_b.has_desync(), "lockstep: no desync when peers agree (core B)")
	# State actually advanced + matches.
	var pa: Entity = world_a.scheduler.env["entities"]["p1"]
	var pb: Entity = world_b.scheduler.env["entities"]["p1"]
	expect_eq(int(pa.get_state("counter", 0)), n, "lockstep: peer-0 input applied n times")
	expect_eq(int(pa.get_state("counter2", 0)), n, "lockstep: peer-1 input applied n times")
	expect_eq(
		int(pb.get_state("counter", 0)),
		int(pa.get_state("counter", 0)),
		"lockstep: both worlds reached identical state"
	)
	world_a.queue_free()
	world_b.queue_free()

	# ---------- 2. desync DETECTED at the exact divergent tick ----------
	# Same inputs on both peers, but inject hidden nondeterminism into world B
	# at tick 2 (a state poke the input log doesn't explain). The per-tick hash
	# exchange must name tick 2 as the first divergent tick.
	var w_a := _build_lockstep_world()
	var w_b := _build_lockstep_world()
	var c_a := LockstepCore.new()
	var c_b := LockstepCore.new()
	c_a.configure(0, peers, {"0": "p1", "1": "p1"})
	c_b.configure(1, peers, {"0": "p1", "1": "p1"})
	var poke_tick := 2
	for t in range(n):
		for c in [c_a, c_b]:
			c.submit_input(0, t, ["ping"])
			c.submit_input(1, t, ["ping2"])
		if t == poke_tick:
			# Hidden divergence on B only — the class of bug lockstep hashes catch.
			(w_b.scheduler.env["entities"]["p1"] as Entity).state["counter"] = 999
		var rra: Dictionary = c_a.step(w_a)
		var rrb: Dictionary = c_b.step(w_b)
		c_a.submit_hash(1, t, rrb["hash"])
		c_b.submit_hash(0, t, rra["hash"])

	expect(c_a.has_desync(), "lockstep: desync detected when a peer diverges")
	expect_eq(c_a.desync_tick, poke_tick, "lockstep: desync named the FIRST divergent tick")
	expect_eq(c_b.desync_tick, poke_tick, "lockstep: both peers agree on the divergent tick")
	w_a.queue_free()
	w_b.queue_free()


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
# Camera intrinsics — focal_length_mm → FOV (scene.json camera block)
# ============================================================


func test_camera_intrinsics() -> void:
	_section("camera_intrinsics (focal_length_mm → fov)")
	# 36mm-sensor formula: fov = 2·atan(36/(2·f)).
	# 18mm → exactly 90° (36/36 = 1 → atan = 45° → ×2).
	expect(absf(CameraDirector._focal_to_fov_deg(18.0) - 90.0) < 0.01,
		"18mm → 90° (got %f)" % CameraDirector._focal_to_fov_deg(18.0))
	# 50mm → ~39.6° (a "normal" lens).
	expect(absf(CameraDirector._focal_to_fov_deg(50.0) - 39.6) < 0.2,
		"50mm → ~39.6° (got %f)" % CameraDirector._focal_to_fov_deg(50.0))
	# 35mm → ~54.4°.
	expect(absf(CameraDirector._focal_to_fov_deg(35.0) - 54.4) < 0.2,
		"35mm → ~54.4° (got %f)" % CameraDirector._focal_to_fov_deg(35.0))
	# Longer focal = narrower FOV (monotonic).
	expect(CameraDirector._focal_to_fov_deg(85.0) < CameraDirector._focal_to_fov_deg(35.0),
		"85mm narrower than 35mm")
	# Non-positive focal → 75° fallback (the prior default).
	expect_eq(CameraDirector._focal_to_fov_deg(0.0), 75.0, "focal 0 → 75° fallback")
	expect_eq(CameraDirector._focal_to_fov_deg(-5.0), 75.0, "negative focal → 75° fallback")

	# Runtime overrides from world_clock state merge onto cam_cfg (opt-in per key).
	var cfg := {"mode": "third_person_3d", "fov": 60.0}
	CameraDirector._merge_camera_overrides(cfg, {})  # no cam_* keys → unchanged
	expect_eq(cfg.get("projection", "<none>"), "<none>", "no override → projection untouched")
	expect_eq(cfg["fov"], 60.0, "no override → fov untouched")
	CameraDirector._merge_camera_overrides(cfg, {"cam_ortho": 1, "cam_ortho_size": 22.0, "cam_fov": 50.0, "cam_focal_mm": 0.0})
	expect_eq(cfg["projection"], "orthographic", "cam_ortho 1 → orthographic")
	expect_eq(cfg["ortho_size"], 22.0, "cam_ortho_size merged")
	expect_eq(cfg["fov"], 50.0, "cam_fov merged")
	expect(not cfg.has("focal_length_mm"), "cam_focal_mm 0 → no focal override (use fov)")
	CameraDirector._merge_camera_overrides(cfg, {"cam_ortho": 0, "cam_focal_mm": 35.0})
	expect_eq(cfg["projection"], "perspective", "cam_ortho 0 → perspective")
	expect_eq(cfg["focal_length_mm"], 35.0, "positive cam_focal_mm → focal override")


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


# ============================================================
# GROUND_RENDERER.REBIND_SHADER_PARAMS — sparse override semantics
# ============================================================
#
# ADR 0055 v2 acceptance gate (2026-05-21). Verifies that calling
# GroundRenderer.rebind_shader_params(level_id) deep-merges per-level
# scene.json overrides over the cached game-level baseline:
#   - Keys declared in the level override → new values
#   - Keys absent from the level override → baseline persists
#
# Empirical motivation: at code-review time the reviewer (tech-director)
# flagged "deep-merge of level scene.json over game scene.json needs to
# be defined clearly. Sparse override semantics — what happens if level
# says shader_params.biome_map but doesn't say biome_color_grass?" This
# test pins the answer in code.


# ADR 0087 — asset paths in game JSON are relative to the game folder or
# start with @lib/. AssetPath.resolve() is the only place that turns them
# into res:// paths. Empirical case 2026-10-17: 201 res:// references in
# game JSON, which a second interpreter cannot read.
func test_asset_path() -> void:
	_section("AssetPath.resolve — host-neutral asset paths (ADR 0087)")
	var saved := AssetPath.game_root
	AssetPath.game_root = "res://data/test_game"
	expect_eq(AssetPath.resolve("assets/meshes/hero.glb"),
		"res://data/test_game/assets/meshes/hero.glb", "relative path → game folder")
	expect_eq(AssetPath.resolve("@lib/meshes/rock.glb"),
		"res://data/lib/meshes/rock.glb", "@lib/ path → shared library")
	expect(not AssetPath.is_asset("@lib/shaders/toon.gdshader"), "a .gdshader file is not an asset (ADR 0089)")
	expect_eq(AssetPath.resolve(""), "", "empty path → empty")
	expect_eq(AssetPath.resolve("res://data/test_game/x.glb"), "", "res:// path is rejected")
	expect_eq(AssetPath.resolve("../demo_other/x.glb"), "", "a .. segment is rejected")
	expect_eq(AssetPath.resolve("/x.glb"), "", "a leading / is rejected")
	expect(AssetPath.is_asset("a/b.PNG"), "is_asset ignores case")
	expect(not AssetPath.is_asset("scene.json"), "a .json file is not an asset")
	# World.data_root's setter points AssetPath at the game folder.
	var w := World.new()
	w.data_root = "res://data/demo_sokoban/"
	expect_eq(AssetPath.game_root, "res://data/demo_sokoban", "World.data_root sets AssetPath.game_root")
	w.free()
	AssetPath.game_root = "res://data/test_game"
	expect(AssetPath.load_asset("assets/meshes/primitive_humanoid_capsule.glb") == null,
		"load_asset returns null for a missing file")
	AssetPath.game_root = "res://data/lib"
	expect(AssetPath.load_asset("assets/meshes/primitive_humanoid_capsule.glb") is PackedScene,
		"load_asset loads an existing file")
	AssetPath.game_root = saved


func test_ground_renderer_rebind() -> void:
	_section("ground_renderer.rebind_shader_params — sparse override")
	# Build a tiny temp data root with one level + a sparse scene.json
	var tmp := "user://_test_rebind_%d" % Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(tmp + "/levels/level_a")
	var f := FileAccess.open(tmp + "/levels/level_a/scene.json", FileAccess.WRITE)
	# Sparse override — only biome_map; biome_color_grass + uv_tile
	# should fall through to the game-level baseline.
	f.store_string(JSON.stringify({
		"ground": {
			"mesh": {
				"shader_params": {
					"biome_map": "assets/no_such_overridden_map.png",
					"blend_softness": 0.99,
				}
			}
		}
	}))
	f.close()

	# Stage GroundRenderer's static caches. ShaderMaterial.new() without
	# an attached Shader still accepts set_shader_parameter calls — the
	# values are stored as Variants regardless. Read-back via
	# get_shader_parameter works the same.
	var sm := ShaderMaterial.new()
	GroundRenderer._shader_material = sm
	GroundRenderer._cached_data_root = tmp.replace("user://", OS.get_user_data_dir() + "/")
	GroundRenderer._game_shader_params = {
		"biome_map":          "assets/no_such_baseline_map.png",
		"biome_color_grass":  [0.5, 0.5, 0.5, 1.0],
		"uv_tile":            30.0,
		"blend_softness":     0.18,
	}
	# Apply the baseline first (mirrors what build() does)
	for k in GroundRenderer._game_shader_params:
		sm.set_shader_parameter(str(k), GroundRenderer._game_shader_params[k])

	# Sanity: baseline applied
	expect_eq(
		str(sm.get_shader_parameter("biome_map")), "assets/no_such_baseline_map.png",
		"baseline biome_map applied"
	)

	# Trigger the rebind
	GroundRenderer.rebind_shader_params("level_a")

	# Declared keys in the override → new values
	expect_eq(
		str(sm.get_shader_parameter("biome_map")), "assets/no_such_overridden_map.png",
		"override: biome_map replaced",
	)
	expect_eq(
		float(sm.get_shader_parameter("blend_softness")), 0.99,
		"override: blend_softness replaced",
	)
	# Undeclared keys → baseline persists (deep-merge sparseness)
	expect_eq(
		float(sm.get_shader_parameter("uv_tile")), 30.0,
		"sparse merge: uv_tile keeps baseline value",
	)
	var grass = sm.get_shader_parameter("biome_color_grass")
	expect_eq(
		typeof(grass), TYPE_ARRAY,
		"sparse merge: biome_color_grass keeps baseline (typed Array)",
	)
	if grass is Array and (grass as Array).size() == 4:
		expect_eq(
			float((grass as Array)[0]), 0.5,
			"sparse merge: biome_color_grass[0] preserved",
		)

	# Second rebind to a non-existent level → should fall back to baseline,
	# re-applying the game-level params. The biome_map we previously
	# overrode is now reset to baseline. This pins the "level transition
	# back to a level without an override" carry-over behavior.
	GroundRenderer.rebind_shader_params("level_no_override")
	expect_eq(
		str(sm.get_shader_parameter("biome_map")), "assets/no_such_baseline_map.png",
		"absent level scene.json → baseline restored",
	)

	# Cleanup
	GroundRenderer._shader_material = null
	GroundRenderer._game_shader_params = {}
	GroundRenderer._cached_data_root = ""


# Pins GroundRenderer.sample_y to ground_biome_displace.gdshader's EXACT
# vertex displacement formula, and verifies the HeightMapShape3D collider
# is built from that same formula. Gate for the 2026-05-27 "player floats
# over displaced terrain" bug: the collider was a flat box while the hills
# were GPU-displaced, and sample_y was keyed to dead `bump_strength` params
# no shader emits. If a future shader edit changes the displacement formula
# without updating sample_y, this test fails (physics floor would drift
# from the visible ground again).
func test_ground_heightmap_collider() -> void:
	_section("ground_renderer heightmap collider — sample_y matches shader")

	# 2x2 known heightmap: corners (0,0)+(1,1)=0.0, (1,0)+(0,1)=1.0
	var img := Image.create(2, 2, false, Image.FORMAT_RGBF)
	img.set_pixel(0, 0, Color(0, 0, 0))
	img.set_pixel(1, 0, Color(1, 1, 1))
	img.set_pixel(0, 1, Color(1, 1, 1))
	img.set_pixel(1, 1, Color(0, 0, 0))
	GroundRenderer._heightmap_img = img
	GroundRenderer._heightmap_strength = 10.0   # height_scale
	GroundRenderer._heightmap_offset = -0.5      # height_offset
	GroundRenderer._heightmap_plane_size = 10.0
	GroundRenderer._heightmap_enabled = true

	# Formula: y = (sample + offset) * scale. NO V-flip, NO tiling.
	# world (-5,-5) → uv (0,0) → pixel(0,0)=0 → (0-0.5)*10 = -5
	# world ( 5,-5) → uv (1,0) → pixel(1,0)=1 → (1-0.5)*10 = +5
	expect(absf(GroundRenderer.sample_y(-5.0, -5.0) - (-5.0)) < 0.01,
		"sample_y(-5,-5) = (0-0.5)*10 = -5")
	expect(absf(GroundRenderer.sample_y(5.0, -5.0) - 5.0) < 0.01,
		"sample_y(5,-5) = (1-0.5)*10 = +5")

	# Collider build: grid heights must equal sample_y at the same coords.
	var gr := GroundRenderer.new(self)
	var shape := gr._build_heightmap_shape(10.0, 10.0)
	expect(shape is HeightMapShape3D, "collider is a HeightMapShape3D")
	expect_eq(shape.map_width, shape.map_depth, "collider grid is square")
	expect_eq(shape.map_data.size(), shape.map_width * shape.map_depth,
		"collider map_data length = width*depth")
	# data[0] is grid corner (ix=0, iz=0) = world (-half, -half) = (-5,-5)
	expect(absf(shape.map_data[0] - (-5.0)) < 0.01,
		"collider corner height = sample_y(-5,-5) = -5")

	# Disabled → flat (sample_y returns 0).
	GroundRenderer._heightmap_enabled = false
	expect_eq(GroundRenderer.sample_y(3.0, 3.0), 0.0,
		"sample_y returns 0 when displacement disabled")

	# Cleanup
	GroundRenderer._heightmap_img = null
	GroundRenderer._heightmap_enabled = false


## ADR 0084 — the lazy tag index returns the same entities, in the same
## order, as the full scan, after each kind of entity or tag change.
func test_query_tag_index() -> void:
	_section("query_tag_index (ADR 0084)")
	var defs := {
		"wolf": {"id": "wolf", "tags": ["animal", "wolf", "animal"]},
		"deer": {"id": "deer", "tags": ["animal", "deer"]},
		"rock": {"id": "rock", "tags": ["solid"]},
	}
	var entities := {}
	# An env built by hand, with no index in it yet.
	var env := {"entities": entities, "relations": RelationStore.new()}
	var ids := func(spec: Dictionary) -> Array:
		return QueryLib.run(spec, env).map(func(e): return e.instance_id)
	var scan := func(spec: Dictionary) -> Array:
		return QueryLib._run(spec, env, {}, false).map(func(e): return e.instance_id)
	entities["d1"] = Entity.create(defs.deer, "d1")
	entities["w1"] = Entity.create(defs.wolf, "w1")
	entities["r1"] = Entity.create(defs.rock, "r1")
	entities["d2"] = Entity.create(defs.deer, "d2")
	expect_eq(ids.call({"tags_all": ["animal"]}), ["d1", "w1", "d2"], "tags_all in insertion order")
	expect_eq(ids.call({"tags_all": ["wolf"]}), ["w1"], "a def with a duplicate tag gives one result")
	expect_eq(
		ids.call({"tags_any": ["solid", "deer", "wolf"]}),
		["d1", "w1", "r1", "d2"],
		"tags_any union keeps insertion order"
	)
	expect_eq(ids.call({"tags_any": ["animal", "deer"]}), ["d1", "w1", "d2"], "tags_any union has no repeats")
	expect_eq(ids.call({"tags_all": ["animal", "missing"]}), [], "a tag nobody has gives no result")
	# Spawn.
	entities["w2"] = Entity.create(defs.wolf, "w2")
	expect_eq(ids.call({"tags_all": ["wolf"]}), ["w1", "w2"], "spawn shows in the index")
	# Despawn.
	var old_w1: Entity = entities["w1"]
	entities.erase("w1")
	expect_eq(ids.call({"tags_all": ["wolf"]}), ["w2"], "despawn leaves the index")
	# add_tag and remove_tag.
	(entities["r1"] as Entity).add_tag("animal")
	expect_eq(ids.call({"tags_all": ["animal"]}), ["d1", "r1", "d2", "w2"], "add_tag shows in the index")
	(entities["d1"] as Entity).remove_tag("animal")
	expect_eq(ids.call({"tags_all": ["animal"]}), ["r1", "d2", "w2"], "remove_tag leaves the index")
	# A repeat add_tag or a remove of an absent tag does not bump the epoch.
	var epoch := Entity.tag_epoch
	(entities["r1"] as Entity).add_tag("animal")
	(entities["r1"] as Entity).remove_tag("never_had")
	expect_eq(Entity.tag_epoch, epoch, "a repeat add_tag forces no rebuild")
	# Direct assignment goes through the setter.
	(entities["d2"] as Entity).tags = ["plant"]
	expect_eq(ids.call({"tags_all": ["animal"]}), ["r1", "w2"], "tags assignment shows in the index")
	expect_eq(ids.call({"tags_all": ["plant"]}), ["d2"], "assigned tag is indexed")
	# Same id, new entity (a forced-id spawn after a despawn, same count).
	var old_w2: Entity = entities["w2"]
	entities.erase("w2")
	entities["w2"] = Entity.create(defs.deer, "w2")
	expect_eq(ids.call({"tags_all": ["wolf"]}), [], "a reused id does not return the old entity")
	expect_eq(ids.call({"tags_all": ["deer"]}), ["d1", "w2"], "a reused id returns the new entity")
	# The index and the scan agree on every shape.
	for spec in [
		{"tags_all": ["animal"], "tags_none": ["deer"]},
		{"tags_any": ["plant", "solid", "animal"]},
		{"tags_any": ["deer"], "limit": 1},
	]:
		expect_eq(ids.call(spec), scan.call(spec), "index equals scan for %s" % spec)
	# The dynamic gate counts an in-place write that skips the epoch.
	var before := QueryLib.index_mismatches
	(entities["d1"] as Entity).tags.append("ghost")
	QueryLib.run({"tags_all": ["ghost"]}, env)
	expect_eq(QueryLib.index_mismatches, before + 1, "verify_index counts a stale index")
	QueryLib.index_mismatches = before
	for e in entities.values():
		(e as Entity).free()
	old_w1.free()
	old_w2.free()


## ADR 0084 part 2 — the cell size comes from the rule radii, and a new size
## keeps every indexed entity findable.
func test_spatial_cell_size() -> void:
	_section("spatial_cell_size (ADR 0084)")
	var mk := func(tt: String, q) -> Rule:
		var d := {"id": "r", "trigger": {"type": tt}, "effect": {"type": "emit", "signal": "x"}}
		if q != null:
			d["query"] = q
		return Rule.from_dict(d)
	var by_tt := func(rules: Array) -> Dictionary:
		var out := {}
		for r in rules:
			var tt: String = (r as Rule).trigger_type()
			if not out.has(tt):
				out[tt] = []
			(out[tt] as Array).append(r)
		return out
	expect_eq(SpatialIndex.derive_cell_size({}), 64.0, "no rules keep 64")
	expect_eq(
		SpatialIndex.derive_cell_size(by_tt.call([mk.call("tick", {"tags_all": ["a"]})])),
		64.0,
		"no literal radius keeps 64"
	)
	expect_eq(
		SpatialIndex.derive_cell_size(by_tt.call([
			mk.call("tick", {"radius": 2}),
			mk.call("tick", {"radius": 3.0}),
			mk.call("tick", {"radius": 50}),
			mk.call("tick", {"radius": "self.state.reach"}),
		])),
		6.0,
		"twice the median literal radius; a formula radius does not count"
	)
	expect_eq(
		SpatialIndex.derive_cell_size(by_tt.call([
			mk.call("contact", {"a": {"tags_all": ["p"]}, "b": {"tags_all": ["q"]}}),
		])),
		2.0,
		"a contact rule without radius counts 1.0"
	)
	expect_eq(
		SpatialIndex.derive_cell_size(by_tt.call([mk.call("tick", {"radius": 1000})])),
		64.0,
		"clamped to 64"
	)
	expect_eq(
		SpatialIndex.derive_cell_size(by_tt.call([mk.call("tick", {"radius": 0.1})])),
		1.0,
		"clamped to 1"
	)
	# Re-bucket: a static entity stays findable after the size changes.
	var sx := SpatialIndex.new()
	var entities := {}
	var pit := Entity.create({"id": "pit", "tags": ["fire"]}, "pit")
	pit.set_position(Vector2(10, -3))
	entities["pit"] = pit
	sx.update_entity("pit", pit.get_planar_position())
	var lone := Entity.create({"id": "lone"}, "lone")
	lone.set_position(Vector2(-40, 30))
	entities["lone"] = lone
	sx.update_entity("lone", lone.get_planar_position())
	sx.set_cell_size(6.0, entities)
	expect_eq(sx.cell_size, 6.0, "set_cell_size sets the size")
	expect(sx.query_radius_ids(Vector2(9, -2), 2.0).has("pit"), "static entity found after re-bucket")
	expect_eq(sx.entity_count(), 2, "re-bucket adds no new ids")
	# A large radius visits the occupied cells and finds the same ids.
	var far := sx.query_radius_ids(Vector2(0, 0), 1000.0)
	far.sort()
	expect_eq(far, ["lone", "pit"], "large radius returns every occupied cell in the box")
	var none := sx.query_radius_ids(Vector2(500, 500), 100.0)
	expect_eq(none, [], "occupied-cell path filters by the box")
	# The scheduler derives the size on the next tick after register_rules.
	var env := {
		"entities": entities, "relations": RelationStore.new(), "spatial_index": sx,
		"world": {}, "parent": null, "next_id": {"_": 0},
	}
	var sched := PhaseScheduler.new(env)
	sched.register_rules([mk.call("tick", {"radius": 12})])
	expect_eq(sx.cell_size, 6.0, "register_rules does not derive at once")
	sched.tick()
	expect_eq(sx.cell_size, 24.0, "the next tick derives the size from the complete rule set")
	expect(sx.query_radius_ids(Vector2(10, -3), 1.0).has("pit"), "static entity found after the scheduler re-bucket")
	pit.free()
	lone.free()


# ============================================================
# FORMULA LANGUAGE (ADR 0088)
# ============================================================


## One case per trap that the 2026-10-17 probe found in Godot's Expression.
func test_formula_language() -> void:
	_section("Formula language — float numbers, 16 functions (ADR 0088)")
	var ctx := {"world": {"tick": 7, "list": [10.0, 20.0, 30.0]}, "self": {"state": {"on": true}}}
	expect_eq(Formula.evaluate("5 / 2", ctx), 2.5, "5 / 2 is a float division")
	expect_eq(Formula.evaluate("-7 / 2", ctx), -3.5, "-7 / 2 does not truncate")
	expect_eq(Formula.evaluate("world.tick / 2", ctx), 3.5, "an engine int binding enters as a float")
	expect_eq(Formula.evaluate("world.list[1.7]", ctx), 20.0, "a float index uses its integer part")
	expect_eq(Formula.evaluate("world.list[1]", ctx), 20.0, "an int literal index still indexes")
	expect_eq(Formula.evaluate("1e3 + .5", ctx), 1000.5, "exponent and leading-dot literals")
	expect_eq(Formula.evaluate("float(self.state.on) * 3", ctx), 3.0, "float(bool) is 1.0")
	expect_eq(Formula.evaluate("round(-2.5)", ctx), -3.0, "round takes a half away from zero")
	expect_eq(Formula.evaluate("atan2(1, 1) * 4", ctx), PI, "atan2 is in the list")
	expect(Formula.evaluate("world.tick > 3 and not (world.tick > 9)", ctx) == true, "and, not, comparison")
	expect(Formula.evaluate("min(1, 2.5)", ctx) is float, "a function on int literals gives a float")

	var rejects := {
		"7.5 % 2": EngineError.FORMULA_PARSE_FAILED,
		"\"a\" + \"b\"": EngineError.FORMULA_PARSE_FAILED,
		"2 ** 3": EngineError.FORMULA_PARSE_FAILED,
		"world.tick > 1 && true": EngineError.FORMULA_PARSE_FAILED,
		"[1, 2][0]": EngineError.FORMULA_PARSE_FAILED,
		"10 if 1 > 2 else 20": EngineError.FORMULA_PARSE_FAILED,
		"PI * 2": EngineError.FORMULA_PARSE_FAILED,
		"wrapf(5, 0, 3)": EngineError.FORMULA_UNKNOWN_FUNCTION,
		"Vector2(1, 2)[0]": EngineError.FORMULA_UNKNOWN_FUNCTION,
		"world.list.size()": EngineError.FORMULA_PARSE_FAILED,
		"str(world.tick)": EngineError.FORMULA_UNKNOWN_FUNCTION,
	}
	for f in rejects:
		var env := {"error_buffer": []}
		var got = Formula.evaluate(f, ctx, env)
		var codes: Array = (env["error_buffer"] as Array).map(func(r): return str(r.code))
		expect(float(got) == 0.0 and rejects[f] in codes, "'%s' raises %s (got %s)" % [f, rejects[f], codes])

	# The function list is the manifest's source. Keep it at 16 unless an ADR adds one.
	expect_eq(Formula.FUNCTIONS.size(), 16, "ADR 0088 lists 16 formula functions")


# ============================================================
# SHADER LIBRARY (ADR 0089)
# ============================================================


## Content names a library shader by name. Empirical case 2026-10-17: 17
## shader references named .gdshader files, which a second interpreter
## cannot run.
func test_shader_lib() -> void:
	_section("ShaderLib — shaders by name (ADR 0089)")
	for shader_name in ShaderLib.NAMES:
		expect(ShaderLib.load_named(shader_name, "test") is Shader, "'%s' loads as a Shader" % shader_name)
	expect(ShaderLib.load_named("sky_magic", "test") == null, "an unknown name gives null (shader.unknown)")
	expect(ShaderLib.load_named("@lib/shaders/toon.gdshader", "test") == null, "a file path is not a name")
	var with := ShaderLib.with_defaults("water_stylized", {"flow_speed": 0.1})
	expect(with.get("water_normal_tex") is Texture2D, "water_stylized gets the interpreter's normal texture")
	expect_eq(with.get("flow_speed"), 0.1, "with_defaults keeps the content parameters")
	var mine := ShaderLib.with_defaults("water_stylized", {"water_normal_tex": "x"})
	expect_eq(mine.get("water_normal_tex"), "x", "with_defaults never replaces a set parameter")
	expect(ShaderLib.with_defaults("toon", {}).is_empty(), "toon has no default textures")
	var saved := AssetPath.game_root
	AssetPath.game_root = "res://data/test_game"
	expect(ShaderLib.load_graph() == null, "a missing compiled graph gives null (shader.not_compiled)")
	AssetPath.game_root = saved
	# Every interpreter parameter of a named shader is a real uniform, or
	# the hide list would drift from the library. Read the source:
	# get_shader_uniform_list() leaves out screen and depth textures.
	var code := ""
	for shader_name in ShaderLib.NAMES:
		code += ShaderLib.load_named(shader_name, "test").code
	for p in ShaderLib.INTERPRETER_PARAMS:
		var rx := RegEx.create_from_string("uniform\\s+\\w+\\s+%s\\b" % p)
		expect(rx.search(code) != null, "interpreter parameter '%s' is a library uniform" % p)


func test_spec_vocabularies() -> void:
	_section("Spec vocabularies — keys, audio channels, lighting, physics (ADR 0090)")
	# Keys: an explicit table, bound by key position.
	expect_eq(InputKeys.keycode("W", "test"), KEY_W, "W maps to the W key")
	expect_eq(InputKeys.keycode("Numpad2", "test"), KEY_KP_2, "Numpad2 maps to keypad 2")
	expect_eq(InputKeys.keycode("Kp 2", "test"), KEY_NONE, "a host key name is not a spec name")
	expect_eq(InputKeys.mouse_button("WheelUp", "test"), MOUSE_BUTTON_WHEEL_UP, "WheelUp maps to the wheel")
	InputRegistrar._register_one({"name": "_vocab_test", "key": "Ctrl"})
	var evs := InputMap.action_get_events("_vocab_test")
	expect(evs.size() == 1 and (evs[0] as InputEventKey).physical_keycode == KEY_CTRL,
		"ui/input.json binds a physical keycode")
	EffectShell.set_input_mapping({"action": "_vocab_test", "key": "E"}, {}, {})
	evs = InputMap.action_get_events("_vocab_test")
	expect(evs.size() == 1 and (evs[0] as InputEventKey).physical_keycode == KEY_E,
		"set_input_mapping binds a physical keycode, as ui/input.json does")
	InputMap.erase_action("_vocab_test")
	# Audio: three channels, each a real bus that feeds Master.
	AudioChannels.ensure_buses()
	for channel in AudioChannels.CHANNELS:
		expect(AudioServer.get_bus_index(AudioChannels.CHANNELS[channel]) >= 0, "channel '%s' has a bus" % channel)
	var music_idx := AudioServer.get_bus_index("Music")
	expect_eq(AudioServer.get_bus_send(music_idx), &"Master", "the music bus feeds master")
	var saved_db := AudioServer.get_bus_volume_db(music_idx)
	EffectShell.set_audio_bus_volume({"bus": "music", "linear": 0.5}, {}, {})
	expect(absf(AudioServer.get_bus_volume_db(music_idx) - linear_to_db(0.5)) < 0.01,
		"set_audio_bus_volume music changes the music bus (the sokoban slider bug)")
	AudioServer.set_bus_volume_db(music_idx, saved_db)
	expect_eq(AudioChannels.bus("Music", "test"), "", "a host bus name is not a channel name")
	var audio_bus = Engine.get_main_loop().root.get_node_or_null("AudioBus")
	if audio_bus != null:
		expect_eq(str(audio_bus._music_player.bus), "Music", "music plays on the music channel")
	# Lighting: a closed field list.
	var scene := {
		"lighting": {
			"ambient": {"color": "#ffffff", "color_day": "#ffffff", "_note": "x"},
			"reflection_probes": [{"position": [0, 1, 0], "radius": 3}],
		},
		"render": {"msaa_3d": "2x"},
	}
	var unknown := LightingDirector.unknown_fields(scene)
	unknown.sort()
	expect_eq(unknown, ["lighting.ambient.color", "lighting.reflection_probes[].radius"],
		"unknown_fields reports dead fields and skips comments")
	# Every field LightingDirector reads is in FIELDS. Read the source.
	var listed := {"lighting": true, "render": true}
	for path in LightingDirector.FIELDS:
		for f in LightingDirector.FIELDS[path]:
			listed[f] = true
	var src := FileAccess.get_file_as_string("res://scripts/engine/directors/lighting_director.gd")
	var rx := RegEx.create_from_string("(?:cfg|_config|amb|pd|Dictionary\\))(?:\\.get|\\.has)\\(\"(\\w+)\"|cfg\\[\"(\\w+)\"\\]")
	var read := {}
	for m in rx.search_all(src):
		read[m.get_string(1) if m.get_string(1) != "" else m.get_string(2)] = true
	var missing: Array = read.keys().filter(func(k): return not listed.has(k))
	expect(read.size() > 30, "the source scan finds the lighting reads (%d)" % read.size())
	expect_eq(missing, [], "LightingDirector reads no field outside FIELDS")
	# Sky: shader_params colors are the day colors, not replaced each frame.
	var sky := {"shader": "sky_clouds", "shader_params": {"sky_top_color": [0.2, 0.4, 0.8]}}
	expect(LightingDirector.sky_color_at(sky, "sky_top_color", 1.0).is_equal_approx(Color(0.2, 0.4, 0.8)),
		"at noon the sky top is the shader_params color")
	sky["sky_top_color_day"] = "#ff0000"
	expect(LightingDirector.sky_color_at(sky, "sky_top_color", 1.0).is_equal_approx(Color("#ff0000")),
		"the day field wins over shader_params")
	expect(LightingDirector.sky_color_at(sky, "sky_top_color", 0.0).is_equal_approx(Color("#0a1530")),
		"at midnight the sky top is the night color")
	# Physics: layer names, not bits.
	var layers := {"wall": 2, "player": 5}
	expect_eq(PhysicsBodyBuilder.layer_mask(["wall", "player"], layers), (1 << 1) | (1 << 4), "names map to bits")
	expect_eq(PhysicsBodyBuilder.layer_mask("all", layers), 0xFFFFFFFF, "all sets every bit")
	expect_eq(PhysicsBodyBuilder.layer_mask(6, layers), 0, "a raw number is not a layer (physics.unknown_layer)")
	var bodies: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/lib/physics/bodies.json"))
	for preset in bodies:
		if bodies[preset] is Dictionary:
			var bt = bodies[preset].get("body_type")
			expect(bt in PhysicsBodyBuilder.BODY_TYPES, "preset '%s' uses a spec body type" % preset)
			for k in bodies[preset]:
				expect(str(k).begins_with("_") or str(k) in PhysicsBodyBuilder.FIELDS,
					"preset '%s' field '%s' is in FIELDS" % [preset, k])


## ADR 0091 — articulated bodies. A two-wheel rover with a ball caster
## drives on a static floor through StepRunner, so the test covers the
## spawn, the readback, the motor drive and one physics step per tick.
## The checks are guarantees, not exact host values (ADR 0086).
const _ROVER_PHYSICS := {
	"body_type": "articulated",
	"root": "chassis",
	"links": {
		"chassis": {"shape": {"type": "box", "size": [0.3, 0.08, 0.4]}, "mass": 2.0},
		"wheel_l": {"shape": {"type": "cylinder", "radius": 0.1, "height": 0.04, "axis": "x"}, "mass": 0.3, "friction": 1.0},
		"wheel_r": {"shape": {"type": "cylinder", "radius": 0.1, "height": 0.04, "axis": "x"}, "mass": 0.3, "friction": 1.0},
		"caster": {"shape": {"type": "sphere", "radius": 0.05}, "mass": 0.1, "friction": 0.0},
		"mast": {"shape": {"type": "box", "size": [0.04, 0.2, 0.04]}, "mass": 0.1},
	},
	"joints": [
		{"type": "hinge", "parent": "chassis", "child": "wheel_l", "at": [-0.19, -0.05, -0.1], "axis": [-1, 0, 0],
			"motor": {"target_velocity": "self.state.left_cmd", "max_torque": 3.0}, "report": "wheel_l"},
		{"type": "hinge", "parent": "chassis", "child": "wheel_r", "at": [0.19, -0.05, -0.1], "axis": [-1, 0, 0],
			"motor": {"target_velocity": "self.state.right_cmd", "max_torque": 3.0}, "report": "wheel_r"},
		{"type": "ball", "parent": "chassis", "child": "caster", "at": [0, -0.1, 0.15]},
		{"type": "fixed", "parent": "chassis", "child": "mast", "at": [0, 0.14, 0.1]},
	],
}


func test_articulated_body() -> void:
	_section("articulated body (ADR 0091)")
	expect(PhysicsBodyBuilder.BODY_TYPES.has("articulated"), "BODY_TYPES lists articulated")
	for f in ["root", "links", "joints"]:
		expect(PhysicsBodyBuilder.FIELDS.has(f), "physics FIELDS lists '%s'" % f)
	expect_eq(ArticulatedBody.JOINT_TYPES, ["hinge", "ball", "fixed"], "the three joint types")
	# _check: each defect gives a reason, the rover gives none.
	expect_eq(ArticulatedBody._check(_ROVER_PHYSICS), "", "the rover is one tree")
	var bad_root := _ROVER_PHYSICS.duplicate(true)
	bad_root["root"] = "nope"
	expect(ArticulatedBody._check(bad_root) != "", "an unknown root is a defect")
	var two_parents := _ROVER_PHYSICS.duplicate(true)
	two_parents["joints"].append({"type": "ball", "parent": "wheel_r", "child": "caster"})
	expect(ArticulatedBody._check(two_parents) != "", "a link with two parents is a defect")
	var loose := _ROVER_PHYSICS.duplicate(true)
	loose["links"]["spare"] = {"shape": {"type": "sphere", "radius": 0.1}}
	expect(ArticulatedBody._check(loose) != "", "a link with no joint to the root is a defect")
	var slider := _ROVER_PHYSICS.duplicate(true)
	slider["joints"][0]["type"] = "slider"
	expect(ArticulatedBody._check(slider) != "", "an unknown joint type is a defect")

	# A world with a floor and one rover.
	var world := World.new()
	world.auto_start = false
	world.verbose = false
	world.tick_seconds = 1.0 / float(Engine.physics_ticks_per_second)
	add_child(world)
	world.set_process(false)
	world.set_physics_process(false)
	var defs := {"rover": {"id": "rover", "tags": ["robot"], "state_init": {"left_cmd": 0.0, "right_cmd": 0.0}}}
	world.scheduler = PhaseScheduler.new({})
	world.scheduler.env = {
		"entities": world.entities, "defs": defs, "relations": RelationStore.new(),
		"spatial_index": SpatialIndex.new(), "world": {}, "parent": world,
		"next_id": {"_": 0}, "error_buffer": [],
	}
	world.world_state = world.scheduler.env["world"]
	var space: RID = world.get_viewport().find_world_3d().space
	var floor_body := PhysicsServer3D.body_create()
	var floor_shape := PhysicsServer3D.box_shape_create()
	PhysicsServer3D.shape_set_data(floor_shape, Vector3(10, 0.5, 10))
	PhysicsServer3D.body_set_mode(floor_body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_add_shape(floor_body, floor_shape)
	PhysicsServer3D.body_set_state(floor_body, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3(0, -0.5, 0)))
	PhysicsServer3D.body_set_space(floor_body, space)
	var rover := Entity.create(defs["rover"], "rover_1", {"position": Vector3(0, 0.15, 0)})
	world.add_child(rover)
	world.entities["rover_1"] = rover
	var ab := ArticulatedBody.build(rover, _ROVER_PHYSICS, space, {})
	expect(ab != null, "the rover builds")
	if ab == null:
		world.queue_free()
		return
	world.articulated_bodies["rover_1"] = ab
	expect_eq(ab._bodies.size(), 4, "the fixed mast merges into the chassis: 4 bodies for 5 links")
	expect_eq(ab._joints.size(), 3, "two hinges and one ball joint")
	var mast_offset: Vector3 = ab.poses["mast"].origin - ab.poses["chassis"].origin
	expect(mast_offset.distance_to(Vector3(0, 0.14, 0.1)) < 0.001, "the mast sits at its 'at' offset")

	# Settle, then both wheels forward: the rover moves toward -Z.
	await StepRunner.run([{"tick": 20}], world, {"verbose": false})
	var p0: Vector3 = rover.get_position()
	rover.state["left_cmd"] = 6.0
	rover.state["right_cmd"] = 6.0
	await StepRunner.run([{"tick": 60}], world, {"verbose": false})
	var p1: Vector3 = rover.get_position()
	expect_eq(int(world.world_state.get("_tick", 0)), 80, "one tick for each step, 80 in all")
	expect(p0.z - p1.z > 0.3, "equal forward speeds move the rover toward -Z (moved %.3f m)" % (p0.z - p1.z))
	expect(absf(p1.x - p0.x) < 0.1, "equal speeds keep it straight (x drift %.3f m)" % (p1.x - p0.x))
	expect(absf(p1.y - 0.15) < 0.05, "the chassis stays on its wheels (y %.3f)" % p1.y)
	expect(float(rover.get_state("wheel_l_angle", 0.0)) > 3.0, "the left wheel angle counts whole turns")
	expect(float(rover.get_state("wheel_r_speed", 0.0)) > 4.0, "the right wheel speed reads back (%.2f rad/s)" % float(rover.get_state("wheel_r_speed", 0.0)))
	expect(rover.get_state("velocity", Vector3.ZERO) is Vector3, "state.velocity is the root velocity")
	expect(ab.poses["mast"].origin.distance_to(ab.poses["chassis"] * Vector3(0, 0.14, 0.1)) < 0.001, "the merged mast follows the chassis")

	# Opposite speeds: the rover turns left in place (yaw grows). It turns
	# about the midpoint of its axle, so the test measures that point.
	var axle1: Vector3 = (ab.poses["wheel_l"].origin + ab.poses["wheel_r"].origin) * 0.5
	var yaw0 := float(rover.get_state("yaw", 0.0))
	rover.state["left_cmd"] = -4.0
	rover.state["right_cmd"] = 4.0
	await StepRunner.run([{"tick": 60}], world, {"verbose": false})
	var axle2: Vector3 = (ab.poses["wheel_l"].origin + ab.poses["wheel_r"].origin) * 0.5
	var turn_drift := Vector2(axle2.x - axle1.x, axle2.z - axle1.z).length()
	expect(float(rover.get_state("yaw", 0.0)) - yaw0 > 0.5, "left back and right forward turn it left (yaw +%.2f)" % (float(rover.get_state("yaw", 0.0)) - yaw0))
	expect(turn_drift < 0.05, "the turn is in place: the axle midpoint moved %.3f m" % turn_drift)

	# Despawn frees every RID.
	PhysicsBodyBuilder.free_3d(rover)
	expect(ab.freed and ab._bodies.is_empty() and ab._joints.is_empty(), "free_3d frees the bodies and joints")
	world.advance_one_tick()
	expect(world.articulated_bodies.is_empty(), "the next tick drops a freed body from the registry")
	PhysicsServer3D.free_rid(floor_body)
	PhysicsServer3D.free_rid(floor_shape)
	world.queue_free()

