extends Object
class_name PhysicsBodyBuilder

## ADR 0044 Session A — physics body factory.
##
## Stateless static utilities for creating PhysicsServer3D bodies from
## Yume entity `physics` blocks. Called by SpawnManager.spawn AFTER the
## Entity is created and added to env.entities; the resulting body_rid
## is stored as meta on the entity (`_physics_body`).
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
static func build_3d(entity, phys_cfg: Dictionary, space_rid: RID, layer_map: Dictionary) -> RID:
	if phys_cfg.is_empty():
		return RID()
	if not space_rid.is_valid():
		push_warning(
			(
				"[PhysicsBodyBuilder] no valid 3D physics space — skipping body for %s"
				% entity.instance_id
			)
		)
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
			# Optional shape offset (collision_shape.offset = [x, y, z]).
			# Lets the collider sit elsewhere than the body's origin —
			# critical for Tripo3D meshes that are bbox-centered (collider
			# at entity.position would sit half-underground). 2026-05-24.
			var off_v = (shape_cfg as Dictionary).get("offset", null)
			if off_v is Array and (off_v as Array).size() >= 3:
				var shape_xform := Transform3D(
					Basis.IDENTITY,
					Vector3(float(off_v[0]), float(off_v[1]), float(off_v[2]))
				)
				PhysicsServer3D.body_add_shape(body, shape_rid, shape_xform)
			else:
				PhysicsServer3D.body_add_shape(body, shape_rid)
	else:
		push_warning(
			(
				"[PhysicsBodyBuilder] entity %s has physics block but no collision_shape — body is shapeless"
				% entity.instance_id
			)
		)

	# Collision layer + mask
	var layer_bits := _resolve_layer_mask(phys_cfg.get("collision_layer", "all"), layer_map)
	var mask_bits := _resolve_layer_mask(phys_cfg.get("collision_mask", "all"), layer_map)
	PhysicsServer3D.body_set_collision_layer(body, layer_bits)
	PhysicsServer3D.body_set_collision_mask(body, mask_bits)

	# Physics material (mass / friction / restitution / damping / gravity)
	if mode == PhysicsServer3D.BODY_MODE_RIGID:
		if phys_cfg.has("mass"):
			PhysicsServer3D.body_set_param(
				body, PhysicsServer3D.BODY_PARAM_MASS, float(phys_cfg["mass"])
			)
		if phys_cfg.has("friction"):
			PhysicsServer3D.body_set_param(
				body, PhysicsServer3D.BODY_PARAM_FRICTION, float(phys_cfg["friction"])
			)
		if phys_cfg.has("restitution"):
			PhysicsServer3D.body_set_param(
				body, PhysicsServer3D.BODY_PARAM_BOUNCE, float(phys_cfg["restitution"])
			)
		if phys_cfg.has("linear_damp"):
			PhysicsServer3D.body_set_param(
				body, PhysicsServer3D.BODY_PARAM_LINEAR_DAMP, float(phys_cfg["linear_damp"])
			)
		if phys_cfg.has("angular_damp"):
			PhysicsServer3D.body_set_param(
				body, PhysicsServer3D.BODY_PARAM_ANGULAR_DAMP, float(phys_cfg["angular_damp"])
			)
		if phys_cfg.has("gravity_scale"):
			PhysicsServer3D.body_set_param(
				body, PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE, float(phys_cfg["gravity_scale"])
			)

	# Set initial transform from entity.state.position
	var pos = entity.get_position() if entity.has_method("get_position") else null
	var transform := Transform3D()
	if pos is Vector3:
		transform.origin = pos
	elif pos is Vector2:
		transform.origin = Vector3(pos.x, 0, pos.y)
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, transform)

	# Stamp the entity with this body's RID so despawn can free it.
	entity.set_meta("_physics_body", body)

	return body


## Free a body created via build_3d / build_character_3d.
## Called by SpawnManager.despawn before queue_free.
##
## ADR 0045 Session A: dispatches on stored Variant type.
##   - RID (static/kinematic/rigid/area) → free attached shapes +
##     PhysicsServer3D.free_rid
##   - Node (character — a CharacterBody3D scene node) →
##     node.queue_free (Godot frees the body + its shape children)
static func free_3d(entity) -> void:
	if not entity.has_meta("_physics_body"):
		return
	var body = entity.get_meta("_physics_body")
	entity.remove_meta("_physics_body")
	if body is RID:
		var rid: RID = body
		if not rid.is_valid():
			return
		# Free shapes attached to the body
		var shape_count := PhysicsServer3D.body_get_shape_count(rid)
		for i in range(shape_count):
			var shape: RID = PhysicsServer3D.body_get_shape(rid, i)
			if shape.is_valid():
				PhysicsServer3D.free_rid(shape)
		# Free the body itself
		PhysicsServer3D.free_rid(rid)
	elif body is Node:
		(body as Node).queue_free()


# ============================================================
# ADR 0045 Session A — character body factory (CharacterBody3D Node)
# ============================================================


## Build a CharacterBody3D Node for a body_type:"character" entity.
## Unlike build_3d (which creates a raw PhysicsServer3D RID), this
## creates a scene-tree Node with its own _physics_process. The Node
## is added as a child of the Entity Node so it lives in the same
## spatial hierarchy as the rest of the scene.
##
## Stored in entity meta `_physics_body` (Variant: Node here, RID
## elsewhere). free_3d + sync_body_transform + sync_body_velocity all
## dispatch on the meta's type.
##
## Behavior wiring (read velocity → move_and_slide → write position)
## lands in Session B inside character_body_runner.gd::_physics_process.
## Session A's runner has an empty _physics_process, so this body
## does nothing yet — it's purely lifecycle plumbing.
static func build_character_3d(
	entity: Entity, phys_cfg: Dictionary, layer_map: Dictionary
) -> CharacterBody3D:
	var body := CharacterBodyRunner.new()
	body.name = "CharacterBody"
	body.bind(entity)

	# Collision shape — same vocabulary as build_3d (box/sphere/capsule/cylinder).
	var shape_cfg: Dictionary = phys_cfg.get("collision_shape", {})
	var shape_node := _build_collision_shape_node(shape_cfg)
	if shape_node != null:
		body.add_child(shape_node)

	# Collision layer/mask — translate name arrays via layer_map.
	body.collision_layer = _layer_mask(phys_cfg.get("collision_layer", []), layer_map)
	body.collision_mask = _layer_mask(phys_cfg.get("collision_mask", []), layer_map)

	# Floor-detection tuning (2026-05-30). Godot's CharacterBody3D defaults
	# break on stairs/uneven world meshes (ADR 0062):
	#   - floor_block_on_wall=true → touching a step's vertical riser (a
	#     "wall") cancels is_on_floor() → on_floor sticks at 0 → the
	#     jump-anim (gated on on_floor==0) loops + the body wedges.
	#   - floor_snap_length=0 → the body floats off / bounces down steps
	#     instead of sticking to the surface.
	# Sensible walkable defaults, all overridable per-entity via phys_cfg:
	body.floor_block_on_wall = bool(phys_cfg.get("floor_block_on_wall", false))
	body.floor_snap_length = float(phys_cfg.get("floor_snap_length", 0.5))
	body.floor_constant_speed = bool(phys_cfg.get("floor_constant_speed", true))
	body.floor_max_angle = deg_to_rad(float(phys_cfg.get("floor_max_angle_deg", 50.0)))

	# Initial transform from entity.state.position
	var pos = entity.get_position() if entity.has_method("get_position") else null
	if pos is Vector3:
		body.position = pos
	elif pos is Vector2:
		body.position = Vector3(pos.x, 0, pos.y)

	# Honor state.scale on the body's transform so its CollisionShape3D
	# child inherits the scale — same convention EntityMesh3D._sync_scale
	# applies to the visual mesh. Without this, a rabbit authored with
	# state.scale=0.35 renders as a 35cm bunny (mesh scaled) but collides
	# as if it were a full-sized animal (lib's capsule radius=0.35, height=
	# 0.8 — human-shaped hitbox). 2026-05-24.
	_apply_state_scale_to_body(body, entity)

	# Attach to the Entity Node so the body lives in the scene tree.
	entity.add_child(body)
	entity.set_meta("_physics_body", body)
	# ADR 0061 Phase 2.5: under an external tick driver (lockstep), motion must
	# be TICK-LOCKED, not free-running. Disable the body's _physics_process
	# (60Hz move_and_slide) so only the driver's per-tick tick_headless integrates
	# it — else peers drift by their differing physics-frame counts (and
	# move_and_slide collision is physics-server-nondeterministic). Generic seam.
	if Engine.has_meta("yume_external_tick_driver"):
		body.process_mode = Node.PROCESS_MODE_DISABLED
	return body


## Read state.scale and apply it to the body's transform.scale.
## Mirrors EntityMesh3D._sync_scale's parsing — accepts:
##   - float / int → uniform Vector3(s, s, s)
##   - Vector3     → per-axis
##   - Array[3]    → per-axis [x, y, z]
##   - Array[2]    → 2D-friendly (x, x, y), mirrors the iso convention
## Idempotent — leaves body.scale unchanged when state.scale isn't set.
static func _apply_state_scale_to_body(body: Node3D, entity: Entity) -> void:
	if entity == null or not entity.has_method("get_state"):
		return
	var s = entity.get_state("scale", null)
	if s == null:
		return
	if s is float or s is int:
		var f := float(s)
		body.scale = Vector3(f, f, f)
	elif s is Vector3:
		body.scale = s
	elif s is Array:
		var a := s as Array
		if a.size() == 3:
			body.scale = Vector3(float(a[0]), float(a[1]), float(a[2]))
		elif a.size() == 2:
			body.scale = Vector3(float(a[0]), float(a[0]), float(a[1]))


## Build a CollisionShape3D node from a shape config dict. Used by
## build_character_3d (CharacterBody3D needs shapes as scene-tree
## children, not as raw RIDs attached via PhysicsServer3D.body_add_shape).
##
## Capsule/cylinder shapes get an automatic vertical offset of
## height/2 so the shape's BASE sits at the body's transform.origin.
## Otherwise the capsule is centered on origin → feet end up below
## ground, mesh renders height/2 above floor after Godot pushes the
## body up. Yume convention: entity.position = feet-on-floor.
## 2026-05-24 — was the root cause of "character & collider have
## different offsets."
##
## Explicit shape_cfg.offset (Vector3-like list) overrides the auto-
## lift. Returns null if shape_cfg is empty / invalid.
##
## Shape dimensions come from one of two sources:
##   - shape_cfg.mesh (path to .glb): dimensions derived from mesh bbox
##     at build time. Author points at a primitive .glb (e.g. lib/assets/
##     meshes/primitive_humanoid_capsule.glb); engine reads the bbox and
##     fits the chosen shape type. Same mesh-derivation pattern as static
##     bodies use via properties.collision_mesh — no manual numbers.
##   - shape_cfg.{radius, height, size}: manual numeric values.
##     Used by lib templates that ship as the framework's primitive
##     numeric defaults (e.g. static_wall's box, rigid_projectile's
##     sphere). Game-specific entities should NOT author these directly
##     — point shape_cfg.mesh at a primitive instead.
static func _build_collision_shape_node(shape_cfg: Dictionary) -> CollisionShape3D:
	if shape_cfg.is_empty():
		return null
	var shape_type := str(shape_cfg.get("type", ""))
	# Resolve dimensions: mesh-derived bbox wins over numeric fields.
	var mesh_bbox: AABB = AABB()
	var has_mesh_bbox := false
	var mesh_path = shape_cfg.get("mesh", null)
	if mesh_path is String and mesh_path != "":
		mesh_bbox = _glb_bbox(mesh_path)
		has_mesh_bbox = mesh_bbox.size.length() > 0.0
	var shape: Shape3D = null
	var auto_lift_y := 0.0  # default: no auto-lift
	match shape_type:
		"box":
			var box := BoxShape3D.new()
			if has_mesh_bbox:
				box.size = mesh_bbox.size
			else:
				var size = shape_cfg.get("size", [1.0, 1.0, 1.0])
				box.size = Vec3Util.from_world_pos(size)
			shape = box
		"sphere":
			var sph := SphereShape3D.new()
			if has_mesh_bbox:
				sph.radius = max(mesh_bbox.size.x, mesh_bbox.size.z) / 2.0
			else:
				sph.radius = float(shape_cfg.get("radius", 0.5))
			shape = sph
			auto_lift_y = sph.radius  # ball sits on its bottom
		"capsule":
			var cap := CapsuleShape3D.new()
			if has_mesh_bbox:
				cap.radius = max(mesh_bbox.size.x, mesh_bbox.size.z) / 2.0
				cap.height = mesh_bbox.size.y
			else:
				cap.radius = float(shape_cfg.get("radius", 0.4))
				cap.height = float(shape_cfg.get("height", 1.8))
			shape = cap
			auto_lift_y = cap.height / 2.0  # capsule base at origin
		"cylinder":
			var cyl := CylinderShape3D.new()
			if has_mesh_bbox:
				cyl.radius = max(mesh_bbox.size.x, mesh_bbox.size.z) / 2.0
				cyl.height = mesh_bbox.size.y
			else:
				cyl.radius = float(shape_cfg.get("radius", 0.5))
				cyl.height = float(shape_cfg.get("height", 1.0))
			shape = cyl
			auto_lift_y = cyl.height / 2.0  # cylinder base at origin
		_:
			return null
	var node := CollisionShape3D.new()
	node.shape = shape
	# Explicit offset (3-element list) wins; otherwise auto-lift Y so
	# the shape's BASE sits at the body's transform.origin.
	var off = shape_cfg.get("offset", null)
	if off is Array and (off as Array).size() >= 3:
		node.position = Vector3(float(off[0]), float(off[1]), float(off[2]))
	elif auto_lift_y > 0.0:
		node.position = Vector3(0, auto_lift_y, 0)
	return node


## Convert a layer-name array to a Godot collision-mask bitfield.
## Mirrors the bit-set logic in build_3d's BODY-RID path.
static func _layer_mask(names, layer_map: Dictionary) -> int:
	var mask := 0
	if names is Array:
		for n in names:
			var bit_index := int(layer_map.get(str(n), 0))
			if bit_index >= 1 and bit_index <= 32:
				mask |= 1 << (bit_index - 1)
	elif str(names) == "all":
		mask = 0xFFFFFFFF
	return mask


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
	if (
		def.has("physics")
		and def["physics"] is Dictionary
		and not (def["physics"] as Dictionary).is_empty()
	):
		if "blocks_motion" in (def.get("tags", []) as Array):
			push_warning(
				(
					"[PhysicsBodyBuilder] entity def '%s' has BOTH `physics` block AND `blocks_motion` tag — `physics` block takes precedence; remove the tag to silence this warning"
					% str(def.get("id", "?"))
				)
			)
		return def["physics"]

	var has_tag := "blocks_motion" in (def.get("tags", []) as Array)
	if not has_tag:
		return {}

	var props: Dictionary = def.get("properties", {})
	var extents = props.get("aabb_extents", null)
	if not (extents is Array) or (extents as Array).is_empty():
		push_warning(
			(
				"[PhysicsBodyBuilder] entity def '%s' has `blocks_motion` tag but no `properties.aabb_extents` — cannot translate; skipping body creation. Add aabb_extents or a `physics` block."
				% str(def.get("id", "?"))
			)
		)
		return {}

	var ext_arr: Array = extents
	# aabb_offset shifts the collider center relative to entity
	# position. Required when the mesh isn't centered at the entity's
	# origin (Tripo3D meshes are bbox-centered, so a collider at
	# entity.position with no offset would sit half-underground).
	# The validator (tools/validators/validate_aabb_extents.py)
	# computes this from the .glb mesh bbox + state.scale +
	# visual.y_offset and writes it into every def. The engine
	# trusts that authored value verbatim — no defaults, no
	# heuristics. Defs without aabb_offset default to [0,0,0]
	# (purely zero state — engine never invents physics geometry).
	var offset_v = props.get("aabb_offset", [0, 0, 0])
	var off_arr: Array = offset_v if offset_v is Array else [0, 0, 0]
	# Detect 2D vs 3D from extents length
	# 3D: [hx, hy, hz] (3 components). 2D: [hx, hy] (2 components).
	if ext_arr.size() >= 3:
		var hx := float(ext_arr[0])
		var hy := float(ext_arr[1])
		var hz := float(ext_arr[2])
		var ox := float(off_arr[0]) if off_arr.size() >= 1 else 0.0
		var oy := float(off_arr[1]) if off_arr.size() >= 2 else 0.0
		var oz := float(off_arr[2]) if off_arr.size() >= 3 else 0.0
		return {
			"body_type": "static",
			"collision_shape": {
				"type": "box",
				"size": [hx * 2.0, hy * 2.0, hz * 2.0],
				"offset": [ox, oy, oz],
			},
			"collision_layer": ["wall"],
			"collision_mask": "all",
			"_translated_from": "blocks_motion+aabb_extents (3D)"
		}
	if ext_arr.size() == 2:
		var hx2 := float(ext_arr[0])
		var hy2 := float(ext_arr[1])
		return {
			"body_type": "static",
			"collision_shape": {"type": "box2d", "size": [hx2 * 2.0, hy2 * 2.0]},
			"collision_layer": ["wall"],
			"collision_mask": "all",
			"_translated_from": "blocks_motion+aabb_extents (2D)"
		}
	push_warning(
		(
			"[PhysicsBodyBuilder] entity def '%s' has aabb_extents with unexpected length %d"
			% [str(def.get("id", "?")), ext_arr.size()]
		)
	)
	return {}


# ============================================================
# INTERNAL
# ============================================================


static func _body_mode_3d(body_type: String) -> int:
	match body_type:
		"static":
			return PhysicsServer3D.BODY_MODE_STATIC
		"kinematic":
			return PhysicsServer3D.BODY_MODE_KINEMATIC
		"rigid":
			return PhysicsServer3D.BODY_MODE_RIGID
		"area":
			push_warning("[PhysicsBodyBuilder] body_type='area' not yet implemented — using static")
			return PhysicsServer3D.BODY_MODE_STATIC
		_:
			push_warning(
				"[PhysicsBodyBuilder] unknown body_type '%s' — defaulting to kinematic" % body_type
			)
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
			(
				PhysicsServer3D
				. shape_set_data(
					shape,
					{
						"radius": float(shape_cfg.get("radius", 0.4)),
						"height": float(shape_cfg.get("height", 1.0)),
					}
				)
			)
		"cylinder":
			shape = PhysicsServer3D.cylinder_shape_create()
			(
				PhysicsServer3D
				. shape_set_data(
					shape,
					{
						"radius": float(shape_cfg.get("radius", 0.4)),
						"height": float(shape_cfg.get("height", 1.0)),
					}
				)
			)
		"trimesh":
			# Concave (triangle-mesh) collision built from a .glb's faces —
			# for STATIC pre-authored world meshes (imported city/terrain)
			# where box/capsule can't approximate the geometry. Faces are in
			# the glb's NATIVE local space, so the entity must render the same
			# .glb with `visual.normalize: false` + scale 1 to align 1:1.
			# Concave shapes are static/kinematic-only (never rigid). ADR 0062.
			var mesh_path := str(shape_cfg.get("mesh", ""))
			var tris := _glb_trimesh_faces(mesh_path)
			if tris.size() >= 3:
				shape = PhysicsServer3D.concave_polygon_shape_create()
				PhysicsServer3D.shape_set_data(shape, {"faces": tris})
			else:
				push_warning(
					"[PhysicsBodyBuilder] trimesh: no faces extracted from '%s'"
					% mesh_path
				)
		_:
			push_warning("[PhysicsBodyBuilder] unsupported 3D shape type '%s'" % stype)
	return shape


## Extract ALL triangle vertices from a .glb's MeshInstance3D nodes, in
## the glb's native local space (each instance's transform relative to the
## scene root is applied). Returns a flat PackedVector3Array (3 verts per
## triangle) suitable for ConcavePolygonShape3D's `faces`. ADR 0062.
static func _glb_trimesh_faces(res_path: String) -> PackedVector3Array:
	var faces := PackedVector3Array()
	if res_path == "" or not ResourceLoader.exists(res_path):
		push_warning("[PhysicsBodyBuilder] trimesh mesh not found: '%s'" % res_path)
		return faces
	var packed = ResourceLoader.load(res_path)
	if not (packed is PackedScene):
		push_warning("[PhysicsBodyBuilder] trimesh source not a PackedScene: '%s'" % res_path)
		return faces
	var root := (packed as PackedScene).instantiate()
	_collect_trimesh_faces(root, Transform3D.IDENTITY, faces)
	root.free()
	return faces


static func _collect_trimesh_faces(node: Node, xform: Transform3D, faces: PackedVector3Array) -> void:
	var t := xform
	if node is Node3D:
		t = xform * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mesh_faces := (node as MeshInstance3D).mesh.get_faces()
		for v in mesh_faces:
			faces.push_back(t * v)
	for child in node.get_children():
		_collect_trimesh_faces(child, t, faces)


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
		for name in value as Array:
			var bit2 := int(layer_map.get(str(name), 0))
			if bit2 > 0:
				mask |= (1 << (bit2 - 1))
			else:
				push_warning("[PhysicsBodyBuilder] unknown collision layer name '%s'" % str(name))
		return mask
	return 0


static func _vec3_from(value) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and (value as Array).size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO


# ============================================================
# ADR 0044 Session B — state ↔ body sync
# ============================================================


## Mirror entity.state.position to the attached body. Called by
## Entity.set_position when a body is attached.
##
## ADR 0045 Session A: dispatches on stored Variant type.
##   - RID → PhysicsServer3D.body_set_state (kinematic gets a warp;
##     rigid same, with the non-physical caveat from ADR 0044
##     Condition 6).
##   - Node (CharacterBody3D) → node.global_position = v3.
static func sync_body_transform(entity) -> void:
	if not entity.has_meta("_physics_body"):
		return
	var body = entity.get_meta("_physics_body")
	var p = entity.get_position()
	var v3: Vector3
	if p is Vector3:
		v3 = p
	elif p is Vector2:
		v3 = Vector3(p.x, 0, p.y)
	else:
		return
	if body is RID:
		var rid: RID = body
		if not rid.is_valid():
			return
		var xform := Transform3D(Basis(), v3)
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, xform)
	elif body is Node3D:
		(body as Node3D).global_position = v3


## Mirror entity.state.velocity to the attached body. Called by
## Entity.set_velocity when a body is attached.
##
## ADR 0045 Session A: dispatches on stored Variant type.
##   - RID → PhysicsServer3D.body_set_state (linear velocity).
##   - Node (CharacterBody3D) → node.velocity = v3 (the Godot-owned
##     velocity field that move_and_slide consumes each tick).
static func sync_body_velocity(entity) -> void:
	if not entity.has_meta("_physics_body"):
		return
	var body = entity.get_meta("_physics_body")
	var v = entity.get_velocity()
	var v3: Vector3
	if v is Vector3:
		v3 = v
	elif v is Vector2:
		# Lift Vector2 (x, z-plane) to Vector3 with y from body's current
		# vertical velocity (2026-05-20, ADR 0055 follow-up for jump support).
		# CharacterBody3D's vertical velocity accumulates gravity / receives
		# jump impulses via character_body_runner._apply_vertical — wiping it
		# here would cancel gravity at every WASD-triggered sync, leaving the
		# player floating mid-air or unable to fall after a jump.
		var preserved_y: float = 0.0
		if body is CharacterBody3D:
			preserved_y = (body as CharacterBody3D).velocity.y
		v3 = Vector3(v.x, preserved_y, v.y)
	else:
		return
	if body is RID:
		var rid: RID = body
		if not rid.is_valid():
			return
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, v3)
	elif body is CharacterBody3D:
		(body as CharacterBody3D).velocity = v3


# ============================================================
# GLB BBOX PARSER — reads min/max from a .glb's POSITION accessors
# ============================================================
#
# Mirrors tools/validators/validate_aabb_extents.py::parse_glb_bbox.
# Pure GDScript — no Mesh resource instantiation (would require
# importing the scene + walking its children). The .glb header
# encodes POSITION accessor min/max directly, so we read them
# straight out of the JSON chunk.
#
# Used by _build_collision_shape_node when shape_cfg.mesh is a
# .glb path: bbox dimensions drive the chosen shape's radius / height
# / size, with NO manual numbers anywhere in the entity / lib def.

const _GLB_MAGIC := 0x46546C67  # "glTF"
const _GLB_CHUNK_JSON := 0x4E4F534A  # "JSON"
const _GLB_CHUNK_BIN := 0x004E4942  # "BIN\0"
static var _glb_bbox_cache: Dictionary = {}


## Read POSITION min/max from a .glb file. Returns an empty AABB
## (size = (0,0,0)) on parse failure. Cached by path so subsequent
## calls are O(1).
static func _glb_bbox(res_path: String) -> AABB:
	if _glb_bbox_cache.has(res_path):
		return _glb_bbox_cache[res_path]
	var aabb := _glb_bbox_uncached(res_path)
	_glb_bbox_cache[res_path] = aabb
	return aabb


static func _glb_bbox_uncached(res_path: String) -> AABB:
	if not FileAccess.file_exists(res_path):
		push_warning("[PhysicsBodyBuilder] collision_shape.mesh not found: %s" % res_path)
		return AABB()
	var f := FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return AABB()
	var magic := f.get_32()
	var _version := f.get_32()
	var _total_length := f.get_32()
	if magic != _GLB_MAGIC:
		push_warning("[PhysicsBodyBuilder] not a .glb file: %s" % res_path)
		return AABB()
	var json_chunk_length := f.get_32()
	var json_chunk_type := f.get_32()
	if json_chunk_type != _GLB_CHUNK_JSON:
		return AABB()
	var json_bytes := f.get_buffer(json_chunk_length)
	var json_text := json_bytes.get_string_from_utf8()
	var parser := JSON.new()
	if parser.parse(json_text) != OK:
		return AABB()
	var doc = parser.data
	if not (doc is Dictionary):
		return AABB()
	# Walk meshes[].primitives[].attributes.POSITION → accessors[N]
	var bbox_min := Vector3(INF, INF, INF)
	var bbox_max := Vector3(-INF, -INF, -INF)
	var found := false
	var meshes: Array = doc.get("meshes", [])
	var accessors: Array = doc.get("accessors", [])
	for m in meshes:
		var prims: Array = m.get("primitives", [])
		for p in prims:
			var attrs: Dictionary = p.get("attributes", {})
			var pos_idx = attrs.get("POSITION", null)
			if pos_idx == null or int(pos_idx) >= accessors.size():
				continue
			var acc: Dictionary = accessors[int(pos_idx)]
			var mn = acc.get("min", null)
			var mx = acc.get("max", null)
			if mn is Array and mx is Array and (mn as Array).size() >= 3 and (mx as Array).size() >= 3:
				bbox_min.x = min(bbox_min.x, float(mn[0]))
				bbox_min.y = min(bbox_min.y, float(mn[1]))
				bbox_min.z = min(bbox_min.z, float(mn[2]))
				bbox_max.x = max(bbox_max.x, float(mx[0]))
				bbox_max.y = max(bbox_max.y, float(mx[1]))
				bbox_max.z = max(bbox_max.z, float(mx[2]))
				found = true
	if not found:
		return AABB()
	return AABB(bbox_min, bbox_max - bbox_min)
