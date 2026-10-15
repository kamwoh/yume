extends RefCounted
class_name MeshLib

## Config-driven 3D mesh library (W5.0b). Mirrors ShapeLib's structure for 2D.
##
## Engine knows MESH PRIMITIVES only: box, sphere, cylinder, capsule, plane,
## prism, torus, quad — Godot's built-in PrimitiveMesh classes. Compositions
## of these primitives live in `data/meshes.json` with $param substitution.
##
## Schema (data/meshes.json):
##   {
##     "meshes": {
##       "tree": {
##         "primitives": [
##           {"op": "cylinder", "pos": [0, 0.4, 0], "size": [0.15, 0.8], "color": "$trunk"},
##           {"op": "sphere",   "pos": [0, 1.0, 0], "size": [0.5],        "color": "$foliage"}
##         ],
##         "params": {"foliage": "#3a8a3a", "trunk": "#6b3a1a"}
##       }
##     }
##   }
##
## Per-entity override:
##   entity.visual = {"mesh": "tree", "params": {"foliage": "#5fa53d"}}
##
## ADR 0083: a top-level `materials` block names shared materials:
##   "materials": {"iron": {"color": "#4a4a4f", "roughness": 0.4, "metallic": 0.8}}
## A part uses `"material": "iron"`, or inline `color`, `roughness`,
## `metallic`, `emission`, `emission_energy`. bake() merges the static
## parts by material key into shared ArrayMeshes.

var meshes: Dictionary = {}  # name → {primitives: Array, params: Dictionary}


static func load_from_file(path: String, env: Dictionary = {}) -> MeshLib:
	var lib := MeshLib.new()
	if not FileAccess.file_exists(path):
		EngineError.raise(
			env,
			EngineError.MESH_FILE_MISSING,
			"MeshLib: no file at %s" % path,
			{"file": path},
			"Drop a meshes.json file at this path, or omit the mesh lib if you want bare cubes.",
			"warning"
		)
		return lib
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		EngineError.raise(
			env,
			EngineError.MESH_INVALID_JSON,
			"MeshLib: invalid JSON in %s" % path,
			{"file": path},
			'Top-level must be a JSON object: {"meshes": {"name": {"primitives": [...]}}}.'
		)
		return lib
	named_materials = data.get("materials", {}) as Dictionary
	var raw: Dictionary = data.get("meshes", {})
	for k in raw.keys():
		var def = raw[k]
		if def is Dictionary:
			lib.meshes[str(k)] = def
	return lib


func has(name: String) -> bool:
	return meshes.has(name)


func get_mesh(name: String) -> Dictionary:
	return meshes.get(name, {})


static func merge_params(mesh_def: Dictionary, instance_params: Dictionary) -> Dictionary:
	var out: Dictionary = (mesh_def.get("params", {}) as Dictionary).duplicate()
	for k in instance_params.keys():
		out[k] = instance_params[k]
	return out


## ADR 0083 — bake cache. The key is the exact text of every input: the
## primitives, the params, the flags and the `materials` block. So a change
## to any of them makes a new entry, and two inputs never share a key.
## Least-recently-used entries go first when the cache is full.
const BAKE_CACHE_MAX := 512
static var _bake_cache: Dictionary = {}  # key -> bake result
static var _bake_order: Array = []  # keys, oldest first
## ADR 0083 — one shared material instance per material key.
static var _material_cache: Dictionary = {}  # key -> StandardMaterial3D
## ADR 0083 — the `materials` block of the last loaded meshes.json.
static var named_materials: Dictionary = {}
## ADR 0083 F3 — ops that only Godot CSG can build.
const CSG_OPS := ["lathe", "extrude", "sweep"]
## ADR 0083 F3 — baked CSG groups. Key: exact text of the group's parts,
## the params and the `materials` block. Oldest entries go first.
static var _csg_cache: Dictionary = {}  # key -> ArrayMesh
static var _csg_order: Array = []


## Build the mesh children of `primitives` under `parent`. All 5 build paths
## use this: entity_mesh_3d, viewmodel_director, yume_scene_preview,
## asset_preview, and (through bake()) multimesh_director.
##
## Static parts merge into at most two baked meshes (shadow casters and
## the rest). A part with `name` or `pivot` stays its own node, so the
## AnimationDirector can address it (ADR 0035).
##
## `cast_shadow_default` applies to every primitive unless the primitive
## itself has `"cast_shadow": <bool>`.
##
## ADR 0083 F3: a CSG group bakes one frame late. Until then the plain parts
## show. Then the baked mesh nodes change, and `on_rebuilt` (if valid) gets
## the new MeshInstance3D nodes, so a caller can paint them again.
static func build_primitives_into(
	parent: Node3D, primitives: Array, params: Dictionary, cast_shadow_default: bool = true,
	on_rebuilt: Callable = Callable()
) -> void:
	var baked := bake(primitives, params, cast_shadow_default, true)
	var nodes := _add_baked_nodes(parent, baked)
	for p in baked["separate"]:
		_add_part_node(parent, p, params, cast_shadow_default)
	if not (baked["pending"] as Array).is_empty():
		_rebuild_after_warm(parent, nodes, baked["pending"], primitives, params,
			cast_shadow_default, on_rebuilt)


static func _add_baked_nodes(parent: Node3D, baked: Dictionary) -> Array:
	var nodes: Array = []
	for entry in baked["meshes"]:
		var mi := MeshInstance3D.new()
		mi.mesh = entry["mesh"]
		if not bool(entry["cast_shadow"]):
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)
		nodes.append(mi)
	return nodes


static func _rebuild_after_warm(
	parent: Node3D, old_nodes: Array, pending: Array, primitives: Array, params: Dictionary,
	cast_shadow_default: bool, on_rebuilt: Callable
) -> void:
	await warm(pending)
	if not is_instance_valid(parent):
		return
	var full := bake(primitives, params, cast_shadow_default, true)
	if not (full["pending"] as Array).is_empty():
		push_warning("mesh_lib: CSG bake failed; the mesh shows its plain parts only")
		return
	for n in old_nodes:
		if is_instance_valid(n):
			parent.remove_child(n)
			n.queue_free()
	var nodes := _add_baked_nodes(parent, full)
	if on_rebuilt.is_valid():
		on_rebuilt.call(nodes)


## ADR 0083 F3 — bake the CSG groups in `pending` (from bake()["pending"])
## into the CSG cache. Godot fills a CSG mesh one frame late (F1 spike), so
## this awaits one process_frame. The CSG nodes stay out of the scene tree.
static func warm(pending: Array) -> void:
	var roots: Array = []
	for g in pending:
		if not _csg_cache.has(g["key"]):
			roots.append([g["key"], _build_csg_root(g["parts"], g["params"])])
	if roots.is_empty():
		return
	await (Engine.get_main_loop() as SceneTree).process_frame
	for r in roots:
		var root: CSGShape3D = r[1]
		var m := root.bake_static_mesh()
		if m != null and m.get_surface_count() > 0:
			_csg_cache[r[0]] = _indexed(m)
			_csg_order.append(r[0])
			if _csg_order.size() > BAKE_CACHE_MAX:
				_csg_cache.erase(_csg_order.pop_front())
		root.free()


## A copy of `m` with an index array on every surface. bake_static_mesh()
## returns surfaces without indices, and the Godot primitives have them.
## SurfaceTool.append_from() keeps only the indexed triangles when the two
## kinds mix, so an unindexed CSG part in a shared surface did not draw.
## Empirical case 2026-10-15: a swept pipe merged with an iron base box.
static func _indexed(m: ArrayMesh) -> ArrayMesh:
	var out := ArrayMesh.new()
	for s in m.get_surface_count():
		var st := SurfaceTool.new()
		st.create_from(m, s)
		st.index()
		st.commit(out)
		out.surface_set_material(s, m.surface_get_material(s))
	return out


## The CSG groups of a part list: {group name: [parts]}. A group is CSG when
## a part has `csg` or a CSG op. A CSG op with no `group` is its own group.
static func csg_groups(primitives: Array) -> Dictionary:
	var named: Dictionary = {}
	var out: Dictionary = {}
	for i in primitives.size():
		var p = primitives[i]
		if not (p is Dictionary):
			continue
		var g := str(p.get("group", ""))
		if g == "":
			if str(p.get("op", "")) in CSG_OPS:
				out["_part%d" % i] = [p]
			continue
		if not named.has(g):
			named[g] = []
		(named[g] as Array).append(p)
	for g in named.keys():
		for p in named[g]:
			if p.has("csg") or str(p.get("op", "")) in CSG_OPS:
				out[g] = named[g]
				break
	return out


## ADR 0083 — bake `primitives` into shared ArrayMeshes, merged by material
## key. Returns {"meshes": [{"mesh": ArrayMesh, "cast_shadow": bool}],
## "separate": [part dicts], "aabb": AABB}. The result is cached. Callers
## must not change the returned meshes or their materials. Duplicate first.
##
## `keep_named` true keeps parts with `name` or `pivot` out of the merge.
## The MultiMesh director passes false: its meshes have no animations.
static func bake(
	primitives: Array, params: Dictionary, cast_shadow_default: bool = true,
	keep_named: bool = true
) -> Dictionary:
	var key := var_to_str([primitives, params, cast_shadow_default, keep_named, named_materials])
	if _bake_cache.has(key):
		_bake_order.erase(key)
		_bake_order.append(key)
		return _bake_cache[key]
	# group key = "<shadow>|<material key>" -> SurfaceTool
	var tools: Dictionary = {}
	var group_mats: Dictionary = {}
	var separate: Array = []
	var pending: Array = []
	# Indices of the parts that CSG builds. (Not dict keys: Godot hashes a
	# Dictionary key by content, so two equal parts would collide.)
	var in_csg: Dictionary = {}
	var groups := csg_groups(primitives)
	for gname in groups.keys():
		var parts: Array = groups[gname]
		for i in primitives.size():
			for p in parts:
				if is_same(primitives[i], p):
					in_csg[i] = true
		var ckey := var_to_str([parts, params, named_materials])
		if not _csg_cache.has(ckey):
			pending.append({"key": ckey, "parts": parts, "params": params})
			continue
		var cm: ArrayMesh = _csg_cache[ckey]
		var cs0 := bool((parts[0] as Dictionary).get("cast_shadow", cast_shadow_default))
		for s in cm.get_surface_count():
			var smat := cm.surface_get_material(s)
			var mk = "csg%d" % s if smat == null else smat.get_meta("_mesh_lib_key", "csg%d" % s)
			var gk := "%s|%s" % [cs0, mk]
			if not tools.has(gk):
				tools[gk] = SurfaceTool.new()
				group_mats[gk] = smat
			(tools[gk] as SurfaceTool).append_from(cm, s, Transform3D.IDENTITY)
	for i in primitives.size():
		var p = primitives[i]
		if not (p is Dictionary) or in_csg.has(i):
			continue
		if keep_named and (p.has("name") or p.has("pivot")):
			separate.append(p)
			continue
		var mesh := _primitive_mesh(p, params)
		if mesh == null:
			continue
		var mat_key := material_key(p, params)
		var cs := bool(p.get("cast_shadow", cast_shadow_default))
		var gk := "%s|%s" % [cs, mat_key]
		if not tools.has(gk):
			tools[gk] = SurfaceTool.new()
			group_mats[gk] = material_for(p, params)
		(tools[gk] as SurfaceTool).append_from(mesh, 0, part_transform(p, params))
	var by_shadow := {true: null, false: null}
	for gk in tools.keys():
		var cs: bool = str(gk).begins_with("true")
		if by_shadow[cs] == null:
			by_shadow[cs] = ArrayMesh.new()
		var am: ArrayMesh = by_shadow[cs]
		(tools[gk] as SurfaceTool).commit(am)
		am.surface_set_material(am.get_surface_count() - 1, group_mats[gk])
	var meshes: Array = []
	var aabb := AABB()
	var first := true
	for cs in [true, false]:
		if by_shadow[cs] == null:
			continue
		var am: ArrayMesh = by_shadow[cs]
		meshes.append({"mesh": am, "cast_shadow": cs})
		aabb = am.get_aabb() if first else aabb.merge(am.get_aabb())
		first = false
	var result := {"meshes": meshes, "separate": separate, "aabb": aabb, "pending": pending}
	# A result with pending CSG groups is partial: never cache it.
	if not pending.is_empty():
		return result
	_bake_cache[key] = result
	_bake_order.append(key)
	if _bake_order.size() > BAKE_CACHE_MAX:
		_bake_cache.erase(_bake_order.pop_front())
	return result


## Drop all baked meshes and shared materials. Tests use it. A meshes.json
## reload does not need it: the key holds the full text of the inputs.
static func clear_caches() -> void:
	_bake_cache.clear()
	_bake_order.clear()
	_material_cache.clear()
	_csg_cache.clear()
	_csg_order.clear()


static func bake_cache_size() -> int:
	return _bake_cache.size()


## The local transform of one part: `rotation_deg` (Node3D YXZ order), then
## `pos`. Both accept `$param` values.
static func part_transform(p: Dictionary, params: Dictionary) -> Transform3D:
	var pos := _to_vec3(_param_resolve(p.get("pos", [0, 0, 0]), params))
	var b := Basis()
	if p.has("rotation_deg"):
		var rd := _to_vec3(_param_resolve(p["rotation_deg"], params))
		b = Basis.from_euler(Vector3(deg_to_rad(rd.x), deg_to_rad(rd.y), deg_to_rad(rd.z)))
	return Transform3D(b, pos)


## The resolved material fields of one part. A `material` name loads its
## entry from the `materials` block. Inline fields win over that entry.
static func _material_fields(p: Dictionary, params: Dictionary) -> Dictionary:
	var f: Dictionary = {}
	var mname = _param_resolve(p.get("material", ""), params)
	if str(mname) != "":
		if not named_materials.has(str(mname)):
			push_warning("mesh_lib: unknown material '%s' (not in the materials block)" % mname)
		f = (named_materials.get(str(mname), {}) as Dictionary).duplicate()
	for k in ["color", "roughness", "metallic", "emission", "emission_energy"]:
		if p.has(k):
			f[k] = _param_resolve(p[k], params)
	return f


## ADR 0083 — the material key: color, roughness, metallic, emission and
## emission energy. Parts with the same key share one material instance.
static func material_key(p: Dictionary, params: Dictionary) -> String:
	var f := _material_fields(p, params)
	var col := _parse_color(f.get("color", "#fff")).to_html()
	var em := "-"
	if f.has("emission"):
		em = "%s*%s" % [_parse_color(f["emission"]).to_html(), float(f.get("emission_energy", 1.0))]
	return "%s|r%s|m%s|e%s" % [
		col, float(f.get("roughness", 1.0)), float(f.get("metallic", 0.0)), em
	]


## The shared material for a part's key. Callers must not change it.
static func material_for(p: Dictionary, params: Dictionary) -> StandardMaterial3D:
	var key := material_key(p, params)
	if _material_cache.has(key):
		return _material_cache[key]
	var f := _material_fields(p, params)
	var mat := _make_material(_parse_color(f.get("color", "#fff")))
	mat.roughness = float(f.get("roughness", 1.0))
	mat.metallic = float(f.get("metallic", 0.0))
	# ADR 0072 — optional emissive primitive ("the lamp is ON").
	if f.has("emission"):
		mat.emission_enabled = true
		mat.emission = _parse_color(f["emission"])
		mat.emission_energy_multiplier = float(f.get("emission_energy", 1.0))
	# Lets bake() find the key of a CSG surface's material.
	mat.set_meta("_mesh_lib_key", key)
	_material_cache[key] = mat
	return mat


## The Godot PrimitiveMesh for one part, or null for an unknown op.
static func _primitive_mesh(p: Dictionary, params: Dictionary) -> Mesh:
	match str(p.get("op", "")):
		"box":
			var m := BoxMesh.new()
			m.size = _to_vec3(_param_resolve(p.get("size", [1, 1, 1]), params))
			return m
		"sphere":
			var r := float(_param_resolve(p.get("radius", 0.5), params))
			var m := SphereMesh.new()
			m.radius = r
			m.height = r * 2.0
			return m
		"cylinder":
			var r := float(_param_resolve(p.get("radius", 0.3), params))
			var m := CylinderMesh.new()
			m.top_radius = r
			m.bottom_radius = r
			m.height = float(_param_resolve(p.get("height", 1.0), params))
			return m
		"capsule":
			var m := CapsuleMesh.new()
			m.radius = float(_param_resolve(p.get("radius", 0.3), params))
			m.height = float(_param_resolve(p.get("height", 1.0), params))
			return m
		"plane":
			var m := PlaneMesh.new()
			m.size = _to_vec2(_param_resolve(p.get("size", [1, 1]), params))
			return m
		"prism":
			var m := PrismMesh.new()
			m.size = _to_vec3(_param_resolve(p.get("size", [1, 1, 1]), params))
			return m
		"torus":
			var m := TorusMesh.new()
			m.inner_radius = float(_param_resolve(p.get("inner_radius", 0.3), params))
			m.outer_radius = float(_param_resolve(p.get("outer_radius", 0.5), params))
			return m
		"quad":
			var m := QuadMesh.new()
			m.size = _to_vec2(_param_resolve(p.get("size", [1, 1]), params))
			return m
	return null


## ADR 0083 F3 — the CSG tree of one group, out of the scene tree. A cut
## part takes the material of the group's first part (F1: a cut with no
## material adds a surface for the faces of the hole).
static func _build_csg_root(parts: Array, params: Dictionary) -> CSGCombiner3D:
	var root := CSGCombiner3D.new()
	var base_mat := material_for(parts[0], params)
	for i in parts.size():
		var p: Dictionary = parts[i]
		var node := _csg_node(p, params, root, i)
		if node == null:
			continue
		node.set("material", base_mat if p.has("csg") else material_for(p, params))
		match str(p.get("csg", "")):
			"subtract":
				node.operation = CSGShape3D.OPERATION_SUBTRACTION
			"intersect":
				node.operation = CSGShape3D.OPERATION_INTERSECTION
		var xf := part_transform(p, params)
		if str(p.get("op", "")) == "extrude":
			# Godot extrudes along -Z. Center the depth on `pos`.
			var depth := float(_param_resolve(p.get("depth", 0.1), params))
			xf = xf * Transform3D(Basis(), Vector3(0, 0, depth * 0.5))
		node.transform = xf
		root.add_child(node)
		if node is CSGPolygon3D and (node as CSGPolygon3D).mode == CSGPolygon3D.MODE_PATH:
			(node as CSGPolygon3D).path_node = NodePath("../SweepPath%d" % i)
	return root


static func _csg_node(p: Dictionary, params: Dictionary, root: Node3D, i: int) -> CSGShape3D:
	var op := str(p.get("op", ""))
	match op:
		"box":
			var n := CSGBox3D.new()
			n.size = _to_vec3(_param_resolve(p.get("size", [1, 1, 1]), params))
			return n
		"sphere":
			var n := CSGSphere3D.new()
			n.radius = float(_param_resolve(p.get("radius", 0.5), params))
			n.radial_segments = 32
			n.rings = 16
			return n
		"cylinder":
			var n := CSGCylinder3D.new()
			n.radius = float(_param_resolve(p.get("radius", 0.3), params))
			n.height = float(_param_resolve(p.get("height", 1.0), params))
			n.sides = 24
			return n
		"torus":
			var n := CSGTorus3D.new()
			n.inner_radius = float(_param_resolve(p.get("inner_radius", 0.3), params))
			n.outer_radius = float(_param_resolve(p.get("outer_radius", 0.5), params))
			return n
		"capsule", "prism":
			var n := CSGMesh3D.new()
			n.mesh = _primitive_mesh(p, params)
			return n
		"lathe":
			var n := CSGPolygon3D.new()
			n.mode = CSGPolygon3D.MODE_SPIN
			n.spin_degrees = 360.0
			n.spin_sides = maxi(3, int(_param_resolve(p.get("segments", 16), params)))
			n.polygon = _closed_profile(_param_resolve(p.get("profile", []), params))
			# A lathe is a curved surface: shade it smooth, as a SphereMesh is.
			n.smooth_faces = true
			return n
		"extrude":
			var n := CSGPolygon3D.new()
			n.mode = CSGPolygon3D.MODE_DEPTH
			n.depth = float(_param_resolve(p.get("depth", 0.1), params))
			n.polygon = _vec2_array(_param_resolve(p.get("polygon", []), params))
			return n
		"sweep":
			var path := Path3D.new()
			path.name = "SweepPath%d" % i
			var curve := Curve3D.new()
			for pt in _param_resolve(p.get("path", []), params):
				curve.add_point(_to_vec3(pt))
			path.curve = curve
			root.add_child(path)
			var n := CSGPolygon3D.new()
			n.mode = CSGPolygon3D.MODE_PATH
			n.path_rotation = CSGPolygon3D.PATH_ROTATION_PATH_FOLLOW
			n.path_local = true
			n.path_interval_type = CSGPolygon3D.PATH_INTERVAL_DISTANCE
			n.path_interval = float(_param_resolve(p.get("interval", 0.05), params))
			n.polygon = _vec2_array(_param_resolve(p.get("polygon", []), params))
			n.smooth_faces = true
			return n
	push_warning("mesh_lib: op '%s' cannot be in a CSG group" % op)
	return null


## A lathe profile closed along the Y axis: adds [0, y_first] and
## [0, y_last] when the ends are off the axis.
static func _closed_profile(profile) -> PackedVector2Array:
	var pts := _vec2_array(profile)
	if pts.is_empty():
		return pts
	if pts[0].x != 0.0:
		pts.insert(0, Vector2(0, pts[0].y))
	if pts[pts.size() - 1].x != 0.0:
		pts.append(Vector2(0, pts[pts.size() - 1].y))
	return pts


static func _vec2_array(v) -> PackedVector2Array:
	var out := PackedVector2Array()
	if v is Array:
		for pt in v:
			out.append(_to_vec2(pt))
	return out


## One addressable part (`name` and/or `pivot`) as its own node.
static func _add_part_node(
	parent: Node3D, p: Dictionary, params: Dictionary, cast_shadow_default: bool
) -> void:
	var mesh := _primitive_mesh(p, params)
	if mesh == null:
		return
	var op := str(p.get("op", ""))
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material_for(p, params)
	var xf := part_transform(p, params)
	mi.basis = xf.basis
	if not bool(p.get("cast_shadow", cast_shadow_default)):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Optional `pivot` — offset from pos to the rotation joint. Accepts:
	#   - Vec3 / array: explicit offset, e.g. [0, 0.275, 0]
	#   - "top": auto-derives to [0, height/2, 0] for cylinder/capsule
	#     primitives. Lets authors say "shoulder/hip joint" without
	#     spelling out the math.
	# When present, the addressable piece becomes a Node3D AT THE JOINT
	# and the mesh hangs below at -pivot. Animation rotation pivots
	# around the joint (shoulder/hip) instead of the mesh's geometric
	# center. Without pivot, the MeshInstance3D itself is the named
	# piece (rotation pivots around mesh center).
	var pivot_v = p.get("pivot", null)
	if pivot_v != null:
		var pivot: Vector3
		if pivot_v is String and str(pivot_v) == "top":
			# Auto-derive from height. Cylinder/capsule have explicit
			# height; other prims have no canonical "top" — warn + skip.
			if op == "cylinder" or op == "capsule":
				var h_resolved := float(_param_resolve(p.get("height", 1.0), params))
				pivot = Vector3(0, h_resolved * 0.5, 0)
			else:
				push_warning("mesh_lib: pivot='top' only supported for cylinder/capsule; got '%s'" % op)
				pivot = Vector3.ZERO
		else:
			pivot = _to_vec3(pivot_v)
		var node := Node3D.new()
		node.position = xf.origin + pivot
		if p.has("name"):
			node.name = str(p["name"])
		mi.position = -pivot
		node.add_child(mi)
		parent.add_child(node)
	else:
		mi.position = xf.origin
		# ADR 0035 — optional `name` makes the primitive addressable by
		# AnimationDirector via parent.find_child(piece_name, ...).
		if p.has("name"):
			mi.name = str(p["name"])
		parent.add_child(mi)


static func _param_resolve(v, params: Dictionary):
	if v is String and (v as String).begins_with("$"):
		var key := (v as String).substr(1)
		return params.get(key, v)
	return v


static func _to_vec3(v) -> Vector3:
	if v is Vector3:
		return v
	if v is Vector2:
		return Vector3(v.x, v.y, 0)
	if v is Array:
		var a := v as Array
		if a.size() >= 3:
			return Vector3(float(a[0]), float(a[1]), float(a[2]))
		if a.size() == 2:
			return Vector3(float(a[0]), float(a[1]), 0)
	if v is float or v is int:
		return Vector3(float(v), float(v), float(v))
	return Vector3.ZERO


static func _to_vec2(v) -> Vector2:
	if v is Vector2:
		return v
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	if v is float or v is int:
		return Vector2(float(v), float(v))
	return Vector2.ONE


static func _parse_color(v) -> Color:
	if v is Color:
		return v
	if v is String:
		return Color(str(v))
	if v is Array and (v as Array).size() >= 3:
		return Color(
			float(v[0]), float(v[1]), float(v[2]), 1.0 if (v as Array).size() < 4 else float(v[3])
		)
	return Color(0.7, 0.7, 0.7)


static func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat
