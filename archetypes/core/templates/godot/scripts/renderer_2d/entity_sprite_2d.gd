extends Node2D
class_name EntitySprite2D

## Renderer component for Entity.
##
## Attaches as a child of an Entity Node2D. Reads `entity.visual.sprite_2d`.
## If the path resolves, draws that texture; otherwise draws a colored debug
## circle based on `visual.color` / `visual.radius`.
##
## Keeps rendering decoupled from simulation: the engine mutates state, the
## renderer reads position + visual and draws. Swap this for a different
## renderer (renderer_3d, ASCII, headless-noop) without touching engine code.

@export var fallback_color: Color = Color(0.7, 0.7, 0.7)
@export var fallback_radius: float = 8.0

var _texture: Texture2D = null
var _color: Color = Color(0.7, 0.7, 0.7)
var _radius: float = 8.0


func _ready() -> void:
	var ent := get_parent() as Entity
	if ent == null:
		push_warning("EntitySprite2D requires an Entity parent")
		return
	var visual: Dictionary = ent.visual
	var sprite_path := str(visual.get("sprite_2d", ""))
	if sprite_path != "" and ResourceLoader.exists(sprite_path):
		_texture = load(sprite_path)
	else:
		_color = _parse_color(visual.get("color", fallback_color))
		_radius = float(visual.get("radius", fallback_radius))
	queue_redraw()


func _process(_dt: float) -> void:
	# Redraw every frame so that state-driven visuals (color changes, burning
	# flicker, etc.) can update. Cheap — _draw only runs if queue_redraw fired.
	pass


func _draw() -> void:
	if _texture != null:
		var size := _texture.get_size()
		draw_texture(_texture, -size * 0.5)
	else:
		draw_circle(Vector2.ZERO, _radius, _color)


static func _parse_color(v) -> Color:
	if v is Color: return v
	if v is String: return Color(str(v))
	if v is Array and (v as Array).size() >= 3:
		return Color(float(v[0]), float(v[1]), float(v[2]), 1.0 if (v as Array).size() < 4 else float(v[3]))
	return Color(0.7, 0.7, 0.7)
