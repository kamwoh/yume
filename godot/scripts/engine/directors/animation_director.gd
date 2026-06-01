extends RefCounted
class_name AnimationDirector

## Per-entity animation state-rule bridge (ADR 0035 + ADR 0046 Phase A.2).
##
## Reads the `animations` + `animation_state_rules` blocks from a mesh def.
## Owns a reference to the entity's `AnimationPlayer` (created externally
## by entity_mesh_3d during mesh build). On each `tick(now_seconds)`,
## evaluates the state rules; if the resolved state changed, calls
## `animation_player.play(state, blend_seconds)`. Godot's C++
## AnimationPlayer drives the actual keyframe interpolation.
##
## ADR 0046 Phase A.2 cutover (2026-05-17): the previous GDScript
## interpolator (`_interp_keys`, `_apply_track`, `_cache_baselines`)
## has been deleted. The director is now ~80 lines: state-rule
## evaluation + AnimationPlayer dispatch. Per the audit at commit
## 856e64a (2026-05-13), this realigns animation under ADR 0021
## ("expose, don't reimplement") — Godot's AnimationPlayer was always
## doing the C++ keyframe interp; Yume now just feeds it the JSON-
## translated AnimationLibrary (see animation_translator.gd) and
## tells it which clip to play.
##
## Invariant #11 (level-discontinuity cleanup, 2026-05-08) note: the
## AnimationPlayer is owned by the entity's visual root (entity_mesh_3d
## adds it as a child of itself). On transition_level, the entity
## destroys its scene tree — the AnimationPlayer dies with it. No new
## smoothed-state surface that survives the discontinuity.
##
## Lifecycle:
##   - Construct via `AnimationDirector.from_mesh_def(...)`. Returns null
##     if the mesh has no `animations` block (backwards-compat) OR if
##     the state-rules list lacks a `default` fallback (load-time
##     error via EngineError.ANIMATION_NO_DEFAULT).
##   - Caller (entity_mesh_3d) creates the AnimationPlayer node + adds
##     it as a child of the visual root + registers the translated
##     AnimationLibrary on it, then calls `attach_player(player)`.
##   - Call `tick(now_seconds)` per render frame from
##     entity_mesh_3d._process.

var _mesh_def: Dictionary  # mesh def from meshes.json
var _root: Node3D  # parent mesh root (entity_mesh_3d)
var _entity: Entity  # Entity (for state / velocity / tag reads)
var _animations: Dictionary  # name → animation block (kept for default-state lookup)
var _state_rules: Array  # animation_state_rules (ordered)
var _animation_player: AnimationPlayer = null  # set via attach_player()
var _active_state: String = ""  # currently-playing state name
var _default_blend: float = 0.15  # cross-fade seconds when state changes
var _clip_aliases: Dictionary = {}  # state_name → clip_name (Phase B)


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
	d._default_blend = float(mesh_def.get("animation_blend_seconds", 0.15))
	if not d._has_default_rule():
		EngineError.raise(
			env,
			EngineError.ANIMATION_NO_DEFAULT,
			"AnimationDirector: animation_state_rules missing 'default' fallback",
			{"mesh": str(mesh_def.get("_origin", "?"))},
			"Add a {default: <state_name>} entry as the LAST rule."
		)
		return null
	return d


## Wire the externally-created AnimationPlayer. Called by entity_mesh_3d
## after it builds the mesh pieces + creates the AnimationPlayer +
## registers the translated AnimationLibrary.
func attach_player(player: AnimationPlayer) -> void:
	_animation_player = player


## ADR 0046 Phase B: register a {state_name: clip_name} mapping. Used
## when the AnimationPlayer's clip names don't match the engine-side
## state names (e.g. .glb files whose clip names come from Blender NLA
## tracks like "Walking" / "Idle" while the rules use "walk" / "idle").
## When no mapping exists for a state, the state name is played verbatim.
func set_clip_aliases(aliases: Dictionary) -> void:
	_clip_aliases = aliases.duplicate()


## Per-frame entry point. `now_seconds` is monotonic game time (kept in
## the signature for backward compat with existing callers; not used
## directly — AnimationPlayer owns its own clock).
func tick(_now_seconds: float) -> void:
	if _animation_player == null:
		return
	var picked := _pick_state()
	if picked != _active_state:
		_active_state = picked
		if picked == "":
			_animation_player.stop()
			return
		# Per-state blend override: animations.<state>.blend_seconds. Falls
		# back to the mesh-def-level animation_blend_seconds.
		var blend := _default_blend
		var clip = _animations.get(picked, null)
		if clip is Dictionary and (clip as Dictionary).has("blend_seconds"):
			blend = float((clip as Dictionary)["blend_seconds"])
		# Phase B: resolve clip_alias mapping if registered (state → .glb
		# clip name). Falls back to the state name verbatim.
		var clip_name := str(_clip_aliases.get(picked, picked))
		if not _animation_player.has_animation(clip_name):
			# Silent miss: keeps the entity static rather than crashing on
			# typo'd alias. Author can grep stdout for the warning.
			push_warning(
				(
					"AnimationDirector: clip '%s' not in player (state=%s, " % [clip_name, picked]
					+ "available: %s)" % str(_animation_player.get_animation_list())
				)
			)
			return
		_animation_player.play(clip_name, blend)
	# ADR 0065 — synced animation: if the entity carries a replicated `anim_phase`
	# (0..1, a deterministic sim-state field), DRIVE the clip's playback position
	# from it every tick instead of letting the AnimationPlayer free-run — so every
	# client shows the SAME pose (same leg forward), not just the same clip out of
	# phase. Opt-in: absent → free-run (single-player / non-networked unchanged).
	_apply_synced_phase()


## Pin the clip's playback time to anim_phase·length when the entity has a synced
## phase. No-op if the field is absent (free-run) or the clip is missing.
func _apply_synced_phase() -> void:
	if _entity == null or _active_state == "":
		return
	var ph = _entity.get_state("anim_phase", null)
	if ph == null:
		return  # not a synced-animation entity → leave the AnimationPlayer alone
	var clip_name := str(_clip_aliases.get(_active_state, _active_state))
	if not _animation_player.has_animation(clip_name):
		return
	var length := _animation_player.get_animation(clip_name).length
	if length <= 0.0:
		return
	if _animation_player.current_animation != clip_name:
		_animation_player.play(clip_name)
	_animation_player.seek(fposmod(float(ph), 1.0) * length, true)


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
				for k in (spec as Dictionary).keys():
					if _entity == null:
						matched = false
						break
					if _entity.get_state(str(k), null) != (spec as Dictionary)[k]:
						matched = false
						break
				if matched and not (spec as Dictionary).is_empty():
					return str(rule.get("state", ""))
		if rule.has("if_state_in"):
			var spec2 = rule["if_state_in"]
			if spec2 is Dictionary:
				var matched_in := true
				for k in (spec2 as Dictionary).keys():
					if _entity == null:
						matched_in = false
						break
					var arr = (spec2 as Dictionary)[k]
					if not (arr is Array):
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


func _vel_len() -> float:
	if _entity == null:
		return 0.0
	var v = _entity.get_state("velocity", null)
	if v is Vector2:
		return (v as Vector2).length()
	if v is Vector3:
		return (v as Vector3).length()
	return 0.0


func _has_default_rule() -> bool:
	for rule in _state_rules:
		if rule is Dictionary and rule.has("default"):
			return true
	return false
