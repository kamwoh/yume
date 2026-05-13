extends RefCounted
class_name ViewmodelDirector

## First-person viewmodel — Doom/CSGO-style "weapon in hand" rendering.
##
## Configured via scene.json's camera.viewmodel block:
##
##   "viewmodel": {
##     "follow_state": "current_weapon",
##     "offset": [0.3, -0.25, -0.5],
##     "weapons": {
##       "1": {"mesh": "viewmodel_plasma"},
##       "2": {"mesh": "viewmodel_shotgun"},
##       "3": {"mesh": "viewmodel_rocket"}
##     }
##   }
##
## Each weapon's mesh is built once on first call to setup() (idempotent
## — re-calls are no-ops once root exists). Runtime swap just toggles
## visibility based on the actor's `follow_state` field value.
##
## Mesh hangs in camera-local space (added as child of CameraDirector's
## Camera3D). Inherits camera rotation, so as the player looks around
## the weapon swings with the view.
##
## Owned by GameShell. CameraDirector's FP camera handler calls
## viewmodel.setup() + viewmodel.update(actor, cam_cfg) each FP frame.

var _shell: Node = null  # GameShell back-ref
var _root: Node3D = null  # parent Node3D under Camera3D
var _meshes: Dictionary = {}  # str(state value) → Node3D


func _init(shell: Node) -> void:
	_shell = shell


## Lazy build. First call wires the viewmodel root under the Camera3D and
## creates one Node3D mesh per declared weapon. Subsequent calls no-op.
## Called from CameraDirector's FP camera each frame.
func setup(cam_cfg: Dictionary) -> void:
	if _root != null:
		return
	var camera3d = _camera3d()
	if camera3d == null:
		return
	var vm_cfg = cam_cfg.get("viewmodel", null)
	if not (vm_cfg is Dictionary):
		return
	var weapons = vm_cfg.get("weapons", null)
	if not (weapons is Dictionary) or weapons.is_empty():
		return
	_root = Node3D.new()
	_root.name = "Viewmodel"
	camera3d.add_child(_root)
	var offset_arr: Array = vm_cfg.get("offset", [0.3, -0.25, -0.5])
	if offset_arr.size() >= 3:
		_root.position = Vector3(float(offset_arr[0]), float(offset_arr[1]), float(offset_arr[2]))
	var lib := MeshLib.load_from_file("res://data/meshes.json")
	for key in weapons.keys():
		var w = weapons[key]
		if not (w is Dictionary):
			continue
		var mesh_name := str(w.get("mesh", ""))
		if mesh_name == "" or not lib.has(mesh_name):
			continue
		var mesh_def := lib.get_mesh(mesh_name)
		var mesh_node := Node3D.new()
		mesh_node.name = "vm_%s" % str(key)
		mesh_node.visible = false
		var params: Dictionary = MeshLib.merge_params(mesh_def, w.get("params", {}) as Dictionary)
		MeshLib.build_primitives_into(mesh_node, mesh_def.get("primitives", []), params)
		_root.add_child(mesh_node)
		_meshes[str(key)] = mesh_node


## Per-frame visibility update. Reads actor's `follow_state` field and shows
## the matching weapon mesh; hides all others. No-op if setup hasn't run
## yet (no viewmodel config in scene.json).
func update(actor, cam_cfg: Dictionary) -> void:
	if _root == null:
		return
	var vm_cfg = cam_cfg.get("viewmodel", null)
	if not (vm_cfg is Dictionary):
		return
	var follow_state := str(vm_cfg.get("follow_state", ""))
	if follow_state == "" or actor == null:
		return
	var current_v = (actor as Entity).get_state(follow_state, "")
	# Coerce numeric state values to string for dict lookup
	var current := str(int(current_v)) if current_v is int or current_v is float else str(current_v)
	for key in _meshes:
		(_meshes[key] as Node3D).visible = (str(key) == current)


## Camera3D accessor — reads through the shell's CameraDirector. Used
## once on first setup() to parent the viewmodel root.
func _camera3d() -> Camera3D:
	var cd = _shell.get("_camera_director")
	if cd == null:
		return null
	return cd.get("_camera3d")
