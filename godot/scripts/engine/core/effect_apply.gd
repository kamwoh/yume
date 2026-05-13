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
		"state_set":
			_state_set(effect, env, context)
		"state_add":
			_state_add(effect, env, context)
		"state_mul":
			_state_mul(effect, env, context)
		"state_clamp":
			_state_clamp(effect, env, context)
		# ADR 0031 — aggregated zone-state primitive
		"zone_state_set":
			_zone_state_set(effect, env, context)
		"zone_state_add":
			_zone_state_add(effect, env, context)
		"zone_state_clamp":
			_zone_state_clamp(effect, env, context)
		"spawn":
			return _spawn(effect, env, context)
		"remove":
			_remove(effect, env, context)
		"transform":
			return _transform(effect, env, context)
		"relate":
			_relate(effect, env, context)
		"unrelate":
			_unrelate(effect, env, context)
		"transfer_relation":
			_transfer_relation(effect, env, context)
		"tag_add":
			_tag_add(effect, env, context)
		"tag_remove":
			_tag_remove(effect, env, context)
		"velocity_set":
			_velocity_set(effect, env, context)
		"velocity_lerp":
			_velocity_lerp(effect, env, context)
		"velocity_set_relative":
			_velocity_set_relative(effect, env, context)
		"velocity_add_relative":
			_velocity_add_relative(effect, env, context)
		"pathfind_to":
			_pathfind_to(effect, env, context)
		"raycast_hit":
			_raycast_hit(effect, env, context)
		"transition_level":
			_transition_level(effect, env, context)
		"emit":
			_emit(effect, env, context)
		"emit_shell_event":
			_emit_shell_event(effect, env, context)
		"transition_screen":
			_transition_screen(effect, env, context)
		"quit_app":
			_quit_app(effect, env, context)
		"show_toast":
			_show_toast(effect, env, context)
		"reload_scene":
			_reload_scene(effect, env, context)
		"scene_change":
			_scene_change(effect, env, context)
		"screen_fade":
			_screen_fade(effect, env, context)
		"save_state":
			_save_state(effect, env, context)
		"load_state":
			_load_state(effect, env, context)
		"show_overlay":
			_show_overlay_effect(effect, env, context)
		"dismiss_overlay":
			_dismiss_overlay_effect(effect, env, context)
		"set_audio_bus_volume":
			_set_audio_bus_volume(effect, env, context)
		"set_input_mapping":
			_set_input_mapping(effect, env, context)
		"switch_actor":
			_switch_actor(effect, env, context)
		"queue_input_for_actor":
			_queue_input_for_actor(effect, env, context)
		"reset_world":
			_reset_world(effect, env, context)
		"party_join":
			_party_join(effect, env, context)
		"party_leave":
			_party_leave(effect, env, context)
		"party_ko":
			_party_ko(effect, env, context)
		"build_place":
			return _build_place(effect, env, context)
		"switch_class":
			return _switch_class(effect, env, context)
		# ADR 0032 — faction primitive
		"declare_war":
			return _declare_war(effect, env, context)
		"sign_treaty":
			return _sign_treaty(effect, env, context)
		"propose_alliance":
			return _propose_alliance(effect, env, context)
		"swear_loyalty":
			return _swear_loyalty(effect, env, context)
		# ADR 0033 — tech-tree primitive
		"try_discover_tech":
			return _try_discover_tech(effect, env, context)
		"learn_from_master":
			return _learn_from_master(effect, env, context)
		"pass_to_apprentice":
			return _pass_to_apprentice(effect, env, context)
		# ADR 0034 — dynasty / heir succession primitive
		"transfer_inventory":
			return _transfer_inventory(effect, env, context)
		"transfer_reputation":
			return _transfer_reputation(effect, env, context)
		"transfer_techs":
			return _transfer_techs(effect, env, context)
		"transition_player_to":
			return _transition_player_to(effect, env, context)
		_:
			EngineError.raise(
				env,
				EngineError.EFFECT_UNKNOWN_TYPE,
				"Unknown effect type: '%s'" % type,
				{"rule_id": context.get("_rule_id", ""), "field": "effect.type", "got": type},
				(
					"Use one of: state_set, state_add, state_mul, state_clamp,"
					+ " zone_state_set, zone_state_add, zone_state_clamp, spawn, remove,"
					+ " transform, relate, unrelate, transfer_relation, tag_add, tag_remove,"
					+ " velocity_set, velocity_lerp, velocity_set_relative,"
					+ " velocity_add_relative, pathfind_to, raycast_hit, transition_level,"
					+ " emit, emit_shell_event, transition_screen, quit_app, show_toast,"
					+ " reload_scene, scene_change, screen_fade, save_state, load_state,"
					+ " show_overlay, dismiss_overlay, set_audio_bus_volume,"
					+ " set_input_mapping, switch_actor, queue_input_for_actor, reset_world,"
					+ " party_join, party_leave, party_ko, build_place, switch_class,"
					+ " declare_war, sign_treaty, propose_alliance, swear_loyalty,"
					+ " try_discover_tech, learn_from_master, pass_to_apprentice,"
					+ " transfer_inventory, transfer_reputation, transfer_techs,"
					+ " transition_player_to."
				),
				"warning"
			)
	return {}


# ============================================================
# STATE EFFECTS
# ============================================================


static func _state_set(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
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


static func _state_add(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	ent.add_state(str(e.get("field", "")), float(EffectResolution.value(e.get("amount"), ctx, env)))


static func _state_mul(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	var field := str(e.get("field", ""))
	var factor := float(EffectResolution.value(e.get("amount"), ctx, env))
	ent.set_state(field, float(ent.get_state(field, 0)) * factor)


static func _state_clamp(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
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


static func _resolve_zone_id(v, ctx: Dictionary, env: Dictionary) -> String:
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


static func _zone_store(env: Dictionary):
	return env.get("zone_store", null)


static func _zone_state_set(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var zs = _zone_store(env)
	if zs == null:
		return
	var zid := _resolve_zone_id(e.get("zone"), ctx, env)
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


static func _zone_state_add(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var zs = _zone_store(env)
	if zs == null:
		return
	var zid := _resolve_zone_id(e.get("zone"), ctx, env)
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


static func _zone_state_clamp(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var zs = _zone_store(env)
	if zs == null:
		return
	var zid := _resolve_zone_id(e.get("zone"), ctx, env)
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
static func _spawn(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
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
	# Resolve formula strings in state-override Arrays (position/velocity).
	# Without this, override `state.velocity = ["cos(facing)*22", 0, ...]`
	# survives Array→float coercion as Vector3.ZERO and the bullet doesn't
	# move. Empirically caught during doomarena3d build (2026-05-03).
	if overrides.has("state") and overrides["state"] is Dictionary:
		var ov_state: Dictionary = overrides["state"]
		for key in ["position", "velocity"]:
			if ov_state.has(key) and ov_state[key] is Array:
				ov_state[key] = EffectResolution.position(ov_state[key], env, ctx)
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
static func _transform(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
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
	_remove({"type": "remove", "target": e.get("target", "self")}, env, ctx)
	# Spawn new — pass preserved state as overrides so it mixes with new def's
	# state_init. Position lives inside preserved_state so it carries over.
	return _spawn(
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


static func _relate(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var store: RelationStore = env.get("relations", null)
	if store == null:
		return
	var type := str(e.get("relation", ""))
	var from_id := EffectResolution.resolve_id(e.get("from", "self"), ctx)
	var to_id := EffectResolution.resolve_id(e.get("to", ""), ctx)
	if type == "" or from_id == "" or to_id == "":
		return
	store.relate(type, from_id, to_id)


static func _unrelate(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
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
static func _transfer_relation(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
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


static func _tag_add(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	ent.add_tag(str(e.get("tag", "")))


static func _tag_remove(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	ent.remove_tag(str(e.get("tag", "")))


# ============================================================
# MOTION (W2 will also add the per-tick motion integrator alongside this)
# ============================================================


static func _velocity_set(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	# Per-axis preservation: if a key is OMITTED, the entity's current
	# velocity component for that axis is retained. Lets independent
	# directional rules (move_north sets y, move_east sets x) combine
	# in the same tick instead of clobbering each other. Empirical case
	# 2026-05-10: WASD lib's 4 separate velocity_set rules each
	# specified BOTH x and y → W+D = whichever fired last won →
	# diagonal motion broken. Now: move_east specifies only x; move_north
	# specifies only y; they compose for diagonals.
	var v_cur = ent.get_velocity()
	var has_x := e.has("x")
	var has_y := e.has("y")
	var has_z := e.has("z")
	var vx: float = (
		float(EffectResolution.value(e.get("x", 0), ctx, env))
		if has_x
		else (
			float((v_cur as Vector3).x)
			if v_cur is Vector3
			else (float((v_cur as Vector2).x) if v_cur is Vector2 else 0.0)
		)
	)
	var vy: float = (
		float(EffectResolution.value(e.get("y", 0), ctx, env))
		if has_y
		else (
			float((v_cur as Vector3).y)
			if v_cur is Vector3
			else (float((v_cur as Vector2).y) if v_cur is Vector2 else 0.0)
		)
	)
	# Presence of `z` decides 2D vs 3D output. Without z, classic Vector2
	# (top-down 2D games). With z, Vector3 — required for 3D homing,
	# vertical motion, etc. Empirically caught when doomarena3d's homing
	# rule on imps with X=0 didn't move them (Z component was silently
	# dropped).
	if has_z or v_cur is Vector3:
		var vz: float = (
			float(EffectResolution.value(e.get("z", 0), ctx, env))
			if has_z
			else (float((v_cur as Vector3).z) if v_cur is Vector3 else 0.0)
		)
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
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	var fwd := float(EffectResolution.value(e.get("forward", 0), ctx, env))
	var strafe := float(EffectResolution.value(e.get("strafe", 0), ctx, env))
	# ADR 0040: optional `facing` override. When present, fixes the rotation
	# regardless of actor.state.facing — used by iso/top-down WASD variants
	# where the camera yaw is constant. Default falls back to actor's facing
	# (set by mouse-look in FP/TP modes).
	var facing: float
	if e.has("facing"):
		facing = float(EffectResolution.value(e["facing"], ctx, env))
	else:
		facing = float(ent.get_state("facing", 0.0))
	# Forward in world: rotate (0,0,-1) by yaw around Y → (-sin, 0, -cos)
	var fx := -sin(facing) * fwd
	var fz := -cos(facing) * fwd
	# Strafe right (player's right when facing yaw): R_y(-90°) of forward.
	# At facing=0 (looking -Z), right = +X (east). General: right = (cos,
	# -sin) in (X, Z). Bug fix 2026-05-08 — previous formula computed
	# 90° CCW (player's left) and the comment misclaimed it was CW. User:
	# "first person view, the left and right are reversed".
	var sx := cos(facing) * strafe
	var sz := -sin(facing) * strafe
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
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	var fwd := float(EffectResolution.value(e.get("forward", 0), ctx, env))
	var strafe := float(EffectResolution.value(e.get("strafe", 0), ctx, env))
	# ADR 0040: optional `facing` override (same shape as _velocity_set_relative).
	var facing: float
	if e.has("facing"):
		facing = float(EffectResolution.value(e["facing"], ctx, env))
	else:
		facing = float(ent.get_state("facing", 0.0))
	var fx := -sin(facing) * fwd
	var fz := -cos(facing) * fwd
	# ADR 0040 Condition 1 (2026-05-10): strafe-sign harmonized with
	# _velocity_set_relative. Was `sx = -cos(facing) * strafe; sz = sin(facing) * strafe`
	# — opposite sign produced player's-LEFT instead of player's-RIGHT for
	# positive strafe. Iso variant rules use strafe=0 so the bug doesn't
	# manifest there, but third-person strafe was inverted relative to
	# _set_relative's convention.
	var sx := cos(facing) * strafe
	var sz := -sin(facing) * strafe
	var dvx := fx + sx
	var dvz := fz + sz
	# Branch on VELOCITY type, not position. Aldenmere-style entities use
	# Vector2 velocity (per WASD lib convention) with Vector3 position;
	# casting v_cur (Vector2) to Vector3 crashed previously. ADR 0040 fix
	# 2026-05-10.
	var v_cur = ent.get_velocity()
	if v_cur is Vector2:
		ent.set_velocity((v_cur as Vector2) + Vector2(dvx, dvz))
	elif v_cur is Vector3:
		ent.set_velocity((v_cur as Vector3) + Vector3(dvx, 0, dvz))
	else:
		# No prior velocity — pick dimensionality from position.
		var pos = ent.get_position()
		if pos is Vector3:
			ent.set_velocity(Vector3(dvx, 0, dvz))
		else:
			ent.set_velocity(Vector2(dvx, dvz))


## Smoothly approach a target velocity each tick. Lets entities feel weighty —
## input rules use velocity_lerp instead of velocity_set so movement
## ramps in/out instead of snapping. `rate` is the per-tick lerp factor
## (0.0 = no change, 1.0 = snap to target). Typical: 0.10-0.25.
static func _velocity_lerp(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	var tx := float(EffectResolution.value(e.get("x", 0), ctx, env))
	var ty := float(EffectResolution.value(e.get("y", 0), ctx, env))
	var rate: float = clamp(float(EffectResolution.value(e.get("rate", 0.15), ctx, env)), 0.0, 1.0)
	var current = ent.get_velocity()
	var current_v: Vector2 = Vector2.ZERO
	if current is Vector2:
		current_v = current
	var lerped: Vector2 = current_v.lerp(Vector2(tx, ty), rate)
	ent.set_velocity(lerped)


## ADR 0024 — pathfind_to. Wraps Pathfinding.tick_pathfind:
## resolves destination_x/y/z + speed (formula bindings supported),
## delegates to the Pathfinding module which writes velocity. No-op
## when target is 2D-positioned or when no navmesh has been built
## for the current level.
##
## Schema:
##   {"type": "pathfind_to", "target": "self",
##    "destination_x": <float|formula>,
##    "destination_y": <float|formula>,
##    "destination_z": <float|formula>,
##    "speed": <float|formula>}
static func _pathfind_to(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	var dx := float(EffectResolution.value(e.get("destination_x", 0), ctx, env))
	var dy := float(EffectResolution.value(e.get("destination_y", 0), ctx, env))
	var dz := float(EffectResolution.value(e.get("destination_z", 0), ctx, env))
	var speed := float(EffectResolution.value(e.get("speed", 1.0), ctx, env))
	Pathfinding.tick_pathfind(env, ent, dx, dy, dz, speed)


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


static func _emit(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
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
	var origin: Vector3 = Vec3Util.from_world_pos(EffectResolution.position(e.get("origin", [0, 0, 0]), env, ctx))
	var direction: Vector3 = Vec3Util.from_world_pos(
		EffectResolution.position(e.get("direction", [0, 0, -1]), env, ctx)
	)
	if direction.length() < 1e-6:
		return
	direction = direction.normalized()
	var max_d: float = float(EffectResolution.value(e.get("max_distance", 100.0), ctx, env))
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
		if not (ent is Entity):
			continue
		var ent_e: Entity = ent
		if not _matches_tags(ent_e, tags_all, tags_none):
			continue
		var radius := float(ent_e.get_property("body_radius", 0.4))
		var pos = ent_e.get_position()
		if pos == null:
			continue
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
		for sub in e.get("on_hit", []) as Array:
			if sub is Dictionary:
				apply(sub, env, sub_ctx)
	else:
		for sub in e.get("on_miss", []) as Array:
			if sub is Dictionary:
				apply(sub, env, sub_ctx)


## Match tag filters with shared helpers.
static func _matches_tags(ent: Entity, tags_all: Array, tags_none: Array) -> bool:
	for t in tags_all:
		if not ent.has_tag(str(t)):
			return false
	for t in tags_none:
		if ent.has_tag(str(t)):
			return false
	return true


## Collect blocks_motion AABBs from env (mirrors World._collect_blockers
## without needing a World instance — usable from static effect context).
static func _collect_blockers_from_env(env: Dictionary) -> Array:
	var out: Array = []
	var entities: Dictionary = env.get("entities", {})
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity):
			continue
		if not (ent as Entity).has_tag("blocks_motion"):
			continue
		var ext = (ent as Entity).get_property("aabb_extents", null)
		if ext == null:
			continue
		var ext_v: Vector3 = Vec3Util.from_world_pos(ext)
		var off_v: Vector3 = Vec3Util.from_world_pos(
			(ent as Entity).get_property("aabb_offset", [0, 0, 0])
		)
		var pos = (ent as Entity).get_position()
		var pos_v: Vector3 = Vector3.ZERO
		if pos is Vector3:
			pos_v = pos
		elif pos is Vector2:
			pos_v = Vector3(pos.x, 0, pos.y)
		else:
			continue
		var center: Vector3 = pos_v + off_v
		(
			out
			. append(
				{
					"minx": center.x - ext_v.x,
					"maxx": center.x + ext_v.x,
					"miny": center.y - ext_v.y,
					"maxy": center.y + ext_v.y,
					"minz": center.z - ext_v.z,
					"maxz": center.z + ext_v.z,
				}
			)
		)
	return out


## Ray-vs-AABB t parameter (slab method). Returns first positive t along
## the ray in [0, INF), or -1 if no intersection.
static func _ray_aabb_t(origin: Vector3, dir: Vector3, b: Dictionary) -> float:
	var t_near: float = -INF
	var t_far: float = INF
	# X
	if abs(dir.x) < 1e-6:
		if origin.x < b["minx"] or origin.x > b["maxx"]:
			return -1.0
	else:
		var t1: float = (b["minx"] - origin.x) / dir.x
		var t2: float = (b["maxx"] - origin.x) / dir.x
		if t1 > t2:
			var tmp := t1
			t1 = t2
			t2 = tmp
		t_near = max(t_near, t1)
		t_far = min(t_far, t2)
	# Y
	if abs(dir.y) < 1e-6:
		if origin.y < b["miny"] or origin.y > b["maxy"]:
			return -1.0
	else:
		var t1: float = (b["miny"] - origin.y) / dir.y
		var t2: float = (b["maxy"] - origin.y) / dir.y
		if t1 > t2:
			var tmp := t1
			t1 = t2
			t2 = tmp
		t_near = max(t_near, t1)
		t_far = min(t_far, t2)
	# Z
	if abs(dir.z) < 1e-6:
		if origin.z < b["minz"] or origin.z > b["maxz"]:
			return -1.0
	else:
		var t1: float = (b["minz"] - origin.z) / dir.z
		var t2: float = (b["maxz"] - origin.z) / dir.z
		if t1 > t2:
			var tmp := t1
			t1 = t2
			t2 = tmp
		t_near = max(t_near, t1)
		t_far = min(t_far, t2)
	if t_near > t_far or t_far < 0.0:
		return -1.0
	return max(t_near, 0.0)


## Ray-vs-sphere t parameter. Returns first positive t along the ray in
## [0, INF), or -1 if no intersection. Standard quadratic.
static func _ray_sphere_t(origin: Vector3, dir: Vector3, center: Vector3, r: float) -> float:
	var oc: Vector3 = origin - center
	var b: float = oc.dot(dir)
	var c: float = oc.dot(oc) - r * r
	var discr: float = b * b - c
	if discr < 0.0:
		return -1.0
	var sq: float = sqrt(discr)
	var t: float = -b - sq
	if t > 0.0:
		return t
	t = -b + sq
	if t > 0.0:
		return t
	return -1.0


## ADR 0006: defer level transition. Sets env._pending_level_transition to
## target name; world.gd processes this between ticks (after the current
## rule's effect chain finishes) so we don't mutate entities mid-rule.
## target = "next" → engine looks up the next level in progression.levels.
##
## Optional `fade_duration` (seconds): when present and > 0, the transition
## is delegated to GameShell which runs a 3-phase state machine:
##   1. FADING_OUT (fade_duration/2 s): overlay alpha 0→1
##   2. SWAP at midpoint: GameShell sets env._pending_level_transition so
##      World picks it up on next tick (atomicity preserved)
##   3. FADING_IN (fade_duration/2 s): overlay alpha 1→0
## Without fade_duration the original instant-swap behavior is preserved.
##
## DESTRUCTIVE — like all transition_level paths, the level swap will
## remove non-persistent entities. Effect-chain validation gate applies:
## anything queued AFTER this effect that depends on the OLD level's
## entities will be silently dropped on swap.
static func _transition_level(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var target := str(EffectResolution.value(e.get("target", "next"), ctx, env))
	if target == "":
		return
	var fade_dur := float(EffectResolution.value(e.get("fade_duration", 0.0), ctx, env))
	if fade_dur > 0.0:
		# Delegate to GameShell. It will set _pending_level_transition at
		# fade midpoint, so world.gd's existing process_pending_level_transition
		# does the actual swap on the next tick boundary.
		var color = e.get("color", "#000000")
		var buf_v = env.get("shell_event_buffer", null)
		var buf: Array
		if buf_v is Array:
			buf = buf_v
		else:
			buf = []
			env["shell_event_buffer"] = buf
		(
			buf
			. append(
				{
					"event": "transition_level_fade_request",
					"target": target,
					"fade_duration": fade_dur,
					"color": color,
				}
			)
		)
		return
	env["_pending_level_transition"] = target


## Tween the screen-fade overlay's alpha to a target value over `duration`
## seconds. GameShell owns the overlay (lives on a CanvasLayer above the
## HUD) and the per-frame lerp. duration=0 → instant.
##   {type: screen_fade, alpha: 0.8, duration: 0.3, color: "#000000"}
##
## Additive (non-destructive) — stacks fine with effects after it in a chain.
static func _screen_fade(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var alpha := float(EffectResolution.value(e.get("alpha", 1.0), ctx, env))
	var duration := float(EffectResolution.value(e.get("duration", 0.0), ctx, env))
	var color = e.get("color", "#000000")
	var buf_v = env.get("shell_event_buffer", null)
	var buf: Array
	if buf_v is Array:
		buf = buf_v
	else:
		buf = []
		env["shell_event_buffer"] = buf
	(
		buf
		. append(
			{
				"event": "screen_fade",
				"alpha": alpha,
				"duration": duration,
				"color": color,
			}
		)
	)


## Hard Godot scene swap via SceneTree.change_scene_to_file. DESTRUCTIVE —
## anything queued after this in the same effect chain is silently dropped
## when the scene reload lands at end-of-frame. See `.claude/rules/
## engine-scripts.md` § effect-chain validation gate. Pushes a screen
## event so ScreenFlow drains and performs the swap (same pattern as
## reload_scene/quit_app).
##   {type: scene_change, target: "res://scenes/title.tscn"}
##
## Target is read raw (no _value formula evaluation) — `res://...` paths
## contain `/`, `:`, and `.` which Formula.looks_like_formula treats as
## expression syntax. Resource paths are always literal.
static func _scene_change(e: Dictionary, env: Dictionary, _ctx: Dictionary) -> void:
	var target := str(e.get("target", ""))
	if target == "":
		push_warning("scene_change effect missing target (rule=%s)" % str(_ctx.get("_rule_id", "")))
		return
	_push_screen_event(env, {"event": "scene_change", "target": target})


# ============================================================
# SCREEN FLOW EFFECTS (ADR 0011)
# ============================================================
#
# Same pattern as emit_shell_event: push a record onto env.screen_event_buffer.
# ScreenFlow drains it each frame (see screen_flow.gd _drain_screen_events).
# Effects don't touch CanvasLayers directly — that's screen_flow's job.


static func _push_screen_event(env: Dictionary, record: Dictionary) -> void:
	var buf_v = env.get("screen_event_buffer", null)
	var buf: Array
	if buf_v is Array:
		buf = buf_v
	else:
		buf = []
		env["screen_event_buffer"] = buf
	buf.append(record)


## Transition to a named screen. ScreenFlow handles modal-vs-replace based
## on the target screen's spec. Special target "@previous" pops the modal
## stack (returns from settings → pause).
static func _transition_screen(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var target := str(EffectResolution.value(e.get("target", ""), ctx, env))
	if target == "":
		push_warning(
			"transition_screen effect missing target (rule=%s)" % str(ctx.get("_rule_id", ""))
		)
		return
	_push_screen_event(env, {"event": "transition_screen", "target": target})


## Quit the application. ScreenFlow calls get_tree().quit() when drained.
static func _quit_app(_e: Dictionary, env: Dictionary, _ctx: Dictionary) -> void:
	_push_screen_event(env, {"event": "quit_app"})


## Show a transient toast label (e.g. "Saved!" after save_state).
## text resolves @strings.X refs. duration in seconds.
##
## NOTE: text uses EffectResolution.value_text() (literal-or-@-only), NOT EffectResolution.value(). Display
## prose like "Debt installment paid" contains spaces, which would trip
## Formula.looks_like_formula and cause a runtime parse error. show_toast's
## text field is meant for human-readable strings, not computation. If you
## need a computed message, build it in a state_set rule first then reference
## the state via @strings.<key> resolved at HUD time.
static func _show_toast(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var text := EffectResolution.value_text(e.get("text", ""), ctx)
	var duration := float(EffectResolution.value(e.get("duration", 2.0), ctx, env))
	_push_screen_event(env, {"event": "show_toast", "text": text, "duration": duration})



## Reload the entire current Godot scene. DESTRUCTIVE — anything queued
## after this in the same effect chain is silently dropped when the scene
## reload lands at end-of-frame. See `.claude/rules/engine-scripts.md`
## § effect-chain validation gate.
##
## For "reset world without scene reload" use the future `reset_world`
## effect (task #99). For most "New Game" buttons, just `transition_screen`
## is sufficient because the world is already at initial state on scene
## load.
static func _reload_scene(e: Dictionary, env: Dictionary, _ctx: Dictionary) -> void:
	var args = e.get("args", {})
	_push_screen_event(env, {"event": "reload_scene", "args": args})


# ============================================================
# SAVE / LOAD EFFECTS (ADR 0010)
# ============================================================
#
# Both effects are DEFERRED — they set env._pending_save / env._pending_load
# (slot number). World.gd processes the pending request between ticks
# (after the current effect chain drains), same pattern as transition_level.
# This keeps save/load atomic relative to the simulation: a save captures
# a stable post-tick state, never mid-rule.


static func _save_state(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var slot := int(EffectResolution.value(e.get("slot", 0), ctx, env))
	env["_pending_save"] = slot


static func _load_state(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var slot := int(EffectResolution.value(e.get("slot", 0), ctx, env))
	env["_pending_load"] = slot


# ============================================================
# OVERLAY EFFECTS (ADR 0012)
# ============================================================
#
# Same pattern as screen events: push records into env.overlay_event_buffer.
# OverlayManager (a Node sibling of GameShell) drains each frame.


static func _push_overlay_event(env: Dictionary, record: Dictionary) -> void:
	var buf_v = env.get("overlay_event_buffer", null)
	var buf: Array
	if buf_v is Array:
		buf = buf_v
	else:
		buf = []
		env["overlay_event_buffer"] = buf
	buf.append(record)


## Show an overlay (modal text + advance condition). All fields except
## "type" are forwarded verbatim into the buffer record so OverlayManager
## sees the full spec (id, title, body, advance_action, advance_signal,
## advance_after_seconds, freeze_world, skippable, highlight_tag, etc.).
##
## Strings pass through raw (so "Press WASD to move." isn't mis-parsed as
## a formula by Formula.looks_like_formula's space/dot heuristic). @-refs
## resolve at show time via ControlFactory._resolve_text. Non-strings
## (numbers, bools) go through _value so dynamic specs from state work
## (e.g. `advance_after_seconds: world.tutorial_step + 2`).
static func _show_overlay_effect(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var record: Dictionary = {"event": "show_overlay"}
	for k in e.keys():
		if str(k) == "type":
			continue
		var v = e[k]
		if v is String:
			record[str(k)] = v
		else:
			record[str(k)] = EffectResolution.value(v, ctx, env)
	_push_overlay_event(env, record)


## Dismiss an overlay by id. Pops from the stack and fires
## overlay_advanced{id, reason: "manual"}. If the id isn't on the
## stack, no-op (idempotent).
static func _dismiss_overlay_effect(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var id := str(EffectResolution.value(e.get("id", ""), ctx, env))
	_push_overlay_event(env, {"event": "dismiss_overlay", "id": id})


# ============================================================
# SETTINGS EFFECTS (ADR 0013)
# ============================================================
#
# Thin wrappers around Godot's AudioServer + InputMap. Per ADR 0021,
# we expose the existing Godot machinery rather than reimplementing it.
# These effects fire from settings_schema.json's `apply` blocks when a
# player changes a setting.


## Set the volume of a Godot AudioServer bus (by name) to a linear
## level in [0.0, 1.0]. Linear converts to dB internally
## (Godot's AudioServer takes dB, but linear is the player-facing value).
static func _set_audio_bus_volume(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var bus_name := str(EffectResolution.value(e.get("bus", "Master"), ctx, env))
	var linear := float(EffectResolution.value(e.get("linear", 1.0), ctx, env))
	linear = clamp(linear, 0.0, 1.0)
	var bus_idx := AudioServer.get_bus_index(bus_name)
	if bus_idx < 0:
		# Bus may not exist if AudioBus autoload didn't add it (e.g. in
		# headless tests). Silent skip to keep this effect cheap-fail.
		return
	# Godot's volume is in dB; linear_to_db handles 0.0 → -inf cleanly.
	AudioServer.set_bus_volume_db(bus_idx, linear_to_db(linear))


## Remap a Godot InputMap action to a new physical key.
## Erases existing bindings for the action, then adds the new key.
## key string is parsed via OS.find_keycode_from_string.
static func _set_input_mapping(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var action := str(EffectResolution.value(e.get("action", ""), ctx, env))
	var key_str := str(EffectResolution.value(e.get("key", ""), ctx, env))
	if action == "" or key_str == "":
		return
	if not InputMap.has_action(action):
		# Action doesn't exist in this game's InputMap. Silent skip.
		return
	var keycode := OS.find_keycode_from_string(key_str)
	if keycode == KEY_NONE:
		push_warning("set_input_mapping: unknown key '%s' for action '%s'" % [key_str, action])
		return
	# Erase any existing key events on this action, keep non-key events
	# (gamepad, mouse) untouched.
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			InputMap.action_erase_event(action, ev)
	var new_ev := InputEventKey.new()
	new_ev.keycode = keycode
	InputMap.action_add_event(action, new_ev)


# ============================================================
# MULTI-ACTOR EFFECTS (ADR 0016)
# ============================================================


## Switch the active actor. DEFERRED — takes effect at next tick boundary
## (per TD condition #3). Subsequent rules in the SAME tick still see the
## old active_actor_id; world.gd processes _pending_active_actor between
## ticks (matches transition_level / save_state pattern).
static func _switch_actor(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var target := str(EffectResolution.value(e.get("target_id", e.get("target", "")), ctx, env))
	if target == "":
		push_warning("switch_actor: missing target_id (rule=%s)" % str(ctx.get("_rule_id", "")))
		return
	env["_pending_active_actor"] = target


## Synthesize input for a specific (typically non-human) actor.
## Foundation for AI policies (ADR 0018). Pushes onto the scheduler's
## input queue with the actor_id in the params dict.
static func _queue_input_for_actor(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var actor_id := str(EffectResolution.value(e.get("actor_id", ""), ctx, env))
	var action := str(EffectResolution.value(e.get("action", ""), ctx, env))
	if actor_id == "" or action == "":
		push_warning(
			(
				"queue_input_for_actor: missing actor_id or action (rule=%s)"
				% str(ctx.get("_rule_id", ""))
			)
		)
		return
	var parent_node = env.get("parent", null)
	if parent_node == null or parent_node.get("scheduler") == null:
		return
	var sched = parent_node.scheduler
	if sched.has_method("queue_input"):
		sched.queue_input(action, {"actor": actor_id, "synthesized": true})


## ADR 0010+0011 follow-up (#99): reset world state without scene reload.
## Used by "New Game" buttons after the player previously clicked Continue
## (which mutated state via load_state). Without this effect, a New Game
## chain is broken: reload_scene + transition_screen drops the transition
## (destructive chain footgun); just transition_screen leaves loaded state
## intact.
##
## Behavior (deferred to between-tick processing in world.gd):
## - Despawn all non-persistent entities (matches transition_level pattern)
## - Reset world_state to initial values from world/state.json
## - For multi-level games (game/flow.json present): reset current_level
##   to starting_level + reload that level's entities
## - For single-level games: reload entities/initial_instances
##
## Non-destructive to the effect chain: only mutates env via
## _pending_world_reset flag, processed at end of tick. Subsequent effects
## (transition_screen, etc.) fire normally.
static func _reset_world(_e: Dictionary, env: Dictionary, _ctx: Dictionary) -> void:
	env["_pending_world_reset"] = true


# ============================================================
# PARTY EFFECTS (ADR 0026)
# ============================================================
#
# Three convenience effects that compose existing primitives (relate /
# tag_add / tag_remove / state_set / unrelate) into a single declarative
# verb per author intent. Per ADR 0026, the engine ships these because
# every party game would otherwise spell out the same 6-line effect chain.
# The PartyDirector module reads the resulting tag + relation + state to
# drive per-frame leashing.


## party_join — add an NPC to the player's party.
##   {target: <npc>, leader: <player_id>}
##
## Effects:
##   1. Add `party_member` tag to target.
##   2. Create `party_member_of` relation: target → leader.
##   3. Set target.state.party_index = leader.state.party_count (next slot).
##   4. Increment leader.state.party_count by 1.
##   5. Initialize target.state.ko = 0 (so KO intercept rules read it).
##
## Idempotent on tag/relation (RelationStore dedup; tag_add no-ops on
## already-present tag) but party_index is only valid for the first call —
## a second party_join would push the count up and reassign a new slot,
## leaving the original index dangling. Authors should gate joins on
## `tags_none: ["party_member"]` to avoid double-add.
static func _party_join(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var member: Entity = EffectResolution.target(e, env, ctx)
	if member == null:
		return
	var leader_id := EffectResolution.resolve_id(e.get("leader", "player"), ctx)
	if leader_id == "":
		return
	var entities: Dictionary = env.get("entities", {})
	if not entities.has(leader_id):
		return
	var leader = entities[leader_id]
	if not (leader is Entity):
		return
	var leader_ent: Entity = leader
	# 1. Tag membership.
	member.add_tag("party_member")
	# 2. Relation: member → leader.
	var store: RelationStore = env.get("relations", null)
	if store != null:
		store.relate("party_member_of", member.instance_id, leader_id)
	# 3. + 4. Slot assignment via leader's party_count counter.
	var slot: int = int(leader_ent.get_state("party_count", 0))
	member.set_state("party_index", slot)
	leader_ent.add_state("party_count", 1)
	# 5. Initialize KO state so intercept rules can read it cleanly.
	if member.get_state("ko", null) == null:
		member.set_state("ko", 0)


## party_leave — remove an NPC from the party.
##   {target: <npc>}
##
## Effects:
##   1. Remove `party_member` tag.
##   2. Drop the `party_member_of` relation (resolved via the store —
##      authors don't pass leader explicitly).
##   3. Decrement leader's state.party_count if a relation existed.
##   4. Clear ko + party_index on the target.
##
## NOTE: this does NOT compact remaining members' party_index. If
## index 0 leaves and indices 1+2 remain, they stay at 1 and 2 — the
## director's offset table treats slots as positions, not order, so
## leaving "slot 0 empty" just means no companion stands there.
## Authors who want re-shuffling can issue party_leave + party_join
## on the remaining members.
static func _party_leave(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var member: Entity = EffectResolution.target(e, env, ctx)
	if member == null:
		return
	var store: RelationStore = env.get("relations", null)
	# 2. + 3. Drop relation; track leader for count decrement.
	var entities: Dictionary = env.get("entities", {})
	if store != null:
		var leaders: Array = store.targets("party_member_of", member.instance_id)
		for leader_id in leaders:
			store.unrelate("party_member_of", member.instance_id, str(leader_id))
			if entities.has(str(leader_id)):
				var leader = entities[str(leader_id)]
				if leader is Entity:
					(leader as Entity).add_state("party_count", -1)
	# 1. Tag.
	member.remove_tag("party_member")
	# 4. Clear member's party state.
	member.set_state("ko", 0)
	member.set_state("party_index", -1)


## party_ko — knock out a party member without removing them.
##   {target: <npc>}
##
## Effects:
##   1. Set state.ko = 1 (intercept rules check this).
##   2. Set state.hp = 1 (so subsequent damage doesn't re-fire KO logic
##      every tick — a hp=0 entity would keep matching an `hp_lte: 0`
##      query indefinitely).
##   3. Snap state.position to leader's current position (so KO'd
##      companions visibly fall next to the player).
##   4. Zero state.velocity (no drift while KO'd).
##
## Author-side: pair with a tick rule that emits `party_revival` on
## reaching a town to wake the member back up. The director listens
## for that signal and resets ko + hp.
static func _party_ko(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var member: Entity = EffectResolution.target(e, env, ctx)
	if member == null:
		return
	# 1. + 2. KO + hp pin.
	member.set_state("ko", 1)
	member.set_state("hp", 1)
	# 3. Snap to leader. Resolve leader via relation; fall back to no-op
	# if no relation (orphaned ko'd entity stays where it died).
	var store: RelationStore = env.get("relations", null)
	if store != null:
		var leaders: Array = store.targets("party_member_of", member.instance_id)
		if leaders.size() == 1:
			var entities: Dictionary = env.get("entities", {})
			var leader_id: String = str(leaders[0])
			if entities.has(leader_id) and entities[leader_id] is Entity:
				member.set_position((entities[leader_id] as Entity).get_position())
	# 4. Stop motion.
	# Use Vector3.ZERO if the member's position is 3D, Vector2.ZERO if 2D —
	# matches Entity.set_velocity's normalization expectations.
	var pos = member.get_position()
	if pos is Vector3:
		member.set_velocity(Vector3.ZERO)
	else:
		member.set_velocity(Vector2.ZERO)


# ============================================================
# BUILD_PLACE (ADR 0037)
# ============================================================
#
# Validates a candidate placement against a fixed predicate set, then
# either spawns the entity (delegating to _spawn for renderer attach +
# spatial-index registration + spawn-trigger dispatch — same lifecycle
# as any other spawn) or fires `on_invalid` with the failure reason
# bound into ctx as `failure_reason`.
#
# CRITICAL: this is the engine's 穿模-prevention gate. Every placement
# touched at runtime MUST go through here, not raw `spawn`, so that
# overlap / range / ground / boundary failures are caught BEFORE the
# new entity enters the spatial index. See ADR 0037 §"Resolution flow".
#
# Predicates are coded in build_validators.gd and are NOT extensible
# from JSON — adding a fifth predicate requires a primitive-expansion
# ADR (per ADR 0021 / 0028 operator-surface reasoning).
#
# Out-of-scope for this implementation (per task spec):
#   - Ghost-mesh PREVIEW rendering. The ADR proposes a separate
#     build_preview_widget.gd Control for cursor-driven UIs. Phase 1's
#     player Build verb uses the simpler "build immediately if valid,
#     show toast if not" UX without a per-frame ghost. Future work,
#     visual gate applies.
#   - Multi-tick construction TICKING. Engine tags the spawned entity
#     `under_construction` and seeds state.build_in_progress when
#     construction_ticks > 0; the per-tick decrement + finalize rules
#     are content (per ADR 0037 §"Multi-tick construction" — Invariant
#     #2 forbids semantic effect names like complete_construction).


## Apply each effect in a chain (Array-of-Dict). Used by build_place's
## on_success / on_invalid sub-effects. Sub-effect failures don't abort
## the chain — same semantics as a top-level effect array on a rule.
static func _apply_chain(chain, env: Dictionary, ctx: Dictionary) -> void:
	if chain == null:
		return
	if chain is Dictionary:
		# Single effect (not wrapped in an array) — accept and apply.
		apply(chain, env, ctx)
		return
	if not (chain is Array):
		return
	for sub in chain as Array:
		if sub is Dictionary:
			apply(sub, env, ctx)


## Validate placement, then spawn the blueprint via the existing _spawn
## path. Returns {placed: bool, instance_id: String, reason: String}.
##
## reason is "" on success, "no_def" if blueprint is unknown, otherwise
## the predicate name that failed (mirrors ADR test plan).
static func _build_place(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var defs: Dictionary = env.get("defs", {})
	var blueprint := str(EffectResolution.value(e.get("blueprint", ""), ctx, env))
	if not defs.has(blueprint):
		EngineError.raise(
			env,
			EngineError.EFFECT_BUILD_PLACE_NO_DEF,
			"build_place: no def '%s'" % blueprint,
			{
				"rule_id": ctx.get("_rule_id", ""),
				"field": "effect.blueprint",
				"got": blueprint,
				"known_defs": defs.keys()
			},
			(
				"Add a definition with id '%s' to entities.json, or fix the build_place blueprint."
				% blueprint
			)
		)
		# Per ADR 0037 test_no_def_error: neither on_success nor on_invalid
		# fires when the def is missing — the structural error short-circuits.
		return {"placed": false, "reason": "no_def", "instance_id": ""}

	var def: Dictionary = defs[blueprint]
	var pos = EffectResolution.position(e.get("position", [0, 0, 0]), env, ctx)
	# Coerce to Vector3 — predicates assume 3D.
	var pos3: Vector3 = Vec3Util.from_world_pos(pos)
	var yaw := float(EffectResolution.value(e.get("yaw", 0.0), ctx, env))
	# ADR 0038: snap position + yaw to grid BEFORE running validation
	# predicates. Means `no_overlap` checks the snapped cell, so authors
	# can pass continuous cursor coords and the engine guarantees the
	# placed entity lands on a grid cell. No-op when grid disabled.
	if GridSnap.should_snap(def, env):
		pos3 = GridSnap.snap_position(pos3, env)
		yaw = GridSnap.snap_yaw(yaw, env)
	var owner_binding := str(e.get("owner", "self"))
	var max_range := float(EffectResolution.value(e.get("max_range", 5.0), ctx, env))
	var validate = e.get("validate", [])
	if not (validate is Array):
		validate = []

	# Stash per-effect predicate options so build_validators can read them
	# (e.g. ground_check_radius). Kept on env so we don't change the
	# predicate signature for one-off knobs.
	var prior_opts = env.get("_build_place_options", null)
	env["_build_place_options"] = {
		"ground_check_radius": float(e.get("ground_check_radius", 0.5)),
		"ground_y_tolerance": float(e.get("ground_y_tolerance", 0.5)),
	}

	# Run predicates left-to-right; first failure short-circuits and the
	# `failure_reason` propagates into the on_invalid context.
	var failure_reason: String = ""
	for pname in validate:
		var pname_s := str(pname)
		var result: Dictionary = BuildValidators.check(
			pname_s, def, pos3, yaw, owner_binding, max_range, env, ctx
		)
		if not bool(result.get("ok", false)):
			failure_reason = str(result.get("reason", pname_s))
			break

	# Restore prior options (or clear if absent) so the env is clean.
	if prior_opts == null:
		env.erase("_build_place_options")
	else:
		env["_build_place_options"] = prior_opts

	var sub_ctx: Dictionary = ctx.duplicate()
	if failure_reason != "":
		# Surface failure through env.error_buffer for qa-tester; severity
		# warning so authors see the issue without aborting headless runs.
		(
			EngineError
			. raise(
				env,
				EngineError.EFFECT_BUILD_PLACE_INVALID,
				(
					"build_place: predicate '%s' rejected placement of '%s' at %s"
					% [failure_reason, blueprint, str(pos3)]
				),
				{
					"rule_id": ctx.get("_rule_id", ""),
					"field": "effect.validate",
					"predicate": failure_reason,
					"blueprint": blueprint,
					"position": str(pos3)
				},
				"This is a normal validation failure — wire on_invalid to refund cost / show a toast / clear build mode.",
				"warning"
			)
		)
		sub_ctx["failure_reason"] = failure_reason
		_apply_chain(e.get("on_invalid", []), env, sub_ctx)
		return {"placed": false, "reason": failure_reason, "instance_id": ""}

	# Validation passed → delegate to _spawn for renderer attach + spatial
	# index registration + spawn-trigger dispatch (same lifecycle as any
	# other spawn).
	var spawn_overrides: Dictionary = {"state": {"yaw": yaw}}
	var construction_ticks := int(EffectResolution.value(e.get("construction_ticks", 0), ctx, env))
	if construction_ticks > 0:
		(spawn_overrides["state"] as Dictionary)["build_in_progress"] = construction_ticks
		(spawn_overrides["state"] as Dictionary)["build_progress_target"] = construction_ticks
		spawn_overrides["tags"] = ["under_construction"]
	var spawn_effect: Dictionary = {
		"type": "spawn",
		"template": blueprint,
		"position": pos3,
		"overrides": spawn_overrides,
	}
	var spawn_result: Dictionary = _spawn(spawn_effect, env, ctx)
	var inst_id: String = str(spawn_result.get("spawned_id", ""))

	# Fire on_success chain. Note: spawn-trigger rules already fired during
	# _spawn's dispatch_lifecycle("spawn", inst_id) call — on_success is the
	# author's hook for build-specific cleanup (e.g. clear build_blueprint
	# state, decrement resource cost, emit a build-specific signal).
	sub_ctx["spawned_id"] = inst_id
	sub_ctx["build_id"] = inst_id
	_apply_chain(e.get("on_success", []), env, sub_ctx)
	return {"placed": true, "reason": "", "instance_id": inst_id}


# ============================================================
# CLASS / OCCUPATION (ADR 0030)
# ============================================================


## switch_class — atomic occupation swap on a player-actor entity.
##
## Effect dict shape:
##   {
##     "type": "switch_class",
##     "target": "self",           # entity-binding key OR literal id;
##                                 # default "self".
##     "to_class": "warrior",      # class id (string OR formula resolving
##                                 # to a string).
##     "cooldown_days": 1,         # optional, default 1. Set 0 to bypass.
##     "on_failure_signal": "..."  # optional. If set AND validation fails,
##                                 # emit this signal with reason payload
##                                 # so game-rules can surface a toast.
##   }
##
## Returns {ok, reason, from, to, instance_id} for the scheduler to
## record. Per ADR 0030 §effect-chain ordering, switch_class is
## NON-DESTRUCTIVE — composes safely in any chain position.
##
## ClassManager (sibling Node under World) hosts the registered class
## defs and the validation logic. effect_apply locates it via the env's
## parent reference. If no ClassManager is mounted (test harnesses
## without a SceneTree, OR demos that never registered any classes),
## the effect logs a warning and no-ops.
static func _switch_class(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	# Resolve target — same convention as EffectResolution.target() but we need the id
	# string, not the Entity, so we can pass it to ClassManager.switch_class.
	var target_key := str(e.get("target", "self"))
	var target_id := str(ctx.get(target_key, target_key))
	var to_class := str(EffectResolution.value(e.get("to_class", ""), ctx, env))
	var cooldown_days: int = int(EffectResolution.value(e.get("cooldown_days", 1), ctx, env))
	# Locate ClassManager. World is env.parent; ClassManager is a
	# named sibling under it.
	var cm: Node = null
	var parent_node = env.get("parent", null)
	if parent_node is Node:
		cm = (parent_node as Node).get_node_or_null("ClassManager")
	if cm == null or not cm.has_method("switch_class"):
		EngineError.raise(
			env,
			EngineError.CLASS_SWITCH_NO_DEF,
			"switch_class: no ClassManager mounted under World",
			{"rule_id": ctx.get("_rule_id", ""), "target": target_id, "to_class": to_class},
			"Add ClassManager Node sibling under World in play.tscn (per ADR 0030).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager", "from": "", "to": to_class}
	var result: Dictionary = cm.call("switch_class", env, target_id, to_class, cooldown_days)
	# On failure, optionally emit on_failure_signal so game-rules can react.
	if not bool(result.get("ok", false)):
		var fail_sig := str(e.get("on_failure_signal", ""))
		if fail_sig != "":
			var buf = env.get("signal_buffer", null)
			if buf is Array:
				(
					(buf as Array)
					. append(
						{
							"name": fail_sig,
							"payload":
							{
								"target": target_id,
								"to_class": to_class,
								"reason": str(result.get("reason", "")),
								"from": str(result.get("from", "")),
							}
						}
					)
				)
	return result


# ============================================================
# FACTION (ADR 0032)
# ============================================================
#
# Four declarative verbs for faction-state mutation:
#   - declare_war       {from, to}
#   - sign_treaty       {from, to, new_stance="neutral"}
#   - propose_alliance  {from, to}
#   - swear_loyalty     {target, faction, delta=10 OR value=int}
#
# All four are NON-DESTRUCTIVE (compose safely in any chain position) and
# atomic on validation failure (unknown faction id leaves state untouched,
# raises FACTION_NO_DEF). FactionDirector (sibling Node under World) hosts
# the registered faction defs + relationship state. effect_apply locates
# it via env.parent.


## Locate FactionDirector. World is env.parent; FactionDirector is a
## named sibling under it. Returns null if not mounted (test harnesses
## without a SceneTree, OR demos that never registered any factions).
static func _faction_director(env: Dictionary) -> Node:
	var parent_node = env.get("parent", null)
	if parent_node is Node:
		var n = (parent_node as Node).get_node_or_null("FactionDirector")
		if n != null:
			return n
	return null


## Resolve a faction id reference (for from/to/faction fields).
## Same policy as _resolve_id: context binding first, literal fallback.
## Strings beginning with formula-start chars get evaluated through the
## formula context (so `"world.active_faction"` resolves to the bound
## faction id). Otherwise treated as a literal id.
static func _resolve_faction_id(v, ctx: Dictionary, env: Dictionary) -> String:
	if v == null:
		return ""
	if v is String:
		var s := str(v)
		if ctx.has(s):
			return str(ctx[s])
		if Formula.looks_like_formula(s):
			var fctx := EffectResolution.formula_context(ctx, env)
			if ctx.has("_rule_id"):
				fctx["_rule_id"] = ctx["_rule_id"]
			var resolved = Formula.evaluate(s, fctx, env)
			return str(resolved) if resolved != null else ""
		return s
	return str(v)


static func _declare_war(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var fd := _faction_director(env)
	if fd == null or not fd.has_method("apply_declare_war"):
		EngineError.raise(
			env,
			EngineError.FACTION_NO_DEF,
			"declare_war: no FactionDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add FactionDirector Node sibling under World in play.tscn (per ADR 0032).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager"}
	var from_id := _resolve_faction_id(e.get("from", ""), ctx, env)
	var to_id := _resolve_faction_id(e.get("to", ""), ctx, env)
	return fd.call("apply_declare_war", env, from_id, to_id)


static func _sign_treaty(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var fd := _faction_director(env)
	if fd == null or not fd.has_method("apply_sign_treaty"):
		EngineError.raise(
			env,
			EngineError.FACTION_NO_DEF,
			"sign_treaty: no FactionDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add FactionDirector Node sibling under World in play.tscn (per ADR 0032).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager"}
	var from_id := _resolve_faction_id(e.get("from", ""), ctx, env)
	var to_id := _resolve_faction_id(e.get("to", ""), ctx, env)
	# Default new_stance is "neutral" — matches FactionDirector.apply_sign_treaty.
	var new_stance := str(EffectResolution.value(e.get("new_stance", "neutral"), ctx, env))
	return fd.call("apply_sign_treaty", env, from_id, to_id, new_stance)


static func _propose_alliance(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var fd := _faction_director(env)
	if fd == null or not fd.has_method("apply_propose_alliance"):
		EngineError.raise(
			env,
			EngineError.FACTION_NO_DEF,
			"propose_alliance: no FactionDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add FactionDirector Node sibling under World in play.tscn (per ADR 0032).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager"}
	var from_id := _resolve_faction_id(e.get("from", ""), ctx, env)
	var to_id := _resolve_faction_id(e.get("to", ""), ctx, env)
	return fd.call("apply_propose_alliance", env, from_id, to_id)


## swear_loyalty — mutate target NPC's state.faction_loyalty[<faction>].
##   {target: <entity_binding|id>, faction: <id>, amount: <int>}
##     OR {target, faction, value: <int>}
##
## `amount` is the delta to add (default +10). `value` overrides to set
## directly. Loyalty values clamp 0-100. Atomic on unknown faction.
static func _swear_loyalty(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var fd := _faction_director(env)
	if fd == null or not fd.has_method("apply_swear_loyalty"):
		EngineError.raise(
			env,
			EngineError.FACTION_NO_DEF,
			"swear_loyalty: no FactionDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add FactionDirector Node sibling under World in play.tscn (per ADR 0032).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager"}
	# Resolve target — same convention as EffectResolution.target() but we need the id
	# string to pass to FactionDirector.apply_swear_loyalty.
	var target_key := str(e.get("target", "self"))
	var target_id := str(ctx.get(target_key, target_key))
	var faction_id := _resolve_faction_id(e.get("faction", ""), ctx, env)
	var opts: Dictionary = {}
	# Author convention: `amount` for the delta-add (mirrors state_add). The
	# FactionDirector internally uses `delta` for symmetry with its other
	# helpers, so we translate here.
	if e.has("amount"):
		opts["delta"] = int(EffectResolution.value(e.get("amount"), ctx, env))
	elif e.has("delta"):
		opts["delta"] = int(EffectResolution.value(e.get("delta"), ctx, env))
	if e.has("value"):
		opts["value"] = int(EffectResolution.value(e.get("value"), ctx, env))
	return fd.call("apply_swear_loyalty", env, target_id, faction_id, opts)


# ============================================================
# TECH-TREE (ADR 0033)
# ============================================================
#
# Three new vocabulary items: try_discover_tech / learn_from_master /
# pass_to_apprentice. Each delegates to the TechTreeDirector node mounted
# as a sibling of World (resolved via env.parent.get_node_or_null). When
# no director is mounted (test harnesses without a SceneTree, OR demos
# that ship no tech_trees.json), the effect logs a warning and no-ops.
#
# Per ADR 0033 §3 these are NON-DESTRUCTIVE effects — they mutate
# entity.state.known_techs and emit signals; they don't tear down scene
# state, so they compose safely in any chain position.


static func _tech_tree_director(env: Dictionary) -> Node:
	var parent_node = env.get("parent", null)
	if parent_node is Node:
		return (parent_node as Node).get_node_or_null("TechTreeDirector")
	return null


## try_discover_tech — roll discovery_chance for one or more eligible
## nodes on the target's tree.
##
## Effect dict shape:
##   {
##     "type": "try_discover_tech",
##     "target": "self",                  # entity-binding key OR literal id
##     "tree":   "smithing",              # tree id (string OR formula)
##     "max_rolls_per_call": 1            # default 1 (safety cap)
##   }
##
## Returns {ok, awarded, target, tree}. awarded="" on no-op. Per ADR
## 0033 §3.1, only the FIRST roll that hits awards a node; subsequent
## eligible candidates this call are silently skipped (rolls again next
## tick).
static func _try_discover_tech(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var ttd := _tech_tree_director(env)
	if ttd == null or not ttd.has_method("try_discover_tech"):
		EngineError.raise(
			env,
			EngineError.TECH_NO_TREE,
			"try_discover_tech: no TechTreeDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add TechTreeDirector Node sibling under World in play.tscn (per ADR 0033).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager"}
	var target_key := str(e.get("target", "self"))
	var target_id := str(ctx.get(target_key, target_key))
	var tree_id := str(EffectResolution.value(e.get("tree", ""), ctx, env))
	var max_rolls: int = int(EffectResolution.value(e.get("max_rolls_per_call", 1), ctx, env))
	var awarded: String = ttd.call("try_discover_tech", env, target_id, tree_id, max_rolls)
	return {
		"ok": awarded != "",
		"awarded": awarded,
		"target": target_id,
		"tree": tree_id,
	}


## learn_from_master — transfer one node from master to apprentice via
## the named relation (default party_member_of, ADR 0026).
##
## Effect dict shape:
##   {
##     "type": "learn_from_master",
##     "target": "self",                  # apprentice entity-binding|id
##     "tree":   "smithing",              # optional; "" = any tree
##     "master_via_relation": "party_member_of",  # ADR 0026 default
##     "master_id": ""                    # optional explicit override
##     "max_per_call": 1                  # default 1
##   }
##
## Returns {ok, awarded, target, tree, master_id}. Per ADR 0033 §3.2,
## missing master = graceful no-op (no error, no signal).
static func _learn_from_master(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var ttd := _tech_tree_director(env)
	if ttd == null or not ttd.has_method("learn_from_master"):
		EngineError.raise(
			env,
			EngineError.TECH_NO_TREE,
			"learn_from_master: no TechTreeDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add TechTreeDirector Node sibling under World in play.tscn (per ADR 0033).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager"}
	var target_key := str(e.get("target", "self"))
	var apprentice_id := str(ctx.get(target_key, target_key))
	var tree_id := str(EffectResolution.value(e.get("tree", ""), ctx, env))
	var relation := str(e.get("master_via_relation", "party_member_of"))
	# Optional explicit master override (rare — for test harnesses or
	# rules that already have a master id in context).
	var master_id := ""
	if e.has("master_id"):
		master_id = EffectResolution.resolve_id(e.get("master_id"), ctx)
	var max_per_call: int = int(EffectResolution.value(e.get("max_per_call", 1), ctx, env))
	var awarded: String = ttd.call(
		"learn_from_master", env, apprentice_id, tree_id, master_id, relation, max_per_call
	)
	return {
		"ok": awarded != "",
		"awarded": awarded,
		"target": apprentice_id,
		"tree": tree_id,
		"master_id": master_id,
	}


## pass_to_apprentice — broadcast: master fires from its own perspective,
## director resolves all apprentices via inverse relation and runs
## learn_from_master per apprentice.
##
## Effect dict shape:
##   {
##     "type": "pass_to_apprentice",
##     "target": "self",                  # master entity-binding|id
##     "tree":   "smithing",              # optional; "" = any tree
##     "apprentice_via_relation": "party_member_of",
##     "max_apprentices_per_call": 4,
##     "max_per_apprentice": 1
##   }
##
## Returns {ok, awarded_count, target, tree}.
static func _pass_to_apprentice(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var ttd := _tech_tree_director(env)
	if ttd == null or not ttd.has_method("pass_to_apprentice"):
		EngineError.raise(
			env,
			EngineError.TECH_NO_TREE,
			"pass_to_apprentice: no TechTreeDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add TechTreeDirector Node sibling under World in play.tscn (per ADR 0033).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager"}
	var target_key := str(e.get("target", "self"))
	var master_id := str(ctx.get(target_key, target_key))
	var tree_id := str(EffectResolution.value(e.get("tree", ""), ctx, env))
	var relation := str(e.get("apprentice_via_relation", "party_member_of"))
	var max_apprentices: int = int(EffectResolution.value(e.get("max_apprentices_per_call", 4), ctx, env))
	var max_per: int = int(EffectResolution.value(e.get("max_per_apprentice", 1), ctx, env))
	var n: int = int(
		ttd.call("pass_to_apprentice", env, master_id, tree_id, relation, max_apprentices, max_per)
	)
	return {
		"ok": n > 0,
		"awarded_count": n,
		"target": master_id,
		"tree": tree_id,
	}


# ============================================================
# DYNASTY (ADR 0034)
# ============================================================
#
# Four declarative store-mover verbs:
#   - transfer_inventory   {from, to}
#   - transfer_reputation  {from, to}
#   - transfer_techs       {from, to, filter="core_only"}
#   - transition_player_to {target}
#
# Each delegates to the DynastyDirector node mounted as a sibling of
# World (resolved via env.parent.get_node_or_null). When no director
# is mounted (test harnesses without a SceneTree, OR demos that ship
# no dynasty content), the effect logs a warning and no-ops.
#
# Per ADR 0034 §"New effects" these are GENERIC store-movers, not
# semantic verbs. The same effects are reusable for non-dynasty
# games (NG+ roguelike carry-over, factory subsidiary spawn,
# corporate succession sim). Per ADR 0034 §"Atomic transition",
# the four effects are non-destructive — they mutate per-entity
# state stores; they don't tear down scene state, so they compose
# safely in any chain position.


static func _dynasty_director(env: Dictionary) -> Node:
	var parent_node = env.get("parent", null)
	if parent_node is Node:
		return (parent_node as Node).get_node_or_null("DynastyDirector")
	return null


## transfer_inventory — move source.state.inventory → target.state.inventory.
## Append-then-clear-source semantics. Returns {ok, count, from, to}.
##
## Effect dict shape:
##   {"type": "transfer_inventory", "from": <entity_binding>, "to": <entity_binding>}
##
## `from` and `to` resolve via _resolve_id (context binding first,
## literal fallback). Either side missing = warning + no-op.
static func _transfer_inventory(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var dd := _dynasty_director(env)
	if dd == null or not dd.has_method("transfer_inventory"):
		EngineError.raise(
			env,
			EngineError.DYNASTY_NO_HEIR,
			"transfer_inventory: no DynastyDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add DynastyDirector Node sibling under World in play.tscn (per ADR 0034).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager", "count": 0}
	var from_id := EffectResolution.resolve_id(e.get("from", ""), ctx)
	var to_id := EffectResolution.resolve_id(e.get("to", ""), ctx)
	var n: int = int(dd.call("transfer_inventory", env, from_id, to_id))
	return {"ok": n > 0, "count": n, "from": from_id, "to": to_id}


## transfer_reputation — move source.state.reputation → target.state.reputation.
## Replace-merge with max() for overlapping faction keys. Source's
## reputation is cleared after transfer. Returns {ok, count, from, to}.
##
## Effect dict shape:
##   {"type": "transfer_reputation", "from": <entity_binding>, "to": <entity_binding>}
static func _transfer_reputation(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var dd := _dynasty_director(env)
	if dd == null or not dd.has_method("transfer_reputation"):
		EngineError.raise(
			env,
			EngineError.DYNASTY_NO_HEIR,
			"transfer_reputation: no DynastyDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add DynastyDirector Node sibling under World in play.tscn (per ADR 0034).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager", "count": 0}
	var from_id := EffectResolution.resolve_id(e.get("from", ""), ctx)
	var to_id := EffectResolution.resolve_id(e.get("to", ""), ctx)
	var n: int = int(dd.call("transfer_reputation", env, from_id, to_id))
	return {"ok": n > 0, "count": n, "from": from_id, "to": to_id}


## transfer_techs — copy filtered subset of source.known_techs → heir.known_techs.
## Filter: "core_only" (default; uses ADR 0033 tech_tree.core flag) or "all".
## Source's known_techs preserved (techs are knowledge, not items).
## Returns {ok, transferred (Array), from, to, filter}.
##
## Effect dict shape:
##   {"type": "transfer_techs", "from": <entity_binding>, "to": <entity_binding>,
##    "filter": "core_only"}
static func _transfer_techs(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var dd := _dynasty_director(env)
	if dd == null or not dd.has_method("transfer_techs"):
		EngineError.raise(
			env,
			EngineError.DYNASTY_NO_HEIR,
			"transfer_techs: no DynastyDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add DynastyDirector Node sibling under World in play.tscn (per ADR 0034).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager", "transferred": []}
	var from_id := EffectResolution.resolve_id(e.get("from", ""), ctx)
	var to_id := EffectResolution.resolve_id(e.get("to", ""), ctx)
	var filter := str(EffectResolution.value(e.get("filter", "core_only"), ctx, env))
	var transferred: Array = dd.call("transfer_techs", env, from_id, to_id, filter)
	return {
		"ok": not transferred.is_empty(),
		"transferred": transferred,
		"from": from_id,
		"to": to_id,
		"filter": filter,
	}


## transition_player_to — swap which entity is the active actor.
## Composes ADR 0016's switch_actor: looks up ActorManager via
## env.parent.actor_manager and calls set_active(new_actor_id).
## Falls back to setting state.is_player=1 on the entity when no
## ActorManager is mounted (test harness path).
##
## Returns {ok, target}.
##
## Effect dict shape:
##   {"type": "transition_player_to", "target": <entity_binding|actor_id>}
##
## Note: unlike ADR 0016's switch_actor (which defers to next tick
## via env._pending_active_actor), this effect applies immediately.
## ADR 0034 §"Atomic transition" requires all succession transfers
## (inventory + reputation + techs + actor swap) to land within the
## same effect chain so save/load mid-transition is structurally
## impossible.
static func _transition_player_to(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
	var dd := _dynasty_director(env)
	if dd == null or not dd.has_method("transition_player_to"):
		EngineError.raise(
			env,
			EngineError.DYNASTY_NO_HEIR,
			"transition_player_to: no DynastyDirector mounted under World",
			{"rule_id": ctx.get("_rule_id", "")},
			"Add DynastyDirector Node sibling under World in play.tscn (per ADR 0034).",
			"warning"
		)
		return {"ok": false, "reason": "no_manager", "target": ""}
	var target_id := EffectResolution.resolve_id(e.get("target", ""), ctx)
	if target_id == "":
		# Some authors put the target in `target_id` (mirroring switch_actor).
		target_id = str(EffectResolution.value(e.get("target_id", ""), ctx, env))
	var ok: bool = bool(dd.call("transition_player_to", env, target_id))
	return {"ok": ok, "target": target_id}
