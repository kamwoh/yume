extends Control

## Minimap — draws 2D overhead view of the dungeon.
## Shows: floor/walls from nav_grid.json, player position, enemy positions.
## Helps debug room connectivity and door alignment.

var nav_grid: Array = []
var grid_min_x: float = 0.0
var grid_min_z: float = 0.0
var cell_size: float = 1.0
var grid_w: int = 0
var grid_h: int = 0

var map_size: float = 200.0  # pixels on screen
var map_margin: float = 10.0

# Colors
var color_void := Color(0.1, 0.1, 0.12)
var color_floor := Color(0.3, 0.28, 0.25)
var color_wall := Color(0.5, 0.48, 0.45)
var color_door := Color(0.6, 0.5, 0.3)
var color_player := Color(0.2, 0.8, 0.3)
var color_enemy := Color(0.9, 0.2, 0.2)
var color_interact := Color(1.0, 0.85, 0.2)
var color_prop := Color(0.4, 0.4, 0.35)


func _ready() -> void:
	# Load nav_grid.json
	var file := FileAccess.open("res://data/nav_grid.json", FileAccess.READ)
	if file:
		var data = JSON.parse_string(file.get_as_text())
		if data is Dictionary:
			nav_grid = data.get("grid", [])
			grid_min_x = data.get("min_x", 0.0)
			grid_min_z = data.get("min_z", 0.0)
			cell_size = data.get("cell_size", 1.0)
			grid_w = data.get("width", 0)
			grid_h = data.get("height", 0)
			print("[Minimap] Loaded: ", grid_w, "x", grid_h, " grid")
	else:
		print("[Minimap] nav_grid.json not found — run dungeon_map.py first")

	# Position in top-right corner
	position = Vector2(get_viewport().get_visible_rect().size.x - map_size - map_margin, map_margin)
	size = Vector2(map_size, map_size)

	# Make sure we render on top
	z_index = 100
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if nav_grid.is_empty():
		return

	# Background
	draw_rect(Rect2(Vector2.ZERO, Vector2(map_size, map_size)), Color(0, 0, 0, 0.7))

	# Calculate scale to fit grid in map_size
	var scale_x: float = map_size / max(grid_w, 1)
	var scale_y: float = map_size / max(grid_h, 1)
	var pix_scale: float = min(scale_x, scale_y)

	# Draw grid cells
	for z in range(grid_h):
		if z >= nav_grid.size():
			break
		var row = nav_grid[z]
		if not row is Array:
			continue
		for x in range(grid_w):
			if x >= row.size():
				break
			var cell_val: int = row[x]
			var color: Color
			match cell_val:
				0: continue  # void — skip
				1: color = color_floor
				2: color = color_wall
				3: color = color_door
				4: color = color_prop
				5: color = color_enemy
				6: color = color_interact
				_: color = color_floor

			var rect := Rect2(
				Vector2(x * pix_scale, z * pix_scale),
				Vector2(pix_scale, pix_scale)
			)
			draw_rect(rect, color)

	# Draw player position
	var player = get_tree().get_first_node_in_group("player")
	if player:
		var px: float = (player.global_position.x - grid_min_x) / cell_size * pix_scale
		var pz: float = (player.global_position.z - grid_min_z) / cell_size * pix_scale
		draw_circle(Vector2(px, pz), 4.0, color_player)
		# Direction indicator
		var model = player.get_node_or_null("PlayerModel")
		if model:
			var dir := Vector2(sin(model.rotation.y), cos(model.rotation.y)) * 6.0
			draw_line(Vector2(px, pz), Vector2(px + dir.x, pz + dir.y), color_player, 2.0)

	# Draw enemies
	for entity in get_tree().get_nodes_in_group("enemy"):
		if entity.get("is_dead"):
			continue
		var ex: float = (entity.global_position.x - grid_min_x) / cell_size * pix_scale
		var ez: float = (entity.global_position.z - grid_min_z) / cell_size * pix_scale
		draw_circle(Vector2(ex, ez), 3.0, color_enemy)

	# Border
	draw_rect(Rect2(Vector2.ZERO, Vector2(map_size, map_size)), Color(0.5, 0.5, 0.5, 0.5), false, 1.0)
