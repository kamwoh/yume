extends Object
class_name Vec3Util

## Shared Vector3 coercion helpers.
##
## Yume's convention for WORLD positions: Vector2 means (x, z) on the
## floor plane — Y is world-up. A 2D Vector2(x, y) lifts to
## Vector3(x, 0, y) so 2D demos and 3D demos can share the same JSON
## state.position values. Renderer details: entity_mesh_3d.gd:127
## reads Entity.get_planar_position() (which preserves this convention).
##
## This util is for GAMEPLAY/world code — pathfinding, build validators,
## effect resolution, party formation, instance-pattern expansion.
##
## NOT for mesh-local geometry. Mesh authoring code (entity_mesh_3d,
## multimesh_director, mesh_lib) uses a different convention where
## Vector2(x, y) → Vector3(x, y, 0) — i.e., screen-space 2D lifted to a
## flat plane. Those files keep their own local _to_vec3 helpers
## (intentionally NOT merged here — different semantics).


## Coerce Array / Vector2 / Vector3 / scalar → Vector3 (world convention).
##
##   Vector3        → passthrough
##   Vector2(x,y)   → Vector3(x, 0, y)     (floor plane, Y=up)
##   Array[3]       → Vector3(a[0], a[1], a[2])
##   Array[2]       → Vector3(a[0], 0, a[1])
##   float / int    → Vector3(v, v, v)     (uniform broadcast — used for
##                                          aabb_extents, scale, etc.)
##   else           → Vector3.ZERO
static func from_world_pos(v) -> Vector3:
	if v is Vector3: return v
	if v is Vector2: return Vector3((v as Vector2).x, 0, (v as Vector2).y)
	if v is Array:
		var a := v as Array
		if a.size() >= 3: return Vector3(float(a[0]), float(a[1]), float(a[2]))
		if a.size() == 2: return Vector3(float(a[0]), 0, float(a[1]))
	if v is float or v is int:
		var f := float(v)
		return Vector3(f, f, f)
	return Vector3.ZERO
