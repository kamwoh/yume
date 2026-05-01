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

static func load_from_file(path: String) -> MeshLib:
	var lib := MeshLib.new()
	if not FileAccess.file_exists(path):
		push_warning("MeshLib: no file at " + path)
		return lib
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		push_error("MeshLib: invalid JSON in " + path)
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
