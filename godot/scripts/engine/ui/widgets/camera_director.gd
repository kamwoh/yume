extends RefCounted
class_name CameraDirector

## All camera modes + camera shake + camera-snap latch.
##
## Per ADR 0021: this is a JSON-content translator on top of Godot's
## Camera2D + Camera3D. scene.json declares `camera.mode` (top_down_2d /
## side_scroll_2d / fixed / top_down_3d / isometric_3d / third_person_3d /
## first_person_3d) plus tuning params (lerp, height, distance, fov, etc.);
## we read those + the actor's state.position/facing/pitch each frame and
## update Camera2D.position / Camera3D.global_transform.
##
## Shake (rules emit_shell_event → "shake" → GameShell._drain_shell_events
## → set_shake) lives here because it operates on Camera2D.offset.
##
## Camera-snap latch: when world swaps levels (transition_level), the
## fade state machine calls set_snap_pending() so the next per-frame
## camera-follow lerp skips and snaps directly to the new actor's
## position. Without it, the lerp_t~0.18 takes ~0.3-0.5s to cover the
## per-level coordinate jump → empty-world frame between worlds.
##
## Owned by GameShell. Some methods cross-call back into the shell via
## _shell.call(...) for now:
##   - _find_entity_by_tag — generic helper, lives in GameShell
##   - _setup_viewmodel / _update_viewmodel — viewmodel section in
##     GameShell (will become its own widget later)

var _shell: Node = null
var _world: Node = null
var _camera: Camera2D = null
var _camera3d: Camera3D = null

# Shake state — pumped by set_shake() from shell event drain; decayed
# each frame by apply_shake().
var _shake_remaining: int = 0
var _shake_intensity: float = 0.0

# Camera-snap latch — set true by set_snap_pending() when world swaps
# levels. Each camera-follow path consumes the flag, sets position
# directly (no lerp) for one frame, then clears it.
var _snap_pending: bool = false

# Mode-transition detection — first_person_3d capture mode + tracking
# last-frame mode so enter/leave-FP can reset state.
var _mode_last: String = ""
var _fp_initial_capture_done: bool = false


func _init(shell: Node) -> void:
	_shell = shell


## Find Camera2D + Camera3D nodes under world. Called once after world is set.
func bind_cameras(world: Node) -> void:
	_world = world
	if _world != null:
		_camera = _world.get_node_or_null("Camera2D")
		_camera3d = _world.get_node_or_null("Camera3D")


## Set shake parameters. Called from GameShell._drain_shell_events when
## a "shake" event drains. Pick stronger of new vs in-progress (intensity ×
## remaining frames is the priority key).
func set_shake(intensity: float, duration: int) -> void:
	if intensity * duration > _shake_intensity * _shake_remaining:
		_shake_intensity = intensity
		_shake_remaining = duration


## Latch the snap-on-next-frame flag. Called from the fade state machine
## when transition_level swaps the world.
func set_snap_pending() -> void:
	_snap_pending = true


## Per-frame camera follow dispatch. Reads scene.json's camera block,
## branches by mode, calls the mode handler. No-op if camera config absent.
func update_follow(scene_cfg: Dictionary) -> void:
	var cam_cfg: Dictionary = scene_cfg.get("camera", {}) as Dictionary
	if cam_cfg.is_empty():
		return
	# Per-frame override from world_clock entity's state.camera_mode if set.
	# Lets a rule fire `state_set field=camera_mode value=...` to swap modes
	# at runtime without engine code changes.
	var override_mode := ""
	if _world != null:
		var sched = _world.get("scheduler")
		if sched != null and sched.get("env") != null:
			var ents: Dictionary = sched.env.get("entities", {}) as Dictionary
			for eid in ents:
				var e = ents[eid]
				if e == null:
					continue
				if e.has_method("has_tag") and e.has_tag("world_clock"):
					var st: Dictionary = e.state as Dictionary
					override_mode = str(st.get("camera_mode", ""))
					break
	var mode: String = ""
	if override_mode != "":
		mode = override_mode
	else:
		mode = str(cam_cfg.get("mode", "top_down_2d"))
	# Detect FP transitions: capture mouse on enter, release on leave.
	if mode != _mode_last:
		var was_fp := _mode_last == "first_person_3d"
		var is_fp := mode == "first_person_3d"
		if was_fp and not is_fp:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			_fp_initial_capture_done = false
			var actor := _find_entity_by_tag(str(cam_cfg.get("follow_tag", "player")))
			if actor != null:
				actor.set_state("facing", 0.0)
				actor.set_state("pitch", 0.0)
		if not was_fp and is_fp:
			_fp_initial_capture_done = false
		# Toggle followed-entity mesh visibility on FPS transitions
		# (2026-05-19, V-toggle support). visual.hide_for_camera_attach
		# is statically applied at entity load to SHADOWS_ONLY for the
		# followed entity in FPS (so the player's own body doesn't occlude
		# the FPS camera). When switching to third-person we want the mesh
		# visible. Mirror the bool: hide in FPS, show otherwise.
		_apply_mesh_visibility_for_mode(cam_cfg, is_fp)
		_mode_last = mode
	# 2D modes need Camera2D; 3D modes need Camera3D. Silent skip if wrong
	# type missing — content responsibility.
	match mode:
		"top_down_2d":
			if _camera != null:
				_apply_2d_zoom(cam_cfg)
				_camera_top_down_2d(cam_cfg)
		"side_scroll_2d":
			if _camera != null:
				_apply_2d_zoom(cam_cfg)
				_camera_side_scroll_2d(cam_cfg)
		"fixed":
			if _camera != null:
				_apply_2d_zoom(cam_cfg)
				_camera_fixed(cam_cfg)
		"top_down_3d":
			if _camera3d != null:
				_camera_top_down_3d(cam_cfg)
		"isometric_3d":
			if _camera3d != null:
				_camera_isometric_3d(cam_cfg)
		"third_person_3d":
			if _camera3d != null:
				_camera_third_person_3d(cam_cfg)
		"first_person_3d":
			if _camera3d != null:
				_camera_first_person_3d(cam_cfg)
		_:
			if _camera != null:
				_apply_2d_zoom(cam_cfg)
				_camera_top_down_2d(cam_cfg)


## Apply current shake offset to camera. Decays each frame. No-op when
## not active. Called from GameShell._process after update_follow.
func apply_shake() -> void:
	if _camera == null:
		return
	if _shake_remaining > 0:
		var offset := Vector2(
			(randf() - 0.5) * 2.0 * _shake_intensity,
			(randf() - 0.5) * 2.0 * _shake_intensity,
		)
		_camera.offset = offset
		_shake_remaining -= 1
		if _shake_remaining <= 0:
			_camera.offset = Vector2.ZERO
	elif _camera.offset != Vector2.ZERO:
		_camera.offset = Vector2.ZERO


# ============================================================
# 2D CAMERA MODES
# ============================================================


func _apply_2d_zoom(cam_cfg: Dictionary) -> void:
	if cam_cfg.has("zoom") and _camera != null:
		var z = _to_vec2(cam_cfg["zoom"])
		if _camera.zoom != z:
			_camera.zoom = z


func _camera_top_down_2d(cam_cfg: Dictionary) -> void:
	# Mode A: center camera on bounding box of entities matching a tag.
	if cam_cfg.has("center_on_tag"):
		var bound_tag := str(cam_cfg["center_on_tag"])
		var bbox := _bbox_of_entities_with_tag(bound_tag)
		if bbox.has("center"):
			var lerp_t := float(cam_cfg.get("lerp", 0.08))
			var center_v = bbox["center"]
			if center_v is Vector2:
				if _snap_pending:
					_camera.position = center_v as Vector2
					_snap_pending = false
				else:
					_camera.position = _camera.position.lerp(center_v as Vector2, lerp_t)
		# Auto-zoom-to-fit.
		if cam_cfg.has("fit_padding") and bbox.has("size"):
			var pad := float(cam_cfg["fit_padding"])
			var bsz_v = bbox["size"]
			if bsz_v is Vector2:
				var bsz := bsz_v as Vector2
				var vp_size := _camera.get_viewport_rect().size
				var target_w: float = bsz.x + 2.0 * pad
				var target_h: float = bsz.y + 2.0 * pad
				var zx: float = vp_size.x / float(max(target_w, 1.0))
				var zy: float = vp_size.y / float(max(target_h, 1.0))
				var z: float = float(min(zx, zy))
				z = clamp(z, 0.25, 4.0)
				var target_zoom := Vector2(z, z)
				var z_lerp := float(cam_cfg.get("zoom_lerp", 0.08))
				_camera.zoom = _camera.zoom.lerp(target_zoom, z_lerp)
		return
	# Mode B: follow_tag — camera tracks one entity.
	var tag := str(cam_cfg.get("follow_tag", ""))
	if tag == "":
		return
	var ent := _find_entity_by_tag(tag)
	if ent == null:
		return
	if not ent.has_method("get_position"):
		return
	var p = ent.get_position()
	if p is Vector2:
		var lerp_t := float(cam_cfg.get("lerp", 0.08))
		if _snap_pending:
			_camera.position = p as Vector2
			_snap_pending = false
		else:
			_camera.position = _camera.position.lerp(p as Vector2, lerp_t)


func _bbox_of_entities_with_tag(tag: String) -> Dictionary:
	var entities: Dictionary = _world.scheduler.env.get("entities", {})
	var min_x := INF
	var min_y := INF
	var max_x := -INF
	var max_y := -INF
	var found := false
	for id in entities:
		var ent = entities[id]
		if not (ent is Entity):
			continue
		if not (ent as Entity).has_tag(tag):
			continue
		var p = (ent as Entity).get_position()
		if not (p is Vector2):
			continue
		var v := p as Vector2
		min_x = min(min_x, v.x)
		max_x = max(max_x, v.x)
		min_y = min(min_y, v.y)
		max_y = max(max_y, v.y)
		found = true
	if not found:
		return {}
	return {
		"center": Vector2((min_x + max_x) * 0.5, (min_y + max_y) * 0.5),
		"size": Vector2(max_x - min_x, max_y - min_y),
	}


## Side-scroller: camera follows entity's x; y stays at config value.
func _camera_side_scroll_2d(cam_cfg: Dictionary) -> void:
	var tag := str(cam_cfg.get("follow_tag", ""))
	if tag == "":
		return
	var ent := _find_entity_by_tag(tag)
	if ent == null:
		return
	if not ent.has_method("get_position"):
		return
	var p = ent.get_position()
	if not (p is Vector2):
		return
	var lerp_t := float(cam_cfg.get("lerp", 0.08))
	var fixed_y := float(cam_cfg.get("fixed_y", _camera.position.y))
	var target := Vector2((p as Vector2).x, fixed_y)
	if _snap_pending:
		_camera.position = target
		_snap_pending = false
	else:
		_camera.position = _camera.position.lerp(target, lerp_t)


## Fixed camera: holds at camera.position from scene.json. No follow.
func _camera_fixed(cam_cfg: Dictionary) -> void:
	if cam_cfg.has("position"):
		var pos := _to_vec2(cam_cfg["position"])
		if _camera.position != pos:
			_camera.position = pos


# ============================================================
# 3D CAMERA MODES (Tier 2.6o Phase 2)
# ============================================================


## Top-down 3D: Camera3D directly above entity, looking down. Orthographic.
func _camera_top_down_3d(cam_cfg: Dictionary) -> void:
	var target_v = _follow_target_3d(cam_cfg)
	if target_v == null:
		return
	var target: Vector3 = target_v
	var height := float(cam_cfg.get("height", 20.0))
	var lerp_t := float(cam_cfg.get("lerp", 0.1))
	var desired := target + Vector3(0, height, 0)
	if _snap_pending:
		_camera3d.global_position = desired
		_snap_pending = false
	else:
		_camera3d.global_position = _camera3d.global_position.lerp(desired, lerp_t)
	_camera3d.look_at(target, Vector3(0, 0, -1))
	_apply_ortho(cam_cfg, true)


## Isometric 3D: Camera3D at 45° angle behind+above target. Orthographic.
func _camera_isometric_3d(cam_cfg: Dictionary) -> void:
	var target_v = _follow_target_3d(cam_cfg)
	if target_v == null:
		return
	var target: Vector3 = target_v
	var distance := float(cam_cfg.get("distance", 16.0))
	var lerp_t := float(cam_cfg.get("lerp", 0.1))
	var offset := Vector3(distance * 0.6, distance * 0.7, distance * 0.6)
	var desired := target + offset
	if _snap_pending:
		_camera3d.global_position = desired
		_snap_pending = false
	else:
		_camera3d.global_position = _camera3d.global_position.lerp(desired, lerp_t)
	# Fixed-orientation iso: orient camera as if AT desired looking at target.
	# Uses use_model_front=false (default) — aim -Z at target, the Camera3D
	# convention. Empirical bug 2026-05-08: use_model_front=true flipped
	# Camera3D forward to +Z and made it look away from target.
	_camera3d.global_transform.basis = Basis.looking_at(target - desired, Vector3.UP, false)
	_apply_ortho(cam_cfg, true)


## Third-person 3D: Camera3D orbits behind entity using state.facing.
func _camera_third_person_3d(cam_cfg: Dictionary) -> void:
	var target_v = _follow_target_3d(cam_cfg)
	if target_v == null:
		return
	var target: Vector3 = target_v
	var actor = _drain_mouse_facing(cam_cfg)
	var facing := 0.0
	if actor != null:
		facing = float(actor.get_state("facing", 0.0))
	var distance := float(cam_cfg.get("distance", 12.0))
	var height := float(cam_cfg.get("height", 5.0))
	var lerp_t := float(cam_cfg.get("lerp", 0.1))
	var fx := -sin(facing)
	var fz := -cos(facing)
	var desired := target + Vector3(-fx * distance, height, -fz * distance)
	if _snap_pending:
		_camera3d.global_position = desired
		_snap_pending = false
	else:
		_camera3d.global_position = _camera3d.global_position.lerp(desired, lerp_t)
	_camera3d.look_at(target, Vector3.UP)
	_apply_ortho(cam_cfg, false)


## First-person 3D: Camera3D at entity eye height. Doom/FPS feel.
func _camera_first_person_3d(cam_cfg: Dictionary) -> void:
	var target_v = _follow_target_3d(cam_cfg)
	if target_v == null:
		return
	var target: Vector3 = target_v
	# Modal / overlay open? Release mouse so user can click buttons.
	var freeze_world := false
	if _world != null:
		var ws: Dictionary = _world.get("world_state") as Dictionary
		if ws != null:
			freeze_world = (
				int(ws.get("screen_freeze_world", 0)) != 0
				or int(ws.get("overlay_freeze_world", 0)) != 0
			)
	if freeze_world:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_VISIBLE:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_fp_initial_capture_done = false
		# Zero the mouse-delta accumulator so any motion the user makes while
		# clicking buttons doesn't apply to the camera once the screen closes.
		# Empirical case 2026-05-16: inventory open → user moves mouse to click
		# Close → screen pops → drained accumulator snapped the camera.
		if _world != null and _world.scheduler != null:
			_world.scheduler.env["mouse_delta"] = Vector2.ZERO
		return
	if not _fp_initial_capture_done:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		_fp_initial_capture_done = true
	if (
		Input.get_mouse_mode() == Input.MOUSE_MODE_VISIBLE
		and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	):
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	var actor = _drain_mouse_facing(cam_cfg)
	if actor == null:
		return
	var facing := float(actor.get_state("facing", 0.0))
	var pitch := float(actor.get_state("pitch", 0.0))
	var eye_height := float(cam_cfg.get("eye_height", 1.7))
	_camera3d.global_position = target + Vector3(0, eye_height, 0)
	_camera3d.rotation = Vector3(pitch, facing, 0)
	_apply_ortho(cam_cfg, false)
	# Viewmodel is its own widget owned by GameShell.
	var vm = _shell.get("_viewmodel_director")
	if vm != null:
		vm.setup(cam_cfg)
		vm.update(actor, cam_cfg)
	_update_crosshair_target(actor, cam_cfg)


# ============================================================
# 3D HELPERS
# ============================================================


func _follow_target_3d(cam_cfg: Dictionary):
	var tag := str(cam_cfg.get("follow_tag", ""))
	if tag == "":
		return null
	var ent := _find_entity_by_tag(tag)
	if ent == null:
		return null
	if not ent.has_method("get_position"):
		return null
	var p = ent.get_position()
	if p is Vector3:
		return p as Vector3
	if p is Vector2:
		return Vector3((p as Vector2).x, 0.0, (p as Vector2).y)
	return null


func _apply_ortho(cam_cfg: Dictionary, want_ortho: bool) -> void:
	if _camera3d == null:
		return
	if want_ortho:
		_camera3d.projection = Camera3D.PROJECTION_ORTHOGONAL
		_camera3d.size = float(cam_cfg.get("ortho_size", 16.0))
	else:
		_camera3d.projection = Camera3D.PROJECTION_PERSPECTIVE
		_camera3d.fov = float(cam_cfg.get("fov", 75.0))


func _drain_mouse_facing(cam_cfg: Dictionary):
	var tag := str(cam_cfg.get("follow_tag", ""))
	if tag == "":
		return null
	var actor := _find_entity_by_tag(tag)
	if actor == null:
		return null
	var sched = _world.get("scheduler")
	if sched == null:
		return actor
	var env: Dictionary = sched.env
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		env["mouse_delta"] = Vector2.ZERO
		return actor
	var delta_v = env.get("mouse_delta", Vector2.ZERO)
	if not (delta_v is Vector2):
		delta_v = Vector2.ZERO
	var delta: Vector2 = delta_v
	if delta.length_squared() == 0.0:
		return actor
	env["mouse_delta"] = Vector2.ZERO
	var sensitivity := float(cam_cfg.get("mouse_sensitivity", 0.003))
	var facing := float(actor.get_state("facing", 0.0))
	facing -= delta.x * sensitivity
	actor.set_state("facing", facing)
	if bool(cam_cfg.get("use_pitch", false)):
		var pitch := float(actor.get_state("pitch", 0.0))
		pitch -= delta.y * sensitivity
		var lim := PI * 0.5 - 0.05
		pitch = clamp(pitch, -lim, lim)
		actor.set_state("pitch", pitch)
	return actor


## 2026-05-10: FP crosshair target. Each frame, find the entity the
## player is most pointing at within `max_distance`. Writes its
## display_name to `world_state.crosshair_target` for HUD bind and its
## id to `world_state.crosshair_target_id` for gather/hunt/talk rules.
##
## Scoring: cylinder-around-ray (#106, 2026-05-16). For each candidate
## entity, project its position onto the camera-forward axis:
##   longitudinal = (ent_pos + y_offset - cam_pos) · forward
##   lateral      = perpendicular distance from the camera-forward ray
##
## Reject if longitudinal is behind, too far, or lateral exceeds
## `tan(cone_rad) * longitudinal` (a proper cone that EXPANDS with
## distance — far entities have looser tolerance than close ones, which
## matches "I'm aimed at it" intuition far better than the old
## dot-product cone). Score is `(1 - lateral_ratio) / longitudinal` so
## an on-axis entity at 5m beats a slightly-off-axis entity at 2m —
## previously the closer-but-off-axis entity won, which is the "weird
## feeling" #106 was filed for.
## Toggle the followed entity's MeshInstance3D cast_shadow setting on
## camera-mode transitions (2026-05-19, V-toggle support). When the
## entity has `visual.hide_for_camera_attach=true`, the entity's mesh
## nodes are SHADOWS_ONLY by default (applied at load). In FPS that's
## correct (camera inside mesh → don't render body parts). When the
## camera switches to third-person, we want the mesh visible — flip
## back to SHADOW_CASTING_SETTING_ON. Returning to FPS restores
## SHADOWS_ONLY.
func _apply_mesh_visibility_for_mode(cam_cfg: Dictionary, is_fp: bool) -> void:
	var tag := str(cam_cfg.get("follow_tag", "player"))
	if tag == "":
		return
	var ent := _find_entity_by_tag(tag)
	if ent == null:
		return
	# Only act when the entity opted into the dual-mode behavior. Without
	# this flag the entity is always visible — no toggling needed.
	if not (ent.visual is Dictionary
			and bool((ent.visual as Dictionary).get("hide_for_camera_attach", false))):
		return
	# Find the entity's renderer node (entity_mesh_3d / similar) — it's a
	# Node3D child of World named after the entity's instance_id.
	if _world == null:
		return
	var rend := _world.get_node_or_null(NodePath(str(ent.instance_id)))
	if rend == null:
		return
	var target_mode := (
		GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if is_fp
		else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	)
	_set_shadow_mode_recursive(rend, target_mode)


func _set_shadow_mode_recursive(node: Node, target_mode: int) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).cast_shadow = target_mode
		_set_shadow_mode_recursive(child, target_mode)


func _update_crosshair_target(actor: Entity, cam_cfg: Dictionary) -> void:
	if _world == null or _camera3d == null:
		return
	var sched = _world.get("scheduler")
	if sched == null:
		return
	var env: Dictionary = sched.env
	var entities: Dictionary = env.get("entities", {})
	var max_distance := float(cam_cfg.get("crosshair_max_distance", 10.0))
	var cone_rad := float(cam_cfg.get("crosshair_cone_rad", 0.26))
	var tan_cone := tan(cone_rad)
	var show_decorative := bool(cam_cfg.get("crosshair_show_decorative", false))
	# Raycast origin depends on camera mode (2026-05-18 V-toggle support):
	# - FPS: camera position + camera forward (camera == player eye).
	# - Third-person: PLAYER's eye + facing direction. The camera sits
	#   behind the player so a camera-based raycast would target the
	#   player's own back. Skyrim / Witcher / RE4-style: crosshair fires
	#   from the player's point of view regardless of camera orbit.
	var mode := str(cam_cfg.get("mode", "first_person_3d"))
	# Per-frame override from world_clock.state.camera_mode (matches
	# update_follow's lookup so V-toggle changes mode-of-truth in one place).
	for eid in entities:
		var ent_v = entities[eid]
		if ent_v is Entity and (ent_v as Entity).has_tag("world_clock"):
			var mv = (ent_v as Entity).get_state("camera_mode", "")
			if str(mv) != "":
				mode = str(mv)
			break
	var cam_pos: Vector3
	var fwd: Vector3
	if mode == "third_person_3d" and actor != null:
		var eye_h := float(cam_cfg.get("eye_height", 1.6))
		var apos_v = actor.get_position()
		var apos: Vector3 = (
			apos_v if apos_v is Vector3
			else Vector3((apos_v as Vector2).x, 0, (apos_v as Vector2).y)
		)
		cam_pos = apos + Vector3(0, eye_h, 0)
		var facing := float(actor.get_state("facing", 0.0))
		fwd = Vector3(-sin(facing), 0, -cos(facing))
	else:
		cam_pos = _camera3d.global_position
		fwd = -_camera3d.global_transform.basis.z
	var best: Entity = null
	var best_score: float = -INF
	for id in entities.keys():
		var ent = entities[id]
		if not (ent is Entity):
			continue
		if ent == actor:
			continue
		if not show_decorative and (ent as Entity).has_tag("decorative"):
			continue
		var name_v = (ent as Entity).get_property("display_name", "")
		if str(name_v) == "":
			continue
		var ep_v = (ent as Entity).get_position()
		var ep: Vector3
		if ep_v is Vector3:
			ep = ep_v
		elif ep_v is Vector2:
			ep = Vector3((ep_v as Vector2).x, 0, (ep_v as Vector2).y)
		else:
			continue
		var y_bias: float = float((ent as Entity).get_property("crosshair_y_offset", 1.0))
		var to_ent: Vector3 = ep + Vector3(0, y_bias, 0) - cam_pos
		var longitudinal: float = to_ent.dot(fwd)
		if longitudinal < 0.01 or longitudinal > max_distance:
			continue
		var closest: Vector3 = cam_pos + fwd * longitudinal
		var lateral: float = (ep + Vector3(0, y_bias, 0) - closest).length()
		# Allow a minimum lateral tolerance so very-close entities aren't
		# impossible to target (tan(cone) * 0.5m = 13cm at 15° — tight).
		var lat_threshold: float = max(0.3, tan_cone * longitudinal)
		if lateral > lat_threshold:
			continue
		# Score: prefer entities CLOSER TO THE RAY (lateral 0 = best)
		# heavily, with mild distance preference. Squaring the on-axis
		# bonus makes off-axis entities lose decisively to on-axis ones.
		var on_axis_bonus: float = 1.0 - lateral / lat_threshold
		var score: float = (on_axis_bonus * on_axis_bonus) / max(longitudinal, 0.5)
		if score > best_score:
			best_score = score
			best = ent
	var world_state: Dictionary = env.get("world", {})
	var new_target: String = ""
	var new_target_id: String = ""
	if best != null:
		new_target = str(best.get_property("display_name", ""))
		new_target_id = str(best.instance_id)
	world_state["crosshair_target"] = new_target
	world_state["crosshair_target_id"] = new_target_id


# ============================================================
# UTIL — delegates to GameShell for shared helpers
# ============================================================


func _find_entity_by_tag(tag: String) -> Object:
	return _shell.call("_find_entity_by_tag", tag)


static func _to_vec2(v) -> Vector2:
	if v is Vector2:
		return v
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO
