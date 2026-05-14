extends Node
class_name MultiMeshDirector

## ADR 0041 — Static-decoration render batching via MultiMeshInstance3D.
##
## Static entities (eligible mesh + no animations + no mutation rules +
## not actor/projectile/player + no velocity) are grouped by
## (mesh_def_id, primitive_index) and rendered as ONE MultiMeshInstance3D
## per group, regardless of N. This collapses ~3000 draw calls (Aldenmere
## forest) into ~30.
##
## Wiring (per ADR 0041):
##   - `scan_and_batch(env)` — called by world.gd AFTER _spawn_initial
##     completes (and after each level transition's new-level spawn).
##   - `cleanup(env)` — called BEFORE _do_level_transition's new spawn.
##     Frees all MultiMeshInstance3D nodes the director built.
##   - `try_promote(env, entity_id)` — called by effect_apply.gd when a
##     state mutation hits a tracked field on a multimesh-managed entity.
##     Promotion is deferred under screen_freeze_world / overlay_freeze_world
##     (Invariant #10) — the pending list drains on freeze release.
##
## Engine-managed tag `_multimesh_managed` (underscore prefix per convention)
## gates the per-entity render path's skip in entity_mesh_3d.gd::_ready.
##
## Static detection (per ADR 0041 §1):
##   - mesh def declares `multimesh_eligible: true` (opt-in, default false)
##   - mesh def has NO `animations` block (animated meshes need per-entity)
##   - entity is NOT tagged actor / projectile / player (defensive — these
##     imply runtime motion / animation)
##   - entity has no velocity or velocity == zero
##   - NO rule's effect mutates one of MUTATION_FIELDS on entities matching
##     this entity's tag set (tag-class-level disqualification — conservative
##     but correct)
##   - entity's state.tint (if set) matches mesh-def's params (so the
##     batched shared material renders correctly)

# Fields a rule may mutate that would invalidate the static assumption.
# Each disqualifies the targeted entity's tag class from multimesh batching.
# Grep-friendly constant — yume-asset-designer skill references it.
const MUTATION_FIELDS := [
	"position",
	"scale",
	"yaw",
	"velocity",
	"tint",
	"color",
	"material_override",
]

# Tag-mutating effect types also disqualify (tag changes can re-route
# grouping or visual).
const TAG_MUTATION_EFFECTS := ["tag_add", "tag_remove"]

# Engine-managed tag — content authors never set this directly.
const MANAGED_TAG := "_multimesh_managed"

# State carried across calls
var _built_nodes: Array = []  # MultiMeshInstance3D nodes we created
var _pending_promotions: Array[String] = []  # entity ids waiting for freeze release
var _world_node: Node = null  # parent for MultiMeshInstance3D
var _position_scale: float = 1.0  # renderer's position_scale (read from cfg)


func _init() -> void:
	# Static-only module instantiated by world.gd. Holds per-world state.
	pass


## Configure the director with the world parent + renderer's position_scale.
## position_scale matters because per-entity positions live in pixel-scale
## (2D convention) and 3D scenes downscale by the renderer's setting.
## MultiMesh transforms operate in WORLD units, so we mirror the renderer.
##
## world_node is the World node — it's a Node, not a Node3D, but MultiMesh
## children are added directly to it (the scene tree handles the 3D context).
func configure(world_node: Node, position_scale: float) -> void:
	_world_node = world_node
	_position_scale = position_scale


## Main entry point — called by world.gd after _spawn_initial. Detects
## static entities, groups them, builds MultiMeshInstance3D per group.
##
## Returns count of (entities, groups, instances) for logging.
func scan_and_batch(env: Dictionary) -> Dictionary:
	if _world_node == null:
		return {"entities": 0, "groups": 0, "instances": 0}
	var entities: Dictionary = env.get("entities", {})
	var defs: Dictionary = env.get("defs", {})
	var rules: Array = _gather_rules(env)
	var disqualified_tags := _scan_disqualified_tag_classes(rules)

	# Group eligible entities by (mesh_def_id, primitive_index, params_key)
	# where params_key is a stable hash of per-instance material params so
	# entities with different tints land in different MultiMeshes.
	var groups: Dictionary = {}  # group_key -> Array of entity dicts
	var managed_ids: Array[String] = []

	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity):
			continue
		var e: Entity = ent
		if not _is_static_candidate(e, defs, disqualified_tags):
			continue
		var mesh_def: Dictionary = _mesh_def_for(e, defs, env)
		if mesh_def.is_empty():
			continue
		var prims: Array = mesh_def.get("primitives", [])
		var resolved_params := MeshLib.merge_params(
			mesh_def, (e.visual as Dictionary).get("params", {})
		)
		var params_key := _hash_params(resolved_params)
		for prim_idx in range(prims.size()):
			var key := "%s|%d|%s" % [_mesh_id_for(e), prim_idx, params_key]
			if not groups.has(key):
				groups[key] = {
					"mesh_def": mesh_def,
					"params": resolved_params,
					"prim_idx": prim_idx,
					"entities": [],
				}
			(groups[key]["entities"] as Array).append(e)
		managed_ids.append(str(id))

	# Apply managed tag + remove per-entity renderer for each managed
	# entity. (Renderer is already attached at this point — we clean up.)
	for mid in managed_ids:
		var me: Entity = entities[mid]
		if not me.has_tag(MANAGED_TAG):
			me.tags.append(MANAGED_TAG)
		_remove_entity_renderer(me)

	# Build one MultiMeshInstance3D per group.
	var total_instances: int = 0
	for key in groups.keys():
		var g: Dictionary = groups[key]
		var built := _build_multimesh_for_group(g)
		if built != null:
			_built_nodes.append(built)
			total_instances += (g["entities"] as Array).size()

	return {
		"entities": managed_ids.size(),
		"groups": groups.size(),
		"instances": total_instances,
	}


## Per Invariant #11 — clean up MultiMeshInstance3D nodes before the new
## level spawns. The corresponding entities are being destroyed by the
## level swap; the multimesh nodes are the only remaining reference.
func cleanup(_env: Dictionary) -> int:
	var freed: int = 0
	for node in _built_nodes:
		if node != null and is_instance_valid(node):
			node.queue_free()
			freed += 1
	_built_nodes.clear()
	_pending_promotions.clear()
	return freed


## Per ADR 0041 §4 — when a state mutation hits a tracked field on a
## managed entity, promote it: remove from multimesh, restore per-entity
## renderer.
##
## Defers under freeze (Invariant #10). The pending list drains via
## drain_pending_promotions() on freeze release.
func try_promote(env: Dictionary, entity_id: String) -> void:
	var world_state: Dictionary = env.get("world", {})
	var frozen := (
		int(world_state.get("screen_freeze_world", 0)) != 0
		or int(world_state.get("overlay_freeze_world", 0)) != 0
	)
	if frozen:
		if not _pending_promotions.has(entity_id):
			_pending_promotions.append(entity_id)
			push_warning("[MULTIMESH-PROMOTE-DEFERRED] entity=%s reason=freeze" % entity_id)
		return
	_apply_promotion(env, entity_id)


## Called by world.gd::_process tick branch at the start of every non-frozen tick to
## drain the deferred promotion queue. Cheap when queue is empty.
func drain_pending_promotions(env: Dictionary) -> void:
	if _pending_promotions.is_empty():
		return
	var to_drain := _pending_promotions.duplicate()
	_pending_promotions.clear()
	for eid in to_drain:
		_apply_promotion(env, eid)


# ============================================================
# INTERNAL — static detection
# ============================================================


func _is_static_candidate(e: Entity, _defs: Dictionary, disqualified_tags: Dictionary) -> bool:
	if e.has_tag("actor") or e.has_tag("projectile") or e.has_tag("player"):
		return false
	# Existing velocity disqualifies — entity is already moving.
	var v = e.get_velocity()
	if v is Vector2 and v != Vector2.ZERO:
		return false
	if v is Vector3 and v != Vector3.ZERO:
		return false
	# Tag-class disqualification: if ANY of the entity's tags appears in
	# disqualified_tags, the entity falls through. Conservative — a rule
	# that mutates one entity's position disqualifies the whole tag class.
	for t in e.tags:
		if disqualified_tags.has(t):
			return false
	# Must have multimesh_eligible mesh def (checked elsewhere via
	# _mesh_def_for; if no eligible mesh def, the entity won't be added
	# to groups regardless).
	return true


func _mesh_def_for(e: Entity, _defs: Dictionary, _env: Dictionary) -> Dictionary:
	# Read mesh name from visual.mesh or visual.shape (renderer fallback).
	var visual: Dictionary = e.visual as Dictionary
	var mesh_name := str(visual.get("mesh", visual.get("shape", "")))
	if mesh_name == "":
		return {}
	# Need access to the MeshLib for the eligibility check. World.gd
	# doesn't pass it directly; we look it up via parent (renderer
	# instance has it cached). Cheap fallback: use the static cache
	# in EntityMesh3D.
	var lib = EntityMesh3D._mesh_lib_cache if EntityMesh3D._mesh_lib_cache != null else null
	if lib == null or not lib.has(mesh_name):
		return {}
	var def := lib.get_mesh(mesh_name)
	if not bool(def.get("multimesh_eligible", false)):
		return {}
	# Animated mesh defs are never static.
	if def.has("animations"):
		return {}
	return def


func _mesh_id_for(e: Entity) -> String:
	var visual: Dictionary = e.visual as Dictionary
	return str(visual.get("mesh", visual.get("shape", "")))


## Stable params hash so entities with different tints land in different
## groups (multimesh shares one material per group).
func _hash_params(params: Dictionary) -> String:
	var keys: Array = params.keys()
	keys.sort()
	var out := ""
	for k in keys:
		out += "%s=%s;" % [str(k), str(params[k])]
	return out


## Scan rule effects; return a dict whose keys are entity-tags such that
## SOME rule's effect could mutate one of MUTATION_FIELDS on entities
## matching that tag. Conservative: a rule that targets tag "tree" via
## query disqualifies ALL entities tagged "tree" from batching.
func _scan_disqualified_tag_classes(rules: Array) -> Dictionary:
	var out: Dictionary = {}
	for r in rules:
		if not (r is Rule):
			continue
		var rule: Rule = r
		# Effects can be a single dict or an array
		var effs = rule.effects if rule.effects is Array else []
		# Determine the tags this rule's query matches (the candidate set).
		var qtags := _tags_from_query(rule.query)
		if qtags.is_empty():
			continue
		for ef in effs:
			if not (ef is Dictionary):
				continue
			var ef_dict: Dictionary = ef
			var et := str(ef_dict.get("type", ""))
			# Tag-mutating effects disqualify too.
			if et in TAG_MUTATION_EFFECTS:
				for t in qtags:
					out[t] = true
				continue
			# state_set / state_add / state_mul / state_clamp on a mutation field
			var field := str(ef_dict.get("field", ""))
			if field != "" and MUTATION_FIELDS.has(field):
				for t in qtags:
					out[t] = true
				continue
			# velocity_set / velocity_lerp / velocity_set_relative / velocity_add_relative
			if et.begins_with("velocity_"):
				for t in qtags:
					out[t] = true
				continue
	return out


func _tags_from_query(q) -> Array:
	if not (q is Dictionary):
		return []
	var spec: Dictionary = q
	# Flat tags_all
	if spec.has("tags_all"):
		return spec["tags_all"]
	# Sub-bindings (a, b, target, actor, etc.) — gather tags from each
	var out: Array = []
	for k in spec.keys():
		var v = spec[k]
		if v is Dictionary and v.has("tags_all"):
			for t in v["tags_all"]:
				if not out.has(t):
					out.append(t)
	return out


func _gather_rules(env: Dictionary) -> Array:
	# Pull from scheduler if available; the env doesn't carry rules directly.
	var parent_node = env.get("parent", null)
	if parent_node == null:
		return []
	var sched = parent_node.get("scheduler")
	if sched == null:
		return []
	var by_trigger: Dictionary = sched.get("rules_by_trigger")
	if by_trigger == null:
		return []
	var out: Array = []
	for k in by_trigger.keys():
		for r in by_trigger[k]:
			out.append(r)
	return out


# ============================================================
# INTERNAL — MultiMesh build
# ============================================================


func _build_multimesh_for_group(g: Dictionary) -> MultiMeshInstance3D:
	var mesh_def: Dictionary = g["mesh_def"]
	var params: Dictionary = g["params"]
	var prim_idx: int = g["prim_idx"]
	var ents: Array = g["entities"]
	if ents.is_empty():
		return null
	var prims: Array = mesh_def.get("primitives", [])
	if prim_idx >= prims.size():
		return null
	var prim: Dictionary = prims[prim_idx]

	# Build the primitive's Mesh once (shared across all instances).
	var mesh := _build_mesh_for_primitive(prim, params)
	if mesh == null:
		return null

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = ents.size()

	# Per-instance transform = entity_transform * primitive_local_transform
	var prim_pos := _to_vec3(_param_resolve(prim.get("pos", [0, 0, 0]), params))
	var prim_rot := Vector3.ZERO
	if prim.has("rotation_deg"):
		var rd := _to_vec3(prim["rotation_deg"])
		prim_rot = Vector3(deg_to_rad(rd.x), deg_to_rad(rd.y), deg_to_rad(rd.z))

	for i in range(ents.size()):
		var e: Entity = ents[i]
		var ep := _entity_world_pos(e)
		var sc := _entity_scale(e)
		var yw := float(e.get_state("yaw", 0.0))

		var t := Transform3D()
		# Compose: primitive local pos rotated by entity yaw, then translated
		# by entity world pos, scaled by entity scale.
		var local_offset := Vector3(prim_pos.x * sc.x, prim_pos.y * sc.y, prim_pos.z * sc.z)
		# Yaw rotation around Y axis
		if yw != 0.0:
			var cs := cos(yw)
			var sn := sin(yw)
			local_offset = Vector3(
				local_offset.x * cs + local_offset.z * sn,
				local_offset.y,
				-local_offset.x * sn + local_offset.z * cs,
			)
		t.origin = ep + local_offset
		# Basis: yaw rotation then per-instance scale, plus primitive's own rotation.
		var b := Basis()
		if yw != 0.0:
			b = b.rotated(Vector3.UP, yw)
		if prim_rot != Vector3.ZERO:
			b = b * Basis.from_euler(prim_rot)
		b = b.scaled(sc)
		t.basis = b
		mm.set_instance_transform(i, t)

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	# Material override applies to all instances of this group.
	var color = _param_resolve(prim.get("color", "#ffffff"), params)
	mmi.material_override = MeshLib._make_material(_parse_color(color))
	# Shadow flag — mesh-def cast_shadow cascades, per-primitive override wins.
	var mesh_cast := bool(mesh_def.get("cast_shadow", true))
	var prim_cast := bool(prim.get("cast_shadow", mesh_cast))
	if not prim_cast:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world_node.add_child(mmi)
	return mmi


func _build_mesh_for_primitive(p: Dictionary, params: Dictionary) -> Mesh:
	var op := str(p.get("op", ""))
	match op:
		"box":
			var size := _to_vec3(_param_resolve(p.get("size", [1, 1, 1]), params))
			var m := BoxMesh.new()
			m.size = size
			return m
		"sphere":
			var r := float(_param_resolve(p.get("radius", 0.5), params))
			var m2 := SphereMesh.new()
			m2.radius = r
			m2.height = r * 2.0
			return m2
		"cylinder":
			var r2 := float(_param_resolve(p.get("radius", 0.3), params))
			var h := float(_param_resolve(p.get("height", 1.0), params))
			var m3 := CylinderMesh.new()
			m3.top_radius = r2
			m3.bottom_radius = r2
			m3.height = h
			return m3
		"capsule":
			var r3 := float(_param_resolve(p.get("radius", 0.3), params))
			var h2 := float(_param_resolve(p.get("height", 1.0), params))
			var m4 := CapsuleMesh.new()
			m4.radius = r3
			m4.height = h2
			return m4
		"plane":
			var sz := _to_vec2(_param_resolve(p.get("size", [1, 1]), params))
			var m5 := PlaneMesh.new()
			m5.size = sz
			return m5
		"prism":
			var sz2 := _to_vec3(_param_resolve(p.get("size", [1, 1, 1]), params))
			var m6 := PrismMesh.new()
			m6.size = sz2
			return m6
		"torus":
			var inner := float(_param_resolve(p.get("inner_radius", 0.3), params))
			var outer := float(_param_resolve(p.get("outer_radius", 0.5), params))
			var m7 := TorusMesh.new()
			m7.inner_radius = inner
			m7.outer_radius = outer
			return m7
		"quad":
			var sz3 := _to_vec2(_param_resolve(p.get("size", [1, 1]), params))
			var m8 := QuadMesh.new()
			m8.size = sz3
			return m8
	return null


# ============================================================
# INTERNAL — promotion (managed → per-entity)
# ============================================================


func _apply_promotion(env: Dictionary, entity_id: String) -> void:
	var entities: Dictionary = env.get("entities", {})
	if not entities.has(entity_id):
		return
	var ent = entities[entity_id]
	if not (ent is Entity):
		return
	var e: Entity = ent
	if not e.has_tag(MANAGED_TAG):
		return
	# Find the entity's slot(s) in our built nodes and zero them.
	# (Compaction is too expensive — zero scale renders nothing.)
	_zero_multimesh_slots_for(e)
	# Remove the tag so per-entity render can take over.
	e.tags.erase(MANAGED_TAG)
	# Re-attach per-entity renderer.
	var world_node = env.get("parent", null)
	if world_node != null and world_node.has_method("_attach_renderer"):
		world_node.call("_attach_renderer", e)


## Find the slot in each MultiMesh that corresponds to entity e and zero
## its transform (effectively invisible). The slot index isn't tracked
## per-entity in v1 — we scan transforms by approximate position match.
## Acceptable for the rare promotion case.
func _zero_multimesh_slots_for(e: Entity) -> void:
	var ep := _entity_world_pos(e)
	for node in _built_nodes:
		if not (node is MultiMeshInstance3D):
			continue
		var mmi: MultiMeshInstance3D = node
		var mm := mmi.multimesh
		if mm == null:
			continue
		for i in range(mm.instance_count):
			var t := mm.get_instance_transform(i)
			if t.origin.distance_to(ep) < 0.5:  # close enough — same entity
				var zero := Transform3D()
				zero.basis = zero.basis.scaled(Vector3.ZERO)
				mm.set_instance_transform(i, zero)


func _remove_entity_renderer(e: Entity) -> void:
	# The renderer is the first child node of the entity that has _mode
	# property (set by entity_mesh_3d.gd::_ready). Remove it; the entity
	# stays for game logic.
	for child in e.get_children():
		if child.has_meta("_yume_renderer") or child.get("_mode") != null:
			e.remove_child(child)
			child.queue_free()
			return


# ============================================================
# INTERNAL — math helpers (mirror MeshLib's)
# ============================================================


func _entity_world_pos(e: Entity) -> Vector3:
	var p = e.get_position()
	if p is Vector3:
		return p * _position_scale
	if p is Vector2:
		return Vector3(p.x, 0, p.y) * _position_scale
	return Vector3.ZERO


func _entity_scale(e: Entity) -> Vector3:
	var s = e.get_state("scale", null)
	if s == null:
		return Vector3.ONE
	if s is float or s is int:
		var f := float(s)
		return Vector3(f, f, f)
	if s is Vector3:
		return s
	if s is Array:
		var a := s as Array
		if a.size() == 3:
			return Vector3(float(a[0]), float(a[1]), float(a[2]))
		if a.size() == 2:
			return Vector3(float(a[0]), float(a[0]), float(a[1]))
	return Vector3.ONE


func _param_resolve(v, params: Dictionary):
	if v is String and (v as String).begins_with("$"):
		var key := (v as String).substr(1)
		return params.get(key, v)
	return v


func _to_vec3(v) -> Vector3:
	if v is Vector3:
		return v
	if v is Vector2:
		return Vector3(v.x, v.y, 0)
	if v is Array:
		var a := v as Array
		if a.size() == 3:
			return Vector3(float(a[0]), float(a[1]), float(a[2]))
		if a.size() == 2:
			return Vector3(float(a[0]), float(a[1]), 0)
	if v is float or v is int:
		var f := float(v)
		return Vector3(f, f, f)
	return Vector3.ZERO


func _to_vec2(v) -> Vector2:
	if v is Vector2:
		return v
	if v is Array:
		var a := v as Array
		if a.size() >= 2:
			return Vector2(float(a[0]), float(a[1]))
	return Vector2.ZERO


func _parse_color(v) -> Color:
	if v is Color:
		return v
	if v is String:
		return Color(v)
	return Color.WHITE
