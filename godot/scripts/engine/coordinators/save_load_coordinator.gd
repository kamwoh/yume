extends RefCounted
class_name SaveLoadCoordinator

## Save/load orchestration — extracted from world.gd on 2026-05-12.
##
## Owns the ADR 0010 save/load pipeline:
##   - process_pending(env) — drains _pending_save + _pending_load
##   - do_save(slot) — serialize world state to slot via SaveState
##   - do_load(slot) — read slot, reload level if needed, apply state +
##     persistent entities + relations + chunk position
##
## SaveState (scripts/engine/save_state.gd) handles low-level
## serialization (write file, read file, version check, restore
## zone state). This coordinator handles the WORLD-LEVEL orchestration:
## level transition on load, chunk re-anchoring, entity respawn via
## SpawnManager, has_save binding refresh.
##
## Pattern: RefCounted, per-World instance, constructor takes World
## reference. Ownership transfers to GameShell as part of the
## "world = sim, game_shell = game" principle realization (2026-05-12).

var _world: World


func _init(world: World) -> void:
	_world = world


# ============================================================
# PUBLIC API
# ============================================================


## Drain pending save + load requests from env. Save fires FIRST (so a
## save+load in the same frame still saves pre-load state). Each
## request is idempotent — env keys are cleared on consumption.
func process_pending(env: Dictionary) -> void:
	# Save first (so a save+load in same frame still saves the pre-load state)
	var pending_save = env.get("_pending_save", null)
	if pending_save != null and pending_save is int:
		env.erase("_pending_save")
		do_save(int(pending_save))
	var pending_load = env.get("_pending_load", null)
	if pending_load != null and pending_load is int:
		env.erase("_pending_load")
		do_load(int(pending_load))


## Serialize current world state to the given slot. No-op + warning if
## the game has no save_policy.json declared.
func do_save(slot: int) -> void:
	if _world.save_policy.is_empty():
		EngineError.raise(
			_world.scheduler.env,
			EngineError.RULE_FILE_MISSING,
			"save_state effect fired but no save_policy.json present",
			{"slot": slot},
			"Add data/<game>/save_policy.json to opt in to persistence.",
			"warning"
		)
		return
	var tick_n: int = _world._tick_count
	var ok := SaveState.save_to_slot(
		_world.scheduler.env, _world.save_policy, slot, _game_name(), tick_n
	)
	if ok:
		# Refresh has_save so menus update immediately
		var slots := int(_world.save_policy.get("slots", 1))
		_world.world_state["has_save"] = 1 if SaveState.has_any_save(_game_name(), slots) else 0
		if _world.verbose:
			print("[World] saved slot %d" % slot)
	else:
		push_warning("[World] save to slot %d failed" % slot)


## Load + apply a saved slot. Reloads level if saved current_level
## differs, re-anchors chunk streamer if chunked, restores zone state,
## overwrites persistent entities, applies saved relations.
func do_load(slot: int) -> void:
	if _world.save_policy.is_empty():
		push_warning("load_state effect fired but no save_policy.json present")
		return
	var result: Dictionary = SaveState.read_slot(_game_name(), slot, _world.save_policy)
	if not bool(result.get("ok", false)):
		var err := str(result.get("error", "unknown"))
		push_warning("[World] load slot %d failed: %s" % [slot, err])
		return
	var payload: Dictionary = result["payload"]
	# Apply saved world_state (replaces, doesn't merge — persisted keys are
	# the source of truth on load)
	var ws_in: Dictionary = payload.get("world_state", {}) as Dictionary
	for k in ws_in.keys():
		_world.world_state[str(k)] = ws_in[k]
	# Reload current_level if it changed (re-spawns the level's entities)
	# AFTER state apply so the level loader sees the saved current_level.
	var saved_level := str(_world.world_state.get("current_level", _world.current_level))
	if saved_level != "" and saved_level != _world.current_level:
		_world._level_transitions.do_transition(saved_level)
	# ADR 0014: restore current_chunk if the save came from chunked-world
	# mode. Re-anchor the streamer at the saved chunk; the next tick's
	# update() will load the right neighbors. We unload everything first
	# so transient chunks from the starting_chunk boot don't linger.
	if _world.chunk_streamer != null and payload.has("current_chunk"):
		var cc = payload["current_chunk"]
		if cc is Array and (cc as Array).size() >= 2:
			var saved_chunk := Vector2i(int(cc[0]), int(cc[1]))
			_apply_saved_chunk(saved_chunk)
	# ADR 0031: restore zone state. Zones in save but absent from current
	# zones.json are dropped silently (forgiveness). Zones present in zones.json
	# but absent from save retain their state_init defaults.
	SaveState.restore_zone_state(_world._build_env(), payload)
	# Apply saved persistent entities (overwrite the level's defaults)
	_apply_saved_entities(payload.get("persistent_entities", []))
	# Apply saved relations (additive — relations from level are kept,
	# saved ones added; redundant relate() calls are no-ops in
	# RelationStore)
	var rels = payload.get("relations", [])
	if rels is Array:
		for r in rels:
			if r is Dictionary:
				(
					_world
					. relations
					. relate(
						str(r.get("type", "")),
						str(r.get("from", "")),
						str(r.get("to", "")),
					)
				)
	if _world.verbose:
		print(
			(
				"[World] loaded slot %d (tick was %d)"
				% [slot, int((payload.get("_meta", {}) as Dictionary).get("tick", -1))]
			)
		)


# ============================================================
# INTERNAL
# ============================================================


## ADR 0014: re-anchor chunk_streamer at a saved chunk. Despawns all
## currently-loaded transient chunks (they came from the starting_chunk
## boot above), reseats current_chunk on the streamer, and triggers a
## fresh load around the saved coord. Persistent entities are untouched.
func _apply_saved_chunk(saved_chunk: Vector2i) -> void:
	if _world.chunk_streamer == null:
		return
	var env := _world._build_env()
	# Unload every transient chunk loaded by boot()
	for c in _world.chunk_streamer.loaded_chunks().duplicate():
		_world.chunk_streamer._unload_chunk(c, env)
	# Reset internal state to force a reload around the saved chunk
	_world.chunk_streamer.current_chunk = saved_chunk
	_world.chunk_streamer.starting_chunk = saved_chunk
	_world.chunk_streamer.boot(env)
	_world.world_state["current_chunk"] = [saved_chunk.x, saved_chunk.y]


## Apply a saved persistent_entities array. For each record:
##   - if an entity with that id exists, update its position + state
##   - if not, spawn from def at saved position with saved state
func _apply_saved_entities(records: Array) -> void:
	for r in records:
		if not (r is Dictionary):
			continue
		var rec: Dictionary = r
		var inst_id := str(rec.get("id", ""))
		var def_id := str(rec.get("def", ""))
		if inst_id == "" or def_id == "":
			continue
		var pos = rec.get("position", null)
		var state_in: Dictionary = rec.get("state", {}) as Dictionary
		var ent = _world.entities.get(inst_id, null)
		if ent != null and ent is Entity:
			# Existing — overwrite position + state
			(ent as Entity).set_position(pos)
			for k in state_in.keys():
				(ent as Entity).set_state(str(k), state_in[k])
		else:
			# Spawn from def
			(
				_world
				. _spawn_manager
				. spawn(
					{
						"def": def_id,
						"id": inst_id,
						"position": pos,
						"state": state_in,
					}
				)
			)


## Resolve the data_root's basename for save namespacing.
## "res://data/demo_sokoban" → "demo_sokoban".
func _game_name() -> String:
	return game_name_from_root(_world.data_root)


## Static variant — used by callers that don't have a SaveLoadCoordinator
## instance handy (world.gd::load_data + world.gd::_do_world_reset call
## this for has_save binding refresh).
static func game_name_from_root(data_root: String) -> String:
	var s := data_root.rstrip("/")
	var slash := s.rfind("/")
	if slash < 0:
		return s
	return s.substr(slash + 1)
