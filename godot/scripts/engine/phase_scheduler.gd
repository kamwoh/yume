extends RefCounted
class_name PhaseScheduler

## Four-phase tick loop + effect write buffer.
##
## Contract: docs/30_framework_primitives.md § "Tick ordering (phased-sequential)"
##
## Phases per tick:
##   1. input   — input-triggered rules (W2 wires this; W1 stub)
##   2. decide  — tick + signal rules read state, queue effects
##   3. commit  — queued effects apply in definition order; spawns/removes/
##                relates take effect; signals emitted here queue for react
##   4. react   — contact + relation_changed rules fire against post-commit
##                state; signals emitted here queue for NEXT tick's input
##
## Within a phase, rules run in JSON definition order. Optional `before`/`after`
## hints refine the order via a topological sort performed once at register
## time. No integer priorities.
##
## W1 scope: tick trigger only. Lifecycle flush (initial spawn) is handled by
## the world orchestrator calling `flush_effects()` after loading entities.

const PHASES: Array[String] = ["input", "decide", "commit", "react"]

# ============================================================
# STATE
# ============================================================

## env — see effect_apply.gd for shape. Injected at init.
var env: Dictionary

## Rules bucketed by trigger type. Within each bucket, definition order or
## topo-sorted order if before/after hints exist.
var rules_by_trigger: Dictionary = {}

## Per-tick counters and queues.
var tick_count: int = 0
var input_queue: Array = []                # queued by caller between ticks
var effect_buffer: Array = []              # [{effect, context, from_rule}]
var commit_phase_signals: Array = []       # emit during commit → drained in react
var react_phase_signals: Array = []        # emit during react → drained next tick

# Cycle warning flag (set once per load when topo-sort can't converge)
var _topo_cycle_warned: bool = false

## ADR 0017 — Spatial-LOD scheduling state. Per-rule per-entity tracking
## of "currently inside LOD radius" (for hysteresis) and "last fired tick"
## (for tick_slowed mode). Engine-private; not exposed via env.
##
## Shape: _lod_state[rule_id][entity_id] = {inside: bool, last_fired: int}
##
## Cleaned up in _on_entity_despawned to bound memory.
var _lod_state: Dictionary = {}


# ============================================================
# INIT
# ============================================================

func _init(environment: Dictionary) -> void:
	env = environment
	# Buffers consumed by the scheduler. effect_apply pushes to these via env.
	if not env.has("signal_buffer"):
		env["signal_buffer"] = []
	# Lifecycle dispatch: inline callable. effect_apply._spawn / _remove call
	# this synchronously so spawn-rules see the new entity and despawn-rules
	# see the dying entity *before* it's gone from env.entities.
	env["dispatch_lifecycle"] = Callable(self, "_dispatch_lifecycle_inline")
	# Subscribe to relation_changed events from the relation store, if present.
	var rs = env.get("relations", null)
	if rs != null and rs.has_signal("relation_added"):
		rs.relation_added.connect(_on_relation_added)
		rs.relation_removed.connect(_on_relation_removed)


func _dispatch_lifecycle_inline(kind: String, entity_id: String) -> void:
	var rules_lc: Array = rules_by_trigger.get(kind, [])
	for r in rules_lc:
		_fire_lifecycle_rule(r, entity_id, "commit")


# ============================================================
# RELATION EVENT BUFFERS (W2.4)
# ============================================================

var _relation_changes: Array = []  # [{change, type, from, to}, ...]

func _on_relation_added(type: String, from_id: String, to_id: String) -> void:
	_relation_changes.append({"change": "added", "type": type, "from": from_id, "to": to_id})

func _on_relation_removed(type: String, from_id: String, to_id: String) -> void:
	_relation_changes.append({"change": "removed", "type": type, "from": from_id, "to": to_id})


# ============================================================
# RULE REGISTRATION
# ============================================================

## Rebuild the trigger-bucketed rule map. Applies before/after topo-sort
## within each bucket.
func register_rules(rules: Array) -> void:
	rules_by_trigger.clear()
	for r in rules:
		if not (r is Rule): continue
		var tt := (r as Rule).trigger_type()
		if not rules_by_trigger.has(tt):
			rules_by_trigger[tt] = []
		(rules_by_trigger[tt] as Array).append(r)
	_topo_sort_all()


## Append rules to the existing bucket map (used by multi-level loads:
## global rules registered once, level-specific rules added on top).
func append_rules(rules: Array) -> void:
	for r in rules:
		if not (r is Rule): continue
		var tt := (r as Rule).trigger_type()
		if not rules_by_trigger.has(tt):
			rules_by_trigger[tt] = []
		(rules_by_trigger[tt] as Array).append(r)
	_topo_sort_all()


## Wipe all registered rules. Used by ADR 0006 level transition before
## reloading per-level rules + global rules.
func clear_rules() -> void:
	rules_by_trigger.clear()


## Find a registered rule by id. Used by variant overlay to apply
## rule-id-keyed field overrides post-load. O(n) — variants rarely
## override more than a handful of rules.
func get_rule_by_id(rule_id: String) -> Rule:
	for tt in rules_by_trigger.keys():
		for r in rules_by_trigger[tt]:
			if (r as Rule).id == rule_id:
				return r as Rule
	return null


func _topo_sort_all() -> void:
	for tt in rules_by_trigger.keys():
		_topo_sort_bucket(rules_by_trigger[tt])


## Adjacent-swap bubble sort using before/after hints. Fine for W1-scale rule
## counts (≤ ~50). Emits a warning if it can't converge (cycle in hints).
func _topo_sort_bucket(bucket: Array) -> void:
	var max_passes := bucket.size() * bucket.size() + 1
	var pass_count := 0
	var changed := true
	while changed and pass_count < max_passes:
		changed = false
		for i in range(bucket.size() - 1):
			var a: Rule = bucket[i]
			var b: Rule = bucket[i + 1]
			if a.runs_after(b) and not b.runs_after(a):
				bucket[i] = b
				bucket[i + 1] = a
				changed = true
		pass_count += 1
	if changed and not _topo_cycle_warned:
		EngineError.raise(env, EngineError.SCHEDULER_TOPO_CYCLE,
			"PhaseScheduler: before/after hints may contain a cycle",
			{"trigger_type": "tick"},
			"Audit rules' before/after lists for circular references; the engine fell back to JSON definition order.",
			"warning")
		_topo_cycle_warned = true


# ============================================================
# INPUTS
# ============================================================

func queue_input(action: String, params: Dictionary = {}) -> void:
	input_queue.append({"action": action, "params": params})


# ============================================================
# MAIN LOOP
# ============================================================

func tick() -> void:
	tick_count += 1
	var world_state: Dictionary = env.get("world", {})
	world_state["tick"] = tick_count

	# ADR 0017: cache LOD anchor position once per tick. Resolves from
	# world.actor_tag (the active actor). All LOD-tagged rules in this
	# tick read env.lod_anchor_position. Null if no actor entity exists.
	_compute_lod_anchor()

	# PHASE 1: input
	_phase_input()
	flush_effects()
	_drain_signals_into("decide")  # signals from input visible in decide

	# PHASE 2: decide
	_phase_decide()
	flush_effects()
	_drain_signals_into("react")
	flush_effects()  # 2026-05-05: signal-rule effects apply BEFORE react
	                 # queries state. Critical for blocker-pattern rules: a
	                 # signal rule sets a "blocked" flag that a contact rule
	                 # in react then reads. Without this flush, contact rules
	                 # see the pre-flag state. Caught during sokoban L2:
	                 # wall_blocks_push set push_blocked=1 but commit_push
	                 # still fired and pushed boxes through perimeter walls.

	# Motion is now integrated per-frame by World (see world.gd._process),
	# NOT per-tick. velocity is a state field updated at tick rate; position
	# advances continuously between ticks for smooth visuals.

	# PHASE 4: react
	_phase_react()
	flush_effects()
	# Any signals emitted during react flow to NEXT tick's input phase
	# (signal_buffer is naturally carried across ticks by being persistent in env).


func run_ticks(n: int) -> void:
	for i in range(n):
		tick()


# ============================================================
# PHASES (W1 stubs for input/react; decide + commit active)
# ============================================================

## Phase 1 (W2.2): drain input queue, fire matching `input` rules.
## Each input event becomes a rule context with flattened payload params.
func _phase_input() -> void:
	if input_queue.is_empty(): return
	var events := input_queue.duplicate()
	input_queue.clear()
	var input_rules: Array = rules_by_trigger.get("input", [])
	for ev in events:
		var action := str(ev.get("action", ""))
		var params: Dictionary = (ev.get("params", {}) as Dictionary).duplicate()
		for r in input_rules:
			var rule: Rule = r
			if str(rule.trigger_param("action", "")) != action: continue
			_fire_payload_rule(rule, params, "input")


## Phase 2 (W1 + W2.1): tick rules + signal rules whose trigger fired before
## decide (signals queued during prior tick's react, or this tick's input).
func _phase_decide() -> void:
	# Tick rules
	var tick_rules: Array = rules_by_trigger.get("tick", [])
	for r in tick_rules:
		var rule: Rule = r
		var interval: int = int(rule.trigger_param("interval", 1))
		if interval <= 0: continue
		if tick_count % interval != 0: continue
		_fire_scan_rule(rule)


## Phase 4 (W2.3, W2.4, W3.2): contact + lifecycle + relation_changed dispatch.
## Signal dispatch already happened in _drain_signals_into("react").
func _phase_react() -> void:
	# W3.2 — contact rules (pair matching via spatial index)
	var contact_rules: Array = rules_by_trigger.get("contact", [])
	for r in contact_rules:
		_fire_contact_rule(r)

	# Drain relation_changed events that occurred since last drain.
	if not _relation_changes.is_empty():
		var changes := _relation_changes.duplicate()
		_relation_changes.clear()
		var rules_rc: Array = rules_by_trigger.get("relation_changed", [])
		for ch in changes:
			for rr in rules_rc:
				var rule: Rule = rr
				if rule.trigger.has("relation") and str(rule.trigger["relation"]) != ch["type"]: continue
				if rule.trigger.has("change") and str(rule.trigger["change"]) != ch["change"]: continue
				var ctx := {"from": ch["from"], "to": ch["to"], "self": ch["from"]}
				_fire_payload_rule(rule, ctx, "react")


## Fire a contact rule (W3.2). Query has `a`, `b`, `radius`. For each entity
## matching `a`, find entities within `radius` matching `b`. Effects queued
## with `a`/`b` context bindings.
##
## Optimization: spatial index narrows the per-`a` lookup. Without index,
## falls back to O(n²) pair scan.
func _fire_contact_rule(rule: Rule) -> void:
	var query = rule.query
	if not (query is Dictionary): return
	if not (query.has("a") and query.has("b")): return
	var a_spec: Dictionary = query["a"]
	var b_spec: Dictionary = query["b"]
	var radius: float = float(query.get("radius", 1.0))
	var chance: float = rule.chance
	# `once_per_a` fires the rule at most once per `a` entity per tick
	# (first matching `b` becomes the target, rest are skipped). Used by
	# tower-defense / shooter targeting where one entity should pick one
	# target per cooldown cycle — without it, contact rules fire per pair
	# and a tower in range of N enemies fires N projectiles per tick.
	var once_per_a: bool = bool(query.get("once_per_a", false))

	# Find all 'a' candidates (full scan — entities matching a's filters)
	var a_candidates: Array = QueryLib.run(a_spec, env, {})
	for a_ent in a_candidates:
		if not (a_ent is Entity): continue
		var a_pos: Vector2 = (a_ent as Entity).get_planar_position()
		# Find b's near a, filtered by b_spec
		var ctx_for_b := {"_origin_position": a_pos, "self": (a_ent as Entity).instance_id}
		var b_spec_with_radius: Dictionary = b_spec.duplicate()
		b_spec_with_radius["radius"] = radius
		var b_candidates: Array = QueryLib.run(b_spec_with_radius, env, ctx_for_b)
		var fired_for_a := false
		for b_ent in b_candidates:
			if not (b_ent is Entity): continue
			if a_ent == b_ent: continue
			if chance < 1.0 and randf() > chance: continue
			var ctx: Dictionary = {
				"a": (a_ent as Entity).instance_id,
				"b": (b_ent as Entity).instance_id,
				"a_entity": a_ent,
				"b_entity": b_ent,
				"_phase": "react",
			}
			if rule.require is Dictionary and not _require_ok(rule.require, ctx):
				continue
			for e in rule.effects:
				_enqueue(e, ctx, rule.id)
			if once_per_a:
				fired_for_a = true
				break
		if once_per_a and fired_for_a:
			continue


# ============================================================
# SIGNAL & LIFECYCLE DISPATCH (W2.1, W2.3)
# ============================================================

## Drain env.signal_buffer; fire matching signal-trigger rules. `into_phase`
## is the phase tag for the resulting rule contexts ("decide" or "react").
func _drain_signals_into(into_phase: String) -> void:
	var buf: Array = env.get("signal_buffer", [])
	if buf.is_empty(): return
	var sigs := buf.duplicate()
	buf.clear()
	var signal_rules: Array = rules_by_trigger.get("signal", [])
	for sig in sigs:
		var name := str(sig.get("name", ""))
		var payload: Dictionary = (sig.get("payload", {}) as Dictionary).duplicate()
		for r in signal_rules:
			var rule: Rule = r
			if str(rule.trigger_param("name", "")) != name: continue
			_fire_payload_rule(rule, payload, into_phase)


## (Lifecycle dispatch is now inline via env.dispatch_lifecycle callable; see
## _dispatch_lifecycle_inline above. Buffer-based drain was removed because
## despawn events would drain AFTER the entity was already removed.)


# ============================================================
# MOTION INTEGRATOR (W2.5) — engine built-in, not a rule
# ============================================================

## After commit phase, advance every entity with non-zero velocity.
## state.position += state.velocity. Dimension-agnostic — works for Vector2 + Vector3.
func _apply_motion() -> void:
	var entities: Dictionary = env.get("entities", {})
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity): continue
		var v = (ent as Entity).get_velocity()
		if v == null: continue
		# Skip if zero (cheap)
		if v is Vector2 and v == Vector2.ZERO: continue
		if v is Vector3 and v == Vector3.ZERO: continue
		var p = (ent as Entity).get_position()
		if p is Vector2 and v is Vector2:
			(ent as Entity).set_position((p as Vector2) + v)
		elif p is Vector3 and v is Vector3:
			(ent as Entity).set_position((p as Vector3) + v)
		elif p is Vector2 and v is Vector3:
			# Mixed: project velocity to planar XZ
			(ent as Entity).set_position(p + Vector2(v.x, v.z))


# ============================================================
# RULE FIRING
# ============================================================

## Fire a rule whose query scans all entities (tick rules). For each match,
## bind `self` in context, validate require, and enqueue effects.
func _fire_scan_rule(rule: Rule) -> void:
	if rule.chance < 1.0 and randf() > rule.chance: return
	var base_ctx: Dictionary = {"_phase": "decide"}

	if rule.query is Dictionary:
		var matches: Array = QueryLib.run(rule.query, env, base_ctx)
		for ent in matches:
			if not (ent is Entity): continue
			# ADR 0017: spatial-LOD filter. Skip entities outside the LOD
			# radius (per the rule's hysteresis state); rate-limit firing
			# for tick_slowed fallback mode.
			if rule.lod is Dictionary and not _lod_should_fire(rule, ent):
				continue
			var ctx := base_ctx.duplicate()
			ctx["self"] = (ent as Entity).instance_id
			ctx["self_entity"] = ent
			if rule.require is Dictionary and not _require_ok(rule.require, ctx):
				continue
			for e in rule.effects:
				_enqueue(e, ctx, rule.id)
	else:
		if rule.require is Dictionary and not _require_ok(rule.require, base_ctx):
			return
		for e in rule.effects:
			_enqueue(e, base_ctx, rule.id)


## Fire a rule whose context is supplied by an event payload (input, signal,
## relation_changed). Different from _fire_scan_rule: no entity scan — the
## rule operates on whatever is in the payload, optionally validated by
## `require`. If `query` is present, scan and bind self per match (rare for
## payload-driven rules but allowed).
func _fire_payload_rule(rule: Rule, payload: Dictionary, phase: String) -> void:
	if rule.chance < 1.0 and randf() > rule.chance: return
	var base_ctx: Dictionary = payload.duplicate()
	base_ctx["_phase"] = phase

	if rule.require is Dictionary and not _require_ok(rule.require, base_ctx):
		return

	if rule.query is Dictionary:
		var matches: Array = QueryLib.run(rule.query, env, base_ctx)
		for ent in matches:
			if not (ent is Entity): continue
			var ctx := base_ctx.duplicate()
			ctx["self"] = (ent as Entity).instance_id
			ctx["self_entity"] = ent
			for e in rule.effects:
				_enqueue(e, ctx, rule.id)
	else:
		for e in rule.effects:
			_enqueue(e, base_ctx, rule.id)


## Fire a lifecycle rule (spawn/despawn) — the rule's `self` is the
## spawning/despawning entity. Optional `query` filters by that entity's
## tags/state.
func _fire_lifecycle_rule(rule: Rule, entity_id: String, phase: String) -> void:
	var entities: Dictionary = env.get("entities", {})
	if not entities.has(entity_id): return
	var ent: Entity = entities[entity_id]
	var ctx: Dictionary = {"self": entity_id, "self_entity": ent, "_phase": phase}

	# Filter mode: query treated as condition on the spawning/despawning entity
	if rule.query is Dictionary:
		if not QueryLib.matches(ent, rule.query, env, ctx): return

	if rule.require is Dictionary and not _require_ok(rule.require, ctx): return

	if rule.chance < 1.0 and randf() > rule.chance: return

	for e in rule.effects:
		_enqueue(e, ctx, rule.id)


## Validate every named context entity against its require-spec.
func _require_ok(req: Dictionary, ctx: Dictionary) -> bool:
	var all: Dictionary = env.get("entities", {})
	for name in req:
		var id = ctx.get(str(name), null)
		if id == null: return false
		var sid := str(id)
		if not all.has(sid): return false
		var ent = all[sid]
		if not (ent is Entity): return false
		if not QueryLib.matches(ent, req[name], env, ctx):
			return false
	return true


# ============================================================
# EFFECT BUFFER
# ============================================================

func _enqueue(effect: Dictionary, ctx: Dictionary, from_rule: String) -> void:
	# 2.6a: stamp the rule id into the context so EffectApply can attribute
	# downstream errors to the rule that queued them.
	var ctx_copy: Dictionary = ctx.duplicate()
	ctx_copy["_rule_id"] = from_rule
	effect_buffer.append({
		"effect": effect,
		"context": ctx_copy,
		"from_rule": from_rule,
	})


## Drain the buffer, apply each effect via EffectApply. Called multiple times
## per tick (after each phase's enqueues) so that spawns/removes within a
## phase commit before the next phase reads state.
func flush_effects() -> void:
	if effect_buffer.is_empty(): return
	var batch = effect_buffer
	effect_buffer = []
	for item in batch:
		EffectApply.apply(item["effect"], env, item["context"])


# ============================================================
# SPATIAL-LOD SCHEDULING (ADR 0017)
# ============================================================

## Compute the LOD anchor position for this tick. Stored in
## env.lod_anchor_position so all LOD-tagged rules in this tick share one
## resolution. Active actor tag comes from the World node (read via env's
## parent backref) — fallback "player" if World isn't accessible.
func _compute_lod_anchor() -> void:
	var entities: Dictionary = env.get("entities", {})
	# Read actor_tag from World if available; default "player".
	var parent_node = env.get("parent", null)
	var actor_tag := "player"
	if parent_node != null and parent_node.get("actor_tag") != null:
		actor_tag = str(parent_node.get("actor_tag"))
	# Find the active actor entity (first match)
	var anchor = null
	for ent in entities.values():
		if ent is Entity and (ent as Entity).has_tag(actor_tag):
			anchor = (ent as Entity).get_planar_position()
			break
	env["lod_anchor_position"] = anchor


## Decide if an LOD-tagged rule should fire on the given entity this tick.
## Implements:
##   1. Hysteresis: entity is "inside" once it crosses enter_radius;
##      stays inside until leave_radius (so it doesn't flip-flop).
##   2. Fallback: when entity is outside, either skip (`freeze`) or
##      rate-limit (`tick_slowed:N`).
func _lod_should_fire(rule: Rule, ent: Entity) -> bool:
	var lod: Dictionary = rule.lod as Dictionary
	var anchor = env.get("lod_anchor_position", null)
	if anchor == null:
		# No active actor → no anchor → all rules run as if no LOD
		# (graceful fallback; better to over-tick than to silently freeze).
		return true
	var entity_pos = ent.get_planar_position()
	if entity_pos == null: return true
	# Distance check (works for Vector2 OR Vector3 — both have distance_to)
	var dist: float = (entity_pos as Vector2).distance_to(anchor as Vector2) \
		if entity_pos is Vector2 else (entity_pos as Vector3).distance_to(anchor as Vector3)
	# Update hysteresis state
	var was_inside := _lod_get_inside(rule.id, ent.instance_id)
	var enter_r := float(lod.get("enter_radius", 200.0))
	var leave_r := float(lod.get("leave_radius", enter_r * 1.10))
	var now_inside: bool
	if was_inside:
		# Was inside — stays inside until past leave_radius
		now_inside = dist <= leave_r
	else:
		# Was outside — must cross enter_radius to come inside
		now_inside = dist <= enter_r
	if now_inside != was_inside:
		_lod_set_inside(rule.id, ent.instance_id, now_inside)
	# Inside → fire normally
	if now_inside: return true
	# Outside → apply fallback mode
	var fallback := str(lod.get("fallback", "freeze"))
	if fallback == "freeze":
		return false
	if fallback.begins_with("tick_slowed:"):
		var slow_factor := float(fallback.substr(12))
		# tick_slowed:0.5 = fire at half rate (every 2 ticks instead of every tick)
		# tick_slowed:0.1 = fire at 1/10 rate
		if slow_factor <= 0.0: return false
		var interval := int(round(1.0 / slow_factor))
		if interval <= 1: return true  # 1.0 or higher = full rate
		var last := _lod_get_last_fired(rule.id, ent.instance_id)
		if tick_count - last >= interval:
			_lod_set_last_fired(rule.id, ent.instance_id, tick_count)
			return true
		return false
	# Unknown fallback — fail-open (fire) so authors notice via behavior
	return true


# State accessors
func _lod_get_inside(rule_id: String, entity_id: String) -> bool:
	var by_entity = _lod_state.get(rule_id, null)
	if not (by_entity is Dictionary): return false
	var rec = (by_entity as Dictionary).get(entity_id, null)
	if not (rec is Dictionary): return false
	return bool((rec as Dictionary).get("inside", false))


func _lod_set_inside(rule_id: String, entity_id: String, value: bool) -> void:
	if not _lod_state.has(rule_id):
		_lod_state[rule_id] = {}
	var by_entity: Dictionary = _lod_state[rule_id]
	if not by_entity.has(entity_id):
		by_entity[entity_id] = {}
	(by_entity[entity_id] as Dictionary)["inside"] = value


func _lod_get_last_fired(rule_id: String, entity_id: String) -> int:
	var by_entity = _lod_state.get(rule_id, null)
	if not (by_entity is Dictionary): return -100000
	var rec = (by_entity as Dictionary).get(entity_id, null)
	if not (rec is Dictionary): return -100000
	return int((rec as Dictionary).get("last_fired", -100000))


func _lod_set_last_fired(rule_id: String, entity_id: String, value: int) -> void:
	if not _lod_state.has(rule_id):
		_lod_state[rule_id] = {}
	var by_entity: Dictionary = _lod_state[rule_id]
	if not by_entity.has(entity_id):
		by_entity[entity_id] = {}
	(by_entity[entity_id] as Dictionary)["last_fired"] = value


## Called from World on entity despawn to GC LOD state.
func clear_lod_state_for_entity(entity_id: String) -> void:
	for rule_id in _lod_state.keys():
		var by_entity: Dictionary = _lod_state[rule_id]
		by_entity.erase(entity_id)
