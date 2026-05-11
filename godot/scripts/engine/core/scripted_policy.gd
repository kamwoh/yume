extends RefCounted
class_name ScriptedPolicy

## ADR 0018 Phase A — In-process scripted-JSON actor policy.
##
## Each policy file declares `rules: [{id, if, then}]`. The `if` clause
## is a condition tree built from primitives (world_state, distance_to,
## actor_state, all/any). The `then` clause is an Array of Action
## Dictionaries — same shape as input events queued via
## scheduler.queue_input.
##
## Per ADR 0018 + TD review: pure-JSON path; no GDScript per game.
## Path B (godot_resource) deferred to Phase B for behavior-tree libraries.
##
## Protocol:
##   policy.decide(observation, actor_state) -> Array[Action]
## Where:
##   observation = Dict {nearby: Array, world_state: Dict, signals: Array}
##   actor_state = Dict {position: Vector2, state: Dict, tags: Array}
##   Action      = Dict {action: "<name>", ...params}
##
## Semantics: rules evaluated in JSON definition order; FIRST matching
## rule's `then` actions are returned. (Behavior-tree-style: select
## highest-priority matching branch.) If no rule matches, returns [].


# ============================================================
# STATE
# ============================================================

var _rules: Array = []   # array of {id, if, then}
var _id: String = ""     # debug label


# ============================================================
# LOADING
# ============================================================

## Load a scripted policy from JSON. Path is relative to data_root
## (e.g. "policies/guard_basic.json"). Returns null on parse failure.
static func load_from_file(path: String) -> ScriptedPolicy:
	if not FileAccess.file_exists(path):
		push_warning("ScriptedPolicy: file not found: %s" % path)
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return null
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		push_warning("ScriptedPolicy: invalid JSON: %s" % path)
		return null
	var p := ScriptedPolicy.new()
	p._id = path
	var raw_rules = (data as Dictionary).get("rules", [])
	if raw_rules is Array:
		p._rules = raw_rules
	return p


# ============================================================
# DECISION
# ============================================================

## Iterate rules in order; first match's `then` actions are returned.
## Each action gets the actor_id stamped in if not present.
func decide(observation: Dictionary, actor_state: Dictionary) -> Array:
	for r in _rules:
		if not (r is Dictionary): continue
		var rule: Dictionary = r
		var if_clause = rule.get("if", null)
		# No `if` clause = always-true (default action); useful as
		# a fallback rule at the bottom of the list.
		if if_clause == null or _eval_condition(if_clause, observation, actor_state):
			var then_v = rule.get("then", [])
			if then_v is Array:
				return _stamp_actor((then_v as Array).duplicate(true), actor_state)
			elif then_v is Dictionary:
				return _stamp_actor([(then_v as Dictionary).duplicate(true)], actor_state)
	return []


# ============================================================
# CONDITION EVALUATION
# ============================================================

## Recursive condition evaluator. Supports:
##   {world_state: {key: <key>, op: ">=", value: <v>}}
##   {actor_state: {field: <field>, op: "==", value: <v>}}
##   {distance_to: {target: <tag>, op: "<", value: <number>}}
##   {nearby_count: {tag: <tag>, op: ">", value: <n>}}
##   {all: [<cond>, <cond>, ...]}    — AND
##   {any: [<cond>, <cond>, ...]}    — OR
##   {not: <cond>}                    — negation
func _eval_condition(cond, obs: Dictionary, st: Dictionary) -> bool:
	if not (cond is Dictionary): return false
	var c: Dictionary = cond
	if c.has("all"):
		for sub in c["all"]:
			if not _eval_condition(sub, obs, st): return false
		return true
	if c.has("any"):
		for sub in c["any"]:
			if _eval_condition(sub, obs, st): return true
		return false
	if c.has("not"):
		return not _eval_condition(c["not"], obs, st)
	if c.has("world_state"):
		return _eval_kv("world_state", c["world_state"],
			(obs.get("world_state", {}) as Dictionary))
	if c.has("actor_state"):
		return _eval_kv("actor_state", c["actor_state"],
			(st.get("state", {}) as Dictionary), "field")
	if c.has("distance_to"):
		return _eval_distance(c["distance_to"], obs, st)
	if c.has("nearby_count"):
		return _eval_nearby_count(c["nearby_count"], obs)
	push_warning("ScriptedPolicy[%s]: unknown condition: %s" % [_id, c.keys()])
	return false


## Compare a value-from-dict against a literal via op.
## key_field: which sub-key holds the dict-key name ("key" or "field").
static func _eval_kv(label: String, spec, source: Dictionary,
					  key_field: String = "key") -> bool:
	if not (spec is Dictionary): return false
	var s: Dictionary = spec
	var key := str(s.get(key_field, ""))
	if key == "" or not source.has(key): return false
	return _compare(source[key], str(s.get("op", "==")), s.get("value", null))


## distance_to: actor → target tag (first matching nearby entity).
## `target: "active_actor"` resolves to obs.active_actor_position.
func _eval_distance(spec, obs: Dictionary, st: Dictionary) -> bool:
	if not (spec is Dictionary): return false
	var s: Dictionary = spec
	var target := str(s.get("target", ""))
	if target == "": return false
	var actor_pos = st.get("position", null)
	if actor_pos == null: return false
	var target_pos = null
	if target == "active_actor":
		target_pos = obs.get("active_actor_position", null)
	else:
		# Find first nearby entity with matching tag
		for e in obs.get("nearby", []):
			if not (e is Dictionary): continue
			var tags = (e as Dictionary).get("tags", [])
			if tags is Array and target in (tags as Array):
				target_pos = (e as Dictionary).get("position", null)
				break
	if target_pos == null: return false
	# Distance (Vector2 or Vector3)
	var dist := 0.0
	if actor_pos is Vector2 and target_pos is Vector2:
		dist = (actor_pos as Vector2).distance_to(target_pos as Vector2)
	elif actor_pos is Vector3 and target_pos is Vector3:
		dist = (actor_pos as Vector3).distance_to(target_pos as Vector3)
	else:
		return false
	return _compare(dist, str(s.get("op", "<")), s.get("value", 0))


## nearby_count: how many nearby entities have tag X.
static func _eval_nearby_count(spec, obs: Dictionary) -> bool:
	if not (spec is Dictionary): return false
	var s: Dictionary = spec
	var tag := str(s.get("tag", ""))
	if tag == "": return false
	var count := 0
	for e in obs.get("nearby", []):
		if not (e is Dictionary): continue
		var tags = (e as Dictionary).get("tags", [])
		if tags is Array and tag in (tags as Array):
			count += 1
	return _compare(count, str(s.get("op", ">=")), s.get("value", 1))


## Generic comparison: a OP b. Operators: ==, !=, <, <=, >, >=.
static func _compare(a, op: String, b) -> bool:
	match op:
		"==": return a == b
		"!=": return a != b
		"<":  return float(a) < float(b)
		"<=": return float(a) <= float(b)
		">":  return float(a) > float(b)
		">=": return float(a) >= float(b)
	return false


## Stamp the actor_id onto each action so the scheduler routes input
## to the right entity. If action already has actor_id, leave it.
static func _stamp_actor(actions: Array, actor_state: Dictionary) -> Array:
	var actor_id := str(actor_state.get("id", ""))
	for a in actions:
		if a is Dictionary and not (a as Dictionary).has("actor_id"):
			(a as Dictionary)["actor_id"] = actor_id
	return actions
