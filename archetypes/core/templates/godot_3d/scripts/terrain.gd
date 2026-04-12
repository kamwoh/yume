extends StaticBody3D

## HeightmapTerrain — real terrain with slopes from heightmap data.
## Reads height array from JSON, builds subdivided mesh with displaced vertices.
## Core engine component — used for: outdoor hills, dungeon levels, cliffs, underwater.

var terrain_mesh: MeshInstance3D
var heightmap: Array = []
var resolution: int = 64
var world_w: float = 100.0
var world_h: float = 100.0
var height_scale: float = 1.0
var base_color := Color(0.45, 0.68, 0.32)
var slope_color := Color(0.55, 0.48, 0.35)
var low_color := Color(0.40, 0.60, 0.28)
var high_color := Color(0.52, 0.72, 0.38)


func build_from_data(data: Dictionary, w: float, h: float) -> void:
	world_w = w
	world_h = h
	heightmap = data.get("heights", [])
	resolution = data.get("resolution", 64)
	height_scale = data.get("height_scale", 3.0)

	# Load terrain colors from elements.json
	var el_file := FileAccess.open("res://data/sim/elements.json", FileAccess.READ)
	if el_file:
		var el_data = JSON.parse_string(el_file.get_as_text())
		if el_data is Dictionary:
			var tc: Dictionary = el_data.get("terrain_material", {})
			var bc = tc.get("base_color", [0.45, 0.68, 0.32])
			var sc = tc.get("slope_color", [0.55, 0.48, 0.35])
			var lc = tc.get("low_color", [0.40, 0.60, 0.28])
			var hc = tc.get("high_color", [0.52, 0.72, 0.38])
			base_color = Color(bc[0], bc[1], bc[2])
			slope_color = Color(sc[0], sc[1], sc[2])
			low_color = Color(lc[0], lc[1], lc[2])
			high_color = Color(hc[0], hc[1], hc[2])

	if heightmap.is_empty():
		push_warning("[Terrain] No heightmap data")
		return

	_build_mesh()
	_build_collision()
	print("[Terrain] Built: ", resolution, "x", resolution, " heightmap, scale=", height_scale)


func _build_mesh() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var step_x: float = world_w / (resolution - 1)
	var step_z: float = world_h / (resolution - 1)
	var half_w: float = world_w / 2.0
	var half_h: float = world_h / 2.0

	# Build vertices with height displacement
	for z in range(resolution - 1):
		for x in range(resolution - 1):
			# 4 corners of this quad
			var v00 := _get_vertex(x, z, step_x, step_z, half_w, half_h)
			var v10 := _get_vertex(x + 1, z, step_x, step_z, half_w, half_h)
			var v01 := _get_vertex(x, z + 1, step_x, step_z, half_w, half_h)
			var v11 := _get_vertex(x + 1, z + 1, step_x, step_z, half_w, half_h)

			# Colors based on height and slope
			var c00 := _height_color(v00.y, x, z)
			var c10 := _height_color(v10.y, x + 1, z)
			var c01 := _height_color(v01.y, x, z + 1)
			var c11 := _height_color(v11.y, x + 1, z + 1)

			# Normals — compute from cross product, ensure pointing UP
			var n1 := (v10 - v00).cross(v01 - v00).normalized()
			var n2 := (v01 - v11).cross(v10 - v11).normalized()
			# Flip if pointing down
			if n1.y < 0:
				n1 = -n1
			if n2.y < 0:
				n2 = -n2

			# UV coords for texture tiling
			var uv00 := Vector2(float(x) / (resolution - 1), float(z) / (resolution - 1))
			var uv10 := Vector2(float(x + 1) / (resolution - 1), float(z) / (resolution - 1))
			var uv01 := Vector2(float(x) / (resolution - 1), float(z + 1) / (resolution - 1))
			var uv11 := Vector2(float(x + 1) / (resolution - 1), float(z + 1) / (resolution - 1))

			# Triangle 1: v00, v10, v01
			st.set_normal(n1)
			st.set_color(c00)
			st.set_uv(uv00)
			st.add_vertex(v00)
			st.set_color(c10)
			st.set_uv(uv10)
			st.add_vertex(v10)
			st.set_color(c01)
			st.set_uv(uv01)
			st.add_vertex(v01)

			# Triangle 2: v10, v11, v01
			st.set_normal(n2)
			st.set_color(c10)
			st.set_uv(uv10)
			st.add_vertex(v10)
			st.set_color(c11)
			st.set_uv(uv11)
			st.add_vertex(v11)
			st.set_color(c01)
			st.set_uv(uv01)
			st.add_vertex(v01)

	var mesh := st.commit()
	terrain_mesh = MeshInstance3D.new()
	terrain_mesh.name = "TerrainMesh"
	terrain_mesh.mesh = mesh

	# Material — grass texture tiled + vertex colors for variation
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = base_color

	# Try loading grass texture
	var grass_tex_path: String = "res://textures/grass.png"
	if ResourceLoader.exists(grass_tex_path):
		var tex: Texture2D = load(grass_tex_path)
		if tex:
			mat.albedo_texture = tex
			# Tile the texture across terrain
			mat.uv1_scale = Vector3(world_w / 4.0, world_h / 4.0, 1.0)
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			# Vertex color multiplies with texture
			mat.vertex_color_use_as_albedo = true
			print("[Terrain] Grass texture loaded and tiled")

	mat.roughness = 0.9
	terrain_mesh.material_override = mat
	add_child(terrain_mesh)


func _build_collision() -> void:
	## Build HeightMapShape3D for physics
	var shape := HeightMapShape3D.new()
	shape.map_width = resolution
	shape.map_depth = resolution

	# HeightMapShape3D expects a flat PackedFloat32Array
	var height_data := PackedFloat32Array()
	height_data.resize(resolution * resolution)

	for z in range(resolution):
		for x in range(resolution):
			var idx: int = z * resolution + x
			var h: float = 0.0
			if idx < heightmap.size():
				h = float(heightmap[idx]) * height_scale
			height_data[idx] = h

	shape.map_data = height_data

	var col := CollisionShape3D.new()
	col.name = "TerrainCollision"
	col.shape = shape
	# Scale collision to match world size
	col.scale = Vector3(world_w / (resolution - 1), 1.0, world_h / (resolution - 1))
	add_child(col)


func _get_vertex(x: int, z: int, step_x: float, step_z: float, half_w: float, half_h: float) -> Vector3:
	var wx: float = x * step_x - half_w
	var wz: float = z * step_z - half_h
	var idx: int = z * resolution + x
	var h: float = 0.0
	if idx < heightmap.size():
		h = float(heightmap[idx]) * height_scale
	return Vector3(wx, h, wz)


func _height_color(h: float, gx: int, gz: int) -> Color:
	## Color based on height: green grass → brown slopes → darker valleys
	var normalized_h: float = h / max(height_scale, 0.01)

	# Calculate slope from neighbors
	var slope: float = 0.0
	var idx: int = gz * resolution + gx
	if gx > 0 and gx < resolution - 1:
		var h_left: float = float(heightmap[idx - 1]) if idx - 1 >= 0 else 0.0
		var h_right: float = float(heightmap[idx + 1]) if idx + 1 < heightmap.size() else 0.0
		slope += abs(h_right - h_left)
	if gz > 0 and gz < resolution - 1:
		var h_up: float = float(heightmap[idx - resolution]) if idx - resolution >= 0 else 0.0
		var h_down: float = float(heightmap[idx + resolution]) if idx + resolution < heightmap.size() else 0.0
		slope += abs(h_down - h_up)

	# Blend based on height + slope
	var grass_factor: float = clamp(1.0 - slope * 2.0, 0.0, 1.0)

	# Start with base green
	var color := base_color
	# Hilltops: lighter green
	color = color.lerp(high_color, clamp(normalized_h * 0.8, 0.0, 0.5))
	# Valleys: darker green
	color = color.lerp(low_color, clamp((0.5 - normalized_h) * 0.5, 0.0, 0.3))
	# Steep slopes: brown
	color = color.lerp(slope_color, (1.0 - grass_factor) * 0.6)

	# Subtle variation
	var noise_var: float = (float((gx * 374761 + gz * 668265) & 0xFF) / 255.0 - 0.5) * 0.04
	color.r += noise_var
	color.g += noise_var
	color.b += noise_var * 0.5

	return color


func get_height_at(world_x: float, world_z: float) -> float:
	## Get interpolated height at any world position. For placing elements on terrain.
	var half_w: float = world_w / 2.0
	var half_h: float = world_h / 2.0
	var fx: float = (world_x + half_w) / world_w * (resolution - 1)
	var fz: float = (world_z + half_h) / world_h * (resolution - 1)

	var ix: int = clampi(int(fx), 0, resolution - 2)
	var iz: int = clampi(int(fz), 0, resolution - 2)
	var dx: float = fx - ix
	var dz: float = fz - iz

	# Bilinear interpolation
	var h00: float = _get_h(ix, iz)
	var h10: float = _get_h(ix + 1, iz)
	var h01: float = _get_h(ix, iz + 1)
	var h11: float = _get_h(ix + 1, iz + 1)

	var h0: float = h00 + (h10 - h00) * dx
	var h1: float = h01 + (h11 - h01) * dx
	return (h0 + (h1 - h0) * dz) * height_scale


func _get_h(x: int, z: int) -> float:
	var idx: int = z * resolution + x
	if idx >= 0 and idx < heightmap.size():
		return float(heightmap[idx])
	return 0.0
