extends Node2D
class_name EntitySprite2D

## Renderer for Entity (2D). Three-tier fallback per W2.7a:
##   1. entity.visual.sprite_2d → load file (real asset)
##   2. entity.visual.shape → compose primitives from shapes.json
##   3. nothing → bare colored circle (entity.visual.color + radius)
##
## Position is synced from entity.state.position each frame, since the parent
## Entity is plain Node (no transform). Engine state mutates → renderer reads.

@export var fallback_color: Color = Color(0.7, 0.7, 0.7)
@export var fallback_radius: float = 8.0
## Path to shapes.json — loaded once per renderer instance, cached statically
## across instances.
@export var shapes_path: String = "res://data/shapes.json"

# Render mode: "texture", "shape", or "bare"
var _mode: String = "bare"

# Texture-mode state
var _texture: Texture2D = null

# Shape-mode state
var _shape_primitives: Array = []
var _shape_params: Dictionary = {}

# Bare-fallback state
var _color: Color = Color(0.7, 0.7, 0.7)
var _radius: float = 8.0

# Entity reference
var _entity_ref: Entity = null

# Visual flips horizontally when velocity.x is negative. Opt-in via
# entity.visual.flip_with_velocity. For directional sprites (fish, ships,
# characters) so they face where they're going.
var _flip_with_velocity: bool = false
# Last sign of velocity.x — kept so we don't snap-flip on x=0 (when stopped).
var _last_facing: int = 1

# Cached shape library (one load per process — re-used across renderers)
static var _shape_lib_cache: ShapeLib = null


func _ready() -> void:
	var ent := get_parent() as Entity
	if ent == null:
		push_warning("EntitySprite2D requires an Entity parent")
		return
	_entity_ref = ent
	var visual: Dictionary = ent.visual
	_flip_with_velocity = bool(visual.get("flip_with_velocity", false))

	# Tier 1 — real sprite asset
	var sprite_path := str(visual.get("sprite_2d", ""))
	if sprite_path != "" and ResourceLoader.exists(sprite_path):
		_texture = load(sprite_path)
		_mode = "texture"
		_sync_position()
		queue_redraw()
		return

	# Tier 2 — shape from library
	var shape_name := str(visual.get("shape", ""))
	if shape_name != "":
		var lib := _get_shape_lib()
		if lib.has(shape_name):
			var shape_def := lib.get_shape(shape_name)
			_shape_primitives = shape_def.get("primitives", [])
			_shape_params = ShapeLib.merge_params(
				shape_def,
				(visual.get("params", {}) as Dictionary)
			)
			_mode = "shape"
			_sync_position()
			queue_redraw()
			return

	# Tier 3 — bare fallback
	_color = _parse_color(visual.get("color", fallback_color))
	_radius = float(visual.get("radius", fallback_radius))
	_mode = "bare"
	_sync_position()
	queue_redraw()


func _process(_dt: float) -> void:
	_sync_position()
	if _flip_with_velocity:
		_sync_facing()


func _sync_position() -> void:
	if _entity_ref == null: return
	position = _entity_ref.get_planar_position()


## Mirror the sprite horizontally based on velocity.x sign. Hold last
## non-zero direction so the sprite doesn't snap back to default when
## the entity stops.
func _sync_facing() -> void:
	if _entity_ref == null: return
	var v = _entity_ref.get_velocity()
	var vx: float = 0.0
	if v is Vector2: vx = (v as Vector2).x
	elif v is Vector3: vx = (v as Vector3).x
	if absf(vx) > 0.01:
		_last_facing = 1 if vx >= 0 else -1
	# scale.x = +1 → default art (assumed facing right); -1 → mirrored.
	# Convention: art is drawn facing right; flip when moving west.
	scale.x = float(_last_facing)


func _draw() -> void:
	match _mode:
		"texture":
			if _texture != null:
				var size := _texture.get_size()
				draw_texture(_texture, -size * 0.5)
		"shape":
			_draw_shape_primitives()
		"bare":
			draw_circle(Vector2.ZERO, _radius, _color)


# ============================================================
# SHAPE INTERPRETER — engine's draw primitive vocabulary
# ============================================================

func _draw_shape_primitives() -> void:
	for p in _shape_primitives:
		if not (p is Dictionary): continue
		var op := str(p.get("op", ""))
		match op:
			"circle":
				var pos := _to_vec2(p.get("pos", [0, 0]))
				var radius := float(_param_resolve(p.get("radius", 5)))
				var color := _resolve_color(p.get("color", "#fff"))
				draw_circle(pos, radius, color)
			"rect":
				var pos := _to_vec2(p.get("pos", [0, 0]))
				var sz := _to_vec2(p.get("size", [10, 10]))
				var color := _resolve_color(p.get("color", "#fff"))
				draw_rect(Rect2(pos, sz), color)
			"polygon":
				var raw_points = p.get("points", [])
				var pts := PackedVector2Array()
				if raw_points is Array:
					for pt in raw_points:
						pts.append(_to_vec2(pt))
				var color := _resolve_color(p.get("color", "#fff"))
				var colors := PackedColorArray()
				for i in range(pts.size()):
					colors.append(color)
				draw_polygon(pts, colors)
			"line":
				var from_p := _to_vec2(p.get("from", [0, 0]))
				var to_p := _to_vec2(p.get("to", [10, 0]))
				var color := _resolve_color(p.get("color", "#fff"))
				var width := float(_param_resolve(p.get("width", 1)))
				draw_line(from_p, to_p, color, width)
			"text":
				# text rendering needs a Font resource — defer until W4+
				pass
			"texture":
				# composite-with-texture support deferred — Tier 1 (real sprite)
				# already covers this for whole-entity textures
				pass


# ============================================================
# PARAM RESOLUTION — `$name` references look up in merged params
# ============================================================

func _param_resolve(v):
	if v is String and (v as String).begins_with("$"):
		var key := (v as String).substr(1)
		return _shape_params.get(key, v)
	return v

func _resolve_color(v) -> Color:
	var resolved = _param_resolve(v)
	return _parse_color(resolved)


# ============================================================
# UTIL
# ============================================================

static func _to_vec2(v) -> Vector2:
	if v is Vector2: return v
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO

static func _parse_color(v) -> Color:
	if v is Color: return v
	if v is String: return Color(str(v))
	if v is Array and (v as Array).size() >= 3:
		return Color(float(v[0]), float(v[1]), float(v[2]),
			1.0 if (v as Array).size() < 4 else float(v[3]))
	return Color(0.7, 0.7, 0.7)


func _get_shape_lib() -> ShapeLib:
	if _shape_lib_cache == null:
		_shape_lib_cache = ShapeLib.load_from_file(shapes_path)
	return _shape_lib_cache
