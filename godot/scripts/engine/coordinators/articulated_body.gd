extends RefCounted
class_name ArticulatedBody

## ADR 0091 — an articulated body: one entity made of links and joints.
##
## Spec shape (a `physics` block with body_type "articulated"):
##
##   "physics": {
##     "body_type": "articulated",
##     "root": "chassis",
##     "links": {
##       "chassis": {"shape": {"type": "box", "size": [0.3, 0.08, 0.4]}, "mass": 2.0},
##       "wheel_l": {"shape": {"type": "cylinder", "radius": 0.1, "height": 0.04, "axis": "x"}}
##     },
##     "joints": [
##       {"type": "hinge", "parent": "chassis", "child": "wheel_l", "at": [-0.19, -0.05, -0.1],
##        "axis": [-1, 0, 0], "motor": {"target_velocity": "self.state.left_cmd", "max_torque": 2.0},
##        "report": "wheel_l"}
##     ],
##     "collision_layer": ["player"], "collision_mask": "all"
##   }
##
## A link frame has the orientation of the root at spawn. `at` places the
## child link origin in the parent link frame, and the joint anchor is that
## origin. A positive hinge velocity turns the child about `axis` by the
## right-hand rule. A `fixed` child merges into its parent body.
##
## Readback, at the start of each tick (World.advance_one_tick):
##   - the root pose writes state.position, state.yaw and state.velocity.
##   - a hinge with `report: "x"` writes state.x_angle (radians, not
##     wrapped) and state.x_speed (radians per second).
## Drive, at the end of each tick: each motor target is a formula with
## `self` and `world` bindings.
##
## The motion itself is host-defined (ADR 0086). This interpreter uses
## PhysicsServer3D rigid bodies and hinge or pin joints.

## The closed lists of ADR 0091. validate_host_neutral.py and
## gen_api_manifest.py read them from this file. A new name needs an ADR.
const JOINT_TYPES: Array = ["hinge", "ball", "fixed"]
const LINK_FIELDS: Array = ["shape", "mass", "friction", "restitution", "visual"]
const JOINT_FIELDS: Array = ["type", "parent", "child", "at", "axis", "limit", "motor", "report"]
const MOTOR_FIELDS: Array = ["target_velocity", "max_torque"]
const SHAPE_AXES: Array = ["x", "y", "z"]

## Godot's hinge motor turns the child against the right-hand rule. The
## spec sign is the right-hand rule, so the interpreter negates it.
## test_articulated_body checks the sign against a real step.
const _HOST_MOTOR_SIGN := -1.0

var entity: Entity = null
var root: String = ""
var freed: bool = false
## link name → the name of the link that owns its body (itself, or the
## parent it merged into through a fixed joint).
var _owner: Dictionary = {}
## link name → its pose in the owner body frame (identity for an owner).
var _in_owner: Dictionary = {}
## owner link name → body RID.
var _bodies: Dictionary = {}
## Each entry: {rid, type, a, b, axis_a, ref_a, ref_b, motor, report, angle, last}
var _joints: Array = []
## link name → world Transform3D, written at each readback. The renderer
## reads it through the entity meta `_link_poses`.
var poses: Dictionary = {}


## Build the bodies and joints of `phys_cfg` for `ent`. Returns null and
## reports physics.bad_articulation when the links do not form one tree.
static func build(
	ent: Entity, phys_cfg: Dictionary, space_rid: RID, layer_map: Dictionary, env: Dictionary = {}
) -> ArticulatedBody:
	var problem := _check(phys_cfg)
	if problem != "":
		EngineError.raise(
			env,
			EngineError.PHYSICS_BAD_ARTICULATION,
			"%s: %s" % [ent.instance_id, problem],
			{"entity": ent.instance_id},
			"Give each link except the root exactly one parent joint (ADR 0091)."
		)
		push_error("%s: %s: %s" % [EngineError.PHYSICS_BAD_ARTICULATION, ent.instance_id, problem])
		return null
	var ab := ArticulatedBody.new()
	ab.entity = ent
	ab._build(phys_cfg, space_rid, layer_map)
	ent.set_meta("_articulated", ab)
	ent.set_meta("_link_poses", ab.poses)
	ent.set_meta("_link_render", ab._render_specs(phys_cfg))
	return ab


## "" when the block is one tree of known joint types, else the problem.
static func _check(phys_cfg: Dictionary) -> String:
	var links = phys_cfg.get("links", null)
	if not (links is Dictionary) or (links as Dictionary).is_empty():
		return "an articulated body needs a 'links' object"
	var root_name := str(phys_cfg.get("root", ""))
	if not (links as Dictionary).has(root_name):
		return "'root' must name a link, got '%s'" % root_name
	var parent_of: Dictionary = {}
	for j in phys_cfg.get("joints", []):
		if not (j is Dictionary):
			return "each joint must be an object"
		var jt := str(j.get("type", ""))
		if not JOINT_TYPES.has(jt):
			return "'%s' is not a joint type. The types are: %s" % [jt, ", ".join(JOINT_TYPES)]
		var p := str(j.get("parent", ""))
		var c := str(j.get("child", ""))
		if not (links as Dictionary).has(p) or not (links as Dictionary).has(c):
			return "joint %s → %s names a link that does not exist" % [p, c]
		if c == root_name or parent_of.has(c):
			return "link '%s' has more than one parent" % c
		parent_of[c] = p
	for link_name in links:
		if str(link_name) == root_name:
			continue
		var seen: Dictionary = {}
		var cur := str(link_name)
		while cur != root_name:
			if not parent_of.has(cur) or seen.has(cur):
				return "link '%s' does not connect to the root" % link_name
			seen[cur] = true
			cur = str(parent_of[cur])
	return ""


func _build(phys_cfg: Dictionary, space_rid: RID, layer_map: Dictionary) -> void:
	root = str(phys_cfg["root"])
	var links: Dictionary = phys_cfg["links"]
	var joints: Array = phys_cfg.get("joints", [])
	# Spawn poses: the root at the entity position and yaw, each child at
	# `at` in its parent frame. Joints are placed in tree order.
	var pos = entity.get_position()
	var origin := Vector3.ZERO
	if pos is Vector3:
		origin = pos
	elif pos is Vector2:
		origin = Vector3(pos.x, 0.0, pos.y)
	var spawn: Dictionary = {root: Transform3D(Basis(Vector3.UP, float(entity.get_state("yaw", 0.0))), origin)}
	_owner[root] = root
	var ordered: Array = []
	var pending: Array = joints.duplicate()
	while not pending.is_empty():
		var rest: Array = []
		for j in pending:
			var p := str(j["parent"])
			if not spawn.has(p):
				rest.append(j)
				continue
			var c := str(j["child"])
			spawn[c] = spawn[p] * Transform3D(Basis.IDENTITY, _vec3(j.get("at", [0, 0, 0])))
			_owner[c] = _owner[p] if str(j["type"]) == "fixed" else c
			ordered.append(j)
		pending = rest
	# One rigid body for each owner link. A fixed child adds its shape and
	# mass to the owner body.
	var mass: Dictionary = {}
	for link_name in spawn:
		var owner_name := str(_owner[link_name])
		_in_owner[link_name] = spawn[owner_name].affine_inverse() * spawn[link_name]
		mass[owner_name] = float(mass.get(owner_name, 0.0)) + float(links[link_name].get("mass", 1.0))
	var layer_bits := PhysicsBodyBuilder.layer_mask(phys_cfg.get("collision_layer", "all"), layer_map)
	var mask_bits := PhysicsBodyBuilder.layer_mask(phys_cfg.get("collision_mask", "all"), layer_map)
	for link_name in spawn:
		var owner_name := str(_owner[link_name])
		if not _bodies.has(owner_name):
			var body := PhysicsServer3D.body_create()
			PhysicsServer3D.body_set_space(body, space_rid)
			PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_RIGID)
			PhysicsServer3D.body_set_collision_layer(body, layer_bits)
			PhysicsServer3D.body_set_collision_mask(body, mask_bits)
			PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, spawn[owner_name])
			# A robot stops and starts on a motor command, and a motor
			# change does not wake a body that sleeps.
			PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_CAN_SLEEP, false)
			PhysicsServer3D.body_attach_object_instance_id(body, entity.get_instance_id())
			var lcfg: Dictionary = links[owner_name]
			if lcfg.has("friction"):
				PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_FRICTION, float(lcfg["friction"]))
			if lcfg.has("restitution"):
				PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_BOUNCE, float(lcfg["restitution"]))
			for k in ["linear_damp", "angular_damp"]:
				if phys_cfg.has(k):
					var param := (
						PhysicsServer3D.BODY_PARAM_LINEAR_DAMP if k == "linear_damp"
						else PhysicsServer3D.BODY_PARAM_ANGULAR_DAMP
					)
					PhysicsServer3D.body_set_param(body, param, float(phys_cfg[k]))
			_bodies[owner_name] = body
		var shape_cfg = links[link_name].get("shape", null)
		if shape_cfg is Dictionary:
			var shape := PhysicsBodyBuilder._create_shape_3d(shape_cfg)
			if shape.is_valid():
				PhysicsServer3D.body_add_shape(
					_bodies[owner_name], shape, _in_owner[link_name] * shape_transform(shape_cfg)
				)
	for owner_name in _bodies:
		PhysicsServer3D.body_set_param(_bodies[owner_name], PhysicsServer3D.BODY_PARAM_MASS, mass[owner_name])
	# Links of one robot never collide with each other.
	var rids: Array = _bodies.values()
	for i in rids.size():
		for k in range(i + 1, rids.size()):
			PhysicsServer3D.body_add_collision_exception(rids[i], rids[k])
	for j in ordered:
		if str(j["type"]) != "fixed":
			_make_joint(j, spawn)
	_read_poses()


func _make_joint(j: Dictionary, spawn: Dictionary) -> void:
	var a := str(_owner[str(j["parent"])])
	var b := str(j["child"])
	var anchor: Vector3 = spawn[b].origin
	var rid := PhysicsServer3D.joint_create()
	var entry := {"rid": rid, "type": str(j["type"]), "a": a, "b": b, "motor": {}, "report": "", "angle": 0.0}
	if str(j["type"]) == "ball":
		PhysicsServer3D.joint_make_pin(
			rid, _bodies[a], spawn[a].affine_inverse() * anchor, _bodies[b], spawn[b].affine_inverse() * anchor
		)
	else:
		var axis_world: Vector3 = spawn[str(j["parent"])].basis * _vec3(j.get("axis", [1, 0, 0])).normalized()
		var frame := Transform3D(_basis_z(axis_world), anchor)
		var local_a: Transform3D = spawn[a].affine_inverse() * frame
		var local_b: Transform3D = spawn[b].affine_inverse() * frame
		PhysicsServer3D.joint_make_hinge(rid, _bodies[a], local_a, _bodies[b], local_b)
		entry["axis_a"] = local_a.basis.z
		entry["ref_a"] = local_a.basis.x
		entry["ref_b"] = local_b.basis.x
		var limit = j.get("limit", null)
		if limit is Array and (limit as Array).size() == 2:
			PhysicsServer3D.hinge_joint_set_flag(rid, PhysicsServer3D.HINGE_JOINT_FLAG_USE_LIMIT, true)
			PhysicsServer3D.hinge_joint_set_param(rid, PhysicsServer3D.HINGE_JOINT_LIMIT_LOWER, float(limit[0]))
			PhysicsServer3D.hinge_joint_set_param(rid, PhysicsServer3D.HINGE_JOINT_LIMIT_UPPER, float(limit[1]))
		var motor = j.get("motor", null)
		if motor is Dictionary:
			entry["motor"] = motor
			PhysicsServer3D.hinge_joint_set_flag(rid, PhysicsServer3D.HINGE_JOINT_FLAG_ENABLE_MOTOR, true)
			# The spec gives torque in N·m. The host takes an impulse for
			# each physics step.
			var dt := 1.0 / float(Engine.physics_ticks_per_second)
			PhysicsServer3D.hinge_joint_set_param(
				rid, PhysicsServer3D.HINGE_JOINT_MOTOR_MAX_IMPULSE, float(motor.get("max_torque", 1.0)) * dt
			)
			PhysicsServer3D.hinge_joint_set_param(rid, PhysicsServer3D.HINGE_JOINT_MOTOR_TARGET_VELOCITY, 0.0)
		entry["report"] = str(j.get("report", ""))
	PhysicsServer3D.joint_disable_collisions_between_bodies(rid, true)
	_joints.append(entry)


## Readback: the root pose and each reported hinge write entity state.
func read_back() -> void:
	if freed or entity == null:
		return
	_read_poses()
	var root_pose: Transform3D = poses[root]
	entity.set_position(root_pose.origin)
	entity.state["yaw"] = root_pose.basis.get_euler().y
	entity.state["velocity"] = PhysicsServer3D.body_get_state(
		_bodies[root], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY
	)
	for j in _joints:
		if str(j["report"]) == "":
			continue
		var ta: Transform3D = poses[j["a"]]
		var tb: Transform3D = poses[j["b"]]
		var axis: Vector3 = (ta.basis * (j["axis_a"] as Vector3)).normalized()
		var r0: Vector3 = ta.basis * (j["ref_a"] as Vector3)
		var r1: Vector3 = tb.basis * (j["ref_b"] as Vector3)
		var raw := atan2(axis.dot(r0.cross(r1)), r0.dot(r1))
		# Unwrap: a wheel angle counts whole turns, as an encoder does.
		var last := float(j.get("last", 0.0))
		j["angle"] = float(j["angle"]) + wrapf(raw - last, -PI, PI)
		j["last"] = raw
		var wa: Vector3 = PhysicsServer3D.body_get_state(_bodies[j["a"]], PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		var wb: Vector3 = PhysicsServer3D.body_get_state(_bodies[j["b"]], PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		entity.state[str(j["report"]) + "_angle"] = float(j["angle"])
		entity.state[str(j["report"]) + "_speed"] = (wb - wa).dot(axis)


## Drive: each hinge motor reads its target formula.
func drive(world_state: Dictionary, env: Dictionary = {}) -> void:
	if freed or entity == null:
		return
	for j in _joints:
		var motor: Dictionary = j["motor"]
		if motor.is_empty():
			continue
		var v := float(Formula.evaluate(motor.get("target_velocity", 0.0), {"self": entity, "world": world_state}, env))
		PhysicsServer3D.hinge_joint_set_param(
			j["rid"], PhysicsServer3D.HINGE_JOINT_MOTOR_TARGET_VELOCITY, _HOST_MOTOR_SIGN * v
		)


func free_all() -> void:
	if freed:
		return
	freed = true
	for j in _joints:
		PhysicsServer3D.free_rid(j["rid"])
	_joints.clear()
	for owner_name in _bodies:
		var body: RID = _bodies[owner_name]
		# Collect first: a freed shape leaves the body, and the indices move.
		var shapes: Array = []
		for i in PhysicsServer3D.body_get_shape_count(body):
			shapes.append(PhysicsServer3D.body_get_shape(body, i))
		PhysicsServer3D.free_rid(body)
		for shape in shapes:
			PhysicsServer3D.free_rid(shape)
	_bodies.clear()


func _read_poses() -> void:
	var owner_pose: Dictionary = {}
	for owner_name in _bodies:
		owner_pose[owner_name] = PhysicsServer3D.body_get_state(
			_bodies[owner_name], PhysicsServer3D.BODY_STATE_TRANSFORM
		)
	for link_name in _owner:
		poses[link_name] = owner_pose[_owner[link_name]] * _in_owner[link_name]


## link name → {shape, visual} for the renderer.
func _render_specs(phys_cfg: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var links: Dictionary = phys_cfg["links"]
	for link_name in links:
		out[link_name] = {
			"shape": links[link_name].get("shape", {}),
			"visual": links[link_name].get("visual", {}),
		}
	return out


## The local transform of a link shape: a cylinder or capsule lies along
## `axis` ("y" by default), then `offset` moves it.
static func shape_transform(shape_cfg: Dictionary) -> Transform3D:
	var basis := Basis.IDENTITY
	match str(shape_cfg.get("axis", "y")):
		"x":
			basis = Basis(Vector3(0, 0, 1), -PI / 2.0)
		"z":
			basis = Basis(Vector3(1, 0, 0), PI / 2.0)
	return Transform3D(basis, _vec3(shape_cfg.get("offset", [0, 0, 0])))


static func _basis_z(z_axis: Vector3) -> Basis:
	var z := z_axis.normalized()
	var up := Vector3.UP if absf(z.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var x := up.cross(z).normalized()
	return Basis(x, z.cross(x), z)


static func _vec3(v) -> Vector3:
	if v is Vector3:
		return v
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO
