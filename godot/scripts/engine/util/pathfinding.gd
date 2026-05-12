extends RefCounted
class_name Pathfinding

## ADR 0024 — NPC pathfinding via Godot's NavigationServer3D.
##
## Per ADR 0021, Yume EXPOSES Godot's navigation stack rather than
## reimplementing A*. This module wires three pieces of vocabulary into
## NavigationServer3D / NavigationRegion3D / NavigationAgent3D:
##
##   tag `walkable_floor`         — contributes a walkable rectangle
##   tag `pathfinding_obstacle`   — punches a hole in the walkable region
##   effect `pathfind_to`         — sets velocity toward next path waypoint
##
## Public surface (all static — module is stateless; per-level state lives
## in env._navigation_region):
##
##   build_navmesh_for_level(env)
##     Called from World._load_level after entities load. Scans
##     env.entities for walkable_floor + pathfinding_obstacle tags,
##     builds a NavigationMesh, attaches a NavigationRegion3D to env.parent,
##     stores the region in env._navigation_region. No-op when no
##     walkable_floor entities exist (legacy levels).
##
##   teardown_navmesh(env)
##     Called from World._do_level_transition before the new level loads.
##     Frees the previous NavigationRegion3D so its agents are unbound.
##
##   tick_pathfind(env, entity, dest_x, dest_y, dest_z, speed)
##     Called by EffectApply._pathfind_to. Lazily attaches a
##     NavigationAgent3D child to entity, updates target_position,
##     reads next path point, writes velocity onto entity. No-op when
##     entity uses a Vector2 position (2D fallback per ADR 0024).
##
## Design notes:
##
## Walkable rectangles tessellate to a 1m grid; each cell whose center
## falls inside any obstacle rectangle is excluded. Each remaining cell
## becomes a 2-triangle polygon in the NavigationMesh. This approach
## avoids NavigationServer3D.bake_from_source_geometry_data() (async,
## thread-bound) and produces a deterministic mesh suitable for both
## production runs and headless unit tests.
##
## CELL_SIZE balances pathfinding granularity against mesh size. 1m
## works for kingdom-sim's city scale (radii of dozens of meters) and
## matches NavigationAgent3D's default radius.

const CELL_SIZE := 1.0

# Default agent shape — picks reasonable defaults for human-scale NPCs.
# Per-game override possible by reading from properties.* on the entity
# at attach time (deferred to a follow-up ADR if a game needs varying
# agent radii).
const DEFAULT_AGENT_RADIUS := 0.5
const DEFAULT_AGENT_HEIGHT := 1.8
const DEFAULT_TARGET_DESIRED_DISTANCE := 0.5
const DEFAULT_PATH_MAX_DISTANCE := 1.0


# ============================================================
# NAVMESH BUILD
# ============================================================

## Build the navigation mesh for the current level. Scans env.entities
## for walkable_floor + pathfinding_obstacle tags, instantiates a
## NavigationRegion3D under env.parent. Stores region in
## env._navigation_region.
##
## No-op when no walkable_floor entities exist (legacy / 2D levels).
## No-op when env.parent is null (headless contexts that don't use the
## scene tree — tests build their own region via build_mesh_data and
## skip the node attachment).
static func build_navmesh_for_level(env: Dictionary) -> void:
	teardown_navmesh(env)
	var rects := _collect_rects(env)
	var walkables: Array = rects["walkable"]
	if walkables.is_empty():
		return
	var obstacles: Array = rects["obstacle"]
	var floor_y := _floor_y_from_walkables(walkables)
	var mesh := build_mesh_data(walkables, obstacles, floor_y)
	# If env.parent isn't a Node (headless / unit-test path), the caller
	# is expected to use build_mesh_data directly. We still mark the
	# region slot empty so teardown is a no-op.
	var parent = env.get("parent", null)
	if not (parent is Node):
		return
	var region := NavigationRegion3D.new()
	region.name = "PathfindingRegion"
	region.navigation_mesh = mesh
	(parent as Node).add_child(region)
	env["_navigation_region"] = region


## Free the active navigation region (if any). Idempotent.
static func teardown_navmesh(env: Dictionary) -> void:
	var region = env.get("_navigation_region", null)
	if region != null and is_instance_valid(region):
		(region as Node).queue_free()
	env["_navigation_region"] = null


## Pure data path — given walkable + obstacle rectangles, produce a
## NavigationMesh resource. Exposed for tests (which run without a
## scene tree) and for any future re-bake logic.
static func build_mesh_data(walkables: Array, obstacles: Array, floor_y: float) -> NavigationMesh:
	var mesh := NavigationMesh.new()
	# Compute the union AABB of all walkable rectangles in XZ. This
	# anchors the cell grid to a single origin so adjacent walkable
	# rectangles produce abutting (not overlapping) cells.
	var union := _union_xz(walkables)
	if union.is_empty():
		return mesh
	var min_x: float = union["min_x"]
	var min_z: float = union["min_z"]
	var max_x: float = union["max_x"]
	var max_z: float = union["max_z"]
	var verts: PackedVector3Array = PackedVector3Array()
	# Vertex dedup keyed on quantized (cx, cz) to keep mesh tidy.
	var vert_index: Dictionary = {}
	var polygons: Array = []
	var nx := int(ceil((max_x - min_x) / CELL_SIZE))
	var nz := int(ceil((max_z - min_z) / CELL_SIZE))
	for ix in range(nx):
		for iz in range(nz):
			var cx0 := min_x + ix * CELL_SIZE
			var cz0 := min_z + iz * CELL_SIZE
			var cx1 := cx0 + CELL_SIZE
			var cz1 := cz0 + CELL_SIZE
			var center_x := (cx0 + cx1) * 0.5
			var center_z := (cz0 + cz1) * 0.5
			# Cell is included iff its center is inside SOME walkable
			# rectangle AND outside ALL obstacle rectangles. Center-test
			# is good enough for CELL_SIZE=1 with kingdom-sim scale; if
			# obstacles get smaller than CELL_SIZE this needs an
			# AABB-vs-AABB inclusion test.
			if not _point_inside_any(center_x, center_z, walkables): continue
			if _point_inside_any(center_x, center_z, obstacles): continue
			# Emit two triangles as one quad polygon. NavigationMesh
			# accepts convex polygons; a quad with consistent winding
			# (CCW when viewed from +Y) routes correctly.
			var i00 := _add_vertex(verts, vert_index, Vector3(cx0, floor_y, cz0))
			var i10 := _add_vertex(verts, vert_index, Vector3(cx1, floor_y, cz0))
			var i11 := _add_vertex(verts, vert_index, Vector3(cx1, floor_y, cz1))
			var i01 := _add_vertex(verts, vert_index, Vector3(cx0, floor_y, cz1))
			polygons.append(PackedInt32Array([i00, i10, i11, i01]))
	mesh.set_vertices(verts)
	for poly in polygons:
		mesh.add_polygon(poly)
	return mesh


# ============================================================
# AGENT TICK
# ============================================================

## Apply one tick of pathfinding for an entity. Lazy-attaches a
## NavigationAgent3D child, updates its target, reads the next path
## point, writes velocity onto the entity.
##
## No-op when:
##   - entity has a Vector2 position (2D — pathfinding is 3D-only in v1)
##   - no navmesh has been built (env._navigation_region missing/null)
##   - the agent's path is empty (NPC stays put rather than wander)
static func tick_pathfind(env: Dictionary, entity, dest_x: float, dest_y: float, dest_z: float, speed: float) -> void:
	if entity == null: return
	if not (entity is Entity): return
	var pos = (entity as Entity).get_position()
	# 2D fallback — pathfind_to is a no-op for Vector2 entities.
	if not (pos is Vector3): return
	# No navmesh region built (level didn't tag any walkable_floor) →
	# silently skip. Caller can fall back to velocity_set.
	var region = env.get("_navigation_region", null)
	if region == null or not is_instance_valid(region):
		return
	var agent: NavigationAgent3D = _ensure_agent(entity, region)
	if agent == null: return
	var dest := Vector3(dest_x, dest_y, dest_z)
	agent.target_position = dest
	# Already at target — emit zero velocity so the integrator can drag
	# the NPC to rest.
	if agent.is_target_reached():
		(entity as Entity).set_velocity(Vector3.ZERO)
		return
	var next_pt: Vector3 = agent.get_next_path_position()
	var here: Vector3 = pos
	var to_next: Vector3 = next_pt - here
	# In headless / before-first-bake situations get_next_path_position
	# can return the agent's own position. Don't divide by zero — emit
	# zero velocity so the entity stays put for this tick.
	if to_next.length() < 0.0001:
		(entity as Entity).set_velocity(Vector3.ZERO)
		return
	var dir := to_next.normalized()
	(entity as Entity).set_velocity(dir * speed)


# ============================================================
# INTERNAL — RECT COLLECTION
# ============================================================

## Scan env.entities for walkable_floor + pathfinding_obstacle tags.
## Each tagged entity contributes one XZ rectangle derived from
## entity.position (XZ center) and properties.aabb_extents (XZ
## half-extents). Y is taken from entity.position.y (used as floor
## height for walkables).
static func _collect_rects(env: Dictionary) -> Dictionary:
	var walkables: Array = []
	var obstacles: Array = []
	var ents: Dictionary = env.get("entities", {})
	for id in ents.keys():
		var ent = ents[id]
		if not (ent is Entity): continue
		var is_walk: bool = (ent as Entity).has_tag("walkable_floor")
		var is_obs: bool = (ent as Entity).has_tag("pathfinding_obstacle")
		if not is_walk and not is_obs: continue
		var ext = (ent as Entity).get_property("aabb_extents", null)
		if ext == null: continue
		var ext_v: Vector3 = Vec3Util.from_world_pos(ext)
		var pos = (ent as Entity).get_position()
		var pos_v: Vector3 = Vector3.ZERO
		if pos is Vector3: pos_v = pos
		elif pos is Vector2: pos_v = Vector3(pos.x, 0, pos.y)
		else: continue
		var rect: Dictionary = {
			"min_x": pos_v.x - ext_v.x,
			"max_x": pos_v.x + ext_v.x,
			"min_z": pos_v.z - ext_v.z,
			"max_z": pos_v.z + ext_v.z,
			"y": pos_v.y,
		}
		if is_walk: walkables.append(rect)
		if is_obs: obstacles.append(rect)
	return {"walkable": walkables, "obstacle": obstacles}


static func _union_xz(rects: Array) -> Dictionary:
	if rects.is_empty(): return {}
	var min_x: float = INF
	var min_z: float = INF
	var max_x: float = -INF
	var max_z: float = -INF
	for r in rects:
		if (r as Dictionary)["min_x"] < min_x: min_x = (r as Dictionary)["min_x"]
		if (r as Dictionary)["min_z"] < min_z: min_z = (r as Dictionary)["min_z"]
		if (r as Dictionary)["max_x"] > max_x: max_x = (r as Dictionary)["max_x"]
		if (r as Dictionary)["max_z"] > max_z: max_z = (r as Dictionary)["max_z"]
	return {"min_x": min_x, "min_z": min_z, "max_x": max_x, "max_z": max_z}


static func _floor_y_from_walkables(walkables: Array) -> float:
	# All walkables on the same Y in v1; use the first.
	if walkables.is_empty(): return 0.0
	return float((walkables[0] as Dictionary).get("y", 0.0))


static func _point_inside_any(x: float, z: float, rects: Array) -> bool:
	for r in rects:
		var d: Dictionary = r
		if x >= d["min_x"] and x <= d["max_x"] and z >= d["min_z"] and z <= d["max_z"]:
			return true
	return false


static func _add_vertex(verts: PackedVector3Array, idx_map: Dictionary, v: Vector3) -> int:
	# Quantize to mm to keep dedup robust against float drift.
	var key := "%d,%d,%d" % [int(round(v.x * 1000)), int(round(v.y * 1000)), int(round(v.z * 1000))]
	if idx_map.has(key):
		return int(idx_map[key])
	var i := verts.size()
	verts.append(v)
	idx_map[key] = i
	return i


# ============================================================
# INTERNAL — AGENT ATTACH
# ============================================================

## Find or create a NavigationAgent3D child of the entity. Idempotent.
## When created, binds it to the level's navigation map (region's map).
static func _ensure_agent(entity, region) -> NavigationAgent3D:
	if entity == null or not (entity is Node): return null
	for child in (entity as Node).get_children():
		if child is NavigationAgent3D:
			return child as NavigationAgent3D
	var agent := NavigationAgent3D.new()
	agent.name = "NavAgent"
	agent.radius = DEFAULT_AGENT_RADIUS
	agent.height = DEFAULT_AGENT_HEIGHT
	agent.target_desired_distance = DEFAULT_TARGET_DESIRED_DISTANCE
	agent.path_max_distance = DEFAULT_PATH_MAX_DISTANCE
	# avoidance_enabled defaults to false in 4.6.1; turn it on so multi-NPC
	# crowds get RVO-style local avoidance for free.
	agent.avoidance_enabled = true
	(entity as Node).add_child(agent)
	# Bind the agent to the navigation map of the region. The region
	# uses the world default map unless we set one explicitly; bind
	# the agent to the same map so its queries hit our mesh.
	if region != null and is_instance_valid(region) and region is NavigationRegion3D:
		var map_rid := (region as NavigationRegion3D).get_navigation_map()
		if map_rid.is_valid():
			agent.set_navigation_map(map_rid)
	return agent
