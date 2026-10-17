extends RefCounted
class_name Formula

## Formula evaluation layer (W4.1).
##
## Wraps Godot's `Expression`. Numeric fields in JSON rule effects/queries
## can be string formulas like `"self.state.hp * 0.5"` instead of literals.
##
## Approach: path substitution.
##   1. Find all dotted paths in the formula referencing context root names
##      (self, target, a, b, world, ...).
##   2. Resolve each path to a value (e.g. `self.state.hp` → entity.state["hp"]).
##   3. Replace path with placeholder `__v0`, `__v1`, ...
##   4. Parse rewritten formula with Expression, passing values as inputs.
##
## Compiled `Expression` instances are cached statically by rewritten-formula
## key (W4.4) so re-evaluation is just `expr.execute(values)`.
##
## Bindings supported in W4 minimum:
##   self.{state,properties,tags,id,def_id}.<field>  — current entity
##   target.* / a.* / b.* / source.* — same shape, different role
##   world.<field> — global state (e.g. world.tick)
##
## The formula language is ADR 0088. Every number is a float, and a call
## must name one of FUNCTIONS. `_check_language` reads the formula token by
## token before Expression sees it, because Expression accepts all of
## GDScript (global functions, constructors, method calls, integer rules).
##
## Deferred to Tier 3:
##   self.held_by.* — relation traversal (needs RelationStore lookup)
##   self.nearest({...}) — spatial helper

## The function list of the formula language (ADR 0088). A new function
## needs an ADR. gen_api_manifest.py and validate_rules.py read this list.
const FUNCTIONS: Array = [
	"abs", "floor", "ceil", "round", "min", "max", "clamp", "lerp",
	"sqrt", "pow", "sin", "cos", "tan", "atan2", "randf", "float",
]
const _KEYWORDS: Array = ["and", "or", "not", "true", "false"]

static var _cache: Dictionary = {}  # cache key → Expression
static var _last_error: String = ""  # for diagnostics

# ============================================================
# PUBLIC
# ============================================================


## Evaluate `formula` against `context`. Returns the result value, or 0.0
## on parse / exec failure. `context` is a flat dict of root names → roots
## (Entity / Dictionary / scalar). Path resolution walks each root.
##
## Pass-through for non-string values: literal numbers / vectors / arrays
## return unchanged. Lets callers use this as a universal "resolve numeric
## field" helper without checking type first.
##
## 2.6a: pass `env` to capture parse / exec failures as structured records
## in `env.error_buffer`. Without env, errors only hit the dev console.
## One compiled RegEx per root name: `root.path.segment` (one or more dotted
## parts after the root). Compiling it on every call cost more than the
## match itself (batch C profile 2026-10-15).
static var _root_regex_cache: Dictionary = {}


static func _root_regex(root: String) -> RegEx:
	var rx: RegEx = _root_regex_cache.get(root)
	if rx == null:
		rx = RegEx.new()
		rx.compile("\\b" + root + "(\\.[A-Za-z_][A-Za-z0-9_]*)+")
		_root_regex_cache[root] = rx
	return rx


## One token of the formula language: space, number, name, or operator.
static var _token_regex: RegEx = null


## Check `src` (bindings already replaced by inputs) against the formula
## language (ADR 0088). Returns [formula, code, message, hint]. On success,
## code is "" and formula has each integer literal as a float literal.
## Godot 4.6.1's Expression has no ternary. It parses the first expression
## and drops the trailing tokens with no error, so `a if cond else b` always
## returned `a`. Empirical 2026-10-16: an aldenmere cloud_wrap formula moved
## every cloud.
static func _check_language(src: String, inputs: PackedStringArray) -> Array:
	if _token_regex == null:
		_token_regex = RegEx.create_from_string(
			"\\s+|(\\d+\\.\\d*|\\.\\d+|\\d+)([eE][+-]?\\d+)?|[A-Za-z_]\\w*|\\*\\*|==|!=|<=|>=|[-+*/()\\[\\],<>]"
		)
	var tokens: Array[RegExMatch] = []
	var pos := 0
	while pos < src.length():
		var m := _token_regex.search(src, pos)
		if m == null or m.get_start() != pos:
			return [
				"", EngineError.FORMULA_PARSE_FAILED,
				"'%s' is not in the formula language." % src[pos],
				"Formulas allow numbers, bindings, + - * /, comparisons, and, or, not, ( ) and [index]."
			]
		if not m.get_string().strip_edges().is_empty():
			tokens.append(m)
		pos = m.get_end()
	var out := ""
	for i in tokens.size():
		var tok := tokens[i].get_string()
		var next := tokens[i + 1].get_string() if i + 1 < tokens.size() else ""
		var prev := tokens[i - 1].get_string() if i > 0 else ""
		var first := tok.unicode_at(0)
		if tok == "**":
			return [
				"", EngineError.FORMULA_PARSE_FAILED,
				"'**' is not in the formula language.",
				"Write pow(x, y)."
			]
		if first == 95 or (first >= 65 and first <= 90) or (first >= 97 and first <= 122):
			if tok == "if" or tok == "else":
				return [
					"", EngineError.FORMULA_PARSE_FAILED,
					"The formula uses 'a if cond else b'. The formula language has no ternary.",
					"Write the choice as arithmetic: b + (a - b) * float(cond)."
				]
			if next == "(" and tok in inputs:
				return [
					"", EngineError.FORMULA_PARSE_FAILED,
					"A method call is not in the formula language.",
					"Call a formula function on the binding, for example abs(self.state.x)."
				]
			if next == "(" and not tok in _KEYWORDS:
				if not tok in FUNCTIONS:
					return [
						"", EngineError.FORMULA_UNKNOWN_FUNCTION,
						"'%s' is not a formula function." % tok,
						"The functions are: %s." % ", ".join(FUNCTIONS)
					]
			elif not (tok in inputs or tok in _KEYWORDS):
				return [
					"", EngineError.FORMULA_PARSE_FAILED,
					"'%s' is not a binding the rule provides." % tok,
					"A binding starts with a root the trigger provides, for example self.state.hp."
				]
		elif tok == "[" and not (prev == "]" or prev == ")" or prev in inputs):
			return [
				"", EngineError.FORMULA_PARSE_FAILED,
				"An array literal is not in the formula language.",
				"Use '[' only to index a binding, for example self.state.position[0]."
			]
		elif tokens[i].get_string(1) != "" and tokens[i].get_string(2) == "" and not "." in tok:
			tok += ".0"
		out += tok + " "
	return [out, "", "", ""]


static func evaluate(formula, context: Dictionary, env: Dictionary = {}):
	# Pass-through for non-string
	if not (formula is String):
		return formula
	var s := str(formula)
	if s == "":
		return 0.0

	# Build rewritten formula by substituting dotted paths
	var rewritten: String = s
	var input_names: PackedStringArray = PackedStringArray()
	var input_values: Array = []
	var roots := context.keys()
	# Sort longest-first so "self_entity" matches before "self"
	roots.sort_custom(func(a, b): return str(a).length() > str(b).length())

	for root_v in roots:
		var root := str(root_v)
		# Most roots do not appear in a given formula. Skip them before any
		# regex work (batch C profile 2026-10-15).
		if not rewritten.contains(root):
			continue
		var matches = _root_regex(root).search_all(rewritten)
		# Process from rightmost to leftmost so offset shifts don't break indices
		for i in range(matches.size() - 1, -1, -1):
			var m = matches[i]
			var full: String = m.get_string()
			var path: String = full.substr(root.length() + 1)
			var val = _resolve_path(context[root_v], path)
			var ph := "__v%d" % input_names.size()
			input_names.append(ph)
			input_values.append(val)
			rewritten = rewritten.substr(0, m.get_start()) + ph + rewritten.substr(m.get_end())

	# Cache key includes rewritten formula AND input order
	var key: String = rewritten + "|" + ",".join(input_names)
	var expr: Expression
	if _cache.has(key):
		expr = _cache[key]
	else:
		var checked := _check_language(rewritten, input_names)
		if checked[1] != "":
			_last_error = "%s in '%s'" % [checked[1], s]
			EngineError.raise(
				env,
				checked[1],
				"Formula '%s': %s" % [s, checked[2]],
				{"rule_id": context.get("_rule_id", ""), "formula": s},
				checked[3]
			)
			return 0.0
		expr = Expression.new()
		var err := expr.parse(checked[0], input_names)
		if err != OK:
			_last_error = "parse error in '%s' → '%s': %s" % [s, checked[0], expr.get_error_text()]
			EngineError.raise(
				env,
				EngineError.FORMULA_PARSE_FAILED,
				"Formula parse error: '%s' → '%s' — %s" % [s, checked[0], expr.get_error_text()],
				{
					"rule_id": context.get("_rule_id", ""),
					"formula": s,
					"rewritten": checked[0],
					"godot_error": expr.get_error_text()
				},
				"Check the formula syntax against the formula language (ADR 0088)."
			)
			return 0.0
		_cache[key] = expr

	# Every number is a float (ADR 0088). Engine integers such as world.tick
	# would otherwise make `/` an integer division.
	for i in input_values.size():
		if input_values[i] is int:
			input_values[i] = float(input_values[i])
	var result = expr.execute(input_values)
	if expr.has_execute_failed():
		_last_error = "exec failed for '%s'" % s
		(
			EngineError
			. raise(
				env,
				EngineError.FORMULA_EXEC_FAILED,
				"Formula exec failed: '%s' (rule=%s)" % [s, context.get("_rule_id", "?")],
				{
					"rule_id": context.get("_rule_id", ""),
					"formula": s,
					"rewritten": rewritten,
					"input_values": input_values
				},
				"A binding may have resolved to an unexpected type — check that all referenced fields exist on the bound entities."
			)
		)
		return 0.0
	return result


## Returns true if a string looks like a formula (has math operators or
## dotted paths). Cheap heuristic to avoid evaluating plain context refs
## like "self" or "actor" as formulas.
##
## Two-layer check: (1) FIRST char must be a formula-starting char
## (lowercase ident, digit, `(`, `-`, `+`, `_`, `@`); rejects English
## text like "Find your shop." which starts with a capital.
## (2) THEN must contain at least one operator/access char.
##
## Empirical: 2026-05-08 objective text "Find your shop in Pendrel..."
## tripped the old `find any of [space + - * / ( ) .]` heuristic
## because it has all of those — got passed to Expression.parse which
## crashed. Fix: require a formula-START char too.
static func looks_like_formula(s: String) -> bool:
	if s == "":
		return false
	var first := s.unicode_at(0)
	# Formulas start with: lowercase a-z (binding), digit (literal),
	# `(` (grouped expr), `-`/`+` (signed), `_` (private binding), `@`
	# (indirection ref). Anything else (capital letters, punctuation,
	# etc.) is not a formula.
	var lower_a := "a".unicode_at(0)
	var lower_z := "z".unicode_at(0)
	var digit_0 := "0".unicode_at(0)
	var digit_9 := "9".unicode_at(0)
	var first_is_formula_start := (
		(first >= lower_a and first <= lower_z)
		or (first >= digit_0 and first <= digit_9)
		or first == "(".unicode_at(0)
		or first == "-".unicode_at(0)
		or first == "+".unicode_at(0)
		or first == "_".unicode_at(0)
		or first == "@".unicode_at(0)
	)
	if not first_is_formula_start:
		return false
	# Then must have at least one operator/access char (else it's a
	# bare binding name, handled separately by ctx-lookup before
	# this function is called).
	for ch in [" ", "+", "-", "*", "/", "(", ")", "."]:
		if s.find(ch) >= 0:
			return true
	return false


# ============================================================
# INTERNAL — path resolution
# ============================================================


## Walk a dotted path against a root value. Returns 0 on missing field
## (matches QueryLib's strict-missing semantic).
static func _resolve_path(root, path: String):
	var parts := path.split(".")
	var cur = root
	for p in parts:
		if p == "":
			continue
		if cur is Entity:
			var ent: Entity = cur
			match p:
				"state":
					cur = ent.state
				"tags":
					cur = ent.tags
				"properties":
					cur = ent.properties
				"id":
					cur = ent.instance_id
				"def_id":
					cur = ent.def_id
				_:
					return 0  # unknown Entity member
			continue
		if cur is Dictionary:
			if cur.has(p):
				cur = cur[p]
			else:
				return 0
			continue
		# Vector2/Vector3 component access — needed for formulas like
		# `a.state.position.x` in contact-pair AI rules.
		if cur is Vector2:
			match p:
				"x":
					cur = (cur as Vector2).x
				"y":
					cur = (cur as Vector2).y
				_:
					return 0
			continue
		if cur is Vector3:
			match p:
				"x":
					cur = (cur as Vector3).x
				"y":
					cur = (cur as Vector3).y
				"z":
					cur = (cur as Vector3).z
				_:
					return 0
			continue
		# Cannot drill further into a scalar
		return 0
	return cur


# ============================================================
# CACHE STATS (diagnostics — W4.8 perf pass uses this)
# ============================================================


static func cache_size() -> int:
	return _cache.size()


static func clear_cache() -> void:
	_cache.clear()


static func get_last_error() -> String:
	return _last_error
