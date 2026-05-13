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
## Math helpers: Godot's Expression supports `sin`, `cos`, `tan`, `sqrt`,
## `pow`, `abs`, `floor`, `ceil`, `round`, `clamp`, `min`, `max`, `lerp`,
## `randf`, etc. as built-in functions — no extra registration needed.
##
## Deferred to Tier 3:
##   self.held_by.* — relation traversal (needs RelationStore lookup)
##   self.nearest({...}) — spatial helper
##
## Deferred to W6:
##   AST whitelist (W4.5) — security, documented as known gap

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

	var regex := RegEx.new()
	for root_v in roots:
		var root := str(root_v)
		# Match `root.path.segment` (one or more dotted parts after root)
		regex.compile("\\b" + root + "(\\.[A-Za-z_][A-Za-z0-9_]*)+")
		var matches = regex.search_all(rewritten)
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
		expr = Expression.new()
		var err := expr.parse(rewritten, input_names)
		if err != OK:
			_last_error = "parse error in '%s' → '%s': %s" % [s, rewritten, expr.get_error_text()]
			EngineError.raise(
				env,
				EngineError.FORMULA_PARSE_FAILED,
				"Formula parse error: '%s' → '%s' — %s" % [s, rewritten, expr.get_error_text()],
				{
					"rule_id": context.get("_rule_id", ""),
					"formula": s,
					"rewritten": rewritten,
					"godot_error": expr.get_error_text()
				},
				(
					"Check formula syntax. Allowed: bindings (self.state.X,"
					+ " target.X, world.tick), math (clamp/min/max/abs/sin/cos/sqrt/pow"
					+ "/floor/ceil/lerp/randf), arithmetic, comparison, bitwise,"
					+ " Vector2/Array subscript, Python-style ternary 'a if cond else b'"
					+ " (NOT C-style 'cond ? a : b' — Godot 4.6.1 Expression doesn't"
					+ " parse it)."
				)
			)
			return 0.0
		_cache[key] = expr

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


## Compile-only; for load-time validation (W4.6). Returns "" on success or
## an error string. Doesn't substitute paths since we don't have values yet —
## just checks GDScript expression syntax.
static func validate_syntax(
	formula: String, _expected_roots: PackedStringArray = PackedStringArray()
) -> String:
	if formula == "":
		return "empty formula"
	# We can't actually validate without knowing roots; just try parsing as-is.
	# Real validation happens at first evaluation; this is a smoke check.
	var probe: String = formula
	# Substitute each dotted path with a placeholder so parse can succeed
	var regex := RegEx.new()
	regex.compile("\\b[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+")
	var i: int = 0
	while regex.search(probe) != null:
		var m := regex.search(probe)
		probe = probe.substr(0, m.get_start()) + ("__p%d" % i) + probe.substr(m.get_end())
		i += 1
		if i > 100:
			break  # safety
	var expr := Expression.new()
	var err := expr.parse(probe)
	if err != OK:
		return "syntax error: %s" % expr.get_error_text()
	return ""


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
