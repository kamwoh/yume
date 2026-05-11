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
var _mesh_cast_shadow: bool = true

# Entity reference + position sync
var _entity_ref: Entity = null

# ADR 0035 — per-entity animation interpreter (null when mesh has no
# `animations` block or when load-time validation failed).
var _animation_director: AnimationDirector = null

# Cached mesh library
static var _mesh_lib_cache: MeshLib = null


func _ready() -> void:
	var ent := get_parent() as Entity
	if ent == null:
		push_warning("EntityMesh3D requires an Entity parent")
		return
	_entity_ref = ent
	# ADR 0041 — engine-managed tag set by multimesh_director when this
	# entity is batched. Mark the renderer so the director can find +
	# remove it cleanly; skip the mesh-build path so we don't waste work
	# on nodes that'll be queue_freed in the same frame.
	set_meta("_yume_renderer", true)
	if ent.has_tag("_multimesh_managed"):
		return
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
		_apply_shadow_only_if_set(visual)
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
			_mesh_cast_shadow = bool(mesh_def.get("cast_shadow", true))
			_build_mesh_children()
			# ADR 0035 — instantiate animation director if mesh def declares
			# animations. Returns null for static meshes (backwards-compat).
			_animation_director = AnimationDirector.from_mesh_def(mesh_def, self, ent, {})
			_mode = "mesh"
			_apply_shadow_only_if_set(visual)
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
	_apply_shadow_only_if_set(visual)
	_sync_position()


## If `visual.hide_for_camera_attach=true`, recursively set all
## MeshInstance3D children to SHADOWS_ONLY — the mesh casts a shadow
## on the ground but doesn't render to any camera. Doom/CSGO viewmodel
## pattern: the player's own body is invisible from their first-person
## view (the viewmodel weapon overlay handles "what the player sees of
## themselves") but still has a presence on the ground for atmosphere.
func _apply_shadow_only_if_set(visual: Dictionary) -> void:
	if not bool(visual.get("hide_for_camera_attach", false)): return
	_set_shadow_only_recursive(self)


func _set_shadow_only_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		_set_shadow_only_recursive(child)


func _process(_dt: float) -> void:
	_sync_position()
	_sync_yaw()
	_sync_scale()
	# ADR 0035 — animate addressable mesh pieces per-frame.
	if _animation_director != null:
		_animation_director.tick(Time.get_ticks_msec() / 1000.0)


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


## Read state.scale if set. Accepts:
##   - float / int  → uniform scale (Vector3(s, s, s))
##   - Vector3      → per-axis scale
##   - Array [x,y,z] → per-axis scale
##   - Array [x,y]   → 2D — treated as (x, x, y) so the same authoring
##     works in iso views (x = horizontal, y = depth)
## Idempotent — when state.scale is unset, scale is left at (1,1,1).
## Used to vary tree size, prop sizes for visual density without
## authoring multiple mesh defs. Empirical case 2026-05-11: Aldenmere
## forest needed 2x-3x scale variation on trees for natural look.
func _sync_scale() -> void:
	if _entity_ref == null: return
	var s = _entity_ref.get_state("scale", null)
	if s == null: return
	if s is float or s is int:
		var f := float(s)
		scale = Vector3(f, f, f)
	elif s is Vector3:
		scale = s
	elif s is Array:
		var a := s as Array
		if a.size() == 3:
			scale = Vector3(float(a[0]), float(a[1]), float(a[2]))
		elif a.size() == 2:
			scale = Vector3(float(a[0]), float(a[0]), float(a[1]))


## Read state.yaw (radians, rotation around the Y axis) if set, and apply.
## Idempotent — when state.yaw is unset, rotation is left untouched, so
## existing data without yaw renders identically. Authoring use: instance
## overrides set `state: {yaw: 0.26}` (~15°) on cottages / props to break
## the strict-grid feel (visual-density axis 6 — diagonal accents).
func _sync_yaw() -> void:
	if _entity_ref == null: return
	var yaw = _entity_ref.get_state("yaw", null)
	if yaw == null: return
	rotation.y = float(yaw)


# ============================================================
# MESH PRIMITIVE INTERPRETER (W5.0a + W5.0b)
# ============================================================

func _build_mesh_children() -> void:
	# Shared helper — same primitive vocabulary used by game_shell viewmodels.
	# Mesh-def `cast_shadow: false` (default true) propagates as the default
	# for every primitive — per-primitive overrides still win. Used to skip
	# the shadow pass on grass / clouds / distant decoration where the
	# shadow contribution costs more than it visually adds.
	MeshLib.build_primitives_into(self, _mesh_primitives, _mesh_params, _mesh_cast_shadow)


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
