extends RefCounted
class_name SensorArray

## ADR 0092 — ray and lidar sensors that write state each tick.
##
## Spec shape (a top-level `sensors` list in an entity def):
##
##   "sensors": [
##     {"type": "ray", "link": "chassis", "at": [0, 0, -0.21], "direction": [0, 0, -1],
##      "range": 3.0, "report": "front"},
##     {"type": "lidar", "at": [0, 0.06, 0], "rays": 24, "fov": 2.4, "range": 4.0,
##      "report": "lidar", "collision_mask": ["wall"]}
##   ]
##
## A sensor frame is the pose of its `link` (an articulated body, ADR
## 0091), or else the entity position and yaw. `at` and `direction` are
## in that frame. Rays hit collision shapes, not areas, and never the
## entity's own bodies.
##
## Readback, after the articulated readback at the start of each tick:
##   - ray:   <report>_distance (`range` when nothing is hit) and
##            <report>_hit (0 or 1).
##   - lidar: <report>_ranges (one distance for each ray),
##            <report>_min and <report>_min_angle. An angle is in radians
##            from `direction` about the frame up axis, positive to the
##            left (the yaw sense). The rays spread evenly over `fov`.
##
## Distances are host-defined (ADR 0086).

## The closed lists of ADR 0092. validate_host_neutral.py and
## gen_api_manifest.py read them from this file. A new name needs an ADR.
const SENSOR_TYPES: Array = ["ray", "lidar"]
const SENSOR_FIELDS: Array = [
	"type", "link", "at", "direction", "range", "rays", "fov", "report", "collision_mask",
]

var entity: Entity = null
var space: RID = RID()
## Each entry: {type, link, at: Vector3, direction: Vector3, range, rays, fov, report, mask}
var sensors: Array = []


## Build the sensors of `cfgs` for `ent`. The caller registers the result
## on World, which reads it once per tick.
static func build(ent: Entity, cfgs: Array, space_rid: RID, layer_map: Dictionary) -> SensorArray:
	var sa := SensorArray.new()
	sa.entity = ent
	sa.space = space_rid
	for c in cfgs:
		if not (c is Dictionary):
			continue
		var t := str(c.get("type", ""))
		if not SENSOR_TYPES.has(t) or str(c.get("report", "")) == "":
			push_error(
				"%s: %s: a sensor needs a type (%s) and a report name (ADR 0092)."
				% [EngineError.SENSOR_BAD_CONFIG, ent.instance_id, ", ".join(SENSOR_TYPES)]
			)
			continue
		var dir := ArticulatedBody._vec3(c.get("direction", [0, 0, -1]))
		sa.sensors.append({
			"type": t,
			"link": str(c.get("link", "")),
			"at": ArticulatedBody._vec3(c.get("at", [0, 0, 0])),
			"direction": dir.normalized() if dir.length() > 1e-6 else Vector3.FORWARD,
			"range": float(c.get("range", 5.0)),
			"rays": maxi(1, int(c.get("rays", 1))),
			"fov": float(c.get("fov", TAU)),
			"report": str(c["report"]),
			"mask": PhysicsBodyBuilder.layer_mask(c.get("collision_mask", "all"), layer_map),
		})
	return sa


## Cast every ray and write the readings to entity state.
func read() -> void:
	if entity == null or not is_instance_valid(entity):
		return
	var dss := PhysicsServer3D.space_get_direct_state(space)
	if dss == null:
		return
	var exclude := _own_bodies()
	for s in sensors:
		var frame := _frame(str(s["link"]))
		var origin: Vector3 = frame * (s["at"] as Vector3)
		var dir: Vector3 = (frame.basis * (s["direction"] as Vector3)).normalized()
		var rng := float(s["range"])
		var rep := str(s["report"])
		if s["type"] == "ray":
			var d := _cast(dss, origin, dir, rng, int(s["mask"]), exclude)
			entity.state[rep + "_distance"] = d
			entity.state[rep + "_hit"] = 1 if d < rng else 0
			continue
		var n := int(s["rays"])
		var fov := float(s["fov"])
		var full := fov >= TAU - 1e-3
		var step := fov / float(n) if full else (fov / float(n - 1) if n > 1 else 0.0)
		var start := -fov * 0.5 if n > 1 else 0.0
		var up := frame.basis.y.normalized()
		var ranges: Array = []
		var best := rng
		var best_angle := 0.0
		for i in n:
			var angle := start + step * float(i)
			var d := _cast(dss, origin, Basis(up, angle) * dir, rng, int(s["mask"]), exclude)
			ranges.append(d)
			if d < best:
				best = d
				best_angle = angle
		entity.state[rep + "_ranges"] = ranges
		entity.state[rep + "_min"] = best
		entity.state[rep + "_min_angle"] = best_angle


func _cast(dss: PhysicsDirectSpaceState3D, origin: Vector3, dir: Vector3, rng: float, mask: int, exclude: Array) -> float:
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * rng, mask, exclude)
	var hit := dss.intersect_ray(q)
	if hit.is_empty():
		return rng
	return origin.distance_to(hit["position"])


## The sensor frame: a link pose, or the entity position and yaw.
func _frame(link: String) -> Transform3D:
	if link != "" and entity.has_meta("_link_poses"):
		var poses: Dictionary = entity.get_meta("_link_poses")
		if poses.has(link):
			return poses[link]
	var p = entity.get_position()
	var origin := Vector3.ZERO
	if p is Vector3:
		origin = p
	elif p is Vector2:
		origin = Vector3(p.x, 0.0, p.y)
	return Transform3D(Basis(Vector3.UP, float(entity.get_state("yaw", 0.0))), origin)


func _own_bodies() -> Array:
	var out: Array = []
	if entity.has_meta("_articulated"):
		var ab = entity.get_meta("_articulated")
		if ab is ArticulatedBody:
			out.append_array((ab as ArticulatedBody)._bodies.values())
	if entity.has_meta("_physics_body"):
		var b = entity.get_meta("_physics_body")
		if b is RID:
			out.append(b)
		elif b is CollisionObject3D:
			out.append((b as CollisionObject3D).get_rid())
	return out
