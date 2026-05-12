extends RefCounted
class_name ActorManager

## ADR 0016 — Multi-actor framework.
##
## Promotes the singleton actor concept to a first-class binding:
## `world.active_actor_id` identifies the currently-controlled entity.
## Multiple actor profiles can exist; the active one receives input.
##
## Per TD condition #1: SINGLE CODE PATH. At load, if `actors.json` is
## absent, the engine SYNTHESIZES a default config pointing at the
## legacy `actor_tag` entity. Engine code only ever reads from the
## actors registry — no special-cased "legacy" branch.
##
## Phase A scope: synthesized default + switch_actor effect + binding.
## Phase B (later):
##   - Multi-input-device routing (gamepad_2 → player_alt)
##   - Per-actor input_actions_press lists
##   - AI policy hookup (ADR 0018)
##   - camera.mode: "follow_active_actor"


# ============================================================
# STATE
# ============================================================

var _actors: Array = []                 # array of {id, starting_entity_tag, input_device, control_mode}
var _by_id: Dictionary = {}              # id → actor dict
var active_actor_id: String = ""
## ADR 0018 Phase A: actor_id → ScriptedPolicy instance for ai_policy actors.
## Loaded once at game start; invoked per tick by tick_policies().
var _policies: Dictionary = {}

## Cache of resolve_active_entity result. Refreshed lazily — fast path
## checks the cache is still valid (entity exists + still has the right
## tag); slow path scans env.entities and updates cache. set_active()
## invalidates. Avoids O(N) tag scan every frame (Aldenmere with 234
## entities hits this 60Hz, was ~14000 has_tag calls/sec — now ~60 cache
## checks/sec under steady state). Added 2026-05-11.
var _cached_active_entity_id: String = ""


# ============================================================
# LOADING
# ============================================================

## Load actors from <data_root>/actors.json if present; else synthesize
## default from the World's actor_tag. Always produces a valid config —
## no dual code paths.
##
## actor_tag_fallback: World.actor_tag (default "player"). Used to build
## the synthesized default actor when actors.json is absent.
static func load_or_synthesize(data_root: String, actor_tag_fallback: String) -> ActorManager:
	var am := ActorManager.new()
	var root := data_root.rstrip("/")
	var path := root + "/actors.json"
	if FileAccess.file_exists(path):
		am._load_from_file(path)
	if am._actors.is_empty():
		# No file OR file empty → synthesize default. Single actor whose
		# starting_entity_tag = legacy actor_tag. Behaves identically to
		# pre-ADR-0016 single-player flow.
		am._actors = [{
			"id": "default_player",
			"input_device": "keyboard",
			"control_mode": "human",
			"starting_entity_tag": actor_tag_fallback,
		}]
		am.active_actor_id = "default_player"
	# Index
	for a in am._actors:
		if a is Dictionary and (a as Dictionary).has("id"):
			am._by_id[str((a as Dictionary)["id"])] = a
	return am


func _load_from_file(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary): return
	var actors_arr = (data as Dictionary).get("actors", [])
	if actors_arr is Array:
		_actors = actors_arr
	active_actor_id = str((data as Dictionary).get("active_actor_id", ""))
	# If file specifies actors but no active_actor_id, default to first
	if active_actor_id == "" and not _actors.is_empty():
		active_actor_id = str((_actors[0] as Dictionary).get("id", ""))


# ============================================================
# ACTOR LOOKUP
# ============================================================

## Find the entity controlled by the given actor_id. Returns "" if no
## matching entity exists. Uses the actor's `starting_entity_tag` to
## locate via env.entities (first entity matching the tag).
func resolve_actor_entity(actor_id: String, entities: Dictionary) -> String:
	# Early-return on empty actor_id (added 2026-05-11) — avoids a silent
	# O(N) scan for tag "" which has_tag always rejects. Defensive against
	# `resolve_actor_entity("", entities)` callers that bypass resolve_active_entity.
	if actor_id == "": return ""
	var actor: Dictionary = _by_id.get(actor_id, {})
	if actor.is_empty(): return ""
	var tag := str(actor.get("starting_entity_tag", ""))
	if tag == "": return ""
	for inst_id in entities.keys():
		var ent = entities[inst_id]
		if ent != null and ent.has_method("has_tag") and ent.has_tag(tag):
			return str(inst_id)
	return ""


## Resolve the active actor's controlled entity id. Convenience for
## input dispatch + camera follow. Cached: fast path validates the
## previous resolution; slow path scans + caches.
func resolve_active_entity(entities: Dictionary) -> String:
	if active_actor_id == "": return ""
	# Fast path: cached id still resolves to a valid entity with the
	# right tag. ~4 O(1) ops, no scan.
	if _cached_active_entity_id != "" \
			and entities.has(_cached_active_entity_id):
		var ent = entities[_cached_active_entity_id]
		if ent != null and ent.has_method("has_tag"):
			var actor: Dictionary = _by_id.get(active_actor_id, {})
			var tag := str(actor.get("starting_entity_tag", ""))
			if tag != "" and ent.has_tag(tag):
				return _cached_active_entity_id
	# Slow path: cache miss / invalid → re-resolve + cache.
	var resolved := resolve_actor_entity(active_actor_id, entities)
	_cached_active_entity_id = resolved
	return resolved


## Set a new active actor. Returns false if actor_id unknown (no change).
## Used by world.gd when processing a deferred switch_actor effect.
func set_active(actor_id: String) -> bool:
	if not _by_id.has(actor_id):
		push_warning("ActorManager: switch_actor target '%s' not in registry" % actor_id)
		return false
	active_actor_id = actor_id
	_cached_active_entity_id = ""  # invalidate; next resolve re-scans
	return true


## ADR 0016: drain a queued switch_actor between ticks. Effect handlers
## set env._pending_active_actor; we read + clear it here so input
## routing changes happen at tick boundaries, not mid-rule. Mirrors the
## new active actor into world_state so bindings + HUD can read it.
##
## No-op when nothing is pending. Called from world.gd::_on_tick after
## scheduler.tick — under freeze (modal up) the entire tick is skipped,
## so the pending value sits in env until the next live tick (intentional
## per Invariant #10: actor swap is sim-state, can wait).
func process_pending(env: Dictionary, world_state: Dictionary, verbose: bool) -> void:
	var pending = env.get("_pending_active_actor", null)
	if pending == null: return
	env.erase("_pending_active_actor")
	var target := str(pending)
	if set_active(target):
		world_state["active_actor_id"] = target
		if verbose:
			print("[ActorManager] active actor → ", target)


# ============================================================
# DIAGNOSTICS
# ============================================================

func actor_ids() -> Array:
	return _by_id.keys()


func get_actor(actor_id: String) -> Dictionary:
	return _by_id.get(actor_id, {})


# ============================================================
# AI POLICIES (ADR 0018 Phase A — scripted JSON path only)
# ============================================================

## Load a scripted policy for each actor with control_mode = ai_policy
## and policy_ref pointing to a JSON file relative to data_root.
## Path B (godot_resource) deferred to Phase B.
func load_policies(data_root: String) -> void:
	var root := data_root.rstrip("/")
	for actor_id in _by_id.keys():
		var actor: Dictionary = _by_id[actor_id]
		if str(actor.get("control_mode", "")) != "ai_policy": continue
		var ref := str(actor.get("policy_ref", ""))
		if ref == "": continue
		# v1: scripted JSON only. Future: detect type via "type" field
		# in policy file or actor's policy_kind field.
		var policy_path := root + "/" + ref
		var p := ScriptedPolicy.load_from_file(policy_path)
		if p != null:
			_policies[str(actor_id)] = p


## Per-tick: for each AI actor, build observation, call policy.decide(),
## queue resulting actions onto the scheduler. Called by World between
## the input and decide phases (see world.gd _on_tick).
func tick_policies(env: Dictionary) -> void:
	if _policies.is_empty(): return
	var entities: Dictionary = env.get("entities", {})
	var world_state: Dictionary = env.get("world", {})
	for actor_id in _policies.keys():
		var entity_id := resolve_actor_entity(str(actor_id), entities)
		if entity_id == "": continue
		var ent = entities.get(entity_id, null)
		if ent == null: continue
		var actor_state := _build_actor_state(entity_id, ent)
		var observation := _build_observation(env, entity_id, ent, world_state)
		var policy = _policies[actor_id]
		var actions = policy.decide(observation, actor_state)
		if not (actions is Array): continue
		_queue_actions_for_actor(env, str(actor_id), actions as Array)


## Bundle the actor's own state into the format ScriptedPolicy expects.
static func _build_actor_state(actor_id: String, ent) -> Dictionary:
	var pos = ent.get_position() if ent.has_method("get_position") else null
	var st: Dictionary = ent.state if "state" in ent else {}
	var tags: Array = ent.tags if "tags" in ent else []
	return {
		"id": actor_id,
		"position": pos,
		"state": st,
		"tags": tags,
	}


## Build a generic observation Dictionary from env state. Phase A:
## minimal — nearby entities (radius 200), world_state, active actor
## position. Phase B can extend to recent_signals + custom tag filters
## per actor's observation_config.
func _build_observation(env: Dictionary, entity_id: String, ent,
						world_state: Dictionary) -> Dictionary:
	var sx = env.get("spatial_index", null)
	var pos = ent.get_position() if ent.has_method("get_position") else null
	var nearby: Array = []
	if sx != null and pos != null and sx.has_method("query_radius_ids"):
		var ids = sx.query_radius_ids(pos, 200)
		var entities: Dictionary = env.get("entities", {})
		for id in ids:
			if str(id) == entity_id: continue
			var other = entities.get(id, null)
			if other == null: continue
			var other_pos = other.get_position() if other.has_method("get_position") else null
			var other_tags = other.tags if "tags" in other else []
			nearby.append({
				"id": str(id),
				"position": other_pos,
				"tags": other_tags,
			})
	# Active actor's position (for distance_to: active_actor)
	var active_pos = null
	if active_actor_id != "":
		var active_ent_id := resolve_active_entity((env.get("entities", {}) as Dictionary))
		if active_ent_id != "":
			var active_ent = (env.get("entities", {}) as Dictionary).get(active_ent_id, null)
			if active_ent != null and active_ent.has_method("get_position"):
				active_pos = active_ent.get_position()
	return {
		"nearby": nearby,
		"world_state": world_state,
		"active_actor_position": active_pos,
	}


## Queue each action onto the scheduler's input queue. Each action's
## actor_id propagates so input rules can target the right entity.
static func _queue_actions_for_actor(env: Dictionary, actor_id: String,
									 actions: Array) -> void:
	var parent_node = env.get("parent", null)
	if parent_node == null or parent_node.get("scheduler") == null: return
	var sched = parent_node.scheduler
	if not sched.has_method("queue_input"): return
	for a in actions:
		if not (a is Dictionary): continue
		var action_name := str((a as Dictionary).get("action", ""))
		if action_name == "": continue
		# Action's params (everything except "action") get forwarded
		var params: Dictionary = (a as Dictionary).duplicate(true)
		params.erase("action")
		# Always carry actor binding
		params["actor"] = actor_id
		params["synthesized"] = true
		sched.queue_input(action_name, params)
