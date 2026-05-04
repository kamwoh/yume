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
		"velocity_add_relative": _velocity_add_relative(effect, env, context)
		"raycast_hit":       _raycast_hit(effect, env, context)
		"transition_level":  _transition_level(effect, env, context)
		"emit":              _emit(effect, env, context)
		"emit_shell_event":  _emit_shell_event(effect, env, context)
		_:
			EngineError.raise(env, EngineError.EFFECT_UNKNOWN_TYPE,
				"Unknown effect type: '%s'" % type,
				{"rule_id": context.get("_rule_id", ""), "field": "effect.type", "got": type},
				"Use one of: state_set, state_add, state_mul, state_clamp, spawn, remove, transform, relate, unrelate, transfer_relation, tag_add, tag_remove, velocity_set, velocity_lerp, velocity_set_relative, velocity_add_relative, raycast_hit, transition_level, emit, emit_shell_event.",
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
	# Resolve formula strings in state-override Arrays (position/velocity).
	# Without this, override `state.velocity = ["cos(facing)*22", 0, ...]`
	# survives Array→float coercion as Vector3.ZERO and the bullet doesn't
	# move. Empirically caught during doomarena3d build (2026-05-03).
	if overrides.has("state") and overrides["state"] is Dictionary:
		var ov_state: Dictionary = overrides["state"]
		for key in ["position", "velocity"]:
			if ov_state.has(key) and ov_state[key] is Array:
				ov_state[key] = _position(ov_state[key], env, ctx)
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
	# Presence of `z` decides 2D vs 3D output. Without z, classic Vector2
	# (top-down 2D games). With z, Vector3 — required for 3D homing,
	# vertical motion, etc. Empirically caught when doomarena3d's homing
	# rule on imps with X=0 didn't move them (Z component was silently
	# dropped).
	if e.has("z"):
		var vz := float(_value(e.get("z", 0), ctx, env))
		ent.set_velocity(Vector3(vx, vy, vz))
	else:
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


## Like velocity_set_relative but ADDS the contribution to current velocity
## instead of overwriting. Lets multiple input rules in the same tick combine
## (W + A both fire → forward + strafe contributions sum into a diagonal
## velocity). Drag handles deceleration when no input. Tune per-tick
## magnitude so equilibrium matches desired top speed: with drag d and tick
## delta dt, equilibrium ≈ add * (1 - d*dt) / (d*dt). Empirically caught
## during doomarena3d v2 playtest: diagonal motion broken because each
## velocity_set_relative call wiped the prior input's component (2026-05-03).
static func _velocity_add_relative(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = _target(e, env, ctx)
	if ent == null: return
	var fwd := float(_value(e.get("forward", 0), ctx, env))
	var strafe := float(_value(e.get("strafe", 0), ctx, env))
	var facing := float(ent.get_state("facing", 0.0))
	var fx := -sin(facing) * fwd
	var fz := -cos(facing) * fwd
	var sx := -cos(facing) * strafe
	var sz := sin(facing) * strafe
	var dvx := fx + sx
	var dvz := fz + sz
	var pos = ent.get_position()
	var v_cur = ent.get_velocity()
	if pos is Vector3:
		var base: Vector3 = Vector3.ZERO if v_cur == null else (v_cur as Vector3)
		ent.set_velocity(base + Vector3(dvx, 0, dvz))
	else:
		var base2: Vector2 = Vector2.ZERO if v_cur == null else (v_cur as Vector2)
		ent.set_velocity(base2 + Vector2(dvx, dvz))


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


# ============================================================
# RAYCAST_HIT (ADR 0005)
# ============================================================
# Hitscan weapon primitive — casts a ray from origin in direction up to
# max_distance, finds the closest entity matching tag filters, optionally
# capped by walls (blocks_motion AABBs). On hit: binds `hit` (entity id)
# and `hit_point` (Vector3 world position) and runs `on_hit` effects. On
# miss: binds `hit_point` (ray endpoint or wall hit point) and runs
# `on_miss`.
static func _raycast_hit(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var origin: Vector3 = _to_vec3_v(_position(e.get("origin", [0, 0, 0]), env, ctx))
	var direction: Vector3 = _to_vec3_v(_position(e.get("direction", [0, 0, -1]), env, ctx))
	if direction.length() < 1e-6: return
	direction = direction.normalized()
	var max_d: float = float(_value(e.get("max_distance", 100.0), ctx, env))
	var tags_all: Array = e.get("tags_all", [])
	var tags_none: Array = e.get("tags_none", [])
	var respect_obstacles: bool = bool(e.get("respect_obstacles", true))

	# Ray-vs-blockers: find first wall hit within max_d.
	var blocker_t: float = max_d
	if respect_obstacles:
		var blockers: Array = _collect_blockers_from_env(env)
		for b in blockers:
			var t: float = _ray_aabb_t(origin, direction, b)
			if t > 0.0 and t < blocker_t:
				blocker_t = t

	# Find closest entity matching tag filters within ray range.
	var closest_t: float = blocker_t
	var hit_id: String = ""
	var entities: Dictionary = env.get("entities", {})
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity): continue
		var ent_e: Entity = ent
		if not _matches_tags(ent_e, tags_all, tags_none): continue
		var radius := float(ent_e.get_property("body_radius", 0.4))
		var pos = ent_e.get_position()
		if pos == null: continue
		var p3: Vector3 = pos if pos is Vector3 else Vector3(pos.x, 0, pos.y)
		var t: float = _ray_sphere_t(origin, direction, p3, radius)
		if t > 0.0 and t < closest_t:
			closest_t = t
			hit_id = str(id)

	var hit_point: Vector3 = origin + direction * closest_t
	var sub_ctx: Dictionary = ctx.duplicate()
	sub_ctx["hit_point"] = hit_point
	if hit_id != "":
		sub_ctx["hit"] = hit_id
		for sub in (e.get("on_hit", []) as Array):
			if sub is Dictionary:
				apply(sub, env, sub_ctx)
	else:
		for sub in (e.get("on_miss", []) as Array):
			if sub is Dictionary:
				apply(sub, env, sub_ctx)


## Match tag filters with shared helpers.
static func _matches_tags(ent: Entity, tags_all: Array, tags_none: Array) -> bool:
	for t in tags_all:
		if not ent.has_tag(str(t)): return false
	for t in tags_none:
		if ent.has_tag(str(t)): return false
	return true


## Collect blocks_motion AABBs from env (mirrors World._collect_blockers
## without needing a World instance — usable from static effect context).
static func _collect_blockers_from_env(env: Dictionary) -> Array:
	var out: Array = []
	var entities: Dictionary = env.get("entities", {})
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity): continue
		if not (ent as Entity).has_tag("blocks_motion"): continue
		var ext = (ent as Entity).get_property("aabb_extents", null)
		if ext == null: continue
		var ext_v: Vector3 = _to_vec3_v(ext)
		var off_v: Vector3 = _to_vec3_v((ent as Entity).get_property("aabb_offset", [0, 0, 0]))
		var pos = (ent as Entity).get_position()
		var pos_v: Vector3 = Vector3.ZERO
		if pos is Vector3: pos_v = pos
		elif pos is Vector2: pos_v = Vector3(pos.x, 0, pos.y)
		else: continue
		var center: Vector3 = pos_v + off_v
		out.append({
			"minx": center.x - ext_v.x, "maxx": center.x + ext_v.x,
			"miny": center.y - ext_v.y, "maxy": center.y + ext_v.y,
			"minz": center.z - ext_v.z, "maxz": center.z + ext_v.z,
		})
	return out


## Ray-vs-AABB t parameter (slab method). Returns first positive t along
## the ray in [0, INF), or -1 if no intersection.
static func _ray_aabb_t(origin: Vector3, dir: Vector3, b: Dictionary) -> float:
	var t_near: float = -INF
	var t_far: float = INF
	# X
	if abs(dir.x) < 1e-6:
		if origin.x < b["minx"] or origin.x > b["maxx"]: return -1.0
	else:
		var t1: float = (b["minx"] - origin.x) / dir.x
		var t2: float = (b["maxx"] - origin.x) / dir.x
		if t1 > t2: var tmp := t1; t1 = t2; t2 = tmp
		t_near = max(t_near, t1); t_far = min(t_far, t2)
	# Y
	if abs(dir.y) < 1e-6:
		if origin.y < b["miny"] or origin.y > b["maxy"]: return -1.0
	else:
		var t1: float = (b["miny"] - origin.y) / dir.y
		var t2: float = (b["maxy"] - origin.y) / dir.y
		if t1 > t2: var tmp := t1; t1 = t2; t2 = tmp
		t_near = max(t_near, t1); t_far = min(t_far, t2)
	# Z
	if abs(dir.z) < 1e-6:
		if origin.z < b["minz"] or origin.z > b["maxz"]: return -1.0
	else:
		var t1: float = (b["minz"] - origin.z) / dir.z
		var t2: float = (b["maxz"] - origin.z) / dir.z
		if t1 > t2: var tmp := t1; t1 = t2; t2 = tmp
		t_near = max(t_near, t1); t_far = min(t_far, t2)
	if t_near > t_far or t_far < 0.0: return -1.0
	return max(t_near, 0.0)


## Ray-vs-sphere t parameter. Returns first positive t along the ray in
## [0, INF), or -1 if no intersection. Standard quadratic.
static func _ray_sphere_t(origin: Vector3, dir: Vector3, center: Vector3, r: float) -> float:
	var oc: Vector3 = origin - center
	var b: float = oc.dot(dir)
	var c: float = oc.dot(oc) - r * r
	var discr: float = b * b - c
	if discr < 0.0: return -1.0
	var sq: float = sqrt(discr)
	var t: float = -b - sq
	if t > 0.0: return t
	t = -b + sq
	if t > 0.0: return t
	return -1.0


static func _to_vec3_v(v) -> Vector3:
	if v is Vector3: return v
	if v is Vector2: return Vector3(v.x, 0, v.y)
	if v is Array:
		var a := v as Array
		if a.size() >= 3: return Vector3(float(a[0]), float(a[1]), float(a[2]))
		if a.size() == 2: return Vector3(float(a[0]), 0, float(a[1]))
	if v is float or v is int:
		return Vector3(float(v), float(v), float(v))
	return Vector3.ZERO


## ADR 0006: defer level transition. Sets env._pending_level_transition to
## target name; world.gd processes this between ticks (after the current
## rule's effect chain finishes) so we don't mutate entities mid-rule.
## target = "next" → engine looks up the next level in progression.levels.
static func _transition_level(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var target := str(_value(e.get("target", "next"), ctx, env))
	if target == "": return
	env["_pending_level_transition"] = target
