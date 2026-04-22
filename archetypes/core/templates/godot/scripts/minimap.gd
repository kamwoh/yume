extends Control

## Minimap — draws 2D overhead view of the world.
## Mode 1 (dungeon): reads nav_grid.json for grid layout
## Mode 2 (simulation): scans live world for sim_element nodes
## Shows: elements, player position, enemy positions.

var nav_grid: Array = []
var grid_min_x: float = 0.0
var grid_min_z: float = 0.0
var cell_size: float = 1.0
var grid_w: int = 0
var grid_h: int = 0

var map_size: float = 200.0
var map_margin: float = 10.0

# Mode
var mode: String = "dungeon"  # "dungeon" or "simulation"
var world_w: float = 40.0
var world_h: float = 40.0

# Colors
var color_void := Color(0.1, 0.1, 0.12)
var color_floor := Color(0.3, 0.28, 0.25)
var color_wall := Color(0.5, 0.48, 0.45)
var color_door := Color(0.6, 0.5, 0.3)
var color_player := Color(0.2, 0.8, 0.3)
var color_enemy := Color(0.9, 0.2, 0.2)
var color_interact := Color(1.0, 0.85, 0.2)
var color_prop := Color(0.4, 0.4, 0.35)
var color_ground := Color(0.25, 0.4, 0.2)
var color_tree := Color(0.15, 0.5, 0.15)
var color_stone := Color(0.5, 0.5, 0.45)
var color_water := Color(0.2, 0.4, 0.8)
var color_fire := Color(1.0, 0.5, 0.1)
var color_farm := Color(0.6, 0.5, 0.2)

# Element type → color mapping
var element_colors: Dictionary = {
	"tree": Color(0.15, 0.5, 0.15),
	"stone": Color(0.5, 0.5, 0.45),
	"water": Color(0.2, 0.4, 0.8),
	"dirt": Color(0.45, 0.35, 0.2),
	"farmland": Color(0.5, 0.4, 0.15),
	"wheat_seed": Color(0.6, 0.55, 0.2),
	"wheat_growing": Color(0.7, 0.6, 0.1),
	"wheat_mature": Color(0.85, 0.7, 0.0),
	"campfire": Color(1.0, 0.5, 0.1),
	"shelter": Color(0.6, 0.4, 0.2),
}


func _ready() -> void:
	# Detect mode: check for sim world config
	var sim_file := FileAccess.open("res://data/sim/world_config.json", FileAccess.READ)
	if sim_file:
		var sim_data = JSON.parse_string(sim_file.get_as_text())
		if sim_data is Dictionary and sim_data.get("world_type", "") == "simulation":
			mode = "simulation"
			var ws: Dictionary = sim_data.get("world_size", {})
			world_w = ws.get("width", 40.0)
			world_h = ws.get("height", 40.0)
			print("[Minimap] Mode: simulation ", world_w, "x", world_h)

	if mode == "dungeon":
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
				print("[Minimap] Mode: dungeon ", grid_w, "x", grid_h)
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
	# Background
	draw_rect(Rect2(Vector2.ZERO, Vector2(map_size, map_size)), Color(0, 0, 0, 0.7))

	if mode == "simulation":
		_draw_simulation()
	else:
		_draw_dungeon()

	# Border
	draw_rect(Rect2(Vector2.ZERO, Vector2(map_size, map_size)), Color(0.5, 0.5, 0.5, 0.5), false, 1.0)


func _draw_simulation() -> void:
	## Draw simulation world — green ground + live element positions
	var half_w: float = world_w / 2.0
	var half_h: float = world_h / 2.0
	var sx: float = map_size / world_w
	var sz: float = map_size / world_h
	var pix_scale: float = min(sx, sz)

	# Green ground
	draw_rect(Rect2(Vector2.ZERO, Vector2(world_w * pix_scale, world_h * pix_scale)), color_ground)

	# Draw all sim elements from live world
	for element in get_tree().get_nodes_in_group("sim_element"):
		var eid: String = str(element.get_meta("element_id")) if element.has_meta("element_id") else ""
		var ex: float = (element.global_position.x + half_w) * pix_scale
		var ez: float = (element.global_position.z + half_h) * pix_scale
		var color: Color = element_colors.get(eid, color_prop)
		var dot_size: float = 2.5
		if eid == "tree":
			dot_size = 4.0
		elif eid == "water":
			dot_size = 3.5
		elif eid == "campfire":
			dot_size = 3.0
		draw_circle(Vector2(ex, ez), dot_size, color)

	# Draw player
	var player = get_tree().get_first_node_in_group("player")
	if player:
		var px: float = (player.global_position.x + half_w) * pix_scale
		var pz: float = (player.global_position.z + half_h) * pix_scale
		draw_circle(Vector2(px, pz), 5.0, color_player)
		var model_node = player.get_node_or_null("PlayerModel")
		if model_node:
			var dir := Vector2(sin(model_node.rotation.y), cos(model_node.rotation.y)) * 7.0
			draw_line(Vector2(px, pz), Vector2(px + dir.x, pz + dir.y), color_player, 2.0)

	# Draw enemies
	for entity in get_tree().get_nodes_in_group("enemy"):
		if entity.get("is_dead"):
			continue
		var ex: float = (entity.global_position.x + half_w) * pix_scale
		var ez: float = (entity.global_position.z + half_h) * pix_scale
		draw_circle(Vector2(ex, ez), 3.0, color_enemy)

	# Draw active camera + FOV cone
	var viewport := get_viewport()
	if viewport:
		var cam := viewport.get_camera_3d()
		if cam:
			var cam_pos := cam.global_position
			var cx: float = (cam_pos.x + half_w) * pix_scale
			var cz: float = (cam_pos.z + half_h) * pix_scale
			var cam_2d := Vector2(cx, cz)

			# Camera icon — small white diamond
			var diamond_size: float = 4.0
			var diamond := PackedVector2Array([
				cam_2d + Vector2(0, -diamond_size),
				cam_2d + Vector2(diamond_size, 0),
				cam_2d + Vector2(0, diamond_size),
				cam_2d + Vector2(-diamond_size, 0),
			])
			draw_colored_polygon(diamond, Color(1.0, 1.0, 1.0, 0.9))

			# FOV cone — view direction + spread
			var cam_forward := -cam.global_transform.basis.z
			var forward_2d := Vector2(cam_forward.x, cam_forward.z).normalized()
			if forward_2d.length() > 0.01:
				var fov_half: float = deg_to_rad(cam.fov / 2.0)
				var cone_len: float = 25.0 * pix_scale  # Length of cone in minimap pixels

				# Left and right edges of FOV
				var angle_base: float = atan2(forward_2d.y, forward_2d.x)
				var left_angle: float = angle_base - fov_half
				var right_angle: float = angle_base + fov_half

				var left_end := cam_2d + Vector2(cos(left_angle), sin(left_angle)) * cone_len
				var right_end := cam_2d + Vector2(cos(right_angle), sin(right_angle)) * cone_len

				# Draw cone as semi-transparent triangle
				var cone := PackedVector2Array([cam_2d, left_end, right_end])
				draw_colored_polygon(cone, Color(1.0, 1.0, 0.5, 0.15))

				# Draw cone edges
				draw_line(cam_2d, left_end, Color(1.0, 1.0, 0.5, 0.5), 1.0)
				draw_line(cam_2d, right_end, Color(1.0, 1.0, 0.5, 0.5), 1.0)

				# Draw center line (look direction)
				var center_end := cam_2d + forward_2d * cone_len * 0.7
				draw_line(cam_2d, center_end, Color(1.0, 1.0, 1.0, 0.7), 1.5)


func _draw_dungeon() -> void:
	## Draw dungeon mode — from nav_grid.json
	if nav_grid.is_empty():
		return

	var scale_x: float = map_size / max(grid_w, 1)
	var scale_y: float = map_size / max(grid_h, 1)
	var pix_scale: float = min(scale_x, scale_y)

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
				0: continue
				1: color = color_floor
				2: color = color_wall
				3: color = color_door
				4: color = color_prop
				5: color = color_enemy
				6: color = color_interact
				_: color = color_floor
			draw_rect(Rect2(Vector2(x * pix_scale, z * pix_scale), Vector2(pix_scale, pix_scale)), color)

	var player = get_tree().get_first_node_in_group("player")
	if player:
		var px: float = (player.global_position.x - grid_min_x) / cell_size * pix_scale
		var pz: float = (player.global_position.z - grid_min_z) / cell_size * pix_scale
		draw_circle(Vector2(px, pz), 4.0, color_player)
		var model_node = player.get_node_or_null("PlayerModel")
		if model_node:
			var dir := Vector2(sin(model_node.rotation.y), cos(model_node.rotation.y)) * 6.0
			draw_line(Vector2(px, pz), Vector2(px + dir.x, pz + dir.y), color_player, 2.0)

	for entity in get_tree().get_nodes_in_group("enemy"):
		if entity.get("is_dead"):
			continue
		var ex: float = (entity.global_position.x - grid_min_x) / cell_size * pix_scale
		var ez: float = (entity.global_position.z - grid_min_z) / cell_size * pix_scale
		draw_circle(Vector2(ex, ez), 3.0, color_enemy)
