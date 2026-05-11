extends RefCounted
class_name BuildValidators

## ADR 0037 — Validation predicates for the `build_place` effect.
##
## Predicates are FIXED ENGINE VOCABULARY — adding a fifth predicate
## requires another ADR (per ADR 0021 / ADR 0028 operator-surface
## reasoning). The v1 set is:
##
##   no_overlap        — blueprint AABB must not intersect any existing
##                       blocks_motion entity at (position + yaw).
##   ground_buildable  — a `ground_buildable` (or `ground` / `ground_tile`)
##                       entity must exist within ground_check_radius of
##                       the base position. Authors place ground tiles
##                       with one of these tags so the predicate can find
##                       them.
##   owner_in_range    — the rule's source/owner entity must be within
##                       `max_range` (planar distance) of the build site.
##   boundary_check    — position must lie within scene.bounds (read from
##                       env.scene_bounds). Bounds may be absent — see the
##                       per-predicate doc for the policy.
##
## Each predicate returns a small dict `{ok: bool, reason: String}`.
## On failure `reason` is the predicate name (matches ADR test plan
## expectations: "no_overlap", "ground_buildable", ...). The
## reason string flows into `on_invalid`'s context as `failure_reason`
## so authors can do `show_toast text="Cannot build here: {failure_reason}"`.
##
## Yaw-rotated AABBs are handled by axis-aligned-enclosing approximation
## (v1 — slightly conservative; rare false-fail at oblique yaws). See
## ADR 0037 Alternative E for the SAT path.

# ============================================================
# DISPATCH
# ============================================================

## Run a single named predicate. Returns {ok: bool, reason: String}.
## Unknown names produce a warning + ok=false (predicate vocabulary is
## fixed; misspellings should be loud).
static func check(name: String, def: Dictionary, pos: Vector3, yaw: float,
				  owner_binding: String, max_range: float,
				  env: Dictionary, ctx: Dictionary) -> Dictionary:
	match name:
		"no_overlap":
			return _no_overlap(def, pos, yaw, env)
		"ground_buildable":
			return _ground_buildable(pos, env)
		"owner_in_range":
			return _owner_in_range(owner_binding, pos, max_range, env, ctx)
		"boundary_check":
			return _boundary_check(pos, env)
		_:
			push_warning("build_place: unknown predicate '%s' (known: no_overlap, ground_buildable, owner_in_range, boundary_check)" % name)
			return {"ok": false, "reason": name}


# ============================================================
# PREDICATES
# ============================================================

## Sweep the spatial_index for `blocks_motion` entities whose AABB overlaps
## the candidate placement's AABB. Uses ADR 0004 / 0007 collision substrate
## (same data the motion integrator reads). See `_aabb_overlap_xz`.
static func _no_overlap(def: Dictionary, pos: Vector3, yaw: float, env: Dictionary) -> Dictionary:
	var our_aabb := _build_world_aabb(def, pos, yaw)
	# If the def has no aabb_extents, treat as no-overlap (a flag entity etc).
	if our_aabb.is_empty():
		return {"ok": true, "reason": ""}
	var sx = env.get("spatial_index", null)
	var entities: Dictionary = env.get("entities", {})
	# Half-extent + a small slop so neighbouring cells aren't missed when our
	# AABB straddles a cell boundary.
	var planar := Vector2(pos.x, pos.z)
	var max_radius := _aabb_xz_radius(our_aabb) + 4.0
	var candidate_ids: Array = []
	if sx != null and sx.has_method("query_radius_ids"):
		candidate_ids = sx.query_radius_ids(planar, max_radius)
	else:
		# Fallback: enumerate all entities. Tests sometimes don't wire a
		# spatial_index — graceful degradation lets the predicate still run.
		for k in entities.keys():
			candidate_ids.append(k)
	for cid in candidate_ids:
		var ent = entities.get(cid, null)
		if ent == null or not (ent is Entity): continue
		var ent_e: Entity = ent
		if not ent_e.has_tag("blocks_motion"): continue
		var other_aabb := _entity_world_aabb(ent_e)
		if other_aabb.is_empty(): continue
		if _aabb_overlap_3d(our_aabb, other_aabb):
			return {"ok": false, "reason": "no_overlap"}
	return {"ok": true, "reason": ""}


## Find a ground tile at (or near) the build position. Accepts ANY of:
##   tag "ground_buildable" (preferred; ADR 0037 canonical)
##   tag "ground"           (back-compat with existing demo content)
##   tag "ground_tile"      (back-compat; some demos use this)
##
## Per-effect overrides (read from env._build_place_options if set by the
## dispatch layer): ground_check_radius (default 0.5m),
## ground_y_tolerance (default 0.5m).
static func _ground_buildable(pos: Vector3, env: Dictionary) -> Dictionary:
	var opts: Dictionary = env.get("_build_place_options", {})
	var radius := float(opts.get("ground_check_radius", 0.5))
	var y_tol := float(opts.get("ground_y_tolerance", 0.5))
	var sx = env.get("spatial_index", null)
	var entities: Dictionary = env.get("entities", {})
	var planar := Vector2(pos.x, pos.z)
	var ids: Array = []
	if sx != null and sx.has_method("query_radius_ids"):
		ids = sx.query_radius_ids(planar, radius)
	else:
		for k in entities.keys():
			ids.append(k)
	for cid in ids:
		var ent = entities.get(cid, null)
		if ent == null or not (ent is Entity): continue
		var ent_e: Entity = ent
		if not (ent_e.has_tag("ground_buildable") or ent_e.has_tag("ground") or ent_e.has_tag("ground_tile")):
			continue
		# Y-tolerance check: ground tile's Y must be near the build's Y.
		var ent_pos = ent_e.get_position()
		var ent_y := 0.0
		if ent_pos is Vector3:
			ent_y = (ent_pos as Vector3).y
		# Vector2-positioned ground tiles have implicit y=0; pos.y must also be ~0.
		if absf(ent_y - pos.y) > y_tol: continue
		# Planar distance check. Spatial query already filters by radius,
		# but cell-buckets overestimate; verify exact planar distance.
		if (ent_e.get_planar_position()).distance_to(planar) <= radius:
			return {"ok": true, "reason": ""}
	return {"ok": false, "reason": "ground_buildable"}


## Look up the owner entity by context binding (default "self") and verify
## planar distance to the build position is ≤ max_range. If the binding
## resolves to nothing, the predicate fails with a structured error so
## authors can debug "why does build always fail."
static func _owner_in_range(owner_binding: String, pos: Vector3, max_range: float,
							 env: Dictionary, ctx: Dictionary) -> Dictionary:
	if owner_binding == "":
		owner_binding = "self"
	# Resolve via context. ctx["self"] is an entity id (string), so look up.
	var ent_id := str(ctx.get(owner_binding, owner_binding))
	var entities: Dictionary = env.get("entities", {})
	if not entities.has(ent_id) or not (entities[ent_id] is Entity):
		EngineError.raise(env, EngineError.EFFECT_BUILD_PLACE_NO_SOURCE,
			"build_place: owner_in_range predicate found no source entity for binding '%s'" % owner_binding,
			{"rule_id": ctx.get("_rule_id", ""), "field": "effect.owner",
			 "got": owner_binding, "resolved_id": ent_id},
			"Make sure the rule binds 'self' (or your `owner` value) to an entity. For input rules, the player is auto-bound to 'self' via the trigger query.",
			"warning")
		return {"ok": false, "reason": "owner_in_range"}
	var owner_ent: Entity = entities[ent_id]
	var owner_pos := owner_ent.get_planar_position()
	var dist := owner_pos.distance_to(Vector2(pos.x, pos.z))
	if dist <= max_range:
		return {"ok": true, "reason": ""}
	return {"ok": false, "reason": "owner_in_range"}


## Position must lie within scene.bounds (per ADR 0011 scene.json bounds).
##
## Bounds source: env.scene_bounds (Dictionary with optional `min` /
## `max` arrays — accepts [x,y] or [x,y,z]). When env has no bounds the
## predicate PASSES with a warning — the alternative would be to silently
## block every build in tests + demos that don't set bounds.
static func _boundary_check(pos: Vector3, env: Dictionary) -> Dictionary:
	var bounds = env.get("scene_bounds", null)
	if bounds == null or not (bounds is Dictionary):
		# ADR-acceptable behaviour — no bounds → predicate is effectively a
		# no-op. Authors who want strict bounds set scene_bounds in their
		# scene.json (engine wires it in).
		return {"ok": true, "reason": ""}
	var bd: Dictionary = bounds
	var minv = bd.get("min", null)
	var maxv = bd.get("max", null)
	if minv == null or maxv == null:
		return {"ok": true, "reason": ""}
	var min_a: Array = minv as Array if minv is Array else []
	var max_a: Array = maxv as Array if maxv is Array else []
	# Determine X / Z bound indices. `min`/`max` may be [x,y] (2D top-down,
	# y treated as z) or [x,y,z] (3D world-space).
	var min_x: float = -INF
	var max_x: float = INF
	var min_z: float = -INF
	var max_z: float = INF
	if min_a.size() >= 2 and max_a.size() >= 2:
		min_x = float(min_a[0]); max_x = float(max_a[0])
		# 2D: index 1 is the Y-axis which is renderer-Z; 3D: index 2.
		var idx_z := 2 if min_a.size() >= 3 else 1
		min_z = float(min_a[idx_z]); max_z = float(max_a[idx_z])
	if pos.x < min_x or pos.x > max_x or pos.z < min_z or pos.z > max_z:
		return {"ok": false, "reason": "boundary_check"}
	return {"ok": true, "reason": ""}


# ============================================================
# AABB MATH HELPERS
# ============================================================

## Build the world-space AABB of a candidate placement.
## Reads the def's `properties.aabb_extents` (half-extents on each axis,
## per ADR 0004) and `properties.aabb_offset` (optional center offset).
## Returns {} when the def has no aabb_extents (caller treats as
## "non-blocking, predicate passes").
static func _build_world_aabb(def: Dictionary, pos: Vector3, yaw: float) -> Dictionary:
	var props: Dictionary = (def.get("properties", {}) as Dictionary)
	var ext_v = props.get("aabb_extents", null)
	if ext_v == null:
		return {}
	var ext: Vector3 = _to_vec3(ext_v)
	var offv: Vector3 = _to_vec3(props.get("aabb_offset", [0, 0, 0]))
	# Yaw rotation: rotate the offset around Y, then take the
	# axis-aligned-enclosing extents of the rotated box (v1 conservative;
	# SAT is future ADR per ADR 0037 alternative E).
	var rotated_off := _rotate_y(offv, yaw)
	var enclosing := _yaw_enclosing_extents(ext, yaw)
	var center := pos + rotated_off
	return {
		"minx": center.x - enclosing.x, "maxx": center.x + enclosing.x,
		"miny": center.y - enclosing.y, "maxy": center.y + enclosing.y,
		"minz": center.z - enclosing.z, "maxz": center.z + enclosing.z,
	}


## World AABB for an existing Entity. Mirrors the merging logic in
## effect_apply._collect_blockers_from_env so the no_overlap predicate
## sees the same world the motion integrator does.
## Yaw on existing entities is read from state.yaw (defaults 0).
static func _entity_world_aabb(ent: Entity) -> Dictionary:
	var ext_v = ent.get_property("aabb_extents", null)
	if ext_v == null:
		return {}
	var ext: Vector3 = _to_vec3(ext_v)
	var offv: Vector3 = _to_vec3(ent.get_property("aabb_offset", [0, 0, 0]))
	var pos = ent.get_position()
	var pos_v: Vector3 = Vector3.ZERO
	if pos is Vector3:
		pos_v = pos
	elif pos is Vector2:
		pos_v = Vector3(pos.x, 0, pos.y)
	var yaw := float(ent.get_state("yaw", 0.0))
	var rotated_off := _rotate_y(offv, yaw)
	var enclosing := _yaw_enclosing_extents(ext, yaw)
	var center := pos_v + rotated_off
	return {
		"minx": center.x - enclosing.x, "maxx": center.x + enclosing.x,
		"miny": center.y - enclosing.y, "maxy": center.y + enclosing.y,
		"minz": center.z - enclosing.z, "maxz": center.z + enclosing.z,
	}


## Standard 3D AABB-vs-AABB overlap test (separating axis on each axis).
static func _aabb_overlap_3d(a: Dictionary, b: Dictionary) -> bool:
	if a.maxx < b.minx or b.maxx < a.minx: return false
	if a.maxy < b.miny or b.maxy < a.miny: return false
	if a.maxz < b.minz or b.maxz < a.minz: return false
	return true


## Half the diagonal of an XZ rectangle — used to size the spatial-index
## query radius generously so candidates aren't missed at corners.
static func _aabb_xz_radius(a: Dictionary) -> float:
	var hx: float = (float(a.maxx) - float(a.minx)) * 0.5
	var hz: float = (float(a.maxz) - float(a.minz)) * 0.5
	return sqrt(hx * hx + hz * hz)


## Axis-aligned-enclosing extents of a box rotated by `yaw` around the Y
## axis. For yaw = k * π/2 this is exact (extents swap X<->Z at π/2).
## For oblique yaw it slightly OVER-estimates, which can cause a false-fail
## near the AABB boundary — acceptable per ADR 0037 alternative E.
static func _yaw_enclosing_extents(ext: Vector3, yaw: float) -> Vector3:
	var c := absf(cos(yaw))
	var s := absf(sin(yaw))
	# Enclosing XZ extents from the rotated box.
	var ex: float = ext.x * c + ext.z * s
	var ez: float = ext.x * s + ext.z * c
	return Vector3(ex, ext.y, ez)


## Rotate a Vector3 around the Y axis by `yaw` (radians).
static func _rotate_y(v: Vector3, yaw: float) -> Vector3:
	var c := cos(yaw)
	var s := sin(yaw)
	return Vector3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)


## Coerce Array / Vector2 / Vector3 / scalar into Vector3.
## Mirrors EffectApply._to_vec3_v so AABB resolution is consistent.
static func _to_vec3(v) -> Vector3:
	if v is Vector3: return v
	if v is Vector2: return Vector3(v.x, 0, v.y)
	if v is Array:
		var a := v as Array
		if a.size() >= 3: return Vector3(float(a[0]), float(a[1]), float(a[2]))
		if a.size() == 2: return Vector3(float(a[0]), 0, float(a[1]))
	if v is float or v is int:
		return Vector3(float(v), float(v), float(v))
	return Vector3.ZERO
