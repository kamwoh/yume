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
		"velocity_lerp":     _velocity_lerp(effect, env, context)
		"velocity_set_relative": _velocity_set_relative(effect, env, context)
		"emit":              _emit(effect, env, context)
		"emit_shell_event":  _emit_shell_event(effect, env, context)
		_:
			EngineError.raise(env, EngineError.EFFECT_UNKNOWN_TYPE,
				"Unknown effect type: '%s'" % type,
				{"rule_id": context.get("_rule_id", ""), "field": "effect.type", "got": type},
				"Use one of: state_set, state_add, state_mul, state_clamp, spawn, remove, transform, relate, unrelate, transfer_relation, tag_add, tag_remove, velocity_set, velocity_lerp, emit, emit_shell_event.",
				"warning")
	return {}


# ============================================================
# STATE EFFECTS
# ============================================================

static func _state_set(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = _target(e, env, ctx)
	if ent == null: return
	ent.set_state(str(e.get("field", "")), _value(e.get("value"), ctx, env))

static func _state_add(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = _target(e, env, ctx)
	if ent == null: return
	ent.add_state(str(e.get("field", "")), float(_value(e.get("amount"), ctx, env)))

static func _state_mul(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = _target(e, env, ctx)
	if ent == null: return
	var field := str(e.get("field", ""))
	var factor := float(_value(e.get("amount"), ctx, env))
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
		EngineError.raise(env, EngineError.EFFECT_SPAWN_NO_DEF,
			"spawn: no def '%s'" % template,
			{"rule_id": ctx.get("_rule_id", ""), "field": "effect.template", "got": template, "known_defs": defs.keys()},
			"Add a definition with id '%s' to entities.json, or fix the spawn template name." % template)
		return {}
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
		# Attach renderer if World provides one. Required for transform/spawn
		# at runtime so the new entity is visible (initial spawns are rendered
		# directly by World._spawn_initial — same hook).
		if parent.has_method("_attach_renderer"):
			parent.call("_attach_renderer", ent)
	# Spatial index registration (W3.1)
	var sx = env.get("spatial_index", null)
	if sx != null and sx.has_method("update_entity"):
		sx.update_entity(inst_id, ent.get_planar_position())
	# Lifecycle: synchronously fire spawn-trigger rules. Their effects queue
	# to effect_buffer and apply on the next flush.
	var dispatch = env.get("dispatch_lifecycle", null)
	if dispatch is Callable:
		dispatch.call("spawn", inst_id)
	return {"spawned_id": inst_id}

static func _remove(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = _target(e, env, ctx)
	if ent == null: return
	var entities: Dictionary = env.get("entities", {})
	var store: RelationStore = env.get("relations", null)
	# Lifecycle: fire despawn-trigger rules SYNCHRONOUSLY while entity still
	# exists in env.entities. Their effects queue to effect_buffer; they apply
	# on the next flush after this remove returns.
	var dispatch = env.get("dispatch_lifecycle", null)
	if dispatch is Callable:
		dispatch.call("despawn", ent.instance_id)
	if store != null:
		store.clear_entity(ent.instance_id)
	# Spatial index removal
	var sx = env.get("spatial_index", null)
	if sx != null and sx.has_method("remove_entity"):
		sx.remove_entity(ent.instance_id)
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
		EngineError.raise(env, EngineError.EFFECT_TRANSFORM_NO_DEF,
			"transform: no def '%s'" % to_def,
			{"rule_id": ctx.get("_rule_id", ""), "field": "effect.to", "got": to_def, "known_defs": defs.keys()},
			"Add a definition with id '%s' to entities.json, or fix the transform target." % to_def)
		return {}
	var preserved_state: Dictionary = ent.state.duplicate(true)
	# Remove old
	_remove({"type": "remove", "target": e.get("target", "self")}, env, ctx)
	# Spawn new — pass preserved state as overrides so it mixes with new def's
	# state_init. Position lives inside preserved_state so it carries over.
	return _spawn({
		"type": "spawn",
		"template": to_def,
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
	var vx := float(_value(e.get("x", 0), ctx, env))
	var vy := float(_value(e.get("y", 0), ctx, env))
	# 2D-default velocity. 3D variant would set z too — extend when needed.
	ent.set_velocity(Vector2(vx, vy))


## Tier 2.6o Phase 3 — set velocity in actor's facing-relative frame.
## Used by first/third-person controls where W means "forward in look
## direction" rather than "+Y in world". `forward` and `strafe` are
## scalars (signed), result projected onto XZ plane (Y-up world).
##
## Convention: facing=0 → forward = (0, 0, -1) (look along -Z).
##             facing=π/2 → forward = (-1, 0, 0) (look along -X).
static func _velocity_set_relative(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = _target(e, env, ctx)
	if ent == null: return
	var fwd := float(_value(e.get("forward", 0), ctx, env))
	var strafe := float(_value(e.get("strafe", 0), ctx, env))
	var facing := float(ent.get_state("facing", 0.0))
	# Forward in world: rotate (0,0,-1) by yaw around Y → (-sin, 0, -cos)
	var fx := -sin(facing) * fwd
	var fz := -cos(facing) * fwd
	# Strafe right = forward rotated 90° clockwise → (-cos, 0, sin)
	var sx := -cos(facing) * strafe
	var sz := sin(facing) * strafe
	# Final velocity: combine and store. If the entity stores Vector2 position
	# (top-down 2D content), project onto XZ via Vector2(x_total, z_total).
	var pos = ent.get_position()
	var vx := fx + sx
	var vz := fz + sz
	if pos is Vector3:
		ent.set_velocity(Vector3(vx, 0, vz))
	else:
		ent.set_velocity(Vector2(vx, vz))


## Smoothly approach a target velocity each tick. Lets entities feel weighty —
## input rules use velocity_lerp instead of velocity_set so movement
## ramps in/out instead of snapping. `rate` is the per-tick lerp factor
## (0.0 = no change, 1.0 = snap to target). Typical: 0.10-0.25.
static func _velocity_lerp(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = _target(e, env, ctx)
	if ent == null: return
	var tx := float(_value(e.get("x", 0), ctx, env))
	var ty := float(_value(e.get("y", 0), ctx, env))
	var rate: float = clamp(float(_value(e.get("rate", 0.15), ctx, env)), 0.0, 1.0)
	var current = ent.get_velocity()
	var current_v: Vector2 = Vector2.ZERO
	if current is Vector2: current_v = current
	var lerped: Vector2 = current_v.lerp(Vector2(tx, ty), rate)
	ent.set_velocity(lerped)


# ============================================================
# SIGNAL EMIT (W2.1)
# ============================================================

## Push a signal onto env.signal_buffer for the scheduler to dispatch.
## Payload values are resolved like effect numeric fields:
##   - bare context name → context lookup (e.g. `"self"` → ctx["self"])
##   - formula string → Formula.evaluate (e.g. `"self.state.xp_value"`)
##   - literal → pass through
## Fire a generic event to the GameShell layer (camera shake, screen flash,
## hitstop, etc). Pushes onto env.shell_event_buffer; GameShell drains each
## frame. Ignored if no GameShell is attached. Decoupled from world.signal
## (which is sim-time + rule-driven) — shell events are presentation-only.
##
## Common events:
##   {event: "shake", intensity: 0.3, duration: 12}
##   {event: "flash", color: "#ff0000", duration: 8}
##   {event: "hitstop", duration: 4}
static func _emit_shell_event(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var event_name := str(e.get("event", ""))
	if event_name == "": return
	var record: Dictionary = {"event": event_name}
	for k in e.keys():
		if str(k) == "type" or str(k) == "event": continue
		record[str(k)] = _value(e[k], ctx, env)
	# Lazy-create the buffer. GameShell may not have wired one yet, OR no
	# GameShell is attached at all (purely sim-only scenes). Either way,
	# events accumulate; GameShell drains if it exists, else buffer just
	# grows (harmless for short runs).
	var buf_v = env.get("shell_event_buffer", null)
	var buf: Array
	if buf_v is Array:
		buf = buf_v
	else:
		buf = []
		env["shell_event_buffer"] = buf
	buf.append(record)


static func _emit(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var name := str(e.get("signal", ""))
	if name == "": return
	var raw_payload: Dictionary = (e.get("payload", {}) as Dictionary)
	var resolved_payload: Dictionary = {}
	for k in raw_payload.keys():
		resolved_payload[k] = _value(raw_payload[k], ctx, env)
	var buf: Array = env.get("signal_buffer", null)
	if buf == null:
		EngineError.raise(env, EngineError.EFFECT_EMIT_NO_BUFFER,
			"emit: env has no signal_buffer — scheduler may be uninitialized",
			{"rule_id": ctx.get("_rule_id", ""), "field": "effect.signal", "got": name},
			"This usually means an effect ran outside a phase scheduler. Wire env via PhaseScheduler.new(env).",
			"warning")
		return
	buf.append({"name": name, "payload": resolved_payload})


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

## Resolve a value: literal pass-through, context lookup for bare names, or
## formula evaluation for strings with operators / dotted paths.
##
## W4: formulas evaluated via Formula.evaluate. Context for formulas exposes
## entity refs as objects (so `self.state.hp` works) — built lazily here from
## the rule's bare-id context.
static func _value(v, ctx: Dictionary, env: Dictionary = {}):
	if v is float or v is int or v is bool: return v
	if v is Array or v is Vector2 or v is Vector3: return v
	if v is String:
		var s := str(v)
		# Bare context binding (e.g. "actor" → context["actor"])
		if ctx.has(s): return ctx[s]
		# Formula? Evaluate with entity-object context.
		if Formula.looks_like_formula(s):
			var fctx := _formula_context(ctx, env)
			# Carry rule attribution into formula context for 2.6a error reporting.
			if ctx.has("_rule_id"):
				fctx["_rule_id"] = ctx["_rule_id"]
			return Formula.evaluate(s, fctx, env)
		# Literal string
		return s
	return v


## Build a formula-friendly context from the rule's bare-id context.
##   ctx.self → context["self"] is an entity_id string. Formula context wants
##   Entity object so `self.state.hp` resolves. Look up entity from env.entities.
static func _formula_context(ctx: Dictionary, env: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var entities: Dictionary = env.get("entities", {})
	# Common entity bindings: id string → Entity object. `from`/`to` are
	# typically set by relation_changed dispatch (W2.4) and signal payloads
	# carrying entity refs.
	var entity_roles: Array[String] = ["self", "target", "a", "b", "source",
		"from", "to", "piece", "from_sq", "to_sq"]
	for role in entity_roles:
		if ctx.has(role):
			var id: String = str(ctx[role])
			if entities.has(id):
				out[role] = entities[id]
	# World state always available
	out["world"] = env.get("world", {})
	# Pre-resolved entity bindings (e.g. self_entity from scan-rule firing)
	var prebound: Array[String] = ["self_entity", "a_entity", "b_entity"]
	for role_ent in prebound:
		if ctx.has(role_ent):
			var key: String = role_ent.replace("_entity", "")
			out[key] = ctx[role_ent]
	# Pass through any other scalar context bindings (e.g. payload values)
	for k in ctx.keys():
		var ks: String = str(k)
		if out.has(ks): continue
		if ks.begins_with("_"): continue
		var v = ctx[k]
		# Don't shadow object bindings with their id strings
		if not (v is String) or not entities.has(str(v)):
			out[ks] = v
	return out

## Position shorthand. Returns Vector2 or Vector3 (preserves dimension).
##   "self"/"a"/"b" → copy that entity's state.position (whatever dimension)
##   Vector2/Vector3 literal → pass through
##   Array length 2 → Vector2; length 3 → Vector3
##   Each array element runs through _value() so formulas like
##   "self.state.position.x + (randf()-0.5)*60" resolve. Formula failures
##   fall back to 0 (per Formula.evaluate convention).
static func _position(v, env: Dictionary, ctx: Dictionary):
	if v is Vector2 or v is Vector3: return v
	if v is Array:
		var a := v as Array
		if a.size() == 2:
			return Vector2(float(_value(a[0], ctx, env)), float(_value(a[1], ctx, env)))
		if a.size() == 3:
			return Vector3(
				float(_value(a[0], ctx, env)),
				float(_value(a[1], ctx, env)),
				float(_value(a[2], ctx, env))
			)
	if v is String and ctx.has(str(v)):
		var ref_id := str(ctx[str(v)])
		var all: Dictionary = env.get("entities", {})
		if all.has(ref_id) and all[ref_id] is Entity:
			return (all[ref_id] as Entity).get_position()
	return Vector2.ZERO
