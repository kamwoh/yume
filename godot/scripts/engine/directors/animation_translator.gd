extends Object
class_name AnimationTranslator

## ADR 0046 Phase A.1 — JSON `animations` block → Godot AnimationLibrary.
##
## Replaces the GDScript per-frame interpolator (`_interp_keys` +
## `_apply_track` in animation_director.gd) by pre-baking each clip into
## a Godot `Animation` resource at mesh-def load time. The translated
## library mounts on a per-entity `AnimationPlayer`; Godot's C++
## interpolator drives playback.
##
## The Yume authoring schema is unchanged:
##   "animations": {
##     "<clip>": {
##       "loop": true|false,
##       "duration": <seconds>,
##       "tracks": [
##         {"piece": "<name>",
##          "rotation_x|y|z": [k0, k1, ...],
##          "translation_x|y|z": [k0, k1, ...],
##          "scale_x|y|z": [k0, k1, ...]}
##       ]
##     }
##   }
##
## Per-axis arrays have N keyframes uniformly spaced over [0, duration].
## TRANSLATION is interpreted as an OFFSET from each piece's baseline
## (resting transform); ROTATION and SCALE REPLACE the per-axis baseline.
## Axes not present in a track keep their baseline value verbatim.
##
## Because Godot's TYPE_VALUE tracks target whole properties (Vector3)
## rather than sub-components, the translator BAKES the baseline + the
## per-axis spec into Vector3 keyframes at build time. One bake per
## piece+property-class per clip. After bake, the Animation resource
## describes absolute Vector3 transforms — Godot just plays them.

# ============================================================
# PUBLIC API
# ============================================================


## Probe each named piece under `mesh_root` for its resting transform.
## Returns `{piece_name: {pos: Vector3, rot: Vector3, scale: Vector3}}`.
## A piece is named when its Node.name matches a `track.piece` reference
## in the animations block — uncalled-out children are skipped (they
## don't animate, no need to capture their baseline).
##
## Decoupled from build_library so tests can synthesize baselines
## without a real mesh tree.
static func collect_baselines(mesh_root: Node, animations: Dictionary) -> Dictionary:
	var piece_names := _collect_piece_names(animations)
	var out: Dictionary = {}
	if mesh_root == null:
		return out
	for piece_name in piece_names:
		var node := mesh_root.find_child(str(piece_name), true, false)
		if node == null or not (node is Node3D):
			continue
		var n: Node3D = node
		out[str(piece_name)] = {
			"pos": n.position,
			"rot": n.rotation,
			"scale": n.scale,
		}
	return out


## Build an AnimationLibrary from a JSON `animations` block + baseline
## map. Each clip in the block → one Animation resource. Returns null
## if the block is empty or malformed.
static func build_library(
	animations: Dictionary, baselines: Dictionary
) -> AnimationLibrary:
	if animations.is_empty():
		return null
	var lib := AnimationLibrary.new()
	for clip_name in animations.keys():
		var clip = animations[clip_name]
		if not (clip is Dictionary):
			continue
		var anim := _build_animation(clip as Dictionary, baselines)
		if anim != null:
			lib.add_animation(str(clip_name), anim)
	return lib


# ============================================================
# INTERNAL
# ============================================================


## Find every unique piece name referenced in any track of any clip.
static func _collect_piece_names(animations: Dictionary) -> Array:
	var names: Dictionary = {}
	for clip_name in animations.keys():
		var clip = animations[clip_name]
		if not (clip is Dictionary):
			continue
		var tracks = (clip as Dictionary).get("tracks", [])
		if not (tracks is Array):
			continue
		for track in tracks:
			if not (track is Dictionary):
				continue
			var p := str((track as Dictionary).get("piece", ""))
			if p != "":
				names[p] = true
	return names.keys()


## Build one Animation resource from a single clip dict.
##
## Per-clip `interp: "cubic"` / `"linear"` (default linear) sets the
## interpolation type for every track in the clip. Godot's
## INTERPOLATION_CUBIC produces smoother motion at the expense of
## constant compute; use it for character locomotion where the eye
## sees mid-stride poses. Linear is fine for blinking, color flashes,
## or grid-snapped UI animations.
static func _build_animation(clip: Dictionary, baselines: Dictionary) -> Animation:
	var duration := float(clip.get("duration", 1.0))
	if duration <= 0.0:
		return null
	var anim := Animation.new()
	anim.length = duration
	if bool(clip.get("loop", true)):
		anim.loop_mode = Animation.LOOP_LINEAR
	else:
		anim.loop_mode = Animation.LOOP_NONE

	var interp_kind := str(clip.get("interp", "linear")).to_lower()
	var interp_type := Animation.INTERPOLATION_LINEAR
	if interp_kind == "cubic":
		interp_type = Animation.INTERPOLATION_CUBIC
	elif interp_kind == "nearest":
		interp_type = Animation.INTERPOLATION_NEAREST

	var tracks = clip.get("tracks", [])
	if not (tracks is Array):
		return anim

	# Group track specs by (piece, property_class). One Godot track per
	# (piece, class) bakes all axes together into Vector3 keyframes.
	var grouped := _group_tracks(tracks as Array)
	for key in grouped.keys():
		var parts := str(key).split("|")
		if parts.size() != 2:
			continue
		var piece_name := parts[0]
		var prop_class := parts[1]  # "rotation" | "translation" | "scale"
		var axis_specs: Dictionary = grouped[key]  # {x: [...], y: [...], z: [...]}
		var baseline: Dictionary = baselines.get(piece_name, {})
		_bake_track(anim, piece_name, prop_class, axis_specs, baseline, duration, interp_type)
	return anim


## Walk all track dicts in a clip; group their axis arrays by
## (piece, property_class). Returns
##   {"<piece>|<class>": {"x": [...], "y": [...], "z": [...]}}
## where unspecified axes are absent from the inner dict.
static func _group_tracks(tracks: Array) -> Dictionary:
	var grouped: Dictionary = {}
	for track in tracks:
		if not (track is Dictionary):
			continue
		var td: Dictionary = track
		var piece := str(td.get("piece", ""))
		if piece == "":
			continue
		for key in td.keys():
			var ks := str(key)
			if ks == "piece":
				continue
			if not (td[key] is Array):
				continue
			var prop_class := ""
			var axis := ""
			if ks.begins_with("rotation_"):
				prop_class = "rotation"
				axis = ks.substr(9)
			elif ks.begins_with("translation_"):
				prop_class = "translation"
				axis = ks.substr(12)
			elif ks.begins_with("scale_"):
				prop_class = "scale"
				axis = ks.substr(6)
			else:
				continue
			if not (axis in ["x", "y", "z"]):
				continue
			var group_key := piece + "|" + prop_class
			if not grouped.has(group_key):
				grouped[group_key] = {}
			(grouped[group_key] as Dictionary)[axis] = td[key]
	return grouped


## Bake the (piece, property_class) axis-arrays + baseline into a Godot
## value track + Vector3 keyframes. One track per (piece, property class)
## per clip.
##
## Track path convention: `"<piece_name>:<property>"` where property is
## `position` / `rotation` / `scale`. AnimationPlayer resolves this
## against its `root_node` — set to the mesh root by the caller during
## A.2 mount.
##
## Translation arrays are OFFSETS from baseline.pos. Rotation/scale
## arrays REPLACE baseline per-axis. Axes not present keep baseline.
##
## interp_type controls how Godot interpolates between Vector3
## keyframes — INTERPOLATION_LINEAR (default), INTERPOLATION_CUBIC for
## smooth motion, or INTERPOLATION_NEAREST for stepped/discrete frames.
static func _bake_track(
	anim: Animation,
	piece_name: String,
	prop_class: String,
	axes: Dictionary,
	baseline: Dictionary,
	duration: float,
	interp_type: int = Animation.INTERPOLATION_LINEAR
) -> void:
	var prop_name := _prop_name_for_class(prop_class)
	if prop_name == "":
		return
	var base_v: Vector3 = _baseline_for_class(baseline, prop_class)
	# N = max axis length so unspecified axes pad with baseline.
	var n := 0
	for axis in ["x", "y", "z"]:
		if axes.has(axis):
			var arr: Array = axes[axis]
			n = max(n, arr.size())
	if n == 0:
		return
	# Add a TYPE_VALUE track targeting "<piece>:<prop>".
	var t_idx := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(t_idx, NodePath(piece_name + ":" + prop_name))
	anim.value_track_set_update_mode(t_idx, Animation.UPDATE_CONTINUOUS)
	anim.track_set_interpolation_type(t_idx, interp_type)
	# Time of each keyframe: uniformly spaced over [0, duration].
	# N=1 → single key at t=0. N>=2 → keys at i*dur/(N-1).
	var step := 0.0
	if n > 1:
		step = duration / float(n - 1)
	for i in n:
		var v: Vector3 = _interp_vector(axes, base_v, prop_class, i, n)
		anim.track_insert_key(t_idx, float(i) * step, v)


## Compute the Vector3 keyframe value at index i. ROTATION/SCALE: per-
## axis REPLACE baseline (axes absent from `axes` keep baseline). TRANS-
## LATION: per-axis ADD to baseline (axes absent contribute 0 offset).
static func _interp_vector(
	axes: Dictionary, base_v: Vector3, prop_class: String, i: int, n: int
) -> Vector3:
	var v := base_v
	for axis in ["x", "y", "z"]:
		if not axes.has(axis):
			continue
		var arr: Array = axes[axis]
		if arr.is_empty():
			continue
		# If this axis has fewer keys than the longest, clamp idx to its
		# last key. Matches "shorter axis pads with its last value".
		var clamped_i: int = min(i, arr.size() - 1)
		var raw := float(arr[clamped_i])
		if prop_class == "translation":
			match axis:
				"x":
					v.x = base_v.x + raw
				"y":
					v.y = base_v.y + raw
				"z":
					v.z = base_v.z + raw
		else:
			match axis:
				"x":
					v.x = raw
				"y":
					v.y = raw
				"z":
					v.z = raw
	return v


static func _prop_name_for_class(prop_class: String) -> String:
	match prop_class:
		"translation":
			return "position"
		"rotation":
			return "rotation"
		"scale":
			return "scale"
	return ""


static func _baseline_for_class(baseline: Dictionary, prop_class: String) -> Vector3:
	if baseline.is_empty():
		# No piece in mesh OR no mesh provided (test path). Sensible
		# defaults: zero translation, zero rotation, unit scale.
		if prop_class == "scale":
			return Vector3.ONE
		return Vector3.ZERO
	match prop_class:
		"translation":
			return baseline.get("pos", Vector3.ZERO)
		"rotation":
			return baseline.get("rot", Vector3.ZERO)
		"scale":
			return baseline.get("scale", Vector3.ONE)
	return Vector3.ZERO
