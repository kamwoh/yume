extends Object
class_name EffectResolution

## Shared resolution helpers for effect handlers.
##
## Every effect category (state / motion / shell / actor / lifecycle / etc.)
## resolves the same kinds of inputs:
##
##   - target entity         → resolve_target
##   - id reference          → resolve_id
##   - value (literal / formula / context binding / array / dict)
##                          → value
##   - position shorthand    → position
##   - text-only value       → value_text
##   - formula context build → formula_context  (used internally by `value`)
##
## Centralized here so the per-category effect modules don't duplicate
## these. All static — module is stateless.
##
## Naming convention: public surface is `EffectResolution.X` (no leading
## underscore). The underscore-prefixed names that used to live in
## effect_apply.gd kept their old form (_target, _value) only because
## they were private to that file; once extracted into a class with
## class_name, the leading underscore stops being meaningful and the
## public names read cleaner at call sites.


## Resolve the target entity for an effect.
## Per contract: context binding first (e.g. "self"), fall back to literal id.
## ADR 0047 promises "One store, two names": `state_set target=world` and
## `state_set target=_engine` write the same data, matching the read-side
## `world.X` HUD binding. Only `_engine` was ever implemented — `target=world`
## resolved to no entity and every such effect was a SILENT NO-OP, which is
## precisely the failure ADR 0047 was written to eliminate (its Context calls
## out "writing state_set target=world, field=gold succeeds silently").
##
## `.claude/rules/data-demo.md` documented `target=world` as working, so
## content authored against the docs did nothing at all.
##
## Empirical 2026-08-17: a career life-sim's entire progression — rank,
## objective text, debt — was written with target="world" and none of it
## landed. Boot was clean, all 31 validators passed, and 9 of 10 scenario
## assertions passed; only the one asserting a world field caught it.
const WORLD_STATE_ALIAS: String = "_engine"


## Resolve a string to an entity id — the ONE place that decides what an
## entity reference in JSON means. `target`, `resolve_id`, and therefore every
## effect that addresses an entity all route through here, so the three forms
## below are available uniformly instead of per-effect.
##
##   "actor" / "row" / "self"     context binding  → the bound id
##   "self.properties.poster"     dotted path      → follow it, use the result
##   "npc_sera_vance"             anything else    → literal id
##
## ADR 0081. The dotted form is INDIRECTION: address the entity a field names
## rather than one the rule hardcodes. Without it, "reward the NPC who posted
## this contract" is inexpressible — a rule can only name a poster literally,
## so N posters means N copies of the same rule, and adding the N+1th silently
## does nothing until someone notices the missing copy.
##
## WHY A DOT IS THE DISAMBIGUATOR: entity ids never contain one, so no existing
## literal can be reinterpreted by this change. That precision is the whole
## point. Routing every id string through Formula.evaluate instead would reopen
## the caabe39 bug class — `looks_like_formula` accepts any lowercase-leading
## string, so plain ids like `npc_sera_vance` would parse as expressions. The
## path is evaluated ONLY when it contains a dot AND its head is a live context
## binding; a dotted string rooted at nothing stays a literal.
static func entity_id(v, ctx: Dictionary, env: Dictionary = {}) -> String:
	if not (v is String):
		return ""
	var s := str(v)
	if ctx.has(s):
		return str(ctx[s])
	var dot := s.find(".")
	if dot > 0 and ctx.has(s.substr(0, dot)):
		var resolved = value(s, ctx, env)
		if resolved == null:
			return ""
		return str(resolved)
	return s


static func target(effect: Dictionary, env: Dictionary, ctx: Dictionary) -> Entity:
	var id := entity_id(effect.get("target", "self"), ctx, env)
	var all: Dictionary = env.get("entities", {})
	if id == "world" and not all.has(id):
		id = WORLD_STATE_ALIAS
	if not all.has(id):
		return null
	var ent = all[id]
	return ent if ent is Entity else null


## Resolve an id reference (for relation from/to fields).
## Thin alias for `entity_id` — kept because 19 call sites read better as
## "resolve_id" and because `env` is optional there.
static func resolve_id(v, ctx: Dictionary, env: Dictionary = {}) -> String:
	return entity_id(v, ctx, env)


## Resolve a value: literal pass-through, context lookup for bare names,
## or formula evaluation for strings with operators / dotted paths.
##
## Recurses into Array + Dictionary so formula strings inside containers
## evaluate per-element. Vector2/Vector3 pass through (concrete numeric
## types, not formula containers). The `@cues.X` / `@strings.X` indirection
## refs pass through unevaluated so consumers (HUD / GameShell) can resolve
## at consumption time.
static func value(v, ctx: Dictionary, env: Dictionary = {}):
	if v is float or v is int or v is bool:
		return v
	if v is Vector2 or v is Vector3:
		return v
	if v is Array:
		var out: Array = []
		for item in v as Array:
			out.append(value(item, ctx, env))
		return out
	if v is Dictionary:
		var out_d: Dictionary = {}
		for k in (v as Dictionary).keys():
			out_d[k] = value((v as Dictionary)[k], ctx, env)
		return out_d
	if v is String:
		var s := str(v)
		# Bare context binding (e.g. "actor" → context["actor"])
		if ctx.has(s):
			return ctx[s]
		# ADR 0009 indirection refs (@cues.X, @strings.X) — pass through
		# unevaluated so GameShell / HUD can resolve at consumption time.
		# Without this, the dot in @cues.foo makes Formula.looks_like_formula
		# return true and parse fails on the @ character.
		if s.begins_with("@"):
			return s
		# Formula? Evaluate with entity-object context.
		if Formula.looks_like_formula(s):
			var fctx := formula_context(ctx, env)
			# Carry rule attribution into formula context for 2.6a error reporting.
			if ctx.has("_rule_id"):
				fctx["_rule_id"] = ctx["_rule_id"]
			return Formula.evaluate(s, fctx, env)
		# Literal string
		return s
	return v


## Text-only resolution: literal pass-through OR context binding lookup.
## No formula evaluation. Used by show_toast and similar text-field
## handlers where a formula would be wrong (and the data-demo.md rule
## about state_set value text-vs-formula gating points here).
static func value_text(v, ctx: Dictionary) -> String:
	if not (v is String):
		return str(v)
	var s := str(v)
	if ctx.has(s):
		return str(ctx[s])
	return s


## Build a formula-friendly context from the rule's bare-id context.
##   ctx.self → context["self"] is an entity_id string. Formula context wants
##   Entity object so `self.state.hp` resolves. Look up entity from env.entities.
static func formula_context(ctx: Dictionary, env: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var entities: Dictionary = env.get("entities", {})
	# Common entity bindings: id string → Entity object. `from`/`to` are
	# typically set by relation_changed dispatch (W2.4) and signal payloads
	# carrying entity refs.
	var entity_roles: Array[String] = [
		"self", "target", "a", "b", "source", "from", "to", "piece", "from_sq", "to_sq"
	]
	for role in entity_roles:
		if ctx.has(role):
			var id: String = str(ctx[role])
			if entities.has(id):
				out[role] = entities[id]
	# World state always available
	out["world"] = env.get("world", {})
	# ADR 0031: zone state available as `zone.<id>.<field>`. The
	# snapshot is a flat {zone_id: state_dict} — Formula._resolve_path
	# walks the dotted path: root=zone → state_dict → field value.
	var zs = env.get("zone_store", null)
	if zs != null and zs.has_method("binding_snapshot"):
		out["zone"] = zs.binding_snapshot()
	else:
		out["zone"] = {}
	# ADR 0032: faction state available as `faction.<id>.<field>`. Each
	# entry contains member_count + leader + tension_with.<other> +
	# stance_with.<other> + controls_zone (and the def's metadata).
	# FactionDirector is a Node sibling under World — locate via env.parent.
	var fd_parent = env.get("parent", null)
	if fd_parent is Node:
		var fd_node = (fd_parent as Node).get_node_or_null("FactionDirector")
		if fd_node != null and fd_node.has_method("binding_snapshot"):
			out["faction"] = fd_node.call("binding_snapshot", env)
		else:
			out["faction"] = {}
	else:
		out["faction"] = {}
	# Pre-resolved entity bindings (e.g. self_entity from scan-rule firing)
	var prebound: Array[String] = ["self_entity", "a_entity", "b_entity"]
	for role_ent in prebound:
		if ctx.has(role_ent):
			var key: String = role_ent.replace("_entity", "")
			out[key] = ctx[role_ent]
	# Pass through any other context bindings. For signal-payload entity
	# refs like `actor` (not in the entity_roles allowlist), look up the
	# entity from its id string so formulas can drill into `.state.X`. For
	# everything else, pass the scalar through verbatim.
	#
	# Empirical case 2026-05-16: gather_pickup signal rule with require:
	# {actor, target} crashed on formula `actor.state._last_slot` because
	# `actor` wasn't in entity_roles → string `"player_marken"` reached the
	# formula evaluator, which couldn't drill into state on a String. The
	# fix removes the allowlist as a correctness gate: any string ctx
	# value that names a real entity is auto-promoted to its Entity.
	for k in ctx.keys():
		var ks: String = str(k)
		if out.has(ks):
			continue
		if ks.begins_with("_"):
			continue
		var v = ctx[k]
		if v is String and entities.has(str(v)):
			out[ks] = entities[str(v)]
		else:
			out[ks] = v
	return out


## Position shorthand. Returns Vector2 or Vector3 (preserves dimension).
##   "self"/"a"/"b" → copy that entity's state.position (whatever dimension)
##   Vector2/Vector3 literal → pass through
##   Array length 2 → Vector2; length 3 → Vector3
##   Each array element runs through value() so formulas like
##   "self.state.position.x + (randf()-0.5)*60" resolve. Formula failures
##   fall back to 0 (per Formula.evaluate convention).
static func position(v, env: Dictionary, ctx: Dictionary):
	if v is Vector2 or v is Vector3:
		return v
	if v is Array:
		var a := v as Array
		if a.size() == 2:
			return Vector2(float(value(a[0], ctx, env)), float(value(a[1], ctx, env)))
		if a.size() == 3:
			return Vector3(
				float(value(a[0], ctx, env)),
				float(value(a[1], ctx, env)),
				float(value(a[2], ctx, env))
			)
	if v is String and ctx.has(str(v)):
		var ref_id := str(ctx[str(v)])
		var all: Dictionary = env.get("entities", {})
		if all.has(ref_id) and all[ref_id] is Entity:
			return (all[ref_id] as Entity).get_position()
	return Vector2.ZERO
