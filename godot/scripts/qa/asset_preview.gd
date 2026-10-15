extends Node3D

## Asset-preview scene root — loads ONE asset (.glb or mesh-lib mesh
## name) and centers it for a clean close-up capture. Used by the
## A/B/C asset-gen comparison tooling.
##
## CLI:
##   godot --path . --rendering-driver opengl3 scenes/asset_preview.tscn -- \
##     --asset=res://data/demo_aldenmere/assets/meshes/oak_tree.glb \
##     --capture-after=2.0 --capture-output=user://preview.png
##
## Or for a code-drawn mesh-lib mesh (Plan C — needs the texture too):
##   ... -- --asset=oak_tree_3d \
##         --texture=res://data/demo_aldenmere/assets/textures/oak_foliage.png \
##         --capture-after=2.0 --capture-output=user://preview_c.png
##
## --rotate-y=DEG (optional, default 0) — turntable angle.
## --turntable=N (ADR 0083 F5) — capture N yaw angles of the asset into one
##   contact sheet, then quit. Frame 0 is the view from -Z (yaw 0). The
##   frames go left to right, then top to bottom, in steps of 360/N deg.
##   Needs a real renderer (not --headless).
## --turntable-output=PATH (default user://turntable.png).
## --lib=PATH (optional) — a draft mesh file in the meshes.json shape. Its
##   meshes and materials load on top of res://data/meshes.json, so a mesh
##   can be previewed before it goes into the library.
## --camera-distance=N (default auto-fit from AABB).
## --play-anim=NAME (optional) — for animated GLBs, plays the named
##   animation clip. Use --play-anim=auto to play the first available
##   clip (handy when you don't know the clip names). Without this
##   flag the asset shows its bind pose (T-pose for rigged meshes).

const TURNTABLE_KEY_YAW := 25.0  # deg off the camera axis, for some shading
# Calibrated 2026-10-15: #808080, #b03020 and #9a968c boxes render within
# 6/255 of their authored colors with these values (white key light).
# --key-energy= and --ambient= override them for a new calibration.
var _key_energy := 0.2
var _ambient := 0.1

@onready var _holder: Node3D = $AssetHolder
@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	var asset_path := ""
	var texture_path := ""
	var rotate_y := 0.0
	var explicit_dist := -1.0
	var play_anim := ""
	var turntable := 0
	var turntable_out := "user://turntable.png"
	var lib_path := ""
	for raw in OS.get_cmdline_user_args():
		var s := str(raw)
		if s.begins_with("--asset="):
			asset_path = s.substr(8)
		elif s.begins_with("--texture="):
			texture_path = s.substr(10)
		elif s.begins_with("--rotate-y="):
			rotate_y = float(s.substr(11))
		elif s.begins_with("--camera-distance="):
			explicit_dist = float(s.substr(18))
		elif s.begins_with("--play-anim="):
			play_anim = s.substr(12)
		elif s.begins_with("--turntable="):
			turntable = int(s.substr(12))
		elif s.begins_with("--turntable-output="):
			turntable_out = s.substr(19)
		elif s.begins_with("--lib="):
			lib_path = s.substr(6)
		elif s.begins_with("--key-energy="):
			_key_energy = float(s.substr(13))
		elif s.begins_with("--ambient="):
			_ambient = float(s.substr(10))
	if asset_path == "":
		push_warning("asset_preview: --asset=<path|mesh_lib_name> required")
		return

	# Load the asset. Two paths: .glb/.gltf via ResourceLoader, OR a
	# mesh-lib name resolved via MeshLib (matches entity_mesh_3d's
	# Tier-2 path).
	if asset_path.ends_with(".glb") or asset_path.ends_with(".gltf"):
		if not ResourceLoader.exists(asset_path):
			push_warning("asset_preview: not found: %s" % asset_path)
			return
		var packed = load(asset_path)
		if packed is PackedScene:
			_holder.add_child((packed as PackedScene).instantiate())
		else:
			push_warning("asset_preview: %s did not load as PackedScene" % asset_path)
			return
		# Apply texture to .glb's surfaces too (per-surface, no
		# material_override path on imported scenes).
		if texture_path != "" and ResourceLoader.exists(texture_path):
			var glb_tex = load(texture_path)
			if glb_tex is Texture2D:
				_paint_texture_recursive(_holder, glb_tex)
	else:
		# Mesh-lib lookup — compose primitives from data/meshes.json.
		var lib := MeshLib.load_from_file("res://data/meshes.json")
		if lib_path != "":
			var mats := MeshLib.named_materials.duplicate()
			var draft := MeshLib.load_from_file(lib_path)
			mats.merge(MeshLib.named_materials, true)
			MeshLib.named_materials = mats
			for k in draft.meshes:
				lib.meshes[k] = draft.meshes[k]
		if not lib.has(asset_path):
			push_warning("asset_preview: mesh '%s' not in lib" % asset_path)
			return
		var mesh_def := lib.get_mesh(asset_path)
		var prims = mesh_def.get("primitives", [])
		var params = MeshLib.merge_params(mesh_def, {})
		MeshLib.build_primitives_into(_holder, prims, params, true)
		# Apply texture to every primitive's material if requested
		# (mirrors entity_mesh_3d::_apply_albedo_texture_to_primitives).
		if texture_path != "" and ResourceLoader.exists(texture_path):
			var tex = load(texture_path)
			if tex is Texture2D:
				_paint_texture_recursive(_holder, tex)

	# Rotate around Y if requested.
	if rotate_y != 0.0:
		_holder.rotation.y = deg_to_rad(rotate_y)

	# Auto-fit camera distance from the asset's AABB (unless overridden).
	# Two frames: the mesh nodes settle, and a CSG group (ADR 0083 F3) bakes
	# one frame late, so its rebuilt mesh must be in before the AABB.
	await get_tree().process_frame
	await get_tree().process_frame
	var aabb: AABB = _compute_aabb(_holder)
	var radius: float = aabb.size.length() * 0.5
	if radius < 0.01:
		radius = 1.0
	var dist: float
	if explicit_dist > 0:
		dist = explicit_dist
	else:
		dist = max(2.0, radius * 2.2)
	_camera.position = Vector3(dist * 0.7, radius + dist * 0.45, dist * 0.7)
	_camera.look_at(aabb.get_center(), Vector3.UP, false)
	if turntable > 0:
		await _capture_turntable(turntable, aabb, dist, turntable_out)
		get_tree().quit()
		return

	# Optional animation playback for animated GLBs (ADR 0053). The
	# AnimationPlayer is embedded in the imported scene by Godot's
	# GLTF importer; we just find it + call play().
	if play_anim != "":
		var ap := _find_anim_player(_holder)
		if ap == null:
			push_warning("asset_preview: --play-anim requested but no AnimationPlayer found in %s" % asset_path)
		else:
			var list := ap.get_animation_list()
			var clip: String = play_anim
			if play_anim == "auto" and list.size() > 0:
				clip = list[0]
			if not ap.has_animation(clip):
				push_warning("asset_preview: clip '%s' not in player. Available: %s" % [clip, list])
			else:
				print("[asset_preview] playing animation: %s (from %s)" % [clip, list])
				ap.play(clip)


## ADR 0083 F5 — N views of the asset at yaw 0, 360/N, ... in one sheet.
## The camera sits on -Z, a little above the asset, so frame 0 shows the
## side that faces -Z (Godot forward).
func _capture_turntable(n: int, aabb: AABB, dist: float, out_path: String) -> void:
	var center := aabb.get_center()
	_camera.position = center + Vector3(0, dist * 0.25, -dist * 0.9)
	_camera.look_at(center, Vector3.UP, false)
	# Studio light, so the sheet shows the authored colors: a white key
	# light from the camera side, 35 deg up. The default preview sun lit
	# the top faces to white and left the front faces in shade: #9a968c
	# stone rendered as (87, 89, 95) on 2026-10-15.
	var sun := get_node_or_null("Sun") as DirectionalLight3D
	if sun != null:
		sun.global_transform = Transform3D.IDENTITY
		sun.rotation = Vector3(deg_to_rad(-35.0), deg_to_rad(180.0 + TURNTABLE_KEY_YAW), 0)
		sun.light_energy = _key_energy
		sun.light_color = Color.WHITE
	var env := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if env != null and env.environment != null:
		env.environment.ambient_light_energy = _ambient
	var cols := mini(n, 4)
	var rows := ceili(float(n) / cols)
	var sheet: Image = null
	var w := 0
	var h := 0
	for i in n:
		_holder.rotation.y = deg_to_rad(360.0 * i / n)
		await get_tree().process_frame
		await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		if sheet == null:
			w = img.get_width() / 2
			h = img.get_height() / 2
			sheet = Image.create(w * cols, h * rows, false, img.get_format())
		img.resize(w, h, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(img, Rect2i(0, 0, w, h), Vector2i((i % cols) * w, (i / cols) * h))
	sheet.save_png(out_path)
	print("[asset_preview] turntable: %d frames -> %s" % [n, ProjectSettings.globalize_path(out_path)])


func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for c in node.get_children():
		if c is AnimationPlayer:
			return c
		var nested := _find_anim_player(c)
		if nested != null:
			return nested
	return null


func _paint_texture_recursive(node: Node, tex: Texture2D) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		var mesh := mi.mesh
		if mesh != null:
			# MeshLib-built primitives (code-drawn meshes) attach
			# materials via mi.material_override. .glb-imported meshes
			# use per-surface. Check override first.
			if mi.material_override != null:
				var src_o: Material = mi.material_override
				var dup_o: StandardMaterial3D
				if src_o is StandardMaterial3D:
					dup_o = (src_o as StandardMaterial3D).duplicate(true)
				else:
					dup_o = StandardMaterial3D.new()
				dup_o.albedo_texture = tex
				mi.material_override = dup_o
			else:
				for i in mesh.get_surface_count():
					var src: Material = mi.get_surface_override_material(i)
					if src == null:
						src = mesh.surface_get_material(i)
					var dup: StandardMaterial3D
					if src is StandardMaterial3D:
						dup = (src as StandardMaterial3D).duplicate(true)
					else:
						dup = StandardMaterial3D.new()
					dup.albedo_texture = tex
					mi.set_surface_override_material(i, dup)
	for child_v in node.get_children():
		var child: Node = child_v
		_paint_texture_recursive(child, tex)


func _compute_aabb(node: Node) -> AABB:
	var combined := AABB()
	var first := true
	for n in _flatten(node):
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			var local: AABB = mi.get_aabb()
			# Transform into world space using mi's global transform.
			local = mi.global_transform * local
			if first:
				combined = local
				first = false
			else:
				combined = combined.merge(local)
	return combined


func _flatten(node: Node) -> Array:
	var out: Array = [node]
	for c_v in node.get_children():
		var c: Node = c_v
		out.append_array(_flatten(c))
	return out
