extends RefCounted
class_name AnimationDirector

## Per-entity animation interpreter (ADR 0035).
##
## Reads the `animations` + `animation_state_rules` blocks from a mesh def,
## along with a parent Node3D (the entity_mesh_3d) containing the mesh's
## primitive children (named via mesh_lib.gd's `name` field). Applies
## per-piece transform deltas each render frame based on a declarative
## state machine over entity velocity / state / tags.
##
## ADR 0021/0044/0045 audit (2026-05-13): this module reimplements
## keyframe interpolation in GDScript (`_interp_keys`, `_apply_track`).
## Godot ships AnimationPlayer + Animation resources that do exactly
## that in optimized C++, plus cubic/spline interp and AnimationTree
## cross-fading. A future ADR (candidate 0046) should:
##   - keep `_pick_state` + the state rules system (Yume-specific
##     gameplay-aware bridge — Godot's AnimationTree doesn't know about
##     entity tags / velocity)
##   - replace `_interp_keys` + `_apply_track` + `_cache_baselines` with
##     a translation layer that builds Animation resources at mesh-def
##     load and plays them via AnimationPlayer
##
## Not urgent — current code is correct, focused, and works fine. The
## architectural smell is real (reimplements what Godot already does);
## the migration cost is real (multi-session). Queued, not blocking.
##
## Lifecycle:
##   - Construct via `AnimationDirector.from_mesh_def(...)`. Returns null
##     if the mesh has no `animations` block (backwards-compat) OR if the
##     state-rules list lacks a `default` fallback (load-time error via
##     EngineError.ANIMATION_NO_DEFAULT).
##   - Call `tick(now_seconds)` per render frame from entity_mesh_3d._process.
##
## Design notes:
##   - Cheap. Per-frame work = O(rules) for state pick + O(tracks × keys)
##     for interpolation + a handful of property writes. ~30-50 ops per
##     entity per frame.
##   - Baseline-aware. At construction, we snapshot each addressed piece's
##     authored position/rotation/scale; tracks apply DELTA on top so the
##     authored rest pose is preserved when no track touches a component.
##   - Graceful fallback. A track referencing a piece that doesn't exist
##     (typo or pre-renamed mesh) logs ONE warning and silently skips on
##     subsequent frames; other tracks still apply.
##   - Linear interpolation only (Phase 1). Cubic/spline deferred to a
##     future ADR.
##   - Hooked observation-driven: this module reads entity state / tags;
##     it never fires effects. Per ADR 0035 + Invariant #2 (no semantic
##     effects), animation introduces zero new effect types / queries /
##     triggers.

var _mesh_def: Dictionary  # mesh def from meshes.json
var _root: Node3D  # parent mesh root (entity_mesh_3d)
var _entity: Entity  # Entity (for state / velocity / tag reads)
var _animations: Dictionary  # name → animation block
var _state_rules: Array  # animation_state_rules (ordered)
var _piece_cache: Dictionary = {}  # piece_name → MeshInstance3D ref
var _missing_pieces_warned: Dictionary = {}  # piece_name → true (one-shot dedup)
var _baseline: Dictionary = {}  # piece_name → {pos: Vec3, rot: Vec3, scale: Vec3}
var _active_state: String = ""  # currently-playing state name
var _state_started_at: float = 0.0  # seconds (game time) when this state activated


## Build a director for a given mesh def + render root + entity.
## Returns null when:
##   - mesh def has no `animations` field (backwards-compat: mesh renders
##     statically)
##   - mesh def has no `animation_state_rules` field
##   - rules array lacks a `default` fallback (load-time error reported)
static func from_mesh_def(
	mesh_def: Dictionary, root: Node3D, entity: Entity, env: Dictionary
) -> AnimationDirector:
	if not (mesh_def.get("animations") is Dictionary):
		return null
	if not (mesh_def.get("animation_state_rules") is Array):
		return null
	var d := AnimationDirector.new()
	d._mesh_def = mesh_def
	d._root = root
	d._entity = entity
	d._animations = mesh_def["animations"]
	d._state_rules = mesh_def["animation_state_rules"]
	if not d._has_default_rule():
		EngineError.raise(
			env,
			EngineError.ANIMATION_NO_DEFAULT,
			"AnimationDirector: animation_state_rules missing 'default' fallback",
			{"mesh": str(mesh_def.get("_origin", "?"))},
			"Add a {default: <state_name>} entry as the LAST rule."
		)
		return null
	d._cache_baselines()
	return d


## For each piece referenced by any track across any state, snapshot the
## authored pose. Tracks then DELTA on top (translation tracks add to
## baseline.pos; rotation tracks REPLACE baseline.rot when active for the
## animated axis).
func _cache_baselines() -> void:
	for state_name in _animations.keys():
		var anim = _animations[state_name]
		if not (anim is Dictionary):
			continue
		var tracks = anim.get("tracks", [])
		if not (tracks is Array):
			continue
		for track in tracks:
			if not (track is Dictionary):
				continue
			var piece_name := str(track.get("piece", ""))
			if piece_name == "" or _baseline.has(piece_name):
				continue
			var node := _find_piece(piece_name)
			if node == null:
				continue
			_baseline[piece_name] = {
				"pos": node.position,
				"rot": node.rotation,
				"scale": node.scale,
			}


## Per-frame entry point. `now_seconds` is monotonic game time (e.g.
## Time.get_ticks_msec() / 1000.0).
func tick(now_seconds: float) -> void:
	var picked := _pick_state()
	if picked != _active_state:
		_active_state = picked
		_state_started_at = now_seconds
	if _active_state == "" or not _animations.has(_active_state):
		return
	var anim = _animations[_active_state]
	if not (anim is Dictionary):
		return
	var dur := float(anim.get("duration", 1.0))
	if dur <= 0.0:
		return
	var elapsed := now_seconds - _state_started_at
	var t: float
	if bool(anim.get("loop", true)):
		t = fposmod(elapsed, dur) / dur
	else:
		t = clamp(elapsed / dur, 0.0, 1.0)
	var tracks = anim.get("tracks", [])
	if not (tracks is Array):
		return
	for track in tracks:
		if track is Dictionary:
			_apply_track(track, t)


## Evaluate state rules top-to-bottom. First match wins. `default` is the
## terminating fallback. Returns "" only if rules array is empty (which is
## already screened by from_mesh_def's default-rule check).
func _pick_state() -> String:
	for rule in _state_rules:
		if not (rule is Dictionary):
			continue
		# `default` MUST be checked first so a `{default: "idle"}` row at
		# the end of the list always returns; placing default last is the
		# author convention but the iteration handles either order.
		if rule.has("default"):
			# `default` value can be the state name (`{default: "idle"}`)
			# or `true` with a sibling `state` key. Prefer explicit name.
			var dval = rule["default"]
			if dval is String:
				return str(dval)
			if rule.has("state"):
				return str(rule["state"])
			# `{default: true}` with no state key — return literal "default"
			# only as a last resort; authors should specify a state name.
			return "default"
		if rule.has("if_velocity_gt") and _vel_len() > float(rule["if_velocity_gt"]):
			return str(rule.get("state", ""))
		if rule.has("if_velocity_lt") and _vel_len() < float(rule["if_velocity_lt"]):
			return str(rule.get("state", ""))
		if rule.has("if_state_eq"):
			var spec = rule["if_state_eq"]
			if spec is Dictionary:
				var matched := true
				for k in spec.keys():
					if _entity == null or _entity.get_state(str(k), null) != spec[k]:
						matched = false
						break
				if matched and not (spec as Dictionary).is_empty():
					return str(rule.get("state", ""))
		if rule.has("if_state_in"):
			var spec2 = rule["if_state_in"]
			if spec2 is Dictionary:
				var matched_in := true
				for k in spec2.keys():
					var arr = spec2[k]
					if not (arr is Array):
						matched_in = false
						break
					if _entity == null:
						matched_in = false
						break
					if not (arr as Array).has(_entity.get_state(str(k), null)):
						matched_in = false
						break
				if matched_in and not (spec2 as Dictionary).is_empty():
					return str(rule.get("state", ""))
		if rule.has("if_tag"):
			if _entity != null and _entity.has_tag(str(rule["if_tag"])):
				return str(rule.get("state", ""))
	return ""


## Apply a single track. Each track is `{piece, <component>: [keys]}`
## where component is one of rotation_{x,y,z} / translation_{x,y,z} /
## scale_{x,y,z}. Multiple components may share a single track dict.
func _apply_track(track: Dictionary, t: float) -> void:
	var piece_name := str(track.get("piece", ""))
	if piece_name == "":
		return
	var node := _find_piece(piece_name)
	if node == null:
		return
	var base: Dictionary = _baseline.get(piece_name, {})
	var base_pos: Vector3 = base.get("pos", node.position)
	var base_rot: Vector3 = base.get("rot", node.rotation)
	var base_scale: Vector3 = base.get("scale", node.scale)
	var pos := base_pos
	var rot := base_rot
	var scl := base_scale
	for key in track.keys():
		if key == "piece":
			continue
		var keys = track[key]
		if not (keys is Array) or (keys as Array).is_empty():
			continue
		var v := _interp_keys(keys, t)
		match str(key):
			"rotation_x":
				rot.x = v
			"rotation_y":
				rot.y = v
			"rotation_z":
				rot.z = v
			"translation_x":
				pos.x = base_pos.x + v
			"translation_y":
				pos.y = base_pos.y + v
			"translation_z":
				pos.z = base_pos.z + v
			"scale_x":
				scl.x = v
			"scale_y":
				scl.y = v
			"scale_z":
				scl.z = v
	node.position = pos
	node.rotation = rot
	node.scale = scl


## Linear interpolation across a 1D keyframe array, t in [0, 1].
## With N keys, the array spans N-1 segments; idx = t * (N-1), frac is the
## fractional remainder. At t=1.0 we land exactly on keys[N-1].
func _interp_keys(keys: Array, t: float) -> float:
	var n := keys.size()
	if n == 0:
		return 0.0
	if n == 1:
		return float(keys[0])
	var span := 1.0 / float(n - 1)
	var idx_f := t / span
	var idx0 := int(floor(idx_f))
	if idx0 >= n - 1:
		return float(keys[n - 1])
	if idx0 < 0:
		idx0 = 0
	var idx1 := idx0 + 1
	var frac := idx_f - float(idx0)
	return lerp(float(keys[idx0]), float(keys[idx1]), frac)


## Find a named child under the mesh root. Caches successful lookups; logs
## ONE warning per missing piece (then silently skips on subsequent frames).
func _find_piece(piece_name: String) -> Node3D:
	if _piece_cache.has(piece_name):
		return _piece_cache[piece_name]
	if _root == null:
		return null
	var found = _root.find_child(piece_name, true, false)
	if found == null or not (found is Node3D):
		if not _missing_pieces_warned.has(piece_name):
			_missing_pieces_warned[piece_name] = true
			push_warning("AnimationDirector: piece '%s' not found under mesh root" % piece_name)
		return null
	_piece_cache[piece_name] = found
	return found


## Returns the magnitude of the entity's velocity (state.velocity), zero
## when the entity has no velocity field. Handles Vector2 and Vector3.
func _vel_len() -> float:
	if _entity == null:
		return 0.0
	var v = _entity.get_state("velocity", null)
	if v is Vector2:
		return (v as Vector2).length()
	if v is Vector3:
		return (v as Vector3).length()
	return 0.0


## Validate that the rules list contains at least one `default` entry.
func _has_default_rule() -> bool:
	for rule in _state_rules:
		if rule is Dictionary and rule.has("default"):
			return true
	return false
