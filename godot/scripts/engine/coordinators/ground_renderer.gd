extends RefCounted
class_name GroundRenderer

## Builds the floor mesh — MeshInstance3D + PlaneMesh + StandardMaterial3D —
## from scene.json's `ground.mesh` block. Lets a 3D game declare its ground
## plane as JSON instead of hand-rolling a Node in the per-game .tscn.
##
## Schema (in scene.json):
##
##   "ground": {
##     "y": 0,                       // existing — sim ground primitive
##     "clamp_tags": ["creature"],   // existing
##     "despawn_tags": ["projectile"],
##     "mesh": {                     // new — visual plane
##       "size": [400, 400],         // width, depth in meters
##       "color": "#6b5c42",         // albedo hex or [r,g,b,a]
##       "roughness": 0.92,
##       "metallic": 0.0
##     }
##   }
##
## If `ground.mesh` is absent, no ground is rendered (fine for abstract
## puzzles, overlay-only games). If a Ground MeshInstance3D already exists
## as a World child (legacy per-game .tscn), GroundRenderer does nothing —
## the .tscn-provided one takes precedence.

var _world: Node = null


func _init(world: Node) -> void:
	_world = world


## Read scene.json, find ground.mesh, build the plane. Called once from
## WorldBoot during the boot sequence. Idempotent (skips if ground node
## already exists).
func build() -> void:
	# Adopt-and-skip: if a static Ground MeshInstance3D was placed in the
	# per-game .tscn, respect it. Author chose explicitly.
	for child in _world.get_children():
		if child is MeshInstance3D and (child as Node).name == "Ground":
			return

	var cfg := _read_mesh_cfg()
	if cfg.is_empty():
		return

	var size_arr: Array = cfg.get("size", [400, 400])
	var w := float(size_arr[0]) if size_arr.size() >= 1 else 400.0
	var d := float(size_arr[1]) if size_arr.size() >= 2 else w
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(w, d)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = _color(cfg.get("color", "#808080"))
	mat.roughness = float(cfg.get("roughness", 0.9))
	mat.metallic = float(cfg.get("metallic", 0.0))

	var node := MeshInstance3D.new()
	node.name = "Ground"
	node.mesh = mesh
	node.material_override = mat
	_world.add_child(node)


## Read scene.json's `ground.mesh` block. Returns {} if the file or block
## is absent. Same JSON-loading pattern as LightingDirector._load_config.
func _read_mesh_cfg() -> Dictionary:
	var root := str(_world.get("data_root")).rstrip("/")
	if root == "":
		return {}
	var path := root + "/scene.json"
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		return {}
	var ground = (data as Dictionary).get("ground", null)
	if not (ground is Dictionary):
		return {}
	var mesh_cfg = (ground as Dictionary).get("mesh", null)
	if not (mesh_cfg is Dictionary):
		return {}
	return mesh_cfg


static func _color(v) -> Color:
	if v is Color:
		return v
	if v is String:
		return Color(v as String)
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		var alpha: float = float(a[3]) if a.size() >= 4 else 1.0
		return Color(float(a[0]), float(a[1]), float(a[2]), alpha)
	return Color.WHITE
