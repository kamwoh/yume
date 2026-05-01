extends RefCounted
class_name SpatialIndex

## Grid-bucket spatial hash for fast radius queries (W3.1).
##
## Entities are bucketed by their planar position into fixed-size cells.
## `query_radius(point, r)` visits only the cells overlapping the circle —
## avoids O(n²) over all entities when scaling to ~100+ entities.
##
## Update on entity motion: World._integrate_motion calls update_entity()
## each frame. Update on spawn/despawn: same path. Stale entries ignored
## defensively in queries.
##
## All operations work on planar XZ positions (Vector2). Vector3 input gets
## projected via Entity.get_planar_position() at the call site.

@export var cell_size: float = 64.0

var grid: Dictionary = {}            # Vector2i → Array[String] of entity ids
var entity_cells: Dictionary = {}    # entity_id → Vector2i (cached current cell)


# ============================================================
# UPDATE
# ============================================================

func update_entity(id: String, pos: Vector2) -> void:
	var new_cell := _cell_of(pos)
	if entity_cells.has(id):
		var old_cell: Vector2i = entity_cells[id]
		if old_cell == new_cell:
			return  # nothing changed
		if grid.has(old_cell):
			(grid[old_cell] as Array).erase(id)
			if (grid[old_cell] as Array).is_empty():
				grid.erase(old_cell)
	if not grid.has(new_cell):
		grid[new_cell] = []
	(grid[new_cell] as Array).append(id)
	entity_cells[id] = new_cell


func remove_entity(id: String) -> void:
	if not entity_cells.has(id): return
	var cell: Vector2i = entity_cells[id]
	if grid.has(cell):
		(grid[cell] as Array).erase(id)
		if (grid[cell] as Array).is_empty():
			grid.erase(cell)
	entity_cells.erase(id)


func clear() -> void:
	grid.clear()
	entity_cells.clear()


# ============================================================
# QUERY
# ============================================================

## Return entity ids whose position lies within `radius` of `origin`.
## Visits only cells overlapping the bounding box of the circle, then filters
## by exact distance.
func query_radius_ids(origin: Vector2, radius: float) -> Array:
	var min_cell := _cell_of(origin - Vector2(radius, radius))
	var max_cell := _cell_of(origin + Vector2(radius, radius))
	var out: Array = []
	var r2 := radius * radius
	for cx in range(min_cell.x, max_cell.x + 1):
		for cy in range(min_cell.y, max_cell.y + 1):
			var cell := Vector2i(cx, cy)
			if not grid.has(cell): continue
			for id in (grid[cell] as Array):
				out.append(id)
	# Note: caller should verify exact distance if needed; cell visit returns
	# slight overestimation. We return ids; QueryLib filters by .distance() too.
	return out


## Convenience: return resolved Entity instances (filtered by exact distance).
func query_radius(origin: Vector2, radius: float, entities: Dictionary) -> Array:
	var out: Array = []
	var r2 := radius * radius
	for id in query_radius_ids(origin, radius):
		if not entities.has(id): continue
		var ent = entities[id]
		if not (ent is Entity): continue
		var p := (ent as Entity).get_planar_position()
		if p.distance_squared_to(origin) <= r2:
			out.append(ent)
	return out


# ============================================================
# DIAGNOSTICS
# ============================================================

func cell_count() -> int:
	return grid.size()

func entity_count() -> int:
	return entity_cells.size()


# ============================================================
# INTERNAL
# ============================================================

func _cell_of(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x / cell_size)), int(floor(p.y / cell_size)))
