extends Control
class_name MinimapWidget

## A small top-down map widget. Draws a square Control with entities
## from `world.entities` rendered as colored dots, projected from
## world coordinates into widget pixel space.
##
## Authoring: in hud.json, place a `{"type": "minimap"}` element with:
##   size           — [w, h] in pixels (default [180, 180])
##   world_bounds   — [x_min, z_min, x_max, z_max] in world units. Maps
##                    the rectangle to the widget's full extent. If
##                    omitted, auto-computed from min/max entity X/Z
##                    each frame (cheap but jittery).
##   background     — hex string, fill color (default "#0c0a08")
##   border         — hex string, perimeter outline (default "#807060")
##   tag_colors     — dict {tag → "#hex"}. First-matching tag wins;
##                    entities matching no tag are skipped.
##   player_tag     — entity tag whose centroid draws bigger + on top
##                    (default "player")
##   dot_radius     — pixel radius for normal entities (default 2.0)
##   player_radius  — pixel radius for player marker (default 4.0)
##
## Per-frame: game_shell calls update_world(world) once at build, then
## the widget reads world.entities each _draw cycle. queue_redraw()
## fires once per frame from game_shell._update_bound_elements.
##
## Why this primitive, not a 3D camera-on-canvas: a real minimap-camera
## would need a second viewport, RenderTarget setup, layer culling. A
## drawn-dot widget is ~30 lines, fits the engine's "primitives +
## interpreter" stance, and reads as a top-down summary which is what
## minimaps are FOR. Cost: doesn't show terrain detail. Benefit: works
## across all camera modes + games for free.
##
## Empirical case 2026-05-09: pendrel city is 320m × 320m but player
## frustum is ~25m × 25m at iso ortho_size 24. Without a minimap,
## players got lost — couldn't see where the shop / fountain / dungeon
## portal were relative to their position. Added in HUD top-right.

var _world: Node = null
var _world_bounds: Array = []  # [x_min, z_min, x_max, z_max], or empty for auto
var _background: Color = Color("#0c0a08")
var _border: Color = Color("#807060")
var _tag_colors: Dictionary = {}  # tag → Color
var _ordered_tags: Array = []  # iteration order for first-match
var _player_tag: String = "player"
var _dot_radius: float = 2.0
var _player_radius: float = 4.0


## Configure from a JSON spec dict.
func configure(cfg: Dictionary) -> void:
	var size_raw = cfg.get("size", [180, 180])
	if size_raw is Array and (size_raw as Array).size() == 2:
		custom_minimum_size = Vector2(float(size_raw[0]), float(size_raw[1]))
	if cfg.has("world_bounds"):
		var b = cfg["world_bounds"]
		if b is Array and (b as Array).size() == 4:
			_world_bounds = [float(b[0]), float(b[1]), float(b[2]), float(b[3])]
	_background = _color(cfg.get("background", "#0c0a08"))
	_border = _color(cfg.get("border", "#807060"))
	var tc = cfg.get("tag_colors", {})
	if tc is Dictionary:
		# Preserve insertion order so authors control first-match precedence
		for k in tc as Dictionary:
			var key := str(k)
			_ordered_tags.append(key)
			_tag_colors[key] = _color((tc as Dictionary)[k])
	_player_tag = str(cfg.get("player_tag", "player"))
	_dot_radius = float(cfg.get("dot_radius", 2.0))
	_player_radius = float(cfg.get("player_radius", 4.0))


## Pass the live World reference. Called once by HUD wiring.
func bind_world(world: Node) -> void:
	_world = world


## Trigger a redraw — called by game_shell each frame.
func tick() -> void:
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, custom_minimum_size)
	# Background
	draw_rect(rect, _background, true)
	# Border
	draw_rect(rect, _border, false, 1.5)
	if _world == null:
		return
	var entities = _world.get("entities")
	if not (entities is Dictionary):
		return
	# Resolve world bounds — auto-fit if not configured
	var bounds := _resolve_bounds(entities)
	if bounds.is_empty():
		return
	var x_min: float = bounds[0]
	var z_min: float = bounds[1]
	var x_max: float = bounds[2]
	var z_max: float = bounds[3]
	var w: float = max(x_max - x_min, 0.001)
	var h: float = max(z_max - z_min, 0.001)
	# Pass 1: non-player entities
	var player_pos = null
	for inst_id in entities as Dictionary:
		var ent = (entities as Dictionary)[inst_id]
		if ent == null or not ent.has_method("get_planar_position"):
			continue
		var pp: Vector2 = ent.get_planar_position()
		var px := (pp.x - x_min) / w * custom_minimum_size.x
		var py := (pp.y - z_min) / h * custom_minimum_size.y
		if ent.has_tag(_player_tag):
			player_pos = Vector2(px, py)
			continue
		var color = _color_for_entity(ent)
		if color == null:
			continue
		draw_circle(Vector2(px, py), _dot_radius, color)
	# Pass 2: player on top, brighter + bigger
	if player_pos != null:
		var pc: Color = _tag_colors.get(_player_tag, Color("#ffd040"))
		draw_circle(player_pos, _player_radius, pc)


## First-matching tag from _ordered_tags wins. Author controls precedence
## by ordering the dict in hud.json (e.g., "named_npc" before "actor").
func _color_for_entity(ent: Node):
	for tag in _ordered_tags:
		if ent.has_tag(tag):
			return _tag_colors[tag]
	return null


## Compute auto-fit bounds from entity X/Z ranges. Cheaper than scanning
## the entire world each frame (caches first computation), but jitters
## as entities spawn / despawn near the edge — author should pass
## explicit world_bounds for stability.
func _resolve_bounds(entities: Dictionary) -> Array:
	if _world_bounds.size() == 4:
		return _world_bounds
	var x_min := INF
	var z_min := INF
	var x_max := -INF
	var z_max := -INF
	for inst_id in entities:
		var ent = entities[inst_id]
		if ent == null or not ent.has_method("get_planar_position"):
			continue
		var pp: Vector2 = ent.get_planar_position()
		x_min = min(x_min, pp.x)
		z_min = min(z_min, pp.y)
		x_max = max(x_max, pp.x)
		z_max = max(z_max, pp.y)
	if x_min == INF:
		return []
	# Pad by 5% on each side
	var pad_x := (x_max - x_min) * 0.05
	var pad_z := (z_max - z_min) * 0.05
	return [x_min - pad_x, z_min - pad_z, x_max + pad_x, z_max + pad_z]


static func _color(v) -> Color:
	if v is Color:
		return v
	if v is String:
		return Color(str(v))
	return Color.WHITE
