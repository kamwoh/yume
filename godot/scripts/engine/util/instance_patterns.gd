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
## Determinism (ADR 0060): scatter/cluster use a PER-PATTERN seeded
## `RandomNumberGenerator` — NOT Godot's shared global PRNG. The seed is
## derived from `base_seed` (scene.json `level_seed`, 0 if unset) XOR the
## pattern's identity (id_prefix + def), so each pattern's layout is
## reproducible INDEPENDENT of how many `randf()` calls anything else made
## first. The old global-`seed()` approach was insufficient: the global
## PRNG's consumption ORDER across boot/scatter/rule `randf()`s isn't
## pinned, so seeded-but-shared still diverged run-to-run (empirical
## 2026-05-30: aldenmere camp_berry scatter diverged at tick 1 despite
## level_seed=4412). A per-stream RNG removes the order dependency entirely.


## Expand a single pattern dict into a list of instance dicts.
## `base_seed` (default 0) is the scene's level_seed; scatter/cluster derive
## a per-pattern RNG from it. Deterministic-pattern callers (tests) can omit it.
##   {"def": ..., "id": ..., "position": [x, y, z]}
static func expand(pattern: Dictionary, base_seed: int = 0) -> Array:
	var t := str(pattern.get("pattern", ""))
	match t:
		"ring":
			return _ring(pattern)
		"grid":
			return _grid(pattern)
		"line":
			return _line(pattern)
		"scatter":
			return _scatter(pattern, base_seed)
		"cluster":
			return _cluster(pattern, base_seed)
		"mirror":
			return _mirror(pattern)
	return []


## Per-pattern deterministic RNG. seed = base_seed XOR identity-hash, so the
## same pattern always scatters identically regardless of call order or what
## else consumed the global PRNG. ADR 0060.
static func _pattern_rng(base_seed: int, p: Dictionary) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	var ident := str(p.get("id_prefix", "")) + "|" + str(p.get("def", "")) + "|" + str(p.get("def_choices", []))
	rng.seed = base_seed ^ (ident.hash() | 1)
	return rng


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
	var origin := Vec3Util.from_world_pos(p.get("origin", [0, 0, 0]))
	var out: Array = []
	if count <= 0 or def_id == "":
		return out
	for i in range(count):
		var angle: float = yaw_offset + TAU * float(i) / float(count)
		var pos := [origin.x + cos(angle) * radius, origin.y + y, origin.z + sin(angle) * radius]
		out.append({"def": def_id, "id": "%s_%d" % [id_prefix, i + 1], "position": pos})
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
	var origin := Vec3Util.from_world_pos(p.get("origin", [0, 0, 0]))
	# By default center the grid on origin so it's symmetric.
	var center: bool = bool(p.get("center", true))
	var out: Array = []
	if cols <= 0 or rows <= 0 or def_id == "":
		return out
	var ox := origin.x
	var oz := origin.z
	if center:
		ox -= (cols - 1) * spacing * 0.5
		oz -= (rows - 1) * spacing * 0.5
	var n: int = 1
	for r in range(rows):
		for c in range(cols):
			out.append(
				{
					"def": def_id,
					"id": "%s_%d" % [id_prefix, n],
					"position": [ox + c * spacing, origin.y, oz + r * spacing]
				}
			)
			n += 1
	return out


# ============================================================
# LINE — n along a segment
# ============================================================


static func _line(p: Dictionary) -> Array:
	var def_id := str(p.get("def", ""))
	var id_prefix := str(p.get("id_prefix", def_id))
	var count := int(p.get("count", 1))
	var start := Vec3Util.from_world_pos(p.get("start", [0, 0, 0]))
	var end := Vec3Util.from_world_pos(p.get("end", [1, 0, 0]))
	var out: Array = []
	if count <= 0 or def_id == "":
		return out
	for i in range(count):
		var t: float = 0.0 if count == 1 else float(i) / float(count - 1)
		var pos := start.lerp(end, t)
		out.append(
			{"def": def_id, "id": "%s_%d" % [id_prefix, i + 1], "position": [pos.x, pos.y, pos.z]}
		)
	return out


# ============================================================
# SCATTER — random within a ring annulus, optional spacing constraint
# ============================================================


static func _scatter(p: Dictionary, base_seed: int = 0) -> Array:
	var rng := _pattern_rng(base_seed, p)  # ADR 0060 — per-pattern, not global
	# `def` for a single def, OR `def_choices: [a, b, c]` for random mix.
	var def_id := str(p.get("def", ""))
	var def_choices: Array = p.get("def_choices", [])
	if def_choices.is_empty() and def_id != "":
		def_choices = [def_id]
	var id_prefix := str(p.get("id_prefix", def_id if def_id != "" else "scatter"))
	var count := int(p.get("count", 1))
	# Per the engine convention, `min_r`/`max_r` define the annulus
	# (ring) around `origin` where scatter spawns. Defaults are 0/5
	# meters — fine for a small flower cluster, but with count > 10
	# and min_spacing ~1m the engine can only fit ~30 entities in a
	# 5m disk before exhausting placement attempts. The caller then
	# silently gets ~30 instances instead of `count`.
	#
	# Empirical case 2026-05-20: yume-map-author shipped a 200-tree
	# forest pattern without min_r/max_r; engine spawned ~30 trees
	# clumped at origin. The harness validator was added the same
	# day but only catches drafts going through wireframe_to_map
	# postprocess — hand-edits and --force still bypass it.
	# Engine-side warning catches ALL call sites.
	var has_min_r: bool = p.has("min_r")
	var has_max_r: bool = p.has("max_r")
	if count > 10 and not (has_min_r and has_max_r):
		var msg := "[scatter.bounds_missing] pattern id_prefix='%s' count=%d > 10 with default min_r/max_r (0/5m). Engine will spawn at most ~30 entities due to packing; expected silently dropped. Add min_r and max_r to the pattern." % [id_prefix, count]
		push_warning(msg)
	var min_r := float(p.get("min_r", 0.0))
	var max_r := float(p.get("max_r", 5.0))
	var y := float(p.get("y", 0.0))
	var min_spacing := float(p.get("min_spacing", 0.0))
	var max_attempts := int(p.get("max_attempts", 100))
	var origin := Vec3Util.from_world_pos(p.get("origin", [0, 0, 0]))
	var exclude_zones: Array = p.get("exclude_zones", [])
	# Optional per-instance scale variation. Uniform random in [min, max].
	# Default 1.0 (no variation). Useful for vegetation: scale_min: 0.7,
	# scale_max: 2.5 yields a natural canopy mix.
	var scale_min := float(p.get("scale_min", 1.0))
	var scale_max := float(p.get("scale_max", 1.0))
	# Optional yaw randomization. Uniform random in [-yaw_jitter, +yaw_jitter]
	# radians. PI = ±180° (any direction). Useful for trees/rocks to break
	# alignment.
	var yaw_jitter := float(p.get("yaw_jitter", 0.0))
	var out: Array = []
	var placed: Array = []
	if count <= 0 or def_choices.is_empty():
		return out
	var attempts: int = 0
	while placed.size() < count and attempts < count * max_attempts:
		var t: float = rng.randf()
		var r: float = lerp(min_r, max_r, sqrt(t))  # sqrt biases toward edge for uniform area
		var angle: float = rng.randf() * TAU
		var pos := Vector3(origin.x + cos(angle) * r, origin.y + y, origin.z + sin(angle) * r)
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
			var picked_def := str(def_choices[rng.randi() % def_choices.size()])
			var inst: Dictionary = {
				"def": picked_def,
				"id": "%s_%d" % [id_prefix, placed.size()],
				"position": [pos.x, pos.y, pos.z]
			}
			# Build state overrides if any randomized field varies.
			var state_ov: Dictionary = {}
			if scale_min != 1.0 or scale_max != 1.0:
				state_ov["scale"] = lerp(scale_min, scale_max, rng.randf())
			if yaw_jitter > 0.0:
				state_ov["yaw"] = (rng.randf() - 0.5) * 2.0 * yaw_jitter
			if not state_ov.is_empty():
				inst["state"] = state_ov
			out.append(inst)
		attempts += 1
	# Under-spawn warning: if the loop exited via the attempt budget
	# rather than reaching `count`, the requested entity count silently
	# dropped. Could be: min_r/max_r too tight, min_spacing too large,
	# exclude_zones covering most of the annulus. Surface so the author
	# knows their pattern under-delivered. Independent gate from the
	# `min_r/max_r missing` warning above — catches OTHER reasons too.
	if out.size() < count:
		var msg2 := "[scatter.under_spawn] pattern id_prefix='%s' requested count=%d but engine placed %d. Likely: annulus too tight (min_r=%.1f, max_r=%.1f), min_spacing=%.1f too large, or exclude_zones covering most of the area." % [id_prefix, count, out.size(), min_r, max_r, min_spacing]
		push_warning(msg2)
	return out


# ============================================================
# CLUSTER — n around an origin with spread + spacing
# ============================================================


static func _cluster(p: Dictionary, base_seed: int = 0) -> Array:
	var rng := _pattern_rng(base_seed, p)  # ADR 0060 — per-pattern, not global
	var def_id := str(p.get("def", ""))
	var id_prefix := str(p.get("id_prefix", def_id))
	var count := int(p.get("count", 1))
	var origin := Vec3Util.from_world_pos(p.get("origin", [0, 0, 0]))
	var spread := float(p.get("spread", 2.0))
	var min_spacing := float(p.get("min_spacing", 0.0))
	var max_attempts := int(p.get("max_attempts", 100))
	var exclude_zones: Array = p.get("exclude_zones", [])
	var out: Array = []
	var placed: Array = []
	if count <= 0 or def_id == "":
		return out
	var attempts: int = 0
	while placed.size() < count and attempts < count * max_attempts:
		var dx: float = (rng.randf() - 0.5) * 2.0 * spread
		var dz: float = (rng.randf() - 0.5) * 2.0 * spread
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
			out.append(
				{
					"def": def_id,
					"id": "%s_%d" % [id_prefix, placed.size()],
					"position": [pos.x, pos.y, pos.z]
				}
			)
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
	if items.is_empty():
		return []
	var axis := str(p.get("axis", "x"))
	var id_suffix := str(p.get("id_suffix", "_mirror"))
	var out: Array = []
	for item in items:
		if not (item is Dictionary):
			continue
		# Original
		out.append(item.duplicate(true))
		# Mirrored copy
		var pos = (item as Dictionary).get("position", [0, 0, 0])
		var pos_v := Vec3Util.from_world_pos(pos)
		var mirrored: Vector3 = pos_v
		match axis:
			"x":
				mirrored = Vector3(-pos_v.x, pos_v.y, pos_v.z)
			"z":
				mirrored = Vector3(pos_v.x, pos_v.y, -pos_v.z)
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
		if not (z is Dictionary):
			continue
		var c := Vec3Util.from_world_pos(z.get("center", [0, 0, 0]))
		var r: float = float(z.get("radius", 0))
		if r <= 0.0:
			continue
		var dx := pos.x - c.x
		var dz := pos.z - c.z
		if dx * dx + dz * dz < r * r:
			return true
	return false
