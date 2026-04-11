extends Control

## HP Bar — shows player and nearby enemy health.
## Positioned at top-left of screen.

var bar_width: float = 200.0
var bar_height: float = 16.0
var margin: float = 10.0

var color_bg := Color(0.15, 0.15, 0.15, 0.8)
var color_hp := Color(0.2, 0.8, 0.2)
var color_hp_low := Color(0.9, 0.2, 0.2)
var color_hp_mid := Color(0.9, 0.7, 0.1)
var color_border := Color(0.4, 0.4, 0.4, 0.6)
var color_text := Color(1, 1, 1)
var color_enemy_hp := Color(0.9, 0.3, 0.2)


func _ready() -> void:
	position = Vector2(margin, margin)
	size = Vector2(bar_width + 20, 100)
	z_index = 100
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var y_offset: float = 0.0

	# Player HP
	var player = get_tree().get_first_node_in_group("player")
	if player:
		var hp: float = player.get("current_hp") if player.get("current_hp") != null else 100.0
		var max_hp: float = player.get("max_hp") if player.get("max_hp") != null else 100.0
		_draw_bar("Player", hp, max_hp, y_offset, color_hp)
		y_offset += bar_height + 20.0

	# Nearest enemy HP (if in range)
	var nearest_enemy: Node = null
	var nearest_dist: float = 999.0
	if player:
		for entity in get_tree().get_nodes_in_group("enemy"):
			if entity.get("is_dead"):
				continue
			var dist: float = player.global_position.distance_to(entity.global_position)
			if dist < 10.0 and dist < nearest_dist:
				nearest_dist = dist
				nearest_enemy = entity

	if nearest_enemy:
		var ehp: float = nearest_enemy.get("current_hp") if nearest_enemy.get("current_hp") != null else 0.0
		var emax: float = nearest_enemy.get("max_hp") if nearest_enemy.get("max_hp") != null else 1.0
		var ename: String = str(nearest_enemy.get("entity_name")) if nearest_enemy.get("entity_name") != null else "Enemy"
		_draw_bar(ename, ehp, emax, y_offset, color_enemy_hp)


func _draw_bar(label: String, current: float, maximum: float, y: float, bar_color: Color) -> void:
	var pct: float = clamp(current / max(maximum, 0.01), 0.0, 1.0)

	# Choose color based on HP percentage
	var fill_color: Color = bar_color
	if pct < 0.25:
		fill_color = color_hp_low
	elif pct < 0.5:
		fill_color = color_hp_mid

	# Label
	draw_string(ThemeDB.fallback_font, Vector2(0, y + 12), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color_text)

	# Background
	var bar_y: float = y + 16
	draw_rect(Rect2(Vector2(0, bar_y), Vector2(bar_width, bar_height)), color_bg)

	# Fill
	draw_rect(Rect2(Vector2(0, bar_y), Vector2(bar_width * pct, bar_height)), fill_color)

	# Border
	draw_rect(Rect2(Vector2(0, bar_y), Vector2(bar_width, bar_height)), color_border, false, 1.0)

	# HP text
	var hp_text: String = "%d / %d" % [int(current), int(maximum)]
	draw_string(ThemeDB.fallback_font, Vector2(bar_width / 2 - 20, bar_y + 12), hp_text, HORIZONTAL_ALIGNMENT_CENTER, -1, 11, color_text)
