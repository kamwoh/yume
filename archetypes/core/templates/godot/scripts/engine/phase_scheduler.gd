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


# ============================================================
# INIT
# ============================================================

func _init(environment: Dictionary) -> void:
	env = environment


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
		push_warning("PhaseScheduler: before/after hints may contain a cycle")
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

	_phase_input()
	flush_effects()

	_phase_decide()

	# PHASE 3: commit — effects queued in decide apply here. Signals emitted
	# during commit go into commit_phase_signals to be consumed in react.
	flush_effects()

	_phase_react()
	flush_effects()

	# Rotate: react emits → next tick's input queue (as synthetic inputs)
	# For W1 we just discard; signal trigger dispatch lands in W2.
	react_phase_signals.clear()


func run_ticks(n: int) -> void:
	for i in range(n):
		tick()


# ============================================================
# PHASES (W1 stubs for input/react; decide + commit active)
# ============================================================

func _phase_input() -> void:
	# W2 extension: drain input_queue, match against "input"-trigger rules,
	# enqueue effects with flattened input params as context.
	pass


func _phase_decide() -> void:
	# Tick rules
	var tick_rules: Array = rules_by_trigger.get("tick", [])
	for r in tick_rules:
		var rule: Rule = r
		var interval: int = int(rule.trigger_param("interval", 1))
		if interval <= 0: continue
		if tick_count % interval != 0: continue
		_fire_scan_rule(rule)

	# W2 extension: signal rules for pre-tick signals.


func _phase_react() -> void:
	# W2 extension: drain commit_phase_signals → fire signal rules.
	# W3 extension: fire contact rules against post-commit state.
	# Lifecycle relation_changed triggers also land in W2.
	pass


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
	effect_buffer.append({
		"effect": effect,
		"context": ctx.duplicate(),
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
