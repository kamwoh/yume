extends Node3D
class_name EntityMesh3D

## 3D renderer for Entity (W5.0a). Mirrors entity_sprite_2d.gd's three-tier
## fallback for 3D:
##   1. entity.visual.model_3d → load .glb / .gltf / .scn / .tscn
##   2. entity.visual.mesh → compose primitives from meshes.json
##   3. nothing → bare colored box (entity.visual.color + size)
##
## Position is synced from entity.state.position (Vector2 or Vector3) each
## frame. 2D positions get lifted to XZ plane (Y=0) per W5.0 coordinate
## convention. Same data contract as the 2D renderer — engine doesn't change.

@export var fallback_color: Color = Color(0.7, 0.7, 0.7)
@export var fallback_size: float = 0.5
@export var meshes_path: String = "res://data/meshes.json"
## Scale entity.state.position into world-units. Engine uses pixel-scale
## positions (~200 unit demos); 3D scenes typically have entities ~1m apart.
## With position_scale=0.05, 200 pixels → 10 world units.
@export var position_scale: float = 0.05

# Render mode: "model", "mesh", or "bare"
var _mode: String = "bare"

# Mesh-mode state
var _mesh_primitives: Array = []
var _mesh_params: Dictionary = {}

# Entity reference + position sync
var _entity_ref: Entity = null

# Cached mesh library
static var _mesh_lib_cache: MeshLib = null


func _ready() -> void:
	var ent := get_parent() as Entity
	if ent == null:
		push_warning("EntityMesh3D requires an Entity parent")
		return
	_entity_ref = ent
	var visual: Dictionary = ent.visual

	# Tier 1 — real model file
	var model_path := str(visual.get("model_3d", ""))
	if model_path != "" and ResourceLoader.exists(model_path):
		var packed = load(model_path)
		if packed is PackedScene:
			add_child((packed as PackedScene).instantiate())
		elif packed is Mesh:
			var mi := MeshInstance3D.new()
			mi.mesh = packed
			add_child(mi)
		_mode = "model"
		_sync_position()
		return

	# Tier 2 — mesh from library (compose primitives). Falls back to
	# visual.shape if no explicit visual.mesh — convenient for shared data
	# files where 2D shape names match 3D mesh names by convention.
	var mesh_name := str(visual.get("mesh", visual.get("shape", "")))
	if mesh_name != "":
		var lib := _get_mesh_lib()
		if lib.has(mesh_name):
			var mesh_def := lib.get_mesh(mesh_name)
			_mesh_primitives = mesh_def.get("primitives", [])
			_mesh_params = MeshLib.merge_params(
				mesh_def,
				(visual.get("params", {}) as Dictionary)
			)
			_build_mesh_children()
			_mode = "mesh"
			_sync_position()
			return

	# Tier 3 — bare colored box
	var color := _parse_color(visual.get("color", fallback_color))
	var size := float(visual.get("size", fallback_size))
	var mi_box := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(size, size, size)
	mi_box.mesh = box
	mi_box.material_override = _make_material(color)
	add_child(mi_box)
	_mode = "bare"
	_sync_position()


func _process(_dt: float) -> void:
	_sync_position()


# ============================================================
# POSITION SYNC — engine state → 3D transform
# ============================================================

func _sync_position() -> void:
	if _entity_ref == null: return
	var p = _entity_ref.get_position()
	if p is Vector3:
		position = p * position_scale
	elif p is Vector2:
		# 2D position → XZ plane, Y=0 (W5.0 coordinate convention).
		# Scale applies because the same data files are authored in 2D pixel
		# units; 3D scenes scale them down to fit world-unit conventions.
		position = Vector3(p.x, 0, p.y) * position_scale


# ============================================================
# MESH PRIMITIVE INTERPRETER (W5.0a + W5.0b)
# ============================================================

func _build_mesh_children() -> void:
	for p in _mesh_primitives:
		if not (p is Dictionary): continue
		var op := str(p.get("op", ""))
		var mesh: Mesh = null
		match op:
			"box":
				var size := _to_vec3(_param_resolve(p.get("size", [1, 1, 1])))
				var m := BoxMesh.new()
				m.size = size
				mesh = m
			"sphere":
				var r := float(_param_resolve(p.get("radius", 0.5)))
				var m := SphereMesh.new()
				m.radius = r
				m.height = r * 2.0
				mesh = m
			"cylinder":
				var r := float(_param_resolve(p.get("radius", 0.3)))
				var h := float(_param_resolve(p.get("height", 1.0)))
				var m := CylinderMesh.new()
				m.top_radius = r
				m.bottom_radius = r
				m.height = h
				mesh = m
			"capsule":
				var r := float(_param_resolve(p.get("radius", 0.3)))
				var h := float(_param_resolve(p.get("height", 1.0)))
				var m := CapsuleMesh.new()
				m.radius = r
				m.height = h
				mesh = m
			"plane":
				var sz := _to_vec2(_param_resolve(p.get("size", [1, 1])))
				var m := PlaneMesh.new()
				m.size = sz
				mesh = m
			"prism":
				var sz := _to_vec3(_param_resolve(p.get("size", [1, 1, 1])))
				var m := PrismMesh.new()
				m.size = sz
				mesh = m
			"torus":
				var inner := float(_param_resolve(p.get("inner_radius", 0.3)))
				var outer := float(_param_resolve(p.get("outer_radius", 0.5)))
				var m := TorusMesh.new()
				m.inner_radius = inner
				m.outer_radius = outer
				mesh = m
			"quad":
				var sz := _to_vec2(_param_resolve(p.get("size", [1, 1])))
				var m := QuadMesh.new()
				m.size = sz
				mesh = m
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = _make_material(_resolve_color(p.get("color", "#fff")))
		var pos := _to_vec3(_param_resolve(p.get("pos", [0, 0, 0])))
		mi.position = pos
		# Optional rotation in degrees (Vector3) — handle simple case
		if p.has("rotation_deg"):
			var rd := _to_vec3(p["rotation_deg"])
			mi.rotation_degrees = rd
		add_child(mi)


# ============================================================
# PARAM RESOLUTION — `$name` references
# ============================================================

func _param_resolve(v):
	if v is String and (v as String).begins_with("$"):
		var key := (v as String).substr(1)
		return _mesh_params.get(key, v)
	return v

func _resolve_color(v) -> Color:
	var resolved = _param_resolve(v)
	return _parse_color(resolved)


# ============================================================
# UTIL
# ============================================================

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


func _get_mesh_lib() -> MeshLib:
	if _mesh_lib_cache == null:
		_mesh_lib_cache = MeshLib.load_from_file(meshes_path)
	return _mesh_lib_cache
