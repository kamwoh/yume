extends RefCounted
class_name GroundRenderer

# === Static ground-snap support (2026-05-18, ADR 0052 extension) ===
#
# When the ground shader does vertex displacement (heightmap-based
# bumps), entities placed at world y=0 would float above or sink
# below the displaced surface. Static y_offset compensation alone
# can't fix this because the displacement varies per (x, z).
#
# Solution: cache the heightmap as a CPU-side Image at boot, and
# expose `sample_y(x, z)` as a static method. Entity renderers
# with `visual.snap_to_ground: true` call this every _sync_position
# to set their Y to the actual displaced ground at their position.
#
# Cheap: one Image kept in memory; bilinear sample per query.
# Used by entity_mesh_3d._sync_position.

static var _heightmap_img: Image = null
static var _heightmap_strength: float = 0.0
static var _heightmap_plane_size: float = 80.0
static var _heightmap_uv_tile: float = 60.0
static var _heightmap_enabled: bool = false


## Sample the displaced ground Y at world coordinates (x, z).
## Matches the shader's vertex displacement exactly:
##   VERTEX.y += (heightmap_sample - 0.5) * bump_strength
## Returns 0.0 when bump displacement is disabled.
static func sample_y(x: float, z: float) -> float:
	if not _heightmap_enabled or _heightmap_img == null:
		return 0.0
	# World (x, z) → PlaneMesh UV [0..1]
	var u: float = (x + _heightmap_plane_size * 0.5) / _heightmap_plane_size
	var v: float = 1.0 - (z + _heightmap_plane_size * 0.5) / _heightmap_plane_size
	# Tile by uv_tile (matches shader's `vec2 tiled_uv = UV * uv_tile`)
	var tu: float = fposmod(u * _heightmap_uv_tile, 1.0)
	var tv: float = fposmod(v * _heightmap_uv_tile, 1.0)
	# Bilinear sample
	var W: int = _heightmap_img.get_width()
	var H: int = _heightmap_img.get_height()
	var px: float = tu * float(W - 1)
	var py: float = tv * float(H - 1)
	var x0: int = int(px)
	var y0: int = int(py)
	var x1: int = mini(x0 + 1, W - 1)
	var y1: int = mini(y0 + 1, H - 1)
	var fx: float = px - float(x0)
	var fy: float = py - float(y0)
	# Image.get_pixel returns Color; .r is the R channel float
	var c00: float = _heightmap_img.get_pixel(x0, y0).r
	var c10: float = _heightmap_img.get_pixel(x1, y0).r
	var c01: float = _heightmap_img.get_pixel(x0, y1).r
	var c11: float = _heightmap_img.get_pixel(x1, y1).r
	var sample: float = (
		c00 * (1.0 - fx) * (1.0 - fy)
		+ c10 * fx * (1.0 - fy)
		+ c01 * (1.0 - fx) * fy
		+ c11 * fx * fy
	)
	return (sample - 0.5) * _heightmap_strength

## Builds the floor mesh — MeshInstance3D + PlaneMesh + StandardMaterial3D —
## from scene.json's `ground.mesh` block. Lets a 3D game declare its ground
## plane as JSON instead of hand-rolling a Node in the per-game .tscn.
##
## Schema (in scene.json):
##
##   "ground": {
##     "y": 0,                       // existing — sim ground primitive
##     "clamp_tags": ["creature"],   // existing
##     "despawn_tags": ["projectile"],
##     "mesh": {                     // visual plane
##       "size": [400, 400],         // width, depth in meters
##       "color": "#6b5c42",         // albedo hex or [r,g,b,a]
##                                   //  (tints the texture if albedo_texture set)
##       "roughness": 0.92,
##       "metallic": 0.0,
##       "albedo_texture": "res://data/<game>/assets/textures/...",  // optional
##       "normal_texture": "res://data/<game>/assets/textures/...",  // optional
##       "uv1_scale": 30              // optional — tile texture N times across the plane
##     }
##   }
##
## If `ground.mesh` is absent, no ground is rendered (fine for abstract
## puzzles, overlay-only games). If a Ground MeshInstance3D already exists
## as a World child (legacy per-game .tscn), GroundRenderer does nothing —
## the .tscn-provided one takes precedence.

var _world: Node = null


func _init(world: Node) -> void:
	_world = world


## Read scene.json, find ground.mesh, build the plane. Called once from
## WorldBoot during the boot sequence. Idempotent (skips if ground node
## already exists).
func build() -> void:
	# Adopt-and-skip: if a static Ground MeshInstance3D was placed in the
	# per-game .tscn, respect it. Author chose explicitly.
	for child in _world.get_children():
		if child is MeshInstance3D and (child as Node).name == "Ground":
			return

	var cfg := _read_mesh_cfg()
	if cfg.is_empty():
		return

	var size_arr: Array = cfg.get("size", [400, 400])
	var w := float(size_arr[0]) if size_arr.size() >= 1 else 400.0
	var d := float(size_arr[1]) if size_arr.size() >= 2 else w
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(w, d)
	# Optional subdivision for vertex-displacement shaders (ADR 0052
	# extension, 2026-05-18). PlaneMesh defaults to subdivide=0 = 2
	# triangles, which can't show vertex bumps. Set `subdivide` to
	# split the plane into N×N quads. Cost: (N+1)² vertices. For an
	# 80m plane at N=128, quad pitch is ~0.6m → bumps visible at
	# typical FPS view distance. Skip if no displacement shader is in
	# use (default 0 = flat plane, no extra vertices).
	var subdivide := int(cfg.get("subdivide", 0))
	if subdivide > 0:
		mesh.subdivide_width = subdivide
		mesh.subdivide_depth = subdivide

	# Typed as Material (parent class) so we can swap in a
	# ShaderMaterial later if `cfg.shader` is set.
	var mat: Material = StandardMaterial3D.new()
	var smat: StandardMaterial3D = mat as StandardMaterial3D
	smat.albedo_color = _color(cfg.get("color", "#808080"))
	smat.roughness = float(cfg.get("roughness", 0.9))
	smat.metallic = float(cfg.get("metallic", 0.0))

	# Optional albedo texture (multiplied by albedo_color). Tiles via uv1_scale.
	var albedo_path: String = str(cfg.get("albedo_texture", "")).strip_edges()
	if albedo_path != "":
		var tex = load(albedo_path)
		if tex is Texture2D:
			smat.albedo_texture = tex
		else:
			push_warning("ground_renderer: albedo_texture failed to load: " + albedo_path)

	# Optional normal map. Tiles with the same uv1_scale.
	var normal_path: String = str(cfg.get("normal_texture", "")).strip_edges()
	if normal_path != "":
		var ntex = load(normal_path)
		if ntex is Texture2D:
			smat.normal_enabled = true
			smat.normal_texture = ntex
		else:
			push_warning("ground_renderer: normal_texture failed to load: " + normal_path)

	# UV tiling. A 400m plane with uv1_scale=30 tiles the texture every ~13m
	# — close-up surface detail without obvious repetition. Z component is
	# unused for a planar UV but Godot stores Vector3 anyway.
	var uv_scale: float = float(cfg.get("uv1_scale", 1.0))
	if uv_scale != 1.0:
		smat.uv1_scale = Vector3(uv_scale, uv_scale, 1.0)

	# ADR 0052: optional custom shader. If `ground.mesh.shader` is set,
	# REPLACE the StandardMaterial3D with a ShaderMaterial backed by
	# the referenced .gdshader. Uniforms come from `shader_params`
	# (dict of param-name -> value, or path-string -> Texture2D).
	# Used for the multi-biome ground (composition pass 2026-05-17).
	var shader_path: String = str(cfg.get("shader", "")).strip_edges()
	if shader_path != "":
		var shader_res = load(shader_path)
		if shader_res is Shader:
			var sm := ShaderMaterial.new()
			sm.shader = shader_res
			var params: Dictionary = cfg.get("shader_params", {})
			for k in params:
				var v = params[k]
				# Auto-load Texture2D from res:// strings — handy
				# so authors don't have to pre-load textures in JSON
				if v is String and (v as String).begins_with("res://"):
					var loaded = load(v)
					if loaded is Texture2D:
						v = loaded
				sm.set_shader_parameter(str(k), v)
			# Plane size uniform — derived from cfg.size, not authored
			# separately. Lets the shader compute world-scale UVs.
			sm.set_shader_parameter("plane_size", max(w, d))
			mat = sm  # Override the StandardMaterial3D

			# Cache heightmap as CPU-side Image for entity ground-snap.
			# Reads `heightmap` shader_param (the same texture passed
			# to the vertex displacement). Entities with
			# `visual.snap_to_ground: true` query this via
			# GroundRenderer.sample_y(x, z) in their _sync_position.
			var hm_enabled := float(params.get("heightmap_enabled", 0.0)) > 0.5
			var hm_val = params.get("heightmap", null)
			if hm_enabled and hm_val is String:
				var hm_path: String = hm_val as String
				if ResourceLoader.exists(hm_path):
					var hm_tex = load(hm_path)
					if hm_tex is Texture2D:
						_heightmap_img = (hm_tex as Texture2D).get_image()
						_heightmap_strength = float(params.get("bump_strength", 0.0))
						_heightmap_plane_size = max(w, d)
						_heightmap_uv_tile = float(params.get("uv_tile", 60.0))
						_heightmap_enabled = (_heightmap_strength > 0.0)
		else:
			push_warning("ground_renderer: shader failed to load: " + shader_path)

	var node := MeshInstance3D.new()
	node.name = "Ground"
	node.mesh = mesh
	node.material_override = mat
	_world.add_child(node)


## Read scene.json's `ground.mesh` block. Returns {} if the file or block
## is absent. Same JSON-loading pattern as LightingDirector._load_config.
func _read_mesh_cfg() -> Dictionary:
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
	if not (ground is Dictionary):
		return {}
	var mesh_cfg = (ground as Dictionary).get("mesh", null)
	if not (mesh_cfg is Dictionary):
		return {}
	return mesh_cfg


static func _color(v) -> Color:
	if v is Color:
		return v
	if v is String:
		return Color(v as String)
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		var alpha: float = float(a[3]) if a.size() >= 4 else 1.0
		return Color(float(a[0]), float(a[1]), float(a[2]), alpha)
	return Color.WHITE
