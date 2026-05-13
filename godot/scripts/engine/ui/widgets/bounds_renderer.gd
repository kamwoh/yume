extends RefCounted
class_name BoundsRenderer

## Renders the 2D-demo bounds visuals — Polygon2D floor + Line2D border —
## from scene.json's `bounds` block. Optional day/night floor tint binding
## lerps the floor color each frame based on a world-state value (typically
## clock.sunlight).
##
## Owned by GameShell. RefCounted with a back-ref so build_bounds() can
## add nodes as children of the shell (CanvasItem-inheriting siblings of
## entities; render at z_index -50 / -49 under content).
##
## Per-frame: GameShell._process calls update_floor_tint().
##
## No-op when scene.json has no `bounds` block (3D demos, single-room
## scenes, etc.).


var _shell: Node = null  # GameShell back-ref
var _floor: Polygon2D = null
var _floor_tint_bind: String = ""
var _floor_color_low: Color = Color.BLACK
var _floor_color_high: Color = Color.WHITE


func _init(shell: Node) -> void:
	_shell = shell


## Build the floor + border once at startup. No-op when scene.json has no
## `bounds` block. Reads colors / extents from the bounds dict; supports
## the day/night `floor_color_day` + `floor_color_night` + `floor_tint_binding`
## triple for dynamic tinting.
func build(scene_cfg: Dictionary) -> void:
	var b: Dictionary = scene_cfg.get("bounds", {}) as Dictionary
	if b.is_empty():
		return
	var lo: Vector2 = _to_vec2(b.get("min", [-300, -200]))
	var hi: Vector2 = _to_vec2(b.get("max", [300, 200]))

	# Add bounds as our own children — they render in the default world canvas
	# regardless of parent (CanvasItem inheritance), and we avoid touching
	# World during its _ready (which Godot rejects with "parent busy").
	if b.has("floor_color") or b.has("floor_color_day"):
		var floor := Polygon2D.new()
		floor.polygon = PackedVector2Array(
			[
				Vector2(lo.x, lo.y),
				Vector2(hi.x, lo.y),
				Vector2(hi.x, hi.y),
				Vector2(lo.x, hi.y),
			]
		)
		floor.color = _color(b.get("floor_color_day", b.get("floor_color", "#222")))
		floor.z_index = -50
		_shell.add_child(floor)
		_floor = floor
		# Optional: tint floor by a state binding (e.g. clock.sunlight) — lerps
		# between floor_color_night (low) and floor_color_day (high) per frame.
		if b.has("floor_tint_binding"):
			_floor_tint_bind = str(b["floor_tint_binding"])
			_floor_color_high = _color(b.get("floor_color_day", "#3a8090"))
			_floor_color_low = _color(b.get("floor_color_night", "#0a0820"))

	if b.has("border_color"):
		var border := Line2D.new()
		border.points = PackedVector2Array(
			[
				Vector2(lo.x, lo.y),
				Vector2(hi.x, lo.y),
				Vector2(hi.x, hi.y),
				Vector2(lo.x, hi.y),
				Vector2(lo.x, lo.y),
			]
		)
		border.width = float(b.get("border_width", 4))
		border.default_color = _color(b["border_color"])
		border.joint_mode = Line2D.LINE_JOINT_BEVEL
		border.z_index = -49
		_shell.add_child(border)


## Lerp the floor color between night (low) and day (high) based on the
## binding value (expected 0..1, e.g. clock.sunlight). No-op if no binding
## was configured in scene.json.
func update_floor_tint() -> void:
	if _floor == null or _floor_tint_bind == "":
		return
	var v = _shell.call("_resolve_binding", _floor_tint_bind)
	if v == null:
		return
	var t: float = clamp(float(v), 0.0, 1.0)
	_floor.color = _floor_color_low.lerp(_floor_color_high, t)


## Local hex/array → Color helper. Mirrors GameShell._color but kept
## independent so this widget doesn't depend on the shell for color parsing.
static func _color(v) -> Color:
	if v is Color:
		return v
	if v is String:
		return Color(v as String)
	return Color.WHITE


## Local Vec2 coercion. Same shape as Vec3Util.from_world_pos but for 2D.
static func _to_vec2(v) -> Vector2:
	if v is Vector2:
		return v
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO
