extends RefCounted
class_name Rule

## Primitive #3 — Rule.
##
## Contract: docs/30_framework_primitives.md §3
##
## Shape (JSON):
##   {id, trigger, query?, require?, chance?, effect, before?, after?, scope?}
##
## Rules are loaded from world/physics.json + game/rules.json (ADR 0009)
## into typed Rule instances. Trigger dispatch, query evaluation, and
## effect application are separate modules; Rule itself is just a
## structural carrier + validator + (W4) Expression cache.
##
## Within-phase ordering is JSON definition order with optional before/after
## hints. Priorities are deliberately not supported — named phases + JSON order
## + hints cover every real case without becoming a maintenance ratchet.

const VALID_TRIGGERS: Array = [
	"tick",
	"frame_tick",
	"contact",
	"signal",
	"input",
	"spawn",
	"despawn",
	"relation_changed",
	"scheduled",
]

# ============================================================
# FIELDS
# ============================================================

var id: String = ""
var trigger: Dictionary = {}
var query: Variant = null  # null or Dictionary
var require: Variant = null  # null or Dictionary
var chance: float = 1.0
var effects: Array = []  # always an Array of effect dicts (singleton normalized)
var before_hints: Array[String] = []
var after_hints: Array[String] = []
var scope: String = ""
## ADR 0017 — spatial-LOD scheduling. null = no LOD (run on all entities,
## current behavior). Otherwise:
##   {anchor: "active_actor"|"camera"|"<tag>",
##    enter_radius: float, leave_radius: float,
##    fallback: "freeze"|"tick_slowed:N"}
var lod: Variant = null

## W4 populates this — maps formula-string → parsed Expression. Lives on the
## rule so that the formula's lifetime matches the rule's, not global.
var _expression_cache: Dictionary = {}

# ============================================================
# LOADING
# ============================================================


static func from_dict(d: Dictionary) -> Rule:
	var r := Rule.new()
	r.id = str(d.get("id", ""))
	r.trigger = (d.get("trigger", {}) as Dictionary).duplicate(true)
	if d.has("query") and d["query"] is Dictionary:
		r.query = (d["query"] as Dictionary).duplicate(true)
	if d.has("require") and d["require"] is Dictionary:
		r.require = (d["require"] as Dictionary).duplicate(true)
	r.chance = float(d.get("chance", 1.0))
	r.effects = _normalize_effects(d.get("effect", []))
	r.before_hints = _as_string_array(d.get("before", []))
	r.after_hints = _as_string_array(d.get("after", []))
	r.scope = str(d.get("scope", ""))
	if d.has("lod") and d["lod"] is Dictionary:
		r.lod = _normalize_lod(d["lod"] as Dictionary)
	return r


## ADR 0017 — normalize LOD config. Supports two forms:
##   1. {radius: 200, ...}  → expanded to enter=190, leave=210 (5% hysteresis)
##   2. {enter_radius: 200, leave_radius: 240, ...}  → used as-is
## Warns if leave_radius <= enter_radius (no hysteresis = boundary jitter).
static func _normalize_lod(raw: Dictionary) -> Dictionary:
	var out: Dictionary = raw.duplicate(true)
	if not out.has("anchor"):
		out["anchor"] = "active_actor"
	if not out.has("fallback"):
		out["fallback"] = "freeze"
	# Shorthand: single radius → 5% hysteresis on each side
	if out.has("radius") and not (out.has("enter_radius") or out.has("leave_radius")):
		var r := float(out["radius"])
		out["enter_radius"] = r * 0.95
		out["leave_radius"] = r * 1.05
	# Defaults if neither form provided
	if not out.has("enter_radius"):
		out["enter_radius"] = 200.0
	if not out.has("leave_radius"):
		out["leave_radius"] = float(out["enter_radius"]) * 1.10
	# Hysteresis check
	if float(out["leave_radius"]) <= float(out["enter_radius"]):
		push_warning(
			(
				"Rule lod: leave_radius (%.1f) <= enter_radius (%.1f) — entities will flip-flop on the boundary"
				% [out["leave_radius"], out["enter_radius"]]
			)
		)
	return out


## Load a list of Rule objects from a rules JSON file (any of
## world/physics.json, game/rules.json, levels/<x>/rules.json).
##
## Pass `env` to capture load-time errors as structured records in
## `env.error_buffer`. Without env, errors only hit the dev console.
##
## ADR 0019: optional `macro_expander` substitutes macro effect references
## with primitive sequences before Rule.from_dict parses them. When null
## (no macros.json for this game), rules pass through unchanged.
static func load_from_file(
	path: String, env: Dictionary = {}, macro_expander = null
) -> Array[Rule]:
	var out: Array[Rule] = []
	if not FileAccess.file_exists(path):
		EngineError.raise(
			env,
			EngineError.RULE_FILE_MISSING,
			"Rules file not found: %s" % path,
			{"file": path},
			"Check that the path exists relative to res:// and is spelled correctly."
		)
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	var raw_text := f.get_as_text()
	var data = JSON.parse_string(raw_text)
	if not (data is Dictionary):
		EngineError.raise(
			env,
			EngineError.RULE_INVALID_JSON,
			"Rules file is not valid JSON: %s" % path,
			{"file": path},
			"Run the file through a JSON linter — top-level must be an object with a 'rules' array."
		)
		return out
	# ADR 0027: expand @lib.X / $extends / $include refs before macros.
	# $include splices lib rule arrays into the parent rules array.
	var resolved = LibResolver.resolve(data)
	if resolved is Dictionary:
		data = resolved
	var list = data.get("rules", [])
	if not (list is Array):
		EngineError.raise(
			env,
			EngineError.RULE_LIST_NOT_ARRAY,
			"%s: 'rules' must be an array" % path,
			{"file": path, "field": "rules", "got_type": _type_name(list)},
			'Wrap your rule entries in an array: { "rules": [ {...}, {...} ] }.'
		)
		return out
	# ADR 0027 condition 3: id-collision detection on $include splice.
	# A rule whose `id` already appeared in this load's rules array (from
	# a $include or hand-authored sibling) is an error — rename either side
	# to disambiguate. NB: only checks within THIS file. Cross-file dup-id
	# is the scheduler's job (rules_by_trigger handles it).
	var seen_ids: Dictionary = {}
	for entry in list:
		if not (entry is Dictionary):
			continue
		var rid := str((entry as Dictionary).get("id", ""))
		if rid == "":
			continue
		if seen_ids.has(rid):
			var prev_origin: String = str(seen_ids[rid])
			var cur_origin: String = str((entry as Dictionary).get("_origin", "(local)"))
			EngineError.raise(
				env,
				EngineError.RULE_DUPLICATE_ID,
				(
					"%s: duplicate rule id '%s' (sources: %s vs %s)"
					% [path, rid, prev_origin, cur_origin]
				),
				{
					"file": path,
					"rule_id": rid,
					"first_origin": prev_origin,
					"second_origin": cur_origin
				},
				(
					"Rename one of the colliding rules. If a $include'd lib bundle "
					+ "has the conflicting id, fork the bundle or rename the local rule."
				)
			)
		seen_ids[rid] = (entry as Dictionary).get("_origin", "(local)")
	# ADR 0019: expand macros before parsing into Rule instances. After
	# expansion, every effect's `type` is a primitive (state_set, spawn, ...).
	# Rule.from_dict sees only primitives — no macro logic at runtime.
	if macro_expander != null and macro_expander.has_method("expand_rules"):
		list = macro_expander.expand_rules(list as Array, env)
	for entry in list:
		if entry is Dictionary:
			out.append(Rule.from_dict(entry))
	return out


# ============================================================
# VALIDATION
# ============================================================


## Validate a list of loaded rules. Returns [] if valid, otherwise an array
## of structured error records (`EngineError.make`-shaped dicts).
##
## 2.6a change: return type is `Array[Dictionary]` (was `Array[String]`) so
## downstream agents can match on `record.code`. Use `record.what` for the
## human-readable summary.
##
## Scope: structural checks only (id uniqueness, trigger type, chance range,
## effect list has type). Deeper checks live elsewhere:
##   - query syntax        → query.gd (W1.5)
##   - effect type validity → effect_apply.gd (W1.6)
##   - formula parseability → formula.gd (W4)
##   - ref integrity        → schema validator (W1.13)
static func validate_all(rules: Array) -> Array[Dictionary]:
	var errors: Array[Dictionary] = []
	var seen: Dictionary = {}
	for i in range(rules.size()):
		var r = rules[i]
		if not (r is Rule):
			errors.append(
				EngineError.make(
					EngineError.RULE_NOT_INSTANCE,
					"Entry %d is not a Rule instance" % i,
					{"index": i, "got_type": _type_name(r)},
					"Use Rule.from_dict() before passing to validate_all."
				)
			)
			continue
		var rule: Rule = r
		if rule.id == "":
			errors.append(
				EngineError.make(
					EngineError.RULE_MISSING_ID,
					"Rule at index %d has no id" % i,
					{"index": i, "field": "id"},
					"Add a unique 'id' string to this rule."
				)
			)
			continue
		if seen.has(rule.id):
			errors.append(
				EngineError.make(
					EngineError.RULE_DUPLICATE_ID,
					"Duplicate rule id: %s" % rule.id,
					{"rule_id": rule.id, "index": i, "field": "id"},
					"Rename one of the duplicates so every rule has a unique id."
				)
			)
		seen[rule.id] = true

		var tt := rule.trigger_type()
		if tt == "":
			errors.append(
				EngineError.make(
					EngineError.RULE_TRIGGER_MISSING,
					"Rule '%s': trigger.type missing" % rule.id,
					{"rule_id": rule.id, "field": "trigger.type"},
					'Add a trigger object: e.g. {"type": "tick", "interval": 1}.'
				)
			)
		elif not (tt in VALID_TRIGGERS):
			errors.append(
				EngineError.make(
					EngineError.RULE_TRIGGER_INVALID,
					"Rule '%s': invalid trigger type '%s'" % [rule.id, tt],
					{
						"rule_id": rule.id,
						"field": "trigger.type",
						"got": tt,
						"valid": VALID_TRIGGERS
					},
					"Use one of: %s." % ", ".join(VALID_TRIGGERS)
				)
			)

		if rule.effects.is_empty():
			errors.append(
				EngineError.make(
					EngineError.RULE_EFFECT_EMPTY,
					"Rule '%s': effect list is empty" % rule.id,
					{"rule_id": rule.id, "field": "effect"},
					'Add at least one effect dict, e.g. {"type": "state_set", ...}.'
				)
			)
		for j in range(rule.effects.size()):
			var eff = rule.effects[j]
			if not (eff is Dictionary):
				errors.append(
					EngineError.make(
						EngineError.RULE_EFFECT_NOT_DICT,
						"Rule '%s' effect[%d] is not a dictionary" % [rule.id, j],
						{
							"rule_id": rule.id,
							"field": "effect",
							"index": j,
							"got_type": _type_name(eff)
						},
						"Each effect entry must be a JSON object with a 'type' field."
					)
				)
			elif not eff.has("type") or str(eff["type"]) == "":
				(
					errors
					. append(
						(
							EngineError
							. make(
								EngineError.RULE_EFFECT_MISSING_TYPE,
								"Rule '%s' effect[%d] missing 'type'" % [rule.id, j],
								{"rule_id": rule.id, "field": "effect.type", "index": j},
								"Add a 'type' field naming one of the supported effects (state_set, spawn, ...)."
							)
						)
					)
				)

		if rule.chance < 0.0 or rule.chance > 1.0:
			errors.append(
				EngineError.make(
					EngineError.RULE_CHANCE_OUT_OF_RANGE,
					"Rule '%s': chance %.2f out of [0.0, 1.0]" % [rule.id, rule.chance],
					{"rule_id": rule.id, "field": "chance", "got": rule.chance},
					"Set 'chance' to a value between 0.0 and 1.0 (default 1.0)."
				)
			)
	return errors


# ============================================================
# INSTANCE ACCESSORS
# ============================================================


func trigger_type() -> String:
	return str(trigger.get("type", ""))


func trigger_param(key: String, default = null):
	return (trigger as Dictionary).get(key, default)


## Does self declare a dependency on `other`?
## True if self.before lists other.id OR other.after lists self.id.
func runs_before(other: Rule) -> bool:
	return other.id in before_hints or id in other.after_hints


func runs_after(other: Rule) -> bool:
	return other.id in after_hints or id in other.before_hints


# ============================================================
# EXPRESSION CACHE (filled lazily in W4 when formulas are wired up)
# ============================================================


## Stored by source string. W4's formula.gd layer owns parse + whitelist;
## Rule merely holds the cache so parsed expressions live as long as the rule.
func cache_expression(source: String, expr: Expression) -> void:
	_expression_cache[source] = expr


func cached_expression(source: String) -> Expression:
	return _expression_cache.get(source, null)


# ============================================================
# UTIL
# ============================================================


static func _normalize_effects(e) -> Array:
	if e is Dictionary:
		return [(e as Dictionary).duplicate(true)]
	if e is Array:
		return (e as Array).duplicate(true)
	return []


static func _as_string_array(v) -> Array[String]:
	var out: Array[String] = []
	if v is String:
		out.append(str(v))
	elif v is Array:
		for s in v:
			out.append(str(s))
	return out


## Human-readable type label for error reports. Used in 2.6a structured
## errors so an LLM reader sees "Array" instead of "5" (TYPE_ARRAY).
static func _type_name(v) -> String:
	if v == null:
		return "null"
	if v is String:
		return "String"
	if v is int:
		return "int"
	if v is float:
		return "float"
	if v is bool:
		return "bool"
	if v is Array:
		return "Array"
	if v is Dictionary:
		return "Dictionary"
	if v is Rule:
		return "Rule"
	return type_string(typeof(v))
