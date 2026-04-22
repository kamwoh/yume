extends RefCounted

## Static helpers for spawning sim_elements (entities, elements, decorations,
## composites). Reads from world_data.elements + element definitions in
## elements_config. Stamps element_id, object_type, groups as meta on the
## spawned node so the rules engine can find/match them.

const ModelHelpers = preload("res://scripts/renderer_3d/model_helpers.gd")


static func build_all(parent: Node3D, world_data: Dictionary, terrain_node: Node, elements_config: Array, asset_config: Dictionary) -> void:
	var elements: Array = world_data.get("elements", [])
	var el_defs: Dictionary = {}
	for edef in elements_config:
		el_defs[str(edef.get("id", ""))] = edef

	for el in elements:
		_build_one(parent, el, el_defs, terrain_node, asset_config)

	_print_summary(elements, el_defs)


static func spawn_one(parent: Node3D, element_id: String, pos: Vector2, terrain_node: Node, elements_config: Array, asset_config: Dictionary) -> Node:
	## Spawn a single element of the given id at the given position (top-down XZ).
	## Used by world_rules_engine for advance_stage / transform / spread effects.
	## Returns the spawned node, or null if element_id not found.
	var el_defs: Dictionary = {}
	for edef in elements_config:
		el_defs[str(edef.get("id", ""))] = edef
	if not el_defs.has(element_id):
		push_warning("[WorldElements] spawn_one: element_id not in defs: " + element_id)
		return null
	var el := {"element": element_id, "x": pos.x, "z": pos.y, "scale": 1.0, "rotation_y": 0.0}
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

	# Place on terrain. ground_mode decides how to sample under the footprint:
	#   "center" (default)  — single sample at center. Fine for small/thin objects.
	#   "min"               — sample 4 corners + center, use lowest. Good for
	#                         buildings on slopes (foundation sinks to lowest point).
	# Composites default to "min" so houses don't float over slopes.
	if terrain_node and terrain_node.has_method("get_height_at"):
		var mode: String = str(edef.get("ground_mode", "min" if obj_type == "composite" else "center"))
		var terrain_h: float = _sample_ground(terrain_node, pos, edef, mode, scale)
		pos.y = terrain_h if obj_type == "composite" else terrain_h - 0.1

	## Physics opt-in. Default: static (most things don't move). Override via
	##   elements.json field  "physics": "static" | "dynamic" | "kinematic"
	## Only objects that need gravity or are pushed around should be dynamic.
	var physics: String = str(edef.get("physics", "static"))
	var node: Node3D
	if obj_type == "entity" or obj_type == "element" or obj_type == "composite":
		match physics:
			"dynamic":
				node = RigidBody3D.new()  # falls, settles, can be pushed
			"kinematic":
				node = CharacterBody3D.new()  # manual velocity, inherits gravity in script
			_:
				node = StaticBody3D.new()  # doesn't move (trees, buildings, rocks)
		node.name = "El_" + eid + "_" + str(randi() % 10000)
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
	# Per-entity mutable state (duplicated so each instance has its own).
	# Read/written by the rules engine's state_add/state_set effects and
	# state_below/state_above conditions.
	var state_cfg = edef.get("state", null)
	if state_cfg is Dictionary:
		node.set_meta("state", state_cfg.duplicate(true))

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


static func _sample_ground(terrain_node: Node, pos: Vector3, edef: Dictionary, mode: String, scale: float) -> float:
	## Sample terrain under the element's footprint and return the height to
	## place it at, per `mode`:
	##   "center" — single sample at pos (fast, thin objects)
	##   "min"    — sample 4 corners of footprint, return lowest (buildings)
	##   "max"    — sample 4 corners, return highest (rarely useful; floats over dips)
	##   "avg"    — average of 4 corners (compromise)
	if mode == "center" or not terrain_node.has_method("get_height_at"):
		return terrain_node.get_height_at(pos.x, pos.z)

	# Use `size` or `footprint` for the XZ extent. Fallback to 1u if neither.
	var fp = edef.get("footprint", null)
	var sz = edef.get("size", null)
	var hw: float = 0.5
	var hd: float = 0.5
	if fp is Array and fp.size() >= 2:
		hw = float(fp[0]) * 0.5 * scale
		hd = float(fp[1]) * 0.5 * scale
	elif sz is Array and sz.size() >= 3:
		hw = float(sz[0]) * 0.5 * scale
		hd = float(sz[2]) * 0.5 * scale

	var samples: Array[float] = [
		terrain_node.get_height_at(pos.x, pos.z),
		terrain_node.get_height_at(pos.x - hw, pos.z - hd),
		terrain_node.get_height_at(pos.x + hw, pos.z - hd),
		terrain_node.get_height_at(pos.x - hw, pos.z + hd),
		terrain_node.get_height_at(pos.x + hw, pos.z + hd),
	]
	match mode:
		"min":
			var lo: float = samples[0]
			for s in samples:
				if s < lo: lo = s
			return lo
		"max":
			var hi: float = samples[0]
			for s in samples:
				if s > hi: hi = s
			return hi
		"avg":
			var sum: float = 0.0
			for s in samples:
				sum += s
			return sum / samples.size()
	return samples[0]  # fallback


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
