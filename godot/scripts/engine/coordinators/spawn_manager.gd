extends RefCounted
class_name SpawnManager

## Entity spawn pipeline — extracted from world.gd on 2026-05-11.
##
## Single entry point: `spawn(inst)` takes a JSON instance dict and
## registers an Entity in the World. Used by all spawn paths:
##   - boot-time `initial_instances` + pattern expansion
##   - save-game persistent-entity restore
##   - `spawn` effect from a rule
##   - `transform` effect (which removes old + spawns new)
##   - level-transition entity load
##
## Owns the renderer-config cache (lazy-loaded once from scene.json) +
## the persistent-clobber guard (Invariant #12) + the grid-snap pass
## (ADR 0038).
##
## Lives as a per-World instance (one cache per World, supports
## multi-world tests). Constructor takes a World reference; everything
## else routes through it (defs, entities map, next_id_seq, spatial_index,
## verbose flag, _build_env, add_child).
##
## Pattern matches ActorManager — RefCounted with world ref, not a
## scene-tree Node. Spawn isn't a per-frame ticker; it's an on-demand
## API.

var _world: World
var _renderer_cfg_loaded: bool = false
var _renderer_cfg: Dictionary = {}


func _init(world: World) -> void:
	_world = world


# ============================================================
# PUBLIC
# ============================================================


## Spawn an entity from a JSON instance dict. The instance specifies a
## `def` (definition id) + optional overrides (state, position, tags,
## properties, visual). Handles `count` for batch-spawn (uses
## next_id_seq for unique ids), the persistent-clobber guard
## (Invariant #12), grid snap (ADR 0038), spatial-index registration,
## and renderer-child attachment.
func spawn(inst: Dictionary) -> void:
	var def_id := str(inst.get("def", ""))
	if not _world.defs.has(def_id):
		(
			EngineError
			. raise(
				_world._build_env(),
				EngineError.WORLD_DEF_UNKNOWN,
				"Unknown def: %s" % def_id,
				{
					"file": "entities.json",
					"field": "initial_instances.def",
					"got": def_id,
					"known_defs": _world.defs.keys()
				},
				(
					"Add a definition with id '%s' under 'definitions', or fix the typo in the instance's 'def' field."
					% def_id
				)
			)
		)
		return
	var count := int(inst.get("count", 1))
	for i in range(count):
		var overrides: Dictionary = (inst.get("overrides", {}) as Dictionary).duplicate(true)
		# Accept shortcut fields at top level of initial-instance JSON
		for sc in ["state", "position", "tags", "properties", "visual"]:
			if inst.has(sc) and not overrides.has(sc):
				overrides[sc] = inst[sc]
		var inst_id := ""
		if inst.has("id") and count == 1:
			inst_id = str(inst["id"])
		else:
			inst_id = "%s_%d" % [def_id, _world.next_id_seq["_"]]
			_world.next_id_seq["_"] += 1
		# 2026-05-08: persistent-clobber guard (Invariant #12). If an
		# entity with this id already exists AND is tagged `persistent`,
		# SKIP the new instance — the persistent's state must survive
		# the level swap untouched. Without this, level entities.json
		# that re-declare a persistent (e.g. world_clock) would overwrite
		# carry-over state with their state_init defaults.
		#
		# Refinement (2026-05-08): the new level instance can still declare
		# a SPAWN POSITION for the persistent. State (HP, inventory, etc.)
		# survives the swap untouched, but the entity teleports to the new
		# level's coords. Logged as [PERSIST-TELEPORT] vs [PERSIST-SKIP].
		if _world.entities.has(inst_id):
			var existing = _world.entities[inst_id]
			if (
				existing != null
				and existing.has_method("has_tag")
				and existing.has_tag("persistent")
			):
				if inst.has("position"):
					var new_pos = inst["position"]
					if new_pos is Array and new_pos.size() >= 2:
						existing.set_position(new_pos)
						if _world.spatial_index != null:
							_world.spatial_index.update_entity(
								inst_id, existing.get_planar_position()
							)
						print(
							"[PERSIST-TELEPORT] '",
							inst_id,
							"' to ",
							new_pos,
							" (new level spawn position)"
						)
					else:
						print(
							"[PERSIST-SKIP] keeping existing persistent '",
							inst_id,
							"' (no valid position in new instance)"
						)
				else:
					print(
						"[PERSIST-SKIP] keeping existing persistent '",
						inst_id,
						"' instead of overwriting from level data"
					)
				continue
		var ent := Entity.create(_world.defs[def_id], inst_id, overrides)
		# ADR 0038: snap initial position + yaw to grid IF
		#   (a) scene.json declares a `grid` block (env.scene_grid non-empty),
		#   (b) grid.snap_initial != false (default true),
		#   (c) the def's tags don't intersect grid.exempt_tags.
		# Drift warning fires when authored position is >0.1 * grid.size from
		# the nearest cell (Condition C3 Gate B — surfaces source-JSON drift
		# in QA logs without a separate static validator).
		# Defensive: _loader may be null in test contexts that bypass
		# world.gd::_ready and inject _grid_cfg manually.
		if _world._loader != null:
			_world._loader.load_grid_cfg()
		if not _world._grid_cfg.is_empty() and bool(_world._grid_cfg.get("snap_initial", true)):
			var snap_env := {"scene_grid": _world._grid_cfg}
			if GridSnap.should_snap(_world.defs[def_id], snap_env):
				var p = ent.state.get("position", null)
				# Drift warning is verbose-mode only — fires per-entity in QA
				# logs (yume-qa-tester runs verbose=true), suppressed during
				# normal play. Snap result is identical either way.
				if p is Vector3:
					if _world.verbose:
						ent.state["position"] = GridSnap.snap_position_with_drift_check(
							p, snap_env, inst_id
						)
					else:
						ent.state["position"] = GridSnap.snap_position(p, snap_env)
				elif p is Vector2:
					ent.state["position"] = GridSnap.snap_position_2d(p, snap_env)
				if ent.state.has("yaw"):
					ent.state["yaw"] = GridSnap.snap_yaw(float(ent.state["yaw"]), snap_env)
		_world.entities[inst_id] = ent
		_world.add_child(ent)
		_attach_renderer(ent)
		# Register in spatial index at initial position
		if _world.spatial_index != null:
			_world.spatial_index.update_entity(inst_id, ent.get_planar_position())
		# ADR 0044 Session A: create PhysicsServer3D body if the def
		# declares a `physics` block (or translates from legacy
		# blocks_motion+aabb_extents). Body is INERT for Session A —
		# legacy _integrate_motion still drives motion; Session B routes
		# velocity to bodies; Session C disables the legacy path.
		_build_physics_body_if_declared(ent)


# ============================================================
# INTERNAL — renderer attachment
# ============================================================


## Attach a renderer child to an entity, if `renderer_script` is set.
## No-op for headless/test runs that set it to "".
func _attach_renderer(ent: Entity) -> void:
	if _world.renderer_script == "":
		return
	# Honor `visual.hidden=true` — entities with no visual representation
	# (singletons like clocks, score trackers, world state holders). Without
	# this, the renderer falls through to the default colored-box and the
	# entity shows as a pink/grey square at its position. Empirically caught
	# during towerdef3d capture (2026-05-03).
	if bool((ent.visual as Dictionary).get("hidden", false)):
		return
	# `visual.hide_for_camera_attach=true` is now a SHADOW-ONLY flag, not
	# a skip. The renderer reads it and applies SHADOW_CASTING_SETTING_
	# SHADOWS_ONLY to its mesh children — the mesh disappears from the
	# viewer's camera but still casts a shadow on the ground. Doom/CSGO
	# pattern: viewer sees only the viewmodel hand/weapon, but their
	# shadow on the floor reveals their full body. (Empirically caught
	# during doomarena3d 2026-05-04 playtest: "i see only gun shadow.")
	var script := load(_world.renderer_script)
	if script == null:
		return
	var node = script.new()
	if node is Node:
		# Allow per-game override of renderer's position_scale (and similar
		# exported props) via scene.json's `renderer` block. Tier 2.6q —
		# fpsgarden authors in world units (radius 13 = 13 meters) and
		# needs position_scale=1; existing 2D demos use the default 0.05
		# (200 pixels → 10 world units).
		_apply_renderer_overrides(node)
		ent.add_child(node)


## Lazy-load scene.json's renderer block into _renderer_cfg.
## Idempotent — first call populates, subsequent calls no-op.
func _ensure_renderer_cfg() -> void:
	if _renderer_cfg_loaded:
		return
	_renderer_cfg_loaded = true
	var scene_path: String = _world.data_root.rstrip("/") + "/scene.json"
	if FileAccess.file_exists(scene_path):
		var f := FileAccess.open(scene_path, FileAccess.READ)
		var data = JSON.parse_string(f.get_as_text())
		if data is Dictionary:
			var cfg = (data as Dictionary).get("renderer", {})
			if cfg is Dictionary:
				_renderer_cfg = cfg


## Apply scene.json's renderer block (e.g. position_scale) to a renderer
## node. Reads from the cached config; loads if not yet populated.
func _apply_renderer_overrides(node) -> void:
	_ensure_renderer_cfg()
	for k in _renderer_cfg.keys():
		# Only set props the renderer actually exposes
		if node.get(str(k)) != null or k in node:
			node.set(str(k), _renderer_cfg[k])


## Public accessor for renderer_cfg — MultiMeshDirector reads
## position_scale from here instead of re-parsing scene.json.
func renderer_cfg() -> Dictionary:
	_ensure_renderer_cfg()
	return _renderer_cfg


# ============================================================
# ADR 0044 — PHYSICS BODY LIFECYCLE
# ============================================================


## Unified despawn path. Called by LevelTransitionCoordinator (level
## swap), WorldResetCoordinator (New Game), and EffectApply._remove
## (the `remove` effect from a rule). Frees the physics body BEFORE
## the Entity Node is freed (per ADR 0044 Condition 4 — body leak
## prevention).
func despawn(inst_id: String) -> void:
	var ent = _world.entities.get(inst_id, null)
	if ent == null:
		return
	# Free physics body (no-op if entity has none)
	PhysicsBodyBuilder.free_3d(ent)
	# Existing cleanup
	if _world.relations != null:
		_world.relations.clear_entity(inst_id)
	if _world.spatial_index != null and _world.spatial_index.has_method("remove_entity"):
		_world.spatial_index.remove_entity(inst_id)
	_world.entities.erase(inst_id)
	ent.queue_free()


# ============================================================
# INTERNAL — physics body creation (ADR 0044 Session A)
# ============================================================


## If the entity's def declares a `physics` block (or has legacy
## `blocks_motion` tag + `properties.aabb_extents`), build a body via
## PhysicsBodyBuilder and stamp the body on the entity as meta
## `_physics_body`. Variant value:
##   - RID for body_type ∈ {static, kinematic, rigid, area}
##   - CharacterBody3D Node for body_type == "character" (ADR 0045)
##
## No-op when:
##   - Def has no physics block AND no blocks_motion tag
##   - World has no 3D physics space (scene is 2D-only)
##
## 2D handling (PhysicsServer2D) lands in a later sub-step per
## ADR 0044 Condition 9.
func _build_physics_body_if_declared(ent: Entity) -> void:
	if _world == null:
		return
	# Read def + check if physics applies. Translation handles
	# the legacy blocks_motion path too.
	var def: Dictionary = _world.defs.get(ent.def_id, {})
	var phys_cfg := PhysicsBodyBuilder.translate_blocks_motion(def)
	if phys_cfg.is_empty():
		return
	var space := _resolve_3d_space()
	if not space.is_valid():
		return
	var layer_map := _resolve_layer_map()
	# ADR 0045: character bodies are CharacterBody3D scene Nodes, not
	# raw PhysicsServer3D RIDs. Dispatch here.
	var body_type := str(phys_cfg.get("body_type", ""))
	if body_type == "character":
		PhysicsBodyBuilder.build_character_3d(ent, phys_cfg, layer_map)
	else:
		PhysicsBodyBuilder.build_3d(ent, phys_cfg, space, layer_map)
	# Static bodies use PhysicsServer3D RIDs (not scene-tree nodes), so
	# Godot's built-in debug_collisions_hint can't render their wireframes.
	# When debug-colliders is on, also attach a MeshInstance3D with a
	# wireframe BoxMesh to make the static collider visible. Skipped for
	# character bodies (their CollisionShape3D child IS picked up by
	# the built-in viz). Task #123, 2026-05-24.
	if body_type != "character":
		_maybe_build_collider_debug_viz(ent, phys_cfg)


## Render a wireframe box matching the static collider's shape/offset.
## Only fires when get_tree().debug_collisions_hint is true (set in
## World._apply_debug_flags from cmdline / scene.json).
func _maybe_build_collider_debug_viz(ent: Entity, phys_cfg: Dictionary) -> void:
	if _world == null:
		return
	var tree := _world.get_tree()
	if tree == null or not tree.debug_collisions_hint:
		return
	var shape_cfg = phys_cfg.get("collision_shape", null)
	if not (shape_cfg is Dictionary):
		return
	if str(shape_cfg.get("type", "")) != "box":
		return
	var size_arr = shape_cfg.get("size", [1, 1, 1])
	if not (size_arr is Array) or (size_arr as Array).size() < 3:
		return
	var off_arr = shape_cfg.get("offset", [0, 0, 0])
	var off_v := Vector3(
		float(off_arr[0]) if off_arr is Array and off_arr.size() >= 1 else 0.0,
		float(off_arr[1]) if off_arr is Array and off_arr.size() >= 2 else 0.0,
		float(off_arr[2]) if off_arr is Array and off_arr.size() >= 3 else 0.0,
	)
	# Build a 12-line wireframe box (8 corners + 12 edges). Filled
	# translucent boxes stack badly when multiple structures overlap
	# the view — the screen turns solid green. Lines only render
	# where edges are, so 50 wireframes don't compose into a wall of color.
	var sx = float(size_arr[0]) * 0.5
	var sy = float(size_arr[1]) * 0.5
	var sz = float(size_arr[2]) * 0.5
	var corners = [
		Vector3(-sx, -sy, -sz), Vector3( sx, -sy, -sz),
		Vector3( sx, -sy,  sz), Vector3(-sx, -sy,  sz),
		Vector3(-sx,  sy, -sz), Vector3( sx,  sy, -sz),
		Vector3( sx,  sy,  sz), Vector3(-sx,  sy,  sz),
	]
	var edges = [
		[0,1],[1,2],[2,3],[3,0],  # bottom
		[4,5],[5,6],[6,7],[7,4],  # top
		[0,4],[1,5],[2,6],[3,7],  # verticals
	]
	var verts := PackedVector3Array()
	for e in edges:
		verts.append(corners[e[0]])
		verts.append(corners[e[1]])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	for v in verts:
		st.add_vertex(v)
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 1.0, 0.4, 1.0)
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	# Honor depth test: wireframes occlude each other (and get
	# occluded by world geometry) via the Z-buffer. Without this,
	# every wireframe in the 15m radius rendered ON TOP of every
	# other one through walls + meshes, turning the scene into a
	# tangle of overlapping green lines. With proper depth, you
	# only see the box of the structure you're currently looking at;
	# distant boxes get clipped behind closer geometry.
	mat.no_depth_test = false
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "_DebugCollider_%s" % str(ent.instance_id)
	mi.mesh = mesh
	# Register in a group so GameShell._cull_debug_colliders_by_distance
	# can hide wireframes far from the active Camera3D (otherwise 200+
	# overlapping wireframes turn the screen into a tangle of green lines).
	mi.add_to_group("_yume_debug_collider")
	# Parent directly to the world root and use GLOBAL positioning so the
	# wireframe is immune to the renderer's transforms — namely
	#   1. visual.y_offset / y_offset_mesh (a y-lift to keep bbox-centered
	#      Tripo3D meshes from sinking), and
	#   2. state.scale (the renderer scales itself by 4.5x for huts, so a
	#      child wireframe parented there would render 4.5x oversized).
	# Both were silently corrupting the wireframe earlier — the box rendered
	# many meters too large and floated above its body. Computing the body's
	# actual global position here, then dropping the wireframe at that exact
	# spot in world space, sidesteps the whole inheritance chain. The real
	# PhysicsServer3D body sits at entity.position * position_scale (NO
	# visual lift, NO scale) with shape offset = collision_shape.offset
	# (already in world units, already scale-baked by validate_aabb_extents).
	# Mirror that math exactly. 2026-05-24.
	var pos = ent.get_position() if ent.has_method("get_position") else null
	var pos_scale := float(renderer_cfg().get("position_scale", 0.05))
	var body_world_pos := Vector3.ZERO
	if pos is Vector3:
		body_world_pos = pos * pos_scale
	elif pos is Vector2:
		body_world_pos = Vector3(pos.x * pos_scale, 0.0, pos.y * pos_scale)
	body_world_pos += off_v
	_world.add_child(mi)
	mi.global_position = body_world_pos


## Resolve the 3D physics space RID for the current scene. Returns
## RID() if the scene isn't 3D (no World3D).
func _resolve_3d_space() -> RID:
	var vp := _world.get_viewport() if _world.has_method("get_viewport") else null
	if vp == null:
		return RID()
	var w3d := vp.find_world_3d() if vp.has_method("find_world_3d") else null
	if w3d == null:
		return RID()
	return w3d.space


## Resolve the collision layer name → bit map from
## @lib.physics.layers.layers. Cached on World after first call.
func _resolve_layer_map() -> Dictionary:
	if _world.has_meta("_physics_layer_map"):
		return _world.get_meta("_physics_layer_map")
	var layers_doc = LibResolver.resolve("@lib.physics.layers")
	var layer_map: Dictionary = {}
	if layers_doc is Dictionary:
		var layers = (layers_doc as Dictionary).get("layers", {})
		if layers is Dictionary:
			layer_map = layers
	_world.set_meta("_physics_layer_map", layer_map)
	return layer_map
