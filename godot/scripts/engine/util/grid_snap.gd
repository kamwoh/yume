extends RefCounted
class_name GridSnap

## ADR 0038 — Sims-style grid placement primitive.
##
## Pure utility: snap entity positions + yaws to a cell grid declared in
## scene.json. Engine snaps at four sites: world load (_spawn_initial),
## pattern expansion (opt-in), runtime build_place (ADR 0037), and the
## build preview widget.
##
## Per Condition C1 (tech-director, 2026-05-10): grid config travels via
## the flat env key `env["scene_grid"]`, parallel to ADR 0037's
## `env["scene_bounds"]` pattern. Empty dict = grid disabled (the default
## for the 13 existing demos).
##
## Per Condition C2 (tech-director, 2026-05-10): y_size defaults to 0
## (DISABLED) for floor-walking worlds. Y-snap activates only when the
## author opts in by setting y_size > 0.


## Is grid snapping enabled? True iff scene_grid is a non-empty dict.
static func is_enabled(env: Dictionary) -> bool:
	var cfg = env.get("scene_grid", {})
	return cfg is Dictionary and not (cfg as Dictionary).is_empty()


## Return the grid config dict (or empty dict).
static func config(env: Dictionary) -> Dictionary:
	var cfg = env.get("scene_grid", {})
	return cfg if cfg is Dictionary else {}


## Snap a Vector3 position to the grid. Y-snap is OPT-IN per Condition C2 —
## y_size must be explicitly set to a positive value. X+Z always snap when
## grid is enabled.
static func snap_position(pos: Vector3, env: Dictionary) -> Vector3:
	if not is_enabled(env):
		return pos
	var c := config(env)
	var size := float(c.get("size", 1.0))
	var origin: Array = c.get("origin", [0, 0, 0])
	var ox := float(origin[0]) if origin.size() > 0 else 0.0
	var oy := float(origin[1]) if origin.size() > 1 else 0.0
	var oz := float(origin[2]) if origin.size() > 2 else 0.0
	# Y-snap: disabled by default (pass-through). Activates iff y_size > 0.
	var y_raw = c.get("y_size", 0)
	var y_size := float(y_raw) if y_raw != null else 0.0
	var snapped_y: float
	if y_size > 0.0:
		snapped_y = oy + round((pos.y - oy) / y_size) * y_size
	else:
		snapped_y = pos.y
	return Vector3(
		ox + round((pos.x - ox) / size) * size,
		snapped_y,
		oz + round((pos.z - oz) / size) * size
	)


## Snap a Vector2 position. Used for 2D entities. The Vector2's .y maps to
## world-Z (renderer convention) so we snap both components by `size`.
static func snap_position_2d(pos: Vector2, env: Dictionary) -> Vector2:
	if not is_enabled(env):
		return pos
	var c := config(env)
	var size := float(c.get("size", 1.0))
	var origin: Array = c.get("origin", [0, 0, 0])
	var ox := float(origin[0]) if origin.size() > 0 else 0.0
	var oz := float(origin[2]) if origin.size() > 2 else 0.0
	return Vector2(
		ox + round((pos.x - ox) / size) * size,
		oz + round((pos.y - oz) / size) * size
	)


## Snap a yaw (radians) to the configured increment (default π/2 = 90°).
## Returns the snapped value wrapped to [0, TAU). No-op when snap_yaw=false
## or grid disabled.
static func snap_yaw(yaw: float, env: Dictionary) -> float:
	if not is_enabled(env):
		return yaw
	var c := config(env)
	if not bool(c.get("snap_yaw", true)):
		return yaw
	var inc := float(c.get("yaw_increment", PI / 2.0))
	if inc <= 0.0:
		return yaw
	return fposmod(round(yaw / inc) * inc, TAU)


## Should this entity def snap? False if any of its tags are in
## exempt_tags (default: actor, projectile, particle, animal). Authors
## can override the exempt list per-game in scene.json's grid block.
static func should_snap(def: Dictionary, env: Dictionary) -> bool:
	if not is_enabled(env):
		return false
	var c := config(env)
	var exempt: Array = c.get("exempt_tags",
		["actor", "projectile", "particle", "animal"])
	var tags: Array = def.get("tags", [])
	for t in exempt:
		if t in tags:
			return false
	return true


## Snap with drift warning (per Condition C3 Gate B, 2026-05-10).
## When the snapped position differs from the authored position by more
## than 0.1 * size on any axis, emit a push_warning. Surfaces source-JSON
## drift in QA logs without requiring a separate static validator. Gate A
## (tools/validate_grid_alignment.py) is the preferred follow-up.
static func snap_position_with_drift_check(pos: Vector3, env: Dictionary,
										   ent_id: String) -> Vector3:
	var snapped := snap_position(pos, env)
	if not is_enabled(env):
		return snapped
	var size := float(config(env).get("size", 1.0))
	var threshold := 0.1 * size
	var dx: float = abs(snapped.x - pos.x)
	var dz: float = abs(snapped.z - pos.z)
	if dx > threshold or dz > threshold:
		push_warning("[grid] entity '%s' position drift dx=%.3f dz=%.3f from nearest cell at size=%.1f — consider authoring at grid coordinates"
			% [ent_id, dx, dz, size])
	return snapped
