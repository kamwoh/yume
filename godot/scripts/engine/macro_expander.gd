extends RefCounted
class_name MacroExpander

## ADR 0019 — Rule plugin / macro layer.
##
## Per-game `macros.json` declares NEW effect names that EXPAND at load
## time to sequences of existing primitive effects + parameter substitution.
## Macros are pure CONTENT composition: the engine still ships a fixed
## primitive set; macros are template metaprogramming for JSON.
##
## Per ADR 0019 + TD review:
## - Load-time expansion only (NOT runtime functions). $param substitutes
##   to literal arg values; runtime context bindings (self, target, a, b)
##   are unchanged.
## - Per-game scoped: each game's macros.json is independent. No
##   cross-game macro leak.
## - Depth ≤ 4, total expanded effects per rule ≤ 50.
## - Cycle detection at load (DFS coloring).
## - Forbidden names: damage, need_decay, need_restore, gain_xp,
##   advance_stage, heal, attack — preserve Invariant #2 even at the
##   macro layer.
##
## Substitution rules at load time:
## - `$param` (bare string) → literal substitute of the macro arg
## - `$param.field.field` → `<arg_value>.field.field` (Formula resolves
##   at fire time via existing context-binding + property traversal)
## - "$param" inside larger string ("-$amount", "$x * 2") → string replace,
##   Formula evaluates at fire time


# ============================================================
# CONSTANTS
# ============================================================

const MAX_RECURSION_DEPTH := 4
const MAX_EXPANDED_EFFECTS := 50
const FORBIDDEN_MACRO_NAMES := [
	"damage", "need_decay", "need_restore", "gain_xp",
	"advance_stage", "heal", "attack",
]


# ============================================================
# STATE
# ============================================================

var _registry: Dictionary = {}     # name → {params: [...], expands_to: [...]}
var _is_valid: bool = false        # false if cycles / forbidden names / etc.


# ============================================================
# LOADING
# ============================================================

## Load macros from <data_root>/macros.json (preferred) OR
## <data_root>/game/macros.json (per ADR 0009 game-tier convention).
## Returns a MacroExpander instance — empty registry if no file or
## validation fails.
##
## env (optional): for structured error reporting.
static func load_from_data_root(data_root: String, env: Dictionary = {}) -> MacroExpander:
	var me := MacroExpander.new()
	var root := data_root.rstrip("/")
	var path := root + "/macros.json"
	if not FileAccess.file_exists(path):
		path = root + "/game/macros.json"
		if not FileAccess.file_exists(path):
			# No macros file → empty registry → expand_rule_effects is a no-op.
			me._is_valid = true
			return me
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return me
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		push_warning("MacroExpander: invalid JSON in %s" % path)
		return me
	var raw_macros = (data as Dictionary).get("macros", [])
	if not (raw_macros is Array):
		push_warning("MacroExpander: 'macros' must be an array in %s" % path)
		return me
	# Build registry — first pass: collect all by name.
	for m in raw_macros:
		if not (m is Dictionary): continue
		var name := str((m as Dictionary).get("name", ""))
		if name == "":
			push_warning("MacroExpander: macro missing 'name'")
			continue
		# Forbidden-name guard
		if name in FORBIDDEN_MACRO_NAMES:
			EngineError.raise(env, EngineError.EFFECT_UNKNOWN_TYPE,
				"Macro name '%s' is forbidden (Invariant #2: no semantic effect types)" % name,
				{"file": path, "macro": name},
				"Rename the macro to something mechanical (e.g. 'apply_damage' → 'subtract_hp_with_signal').")
			continue
		me._registry[name] = {
			"params": (m as Dictionary).get("params", []),
			"expands_to": (m as Dictionary).get("expands_to", []),
		}
	# Validate: cycle detection + leaf-primitive check
	if me._has_cycles():
		push_warning("MacroExpander: cycle detected; macros disabled for this game")
		me._registry.clear()
		return me
	me._is_valid = true
	return me


# ============================================================
# CYCLE DETECTION (DFS coloring)
# ============================================================

func _has_cycles() -> bool:
	# Standard DFS coloring: WHITE=unvisited, GRAY=in current dfs stack,
	# BLACK=finished. Edge to GRAY = cycle.
	var color: Dictionary = {}
	for name in _registry.keys():
		color[name] = "WHITE"
	for name in _registry.keys():
		if color[name] == "WHITE":
			if _dfs_visit(name, color):
				return true
	return false


func _dfs_visit(name: String, color: Dictionary) -> bool:
	color[name] = "GRAY"
	var spec: Dictionary = _registry[name]
	for eff in spec.get("expands_to", []):
		if not (eff is Dictionary): continue
		var t := str((eff as Dictionary).get("type", ""))
		if _registry.has(t):
			match str(color.get(t, "WHITE")):
				"GRAY":
					push_warning("MacroExpander: cycle '%s → %s'" % [name, t])
					return true
				"WHITE":
					if _dfs_visit(t, color):
						return true
	color[name] = "BLACK"
	return false


# ============================================================
# RULE EFFECT EXPANSION (PUBLIC ENTRY POINT)
# ============================================================

## Walk `rules_array` (raw JSON dicts BEFORE Rule.from_dict). For each
## rule's `effect` field, expand any macro reference into the underlying
## primitive sequence. Returns a NEW array; doesn't mutate input.
func expand_rules(rules_array: Array, env: Dictionary = {}) -> Array:
	if _registry.is_empty(): return rules_array
	var out: Array = []
	for r in rules_array:
		if not (r is Dictionary):
			out.append(r)
			continue
		var rule_dict: Dictionary = (r as Dictionary).duplicate(true)
		var raw_effect = rule_dict.get("effect", null)
		if raw_effect != null:
			var effect_list: Array = []
			if raw_effect is Array:
				effect_list = (raw_effect as Array)
			else:
				effect_list = [raw_effect]
			var expanded: Array = []
			for eff in effect_list:
				if eff is Dictionary:
					var sub := _expand_one(eff as Dictionary, 0, env, str(rule_dict.get("id", "")))
					for e in sub:
						expanded.append(e)
				else:
					expanded.append(eff)
			# Enforce per-rule expanded-effect count limit
			if expanded.size() > MAX_EXPANDED_EFFECTS:
				push_warning("Macro expansion: rule '%s' expanded to %d effects (limit %d) — keeping first %d" % [
					str(rule_dict.get("id", "")), expanded.size(),
					MAX_EXPANDED_EFFECTS, MAX_EXPANDED_EFFECTS])
				expanded = expanded.slice(0, MAX_EXPANDED_EFFECTS)
			rule_dict["effect"] = expanded
		out.append(rule_dict)
	return out


## Expand one effect dict. If type is a macro, expand recursively.
## Returns an Array of primitive effects (1+ entries; just [eff] if not a macro).
func _expand_one(eff: Dictionary, depth: int, env: Dictionary, rule_id: String) -> Array:
	if depth > MAX_RECURSION_DEPTH:
		push_warning("Macro expansion: depth limit (%d) exceeded in rule '%s'" % [
			MAX_RECURSION_DEPTH, rule_id])
		return []
	var t := str(eff.get("type", ""))
	if not _registry.has(t):
		# Not a macro — pass through unchanged.
		return [eff]
	var spec: Dictionary = _registry[t]
	var params: Array = spec.get("params", [])
	var template: Array = spec.get("expands_to", [])
	# Build args dict from the call site's effect dict
	var args: Dictionary = {}
	for p in params:
		var key := str(p)
		if eff.has(key):
			args[key] = eff[key]
	# Substitute + recurse
	var out: Array = []
	for sub_template in template:
		if not (sub_template is Dictionary): continue
		var substituted := _substitute(sub_template as Dictionary, args)
		# Recurse: substituted may itself be a macro reference
		var deeper := _expand_one(substituted, depth + 1, env, rule_id)
		for d in deeper:
			out.append(d)
	return out


# ============================================================
# PARAMETER SUBSTITUTION
# ============================================================

## Walk the template dict; for every string value, perform $param
## substitution with args. Returns a new dict.
func _substitute(template: Dictionary, args: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in template.keys():
		out[str(k)] = _substitute_value(template[k], args)
	return out


## Recursive substitution for any value type.
func _substitute_value(v, args: Dictionary):
	if v is String:
		return _substitute_string(v as String, args)
	if v is Array:
		var arr_out: Array = []
		for item in (v as Array):
			arr_out.append(_substitute_value(item, args))
		return arr_out
	if v is Dictionary:
		return _substitute(v as Dictionary, args)
	return v


## Substitute $param tokens in a string. Handles:
##   "$amount"            → literal arg value (typed if numeric/bool)
##   "-$amount"           → string with arg substituted ("-10")
##   "$target.field.x"    → string with arg substituted ("b.field.x")
##   "no params here"     → unchanged
##
## Bare $param substitution returns the typed value (int/float/bool/etc.)
## so numeric args land as numbers, not strings. Compound tokens
## ("-$amount", "$x * 2", "$target.foo") return strings — Formula
## resolves them at fire time.
func _substitute_string(s: String, args: Dictionary):
	# Bare $param case: entire string is "$arg" → return typed value
	if s.length() > 1 and s.begins_with("$"):
		var bare := s.substr(1)
		# Allow only for clean identifier (no dots / arithmetic)
		if _is_identifier(bare) and args.has(bare):
			return args[bare]
	# Compound: scan for $name tokens, replace with str(arg). Formula
	# evaluates the full expression at fire time.
	if s.find("$") < 0: return s
	var result := s
	# Replace longest names first to avoid prefix collisions ($a vs $amount)
	var keys := args.keys()
	keys.sort_custom(func(a, b): return str(a).length() > str(b).length())
	for k in keys:
		var token := "$" + str(k)
		var replacement := str(args[k])
		result = result.replace(token, replacement)
	return result


static func _is_identifier(s: String) -> bool:
	if s == "": return false
	for ch in s:
		var c := ch as String
		var is_alnum := (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") \
			or (c >= "0" and c <= "9") or c == "_"
		if not is_alnum: return false
	return true


# ============================================================
# DIAGNOSTICS
# ============================================================

func registered_names() -> Array:
	return _registry.keys()


func is_valid() -> bool:
	return _is_valid
