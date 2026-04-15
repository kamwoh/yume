class_name WorldElements
extends RefCounted

## Static helpers for spawning sim_elements (entities, elements, decorations,
## composites). Reads from world_data.elements + element definitions in
## elements_config. Stamps element_id, object_type, groups as meta on the
## spawned node so the rules engine can find/match them.


static func build_all(parent: Node3D, world_data: Dictionary, terrain_node: Node, elements_config: Array, asset_config: Dictionary) -> void:
	var elements: Array = world_data.get("elements", [])
	var el_defs: Dictionary = {}
	for edef in elements_config:
		el_defs[str(edef.get("id", ""))] = edef

	for el in elements:
		_build_one(parent, el, el_defs, terrain_node, asset_config)

	_print_summary(elements, el_defs)


static func spawn_one(parent: Node3D, element_id: String, pos: Vector3, terrain_node: Node, elements_config: Array, asset_config: Dictionary) -> Node:
	## Spawn a single element of the given id at the given position.
	## Used by world_rules_engine for advance_stage / transform / spread effects.
	## Returns the spawned node, or null if element_id not found.
	var el_defs: Dictionary = {}
	for edef in elements_config:
		el_defs[str(edef.get("id", ""))] = edef
	if not el_defs.has(element_id):
		push_warning("[WorldElements] spawn_one: element_id not in defs: " + element_id)
		return null
	var el := {"element": element_id, "x": pos.x, "z": pos.z, "scale": 1.0, "rotation_y": 0.0}
	_build_one(parent, el, el_defs, terrain_node, asset_config)
	# Return the just-added child (last in parent's children)
	return parent.get_child(parent.get_child_count() - 1)


static func _build_one(parent: Node3D, el: Dictionary, el_defs: Dictionary, terrain_node: Node, asset_config: Dictionary) -> void:
	var eid: String = str(el.get("element", ""))
	var pos := Vector3(el.get("x", 0), 0, el.get("z", 0))
	var model: String = str(el.get("model", "_primitive"))
	var scale: float = el.get("scale", 1.0)
	var rot_y: float = el.get("rotation_y", 0)
	var edef: Dictionary = el_defs.get(eid, {})
	var obj_type: String = str(edef.get("object_type", "decoration"))

	# Place on terrain. Composites are ground-aligned; non-composites get a
	# slight sink to avoid z-fighting / floating.
	if terrain_node and terrain_node.has_method("get_height_at"):
		var terrain_h: float = terrain_node.get_height_at(pos.x, pos.z)
		pos.y = terrain_h if obj_type == "composite" else terrain_h - 0.1

	var node: Node3D
	if obj_type == "entity" or obj_type == "element" or obj_type == "composite":
		var body := StaticBody3D.new()
		body.name = "El_" + eid + "_" + str(randi() % 10000)
		node = body
	else:
		node = Node3D.new()
		node.name = "Decor_" + eid + "_" + str(randi() % 10000)

	node.position = pos
	if obj_type == "composite":
		node.rotation_degrees.y = rot_y
	node.add_to_group("sim_element")
	node.set_meta("element_id", eid)
	node.set_meta("object_type", obj_type)
	var groups_cfg = edef.get("groups", null)
	if groups_cfg is Dictionary:
		node.set_meta("groups", groups_cfg)

	var mat_cfg = edef.get("material", null)
	var model_loaded := false
	if obj_type == "composite":
		model_loaded = _add_composite_parts(node, edef, scale, asset_config)
	else:
		model_loaded = ModelHelpers.try_add_model(node, model, scale, rot_y, asset_config)
		if not model_loaded:
			if mat_cfg != null and mat_cfg is Dictionary:
				ModelHelpers.add_from_material_config(node, mat_cfg, scale)
			else:
				ModelHelpers.add_primitive_fallback(node, eid, scale)

	if model_loaded:
		var tint_cfg = edef.get("tint", null)
		if tint_cfg is Dictionary and tint_cfg.get("enabled", false):
			ModelHelpers.apply_tint(node, tint_cfg)

	# Collision from JSON
	var col_cfg = edef.get("collision", null)
	if col_cfg != null and col_cfg is Dictionary and node is StaticBody3D:
		var col := CollisionShape3D.new()
		var col_type: String = str(col_cfg.get("type", "box"))
		if col_type == "box":
			var box := BoxShape3D.new()
			var s = col_cfg.get("size", [0.8, 1.5, 0.8])
			box.size = Vector3(s[0], s[1], s[2]) * scale
			col.shape = box
		col.position.y = col_cfg.get("offset_y", 0.5) * scale
		node.add_child(col)

	# Light from JSON
	var light_cfg = edef.get("light", null)
	if light_cfg != null and light_cfg is Dictionary:
		var light := OmniLight3D.new()
		var lc = light_cfg.get("color", [1.0, 0.7, 0.3])
		light.light_color = Color(lc[0], lc[1], lc[2])
		light.light_energy = light_cfg.get("energy", 2.0)
		light.omni_range = light_cfg.get("range", 6.0)
		light.position.y = light_cfg.get("height", 1.0)
		light.shadow_enabled = true
		node.add_child(light)

	if edef.has("hp"):
		node.set_meta("hp", edef.get("hp"))
		node.set_meta("max_hp", edef.get("hp"))

	parent.add_child(node)


static func _add_composite_parts(parent: Node3D, edef: Dictionary, scale: float, asset_config: Dictionary) -> bool:
	## Iterate parts[] in the element def. Each part: {model, offset, rotation_y, scale?, tint?}.
	## Per-part tint overrides composite-level tint.
	var parts = edef.get("parts", [])
	if not (parts is Array) or parts.is_empty():
		return false
	var wrap := Node3D.new()
	wrap.name = "Parts"
	parent.add_child(wrap)
	var loaded_any := false
	for p in parts:
		if not (p is Dictionary):
			continue
		var part_model: String = str(p.get("model", ""))
		if part_model == "":
			continue
		var off = p.get("offset", [0, 0, 0])
		var part_scale: float = float(p.get("scale", 1.0)) * scale
		var part_rot_y: float = float(p.get("rotation_y", 0.0))
		var holder := Node3D.new()
		holder.name = "Part_" + part_model
		if off is Array and off.size() >= 3:
			holder.position = Vector3(float(off[0]), float(off[1]), float(off[2])) * scale
		wrap.add_child(holder)
		if ModelHelpers.try_add_model(holder, part_model, part_scale, part_rot_y, asset_config):
			loaded_any = true
			var part_tint = p.get("tint", null)
			if part_tint is Dictionary:
				ModelHelpers.apply_tint(holder, part_tint)
		else:
			push_warning("[SimWorld] Composite part failed to load: " + part_model)
	return loaded_any


static func _print_summary(elements: Array, el_defs: Dictionary) -> void:
	var entity_count: int = 0
	var element_count: int = 0
	var decor_count: int = 0
	for el in elements:
		var eid: String = str(el.get("element", ""))
		var t: String = str(el_defs.get(eid, {}).get("object_type", "decoration"))
		match t:
			"entity": entity_count += 1
			"element", "composite": element_count += 1
			_: decor_count += 1
	print("[SimWorld] Elements: ", elements.size(), " (", entity_count, " entities, ", element_count, " elements, ", decor_count, " decorations)")
