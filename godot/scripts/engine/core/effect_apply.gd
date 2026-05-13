extends RefCounted
class_name EffectApply

## Primitive #5 — Effect (application side).
##
## Contract: docs/30_framework_primitives.md §5
##
## `apply(effect, env, context)` mutates the world to fulfill one effect dict.
## The calling phase scheduler (W1.8) decides *when* to apply (commit vs react)
## and in what order. This module is purely about *how*.
##
## `env` carries mutable engine services:
##   env.entities    : Dictionary (instance_id → Entity)
##   env.relations   : RelationStore
##   env.defs        : Dictionary (def_id → entity definition)
##   env.parent      : Node  — parent node for spawned entity children (the
##                             scene's entity root). Node2D expected.
##   env.next_id     : Dictionary {"_": int} — spawn-id counter (shared ref)
##
## `context` carries per-rule bindings: `self`, `a`, `b`, input-payload keys.
##
## W1 scope:
##   state_set, state_add, state_mul, state_clamp,
##   spawn, remove, transform,
##   relate, unrelate, transfer_relation,
##   tag_add, tag_remove.
##
## Deferred:
##   velocity_set (W2 — motion tick lives alongside)
##   emit         (W2 — signal scheduler wires outbound queue)
##   formula-valued numeric fields (W4 — formula.gd wrapper)

# ============================================================
# PUBLIC
# ============================================================


## Apply a single effect. Returns a side-effect record for the scheduler to
## consume (e.g. emitted signals); empty dict if none.
static func apply(effect: Dictionary, env: Dictionary, context: Dictionary) -> Dictionary:
	var type: String = str(effect.get("type", ""))
	match type:
		"state_set":
			EffectCore.state_set(effect, env, context)
		"state_add":
			EffectCore.state_add(effect, env, context)
		"state_mul":
			EffectCore.state_mul(effect, env, context)
		"state_clamp":
			EffectCore.state_clamp(effect, env, context)
		# ADR 0031 — aggregated zone-state primitive
		"zone_state_set":
			EffectCore.zone_state_set(effect, env, context)
		"zone_state_add":
			EffectCore.zone_state_add(effect, env, context)
		"zone_state_clamp":
			EffectCore.zone_state_clamp(effect, env, context)
		"spawn":
			return EffectCore.spawn(effect, env, context)
		"remove":
			EffectCore.remove(effect, env, context)
		"transform":
			return EffectCore.transform(effect, env, context)
		"relate":
			EffectCore.relate(effect, env, context)
		"unrelate":
			EffectCore.unrelate(effect, env, context)
		"transfer_relation":
			EffectCore.transfer_relation(effect, env, context)
		"tag_add":
			EffectCore.tag_add(effect, env, context)
		"tag_remove":
			EffectCore.tag_remove(effect, env, context)
		"velocity_set":
			EffectMotion.velocity_set(effect, env, context)
		"velocity_lerp":
			EffectMotion.velocity_lerp(effect, env, context)
		"velocity_set_relative":
			EffectMotion.velocity_set_relative(effect, env, context)
		"velocity_add_relative":
			EffectMotion.velocity_add_relative(effect, env, context)
		"pathfind_to":
			EffectMotion.pathfind_to(effect, env, context)
		"raycast_hit":
			EffectMotion.raycast_hit(effect, env, context)
		"transition_level":
			EffectShell.transition_level(effect, env, context)
		"emit":
			EffectCore.emit(effect, env, context)
		"emit_shell_event":
			EffectCore.emit_shell_event(effect, env, context)
		"transition_screen":
			EffectShell.transition_screen(effect, env, context)
		"quit_app":
			EffectShell.quit_app(effect, env, context)
		"show_toast":
			EffectShell.show_toast(effect, env, context)
		"reload_scene":
			EffectShell.reload_scene(effect, env, context)
		"scene_change":
			EffectShell.scene_change(effect, env, context)
		"screen_fade":
			EffectShell.screen_fade(effect, env, context)
		"save_state":
			EffectShell.save_state(effect, env, context)
		"load_state":
			EffectShell.load_state(effect, env, context)
		"show_overlay":
			EffectShell.show_overlay_effect(effect, env, context)
		"dismiss_overlay":
			EffectShell.dismiss_overlay_effect(effect, env, context)
		"set_audio_bus_volume":
			EffectShell.set_audio_bus_volume(effect, env, context)
		"set_input_mapping":
			EffectShell.set_input_mapping(effect, env, context)
		"switch_actor":
			EffectActor.switch_actor(effect, env, context)
		"queue_input_for_actor":
			EffectActor.queue_input_for_actor(effect, env, context)
		"reset_world":
			EffectActor.reset_world(effect, env, context)
		"party_join":
			EffectActor.party_join(effect, env, context)
		"party_leave":
			EffectActor.party_leave(effect, env, context)
		"party_ko":
			EffectActor.party_ko(effect, env, context)
		"build_place":
			return _build_place(effect, env, context)
		"switch_class":
			return _switch_class(effect, env, context)
		# ADR 0032 — faction primitive
		"declare_war":
			return _declare_war(effect, env, context)
		"sign_treaty":
			return _sign_treaty(effect, env, context)
		"propose_alliance":
			return _propose_alliance(effect, env, context)
		"swear_loyalty":
			return _swear_loyalty(effect, env, context)
		# ADR 0033 — tech-tree primitive
		"try_discover_tech":
			return _try_discover_tech(effect, env, context)
		"learn_from_master":
			return _learn_from_master(effect, env, context)
		"pass_to_apprentice":
			return _pass_to_apprentice(effect, env, context)
		# ADR 0034 — dynasty / heir succession primitive
		"transfer_inventory":
			return _transfer_inventory(effect, env, context)
		"transfer_reputation":
			return _transfer_reputation(effect, env, context)
		"transfer_techs":
			return _transfer_techs(effect, env, context)
		"transition_player_to":
			return _transition_player_to(effect, env, context)
		_:
			EngineError.raise(
				env,
				EngineError.EFFECT_UNKNOWN_TYPE,
				"Unknown effect type: '%s'" % type,
				{"rule_id": context.get("_rule_id", ""), "field": "effect.type", "got": type},
				(
					"Use one of: state_set, state_add, state_mul, state_clamp,"
					+ " zone_state_set, zone_state_add, zone_state_clamp, spawn, remove,"
					+ " transform, relate, unrelate, transfer_relation, tag_add, tag_remove,"
					+ " velocity_set, velocity_lerp, velocity_set_relative,"
					+ " velocity_add_relative, pathfind_to, raycast_hit, transition_level,"
					+ " emit, emit_shell_event, transition_screen, quit_app, show_toast,"
					+ " reload_scene, scene_change, screen_fade, save_state, load_state,"
					+ " show_overlay, dismiss_overlay, set_audio_bus_volume,"
					+ " set_input_mapping, switch_actor, queue_input_for_actor, reset_world,"
					+ " party_join, party_leave, party_ko, build_place, switch_class,"
					+ " declare_war, sign_treaty, propose_alliance, swear_loyalty,"
					+ " try_discover_tech, learn_from_master, pass_to_apprentice,"
					+ " transfer_inventory, transfer_reputation, transfer_techs,"
					+ " transition_player_to."
				),
				"warning"
			)
	return {}


# ============================================================
# BUILD_PLACE (ADR 0037)
# ============================================================
#
# Validates a candidate placement against a fixed predicate set, then
# either spawns the entity (delegating to _spawn for renderer attach +
# spatial-index registration + spawn-trigger dispatch — same lifecycle
# as any other spawn) or fires `on_invalid` with the failure reason
# bound into ctx as `failure_reason`.
#
# CRITICAL: this is the engine's 穿模-prevention gate. Every placement
# touched at runtime MUST go through here, not raw `spawn`, so that
# overlap / range / ground / boundary failures are caught BEFORE the
# new entity enters the spatial index. See ADR 0037 §"Resolution flow".
#
# Predicates are coded in build_validators.gd and are NOT extensible
# from JSON — adding a fifth predicate requires a primitive-expansion
# ADR (per ADR 0021 / 0028 operator-surface reasoning).
#
# Out-of-scope for this implementation (per task spec):
#   - Ghost-mesh PREVIEW rendering. The ADR proposes a separate
#     build_preview_widget.gd Control for cursor-driven UIs. Phase 1's
#     player Build verb uses the simpler "build immediately if valid,
#     show toast if not" UX without a per-frame ghost. Future work,
#     visual gate applies.
#   - Multi-tick construction TICKING. Engine tags the spawned entity
#     `under_construction` and seeds state.build_in_progress when
#     construction_ticks > 0; the per-tick decrement + finalize rules
#     are content (per ADR 0037 §"Multi-tick construction" — Invariant
#     #2 forbids semantic effect names like complete_construction).


## Apply each effect in a chain (Array-of-Dict). Used by build_place's
## on_success / on_invalid sub-effects. Sub-effect failures don't abort
## the chain — same semantics as a top-level effect array on a rule.
static func _apply_chain(chain, env: Dictionary, ctx: Dictionary) -> void:
	if chain == null:
		return
	if chain is Dictionary:
		# Single effect (not wrapped in an array) — accept and apply.
		apply(chain, env, ctx)
		return
	if not (chain is Array):
		return
	for sub in chain as Array:
		if sub is Dictionary:
			apply(sub, env, ctx)


## Validate placement, then spawn the blueprint via the existing _spawn
## path. Returns {placed: bool, instance_id: String, reason: String}.
##
## reason is "" on success, "no_def" if blueprint is unknown, otherwise
## the predicate name that failed (mirrors ADR test plan).
static func _build_place(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var defs: Dictionary = env.get("defs", {})
	var blueprint := str(EffectResolution.value(e.get("blueprint", ""), ctx, env))
	if not defs.has(blueprint):
		EngineError.raise(
			env,
			EngineError.EFFECT_BUILD_PLACE_NO_DEF,
			"build_place: no def '%s'" % blueprint,
			{
				"rule_id": ctx.get("_rule_id", ""),
				"field": "effect.blueprint",
				"got": blueprint,
				"known_defs": defs.keys()
			},
			(
				"Add a definition with id '%s' to entities.json, or fix the build_place blueprint."
				% blueprint
			)
		)
		# Per ADR 0037 test_no_def_error: neither on_success nor on_invalid
		# fires when the def is missing — the structural error short-circuits.
		return {"placed": false, "reason": "no_def", "instance_id": ""}

	var def: Dictionary = defs[blueprint]
	var pos = EffectResolution.position(e.get("position", [0, 0, 0]), env, ctx)
	# Coerce to Vector3 — predicates assume 3D.
	var pos3: Vector3 = Vec3Util.from_world_pos(pos)
	var yaw := float(EffectResolution.value(e.get("yaw", 0.0), ctx, env))
	# ADR 0038: snap position + yaw to grid BEFORE running validation
	# predicates. Means `no_overlap` checks the snapped cell, so authors
	# can pass continuous cursor coords and the engine guarantees the
	# placed entity lands on a grid cell. No-op when grid disabled.
	if GridSnap.should_snap(def, env):
		pos3 = GridSnap.snap_position(pos3, env)
		yaw = GridSnap.snap_yaw(yaw, env)
	var owner_binding := str(e.get("owner", "self"))
	var max_range := float(EffectResolution.value(e.get("max_range", 5.0), ctx, env))
	var validate = e.get("validate", [])
	if not (validate is Array):
		validate = []

	# Stash per-effect predicate options so build_validators can read them
	# (e.g. ground_check_radius). Kept on env so we don't change the
	# predicate signature for one-off knobs.
	var prior_opts = env.get("_build_place_options", null)
	env["_build_place_options"] = {
		"ground_check_radius": float(e.get("ground_check_radius", 0.5)),
		"ground_y_tolerance": float(e.get("ground_y_tolerance", 0.5)),
	}

	# Run predicates left-to-right; first failure short-circuits and the
	# `failure_reason` propagates into the on_invalid context.
	var failure_reason: String = ""
	for pname in validate:
		var pname_s := str(pname)
		var result: Dictionary = BuildValidators.check(
			pname_s, def, pos3, yaw, owner_binding, max_range, env, ctx
		)
		if not bool(result.get("ok", false)):
			failure_reason = str(result.get("reason", pname_s))
			break

	# Restore prior options (or clear if absent) so the env is clean.
	if prior_opts == null:
		env.erase("_build_place_options")
	else:
		env["_build_place_options"] = prior_opts

	var sub_ctx: Dictionary = ctx.duplicate()
	if failure_reason != "":
		# Surface failure through env.error_buffer for qa-tester; severity
		# warning so authors see the issue without aborting headless runs.
		(
			EngineError
			. raise(
				env,
				EngineError.EFFECT_BUILD_PLACE_INVALID,
				(
					"build_place: predicate '%s' rejected placement of '%s' at %s"
					% [failure_reason, blueprint, str(pos3)]
				),
				{
					"rule_id": ctx.get("_rule_id", ""),
					"field": "effect.validate",
					"predicate": failure_reason,
					"blueprint": blueprint,
					"position": str(pos3)
				},
				"This is a normal validation failure — wire on_invalid to refund cost / show a toast / clear build mode.",
				"warning"
			)
		)
		sub_ctx["failure_reason"] = failure_reason
		_apply_chain(e.get("on_invalid", []), env, sub_ctx)
		return {"placed": false, "reason": failure_reason, "instance_id": ""}

	# Validation passed → delegate to _spawn for renderer attach + spatial
	# index registration + spawn-trigger dispatch (same lifecycle as any
	# other spawn).
	var spawn_overrides: Dictionary = {"state": {"yaw": yaw}}
	var construction_ticks := int(EffectResolution.value(e.get("construction_ticks", 0), ctx, env))
	if construction_ticks > 0:
		(spawn_overrides["state"] as Dictionary)["build_in_progress"] = construction_ticks
		(spawn_overrides["state"] as Dictionary)["build_progress_target"] = construction_ticks
		spawn_overrides["tags"] = ["under_construction"]
	var spawn_effect: Dictionary = {
		"type": "spawn",
		"template": blueprint,
		"position": pos3,
		"overrides": spawn_overrides,
	}
	var spawn_result: Dictionary = EffectCore.spawn(spawn_effect, env, ctx)
	var inst_id: String = str(spawn_result.get("spawned_id", ""))

	# Fire on_success chain. Note: spawn-trigger rules already fired during
	# _spawn's dispatch_lifecycle("spawn", inst_id) call — on_success is the
	# author's hook for build-specific cleanup (e.g. clear build_blueprint
	# state, decrement resource cost, emit a build-specific signal).
	sub_ctx["spawned_id"] = inst_id
	sub_ctx["build_id"] = inst_id
	_apply_chain(e.get("on_success", []), env, sub_ctx)
	return {"placed": true, "reason": "", "instance_id": inst_id}


# ============================================================
# CLASS / OCCUPATION (ADR 0030)
# ============================================================


## switch_class — atomic occupation swap on a player-actor entity.
##
## Effect dict shape:
##   {
##     "type": "switch_class",
##     "target": "self",           # entity-binding key OR literal id;
##                                 # default "self".
##     "to_class": "warrior",      # class id (string OR formula resolving
##                                 # to a string).
##     "cooldown_days": 1,         # optional, default 1. Set 0 to bypass.
##     "on_failure_signal": "..."  # optional. If set AND validation fails,
##                                 # emit this signal with reason payload
##                                 # so game-rules can surface a toast.
##   }
##
## Returns {ok, reason, from, to, instance_id} for the scheduler to
## record. Per ADR 0030 §effect-chain ordering, switch_class is
## NON-DESTRUCTIVE — composes safely in any chain position.
##
## ClassManager (sibling Node under World) hosts the registered class
## defs and the validation logic. effect_apply locates it via the env's
## parent reference. If no ClassManager is mounted (test harnesses
## without a SceneTree, OR demos that never registered any classes),
## the effect logs a warning and no-ops.
static func _switch_class(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	# Resolve target — same convention as EffectResolution.target() but we need the id
	# string, not the Entity, so we can pass it to ClassManager.switch_class.
	var target_key := str(e.get("target", "self"))
	var target_id := str(ctx.get(target_key, target_key))
	var to_class := str(EffectResolution.value(e.get("to_class", ""), ctx, env))
	var cooldown_days: int = int(EffectResolution.value(e.get("cooldown_days", 1), ctx, env))
	# Locate ClassManager. World is env.parent; ClassManager is a
	# named sibling under it.
	var cm: Node = null
	var parent_node = env.get("parent", null)
	if parent_node is Node:
		cm = (parent_node as Node).get_node_or_null("ClassManager")
	if cm == null or not cm.has_method("switch_class"):
		EngineError.raise(
			env,
			EngineError.CLASS_SWITCH_NO_DEF,
			"switch_class: no ClassManager mounted under World",
			{"rule_id": ctx.get("_rule_id", ""), "target": target_id, "to_class": to_class},
			"Add ClassManager Node sibling under World in play.tscn (per ADR 0030).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager", "from": "", "to": to_class}
	var result: Dictionary = cm.call("switch_class", env, target_id, to_class, cooldown_days)
	# On failure, optionally emit on_failure_signal so game-rules can react.
	if not bool(result.get("ok", false)):
		var fail_sig := str(e.get("on_failure_signal", ""))
		if fail_sig != "":
			var buf = env.get("signal_buffer", null)
			if buf is Array:
				(
					(buf as Array)
					. append(
						{
							"name": fail_sig,
							"payload":
							{
								"target": target_id,
								"to_class": to_class,
								"reason": str(result.get("reason", "")),
								"from": str(result.get("from", "")),
							}
						}
					)
				)
	return result


# ============================================================
# FACTION (ADR 0032)
# ============================================================
#
# Four declarative verbs for faction-state mutation:
#   - declare_war       {from, to}
#   - sign_treaty       {from, to, new_stance="neutral"}
#   - propose_alliance  {from, to}
#   - swear_loyalty     {target, faction, delta=10 OR value=int}
#
# All four are NON-DESTRUCTIVE (compose safely in any chain position) and
# atomic on validation failure (unknown faction id leaves state untouched,
# raises FACTION_NO_DEF). FactionDirector (sibling Node under World) hosts
# the registered faction defs + relationship state. effect_apply locates
# it via env.parent.


## Locate FactionDirector. World is env.parent; FactionDirector is a
## named sibling under it. Returns null if not mounted (test harnesses
## without a SceneTree, OR demos that never registered any factions).
static func _faction_director(env: Dictionary) -> Node:
	var parent_node = env.get("parent", null)
	if parent_node is Node:
		var n = (parent_node as Node).get_node_or_null("FactionDirector")
		if n != null:
			return n
	return null


## Resolve a faction id reference (for from/to/faction fields).
## Same policy as _resolve_id: context binding first, literal fallback.
## Strings beginning with formula-start chars get evaluated through the
## formula context (so `"world.active_faction"` resolves to the bound
## faction id). Otherwise treated as a literal id.
static func _resolve_faction_id(v, ctx: Dictionary, env: Dictionary) -> String:
	if v == null:
		return ""
	if v is String:
		var s := str(v)
		if ctx.has(s):
			return str(ctx[s])
		if Formula.looks_like_formula(s):
			var fctx := EffectResolution.formula_context(ctx, env)
			if ctx.has("_rule_id"):
				fctx["_rule_id"] = ctx["_rule_id"]
			var resolved = Formula.evaluate(s, fctx, env)
			return str(resolved) if resolved != null else ""
		return s
	return str(v)


static func _declare_war(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var fd := _faction_director(env)
	if fd == null or not fd.has_method("apply_declare_war"):
		EngineError.raise(
			env,
			EngineError.FACTION_NO_DEF,
			"declare_war: no FactionDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add FactionDirector Node sibling under World in play.tscn (per ADR 0032).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager"}
	var from_id := _resolve_faction_id(e.get("from", ""), ctx, env)
	var to_id := _resolve_faction_id(e.get("to", ""), ctx, env)
	return fd.call("apply_declare_war", env, from_id, to_id)


static func _sign_treaty(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var fd := _faction_director(env)
	if fd == null or not fd.has_method("apply_sign_treaty"):
		EngineError.raise(
			env,
			EngineError.FACTION_NO_DEF,
			"sign_treaty: no FactionDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add FactionDirector Node sibling under World in play.tscn (per ADR 0032).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager"}
	var from_id := _resolve_faction_id(e.get("from", ""), ctx, env)
	var to_id := _resolve_faction_id(e.get("to", ""), ctx, env)
	# Default new_stance is "neutral" — matches FactionDirector.apply_sign_treaty.
	var new_stance := str(EffectResolution.value(e.get("new_stance", "neutral"), ctx, env))
	return fd.call("apply_sign_treaty", env, from_id, to_id, new_stance)


static func _propose_alliance(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var fd := _faction_director(env)
	if fd == null or not fd.has_method("apply_propose_alliance"):
		EngineError.raise(
			env,
			EngineError.FACTION_NO_DEF,
			"propose_alliance: no FactionDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add FactionDirector Node sibling under World in play.tscn (per ADR 0032).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager"}
	var from_id := _resolve_faction_id(e.get("from", ""), ctx, env)
	var to_id := _resolve_faction_id(e.get("to", ""), ctx, env)
	return fd.call("apply_propose_alliance", env, from_id, to_id)


## swear_loyalty — mutate target NPC's state.faction_loyalty[<faction>].
##   {target: <entity_binding|id>, faction: <id>, amount: <int>}
##     OR {target, faction, value: <int>}
##
## `amount` is the delta to add (default +10). `value` overrides to set
## directly. Loyalty values clamp 0-100. Atomic on unknown faction.
static func _swear_loyalty(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var fd := _faction_director(env)
	if fd == null or not fd.has_method("apply_swear_loyalty"):
		EngineError.raise(
			env,
			EngineError.FACTION_NO_DEF,
			"swear_loyalty: no FactionDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add FactionDirector Node sibling under World in play.tscn (per ADR 0032).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager"}
	# Resolve target — same convention as EffectResolution.target() but we need the id
	# string to pass to FactionDirector.apply_swear_loyalty.
	var target_key := str(e.get("target", "self"))
	var target_id := str(ctx.get(target_key, target_key))
	var faction_id := _resolve_faction_id(e.get("faction", ""), ctx, env)
	var opts: Dictionary = {}
	# Author convention: `amount` for the delta-add (mirrors state_add). The
	# FactionDirector internally uses `delta` for symmetry with its other
	# helpers, so we translate here.
	if e.has("amount"):
		opts["delta"] = int(EffectResolution.value(e.get("amount"), ctx, env))
	elif e.has("delta"):
		opts["delta"] = int(EffectResolution.value(e.get("delta"), ctx, env))
	if e.has("value"):
		opts["value"] = int(EffectResolution.value(e.get("value"), ctx, env))
	return fd.call("apply_swear_loyalty", env, target_id, faction_id, opts)


# ============================================================
# TECH-TREE (ADR 0033)
# ============================================================
#
# Three new vocabulary items: try_discover_tech / learn_from_master /
# pass_to_apprentice. Each delegates to the TechTreeDirector node mounted
# as a sibling of World (resolved via env.parent.get_node_or_null). When
# no director is mounted (test harnesses without a SceneTree, OR demos
# that ship no tech_trees.json), the effect logs a warning and no-ops.
#
# Per ADR 0033 §3 these are NON-DESTRUCTIVE effects — they mutate
# entity.state.known_techs and emit signals; they don't tear down scene
# state, so they compose safely in any chain position.


static func _tech_tree_director(env: Dictionary) -> Node:
	var parent_node = env.get("parent", null)
	if parent_node is Node:
		return (parent_node as Node).get_node_or_null("TechTreeDirector")
	return null


## try_discover_tech — roll discovery_chance for one or more eligible
## nodes on the target's tree.
##
## Effect dict shape:
##   {
##     "type": "try_discover_tech",
##     "target": "self",                  # entity-binding key OR literal id
##     "tree":   "smithing",              # tree id (string OR formula)
##     "max_rolls_per_call": 1            # default 1 (safety cap)
##   }
##
## Returns {ok, awarded, target, tree}. awarded="" on no-op. Per ADR
## 0033 §3.1, only the FIRST roll that hits awards a node; subsequent
## eligible candidates this call are silently skipped (rolls again next
## tick).
static func _try_discover_tech(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var ttd := _tech_tree_director(env)
	if ttd == null or not ttd.has_method("try_discover_tech"):
		EngineError.raise(
			env,
			EngineError.TECH_NO_TREE,
			"try_discover_tech: no TechTreeDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add TechTreeDirector Node sibling under World in play.tscn (per ADR 0033).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager"}
	var target_key := str(e.get("target", "self"))
	var target_id := str(ctx.get(target_key, target_key))
	var tree_id := str(EffectResolution.value(e.get("tree", ""), ctx, env))
	var max_rolls: int = int(EffectResolution.value(e.get("max_rolls_per_call", 1), ctx, env))
	var awarded: String = ttd.call("try_discover_tech", env, target_id, tree_id, max_rolls)
	return {
		"ok": awarded != "",
		"awarded": awarded,
		"target": target_id,
		"tree": tree_id,
	}


## learn_from_master — transfer one node from master to apprentice via
## the named relation (default party_member_of, ADR 0026).
##
## Effect dict shape:
##   {
##     "type": "learn_from_master",
##     "target": "self",                  # apprentice entity-binding|id
##     "tree":   "smithing",              # optional; "" = any tree
##     "master_via_relation": "party_member_of",  # ADR 0026 default
##     "master_id": ""                    # optional explicit override
##     "max_per_call": 1                  # default 1
##   }
##
## Returns {ok, awarded, target, tree, master_id}. Per ADR 0033 §3.2,
## missing master = graceful no-op (no error, no signal).
static func _learn_from_master(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var ttd := _tech_tree_director(env)
	if ttd == null or not ttd.has_method("learn_from_master"):
		EngineError.raise(
			env,
			EngineError.TECH_NO_TREE,
			"learn_from_master: no TechTreeDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add TechTreeDirector Node sibling under World in play.tscn (per ADR 0033).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager"}
	var target_key := str(e.get("target", "self"))
	var apprentice_id := str(ctx.get(target_key, target_key))
	var tree_id := str(EffectResolution.value(e.get("tree", ""), ctx, env))
	var relation := str(e.get("master_via_relation", "party_member_of"))
	# Optional explicit master override (rare — for test harnesses or
	# rules that already have a master id in context).
	var master_id := ""
	if e.has("master_id"):
		master_id = EffectResolution.resolve_id(e.get("master_id"), ctx)
	var max_per_call: int = int(EffectResolution.value(e.get("max_per_call", 1), ctx, env))
	var awarded: String = ttd.call(
		"learn_from_master", env, apprentice_id, tree_id, master_id, relation, max_per_call
	)
	return {
		"ok": awarded != "",
		"awarded": awarded,
		"target": apprentice_id,
		"tree": tree_id,
		"master_id": master_id,
	}


## pass_to_apprentice — broadcast: master fires from its own perspective,
## director resolves all apprentices via inverse relation and runs
## learn_from_master per apprentice.
##
## Effect dict shape:
##   {
##     "type": "pass_to_apprentice",
##     "target": "self",                  # master entity-binding|id
##     "tree":   "smithing",              # optional; "" = any tree
##     "apprentice_via_relation": "party_member_of",
##     "max_apprentices_per_call": 4,
##     "max_per_apprentice": 1
##   }
##
## Returns {ok, awarded_count, target, tree}.
static func _pass_to_apprentice(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var ttd := _tech_tree_director(env)
	if ttd == null or not ttd.has_method("pass_to_apprentice"):
		EngineError.raise(
			env,
			EngineError.TECH_NO_TREE,
			"pass_to_apprentice: no TechTreeDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add TechTreeDirector Node sibling under World in play.tscn (per ADR 0033).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager"}
	var target_key := str(e.get("target", "self"))
	var master_id := str(ctx.get(target_key, target_key))
	var tree_id := str(EffectResolution.value(e.get("tree", ""), ctx, env))
	var relation := str(e.get("apprentice_via_relation", "party_member_of"))
	var max_apprentices: int = int(EffectResolution.value(e.get("max_apprentices_per_call", 4), ctx, env))
	var max_per: int = int(EffectResolution.value(e.get("max_per_apprentice", 1), ctx, env))
	var n: int = int(
		ttd.call("pass_to_apprentice", env, master_id, tree_id, relation, max_apprentices, max_per)
	)
	return {
		"ok": n > 0,
		"awarded_count": n,
		"target": master_id,
		"tree": tree_id,
	}


# ============================================================
# DYNASTY (ADR 0034)
# ============================================================
#
# Four declarative store-mover verbs:
#   - transfer_inventory   {from, to}
#   - transfer_reputation  {from, to}
#   - transfer_techs       {from, to, filter="core_only"}
#   - transition_player_to {target}
#
# Each delegates to the DynastyDirector node mounted as a sibling of
# World (resolved via env.parent.get_node_or_null). When no director
# is mounted (test harnesses without a SceneTree, OR demos that ship
# no dynasty content), the effect logs a warning and no-ops.
#
# Per ADR 0034 §"New effects" these are GENERIC store-movers, not
# semantic verbs. The same effects are reusable for non-dynasty
# games (NG+ roguelike carry-over, factory subsidiary spawn,
# corporate succession sim). Per ADR 0034 §"Atomic transition",
# the four effects are non-destructive — they mutate per-entity
# state stores; they don't tear down scene state, so they compose
# safely in any chain position.


static func _dynasty_director(env: Dictionary) -> Node:
	var parent_node = env.get("parent", null)
	if parent_node is Node:
		return (parent_node as Node).get_node_or_null("DynastyDirector")
	return null


## transfer_inventory — move source.state.inventory → target.state.inventory.
## Append-then-clear-source semantics. Returns {ok, count, from, to}.
##
## Effect dict shape:
##   {"type": "transfer_inventory", "from": <entity_binding>, "to": <entity_binding>}
##
## `from` and `to` resolve via _resolve_id (context binding first,
## literal fallback). Either side missing = warning + no-op.
static func _transfer_inventory(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var dd := _dynasty_director(env)
	if dd == null or not dd.has_method("transfer_inventory"):
		EngineError.raise(
			env,
			EngineError.DYNASTY_NO_HEIR,
			"transfer_inventory: no DynastyDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add DynastyDirector Node sibling under World in play.tscn (per ADR 0034).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager", "count": 0}
	var from_id := EffectResolution.resolve_id(e.get("from", ""), ctx)
	var to_id := EffectResolution.resolve_id(e.get("to", ""), ctx)
	var n: int = int(dd.call("transfer_inventory", env, from_id, to_id))
	return {"ok": n > 0, "count": n, "from": from_id, "to": to_id}


## transfer_reputation — move source.state.reputation → target.state.reputation.
## Replace-merge with max() for overlapping faction keys. Source's
## reputation is cleared after transfer. Returns {ok, count, from, to}.
##
## Effect dict shape:
##   {"type": "transfer_reputation", "from": <entity_binding>, "to": <entity_binding>}
static func _transfer_reputation(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var dd := _dynasty_director(env)
	if dd == null or not dd.has_method("transfer_reputation"):
		EngineError.raise(
			env,
			EngineError.DYNASTY_NO_HEIR,
			"transfer_reputation: no DynastyDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add DynastyDirector Node sibling under World in play.tscn (per ADR 0034).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager", "count": 0}
	var from_id := EffectResolution.resolve_id(e.get("from", ""), ctx)
	var to_id := EffectResolution.resolve_id(e.get("to", ""), ctx)
	var n: int = int(dd.call("transfer_reputation", env, from_id, to_id))
	return {"ok": n > 0, "count": n, "from": from_id, "to": to_id}


## transfer_techs — copy filtered subset of source.known_techs → heir.known_techs.
## Filter: "core_only" (default; uses ADR 0033 tech_tree.core flag) or "all".
## Source's known_techs preserved (techs are knowledge, not items).
## Returns {ok, transferred (Array), from, to, filter}.
##
## Effect dict shape:
##   {"type": "transfer_techs", "from": <entity_binding>, "to": <entity_binding>,
##    "filter": "core_only"}
static func _transfer_techs(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var dd := _dynasty_director(env)
	if dd == null or not dd.has_method("transfer_techs"):
		EngineError.raise(
			env,
			EngineError.DYNASTY_NO_HEIR,
			"transfer_techs: no DynastyDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add DynastyDirector Node sibling under World in play.tscn (per ADR 0034).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager", "transferred": []}
	var from_id := EffectResolution.resolve_id(e.get("from", ""), ctx)
	var to_id := EffectResolution.resolve_id(e.get("to", ""), ctx)
	var filter := str(EffectResolution.value(e.get("filter", "core_only"), ctx, env))
	var transferred: Array = dd.call("transfer_techs", env, from_id, to_id, filter)
	return {
		"ok": not transferred.is_empty(),
		"transferred": transferred,
		"from": from_id,
		"to": to_id,
		"filter": filter,
	}


## transition_player_to — swap which entity is the active actor.
## Composes ADR 0016's switch_actor: looks up ActorManager via
## env.parent.actor_manager and calls set_active(new_actor_id).
## Falls back to setting state.is_player=1 on the entity when no
## ActorManager is mounted (test harness path).
##
## Returns {ok, target}.
##
## Effect dict shape:
##   {"type": "transition_player_to", "target": <entity_binding|actor_id>}
##
## Note: unlike ADR 0016's switch_actor (which defers to next tick
## via env._pending_active_actor), this effect applies immediately.
## ADR 0034 §"Atomic transition" requires all succession transfers
## (inventory + reputation + techs + actor swap) to land within the
## same effect chain so save/load mid-transition is structurally
## impossible.
static func _transition_player_to(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var dd := _dynasty_director(env)
	if dd == null or not dd.has_method("transition_player_to"):
		EngineError.raise(
			env,
			EngineError.DYNASTY_NO_HEIR,
			"transition_player_to: no DynastyDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add DynastyDirector Node sibling under World in play.tscn (per ADR 0034).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager", "target": ""}
	var target_id := EffectResolution.resolve_id(e.get("target", ""), ctx)
	if target_id == "":
		# Some authors put the target in `target_id` (mirroring switch_actor).
		target_id = str(EffectResolution.value(e.get("target_id", ""), ctx, env))
	var ok: bool = bool(dd.call("transition_player_to", env, target_id))
	return {"ok": ok, "target": target_id}
