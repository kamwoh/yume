extends Object
class_name PhysicsBodyBuilder

## ADR 0044 Session A — physics body factory.
##
## Stateless static utilities for creating PhysicsServer3D bodies from
## Yume entity `physics` blocks. Called by SpawnManager.spawn AFTER the
## Entity is created and added to env.entities; the resulting body_rid
## is stored as meta on the entity (`_physics_body_rid`).
##
## Schema (from ADR 0044 § "JSON schema (per-entity physics declaration)"):
##
##   "physics": {
##     "body_type": "static" | "kinematic" | "rigid" | "area",
##     "collision_shape": {"type": "box"|"sphere"|"capsule"|"cylinder",
##                         "size":   [x,y,z]   // box
##                         "radius": float     // sphere/capsule/cylinder
##                         "height": float     // capsule/cylinder
##                        },
##     "collision_layer": ["wall", "player", ...],     // names
##     "collision_mask":  ["player", "enemy", ...],    // names
##     "mass": float,
##     "friction": float (0..1),
##     "restitution": float (0..1),
##     "linear_damp": float,
##     "angular_damp": float,
##     "gravity_scale": float
##   }
##
## Translation layer: entities with legacy `blocks_motion` tag +
## `properties.aabb_extents` get an auto-synthesized physics block
## via `translate_blocks_motion(def)`.
##
## Bodies are created in Yume's 3D physics space (from the active
## Viewport's World3D). 2D backend (PhysicsServer2D) lands in a later
## sub-step per ADR Condition 9.


# ============================================================
# PUBLIC API
# ============================================================

## Build a PhysicsServer3D body from an entity's physics block.
## Returns RID.from_int64(0) on failure / no-op.
##
## Params:
##   entity     — the Entity node (must have state.position)
##   phys_cfg   — the resolved physics block dict (post-translation)
##   space_rid  — the 3D physics space (from world.physics_space_3d)
##   layer_map  — name → bit dict (from @lib.physics.layers.layers)
static func build_3d(entity, phys_cfg: Dictionary, space_rid: RID,
                     layer_map: Dictionary) -> RID:
	if phys_cfg.is_empty():
		return RID()
	if not space_rid.is_valid():
		push_warning("[PhysicsBodyBuilder] no valid 3D physics space — skipping body for %s" % entity.instance_id)
		return RID()

	var body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_space(body, space_rid)

	# Body type → Godot body mode
	var btype := str(phys_cfg.get("body_type", "kinematic"))
	var mode := _body_mode_3d(btype)
	PhysicsServer3D.body_set_mode(body, mode)

	# Collision shape
	var shape_cfg = phys_cfg.get("collision_shape", null)
	if shape_cfg is Dictionary:
		var shape_rid := _create_shape_3d(shape_cfg)
		if shape_rid.is_valid():
			PhysicsServer3D.body_add_shape(body, shape_rid)
	else:
		push_warning("[PhysicsBodyBuilder] entity %s has physics block but no collision_shape — body is shapeless" % entity.instance_id)

	# Collision layer + mask
	var layer_bits := _resolve_layer_mask(phys_cfg.get("collision_layer", "all"), layer_map)
	var mask_bits  := _resolve_layer_mask(phys_cfg.get("collision_mask",  "all"), layer_map)
	PhysicsServer3D.body_set_collision_layer(body, layer_bits)
	PhysicsServer3D.body_set_collision_mask(body, mask_bits)

	# Physics material (mass / friction / restitution / damping / gravity)
	if mode == PhysicsServer3D.BODY_MODE_RIGID:
		if phys_cfg.has("mass"):
			PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_MASS,
				float(phys_cfg["mass"]))
		if phys_cfg.has("friction"):
			PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_FRICTION,
				float(phys_cfg["friction"]))
		if phys_cfg.has("restitution"):
			PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_BOUNCE,
				float(phys_cfg["restitution"]))
		if phys_cfg.has("linear_damp"):
			PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_LINEAR_DAMP,
				float(phys_cfg["linear_damp"]))
		if phys_cfg.has("angular_damp"):
			PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_ANGULAR_DAMP,
				float(phys_cfg["angular_damp"]))
		if phys_cfg.has("gravity_scale"):
			PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE,
				float(phys_cfg["gravity_scale"]))

	# Set initial transform from entity.state.position
	var pos = entity.get_position() if entity.has_method("get_position") else null
	var transform := Transform3D()
	if pos is Vector3:
		transform.origin = pos
	elif pos is Vector2:
		transform.origin = Vector3(pos.x, 0, pos.y)
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, transform)

	# Stamp the entity with this body's RID so despawn can free it.
	entity.set_meta("_physics_body_rid", body)

	return body


## Free a body created via build_3d (and its associated shapes).
## Called by SpawnManager.despawn before queue_free.
static func free_3d(entity) -> void:
	if not entity.has_meta("_physics_body_rid"):
		return
	var body: RID = entity.get_meta("_physics_body_rid")
	if not body.is_valid():
		entity.remove_meta("_physics_body_rid")
		return
	# Free shapes attached to the body
	var shape_count := PhysicsServer3D.body_get_shape_count(body)
	for i in range(shape_count):
		var shape: RID = PhysicsServer3D.body_get_shape(body, i)
		if shape.is_valid():
			PhysicsServer3D.free_rid(shape)
	# Free the body itself
	PhysicsServer3D.free_rid(body)
	entity.remove_meta("_physics_body_rid")


# ============================================================
# TRANSLATION LAYER
# ============================================================

## Synthesize a physics block from legacy `blocks_motion` tag +
## `properties.aabb_extents`. Returns {} if the def doesn't have the
## legacy markers (no translation needed).
##
## Per ADR 0044 "Backward compatibility" — translation is the default
## strategy. Old games keep running without per-game JSON edits.
static func translate_blocks_motion(def: Dictionary) -> Dictionary:
	# Check for explicit physics block first — wins over translation.
	if def.has("physics") and def["physics"] is Dictionary and not (def["physics"] as Dictionary).is_empty():
		if "blocks_motion" in (def.get("tags", []) as Array):
			push_warning("[PhysicsBodyBuilder] entity def '%s' has BOTH `physics` block AND `blocks_motion` tag — `physics` block takes precedence; remove the tag to silence this warning"
				% str(def.get("id", "?")))
		return def["physics"]

	var has_tag := "blocks_motion" in (def.get("tags", []) as Array)
	if not has_tag:
		return {}

	var props: Dictionary = def.get("properties", {})
	var extents = props.get("aabb_extents", null)
	if not (extents is Array) or (extents as Array).is_empty():
		push_warning("[PhysicsBodyBuilder] entity def '%s' has `blocks_motion` tag but no `properties.aabb_extents` — cannot translate; skipping body creation. Add aabb_extents or a `physics` block."
			% str(def.get("id", "?")))
		return {}

	var ext_arr: Array = extents
	# Detect 2D vs 3D from extents length
	# 3D: [hx, hy, hz] (3 components). 2D: [hx, hy] (2 components).
	if ext_arr.size() >= 3:
		var hx := float(ext_arr[0])
		var hy := float(ext_arr[1])
		var hz := float(ext_arr[2])
		return {
			"body_type": "static",
			"collision_shape": {"type": "box", "size": [hx * 2.0, hy * 2.0, hz * 2.0]},
			"collision_layer": ["wall"],
			"collision_mask": "all",
			"_translated_from": "blocks_motion+aabb_extents (3D)"
		}
	elif ext_arr.size() == 2:
		var hx2 := float(ext_arr[0])
		var hy2 := float(ext_arr[1])
		return {
			"body_type": "static",
			"collision_shape": {"type": "box2d", "size": [hx2 * 2.0, hy2 * 2.0]},
			"collision_layer": ["wall"],
			"collision_mask": "all",
			"_translated_from": "blocks_motion+aabb_extents (2D)"
		}
	push_warning("[PhysicsBodyBuilder] entity def '%s' has aabb_extents with unexpected length %d"
		% [str(def.get("id", "?")), ext_arr.size()])
	return {}


# ============================================================
# INTERNAL
# ============================================================

static func _body_mode_3d(body_type: String) -> int:
	match body_type:
		"static":    return PhysicsServer3D.BODY_MODE_STATIC
		"kinematic": return PhysicsServer3D.BODY_MODE_KINEMATIC
		"rigid":     return PhysicsServer3D.BODY_MODE_RIGID
		"area":
			push_warning("[PhysicsBodyBuilder] body_type='area' not yet implemented — using static")
			return PhysicsServer3D.BODY_MODE_STATIC
		_:
			push_warning("[PhysicsBodyBuilder] unknown body_type '%s' — defaulting to kinematic" % body_type)
			return PhysicsServer3D.BODY_MODE_KINEMATIC


static func _create_shape_3d(shape_cfg: Dictionary) -> RID:
	var stype := str(shape_cfg.get("type", "box"))
	var shape := RID()
	match stype:
		"box":
			shape = PhysicsServer3D.box_shape_create()
			var size_v: Vector3 = _vec3_from(shape_cfg.get("size", [1, 1, 1]))
			# Godot's BoxShape3D wants HALF extents.
			PhysicsServer3D.shape_set_data(shape, size_v * 0.5)
		"sphere":
			shape = PhysicsServer3D.sphere_shape_create()
			PhysicsServer3D.shape_set_data(shape, float(shape_cfg.get("radius", 0.5)))
		"capsule":
			shape = PhysicsServer3D.capsule_shape_create()
			PhysicsServer3D.shape_set_data(shape, {
				"radius": float(shape_cfg.get("radius", 0.4)),
				"height": float(shape_cfg.get("height", 1.0)),
			})
		"cylinder":
			shape = PhysicsServer3D.cylinder_shape_create()
			PhysicsServer3D.shape_set_data(shape, {
				"radius": float(shape_cfg.get("radius", 0.4)),
				"height": float(shape_cfg.get("height", 1.0)),
			})
		_:
			push_warning("[PhysicsBodyBuilder] unsupported 3D shape type '%s'" % stype)
	return shape


## Resolve collision_layer / collision_mask to a 32-bit mask.
## Accepts:
##   "all"              → 0xFFFFFFFF
##   ["wall", "player"] → bit(wall) | bit(player)
##   int (raw mask)     → passed through
static func _resolve_layer_mask(value, layer_map: Dictionary) -> int:
	if value is int:
		return int(value)
	if value is String:
		if str(value) == "all":
			return 0xFFFFFFFF
		# Single layer name
		var bit := int(layer_map.get(str(value), 0))
		return (1 << (bit - 1)) if bit > 0 else 0
	if value is Array:
		var mask: int = 0
		for name in (value as Array):
			var bit2 := int(layer_map.get(str(name), 0))
			if bit2 > 0:
				mask |= (1 << (bit2 - 1))
			else:
				push_warning("[PhysicsBodyBuilder] unknown collision layer name '%s'" % str(name))
		return mask
	return 0


static func _vec3_from(value) -> Vector3:
	if value is Vector3: return value
	if value is Array and (value as Array).size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO


# ============================================================
# ADR 0044 Session B — state ↔ body sync
# ============================================================

## Mirror entity.state.position to body.global_transform. Called by
## Entity.set_position when a body is attached. Per ADR 0044 Condition
## 6: kinematic gets a warp (body.transform = pos); rigid gets a
## warp + warn (direct position writes on rigid bodies are
## non-physical but we let it through to support hot-swap of state
## by rules).
static func sync_body_transform(entity) -> void:
	if not entity.has_meta("_physics_body_rid"): return
	var body: RID = entity.get_meta("_physics_body_rid")
	if not body.is_valid(): return
	var p = entity.get_position()
	var v3: Vector3
	if p is Vector3:
		v3 = p
	elif p is Vector2:
		v3 = Vector3(p.x, 0, p.y)
	else:
		return
	var xform := Transform3D(Basis(), v3)
	PhysicsServer3D.body_set_state(body,
		PhysicsServer3D.BODY_STATE_TRANSFORM, xform)


## Mirror entity.state.velocity to body.linear_velocity. Called by
## Entity.set_velocity when a body is attached.
static func sync_body_velocity(entity) -> void:
	if not entity.has_meta("_physics_body_rid"): return
	var body: RID = entity.get_meta("_physics_body_rid")
	if not body.is_valid(): return
	var v = entity.get_velocity()
	var v3: Vector3
	if v is Vector3:
		v3 = v
	elif v is Vector2:
		# Yume's 2D convention: Vector2(x, y) where y maps to world-Z.
		v3 = Vector3(v.x, 0, v.y)
	else:
		return
	PhysicsServer3D.body_set_state(body,
		PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, v3)
