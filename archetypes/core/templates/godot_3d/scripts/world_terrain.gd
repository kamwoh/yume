class_name WorldTerrain
extends RefCounted

## Static helpers for building terrain, edge trees, paths, and the starting camp.
## Stateless — sim_world owns the terrain_node reference. All these methods take
## (parent, world_data, asset_config, ...) and return the terrain node where useful.


static func build_heightmap(parent: Node3D, world_data: Dictionary, world_w: float, world_h: float) -> Node:
	## Returns the terrain node (used later for height queries) or null on fallback.
	var terrain_data: Dictionary = world_data.get("terrain", {})
	var hmap: Dictionary = terrain_data.get("heightmap", {})

	if not hmap.is_empty():
		var script = load("res://scripts/terrain.gd")
		if script:
			var terrain := StaticBody3D.new()
			terrain.name = "Terrain"
			terrain.set_script(script)
			parent.add_child(terrain)
			terrain.build_from_data(hmap, world_w, world_h)
			print("[SimWorld] Heightmap terrain built")
			return terrain

	# Fallback: flat ground
	build_flat_ground(parent, world_data, world_w, world_h)
	return null


static func build_flat_ground(parent: Node3D, world_data: Dictionary, world_w: float, world_h: float) -> void:
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	var mesh_inst := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(world_w, world_h)
	mesh_inst.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.55, 0.25)
	mat.roughness = 0.9
	mesh_inst.material_override = mat
	ground.add_child(mesh_inst)

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(world_w, 0.1, world_h)
	col.shape = box
	col.position.y = -0.05
	ground.add_child(col)
	parent.add_child(ground)

	# Patches + flowers from JSON
	var patches: Array = world_data.get("terrain", {}).get("patches", [])
	for p in patches:
		var patch := MeshInstance3D.new()
		patch.mesh = CylinderMesh.new()
		patch.mesh.top_radius = p.get("radius", 2.0)
		patch.mesh.bottom_radius = p.get("radius", 2.0) * 1.1
		patch.mesh.height = 0.02
		patch.position = Vector3(p.get("x", 0), 0.01, p.get("z", 0))
		var pmat := StandardMaterial3D.new()
		var shade: String = str(p.get("shade", "lighter"))
		pmat.albedo_color = Color(0.38, 0.58, 0.28) if shade == "lighter" else Color(0.3, 0.48, 0.2)
		patch.material_override = pmat
		ground.add_child(patch)

	var flower_color_map: Dictionary = {
		"yellow": Color(0.9, 0.85, 0.2),
		"red": Color(0.9, 0.3, 0.3),
		"white": Color(0.95, 0.95, 0.9),
		"purple": Color(0.6, 0.3, 0.8),
	}
	var flowers: Array = world_data.get("terrain", {}).get("flowers", [])
	for f in flowers:
		var flower := MeshInstance3D.new()
		flower.mesh = SphereMesh.new()
		flower.mesh.radius = f.get("size", 0.06)
		flower.mesh.height = f.get("size", 0.06) * 2
		flower.position = Vector3(f.get("x", 0), 0.05, f.get("z", 0))
		var fmat := StandardMaterial3D.new()
		fmat.albedo_color = flower_color_map.get(str(f.get("color", "white")), Color.WHITE)
		flower.material_override = fmat
		ground.add_child(flower)

	print("[SimWorld] Ground: ", world_w, "x", world_h, " + ", patches.size(), " patches + ", flowers.size(), " flowers")


static func build_edge_trees(parent: Node3D, world_data: Dictionary, terrain_node: Node, elements_config: Array, asset_config: Dictionary) -> void:
	var tree_tint: Dictionary = {}
	for edef in elements_config:
		if str(edef.get("id", "")) == "tree":
			tree_tint = edef.get("tint", {})
			break

	var edge_trees: Array = world_data.get("edge_trees", [])
	for et in edge_trees:
		var ex: float = et.get("x", 0)
		var ez: float = et.get("z", 0)
		var ey: float = 0.0
		if terrain_node and terrain_node.has_method("get_height_at"):
			ey = terrain_node.get_height_at(ex, ez) - 0.15
		var node := Node3D.new()
		node.name = "EdgeTree_" + str(randi() % 10000)
		node.position = Vector3(ex, ey, ez)
		if ModelHelpers.try_add_model(node, str(et.get("model", "tree_default")), et.get("scale", 1.0), et.get("rotation_y", 0), asset_config):
			if tree_tint.get("enabled", false):
				ModelHelpers.apply_tint(node, tree_tint)
		parent.add_child(node)
	print("[SimWorld] Edge trees: ", edge_trees.size())


static func build_paths(parent: Node3D, world_data: Dictionary, terrain_node: Node, asset_config: Dictionary) -> void:
	var paths: Array = world_data.get("paths", [])
	var path_tint: Dictionary = {"enabled": true, "color": [0.6, 0.48, 0.3, 1.0]}
	for p in paths:
		var px: float = p.get("x", 0)
		var pz: float = p.get("z", 0)
		var py: float = 0.02
		if terrain_node and terrain_node.has_method("get_height_at"):
			py = terrain_node.get_height_at(px, pz) + 0.02
		var node := Node3D.new()
		node.name = "Path_" + str(randi() % 10000)
		node.position = Vector3(px, py, pz)
		if ModelHelpers.try_add_model(node, str(p.get("model", "ground_pathStraight")), p.get("scale", 1.0), p.get("rotation_y", 0), asset_config):
			ModelHelpers.apply_tint(node, path_tint)
		parent.add_child(node)
	print("[SimWorld] Paths: ", paths.size(), " brown tiles")


static func build_camp(parent: Node3D, world_data: Dictionary, terrain_node: Node, elements_config: Array, asset_config: Dictionary) -> void:
	var camp: Array = world_data.get("camp", [])
	var el_defs: Dictionary = {}
	for edef in elements_config:
		el_defs[str(edef.get("id", ""))] = edef

	for c in camp:
		var pos := Vector3(c.get("x", 0), 0, c.get("z", 0))
		if terrain_node and terrain_node.has_method("get_height_at"):
			pos.y = terrain_node.get_height_at(pos.x, pos.z) - 0.1
		var model: String = str(c.get("model", "_primitive"))
		var scale: float = c.get("scale", 1.0)
		var rot_y: float = c.get("rotation_y", 0)

		var eid: String = str(c.get("element", ""))
		var edef: Dictionary = el_defs.get(eid, {})

		var body := StaticBody3D.new()
		body.name = "Camp_" + eid
		body.position = pos
		body.add_to_group("sim_element")
		body.set_meta("element_id", eid)
		# Same state/groups meta as WorldElements so the rules engine can tick
		# per-entity rules on camp structures too (e.g. campfire fuel decay).
		var groups_cfg = edef.get("groups", null)
		if groups_cfg is Dictionary:
			body.set_meta("groups", groups_cfg)
		var state_cfg = edef.get("state", null)
		if state_cfg is Dictionary:
			body.set_meta("state", state_cfg.duplicate(true))

		ModelHelpers.try_add_model(body, model, scale, rot_y, asset_config)

		var tint_cfg = edef.get("tint", null)
		if tint_cfg is Dictionary and tint_cfg.get("enabled", false):
			ModelHelpers.apply_tint(body, tint_cfg)

		var light_cfg = edef.get("light", null)
		if light_cfg is Dictionary:
			var light := OmniLight3D.new()
			var lc = light_cfg.get("color", [1.0, 0.7, 0.3])
			light.light_color = Color(lc[0], lc[1], lc[2])
			light.light_energy = light_cfg.get("energy", 2.5)
			light.omni_range = light_cfg.get("range", 8.0)
			light.position.y = light_cfg.get("height", 1.0)
			light.shadow_enabled = true
			body.add_child(light)

		parent.add_child(body)
	print("[SimWorld] Camp: ", camp.size(), " structures")
