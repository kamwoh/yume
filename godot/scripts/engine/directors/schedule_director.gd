extends Node
class_name ScheduleDirector

## ADR 0029 — Schedule primitive.
##
## Reads the `schedule` block on entity defs and resolves the active slot
## each tick from a bound time-of-day source. Writes `current_verb` +
## `current_target` directly onto the entity's state and emits a
## `schedule_phase_changed` signal on slot transitions.
##
## Per ADR 0021, this module EXPOSES the existing tag + state primitives —
## it does NOT introduce new effect types. The schedule block is the new
## primitive (declarative data on entity defs); ScheduleDirector is the
## interpreter; nothing about WHAT NPCs do moves into engine code.
##
## Wiring: ScheduleDirector expects to be a child of a Node whose script
## is `World`. Sibling of GameShell + ScreenFlow + LightingDirector +
## PartyDirector. PhaseScheduler calls `tick(env)` at the START of decide
## phase (before tick-rules fire) so AI rules in the SAME tick read the
## just-resolved `current_verb` / `current_target`.
##
## Lifecycle:
## 1. Boot: nothing to load — director is purely state-driven from defs.
## 2. Per-tick (driven by PhaseScheduler): scan registered schedules,
##    resolve active slot per entity, mutate state + emit transition
##    signals. Off-camera throttling per ADR 0017 spatial-LOD pattern.
## 3. Entity register: `register_schedule(entity_id, schedule_dict)` —
##    called by World.load_data after entity creation OR by tests.

# ============================================================
# CONSTANTS
# ============================================================

const SIGNAL_NAME: String = "schedule_phase_changed"
const DEFAULT_WRAPS_AT: float = 24.0

# ============================================================
# STATE
# ============================================================

var _world: Node = null
# Per-entity schedule cache: entity_id → {
#   slots, default_verb, emit_on_transition, wraps_at,
#   bind_tag, bind_field, lod_cfg, last_slot_index,
#   last_resolved_target_for_slot
# }
var _cache: Dictionary = {}
# LOD hysteresis state (mirrors phase_scheduler.gd::_lod_state pattern):
# _lod_state[entity_id] = {inside: bool, last_fired: int}
var _lod_state: Dictionary = {}

# ============================================================
# LIFECYCLE
# ============================================================


func _ready() -> void:
	_world = get_parent()
	if _world == null or not _world.has_method("_build_env"):
		# No World parent — silently no-op (lets test harnesses include
		# the node without crashing). Tests instantiate the director
		# directly and call tick(env) without a SceneTree.
		return


# ============================================================
# REGISTRATION
# ============================================================


## Register an entity's schedule. Called by World.load_data after
## entity creation walks defs/instances. The schedule_dict comes from
## the entity def's `schedule` block (or a $extends-resolved variant).
##
## Idempotent: re-registering an entity_id replaces its cache entry.
## No-op for malformed schedules (logged via EngineError; director
## continues operating on other entities — Risk #11 in ADR 0029).
func register_schedule(entity_id: String, schedule_dict: Dictionary, env: Dictionary = {}) -> void:
	if entity_id == "":
		return
	if not _validate_schedule(entity_id, schedule_dict, env):
		return
	# Parse binds_to once (default world_clock.current_hour). Keeps the
	# per-tick resolution path branchless.
	var bind_path := str(schedule_dict.get("binds_to", "world_clock.current_hour"))
	var bind_tag: String = ""
	var bind_field: String = ""
	var dot := bind_path.find(".")
	if dot > 0:
		bind_tag = bind_path.substr(0, dot)
		bind_field = bind_path.substr(dot + 1)
	else:
		# No dot → treat the whole path as a world_state field.
		bind_tag = "world"
		bind_field = bind_path
	_cache[entity_id] = {
		"slots": (schedule_dict.get("slots", []) as Array).duplicate(true),
		"default_verb": str(schedule_dict.get("default_verb", "idle")),
		"emit_on_transition": bool(schedule_dict.get("emit_on_transition", true)),
		"wraps_at": float(schedule_dict.get("wraps_at", DEFAULT_WRAPS_AT)),
		"bind_tag": bind_tag,
		"bind_field": bind_field,
		"lod_cfg": schedule_dict.get("lod", null),
		# -2 sentinel: forces a transition on the FIRST tick (mid-day spawn
		# semantics — entity spawned mid-slot still gets verb resolved + a
		# transition signal). -1 would conflict with no-match return value.
		"last_slot_index": -2,
		"last_resolved_target_for_slot": {},
	}


## Unregister on despawn. Called by World; idempotent.
func unregister_schedule(entity_id: String) -> void:
	_cache.erase(entity_id)
	_lod_state.erase(entity_id)


## Bulk-register from a dict of entity defs. Walks the defs map,
## finds any with a `schedule` block, and registers their initial
## instance(s). Called once after world load_data completes.
func register_schedules_from_env(env: Dictionary) -> void:
	var entities = env.get("entities", null)
	var defs = env.get("defs", null)
	if not (entities is Dictionary) or not (defs is Dictionary):
		return
	for entity_id in (entities as Dictionary).keys():
		var ent = (entities as Dictionary)[entity_id]
		if not (ent is Entity):
			continue
		var def_id := str((ent as Entity).def_id)
		if def_id == "":
			continue
		var def = (defs as Dictionary).get(def_id, null)
		if not (def is Dictionary):
			continue
		var sched = (def as Dictionary).get("schedule", null)
		if sched is Dictionary:
			register_schedule(str(entity_id), sched, env)


# ============================================================
# TICK — the interpreter loop
# ============================================================


## Called by PhaseScheduler at start of decide phase (before tick-rules).
## env is the engine's standard env dict. We:
##   1. Read the bound time value (defaults to world.current_hour)
##   2. Pick the active slot (first match wins, wrap-around aware)
##   3. Pick the verb (with tendency-drift fallback)
##   4. Resolve target on slot transition only
##   5. Mutate entity.state directly + queue transition signal on change
func tick(env: Dictionary) -> void:
	if _cache.is_empty():
		return
	var entities = env.get("entities", null)
	if not (entities is Dictionary):
		return
	var current_tick: int = int(env.get("tick_count", 0))
	for entity_id in _cache.keys():
		if not (entities as Dictionary).has(entity_id):
			continue
		var ent = (entities as Dictionary)[entity_id]
		if not (ent is Entity):
			continue
		var cache: Dictionary = _cache[entity_id]
		# LOD gate (ADR 0017 hysteresis pattern). Off-camera entities
		# resolve at lower cadence; mid-camera entities resolve every tick.
		if not _lod_should_fire(entity_id, ent as Entity, cache, env, current_tick):
			continue
		# 1. Read time source.
		var time_value = _resolve_bound_time(cache, env)
		if time_value == null:
			continue  # bind broken; reported once at register time
		# 2. Find active slot (first match wins; wrap-around supported).
		var slot_index := _pick_active_slot(float(time_value), cache)
		# 3. Pick verb (tendency-drift fallback when slot has the array).
		var slot: Dictionary = {}
		if slot_index >= 0:
			slot = cache.slots[slot_index]
		var verb := _pick_verb(slot, cache, ent as Entity)
		var location_tag := str(slot.get("location_tag", "")) if not slot.is_empty() else ""
		# 4. Resolve target only on transitions (cache per-slot).
		var target_id: String = ""
		var transitioned: bool = slot_index != int(cache.last_slot_index)
		if transitioned:
			target_id = _resolve_target(ent as Entity, location_tag, env)
			(cache["last_resolved_target_for_slot"] as Dictionary)[slot_index] = target_id
		else:
			target_id = str(
				(cache["last_resolved_target_for_slot"] as Dictionary).get(slot_index, "")
			)
		# 5. Apply state mutations directly. Same pattern as
		#    LightingDirector / PartyDirector — direct state writes,
		#    not via effect_apply. This keeps the "schedule resolves
		#    BEFORE tick-rules in the same decide phase" semantics
		#    crisp (writes are immediately visible to subsequent rules).
		(ent as Entity).set_state("current_verb", verb)
		(ent as Entity).set_state("current_target", target_id)
		# Also write the target's CURRENT position so content rules can
		# pathfind without doing their own id→entity lookup (the
		# `self.nearest()` formula is deferred per data-demo.md). Cleared
		# when target is empty so query gates like `current_target_pos_ne []`
		# work cleanly.
		var target_pos: Array = []
		if target_id != "":
			var entities_dict = env.get("entities", {})
			var target_ent = (entities_dict as Dictionary).get(target_id, null)
			if target_ent is Entity:
				var p = (target_ent as Entity).get_position()
				if p is Vector3:
					target_pos = [(p as Vector3).x, (p as Vector3).y, (p as Vector3).z]
				elif p is Vector2:
					target_pos = [(p as Vector2).x, 0.0, (p as Vector2).y]
		(ent as Entity).set_state("current_target_pos", target_pos)
		# 6. Emit transition signal via env.signal_buffer (same surface
		#    `_emit` effect uses). Delivered to react phase by scheduler
		#    drain.
		if transitioned and bool(cache.get("emit_on_transition", true)):
			# Skip the very first registration (sentinel -2 → "no prior").
			# Mid-day-spawn semantics: the FIRST resolved slot DOES emit
			# the signal so consumers (juice, audio, narrative) hear about
			# the entity entering the world mid-slot.
			var prev_idx: int = int(cache.last_slot_index)
			var prev_verb: String = ""
			if prev_idx >= 0:
				prev_verb = _verb_for_slot_at_index(cache, prev_idx, ent as Entity)
			elif prev_idx == -2:
				prev_verb = ""  # never resolved before — registration
			else:
				prev_verb = str(cache.get("default_verb", "idle"))
			_emit_transition(env, entity_id, prev_verb, verb, slot_index)
		cache["last_slot_index"] = slot_index


# ============================================================
# SLOT RESOLUTION
# ============================================================


## Find the first slot whose [start, end) interval contains `time`.
## Wrap-around slots (start > end, e.g. 21..6) match if time >= start
## OR time < end. Returns -1 when no slot matches (caller falls back
## to default_verb).
##
## Static so tests can probe without a SceneTree.
static func _pick_active_slot(time: float, cache: Dictionary) -> int:
	var slots: Array = cache.get("slots", [])
	for i in range(slots.size()):
		var s = slots[i]
		if not (s is Dictionary):
			continue
		var start: float = float((s as Dictionary).get("start", 0.0))
		var end: float = float((s as Dictionary).get("end", DEFAULT_WRAPS_AT))
		if start > end:
			# Wrap-around: e.g. 21.0..6.0 covers (21, 22, 23, 0, 1, ..., 5).
			if time >= start or time < end:
				return i
		else:
			# Half-open [start, end): start matches, end does not.
			if time >= start and time < end:
				return i
	return -1


## Pick the active verb. If slot has `fallback_verb_by_tendency`,
## inspect entity.state.tendency dict and pick the verb with the
## highest tendency stat. Falls back to slot's `verb` if no tendency
## or all listed tendencies are zero.
static func _pick_verb(slot: Dictionary, cache: Dictionary, ent: Entity) -> String:
	if slot.is_empty():
		return str(cache.get("default_verb", "idle"))
	var fallback = slot.get("fallback_verb_by_tendency", null)
	if fallback is Array and not (fallback as Array).is_empty():
		var tendency = ent.get_state("tendency", null)
		if tendency is Dictionary and not (tendency as Dictionary).is_empty():
			var best_verb: String = ""
			var best_score: float = -INF
			for verb_v in fallback as Array:
				var verb_str: String = str(verb_v)
				var score: float = float((tendency as Dictionary).get(verb_str, 0))
				if score > best_score:
					best_score = score
					best_verb = verb_str
			if best_score > 0.0:
				return best_verb
	# Default: slot's primary verb. Falls through to default_verb if absent.
	return str(slot.get("verb", cache.get("default_verb", "idle")))


## Helper for transition signals — what verb WOULD this slot resolve to
## right now? (Used to populate `prev_verb` in the signal payload.)
static func _verb_for_slot_at_index(cache: Dictionary, idx: int, ent: Entity) -> String:
	var slots: Array = cache.get("slots", [])
	if idx < 0 or idx >= slots.size():
		return str(cache.get("default_verb", "idle"))
	return _pick_verb(slots[idx], cache, ent)


# ============================================================
# TIME BINDING
# ============================================================


## Resolve the bound time value from env. Two modes (mirrors
## LightingDirector._resolve_time_of_day):
##   1. world dict (env.world) has the field — wins (set via state_set
##      target=world).
##   2. Otherwise, find first entity tagged bind_tag and read state field.
## Returns null if neither path produces a value (caller skips the entity).
func _resolve_bound_time(cache: Dictionary, env: Dictionary):
	var bind_tag: String = str(cache.get("bind_tag", ""))
	var bind_field: String = str(cache.get("bind_field", ""))
	if bind_field == "":
		return null
	# Path 1: world_state dict
	if bind_tag == "world":
		var ws = env.get("world", null)
		if ws is Dictionary and (ws as Dictionary).has(bind_field):
			return float((ws as Dictionary)[bind_field])
		return null
	# Path 2: first entity with the bind_tag (singleton convention)
	var entities = env.get("entities", null)
	if entities is Dictionary:
		for ent in (entities as Dictionary).values():
			if not (ent is Entity):
				continue
			if (ent as Entity).has_tag(bind_tag):
				var v = (ent as Entity).get_state(bind_field, null)
				if v != null:
					return float(v)
	# Final fallback: env.world dict by field name (some games store
	# time directly in world_state without a clock entity).
	var ws2 = env.get("world", null)
	if ws2 is Dictionary and (ws2 as Dictionary).has(bind_field):
		return float((ws2 as Dictionary)[bind_field])
	return null


# ============================================================
# TARGET RESOLUTION
# ============================================================


## Resolve location_tag → entity_id. Two-stage:
##   1. Prefer a relation hint (home_at / works_at / tends) when the
##      entity has one whose target also carries the location_tag.
##   2. Otherwise pick the nearest entity with the location_tag.
## Returns "" if nothing matches (AI consumer rules can fail open).
##
## Called only on slot transitions (cached per-slot).
static func _resolve_target(ent: Entity, location_tag: String, env: Dictionary) -> String:
	if location_tag == "":
		return ""
	var entities = env.get("entities", null)
	if not (entities is Dictionary):
		return ""
	# Relation hints: try standard relation types in order.
	var rels = env.get("relations", null)
	if rels != null and rels.has_method("targets"):
		var hint_types: Array = ["home_at", "works_at", "tends"]
		for hint in hint_types:
			var targets: Array = rels.targets(str(hint), ent.instance_id)
			for tid in targets:
				var tid_str: String = str(tid)
				if not (entities as Dictionary).has(tid_str):
					continue
				var t = (entities as Dictionary)[tid_str]
				if t is Entity and (t as Entity).has_tag(location_tag):
					return tid_str
	# Nearest match: walk entities, pick lowest distance.
	var ent_pos: Vector2 = ent.get_planar_position()
	var best_id: String = ""
	var best_dist: float = INF
	for cand_id in (entities as Dictionary).keys():
		var cand = (entities as Dictionary)[cand_id]
		if not (cand is Entity):
			continue
		if cand == ent:
			continue
		if not (cand as Entity).has_tag(location_tag):
			continue
		var d: float = (cand as Entity).get_planar_position().distance_to(ent_pos)
		if d < best_dist:
			best_dist = d
			best_id = str(cand_id)
	return best_id


# ============================================================
# SIGNAL EMIT
# ============================================================


## Push schedule_phase_changed onto env.signal_buffer. Uses the same
## buffer the `emit` effect writes to; PhaseScheduler drains it into
## the react phase. No new signal infrastructure.
static func _emit_transition(
	env: Dictionary, entity_id: String, prev_verb: String, new_verb: String, slot_index: int
) -> void:
	var buf = env.get("signal_buffer", null)
	if not (buf is Array):
		# No signal buffer → scheduler not initialized. Same warning
		# path effect_apply._emit uses.
		return
	(
		(buf as Array)
		. append(
			{
				"name": SIGNAL_NAME,
				"payload":
				{
					"entity": entity_id,
					"prev_verb": prev_verb,
					"new_verb": new_verb,
					"slot_id": slot_index,
				}
			}
		)
	)


# ============================================================
# LOD (ADR 0017)
# ============================================================


## Mirror PhaseScheduler's hysteresis: an entity is "inside" once it
## crosses enter_radius and stays inside until past leave_radius. When
## outside, throttle to the configured cadence (`tick_slowed:N`) or
## skip entirely (`freeze`). No-op when the schedule has no `lod`
## block (Phase 1 default — every entity resolves every tick).
func _lod_should_fire(
	entity_id: String, ent: Entity, cache: Dictionary, env: Dictionary, current_tick: int
) -> bool:
	var lod = cache.get("lod_cfg", null)
	if not (lod is Dictionary):
		return true
	var anchor = env.get("lod_anchor_position", null)
	if anchor == null:
		return true  # graceful: over-tick beats freeze
	var ent_pos = ent.get_planar_position()
	if ent_pos == null:
		return true
	var dist: float
	if ent_pos is Vector2 and anchor is Vector2:
		dist = (ent_pos as Vector2).distance_to(anchor as Vector2)
	elif ent_pos is Vector3 and anchor is Vector3:
		dist = (ent_pos as Vector3).distance_to(anchor as Vector3)
	else:
		return true  # mixed-dimension; fail-open
	var was_inside: bool = bool((_lod_state.get(entity_id, {}) as Dictionary).get("inside", false))
	var enter_r: float = float((lod as Dictionary).get("enter_radius", 200.0))
	var leave_r: float = float((lod as Dictionary).get("leave_radius", enter_r * 1.10))
	var now_inside: bool
	if was_inside:
		now_inside = dist <= leave_r
	else:
		now_inside = dist <= enter_r
	if not _lod_state.has(entity_id):
		_lod_state[entity_id] = {}
	(_lod_state[entity_id] as Dictionary)["inside"] = now_inside
	if now_inside:
		return true
	# Outside fallback: outside_mode is the ADR 0029 spelling;
	# also accept ADR 0017's `fallback` for parity.
	var fb: String = str(
		(lod as Dictionary).get("outside_mode", (lod as Dictionary).get("fallback", "freeze"))
	)
	if fb == "freeze":
		return false
	if fb.begins_with("tick_slowed:"):
		var rate := float(fb.substr(12))
		if rate <= 0.0:
			return false
		var interval: int = int(round(1.0 / rate))
		if interval <= 1:
			return true
		var last: int = int((_lod_state[entity_id] as Dictionary).get("last_fired", -100000))
		if current_tick - last >= interval:
			(_lod_state[entity_id] as Dictionary)["last_fired"] = current_tick
			return true
		return false
	# Unknown fallback — fail-open so authors notice via observed behavior.
	return true


# ============================================================
# VALIDATION
# ============================================================


## Sanity-check a schedule dict at registration. Logs (push_warning +
## EngineError) on malformed input but DOES NOT crash — the director
## skips this entity and continues with others (Risk #11 in the ADR).
##
## Returns true iff the schedule is well-enough-formed to register.
static func _validate_schedule(entity_id: String, sched: Dictionary, env: Dictionary) -> bool:
	if sched.is_empty():
		push_warning("ScheduleDirector: '%s' has empty schedule block — skipping." % entity_id)
		return false
	var slots = sched.get("slots", null)
	if not (slots is Array) or (slots as Array).is_empty():
		push_warning("ScheduleDirector: '%s' schedule has no slots — skipping." % entity_id)
		if env.has("error_buffer"):
			EngineError.raise(
				env,
				"schedule.no_slots",
				"ScheduleDirector: '%s' has empty slots array" % entity_id,
				{"entity": entity_id},
				"Add at least one slot with start/end/verb.",
				"warning"
			)
		return false
	# Spot-check slot shapes. We accept malformed individual slots
	# (skipped at runtime) but reject the whole schedule if NONE are valid.
	var any_valid: bool = false
	for s in slots as Array:
		if (
			s is Dictionary
			and (s as Dictionary).has("start")
			and (s as Dictionary).has("end")
			and (s as Dictionary).has("verb")
		):
			any_valid = true
			break
	if not any_valid:
		push_warning(
			"ScheduleDirector: '%s' has no valid slot (missing start/end/verb keys)" % entity_id
		)
		if env.has("error_buffer"):
			EngineError.raise(
				env,
				"schedule.malformed",
				(
					"ScheduleDirector: '%s' has no slot with required keys (start, end, verb)"
					% entity_id
				),
				{"entity": entity_id},
				"Each slot needs start, end, verb.",
				"warning"
			)
		return false
	return true
