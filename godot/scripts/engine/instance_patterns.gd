extends RefCounted
class_name InstancePatterns

## Tier 2.6q — declarative instance placement patterns.
##
## Lets entities/zz_instances.json (and similar) declare placements via
## intent rather than hand-typed coordinates:
##
##   {
##     "patterns": [
##       {"def": "tree", "pattern": "ring",  "count": 8, "radius": 13},
##       {"def": "rock", "pattern": "scatter", "count": 12,
##                       "min_r": 2, "max_r": 8, "min_spacing": 1.5},
##       {"def": "wall", "pattern": "grid",  "cols": 10, "rows": 10, "spacing": 2}
##     ],
##     "initial_instances": [...]   // singletons (player) still hand-placed
##   }
##
## Each pattern expands at load time into concrete instance dicts that
## flow into the same _spawn_initial path as hand-coded ones. So a
## pattern is just sugar for many initial_instances entries.
##
## Patterns shipped:
##   ring     — n on a circle (count, radius, y, yaw_offset)
##   grid     — cols × rows (cols, rows, spacing, origin)
##   line     — n along segment (count, start, end)
##   scatter  — random with min-spacing (count, min_r, max_r, y,
##              min_spacing, max_attempts, exclude_zones)
##   cluster  — n around an origin (count, origin, spread, min_spacing,
##              exclude_zones)
##   mirror   — duplicate `items` mirrored across `axis` ("x" or "z")
##
## `exclude_zones` (scatter + cluster): list of {center, radius} circles
## where placement is forbidden. Useful for protecting player spawn,
## boss spawn frame, choke points.
##
## Determinism: scene.json's `level_seed` value is applied to Godot's
## global PRNG at world load. With a fixed seed, scatter/cluster
## produce the same map every run; without one, each session randomizes.


## Expand a single pattern dict into a list of instance dicts.
## Each returned dict has the same shape as initial_instances entries:
##   {"def": ..., "id": ..., "position": [x, y, z]}
static func expand(pattern: Dictionary) -> Array:
	var t := str(pattern.get("pattern", ""))
	match t:
		"ring":    return _ring(pattern)
		"grid":    return _grid(pattern)
		"line":    return _line(pattern)
		"scatter": return _scatter(pattern)
		"cluster": return _cluster(pattern)
		"mirror":  return _mirror(pattern)
	return []


# ============================================================
# RING — n entities evenly spaced on a circle
# ============================================================

static func _ring(p: Dictionary) -> Array:
	var def_id := str(p.get("def", ""))
	var id_prefix := str(p.get("id_prefix", def_id))
	var count := int(p.get("count", 1))
	var radius := float(p.get("radius", 1.0))
	var y := float(p.get("y", 0.0))
	var yaw_offset := float(p.get("yaw_offset", 0.0))
	var origin := _to_vec3(p.get("origin", [0, 0, 0]))
	var out: Array = []
	if count <= 0 or def_id == "": return out
	for i in range(count):
		var angle: float = yaw_offset + TAU * float(i) / float(count)
		var pos := [
			origin.x + cos(angle) * radius,
			origin.y + y,
			origin.z + sin(angle) * radius
		]
		out.append({
			"def": def_id,
			"id": "%s_%d" % [id_prefix, i + 1],
			"position": pos
		})
	return out


# ============================================================
# GRID — cols × rows
# ============================================================

static func _grid(p: Dictionary) -> Array:
	var def_id := str(p.get("def", ""))
	var id_prefix := str(p.get("id_prefix", def_id))
	var cols := int(p.get("cols", 1))
	var rows := int(p.get("rows", 1))
	var spacing := float(p.get("spacing", 1.0))
	var origin := _to_vec3(p.get("origin", [0, 0, 0]))
	# By default center the grid on origin so it's symmetric.
	var center: bool = bool(p.get("center", true))
	var out: Array = []
	if cols <= 0 or rows <= 0 or def_id == "": return out
	var ox := origin.x
	var oz := origin.z
	if center:
		ox -= (cols - 1) * spacing * 0.5
		oz -= (rows - 1) * spacing * 0.5
	var n: int = 1
	for r in range(rows):
		for c in range(cols):
			out.append({
				"def": def_id,
				"id": "%s_%d" % [id_prefix, n],
				"position": [ox + c * spacing, origin.y, oz + r * spacing]
			})
			n += 1
	return out


# ============================================================
# LINE — n along a segment
# ============================================================

static func _line(p: Dictionary) -> Array:
	var def_id := str(p.get("def", ""))
	var id_prefix := str(p.get("id_prefix", def_id))
	var count := int(p.get("count", 1))
	var start := _to_vec3(p.get("start", [0, 0, 0]))
	var end := _to_vec3(p.get("end", [1, 0, 0]))
	var out: Array = []
	if count <= 0 or def_id == "": return out
	for i in range(count):
		var t: float = 0.0 if count == 1 else float(i) / float(count - 1)
		var pos := start.lerp(end, t)
		out.append({
			"def": def_id,
			"id": "%s_%d" % [id_prefix, i + 1],
			"position": [pos.x, pos.y, pos.z]
		})
	return out


# ============================================================
# SCATTER — random within a ring annulus, optional spacing constraint
# ============================================================

static func _scatter(p: Dictionary) -> Array:
	var def_id := str(p.get("def", ""))
	var id_prefix := str(p.get("id_prefix", def_id))
	var count := int(p.get("count", 1))
	var min_r := float(p.get("min_r", 0.0))
	var max_r := float(p.get("max_r", 5.0))
	var y := float(p.get("y", 0.0))
	var min_spacing := float(p.get("min_spacing", 0.0))
	var max_attempts := int(p.get("max_attempts", 100))
	var origin := _to_vec3(p.get("origin", [0, 0, 0]))
	var exclude_zones: Array = p.get("exclude_zones", [])
	var out: Array = []
	var placed: Array = []
	if count <= 0 or def_id == "": return out
	var attempts: int = 0
	while placed.size() < count and attempts < count * max_attempts:
		var t: float = randf()
		var r: float = lerp(min_r, max_r, sqrt(t))  # sqrt biases toward edge for uniform area
		var angle: float = randf() * TAU
		var pos := Vector3(
			origin.x + cos(angle) * r,
			origin.y + y,
			origin.z + sin(angle) * r
		)
		var ok: bool = true
		if min_spacing > 0:
			for prior in placed:
				if (prior as Vector3).distance_to(pos) < min_spacing:
					ok = false
					break
		if ok and not exclude_zones.is_empty():
			ok = not _in_exclude_zone(pos, exclude_zones)
		if ok:
			placed.append(pos)
			out.append({
				"def": def_id,
				"id": "%s_%d" % [id_prefix, placed.size()],
				"position": [pos.x, pos.y, pos.z]
			})
		attempts += 1
	return out


# ============================================================
# CLUSTER — n around an origin with spread + spacing
# ============================================================

static func _cluster(p: Dictionary) -> Array:
	var def_id := str(p.get("def", ""))
	var id_prefix := str(p.get("id_prefix", def_id))
	var count := int(p.get("count", 1))
	var origin := _to_vec3(p.get("origin", [0, 0, 0]))
	var spread := float(p.get("spread", 2.0))
	var min_spacing := float(p.get("min_spacing", 0.0))
	var max_attempts := int(p.get("max_attempts", 100))
	var exclude_zones: Array = p.get("exclude_zones", [])
	var out: Array = []
	var placed: Array = []
	if count <= 0 or def_id == "": return out
	var attempts: int = 0
	while placed.size() < count and attempts < count * max_attempts:
		var dx: float = (randf() - 0.5) * 2.0 * spread
		var dz: float = (randf() - 0.5) * 2.0 * spread
		var pos := Vector3(origin.x + dx, origin.y, origin.z + dz)
		var ok: bool = true
		if min_spacing > 0:
			for prior in placed:
				if (prior as Vector3).distance_to(pos) < min_spacing:
					ok = false
					break
		if ok and not exclude_zones.is_empty():
			ok = not _in_exclude_zone(pos, exclude_zones)
		if ok:
			placed.append(pos)
			out.append({
				"def": def_id,
				"id": "%s_%d" % [id_prefix, placed.size()],
				"position": [pos.x, pos.y, pos.z]
			})
		attempts += 1
	return out


# ============================================================
# MIRROR — duplicate `items` reflected across an axis
# ============================================================
# Useful for symmetric arena layouts: hand-place N landmarks on one
# side, mirror onto the other. Output count = items.size() × 2 (the
# original list + the mirrored list). axis: "x" flips x, "z" flips z.

static func _mirror(p: Dictionary) -> Array:
	var items: Array = p.get("items", [])
	if items.is_empty(): return []
	var axis := str(p.get("axis", "x"))
	var id_suffix := str(p.get("id_suffix", "_mirror"))
	var out: Array = []
	for item in items:
		if not (item is Dictionary): continue
		# Original
		out.append(item.duplicate(true))
		# Mirrored copy
		var pos = (item as Dictionary).get("position", [0, 0, 0])
		var pos_v := _to_vec3(pos)
		var mirrored: Vector3 = pos_v
		match axis:
			"x": mirrored = Vector3(-pos_v.x, pos_v.y, pos_v.z)
			"z": mirrored = Vector3(pos_v.x, pos_v.y, -pos_v.z)
		var copy: Dictionary = (item as Dictionary).duplicate(true)
		copy["position"] = [mirrored.x, mirrored.y, mirrored.z]
		var orig_id := str(copy.get("id", ""))
		if orig_id != "":
			copy["id"] = orig_id + id_suffix
		out.append(copy)
	return out


# ============================================================
# UTIL
# ============================================================

## Test if pos lies inside any of the exclude_zones (each {center, radius}
## in 2D — XZ plane). Y ignored.
static func _in_exclude_zone(pos: Vector3, zones: Array) -> bool:
	for z in zones:
		if not (z is Dictionary): continue
		var c := _to_vec3(z.get("center", [0, 0, 0]))
		var r: float = float(z.get("radius", 0))
		if r <= 0.0: continue
		var dx := pos.x - c.x
		var dz := pos.z - c.z
		if dx * dx + dz * dz < r * r:
			return true
	return false


static func _to_vec3(v) -> Vector3:
	if v is Vector3: return v
	if v is Vector2: return Vector3((v as Vector2).x, 0, (v as Vector2).y)
	if v is Array:
		var a := v as Array
		if a.size() == 3:
			return Vector3(float(a[0]), float(a[1]), float(a[2]))
		if a.size() == 2:
			return Vector3(float(a[0]), 0, float(a[1]))
	return Vector3.ZERO
