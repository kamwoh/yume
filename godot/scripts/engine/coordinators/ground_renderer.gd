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
static var _heightmap_strength: float = 0.0   # = height_scale (biome shader)
static var _heightmap_offset: float = -0.5     # = height_offset (biome shader)
static var _heightmap_plane_size: float = 80.0
static var _heightmap_enabled: bool = false

# === Per-level shader_params rebind (ADR 0055, 2026-05-20) ===
#
# Cached at boot in build(); replayed at level_transition by
# rebind_shader_params(level_id) which reads
# data/<game>/levels/<level_id>/scene.json sparse overrides and
# deep-merges over the cached game-level params.
#
# Per invariant #11 (level-discontinuity engine-state cleanup): the
# biome_map shader uniform is level-coupled state. Snap behavior is
# synchronous — the shader switches in one frame, matching the
# camera-snap semantics from `transition_level_fade_request`.
static var _shader_material: ShaderMaterial = null
static var _game_shader_params: Dictionary = {}
static var _cached_data_root: String = ""


## Clear all cached static references before game shutdown. Without
## this, the ShaderMaterial + heightmap Image references survive the
## SceneTree teardown → Godot reports "ObjectDB instances leaked at
## exit" and "1 resources still in use at exit". Cosmetic warnings
## (OS reclaims memory anyway), but cleaning up avoids the log noise.
## Called from camera_director's ESC-quit path; safe no-op if called
## multiple times.
static func cleanup() -> void:
	_shader_material = null
	_game_shader_params = {}
	_cached_data_root = ""
	_heightmap_img = null
	_heightmap_enabled = false


## Sample the displaced ground Y at world coordinates (x, z).
## Matches ground_biome_displace.gdshader's vertex() displacement EXACTLY:
##   hm_uv = ((x + ps/2)/ps, (z + ps/2)/ps)   # no V-flip, no tiling
##   y = (heightmap_sample(hm_uv) + height_offset) * height_scale
## Returns 0.0 when displacement is disabled. This is the authority the
## HeightMapShape3D collider is built from, so physics floor == visual.
static func sample_y(x: float, z: float) -> float:
	if not _heightmap_enabled or _heightmap_img == null:
		return 0.0
	# World (x, z) → PlaneMesh UV [0..1]. NO V-flip (matches the shader +
	# pixel_to_world: image_y → world_z directly). NO uv tiling (the biome
	# shader samples the heightmap once across the whole plane).
	var ps: float = _heightmap_plane_size
	var u: float = clampf((x + ps * 0.5) / ps, 0.0, 1.0)
	var v: float = clampf((z + ps * 0.5) / ps, 0.0, 1.0)
	var W: int = _heightmap_img.get_width()
	var H: int = _heightmap_img.get_height()
	var px: float = u * float(W - 1)
	var py: float = v * float(H - 1)
	var x0: int = int(px)
	var y0: int = int(py)
	var x1: int = mini(x0 + 1, W - 1)
	var y1: int = mini(y0 + 1, H - 1)
	var fx: float = px - float(x0)
	var fy: float = py - float(y0)
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
	return (sample + _heightmap_offset) * _heightmap_strength

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
				else:
					v = _coerce_shader_value(v)
				sm.set_shader_parameter(str(k), v)
			# Plane size uniform — derived from cfg.size, not authored
			# separately. Lets the shader compute world-scale UVs.
			sm.set_shader_parameter("plane_size", max(w, d))
			mat = sm  # Override the StandardMaterial3D

			# Cache heightmap as CPU-side Image so the physics floor
			# (HeightMapShape3D collider, built below) and any
			# ground-snap follow the SAME displacement the vertex
			# shader applies. Reads the biome-displace shader's actual
			# uniforms: `heightmap` texture + `height_scale` +
			# `height_offset` (see ground_biome_displace.gdshader).
			var hm_val = params.get("heightmap", null)
			var h_scale := float(params.get("height_scale", 0.0))
			if hm_val is String and h_scale != 0.0:
				var hm_path: String = hm_val as String
				if ResourceLoader.exists(hm_path):
					var hm_tex = load(hm_path)
					if hm_tex is Texture2D:
						_heightmap_img = (hm_tex as Texture2D).get_image()
						_heightmap_strength = h_scale
						_heightmap_offset = float(params.get("height_offset", -0.5))
						_heightmap_plane_size = max(w, d)
						_heightmap_enabled = true
			# Cache for per-level rebind (ADR 0055, 2026-05-20).
			# The game-level params dict is the baseline; per-level
			# overrides merge over it on transition.
			_shader_material = sm
			_game_shader_params = (params as Dictionary).duplicate(true)
			_cached_data_root = str(_world.get("data_root")).rstrip("/")
		else:
			push_warning("ground_renderer: shader failed to load: " + shader_path)

	var node := MeshInstance3D.new()
	node.name = "Ground"
	node.mesh = mesh
	node.material_override = mat
	_world.add_child(node)

	# Real ground collider — replaces the soft y_floor convention in
	# character_body_runner. Per Yume's "expose Godot, don't reimplement"
	# — a StaticBody3D + shape, not a magic constant in GDScript.
	#
	# When the biome shader displaces vertices by a heightmap (cached
	# above), the collider is a HeightMapShape3D rebuilt from that SAME
	# heightmap via sample_y — so the physics floor follows the visible
	# hills and the player no longer floats over valleys / sinks into
	# hills. Otherwise (flat ground) a thin BoxShape3D with its top at
	# y=0 matches the flat plane. 2026-05-27 (was flat-only until the
	# totem-hills float bug at height_scale=10 forced the displaced case).
	var body := StaticBody3D.new()
	body.name = "GroundCollider"
	# Collision layer: "floor" (bit 3 per data/lib/physics/layers.json).
	# Player + NPC collision_masks include "floor" so they collide with
	# the ground. Without this explicit layer, the default (bit 1) means
	# entities whose masks don't include bit 1 fall through.
	body.collision_layer = 1 << 2  # bit 3 = "floor"
	body.collision_mask = 0  # ground itself doesn't need to react to anything
	var shape_node := CollisionShape3D.new()
	if _heightmap_enabled and _heightmap_img != null:
		# 1-metre cells (N-1 == plane), so the shape spans the plane at
		# scale 1.0 — NO node scaling. Godot physics is unreliable with
		# non-uniformly-scaled collision shapes, so we size the grid to
		# avoid scaling entirely.
		shape_node.shape = _build_heightmap_shape(w, d)
		var _hm_n: int = _hm_collider_n(maxf(w, d))
		print("[ground_renderer] heightmap collider built: %dx%d cells, plane=%.0fm, y-range=%.2f..%.2f" % [
			_hm_n, _hm_n, maxf(w, d),
			_heightmap_offset * _heightmap_strength,
			(1.0 + _heightmap_offset) * _heightmap_strength])
	else:
		var box := BoxShape3D.new()
		box.size = Vector3(w, 0.2, d)
		shape_node.shape = box
		shape_node.position = Vector3(0, -0.1, 0)  # top at y=0
	body.add_child(shape_node)
	_world.add_child(body)


## Grid resolution (points per axis) for the heightmap collider. Sized
## to 1-metre cells (N-1 == plane) so the shape needs NO scaling. Capped
## so very large worlds don't build an enormous shape.
static func _hm_collider_n(plane: float) -> int:
	return clampi(int(round(plane)) + 1, 33, 401)


## Build a HeightMapShape3D whose per-cell heights are sampled from the
## SAME displacement formula the shader uses (via sample_y), so the
## physics floor matches the visible terrain. Grid is N×N centered at
## origin in local units; the caller scales x/z to span the plane.
func _build_heightmap_shape(w: float, d: float) -> HeightMapShape3D:
	var plane: float = maxf(w, d)
	var n: int = _hm_collider_n(plane)
	var data := PackedFloat32Array()
	data.resize(n * n)
	var half: float = plane * 0.5
	var step: float = plane / float(n - 1)
	for iz in range(n):
		var wz: float = -half + float(iz) * step
		for ix in range(n):
			var wx: float = -half + float(ix) * step
			# map_data is row-major: [depth_row * width + width_col].
			data[iz * n + ix] = sample_y(wx, wz)
	var shape := HeightMapShape3D.new()
	shape.map_width = n
	shape.map_depth = n
	shape.map_data = data
	return shape


## ADR 0059 — build the water surface from scene.json's `water.mesh`
## block. A flat transparent PlaneMesh at `water.level`, backed by a
## custom shader (water_stylized.gdshader). NO collider — water isn't
## a walkable surface; actors pass through.
##
## Depth-test handles the shoreline for free: the opaque terrain (built
## by build()) writes depth first, so the transparent water plane only
## shows where the terrain dips BELOW water.level (the heightmap-carved
## riverbed). No semantic-map alpha mask needed.
##
## Called from WorldBoot after build(). Idempotent: skips if a Water
## node already exists.
func build_water() -> void:
	for child in _world.get_children():
		if child is MeshInstance3D and (child as Node).name == "Water":
			return

	var scene_cfg := _read_scene_root()
	var water := scene_cfg.get("water", {}) as Dictionary
	if water.is_empty():
		return
	var cfg := water.get("mesh", {}) as Dictionary
	if cfg.is_empty():
		return

	var size_arr: Array = cfg.get("size", [80, 80])
	var w := float(size_arr[0]) if size_arr.size() >= 1 else 80.0
	var d := float(size_arr[1]) if size_arr.size() >= 2 else w
	var level := float(cfg.get("level", 0.0))
	var box_depth := float(cfg.get("box_depth", 0.0))

	# Box volume (2026-05-28): when box_depth > 0, the mesh is a 3D BOX
	# with the top face at water_level and the bottom face buried at
	# water_level - box_depth. The shader's `cull_disabled` lets the
	# box's interior render when the camera is below water_level — that
	# gives the natural underwater effect (refraction + depth-tint of
	# the world as seen through water). Legacy flat-plane mode (no
	# box_depth, or box_depth==0) is preserved for older demos.
	var mesh: Mesh
	var node_y := level
	if box_depth > 0.0:
		var bm := BoxMesh.new()
		bm.size = Vector3(w, box_depth, d)
		mesh = bm
		# Box pivot is the centre; offset down so the TOP face sits
		# exactly at water_level.
		node_y = level - box_depth * 0.5
	else:
		var pm := PlaneMesh.new()
		pm.size = Vector2(w, d)
		mesh = pm

	var shader_path: String = str(cfg.get("shader", "")).strip_edges()
	if shader_path == "":
		push_warning("ground_renderer: water.mesh has no `shader` — skipping")
		return
	var shader_res = load(shader_path)
	if not (shader_res is Shader):
		push_warning("ground_renderer: water shader failed to load: " + shader_path)
		return

	var sm := ShaderMaterial.new()
	sm.shader = shader_res
	var params: Dictionary = cfg.get("shader_params", {})
	for k in params:
		var v = params[k]
		if v is String and (v as String).begins_with("res://"):
			var loaded = load(v)
			if loaded is Texture2D:
				v = loaded
		sm.set_shader_parameter(str(k), v)

	var node := MeshInstance3D.new()
	node.name = "Water"
	node.mesh = mesh
	node.material_override = sm
	node.position = Vector3(0, node_y, 0)
	# Transparent surface: don't cast shadows onto the riverbed.
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world.add_child(node)


## Coerce a JSON-decoded shader-param value into the type Godot's
## set_shader_parameter expects for array/vector uniforms.
##
## JSON gives plain Arrays. A `vec3[]` uniform needs a
## PackedVector3Array; a `vec3` uniform accepts an Array of 3 numbers
## but a PackedVector3Array of [r,g,b] sub-arrays does NOT auto-convert.
## So: an Array whose elements are themselves length-3 numeric arrays
## → PackedVector3Array (the biome_key / biome_albedo case). A flat
## numeric Array → PackedFloat32Array (biome_roughness[]). Everything
## else passes through (scalars, single vecN arrays, strings).
static func _coerce_shader_value(v):
	if not (v is Array):
		return v
	var arr: Array = v
	if arr.is_empty():
		return v
	# Array of length-3 numeric arrays → PackedVector3Array
	var first = arr[0]
	if first is Array and (first as Array).size() == 3:
		var out := PackedVector3Array()
		for el in arr:
			if el is Array and (el as Array).size() == 3:
				out.append(Vector3(
					float(el[0]), float(el[1]), float(el[2])
				))
		return out
	# Flat numeric array of length >= 1 where every element is a number
	# AND the array is longer than 4 → treat as a float[] uniform
	# (biome_roughness). Short numeric arrays (<=4) are left alone so
	# single vec2/3/4 uniforms still work.
	if (first is float or first is int) and arr.size() > 4:
		var fout := PackedFloat32Array()
		for el in arr:
			fout.append(float(el))
		return fout
	return v


## Read the full scene.json root dict (not just ground.mesh). Used by
## build_water(); returns {} if absent/unparseable.
func _read_scene_root() -> Dictionary:
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
	return data if data is Dictionary else {}


## Rebind ground shader parameters when a level transition has loaded
## a new level. Reads `data/<game>/levels/<level_id>/scene.json` if
## it exists, deep-merges its `ground.mesh.shader_params` over the
## cached game-level params, and calls `set_shader_parameter()` on
## the existing Ground MeshInstance3D's ShaderMaterial for each
## changed key. No node teardown — the same ShaderMaterial is reused.
##
## Per ADR 0055 v2 / invariant #11: called from
## level_transition_coordinator.do_transition() AFTER load_level()
## completes, paired with camera-snap. The shader switches in one
## frame — no interpolation between biome maps.
##
## Safe no-op when:
##   - Ground uses StandardMaterial3D (no shader configured)
##   - Per-level scene.json doesn't exist
##   - Per-level scene.json doesn't override ground.mesh.shader_params
##
## Empirical case 2026-05-20: ADR 0055 added per-level biome maps.
## Without this rebind, transitioning to a level with a different
## biome map would show the OLD level's ground texture under the NEW
## level's entities — exactly the kind of "engine state coupled to
## OLD level identity" bug class invariant #11 was written to catch.
static func rebind_shader_params(level_id: String) -> void:
	if _shader_material == null:
		# Ground uses StandardMaterial3D — nothing to rebind.
		return
	if _cached_data_root == "" or level_id == "":
		return
	var path := _cached_data_root + "/levels/" + level_id + "/scene.json"
	if not FileAccess.file_exists(path):
		# No per-level override — re-apply the game-level baseline
		# in case a PREVIOUS level had overrides that need clearing.
		_apply_params(_game_shader_params)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var raw := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		return
	var doc := parsed as Dictionary
	var ground: Dictionary = doc.get("ground", {}) as Dictionary
	var mesh_cfg: Dictionary = ground.get("mesh", {}) as Dictionary
	var level_params: Dictionary = mesh_cfg.get("shader_params", {}) as Dictionary
	# Deep-merge: start from the game-level baseline, overlay the
	# level-level keys. Sparse override semantics — undeclared keys
	# inherit from the game-level baseline.
	var merged: Dictionary = _game_shader_params.duplicate(true)
	for k in level_params:
		merged[str(k)] = level_params[k]
	_apply_params(merged)


## Apply a shader_params dict to the cached ShaderMaterial. Auto-loads
## Texture2D for any `res://` string value (matches build()'s logic).
static func _apply_params(params: Dictionary) -> void:
	if _shader_material == null:
		return
	for k in params:
		var v = params[k]
		if v is String and (v as String).begins_with("res://"):
			var loaded = load(v as String)
			if loaded is Texture2D:
				v = loaded
		_shader_material.set_shader_parameter(str(k), v)


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
