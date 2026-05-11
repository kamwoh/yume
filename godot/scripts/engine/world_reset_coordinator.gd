extends RefCounted
class_name WorldResetCoordinator

## World reset orchestration — extracted from world.gd on 2026-05-12.
##
## Task #99 pipeline: a "New Game" or "Continue" button can fire the
## `reset_world` effect, which sets env._pending_world_reset=true.
## This coordinator drains that flag and performs the reset:
##
##   1. Despawn all non-persistent entities (matches transition_level)
##   2. Clear world_state in-place, reload from world/state.json
##   3. Reload entities + relations. Multi-level games reset to the
##      progression's starting_level; single-level games re-load root.
##   4. Refresh has_save binding (saves are NOT deleted; just resync UI)
##   5. Refresh active_actor_id mirror (ActorManager state untouched)
##
## NO scene reload — World + scheduler + screen_flow + settings persist.
## "New Game" cleans up after a Continue without dropping any UI state.
##
## Pattern: RefCounted, per-World instance, world reference via _world.


var _world: World


func _init(world: World) -> void:
	_world = world


# ============================================================
# PUBLIC API
# ============================================================

## Drain a pending world reset (set by the reset_world effect).
func process_pending(env: Dictionary) -> void:
	if not bool(env.get("_pending_world_reset", false)): return
	env.erase("_pending_world_reset")
	do_reset()


## Execute the reset: despawn non-persistent entities, reset state,
## reload starting level (multi-level) or root entities (single-level),
## refresh has_save + active_actor_id bindings.
func do_reset() -> void:
	var root := _world.data_root.rstrip("/")
	# 1. Despawn all non-persistent entities (matches transition_level).
	# 2026-05-12 note: ADR 0044 Session A will add PhysicsServer3D.body_free
	# to this loop once entities own physics bodies.
	var to_remove: Array[String] = []
	for id in _world.entities.keys():
		var ent = _world.entities[id]
		if ent is Entity and not (ent as Entity).has_tag("persistent"):
			to_remove.append(str(id))
	for rid in to_remove:
		var rent: Entity = _world.entities.get(rid, null)
		if rent == null: continue
		if _world.relations != null:
			_world.relations.clear_entity(rid)
		if _world.spatial_index != null and _world.spatial_index.has_method("remove_entity"):
			_world.spatial_index.remove_entity(rid)
		_world.entities.erase(rid)
		rent.queue_free()
	# 2. Reset world_state to initial values. Clear in-place so any
	# external references (env.world is a back-ref) stay valid.
	_world.world_state.clear()
	_world.world_state["tick"] = 0
	_world._load_world_file(root + "/world/state.json")
	# 3. Reload entities + relations. For multi-level games, reset to
	# the progression's starting_level. For single-level, just re-load
	# root entities.
	var prog_path := root + "/game/flow.json"
	if FileAccess.file_exists(prog_path):
		_world._load_progression(prog_path)         # resets current_level → starting_level
		_world.world_state["current_level"] = _world.current_level
		_world._load_entities_path(root)             # re-load persistent root entities
		if _world.current_level != "":
			_world._level_transitions.load_level(_world.current_level)
	else:
		_world._load_entities_path(root)
	# 4. Refresh has_save (ADR 0010) — reset doesn't delete saves; it just
	# clears in-memory state. has_save remains accurate.
	if not _world.save_policy.is_empty():
		var slots := int(_world.save_policy.get("slots", 1))
		_world.world_state["has_save"] = 1 if SaveState.has_any_save(
			SaveLoadCoordinator.game_name_from_root(_world.data_root), slots) else 0
	# 5. Refresh active_actor_id mirror (ActorManager state untouched).
	if _world.actor_manager != null:
		_world.world_state["active_actor_id"] = _world.actor_manager.active_actor_id
	_world.scheduler.flush_effects()
	if _world.verbose:
		print("[World] reset_world complete (level: %s)" % _world.current_level)
