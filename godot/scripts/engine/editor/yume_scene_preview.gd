@tool
extends Node3D
class_name YumeScenePreview

## ADR 0073 — editor-time, READ-ONLY scene preview.
##
## Yume `.tscn` files are thin launchers; everything visible is built at
## RUNTIME from JSON. This `@tool` node, mounted as a child of `World`,
## reads the sibling `World.data_root`'s JSON IN THE EDITOR and builds a
## throwaway preview so authors can see entity layout without launching.
##
## THREE GUARANTEES (see ADR 0073):
##   1. Never persists — every built node has owner = null; all live
##      under one `_PreviewRoot` child (also owner = null). Saving the
##      .tscn bakes nothing.
##   2. Runtime no-op — when the game runs (not is_editor_hint), this
##      node does nothing; World builds the real scene.
##   3. No contagion — does NOT @tool World/Entity/EntityMesh3D. Reuses
##      only STATIC helpers (MeshLib, InstancePatterns). The small
##      replicated slice (.glb normalize + placement) is commented
##      "mirrors entity_mesh_3d.gd".
##
## BEST-EFFORT for layout, NOT a pixel match: neutral editor light (not
## the game mood), no per-entity lights / textures / animation / shaders.
## The authoritative render is still the running game + captures.

const _PREVIEW_ROOT := "_PreviewRoot"

## Toggle in the inspector to rebuild after editing JSON (no reopen).
@export var refresh_preview: bool = false:
	set(v):
		refresh_preview = false
		if Engine.is_editor_hint() and is_inside_tree():
			_rebuild()

## Override the data_root (else read from the parent World node).
@export var data_root_override: String = ""


func _ready() -> void:
	if not Engine.is_editor_hint():
		return  # runtime: World builds the real scene; we do nothing
	_rebuild.call_deferred()


# ============================================================
# BUILD
# ============================================================


## Build the preview. Callers (_ready, refresh) gate on is_editor_hint;
## this is unguarded so a headless unit test can exercise it directly.
func _rebuild() -> void:
	_clear_preview()
	var root_path := _resolve_data_root()
	if root_path == "":
		push_warning("[YumeScenePreview] no data_root (set data_root_override or add a World parent)")
		return
	var scene := _read_json(root_path + "/scene.json")
	var holder := Node3D.new()
	holder.name = _PREVIEW_ROOT
	add_child(holder)
	holder.owner = null  # never serialized
	_build_editor_light(holder)
	_build_ground(holder, scene)
	_build_entities(holder, root_path)


func _clear_preview() -> void:
	var existing := get_node_or_null(_PREVIEW_ROOT)
	if existing != null:
		existing.free()


## data_root_override wins; else the parent World's exported data_root.
func _resolve_data_root() -> String:
	if data_root_override != "":
		return data_root_override.rstrip("/")
	var p := get_parent()
	if p != null:
		var dr = p.get("data_root")
		if dr != null and str(dr) != "":
			return str(dr).rstrip("/")
	return ""


## Neutral viewing light — deliberately NOT the game's lighting mood, so
## a night scene is still legible for layout. owner=null.
func _build_editor_light(holder: Node3D) -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-55.0), deg_to_rad(40.0), 0.0)
	sun.light_energy = 1.1
	holder.add_child(sun)
	sun.owner = null
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = ProceduralSkyMaterial.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.5
	we.environment = env
	holder.add_child(we)
	we.owner = null


func _build_ground(holder: Node3D, scene: Dictionary) -> void:
	var ground = scene.get("ground", null)
	if not (ground is Dictionary):
		return
	var mesh_cfg = (ground as Dictionary).get("mesh", null)
	if not (mesh_cfg is Dictionary):
		return
	var size = (mesh_cfg as Dictionary).get("size", [50, 50])
	var pm := PlaneMesh.new()
	if size is Array and (size as Array).size() >= 2:
		pm.size = Vector2(float(size[0]), float(size[1]))
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = MeshLib._parse_color((mesh_cfg as Dictionary).get("color", "#3a3a3a"))
	mi.material_override = mat
	mi.position.y = float((ground as Dictionary).get("y", 0))
	holder.add_child(mi)
	mi.owner = null


# ============================================================
# ENTITIES (mirrors world_loader.load_entities_path, read-only)
# ============================================================


func _build_entities(holder: Node3D, root_path: String) -> void:
	var dicts: Array = []
	var single := root_path + "/entities.json"
	if FileAccess.file_exists(single):
		dicts.append(_read_json(single))
	var dir_path := root_path + "/entities"
	if DirAccess.dir_exists_absolute(dir_path):
		var dir := DirAccess.open(dir_path)
		if dir != null:
			var files: Array[String] = []
			dir.list_dir_begin()
			var fname := dir.get_next()
			while fname != "":
				if not dir.current_is_dir() and fname.ends_with(".json"):
					files.append(fname)
				fname = dir.get_next()
			files.sort()
			for f in files:
				dicts.append(_read_json(dir_path + "/" + f))
	# Also any single-level entities (best-effort; multi-level overlays all).
	var levels_dir := root_path + "/levels"
	if DirAccess.dir_exists_absolute(levels_dir):
		var ld := DirAccess.open(levels_dir)
		if ld != null:
			ld.list_dir_begin()
			var sub := ld.get_next()
			while sub != "":
				if ld.current_is_dir() and not sub.begins_with("."):
					var lf := levels_dir + "/" + sub + "/entities.json"
					if FileAccess.file_exists(lf):
						dicts.append(_read_json(lf))
				sub = ld.get_next()

	# Phase 1: merge definitions by id (last wins, matching the engine).
	var defs: Dictionary = {}
	for d in dicts:
		for de in d.get("definitions", []):
			if de is Dictionary:
				defs[str(de.get("id", ""))] = de
	# Phase 2: instances + pattern expansion (reuse the runtime expander).
	var instances: Array = []
	for d in dicts:
		for p in d.get("patterns", []):
			if p is Dictionary:
				for inst in InstancePatterns.expand(p, 0):
					instances.append(inst)
		for inst in d.get("initial_instances", []):
			if inst is Dictionary:
				instances.append(inst)

	var count := 0
	for inst in instances:
		var node := _build_instance(inst, defs)
		if node != null:
			holder.add_child(node)
			_set_owner_null_recursive(node)
			count += 1
	if count == 0:
		push_warning("[YumeScenePreview] no visible entities found under %s" % root_path)


## Build one instance's visual subtree. Returns null for hidden/logical
## entities (cameras, singletons) — matching spawn_manager's skip.
func _build_instance(inst: Dictionary, defs: Dictionary) -> Node3D:
	var def_id := str(inst.get("def", ""))
	var def: Dictionary = defs.get(def_id, {})
	if def.is_empty():
		return null
	var visual: Dictionary = def.get("visual", {})
	if bool(visual.get("hidden", false)):
		return null

	# Merged state (state_init + per-instance state overrides).
	var state: Dictionary = (def.get("state_init", {}) as Dictionary).duplicate(true)
	var inst_state = inst.get("state", null)
	if inst_state is Dictionary:
		for k in (inst_state as Dictionary):
			state[k] = (inst_state as Dictionary)[k]

	var node := Node3D.new()
	node.name = str(inst.get("id", def_id))

	# --- mesh (mirrors entity_mesh_3d.gd tiers) ---
	var mesh_field := str(visual.get("mesh", visual.get("shape", "")))
	var normalized_glb := false
	if mesh_field.ends_with(".glb") or mesh_field.ends_with(".gltf"):
		normalized_glb = _build_glb(node, mesh_field)
	elif mesh_field != "":
		var lib := _get_lib()
		if lib != null and lib.has(mesh_field):
			var mesh_def := lib.get_mesh(mesh_field)
			var params := MeshLib.merge_params(mesh_def, visual.get("params", {}) as Dictionary)
			MeshLib.build_primitives_into(
				node, mesh_def.get("primitives", []), params, true
			)
		else:
			_build_bare_box(node, visual)
	else:
		_build_bare_box(node, visual)

	# --- placement (mirrors _sync_position / _sync_scale / _sync_yaw) ---
	var ps := 1.0  # preview assumes world-units; validate_position_scale gates 3D demos
	var pos = inst.get("position", state.get("position", [0, 0, 0]))
	if pos is Array and (pos as Array).size() >= 3:
		node.position = Vector3(float(pos[0]), float(pos[1]), float(pos[2])) * ps
	_apply_scale(node, state.get("scale", null), normalized_glb)
	var yaw := float(state.get("yaw", 0.0))
	yaw += float((def.get("properties", {}) as Dictionary).get("mesh_yaw_offset", 0.0))
	node.rotation.y = yaw
	return node


## .glb: load, normalize to unit-height/base-on-ground. Returns true on
## success (caller then scales uniformly by state.scale.y).
## Mirrors entity_mesh_3d.gd _normalize_glb + _local_aabb.
func _build_glb(node: Node3D, path: String) -> bool:
	if not ResourceLoader.exists(path):
		return false
	var packed = load(path)
	if not (packed is PackedScene):
		return false
	var inst = (packed as PackedScene).instantiate()
	if not (inst is Node3D):
		return false
	var norm := Node3D.new()
	node.add_child(norm)
	norm.add_child(inst)
	var aabb: AABB = (inst as Node3D).transform * _local_aabb(inst as Node3D)
	if aabb.size.y > 0.0001:
		var s := 1.0 / aabb.size.y
		norm.scale = Vector3(s, s, s)
		norm.position = Vector3(
			-(aabb.position.x + aabb.size.x * 0.5) * s,
			-aabb.position.y * s,
			-(aabb.position.z + aabb.size.z * 0.5) * s
		)
	return true


func _local_aabb(node: Node3D) -> AABB:
	var out := AABB()
	var seeded := false
	if node is MeshInstance3D:
		out = (node as MeshInstance3D).get_aabb()
		seeded = true
	for c in node.get_children():
		if c is Node3D:
			var child_aabb: AABB = (c as Node3D).transform * _local_aabb(c as Node3D)
			if child_aabb.size == Vector3.ZERO:
				continue
			out = out.merge(child_aabb) if seeded else child_aabb
			seeded = true
	return out


## glb normalized → uniform height scale (state.scale.y); kits/prims →
## anisotropic. Mirrors entity_mesh_3d.gd _sync_scale.
func _apply_scale(node: Node3D, s, normalized_glb: bool) -> void:
	if s == null:
		return
	if normalized_glb:
		var h := 1.0
		if s is float or s is int:
			h = float(s)
		elif s is Array and (s as Array).size() >= 2:
			h = float((s as Array)[1])
		node.scale = Vector3(h, h, h)
		return
	if s is float or s is int:
		var f := float(s)
		node.scale = Vector3(f, f, f)
	elif s is Array:
		var a := s as Array
		if a.size() == 3:
			node.scale = Vector3(float(a[0]), float(a[1]), float(a[2]))
		elif a.size() == 2:
			node.scale = Vector3(float(a[0]), float(a[0]), float(a[1]))


func _build_bare_box(node: Node3D, visual: Dictionary) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	var sz := float(visual.get("size", 0.5))
	box.size = Vector3(sz, sz, sz)
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = MeshLib._parse_color(visual.get("color", "#b0b0b0"))
	mi.material_override = mat
	node.add_child(mi)


# ============================================================
# HELPERS
# ============================================================


var _lib_cache: MeshLib = null


func _get_lib() -> MeshLib:
	if _lib_cache == null:
		_lib_cache = MeshLib.load_from_file("res://data/meshes.json")
	return _lib_cache


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data = JSON.parse_string(f.get_as_text())
	return data if data is Dictionary else {}


func _set_owner_null_recursive(node: Node) -> void:
	node.owner = null
	for c in node.get_children():
		_set_owner_null_recursive(c)
