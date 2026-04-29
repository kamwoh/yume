extends RefCounted
class_name Rule

## Primitive #3 — Rule.
##
## Contract: docs/30_framework_primitives.md §3
##
## Shape (JSON):
##   {id, trigger, query?, require?, chance?, effect, before?, after?, scope?}
##
## Rules are loaded from world_rules.json into typed Rule instances. Trigger
## dispatch, query evaluation, and effect application are separate modules;
## Rule itself is just a structural carrier + validator + (W4) Expression cache.
##
## Within-phase ordering is JSON definition order with optional before/after
## hints. Priorities are deliberately not supported — named phases + JSON order
## + hints cover every real case without becoming a maintenance ratchet.

const VALID_TRIGGERS: Array = [
	"tick", "contact", "signal", "input",
	"spawn", "despawn", "relation_changed", "scheduled",
]

# ============================================================
# FIELDS
# ============================================================

var id: String = ""
var trigger: Dictionary = {}
var query: Variant = null          # null or Dictionary
var require: Variant = null        # null or Dictionary
var chance: float = 1.0
var effects: Array = []            # always an Array of effect dicts (singleton normalized)
var before_hints: Array[String] = []
var after_hints: Array[String] = []
var scope: String = ""

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
	return r


## Load a list of Rule objects from a world_rules.json file.
static func load_from_file(path: String) -> Array[Rule]:
	var out: Array[Rule] = []
	if not FileAccess.file_exists(path):
		push_error("Rules file not found: " + path)
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		push_error("Invalid JSON: " + path)
		return out
	var list = data.get("rules", [])
	if not (list is Array):
		push_error("%s: 'rules' must be an array" % path)
		return out
	for entry in list:
		if entry is Dictionary:
			out.append(Rule.from_dict(entry))
	return out


# ============================================================
# VALIDATION
# ============================================================

## Validate a list of loaded rules. Returns [] if valid, otherwise error strings.
## Each error is phrased to identify the offending rule by id + field.
##
## Scope: structural checks only (id uniqueness, trigger type, chance range,
## effect list has type). Deeper checks live elsewhere:
##   - query syntax        → query.gd (W1.5)
##   - effect type validity → effect_apply.gd (W1.6)
##   - formula parseability → formula.gd (W4)
##   - ref integrity        → schema validator (W1.13)
static func validate_all(rules: Array) -> Array[String]:
	var errors: Array[String] = []
	var seen: Dictionary = {}
	for i in range(rules.size()):
		var r = rules[i]
		if not (r is Rule):
			errors.append("Entry %d is not a Rule instance" % i)
			continue
		var rule: Rule = r
		if rule.id == "":
			errors.append("Rule at index %d has no id" % i)
			continue
		if seen.has(rule.id):
			errors.append("Duplicate rule id: %s" % rule.id)
		seen[rule.id] = true

		var tt := rule.trigger_type()
		if tt == "":
			errors.append("Rule '%s': trigger.type missing" % rule.id)
		elif not (tt in VALID_TRIGGERS):
			errors.append("Rule '%s': invalid trigger type '%s' (valid: %s)" % [rule.id, tt, VALID_TRIGGERS])

		if rule.effects.is_empty():
			errors.append("Rule '%s': effect list is empty" % rule.id)
		for j in range(rule.effects.size()):
			var eff = rule.effects[j]
			if not (eff is Dictionary):
				errors.append("Rule '%s' effect[%d] is not a dictionary" % [rule.id, j])
			elif not eff.has("type") or str(eff["type"]) == "":
				errors.append("Rule '%s' effect[%d] missing 'type'" % [rule.id, j])

		if rule.chance < 0.0 or rule.chance > 1.0:
			errors.append("Rule '%s': chance %.2f out of [0.0, 1.0]" % [rule.id, rule.chance])
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
