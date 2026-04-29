extends RefCounted
class_name EffectApply

## Primitive #5 — Effect (application side).
##
## Contract: docs/30_framework_primitives.md §5
##
## `apply(effect, env, context)` mutates the world to fulfill one effect dict.
## The calling phase scheduler (W1.8) decides *when* to apply (commit vs react)
## and in what order. This module is purely about *how*.
##
## `env` carries mutable engine services:
##   env.entities    : Dictionary (instance_id → Entity)
##   env.relations   : RelationStore
##   env.defs        : Dictionary (def_id → entity definition)
##   env.parent      : Node  — parent node for spawned entity children (the
##                             scene's entity root). Node2D expected.
##   env.next_id     : Dictionary {"_": int} — spawn-id counter (shared ref)
##
## `context` carries per-rule bindings: `self`, `a`, `b`, input-payload keys.
##
## W1 scope:
##   state_set, state_add, state_mul, state_clamp,
##   spawn, remove, transform,
##   relate, unrelate, transfer_relation,
##   tag_add, tag_remove.
##
## Deferred:
##   velocity_set (W2 — motion tick lives alongside)
##   emit         (W2 — signal scheduler wires outbound queue)
##   formula-valued numeric fields (W4 — formula.gd wrapper)

# ============================================================
# PUBLIC
# ============================================================

## Apply a single effect. Returns a side-effect record for the scheduler to
## consume (e.g. emitted signals); empty dict if none.
static func apply(effect: Dictionary, env: Dictionary, context: Dictionary) -> Dictionary:
	var type: String = str(effect.get("type", ""))
	match type:
		"state_set":         _state_set(effect, env, context)
		"state_add":         _state_add(effect, env, context)
		"state_mul":         _state_mul(effect, env, context)
		"state_clamp":       _state_clamp(effect, env, context)
		"spawn":             return _spawn(effect, env, context)
		"remove":            _remove(effect, env, context)
		"transform":         return _transform(effect, env, context)
		"relate":            _relate(effect, env, context)
		"unrelate":          _unrelate(effect, env, context)
		"transfer_relation": _transfer_relation(effect, env, context)
		"tag_add":           _tag_add(effect, env, context)
		"tag_remove":        _tag_remove(effect, env, context)
		"velocity_set":      _velocity_set(effect, env, context)
		"emit":              push_warning("effect 'emit' routed via phase_scheduler, not effect_apply")
		_:                   push_warning("Unknown effect type: %s" % type)
	return {}


# ============================================================
# STATE EFFECTS
# ============================================================

static func _state_set(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = _target(e, env, ctx)
	if ent == null: return
	ent.set_state(str(e.get("field", "")), _value(e.get("value"), ctx))

static func _state_add(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = _target(e, env, ctx)
	if ent == null: return
	ent.add_state(str(e.get("field", "")), float(_value(e.get("amount"), ctx)))

static func _state_mul(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = _target(e, env, ctx)
	if ent == null: return
	var field := str(e.get("field", ""))
	var factor := float(_value(e.get("amount"), ctx))
	ent.set_state(field, float(ent.get_state(field, 0)) * factor)

static func _state_clamp(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = _target(e, env, ctx)
	if ent == null: return
	var field := str(e.get("field", ""))
	var lo := float(e.get("min", -INF))
	var hi := float(e.get("max", INF))
	ent.set_state(field, clamp(float(ent.get_state(field, 0)), lo, hi))


# ============================================================
# LIFECYCLE EFFECTS
# ============================================================

## Spawn a new entity from a def template. Returns {new_id: "..."} for the
## phase scheduler to dispatch `spawn` triggers against. Position can be:
##   - "self"/"a"/"b"/etc.  → copy context entity's position
##   - [x, y] or Vector2    → literal
##   - absent               → origin
static func _spawn(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var defs: Dictionary = env.get("defs", {})
	var template := str(e.get("template", ""))
	if not defs.has(template):
		push_error("spawn: no def '%s'" % template); return {}
	var def: Dictionary = defs[template]
	var overrides: Dictionary = (e.get("overrides", {}) as Dictionary).duplicate(true)
	if e.has("position"):
		overrides["position"] = _position(e["position"], env, ctx)
	# Determine instance id
	var inst_id := ""
	if overrides.has("_forced_id"):
		inst_id = str(overrides["_forced_id"])
		overrides.erase("_forced_id")
	else:
		var seq: Dictionary = env.get("next_id", {"_": 0})
		inst_id = "%s_%d" % [template, int(seq.get("_", 0))]
		seq["_"] = int(seq.get("_", 0)) + 1
	var ent := Entity.create(def, inst_id, overrides)
	(env.get("entities", {}) as Dictionary)[inst_id] = ent
	var parent = env.get("parent", null)
	if parent is Node:
		parent.add_child(ent)
	return {"spawned_id": inst_id}

static func _remove(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = _target(e, env, ctx)
	if ent == null: return
	var entities: Dictionary = env.get("entities", {})
	var store: RelationStore = env.get("relations", null)
	if store != null:
		store.clear_entity(ent.instance_id)
	entities.erase(ent.instance_id)
	ent.queue_free()

## Replace an entity in place with a new def, preserving position and merging
## state (new def's state_init takes precedence for any overlapping fields).
static func _transform(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var ent: Entity = _target(e, env, ctx)
	if ent == null: return {}
	var to_def := str(e.get("to", ""))
	var defs: Dictionary = env.get("defs", {})
	if not defs.has(to_def):
		push_error("transform: no def '%s'" % to_def); return {}
	var preserved_state: Dictionary = ent.state.duplicate(true)
	var pos := ent.position
	# Remove old
	_remove({"type": "remove", "target": e.get("target", "self")}, env, ctx)
	# Spawn new — pass preserved state as overrides so it mixes with new def's state_init
	return _spawn({
		"type": "spawn",
		"template": to_def,
		"position": pos,
		"overrides": {"state": preserved_state},
	}, env, ctx)


# ============================================================
# RELATION EFFECTS
# ============================================================

static func _relate(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var store: RelationStore = env.get("relations", null)
	if store == null: return
	var type := str(e.get("relation", ""))
	var from_id := _resolve_id(e.get("from", "self"), ctx)
	var to_id := _resolve_id(e.get("to", ""), ctx)
	if type == "" or from_id == "" or to_id == "": return
	store.relate(type, from_id, to_id)

static func _unrelate(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var store: RelationStore = env.get("relations", null)
	if store == null: return
	var type := str(e.get("relation", ""))
	var from_id := _resolve_id(e.get("from", "self"), ctx)
	var to_id := _resolve_id(e.get("to", ""), ctx)
	if type == "" or from_id == "" or to_id == "": return
	store.unrelate(type, from_id, to_id)

## Swap one endpoint of an edge.
##   {relation, from, to, new_to}   → move `from→to` to `from→new_to`
##   {relation, from, to, new_from} → move `from→to` to `new_from→to`
static func _transfer_relation(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var store: RelationStore = env.get("relations", null)
	if store == null: return
	var type := str(e.get("relation", ""))
	var from_id := _resolve_id(e.get("from", "self"), ctx)
	var to_id := _resolve_id(e.get("to", ""), ctx)
	if e.has("new_to"):
		store.transfer_to(type, from_id, to_id, _resolve_id(e["new_to"], ctx))
	elif e.has("new_from"):
		store.transfer_from(type, from_id, _resolve_id(e["new_from"], ctx), to_id)


# ============================================================
# TAG EFFECTS
# ============================================================

static func _tag_add(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = _target(e, env, ctx)
	if ent == null: return
	ent.add_tag(str(e.get("tag", "")))

static func _tag_remove(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = _target(e, env, ctx)
	if ent == null: return
	ent.remove_tag(str(e.get("tag", "")))


# ============================================================
# MOTION (W2 will also add the per-tick motion integrator alongside this)
# ============================================================

static func _velocity_set(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = _target(e, env, ctx)
	if ent == null: return
	var vx := float(_value(e.get("x", 0), ctx))
	var vy := float(_value(e.get("y", 0), ctx))
	ent.set_velocity(Vector2(vx, vy))


# ============================================================
# RESOLUTION HELPERS
# ============================================================

## Resolve the target entity for an effect.
## Per contract: context binding first (e.g. "self"), fall back to literal id.
static func _target(effect: Dictionary, env: Dictionary, ctx: Dictionary) -> Entity:
	var key := str(effect.get("target", "self"))
	var id := str(ctx.get(key, key))
	var all: Dictionary = env.get("entities", {})
	if not all.has(id): return null
	var ent = all[id]
	return ent if ent is Entity else null

## Resolve an id reference (for relation from/to fields).
## Same policy: context binding first, literal fallback.
static func _resolve_id(v, ctx: Dictionary) -> String:
	if v is String:
		var s := str(v)
		if ctx.has(s): return str(ctx[s])
		return s
	return ""

## Resolve a value (literal or context lookup). W4 extends this with formulas.
static func _value(v, ctx: Dictionary):
	if v is String:
		var s := str(v)
		if ctx.has(s): return ctx[s]
		return s
	return v

## Position shorthand: "self" → copy that entity's position; array → Vector2.
static func _position(v, env: Dictionary, ctx: Dictionary) -> Vector2:
	if v is Vector2: return v
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	if v is String and ctx.has(str(v)):
		var ref_id := str(ctx[str(v)])
		var all: Dictionary = env.get("entities", {})
		if all.has(ref_id) and all[ref_id] is Entity:
			return (all[ref_id] as Entity).position
	return Vector2.ZERO
