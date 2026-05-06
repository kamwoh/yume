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

var meshes: Dictionary = {}            # name → {primitives: Array, params: Dictionary}

static func load_from_file(path: String, env: Dictionary = {}) -> MeshLib:
	var lib := MeshLib.new()
	if not FileAccess.file_exists(path):
		EngineError.raise(env, EngineError.MESH_FILE_MISSING,
			"MeshLib: no file at %s" % path,
			{"file": path},
			"Drop a meshes.json file at this path, or omit the mesh lib if you want bare cubes.",
			"warning")
		return lib
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		EngineError.raise(env, EngineError.MESH_INVALID_JSON,
			"MeshLib: invalid JSON in %s" % path,
			{"file": path},
			"Top-level must be a JSON object: {\"meshes\": {\"name\": {\"primitives\": [...]}}}.")
		return lib
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


## Build primitive children under `parent`. Used by entity_mesh_3d.gd
## (entity rendering) AND game_shell.gd (FPS viewmodel rendering — same
## mesh-primitive vocabulary, different host nodes). Centralizes the
## op-dispatch so adding a new primitive (e.g. arrow, ring) only needs
## one change here.
static func build_primitives_into(parent: Node3D, primitives: Array, params: Dictionary) -> void:
	for p in primitives:
		if not (p is Dictionary): continue
		var op := str(p.get("op", ""))
		var mesh: Mesh = null
		match op:
			"box":
				var size := _to_vec3(_param_resolve(p.get("size", [1, 1, 1]), params))
				var m := BoxMesh.new()
				m.size = size
				mesh = m
			"sphere":
				var r := float(_param_resolve(p.get("radius", 0.5), params))
				var m := SphereMesh.new()
				m.radius = r
				m.height = r * 2.0
				mesh = m
			"cylinder":
				var r := float(_param_resolve(p.get("radius", 0.3), params))
				var h := float(_param_resolve(p.get("height", 1.0), params))
				var m := CylinderMesh.new()
				m.top_radius = r
				m.bottom_radius = r
				m.height = h
				mesh = m
			"capsule":
				var r := float(_param_resolve(p.get("radius", 0.3), params))
				var h := float(_param_resolve(p.get("height", 1.0), params))
				var m := CapsuleMesh.new()
				m.radius = r
				m.height = h
				mesh = m
			"plane":
				var sz := _to_vec2(_param_resolve(p.get("size", [1, 1]), params))
				var m := PlaneMesh.new()
				m.size = sz
				mesh = m
			"prism":
				var sz := _to_vec3(_param_resolve(p.get("size", [1, 1, 1]), params))
				var m := PrismMesh.new()
				m.size = sz
				mesh = m
			"torus":
				var inner := float(_param_resolve(p.get("inner_radius", 0.3), params))
				var outer := float(_param_resolve(p.get("outer_radius", 0.5), params))
				var m := TorusMesh.new()
				m.inner_radius = inner
				m.outer_radius = outer
				mesh = m
			"quad":
				var sz := _to_vec2(_param_resolve(p.get("size", [1, 1]), params))
				var m := QuadMesh.new()
				m.size = sz
				mesh = m
		if mesh == null: continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = _make_material(_parse_color(_param_resolve(p.get("color", "#fff"), params)))
		var pos := _to_vec3(_param_resolve(p.get("pos", [0, 0, 0]), params))
		mi.position = pos
		if p.has("rotation_deg"):
			var rd := _to_vec3(p["rotation_deg"])
			mi.rotation_degrees = rd
		parent.add_child(mi)


static func _param_resolve(v, params: Dictionary):
	if v is String and (v as String).begins_with("$"):
		var key := (v as String).substr(1)
		return params.get(key, v)
	return v


static func _to_vec3(v) -> Vector3:
	if v is Vector3: return v
	if v is Vector2: return Vector3(v.x, v.y, 0)
	if v is Array:
		var a := v as Array
		if a.size() >= 3: return Vector3(float(a[0]), float(a[1]), float(a[2]))
		if a.size() == 2: return Vector3(float(a[0]), float(a[1]), 0)
	if v is float or v is int:
		return Vector3(float(v), float(v), float(v))
	return Vector3.ZERO


static func _to_vec2(v) -> Vector2:
	if v is Vector2: return v
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	if v is float or v is int:
		return Vector2(float(v), float(v))
	return Vector2.ONE


static func _parse_color(v) -> Color:
	if v is Color: return v
	if v is String: return Color(str(v))
	if v is Array and (v as Array).size() >= 3:
		return Color(float(v[0]), float(v[1]), float(v[2]),
			1.0 if (v as Array).size() < 4 else float(v[3]))
	return Color(0.7, 0.7, 0.7)


static func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat
