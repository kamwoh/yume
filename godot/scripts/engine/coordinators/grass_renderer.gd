extends RefCounted
class_name GrassRenderer

## Grass-blade MultiMesh — real, protruding grass (option 2), 2026-05-27.
##
## Opt-in via scene.json `ground.grass_blades`. Scatters tapered blade
## cards across the GRASS biome (masked by the splatmap), sits them on the
## displaced terrain (GroundRenderer.sample_y), and renders them as ONE
## MultiMesh draw call with a vertex-sway wind shader (grass_blade.gdshader).
## No per-blade physics, no transparency overdraw (opaque cards).
##
## Per ADR 0021 (expose Godot, don't reimplement): this is a thin wrapper
## over Godot's MultiMeshInstance3D — the engine ships the primitive, the
## scene declares density/extent in JSON.
##
## scene.json schema:
##   "ground": {
##     "mesh": { ... shader_params with biome_map / plane_size /
##               grass_biome_index / biome_key ... },
##     "grass_blades": {
##       "enabled": true,
##       "count": 25000,        // candidate blades (placed only on grass)
##       "radius": 55.0,        // scatter disc radius (m) around origin
##       "blade_w": 0.09,       // blade base width (m)
##       "blade_h": 0.55,       // blade height (m)
##       "scale_jitter": 0.4,   // ± fraction on per-blade size
##       "seed": 7
##     }
##   }
##
## Performance knobs are `count` + `radius` (density) — drop them if a
## target machine struggles. A future pass can cull to a camera-centred
## patch; v1 scatters a fixed disc.

var _world: Node = null


func _init(world: Node) -> void:
	_world = world


func build() -> void:
	var ground := _read_ground()
	if ground.is_empty():
		return
	var mesh_cfg: Dictionary = ground.get("mesh", {})
	var sp: Dictionary = mesh_cfg.get("shader_params", {})
	var plane: float = float(sp.get("plane_size", _plane_from_size(mesh_cfg)))
	var grass_idx := int(sp.get("grass_biome_index", -1))
	if grass_idx < 0:
		return  # no grass biome → nothing to scatter

	# Shared: grass splatmap key + the splatmap Image for masking. Both the
	# blade and flower layers scatter only on grass, on the displaced terrain.
	var key := _grass_key(sp, grass_idx)
	var biome_img := _load_image(sp.get("biome_map", ""))

	var blades = ground.get("grass_blades", null)
	if blades is Dictionary and bool((blades as Dictionary).get("enabled", false)):
		_build_blades(blades, plane, biome_img, key)
	var flowers = ground.get("flowers", null)
	if flowers is Dictionary and bool((flowers as Dictionary).get("enabled", false)):
		_build_flowers(flowers, plane, biome_img, key)


## Scatter `count` points uniformly in a disc of `radius` around origin,
## keeping only those on the grass biome, each lifted onto the displaced
## terrain. Shared by the blade + flower layers.
func _scatter_points(count: int, radius: float, biome_img: Image,
		plane: float, key: Vector3, rng: RandomNumberGenerator) -> Array:
	var pts: Array = []
	var attempts := count * 3
	for _i in range(attempts):
		if pts.size() >= count:
			break
		var ang := rng.randf() * TAU
		var r := sqrt(rng.randf()) * radius
		var x := cos(ang) * r
		var z := sin(ang) * r
		if biome_img != null and not _is_grass(x, z, biome_img, plane, key):
			continue
		pts.append(Vector3(x, GroundRenderer.sample_y(x, z), z))
	return pts


func _build_blades(cfg: Dictionary, plane: float, biome_img: Image, key: Vector3) -> void:
	var count := int(cfg.get("count", 25000))
	var radius := float(cfg.get("radius", plane * 0.45))
	var blade_w := float(cfg.get("blade_w", 0.09))
	var blade_h := float(cfg.get("blade_h", 0.55))
	var jitter := float(cfg.get("scale_jitter", 0.4))
	var rng := RandomNumberGenerator.new()
	rng.seed = int(cfg.get("seed", 7))

	var pts := _scatter_points(count, radius, biome_img, plane, key, rng)
	if pts.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _blade_mesh(blade_w, blade_h)
	mm.instance_count = pts.size()
	for i in pts.size():
		var s := 1.0 + rng.randf_range(-jitter, jitter)
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(
			Vector3(s, s * (1.0 + rng.randf_range(-jitter, jitter)), s))
		mm.set_instance_transform(i, Transform3D(b, pts[i]))

	var mat := ShaderMaterial.new()
	var shader_res = load("res://data/lib/shaders/grass_blade.gdshader")
	if shader_res is Shader:
		mat.shader = shader_res
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "GrassBlades"
	mmi.multimesh = mm
	mmi.material_override = mat
	_world.add_child(mmi)
	if bool(_world.get("verbose")):
		print("[grass_renderer] %d blades placed" % pts.size())


## Flower specks — tiny per-instance-coloured crosses scattered sparsely on
## the grass (the hero reference's yellow/white dots). MultiMesh per-instance
## colour + a vertex-colour material, so all colours share one draw call.
func _build_flowers(cfg: Dictionary, plane: float, biome_img: Image, key: Vector3) -> void:
	var count := int(cfg.get("count", 1800))
	var radius := float(cfg.get("radius", plane * 0.45))
	var size := float(cfg.get("size", 0.14))
	var colors: Array = cfg.get("colors", ["#f2e25c", "#f6f4ec", "#f0a8c4"])
	var rng := RandomNumberGenerator.new()
	rng.seed = int(cfg.get("seed", 13))

	var pts := _scatter_points(count, radius, biome_img, plane, key, rng)
	if pts.is_empty():
		return
	var pal: Array = []
	for c in colors:
		pal.append(Color(str(c)))
	if pal.is_empty():
		pal.append(Color("#f2e25c"))

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _flower_mesh(size)
	mm.instance_count = pts.size()
	for i in pts.size():
		var s := 1.0 + rng.randf_range(-0.3, 0.3)
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
		mm.set_instance_transform(i, Transform3D(b, pts[i]))
		mm.set_instance_color(i, pal[rng.randi() % pal.size()])

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 0.85
	# A touch of emission so the specks pop against shadowed grass.
	mat.emission_enabled = true
	mat.emission = Color(1.0, 1.0, 1.0)
	mat.emission_energy_multiplier = 0.18
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Flowers"
	mmi.multimesh = mm
	mmi.material_override = mat
	_world.add_child(mmi)
	if bool(_world.get("verbose")):
		print("[grass_renderer] %d flowers placed" % pts.size())


# --- helpers -----------------------------------------------------------

func _read_ground() -> Dictionary:
	var root := str(_world.get("data_root")).rstrip("/")
	if root == "":
		return {}
	var path := root + "/scene.json"
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		return {}
	var ground = (data as Dictionary).get("ground", null)
	return ground if ground is Dictionary else {}


func _plane_from_size(mesh_cfg: Dictionary) -> float:
	var size_arr: Array = mesh_cfg.get("size", [80.0, 80.0])
	var w := float(size_arr[0]) if size_arr.size() >= 1 else 80.0
	var d := float(size_arr[1]) if size_arr.size() >= 2 else w
	return max(w, d)


func _grass_key(sp: Dictionary, grass_idx: int) -> Vector3:
	var keys = sp.get("biome_key", [])
	if keys is Array and grass_idx < (keys as Array).size():
		var k = keys[grass_idx]
		if k is Array and (k as Array).size() >= 3:
			return Vector3(float(k[0]), float(k[1]), float(k[2]))
	return Vector3(0.627, 0.847, 0.282)  # fallback ≈ #a0d870 grass key


func _load_image(path_v) -> Image:
	var path := str(path_v).strip_edges()
	if path == "" or not ResourceLoader.exists(path):
		return null
	var tex = load(path)
	return (tex as Texture2D).get_image() if tex is Texture2D else null


func _is_grass(x: float, z: float, img: Image, plane: float, key: Vector3) -> bool:
	# Same UV mapping as the ground shader (no V flip).
	var u: float = clampf((x + plane * 0.5) / plane, 0.0, 1.0)
	var v: float = clampf((z + plane * 0.5) / plane, 0.0, 1.0)
	var px := int(u * float(img.get_width() - 1))
	var py := int(v * float(img.get_height() - 1))
	var c := img.get_pixel(px, py)
	return Vector3(c.r, c.g, c.b).distance_to(key) < 0.25


func _blade_mesh(w: float, h: float) -> ArrayMesh:
	# Tapered blade standing in +Y; UV.y = height ratio (0 base → 1 tip).
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var verts := [
		Vector3(-w * 0.5, 0.0, 0.0), Vector3(w * 0.5, 0.0, 0.0),
		Vector3(-w * 0.35, h * 0.55, 0.0), Vector3(w * 0.35, h * 0.55, 0.0),
		Vector3(0.0, h, 0.0),
	]
	var uvs := [
		Vector2(0.0, 0.0), Vector2(1.0, 0.0),
		Vector2(0.0, 0.55), Vector2(1.0, 0.55), Vector2(0.5, 1.0),
	]
	var tris := [0, 2, 1, 1, 2, 3, 2, 4, 3]
	for idx in tris:
		st.set_uv(uvs[idx])
		st.set_normal(Vector3(0.0, 0.0, 1.0))
		st.add_vertex(verts[idx])
	return st.commit()


func _flower_mesh(size: float) -> ArrayMesh:
	# A small upright cross of two quads (visible from any angle), standing
	# in +Y. Flat-coloured per instance (no UV needed). w = petal span.
	var w := size
	var h := size * 1.1
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Quad A in the XY plane, Quad B in the ZY plane — both centred, base y=0.
	var quads := [
		[Vector3(-w * 0.5, 0.0, 0.0), Vector3(w * 0.5, 0.0, 0.0),
		 Vector3(w * 0.5, h, 0.0), Vector3(-w * 0.5, h, 0.0)],
		[Vector3(0.0, 0.0, -w * 0.5), Vector3(0.0, 0.0, w * 0.5),
		 Vector3(0.0, h, w * 0.5), Vector3(0.0, h, -w * 0.5)],
	]
	for q in quads:
		for idx in [0, 1, 2, 0, 2, 3]:
			st.set_normal(Vector3(0.0, 1.0, 0.0))
			st.add_vertex(q[idx])
	return st.commit()
