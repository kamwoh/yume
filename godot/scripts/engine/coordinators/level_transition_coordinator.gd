extends RefCounted
class_name LevelTransitionCoordinator

## Level lifecycle — extracted from world.gd on 2026-05-12.
##
## Owns the ADR 0006 multi-level transition pipeline:
##   1. process_pending(env) — drained each tick; consumes
##      env._pending_level_transition (set by transition_level effect)
##   2. do_transition(target) — the actual swap: teardown old level's
##      entities + navmesh + multimesh batching, reload rules, spawn
##      new level's content, fire post-swap re-batch + autosave hook
##   3. load_level(name) — load a single level's content (rules +
##      entities). Used at boot AND post-transition (do_transition
##      calls it after teardown).
##
## Invariant #11 (level-discontinuity cleanup) is load-bearing here:
## entities are positionally coupled to engine state (navmesh, multimesh
## buffers) that must be explicitly torn down before despawn. Future
## ADR 0044 Session A will add PhysicsServer3D.body_free to the despawn
## path — the natural site is `do_transition`'s entity-removal loop.
##
## Pattern matches ActorManager / SpawnManager — RefCounted, per-World
## instance, single constructor takes a world reference. Public methods
## are stateless (no internal state besides the world ref).

var _world: World


func _init(world: World) -> void:
	_world = world


# ============================================================
# PUBLIC API
# ============================================================


## Drain a pending level transition queued via the `transition_level`
## effect. Called from world.gd::_process tick branch (every sim-tick) AND from
## scenario_runner (which bypasses _process). No-op when no pending
## transition.
func process_pending(env: Dictionary) -> void:
	var pending = env.get("_pending_level_transition", "")
	if str(pending) != "":
		env["_pending_level_transition"] = ""
		do_transition(str(pending))
		return

	# ADR 0077 — level subroutines. Both bypass the level_order membership
	# check: a sub-level is deliberately OFF-PROGRESSION so `transition_level
	# "next"` can never walk into it.
	var call_target = env.get("_pending_level_call", "")
	if str(call_target) != "":
		env["_pending_level_call"] = ""
		do_transition(str(call_target), true)
		return

	var ret = env.get("_pending_level_return", null)
	if ret is Dictionary:
		env["_pending_level_return"] = null
		_do_return(env, ret as Dictionary)


## Return to a caller level, then emit its return_signal with the result.
##
## The emit happens AFTER the swap on purpose: the caller's rules are not
## registered until its level loads, so a signal emitted beforehand would
## fall on an empty bucket and the result would vanish.
func _do_return(env: Dictionary, frame: Dictionary) -> void:
	var target := str(frame.get("level", ""))
	if target == "" or not _world.level_order.has(target):
		# The caller no longer exists (renamed level, edited progression, a
		# save from an older build). Falling back to the progression's first
		# level is recoverable; leaving the player stranded in a sub-level
		# with no exit is not.
		var fallback := str(_world.level_order[0]) if not _world.level_order.is_empty() else ""
		(
			EngineError
			. raise(
				env,
				EngineError.LEVEL_RETURN_ORPHANED,
				"level_return caller '%s' is not a known level — falling back to '%s'" % [target, fallback],
				{"got": target},
				"Check that the calling level still exists in progression.levels.",
				"warning"
			)
		)
		if fallback == "":
			return
		target = fallback
	do_transition(target, true)

	var sig := str(frame.get("return_signal", ""))
	if sig == "":
		return
	# Built through EffectCore.push_signal, not by hand. This site used to append
	# `{...result fields..., "name": sig}` — the result FLATTENED beside the name —
	# while the drain reads `sig["payload"]`. So ADR 0077's entire return value,
	# the reason level_return takes a `result` at all, arrived empty at every rule
	# and the caller could only ever see that a delve had ended, never how.
	# Empirical 2026-08-18: a cleared dungeon floor paid 0 coin.
	var payload = frame.get("result", {})
	EffectCore.push_signal(
		env, sig, (payload as Dictionary).duplicate(true) if payload is Dictionary else {}
	)


## Execute a level swap. Removes non-persistent entities, clears
## scheduler rules, reloads global rules, then loads the new level's
## content. Player + persistent entities (Invariant #12) survive
## the swap with their state intact.
##
## Special target "next" resolves to the next level in progression
## (level_order); past the last level sets world_state.all_levels_complete=1.
## `off_progression` (ADR 0077) skips the level_order membership check, for
## sub-levels entered via level_call. Those are deliberately absent from the
## progression so "next" can't reach them.
func do_transition(target: String, off_progression: bool = false) -> void:
	# Resolve "next" shorthand against progression order.
	if target == "next":
		var idx: int = _world.level_order.find(_world.current_level)
		if idx >= 0 and idx + 1 < _world.level_order.size():
			target = str(_world.level_order[idx + 1])
		else:
			# Past the last level — game won. Set a world-state flag so
			# HUD's win condition can trigger (binds to clock/world).
			_world.world_state["all_levels_complete"] = 1
			if _world.verbose:
				print("[World] all levels complete: ", _world.on_all_complete_msg)
			return
	if not off_progression and not _world.level_order.has(target):
		push_warning("[World] transition_level target '%s' not in progression.levels" % target)
		return
	# ADR 0024: tear down old level's navigation region BEFORE removing
	# entities — agents bound to it will be freed alongside their parent
	# entities below, but the region itself must go too.
	if _world.scheduler != null:
		Pathfinding.teardown_navmesh(_world.scheduler.env)
	# ADR 0041: free the old level's MultiMeshInstance3D nodes (per
	# Invariant #11 — level-discontinuity engine-state cleanup audit).
	# The corresponding entities are about to be destroyed below; the
	# multimesh nodes are the only remaining references and would leak.
	if _world._multimesh_director != null and _world.scheduler != null:
		var freed := _world._multimesh_director.cleanup(_world.scheduler.env)
		if _world.verbose and freed > 0:
			print("[MULTIMESH-CLEAR] freed %d nodes from level %s" % [freed, _world.current_level])
	# Remove non-persistent entities.
	# 2026-05-12 note: ADR 0044 Session A will add
	#   PhysicsServer3D.body_free(body_rid)
	# inside this loop once entities own physics bodies.
	# Survives if the entity carries ANY of the declared persistent tags
	# (game/flow.json `persistent_tags`, default ["persistent"]). Hardcoding the
	# literal "persistent" here is what made that key dead content: a game
	# declaring ["player", "persistent"] still lost its player on the first swap,
	# and nothing errored — the player simply was not on the next level, so every
	# rule requiring one silently stopped matching.
	#
	# The `_engine` entity (ADR 0047) always survives. It is engine-owned, and
	# no game tags it. A game that declared `persistent_tags: ["player"]` used
	# to lose it on the first swap, and every later `world` write did nothing.
	# Empirical 2026-10-18: the levels_variants conformance case.
	var keep_tags: Array = _world.level_persistent_tags + ["_engine"]
	var to_remove: Array[String] = []
	for id in _world.entities.keys():
		var ent = _world.entities[id]
		if not (ent is Entity):
			continue
		var keep := false
		for t in keep_tags:
			if (ent as Entity).has_tag(str(t)):
				keep = true
				break
		if not keep:
			to_remove.append(str(id))
	for rid in to_remove:
		var rent: Entity = _world.entities.get(rid, null)
		if rent == null:
			continue
		if _world.relations != null:
			_world.relations.clear_entity(rid)
		if _world.spatial_index != null and _world.spatial_index.has_method("remove_entity"):
			_world.spatial_index.remove_entity(rid)
		_world.entities.erase(rid)
		rent.queue_free()
	# Clear scheduler rules and reload globals (persistent across levels).
	# physics first (register), game-rules appended. Per-level rules get
	# appended in load_level.
	if _world.scheduler != null and _world.scheduler.has_method("clear_rules"):
		_world.scheduler.clear_rules()
	var root := _world.data_root.rstrip("/")
	_world._loader.load_rules_files_for(root + "/world/rules.json")
	_world._loader.load_rules_files_for(root + "/game/goals.json", true)
	# ADR 0012: tutorial.json is global (not per-level), re-register here
	# so sequencing rules survive level transitions.
	_world._loader.load_rules_file(root + "/tutorial.json", true)
	# Load new level. ADR 0047: current_level setter writes through to
	# world_state["current_level"] — single source of truth.
	_world.current_level = target
	load_level(target)
	_world.scheduler.flush_effects()
	# ADR 0055 (2026-05-20): rebind ground shader params from the new
	# level's optional scene.json override. Per invariant #11, this is
	# how the engine handles "engine state coupled to OLD level
	# identity" — biome_map is one such piece of state. Safe no-op
	# when ground uses StandardMaterial3D, or when the new level has
	# no scene.json override.
	GroundRenderer.rebind_shader_params(target)
	# ADR 0041: re-batch the new level's static decoration. Mirrors the
	# load_data() call at boot, but for mid-session level swaps.
	_world._run_multimesh_director()
	# ADR 0010 autosave: on_level_transition. Push a save into the env's
	# pending slot so the next process_pending_save_load picks it up.
	# Slot 0 = autosave by convention.
	if not _world.save_policy.is_empty():
		var auto: Dictionary = _world.save_policy.get("autosave", {}) as Dictionary
		if bool(auto.get("on_level_transition", false)):
			_world.scheduler.env["_pending_save"] = 0
	if _world.verbose:
		print("[World] transitioned to level: ", target)


## Load a single level's rules + entities. Used by:
##   - world.gd::load_data (initial level at boot)
##   - world.gd::_do_load (after restoring saved current_level)
##   - do_transition (after old level teardown)
##
## Builds the navmesh if the level has walkable_floor entities.
## Multimesh re-batching is intentionally NOT done here — it's the
## caller's responsibility (load_data + do_transition both batch
## AFTER load_level returns, to avoid duplicate batching at boot).
func load_level(name: String) -> void:
	if _world.levels_root == "" or name == "":
		return
	var lvl_dir := _world.levels_root + "/" + name
	_world._loader.load_rules_files_for(lvl_dir + "/rules.json", true)
	_world._loader.load_entities_path(lvl_dir)
	# ADR 0024: build the navigation mesh from walkable_floor +
	# pathfinding_obstacle entities. No-op when the level doesn't tag
	# any (legacy / 2D / non-routing levels). The scheduler's env is the
	# stable dict effect handlers see, so build directly against that —
	# Pathfinding stashes the region under `_navigation_region` and the
	# pathfind_to effect reads it from the same key.
	if _world.scheduler != null:
		Pathfinding.build_navmesh_for_level(_world.scheduler.env)
