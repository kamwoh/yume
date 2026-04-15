class_name ModelHelpers
extends RefCounted

## Shared helpers used by element / agent / terrain spawning code.
## All static — no per-instance state. Pass asset_config in.

static func find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var r := find_anim_player(child)
		if r:
			return r
	return null


static func attach_animations(model_node: Node3D, asset_config: Dictionary) -> AnimationPlayer:
	## Kenney/KayKit pattern: character GLBs have skeletons but NO animations.
	## Animations live in separate rig files listed in asset_config.animation_files.
	## This loads each rig GLB, copies its animations into a single AnimationPlayer
	## under model_node, and returns that player. Returns null if no animations found.
	var anim_files: Array = asset_config.get("animation_files", [])
	if anim_files.is_empty():
		return null

	var anim_player: AnimationPlayer = find_anim_player(model_node)
	if anim_player == null:
		anim_player = AnimationPlayer.new()
		anim_player.name = "AnimationPlayer"
		model_node.add_child(anim_player)

	var anim_cfg: Dictionary = asset_config.get("animation_config", {})
	var loop_prefixes: Array = anim_cfg.get("loop_prefixes", [])

	for anim_path in anim_files:
		if not ResourceLoader.exists(str(anim_path)):
			continue
		var anim_scene: PackedScene = load(str(anim_path))
		if not anim_scene:
			continue
		var anim_instance := anim_scene.instantiate()
		_copy_animations_recursive(anim_instance, anim_player, loop_prefixes)
		anim_instance.queue_free()

	# Default to idle
	if anim_player.has_animation("Idle_A"):
		anim_player.play("Idle_A")
	return anim_player


static func _copy_animations_recursive(node: Node, target_player: AnimationPlayer, loop_prefixes: Array) -> void:
	if node is AnimationPlayer:
		var src: AnimationPlayer = node
		for anim_name in src.get_animation_list():
			if anim_name == "T-Pose":
				continue
			var anim: Animation = src.get_animation(anim_name)
			if not anim:
				continue
			var lib: AnimationLibrary = null
			if target_player.has_animation_library(""):
				lib = target_player.get_animation_library("")
			else:
				lib = AnimationLibrary.new()
				target_player.add_animation_library("", lib)
			if not lib.has_animation(anim_name):
				for prefix in loop_prefixes:
					if anim_name.begins_with(str(prefix)):
						anim.loop_mode = Animation.LOOP_LINEAR
						break
				lib.add_animation(anim_name, anim)
	for child in node.get_children():
		_copy_animations_recursive(child, target_player, loop_prefixes)


static func try_add_model(parent: Node3D, model_name: String, scale: float, rot_y: float, asset_config: Dictionary) -> bool:
	"""Try loading a GLB and adding as child of parent. Returns true if loaded."""
	if model_name.begins_with("_primitive"):
		return false
	var search_paths: Array = asset_config.get("model_search_paths", ["res://models/"])
	var extensions: Array = asset_config.get("model_extensions", ["glb", "gltf"])
	for base_path in search_paths:
		for ext in extensions:
			var path: String = str(base_path) + model_name + "." + str(ext)
			if ResourceLoader.exists(path):
				var scene: PackedScene = load(path)
				if scene:
					var instance := scene.instantiate()
					instance.name = "Model"
					instance.scale = Vector3.ONE * scale
					instance.rotation_degrees.y = rot_y
					parent.add_child(instance)
					return true
	return false


static func apply_tint(node: Node3D, tint_cfg: Dictionary) -> void:
	"""Apply color tint to loaded GLB model from JSON config.
	Smart tinting: leaves get leaf_color, bark/wood/trunk gets trunk_color.
	If trunk_color not specified, defaults to leaf_color (uniform tint)."""
	var leaf_color_arr = tint_cfg.get("color", [0.3, 0.6, 0.25, 1.0])
	var trunk_color_arr = tint_cfg.get("trunk_color", null)
	var leaf_color := Color(leaf_color_arr[0], leaf_color_arr[1], leaf_color_arr[2], leaf_color_arr[3] if leaf_color_arr.size() > 3 else 1.0)
	var trunk_color: Color = leaf_color
	if trunk_color_arr is Array and trunk_color_arr.size() >= 3:
		trunk_color = Color(trunk_color_arr[0], trunk_color_arr[1], trunk_color_arr[2], trunk_color_arr[3] if trunk_color_arr.size() > 3 else 1.0)
	_tint_recursive(node, leaf_color, trunk_color)


static func _tint_recursive(node: Node, leaf_color: Color, trunk_color: Color) -> void:
	if node is MeshInstance3D:
		var node_name: String = node.name.to_lower()
		var parent_name: String = node.get_parent().name.to_lower() if node.get_parent() else ""
		# Skip tinting if mesh has a specific color suffix (preserve flower petals).
		if "color" in node_name and ("red" in node_name or "yellow" in node_name or "purple" in node_name or "blue" in node_name):
			pass
		else:
			var mat := StandardMaterial3D.new()
			if "bark" in node_name or "trunk" in node_name or "wood" in node_name or "bark" in parent_name:
				mat.albedo_color = trunk_color
			else:
				mat.albedo_color = leaf_color
			mat.roughness = 0.85
			node.material_override = mat
	for child in node.get_children():
		_tint_recursive(child, leaf_color, trunk_color)


static func add_from_material_config(parent: Node3D, mat_cfg: Dictionary, scale: float) -> void:
	"""Build a primitive mesh from JSON material properties."""
	var mesh := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	var c = mat_cfg.get("color", [0.5, 0.5, 0.5, 1.0])
	if c is Array:
		mat.albedo_color = Color(c[0], c[1], c[2], c[3] if c.size() > 3 else 1.0)
	mat.metallic = mat_cfg.get("metallic", 0.0)
	mat.roughness = mat_cfg.get("roughness", 0.8)
	if str(mat_cfg.get("transparency", "")) == "alpha":
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var em = mat_cfg.get("emission", null)
	if em != null and em is Array:
		mat.emission_enabled = true
		mat.emission = Color(em[0], em[1], em[2])
		mat.emission_energy_multiplier = mat_cfg.get("emission_energy", 1.0)

	var shape: String = str(mat_cfg.get("shape", "sphere"))
	var size_var: float = scale * (0.8 + randf() * 0.4)
	match shape:
		"cylinder":
			mesh.mesh = CylinderMesh.new()
			mesh.mesh.top_radius = mat_cfg.get("shape_radius", 1.0) * size_var
			mesh.mesh.bottom_radius = mat_cfg.get("shape_radius", 1.0) * size_var * 1.1
			mesh.mesh.height = mat_cfg.get("shape_height", 0.1) * size_var
		"sphere":
			mesh.mesh = SphereMesh.new()
			mesh.mesh.radius = mat_cfg.get("shape_radius", 0.5) * size_var
			mesh.mesh.height = mat_cfg.get("shape_radius", 0.5) * size_var * 2
		"box":
			mesh.mesh = BoxMesh.new()
			var bsize: float = mat_cfg.get("shape_radius", 0.5) * size_var
			mesh.mesh.size = Vector3(bsize, mat_cfg.get("shape_height", bsize), bsize)
		_:
			mesh.mesh = SphereMesh.new()
			mesh.mesh.radius = 0.3 * size_var
	mesh.position.y = mat_cfg.get("offset_y", 0.0) * size_var
	mesh.material_override = mat
	parent.add_child(mesh)


static func add_primitive_fallback(parent: Node3D, element_id: String, scale: float) -> void:
	"""Hardcoded primitive shapes when no GLB or material config exists. Last-resort visual."""
	var mesh := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	var size_var: float = scale
	match element_id:
		"tree":
			var trunk := MeshInstance3D.new()
			trunk.mesh = CylinderMesh.new()
			trunk.mesh.top_radius = 0.08 * size_var
			trunk.mesh.bottom_radius = 0.15 * size_var
			trunk.mesh.height = 2.0 * size_var
			trunk.position.y = 1.0 * size_var
			var tmat := StandardMaterial3D.new()
			tmat.albedo_color = Color(0.4, 0.25, 0.12)
			trunk.material_override = tmat
			parent.add_child(trunk)
			mesh.mesh = SphereMesh.new()
			mesh.mesh.radius = 0.7 * size_var
			mesh.mesh.height = 1.0 * size_var
			mesh.position.y = 2.2 * size_var
			mat.albedo_color = Color(0.2, 0.5, 0.15)
		"stone":
			mesh.mesh = BoxMesh.new()
			mesh.mesh.size = Vector3(0.7, 0.5, 0.6) * size_var
			mesh.position.y = 0.25 * size_var
			mat.albedo_color = Color(0.5, 0.48, 0.45)
		"water", "_primitive_water":
			mesh.mesh = CylinderMesh.new()
			mesh.mesh.top_radius = 2.0 * size_var
			mesh.mesh.bottom_radius = 2.2 * size_var
			mesh.mesh.height = 0.15
			mesh.position.y = -0.05
			mat.albedo_color = Color(0.15, 0.4, 0.75, 0.8)
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.metallic = 0.4
			mat.roughness = 0.05
		"campfire":
			mesh.mesh = SphereMesh.new()
			mesh.mesh.radius = 0.15
			mesh.position.y = 0.15
			mat.albedo_color = Color(1.0, 0.4, 0.05)
			mat.emission_enabled = true
			mat.emission = Color(1.0, 0.4, 0.05)
			mat.emission_energy_multiplier = 3.0
		_:
			mesh.mesh = BoxMesh.new()
			mesh.mesh.size = Vector3(0.5, 0.5, 0.5) * size_var
			mesh.position.y = 0.25 * size_var
			mat.albedo_color = Color(0.5, 0.5, 0.5)
	mesh.material_override = mat
	parent.add_child(mesh)
