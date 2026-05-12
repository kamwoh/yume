extends RefCounted
class_name ShapeLib

## Config-driven shape library (W2.7a).
##
## Engine knows DRAW PRIMITIVES only: circle, rect, polygon, line, text,
## texture. Shapes are JSON compositions of these primitives with $param
## substitution. Adding a new shape ("lantern", "bush", "scarecrow") is a
## JSON edit; engine code never changes.
##
## Honors invariant #8: engine = primitives + interpreter. The verb set is
## fixed in code; the noun catalog (specific shapes) lives in data/shapes.json.
##
## Schema (data/shapes.json):
##   {
##     "shapes": {
##       "tree": {
##         "primitives": [
##           {"op": "circle", "pos": [0, -8], "radius": 10, "color": "$foliage"},
##           {"op": "rect",   "pos": [-2, 0], "size": [4, 8], "color": "$trunk"}
##         ],
##         "params": {"foliage": "#3a8a3a", "trunk": "#6b3a1a"}
##       }
##     }
##   }
##
## Per-entity override:
##   entity.visual = {"shape": "tree", "params": {"foliage": "#5fa53d"}}
## entity.visual.params merges over shape.params at draw time.

var shapes: Dictionary = {}  # name → {primitives: Array, params: Dictionary}


static func load_from_file(path: String, env: Dictionary = {}) -> ShapeLib:
	var lib := ShapeLib.new()
	if not FileAccess.file_exists(path):
		(
			EngineError
			. raise(
				env,
				EngineError.SHAPE_FILE_MISSING,
				"ShapeLib: no file at %s" % path,
				{"file": path},
				"Drop a shapes.json file at this path, or omit the shape lib if you want plain colored circles.",
				"warning"
			)
		)
		return lib
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		EngineError.raise(
			env,
			EngineError.SHAPE_INVALID_JSON,
			"ShapeLib: invalid JSON in %s" % path,
			{"file": path},
			'Top-level must be a JSON object: {"shapes": {"name": {"primitives": [...]}}}.'
		)
		return lib
	var raw: Dictionary = data.get("shapes", {})
	for k in raw.keys():
		var def = raw[k]
		if def is Dictionary:
			lib.shapes[str(k)] = def
	return lib


func has(name: String) -> bool:
	return shapes.has(name)


## Returns the shape def Dictionary {primitives: Array, params: Dictionary},
## or empty dict if not found.
func get_shape(name: String) -> Dictionary:
	return shapes.get(name, {})


## Resolve params for an instance: shape's defaults overridden by
## entity-supplied params. Used by renderer to fill `$key` references.
static func merge_params(shape_def: Dictionary, instance_params: Dictionary) -> Dictionary:
	var out: Dictionary = (shape_def.get("params", {}) as Dictionary).duplicate()
	for k in instance_params.keys():
		out[k] = instance_params[k]
	return out
