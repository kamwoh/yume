extends RefCounted
class_name MotionIntegrator

## Per-frame motion integration — extracted from world.gd on 2026-05-12.
##
## Owns the ADR 0044 Session D motion pipeline:
##   1. Apply drag (state.drag) — decay velocity toward zero
##   2. Skip entities tagged blocks_motion (static; don't self-move)
##   3. Compute proposed position = current + velocity * delta
##   4. resolve_motion_via_physics_3d slides along separate axes on
##      collision (try X-only, then Z-only, else stay)
##   5. Entity.set_position writes — auto-syncs to body if attached
##   6. Spatial index updated for radius queries
##
## Vector3 path is the only physics-aware path. Vector2 motion is
## a passthrough (no collision) until PhysicsServer2D backend lands.
##
## Holds the cached SphereShape3D collision-test shape — created lazily
## per unique body_radius, freed on NOTIFICATION_PREDELETE.
##
## Pattern matches LevelTransitionCoordinator / SpawnManager — RefCounted,
## per-World instance, constructor takes a world reference.

const DRAG_REST_EPSILON := 0.5
const DEFAULT_BODY_RADIUS := 0.4

var _world: World
var _physics_test_shape_3d: RID = RID()
var _physics_test_shape_radius: float = -1.0


func _init(world: World) -> void:
	_world = world


## RefCounted predelete — free the cached SphereShape3D RID so it
## doesn't leak when the World drops the integrator. Caught 2026-05-12
## boot test: "1 RID allocation of type 'P12GodotShape3D' was leaked
## at exit" before this was added.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _physics_test_shape_3d.is_valid():
			PhysicsServer3D.free_rid(_physics_test_shape_3d)
			_physics_test_shape_3d = RID()


## Integrate one frame of motion for all entities. Called from
## World._process each frame.
func integrate(delta: float) -> void:
	var entities: Dictionary = _world.entities
	var spatial_index = _world.spatial_index
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity):
			continue
		var v = (ent as Entity).get_velocity()
		if v == null:
			continue
		# Apply drag if configured. Skipped if drag = 0 (default).
		var drag_v := float((ent as Entity).get_state("drag", 0.0))
		if drag_v > 0.0:
			var factor: float = 1.0 - clamp(drag_v * delta, 0.0, 1.0)
			if v is Vector2:
				var v2: Vector2 = v
				if v2 != Vector2.ZERO:
					v2 *= factor
					if v2.length() < DRAG_REST_EPSILON:
						v2 = Vector2.ZERO
					(ent as Entity).set_velocity(v2)
					v = v2
			elif v is Vector3:
				var v3: Vector3 = v
				if v3 != Vector3.ZERO:
					v3 *= factor
					if v3.length() < DRAG_REST_EPSILON * 0.01:
						v3 = Vector3.ZERO
					(ent as Entity).set_velocity(v3)
					v = v3
		# Static obstacles don't move themselves.
		if (ent as Entity).has_tag("blocks_motion"):
			continue
		var body_r: float = float((ent as Entity).get_property("body_radius", DEFAULT_BODY_RADIUS))
		var p = (ent as Entity).get_position()
		var moved := false
		# Vector3 path — all 3D scenes (Aldenmere + future 3D games).
		# Vector2 velocity translated to Vector3 (x, 0, y) per Yume convention.
		if p is Vector3:
			var new_p3: Vector3
			if v is Vector3 and v != Vector3.ZERO:
				new_p3 = (p as Vector3) + (v as Vector3) * delta
			elif v is Vector2 and v != Vector2.ZERO:
				var v2: Vector2 = v
				new_p3 = (p as Vector3) + Vector3(v2.x, 0, v2.y) * delta
			else:
				continue
			new_p3 = _resolve_motion_via_physics_3d(p as Vector3, new_p3, body_r)
			(ent as Entity).set_position(new_p3)
			moved = true
		elif p is Vector2 and v is Vector2 and v != Vector2.ZERO:
			# 2D scene fallback (no physics collision; entity moves freely).
			# Other demos using Vector2 motion need PhysicsServer2D backend
			# (future sub-step). Aldenmere doesn't hit this branch.
			(ent as Entity).set_position((p as Vector2) + (v as Vector2) * delta)
			moved = true
		if moved and spatial_index != null:
			spatial_index.update_entity(id, (ent as Entity).get_planar_position())


## Cached SphereShape3D for collision queries. Created once per
## unique body_radius; freed at predelete.
func _ensure_physics_test_shape(radius: float) -> RID:
	if _physics_test_shape_3d.is_valid() and abs(_physics_test_shape_radius - radius) < 0.001:
		return _physics_test_shape_3d
	if _physics_test_shape_3d.is_valid():
		PhysicsServer3D.free_rid(_physics_test_shape_3d)
	_physics_test_shape_3d = PhysicsServer3D.sphere_shape_create()
	PhysicsServer3D.shape_set_data(_physics_test_shape_3d, radius)
	_physics_test_shape_radius = radius
	return _physics_test_shape_3d


## Returns true if a sphere of `radius` at `pos` overlaps ANY physics
## body in the 3D space. Used by integrate() to detect collision
## between a moving (body-less) entity and static walls (which DO have
## bodies via Session A translation of blocks_motion).
##
## Returns false when no 3D space exists (2D scene, headless test
## without viewport) — caller treats as no collision.
func _physics_collides_3d(pos: Vector3, radius: float) -> bool:
	var vp := _world.get_viewport()
	if vp == null:
		return false
	var w3d := vp.find_world_3d()
	if w3d == null:
		return false
	var space: RID = w3d.space
	if not space.is_valid():
		return false
	var ds := PhysicsServer3D.space_get_direct_state(space)
	if ds == null:
		return false
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape_rid = _ensure_physics_test_shape(radius)
	query.transform = Transform3D(Basis(), pos)
	query.collision_mask = 0xFFFFFFFF
	return not ds.intersect_shape(query, 1).is_empty()


## Resolve 3D motion via PhysicsServer3D.intersect_shape — replaces
## the hand-rolled AABB slide. Same separate-axes slide policy: try
## X-only, then Z-only, then stay. Y is preserved (Aldenmere's
## entities stay on ground; ground constraint handled separately).
func _resolve_motion_via_physics_3d(from_p: Vector3, to_p: Vector3, radius: float) -> Vector3:
	if not _physics_collides_3d(to_p, radius):
		return to_p
	var x_only := Vector3(to_p.x, from_p.y, from_p.z)
	if not _physics_collides_3d(x_only, radius):
		return Vector3(to_p.x, to_p.y, from_p.z)
	var z_only := Vector3(from_p.x, from_p.y, to_p.z)
	if not _physics_collides_3d(z_only, radius):
		return Vector3(from_p.x, to_p.y, to_p.z)
	return from_p
