extends Object
class_name EffectMotion

## Motion + spatial-query effect handlers.
##
##   - velocity_set / velocity_set_relative / velocity_add_relative /
##     velocity_lerp — direct + camera-relative + accumulating velocity
##     contributions for the seven-primitive motion vocabulary.
##   - pathfind_to — wires entity velocity toward next NavigationAgent3D
##     waypoint (ADR 0024). Delegates to Pathfinding util module.
##   - raycast_hit — hitscan weapon primitive (ADR 0005). Casts a ray
##     from origin, finds closest tag-matching entity, optionally walled
##     by blocks_motion AABBs. Internal helpers (_matches_tags,
##     _collect_blockers_from_env, _ray_aabb_t, _ray_sphere_t) live
##     here too — they're raycast-only and shouldn't pollute global
##     namespace.
##
## All static. Resolution helpers in EffectResolution.

# ============================================================
# MOTION (W2 will also add the per-tick motion integrator alongside this)
# ============================================================


static func velocity_set(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
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
static func velocity_set_relative(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
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


## Camera-relative velocity contribution. Auto-resets velocity on the FIRST
## fire per sim-tick for a given entity, then accumulates subsequent fires
## within the same tick. So multiple input rules in one tick combine (W + D
## → forward + strafe → diagonal), but the previous tick's velocity never
## carries over — eliminates the facing-lag drift that used to need a
## separate _pretick_velocity_zero scan in world.gd.
##
## "First fire per tick" is detected via `state._vel_add_last_tick` vs
## `world._tick` (the monotonic sim-tick counter, set by world.gd::_tick_due).
##
## Equilibrium: with drag d and tick delta dt, top speed ≈ add * 1/(d*dt)
## when drag is opt-in. Without drag (e.g. Aldenmere FP), velocity is set
## fresh each tick — only this tick's keys matter — so top speed = add
## directly.
##
## Empirically motivated:
##   - 2026-05-03 doomarena3d v2 playtest: diagonal broken with velocity_
##     set_relative wiping prior input → moved to _add_relative.
##   - 2026-05-10 Aldenmere FP: facing-lag drift on mouse turn while walking
##     → patched with state.zero_velocity_pretick + _pretick_velocity_zero.
##   - 2026-05-15: root-cause fix — auto-reset in the effect itself.
static func velocity_add_relative(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
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
	# ADR 0040 Condition 1: strafe-sign matches _velocity_set_relative.
	var sx := cos(facing) * strafe
	var sz := -sin(facing) * strafe
	var dvx := fx + sx
	var dvz := fz + sz
	# Cross-tick auto-reset: first fire this tick zeros velocity before
	# adding; subsequent fires (multi-key same tick) accumulate normally.
	var ws: Dictionary = env.get("world", {}) as Dictionary
	var current_tick := int(ws.get("_tick", -1))
	var last_tick := int(ent.get_state("_vel_add_last_tick", -2))
	var fresh_tick := current_tick != last_tick
	if fresh_tick:
		ent.set_state("_vel_add_last_tick", current_tick)
	# Branch on velocity TYPE, not position (ADR 0040 fix 2026-05-10:
	# Vector2 velocity + Vector3 position is valid for floor-walkers).
	var v_cur = ent.get_velocity()
	if v_cur is Vector2:
		var base := Vector2.ZERO if fresh_tick else (v_cur as Vector2)
		ent.set_velocity(base + Vector2(dvx, dvz))
	elif v_cur is Vector3:
		var base := Vector3.ZERO if fresh_tick else (v_cur as Vector3)
		ent.set_velocity(base + Vector3(dvx, 0, dvz))
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
static func velocity_lerp(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
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
static func pathfind_to(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var ent: Entity = EffectResolution.target(e, env, ctx)
	if ent == null:
		return
	var dx := float(EffectResolution.value(e.get("destination_x", 0), ctx, env))
	var dy := float(EffectResolution.value(e.get("destination_y", 0), ctx, env))
	var dz := float(EffectResolution.value(e.get("destination_z", 0), ctx, env))
	var speed := float(EffectResolution.value(e.get("speed", 1.0), ctx, env))
	Pathfinding.tick_pathfind(env, ent, dx, dy, dz, speed)


# ============================================================
# RAYCAST_HIT (ADR 0005)
# ============================================================
# Hitscan weapon primitive — casts a ray from origin in direction up to
# max_distance, finds the closest entity matching tag filters, optionally
# capped by walls (blocks_motion AABBs). On hit: binds `hit` (entity id)
# and `hit_point` (Vector3 world position) and runs `on_hit` effects. On
# miss: binds `hit_point` (ray endpoint or wall hit point) and runs
# `on_miss`.
static func raycast_hit(e: Dictionary, env: Dictionary, ctx: Dictionary) -> void:
	var origin: Vector3 = Vec3Util.from_world_pos(
		EffectResolution.position(e.get("origin", [0, 0, 0]), env, ctx)
	)
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
				EffectApply.apply(sub, env, sub_ctx)
	else:
		for sub in e.get("on_miss", []) as Array:
			if sub is Dictionary:
				EffectApply.apply(sub, env, sub_ctx)


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
