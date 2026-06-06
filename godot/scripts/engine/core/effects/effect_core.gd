extends Object
class_name EffectCore

## Foundational effect handlers — Yume's primitive vocabulary
## (state / zone-state / lifecycle / relation / tag / signal).
##
## Per ADR 0001 these are the engine's seven primitives in effect form:
##   - state primitive (#1's "reserved state fields" + arbitrary state):
##     state_set, state_add, state_mul, state_clamp
##   - zone-state primitive (ADR 0031):
##     zone_state_set, zone_state_add, zone_state_clamp
##   - lifecycle (entity birth/death/replacement):
##     spawn, remove, transform
##   - relation primitive (#7):
##     relate, unrelate, transfer_relation
##   - tag primitive (#2):
##     tag_add, tag_remove
##   - signal primitive (event-shaped):
##     emit, emit_shell_event
##
## All static. Shared resolution lives in EffectResolution (target/value/etc.).
## Effect dispatcher (the apply() match) lives in EffectApply.

# ============================================================
# STATE EFFECTS
# ============================================================


static func state_set(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	var field := str(e.get("field", ""))
	var value = EffectResolution.value(e.get("value"), ctx, env)
	# 2026-05-04 consistency fix: position/velocity field-sets route through
	# Entity's normalizing setters so Array values [x, y] → Vector2 (or
	# [x, y, z] → Vector3). Without this, state_set field="position" with
	# an Array stores raw Array — renderer handles it via get_planar_position
	# but formulas reading self.state.position.x return 0 (Formula doesn't
	# drill into Arrays). Normalizing keeps state.position as Vector2/Vector3
	# regardless of how it was set.
	if field == "position":
		ent.set_position(value)
		# 2026-05-05: state_set position must update spatial index, else contact
		# queries see stale cell registration. Without this, an entity moved via
		# state_set (no velocity) becomes invisible to radius queries the moment
		# it crosses a spatial cell boundary. Caught during sokoban L2 playthrough
		# debug — boxes crossed cells after a few pushes and box_at_attempt
		# queries stopped matching them. Motion-integration update covers
		# velocity-driven movement; this covers effect-driven movement.
		var sx = env.get("spatial_index", null)
		if sx != null and sx.has_method("update_entity"):
			sx.update_entity(ent.instance_id, ent.get_planar_position())
	elif field == "velocity":
		ent.set_velocity(value)
	else:
		ent.set_state(field, value)


static func state_add(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	ent.add_state(str(e.get("field", "")), float(EffectResolution.value(e.get("amount"), ctx, env)))


static func state_mul(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	var field := str(e.get("field", ""))
	var factor := float(EffectResolution.value(e.get("amount"), ctx, env))
	ent.set_state(field, float(ent.get_state(field, 0)) * factor)


static func state_clamp(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	var field := str(e.get("field", ""))
	var lo := float(e.get("min", -INF))
	var hi := float(e.get("max", INF))
	ent.set_state(field, clamp(float(ent.get_state(field, 0)), lo, hi))


# ============================================================
# ZONE STATE EFFECTS (ADR 0031)
# ============================================================
#
# Three new vocabulary items: zone_state_set / _add / _clamp.
# Schema: {type, zone, field, value | amount | min/max}.
#
# `zone` resolves like entity targets — context binding (e.g. "a.zone_id"
# resolved through formulas, or a bare ctx key) first, literal id fallback.
# Effects no-op silently (with a warning EngineError) if zone_store is
# missing or the zone id is unknown — matches state_set's behavior on
# missing entity targets.


static func resolve_zone_id(v, ctx: Dictionary, env: Dictionary) -> String:
	# Mirror _resolve_id but accept formulas too (e.g. "world.active_kingdom").
	if v == null:
		return ""
	if v is String:
		var s := str(v)
		# Bare context binding (e.g. "kingdom" → ctx["kingdom"])
		if ctx.has(s):
			return str(ctx[s])
		# Formula? evaluate it (e.g. "world.active_kingdom", "self.home_zone")
		if Formula.looks_like_formula(s):
			var fctx := EffectResolution.formula_context(ctx, env)
			if ctx.has("_rule_id"):
				fctx["_rule_id"] = ctx["_rule_id"]
			var resolved = Formula.evaluate(s, fctx, env)
			return str(resolved) if resolved != null else ""
		# Literal id
		return s
	return str(v)


static func zone_store(env: Dictionary):
	return env.get("zone_store", null)


static func zone_state_set(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var zs = zone_store(env)
	if zs == null:
		return
	var zid := resolve_zone_id(e.get("zone"), ctx, env)
	if zid == "" or not zs.has(zid):
		(
			EngineError
			. raise(
				env,
				"effect.zone_unknown",
				"zone_state_set: unknown zone '%s'" % zid,
				{"rule_id": ctx.get("_rule_id", ""), "field": "zone", "got": zid},
				"Verify the zone id exists in world/zones.json or that the binding resolves to a known zone.",
				"warning"
			)
		)
		return
	var field := str(e.get("field", ""))
	var value = EffectResolution.value(e.get("value"), ctx, env)
	zs.set_field(zid, field, value)


static func zone_state_add(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var zs = zone_store(env)
	if zs == null:
		return
	var zid := resolve_zone_id(e.get("zone"), ctx, env)
	if zid == "" or not zs.has(zid):
		(
			EngineError
			. raise(
				env,
				"effect.zone_unknown",
				"zone_state_add: unknown zone '%s'" % zid,
				{"rule_id": ctx.get("_rule_id", ""), "field": "zone", "got": zid},
				"Verify the zone id exists in world/zones.json or that the binding resolves to a known zone.",
				"warning"
			)
		)
		return
	var field := str(e.get("field", ""))
	# Per ADR §"Effects" — amount is the canonical key (mirrors state_add).
	# Accept `delta` as a back-compat alias since the ADR's example JSON
	# spelled it `delta`. Authors land on `amount` going forward.
	var raw = e.get("amount", e.get("delta", 0))
	var delta := float(EffectResolution.value(raw, ctx, env))
	zs.add_field(zid, field, delta)


static func zone_state_clamp(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var zs = zone_store(env)
	if zs == null:
		return
	var zid := resolve_zone_id(e.get("zone"), ctx, env)
	if zid == "" or not zs.has(zid):
		(
			EngineError
			. raise(
				env,
				"effect.zone_unknown",
				"zone_state_clamp: unknown zone '%s'" % zid,
				{"rule_id": ctx.get("_rule_id", ""), "field": "zone", "got": zid},
				"Verify the zone id exists in world/zones.json or that the binding resolves to a known zone.",
				"warning"
			)
		)
		return
	var field := str(e.get("field", ""))
	var lo := float(EffectResolution.value(e.get("min", -INF), ctx, env))
	var hi := float(EffectResolution.value(e.get("max", INF), ctx, env))
	zs.clamp_field(zid, field, lo, hi)


# ============================================================
# LIFECYCLE EFFECTS
# ============================================================


## Spawn a new entity from a def template. Returns {new_id: "..."} for the
## phase scheduler to dispatch `spawn` triggers against. Position can be:
##   - "self"/"a"/"b"/etc.  → copy context entity's position
##   - [x, y] or Vector2    → literal
##   - absent               → origin
static func spawn(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var defs: Dictionary = env.get("defs", {})
	var template := str(e.get("template", ""))
	if not defs.has(template):
		EngineError.raise(
			env,
			EngineError.EFFECT_SPAWN_NO_DEF,
			"spawn: no def '%s'" % template,
			{
				"rule_id": ctx.get("_rule_id", ""),
				"field": "effect.template",
				"got": template,
				"known_defs": defs.keys()
			},
			(
				"Add a definition with id '%s' to entities.json, or fix the spawn template name."
				% template
			)
		)
		return {}
	var def: Dictionary = defs[template]
	var overrides: Dictionary = (e.get("overrides", {}) as Dictionary).duplicate(true)
	if e.has("position"):
		overrides["position"] = EffectResolution.position(e["position"], env, ctx)
	# Resolve formula strings in state overrides. position/velocity are Arrays
	# (Vector-valued → EffectResolution.position); every OTHER scalar override
	# that's a formula string goes through EffectResolution.value. Without the
	# scalar pass, `state.y_velocity = "sin(pitch)*22"` survived as a STRING and
	# coerced to 0 — a pitch-aimed projectile flew flat (the runner's vertical
	# channel got 0). Array case empirically caught 2026-05-03; scalar case
	# 2026-06-06 (doomarena3d "shoot up, bullet still goes horizontal").
	if overrides.has("state") and overrides["state"] is Dictionary:
		var ov_state: Dictionary = overrides["state"]
		for key in ov_state.keys():
			var ov_v = ov_state[key]
			if (key == "position" or key == "velocity") and ov_v is Array:
				ov_state[key] = EffectResolution.position(ov_v, env, ctx)
			elif ov_v is String:
				ov_state[key] = EffectResolution.value(ov_v, ctx, env)
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
		# Attach the per-entity renderer so a runtime spawn is VISIBLE (initial
		# instances get this via SpawnManager._attach_renderer). NOTE: the hook
		# is World.attach_runtime_renderer, NOT "_attach_renderer" — the latter
		# lives on SpawnManager, not on env.parent (World), so the old guard was
		# always false and rule-spawned entities rendered nothing (collider only).
		# Empirical 2026-06-06: doomarena3d monsters + bullets were invisible.
		if parent.has_method("attach_runtime_renderer"):
			parent.call("attach_runtime_renderer", ent)
		# ADR 0044/0045 parity: build the physics body for runtime spawns too.
		# SpawnManager.spawn (initial instances) builds bodies; this path didn't,
		# so rule-spawned movers (projectiles, summoned NPCs) were frozen — they
		# got a renderer but no CharacterBody3D / rigid body to integrate motion.
		# Empirical 2026-06-06: doomarena3d enemies + bullets never moved.
		if parent.has_method("build_runtime_physics_body"):
			parent.call("build_runtime_physics_body", ent)
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


static func remove(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
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
static func transform(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return {}
	var to_def := str(e.get("to", ""))
	var defs: Dictionary = env.get("defs", {})
	if not defs.has(to_def):
		EngineError.raise(
			env,
			EngineError.EFFECT_TRANSFORM_NO_DEF,
			"transform: no def '%s'" % to_def,
			{
				"rule_id": ctx.get("_rule_id", ""),
				"field": "effect.to",
				"got": to_def,
				"known_defs": defs.keys()
			},
			"Add a definition with id '%s' to entities.json, or fix the transform target." % to_def
		)
		return {}
	var preserved_state: Dictionary = ent.state.duplicate(true)
	# Remove old
	remove({"type": "remove", "target": e.get("target", "self")}, env, ctx)
	# Spawn new — pass preserved state as overrides so it mixes with new def's
	# state_init. Position lives inside preserved_state so it carries over.
	return spawn(
		{
			"type": "spawn",
			"template": to_def,
			"overrides": {"state": preserved_state},
		},
		env,
		ctx
	)


# ============================================================
# RELATION EFFECTS
# ============================================================


static func relate(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var store: RelationStore = env.get("relations", null)
	if store == null:
		return
	var type := str(e.get("relation", ""))
	var from_id := EffectResolution.resolve_id(e.get("from", "self"), ctx)
	var to_id := EffectResolution.resolve_id(e.get("to", ""), ctx)
	if type == "" or from_id == "" or to_id == "":
		return
	store.relate(type, from_id, to_id)


static func unrelate(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var store: RelationStore = env.get("relations", null)
	if store == null:
		return
	var type := str(e.get("relation", ""))
	var from_id := EffectResolution.resolve_id(e.get("from", "self"), ctx)
	var to_id := EffectResolution.resolve_id(e.get("to", ""), ctx)
	if type == "" or from_id == "" or to_id == "":
		return
	store.unrelate(type, from_id, to_id)


## Swap one endpoint of an edge.
##   {relation, from, to, new_to}   → move `from→to` to `from→new_to`
##   {relation, from, to, new_from} → move `from→to` to `new_from→to`
static func transfer_relation(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var store: RelationStore = env.get("relations", null)
	if store == null:
		return
	var type := str(e.get("relation", ""))
	var from_id := EffectResolution.resolve_id(e.get("from", "self"), ctx)
	var to_id := EffectResolution.resolve_id(e.get("to", ""), ctx)
	if e.has("new_to"):
		store.transfer_to(type, from_id, to_id, EffectResolution.resolve_id(e["new_to"], ctx))
	elif e.has("new_from"):
		store.transfer_from(type, from_id, EffectResolution.resolve_id(e["new_from"], ctx), to_id)


# ============================================================
# TAG EFFECTS
# ============================================================


static func tag_add(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	ent.add_tag(str(e.get("tag", "")))


static func tag_remove(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	ent.remove_tag(str(e.get("tag", "")))


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
static func emit_shell_event(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var event_name := str(e.get("event", ""))
	if event_name == "":
		return
	var record: Dictionary = {"event": event_name}
	for k in e.keys():
		if str(k) == "type" or str(k) == "event":
			continue
		record[str(k)] = EffectResolution.value(e[k], ctx, env)
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


# ============================================================
# ARRAY PRIMITIVES (2026-05-16 — multi-slot inventory foundation)
# ============================================================
# Generic effects for Array-valued state fields. Inventory composes
# these (state.inventory = ["", "", "", ""]; array_insert_first_empty
# = "pick up into next free slot"; array_set_at = "use / drop / set
# directly"). Not inventory-specific — usable for any Array-valued
# field (action history, message buffer, sequenced state, etc.).


## Set state[field][index] = value. Bounds-extends the array with
## `null` if the index is past the end. Returns silently if entity /
## field missing.
static func array_set_at(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	var field := str(e.get("field", ""))
	if field == "":
		return
	var index := int(EffectResolution.value(e.get("index", 0), ctx, env))
	# Negative index = sentinel for "no slot" (e.g. array_insert_first_empty
	# failed to find a free slot). Treat as a no-op rather than wrapping
	# Python-style to the array's tail.
	if index < 0:
		return
	var value = EffectResolution.value(e.get("value", null), ctx, env)
	var arr_v = ent.get_state(field, [])
	if not (arr_v is Array):
		arr_v = []
	var arr: Array = (arr_v as Array).duplicate()
	while arr.size() <= index:
		arr.append(null)
	arr[index] = value
	ent.set_state(field, arr)


## Insert value at the first slot of state[field] matching `sentinel`
## (default ""). On success, writes the chosen slot index to
## state[result_field] (if `result_field` is set, default "_last_slot") so
## subsequent effects in the chain can reference it (e.g. array_set_at
## on a parallel array using the same index). On failure (no empty slot),
## writes -1 to result_field and optionally emits `on_full.signal`.
## Used for "pick up into first free inventory slot."
static func array_insert_first_empty(
	e: Dictionary, env: Dictionary, ctx: Dictionary
) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	var field := str(e.get("field", ""))
	if field == "":
		return
	var sentinel = EffectResolution.value(e.get("sentinel", ""), ctx, env)
	var value = EffectResolution.value(e.get("value", null), ctx, env)
	if value == null:
		return
	var result_field := str(e.get("result_field", "_last_slot"))
	var arr_v = ent.get_state(field, [])
	if not (arr_v is Array):
		arr_v = []
	var arr: Array = (arr_v as Array).duplicate()
	for i in arr.size():
		if arr[i] == sentinel:
			arr[i] = value
			ent.set_state(field, arr)
			ent.set_state(result_field, i)
			return
	# All slots full.
	ent.set_state(result_field, -1)
	var on_full = e.get("on_full", null)
	if on_full != null and on_full is Dictionary:
		var sig_name = str((on_full as Dictionary).get("signal", ""))
		if sig_name != "":
			var buf = env.get("signal_buffer", null)
			if buf != null:
				var payload: Dictionary = (
					((on_full as Dictionary).get("payload", {}) as Dictionary).duplicate()
				)
				buf.append({"name": sig_name, "payload": payload})


## Count elements of state[array_field] equal to sentinel; write count to
## state[dest_field]. Used to derive "empty-slot count" for inventory gating
## without needing array-aware query operators.
static func array_count_matching(
	e: Dictionary, env: Dictionary, ctx: Dictionary
) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	var array_field := str(e.get("array_field", ""))
	var dest_field := str(e.get("dest_field", ""))
	if array_field == "" or dest_field == "":
		return
	var sentinel = EffectResolution.value(e.get("sentinel", ""), ctx, env)
	var arr_v = ent.get_state(array_field, [])
	var count := 0
	if arr_v is Array:
		for item in arr_v as Array:
			if item == sentinel:
				count += 1
	ent.set_state(dest_field, count)


## Read state[array_field][state[index_field]] and write it to state[dest_field].
## Used to derive a "view" scalar field from one slot of a parallel-array
## inventory (e.g. held_item ← inventory[active_slot]). The formula evaluator
## can't yet do dynamic array subscripts in a path, so this effect exposes
## the pattern without bloating formula.gd. Returns the `default` value if
## the index is out of bounds or the array field is missing.
static func array_sync_to_field(
	e: Dictionary, env: Dictionary, ctx: Dictionary
) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	var array_field := str(e.get("array_field", ""))
	var index_field := str(e.get("index_field", ""))
	var dest_field := str(e.get("dest_field", ""))
	if array_field == "" or index_field == "" or dest_field == "":
		return
	var default_val = e.get("default", "")
	var arr_v = ent.get_state(array_field, [])
	var idx := int(ent.get_state(index_field, 0))
	var out_val = default_val
	if arr_v is Array:
		var arr: Array = arr_v
		if idx >= 0 and idx < arr.size():
			out_val = arr[idx]
			if out_val == null:
				out_val = default_val
	ent.set_state(dest_field, out_val)


static func emit(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var name := str(e.get("signal", ""))
	if name == "":
		return
	var raw_payload: Dictionary = e.get("payload", {}) as Dictionary
	var resolved_payload: Dictionary = {}
	for k in raw_payload.keys():
		resolved_payload[k] = EffectResolution.value(raw_payload[k], ctx, env)
	var buf: Array = env.get("signal_buffer", null)
	if buf == null:
		(
			EngineError
			. raise(
				env,
				EngineError.EFFECT_EMIT_NO_BUFFER,
				"emit: env has no signal_buffer — scheduler may be uninitialized",
				{"rule_id": ctx.get("_rule_id", ""), "field": "effect.signal", "got": name},
				"This usually means an effect ran outside a phase scheduler. Wire env via PhaseScheduler.new(env).",
				"warning"
			)
		)
		return
	buf.append({"name": name, "payload": resolved_payload})
