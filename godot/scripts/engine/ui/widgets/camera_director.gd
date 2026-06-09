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
# Third-person: snap (not lerp) the first frame the follow target resolves, so a
# spawn-on-join character doesn't get a ~0.3s lerp-in from the default camera pose.
var _tp_has_target: bool = false

# Mode-transition detection — first_person_3d capture mode + tracking
# last-frame mode so enter/leave-FP can reset state.
var _mode_last: String = ""
var _fp_initial_capture_done: bool = false
# Standard ESC-to-release-cursor behavior (2026-05-20). Toggle latches
# across frames. While true: every camera-mode function releases the
# mouse + skips orientation updates so the cursor stays free for
# desktop use. Press ESC again to re-capture and resume play.
var _mouse_released_by_user: bool = false

# Ephemeral free-cam pose when no free_camera entity exists in the world.
# Stored director-local so we don't write to player.state.position (the
# physics body would overwrite immediately, producing a "stuck" feel).
# Lost on game restart — that's fine, it's a fallback for unauthored levels.
var _freecam_ephemeral_pos: Vector3 = Vector3.ZERO
var _freecam_ephemeral_yaw: float = 0.0
var _freecam_ephemeral_pitch: float = 0.0
var _freecam_ephemeral_initialized: bool = false
var _warned_no_free_camera: bool = false


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
	# Standard FPS-game ESC behavior (2026-05-20). Three-state flow:
	#   1st ESC press → release cursor (mouse becomes a normal pointer)
	#   2nd ESC press while released → quit the game
	#   Left-click while released → re-capture (resume play, no quit)
	# When aldenmere (or any game) grows a pause menu, replace the
	# quit() branch with `transition_screen target=pause_menu`.
	if InputMap.has_action("toggle_mouse_capture") \
			and Input.is_action_just_pressed("toggle_mouse_capture"):
		if _mouse_released_by_user:
			# Second ESC while cursor released → quit. Static-cache
			# cleanup happens centrally in world.gd::_exit_tree on
			# tree teardown — no per-call cleanup needed here.
			print("[CameraDirector] ESC pressed while cursor released — quitting")
			if _camera3d != null:
				_camera3d.get_tree().quit()
			elif _camera != null:
				_camera.get_tree().quit()
			return
		_mouse_released_by_user = true
	# Click-to-recapture: while the cursor is released, a left-mouse-
	# button press signals "I want to play again". Release the latch so
	# the next mode-handler can re-capture. Standard FPS convention —
	# matches Half-Life, Counter-Strike, every modern shooter.
	if _mouse_released_by_user \
			and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_mouse_released_by_user = false
	if _mouse_released_by_user:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		# Drain mouse_delta each frame while released so we don't
		# accumulate desktop-cursor motion into the buffer. Without
		# this, on re-capture the camera dumps the entire built-up
		# delta in one frame → screen snaps to whatever direction the
		# user moved the mouse while away. Empirical case 2026-05-21.
		if _world != null:
			var sched = _world.get("scheduler")
			if sched != null:
				sched.env["mouse_delta"] = Vector2.ZERO
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
					_merge_camera_overrides(cam_cfg, st)
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
		# Reset ephemeral free-cam init on mode change so re-entering
		# free_cam picks up the new mode's Camera3D pose.
		var was_free := _mode_last == "free_cam"
		var is_free := mode == "free_cam"
		if was_free and not is_free:
			_freecam_ephemeral_initialized = false
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
		"free_cam":
			# 2026-05-20: cinematic free-camera mode. Decoupled from
			# player entirely — WASD moves the camera, Space/Ctrl
			# raise/lower it, mouse rotates it. Player input is
			# gated off via JSON rules (camera_mode != 'free_cam')
			# so AI/schedule continues but the player ignores WASD.
			# Use case: filming the living world. Press C to toggle.
			if _camera3d != null:
				_camera_free_cam(cam_cfg)
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
		_tp_has_target = false
		return
	var target: Vector3 = target_v
	# Snap (no lerp) the FIRST frame a follow target appears. Covers net
	# spawn-on-join: the followed character pops in mid-session, and without a
	# snap the camera lerps in from its default .tscn pose — which is an oblique/
	# top-down frame — for ~0.3s. Empirical 2026-06-01: the net video's first
	# frame showed that default top-down before the lerp settled behind the actor.
	if not _tp_has_target:
		_snap_pending = true
		_tp_has_target = true
	# 2026-05-19: third-person also captures the mouse so _drain_mouse_facing
	# updates state.facing. Without capture, the drain bails at its
	# mouse_mode != CAPTURED check and the player can't rotate. Mirrors
	# what _camera_first_person_3d does. Modal/overlay freeze releases the
	# mouse same as in FPS (handled in the FP override branch below).
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
		if _world != null and _world.scheduler != null:
			_world.scheduler.env["mouse_delta"] = Vector2.ZERO
	else:
		if not _fp_initial_capture_done:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			_fp_initial_capture_done = true
		if (
			Input.get_mouse_mode() == Input.MOUSE_MODE_VISIBLE
			and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		):
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	var actor = _drain_mouse_facing(cam_cfg)
	var facing := 0.0
	var pitch := 0.0
	if actor != null:
		facing = float(actor.get_state("facing", 0.0))
		pitch = float(actor.get_state("pitch", 0.0))
	# Distance: prefer per-actor override (state.camera_distance, set by
	# scroll-wheel zoom rules), fall back to scene.json's `distance`.
	# Clamped to [distance_min, distance_max] from cfg so rules can blindly
	# add/subtract without overshooting.
	var distance_default := float(cam_cfg.get("distance", 12.0))
	var dmin := float(cam_cfg.get("distance_min", distance_default))
	var dmax := float(cam_cfg.get("distance_max", distance_default))
	var distance_raw = actor.get_state("camera_distance", distance_default)
	var distance: float = clamp(float(distance_raw), dmin, dmax)
	var height := float(cam_cfg.get("height", 5.0))
	var lerp_t := float(cam_cfg.get("lerp", 0.1))
	# Pitch raises/lowers the orbiting camera around the player (2026-05-19).
	# Without this, mouse-up/down doesn't move the 3rd-person camera at all
	# even though _drain_mouse_facing successfully updates state.pitch.
	# Sign convention: mouse-down decreases state.pitch (_drain_mouse_facing
	# does `pitch -= delta.y * sens`, so negative-Y delta from mouse-down
	# subtracts → negative pitch). User intuition for mouse-down is "look
	# DOWN at the ground" = camera moves UP to see player's feet from above.
	# So negative pitch → camera HIGHER. The math negates sin(pitch).
	# Pitch ∈ [-π/2, +π/2] (clamped in drain).
	# Horizontal distance shrinks slightly as pitch nears ±π/2 so the camera
	# stays at a constant radius around the player.
	var pitched_height := height - sin(pitch) * distance
	var pitched_dist := distance * cos(pitch)
	var fx := -sin(facing)
	var fz := -cos(facing)
	# Over-the-shoulder offset (2026-05-20): shoulder_offset shifts the
	# camera SIDEWAYS in the player's local frame. Positive = camera to
	# the player's right (player appears LEFT of center on screen,
	# over-the-shoulder style). Negative = camera to the player's left
	# (mirrored framing).
	# 0 = centered (centered-third-person style). Vector perpendicular to facing-forward
	# in the XZ plane: right = (cos facing, -sin facing).
	var shoulder := float(cam_cfg.get("shoulder_offset", 0.0))
	var right := Vector3(cos(facing), 0, -sin(facing))
	var desired := target + Vector3(
		-fx * pitched_dist,
		pitched_height,
		-fz * pitched_dist,
	) + right * shoulder
	# Camera collision (task #96 follow-up). Raycast from the player's
	# eye-level to the desired camera position. If something solid is
	# in between (wall, tree trunk, structure), shorten the camera
	# distance to keep line-of-sight clear. Without this, the camera
	# can clip through walls or end up inside foliage when the player
	# walks past a tree on the camera's side.
	# Layer 1 is the engine's default static-collider layer (walls,
	# structures, blocks_motion entities). Layer mask 0xFFFFFFFE
	# skips layer 1 to exclude... actually we WANT layer 1 (static).
	# Use mask=1 to hit only the default layer.
	var space = _camera3d.get_world_3d().direct_space_state if _camera3d.get_world_3d() != null else null
	if space != null:
		var ray_from := target + Vector3(0, 1.0, 0)  # eye-level start
		var query := PhysicsRayQueryParameters3D.create(ray_from, desired)
		query.collision_mask = 1  # static colliders (layer 1)
		query.collide_with_areas = false
		var hit := space.intersect_ray(query)
		if not hit.is_empty() and hit.has("position"):
			var hit_pos: Vector3 = hit.position
			var to_desired: Vector3 = desired - ray_from
			var hit_distance: float = (hit_pos - ray_from).length()
			# Pull camera back to just before the hit, with a small
			# clearance buffer so we don't z-fight the wall.
			var dir := to_desired.normalized()
			var pulled_distance: float = max(1.2, hit_distance - 0.3)
			desired = ray_from + dir * pulled_distance
	# Also shift the look-at target by the SAME shoulder amount so the
	# camera doesn't try to re-center the player. With shift applied to
	# both camera AND look_target, the player stays at the offset
	# position in the frame (left third for positive shoulder).
	var shoulder_look_shift := right * shoulder
	if _snap_pending:
		_camera3d.global_position = desired
		_snap_pending = false
	else:
		_camera3d.global_position = _camera3d.global_position.lerp(desired, lerp_t)
	# Camera-stability fix (2026-05-20): orientation computed against the
	# DESIRED (final) position, NOT the current lerping position. Otherwise
	# look_at recomputes from the mid-lerp camera each frame, making the
	# orientation gradually rotate with the position lerp — user-felt as
	# "mouse rotation has delay". See .claude/rules/engine-scripts.md
	# § Camera-stability anti-patterns. Same bug class as the 2026-05-08
	# merchant iso-3d issue; same fix.
	var look_h := float(cam_cfg.get("eye_height", 1.6))
	var look_target := target + Vector3(0, look_h, 0) + shoulder_look_shift
	# Basis.looking_at takes (target_direction, up, use_model_front=false).
	# Camera3D forward is -Z, so use_model_front MUST be false (the default).
	# True would flip +Z toward target and make the camera look AWAY
	# (empirical case 2026-05-08 merchant: empty world rendered).
	_camera3d.global_transform.basis = Basis.looking_at(
		look_target - desired, Vector3.UP, false
	)
	_apply_ortho(cam_cfg, false)
	if actor != null:
		_update_crosshair_target(actor, cam_cfg)


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


## Cinematic free-camera mode (2026-05-21 refactor to entity model).
## Camera state lives on a `free_camera`-tagged ENTITY (per ADR 0001 +
## the everything-is-an-entity principle) — not on the player. Engine
## reads world_clock.active_camera_id, finds that entity, applies its
## state.position + state.yaw + state.pitch to Camera3D.
##
## Multi-camera: any number of free_camera entities can coexist in a
## level (camera_a, camera_b, etc.). Tab cycles to the next one.
## Each camera tagged `persistent` survives level transitions (its
## position is saved per ADR 0010 save/restore).
##
## State (per free_camera entity):
##   position    [x, y, z] world position
##   yaw         float — Y-axis rotation
##   pitch       float — X-axis rotation (clamped ±π/2)
##
## Falls back to the current Camera3D pose if no free_camera entity
## exists in the level (single-camera ad-hoc case).
func _camera_free_cam(cam_cfg: Dictionary) -> void:
	# Modal / overlay open? Release mouse so the user can click pause-menu
	# buttons. Same gate as _camera_first_person_3d (lines ~436-441).
	var freeze_world := false
	if _world != null:
		var ws: Dictionary = _world.get("world_state") as Dictionary
		if ws != null:
			freeze_world = (
				int(ws.get("screen_freeze_world", 0)) != 0
				or int(ws.get("overlay_freeze_world", 0)) != 0
			)
	if freeze_world:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		return

	# Mouse capture (same as FPS / third-person — keeps yaw/pitch live)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# === Resolve the active camera entity ===
	# Look up world_clock to get active_camera_id, then find that entity.
	# If not found, fall back to the first free_camera-tagged entity in
	# the world. If still none, use director-local ephemeral pose vars
	# (NOT the player — writing to player.state.position fights physics +
	# WASD systems, producing a "stuck" feel). The level should author
	# free_camera initial_instances; we log a one-time warning when not.
	var clock := _find_entity_by_tag("world_clock")
	var active_id := ""
	if clock != null:
		active_id = str(clock.get_state("active_camera_id", ""))
	var cam_ent: Object = null
	if active_id != "" and _world != null:
		var ents: Dictionary = _world.get("entities") as Dictionary
		if ents != null and ents.has(active_id):
			cam_ent = ents[active_id]
	if cam_ent == null:
		cam_ent = _find_entity_by_tag("free_camera")
	var use_ephemeral := cam_ent == null
	if use_ephemeral and not _warned_no_free_camera:
		push_warning("[CameraDirector.free_cam] no free_camera entity in level — flying from Camera3D's current pose (pose will not persist across level transitions). Author free_camera initial_instances per .claude/skills/yume-content-designer/SKILL.md.")
		_warned_no_free_camera = true

	# === Tab cycles to the next free_camera entity ===
	# Skipped in ephemeral mode (nothing to cycle through).
	if not use_ephemeral and Input.is_action_just_pressed("cycle_camera") and _world != null:
		var ents2: Dictionary = _world.get("entities") as Dictionary
		var cams: Array = []
		for ent_id in ents2.keys():
			var e = ents2[ent_id]
			if e is Entity and (e as Entity).has_tag("free_camera"):
				cams.append(str(ent_id))
		cams.sort()
		if cams.size() > 0:
			var idx := cams.find(active_id)
			var next_id: String = cams[(idx + 1) % cams.size()] if idx >= 0 else cams[0]
			if clock != null:
				clock.set_state("active_camera_id", next_id)
			# Switch cam_ent to the new camera for THIS frame
			if ents2.has(next_id):
				cam_ent = ents2[next_id]

	# === Read pose ===
	# Initialize from live Camera3D on first entry so the cinematic-mode
	# transition is seamless (camera lands where the previous mode left
	# it). Both entity-backed and ephemeral paths handle this.
	var cam_pos: Vector3
	var cam_yaw: float
	var cam_pitch: float
	if use_ephemeral:
		if not _freecam_ephemeral_initialized:
			_freecam_ephemeral_pos = _camera3d.global_position
			_freecam_ephemeral_yaw = _camera3d.rotation.y
			_freecam_ephemeral_pitch = _camera3d.rotation.x
			_freecam_ephemeral_initialized = true
		cam_pos = _freecam_ephemeral_pos
		cam_yaw = _freecam_ephemeral_yaw
		cam_pitch = _freecam_ephemeral_pitch
	else:
		var pos_v = cam_ent.get_state("position", null)
		if pos_v == null:
			cam_pos = _camera3d.global_position
			cam_ent.set_state("position", [cam_pos.x, cam_pos.y, cam_pos.z])
		else:
			cam_pos = Vec3Util.from_world_pos(pos_v)
		cam_yaw = float(cam_ent.get_state("yaw", _camera3d.rotation.y))
		cam_pitch = float(cam_ent.get_state("pitch", _camera3d.rotation.x))

	# === Mouse → yaw/pitch on the active camera entity ===
	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		var sched = _world.get("scheduler")
		if sched != null:
			var env: Dictionary = sched.env
			var delta_v = env.get("mouse_delta", Vector2.ZERO)
			var delta: Vector2 = delta_v if delta_v is Vector2 else Vector2.ZERO
			if delta.length_squared() > 0.0:
				var sensitivity := float(cam_cfg.get("mouse_sensitivity", 0.003))
				cam_yaw -= delta.x * sensitivity
				cam_pitch -= delta.y * sensitivity
				cam_pitch = clamp(cam_pitch, -PI * 0.49, PI * 0.49)
				if use_ephemeral:
					_freecam_ephemeral_yaw = cam_yaw
					_freecam_ephemeral_pitch = cam_pitch
				else:
					cam_ent.set_state("yaw", cam_yaw)
					cam_ent.set_state("pitch", cam_pitch)
				env["mouse_delta"] = Vector2.ZERO

	# === WASD / Space / Ctrl → camera position on the active entity ===
	var base_speed := float(cam_cfg.get("freecam_speed", 8.0))
	var sprint_mult := float(cam_cfg.get("freecam_sprint", 2.0))
	var speed := base_speed
	if Input.is_action_pressed("sprint"):
		speed *= sprint_mult
	var dt := float(_camera3d.get_process_delta_time())
	if dt <= 0.0:
		dt = 1.0 / 60.0

	# Local-frame movement basis. Forward includes pitch (W into ground
	# when aiming down); strafe stays horizontal; vertical is world-Y.
	# See 2026-05-20 notes for sign convention.
	var fwd := Vector3(
		-sin(cam_yaw) * cos(cam_pitch),
		sin(cam_pitch),
		-cos(cam_yaw) * cos(cam_pitch),
	)
	var right := Vector3(cos(cam_yaw), 0, -sin(cam_yaw))
	var delta_pos := Vector3.ZERO
	if Input.is_action_pressed("move_north"):
		delta_pos += fwd
	if Input.is_action_pressed("move_south"):
		delta_pos -= fwd
	if Input.is_action_pressed("move_east"):
		delta_pos += right
	if Input.is_action_pressed("move_west"):
		delta_pos -= right
	if Input.is_action_pressed("cam_up"):
		delta_pos += Vector3.UP
	if Input.is_action_pressed("cam_down"):
		delta_pos -= Vector3.UP
	if delta_pos.length_squared() > 0.0001:
		delta_pos = delta_pos.normalized() * speed * dt
		cam_pos += delta_pos
		if use_ephemeral:
			_freecam_ephemeral_pos = cam_pos
		else:
			cam_ent.set_state("position", [cam_pos.x, cam_pos.y, cam_pos.z])

	# Apply to Camera3D
	_camera3d.global_position = cam_pos
	_camera3d.rotation = Vector3(cam_pitch, cam_yaw, 0)
	_apply_ortho(cam_cfg, false)


# ============================================================
# 3D HELPERS
# ============================================================


func _follow_target_3d(cam_cfg: Dictionary):
	var tag := str(cam_cfg.get("follow_tag", ""))
	if tag == "":
		return null
	var ent := _resolve_follow_entity(tag)
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


## Apply projection + clip planes from cam_cfg. `want_ortho` is the
## camera_mode's DEFAULT (iso / top_down → true; fp / tp / free_cam → false),
## but a scene can OVERRIDE it with `cam_cfg.projection`
## ("orthographic" | "perspective") — e.g. orthographic FPS for a stylized
## look, or perspective top_down for a cinematic. `clip_near` / `clip_far` +
## `focal_length_mm` let authors write film-camera language. Every field
## defaults to the prior behavior (and to Godot's Camera3D defaults), so a
## scene that sets none renders identically. (scene.json `camera` block.)
func _apply_ortho(cam_cfg: Dictionary, want_ortho: bool) -> void:
	if _camera3d == null:
		return
	# Projection: an explicit cam_cfg.projection overrides the mode default.
	var ortho := want_ortho
	var proj := str(cam_cfg.get("projection", "")).to_lower()
	if proj == "orthographic" or proj == "ortho":
		ortho = true
	elif proj == "perspective" or proj == "persp":
		ortho = false
	# Clip planes — always applied (defaults match Godot's Camera3D defaults).
	_camera3d.near = float(cam_cfg.get("clip_near", 0.05))
	_camera3d.far = float(cam_cfg.get("clip_far", 4000.0))
	if ortho:
		_camera3d.projection = Camera3D.PROJECTION_ORTHOGONAL
		# Godot requires ortho size > 0; guard so a bad author/tune value can't
		# spam errors (Camera3D rejects out-of-range + keeps the old value).
		_camera3d.size = maxf(0.01, float(cam_cfg.get("ortho_size", 16.0)))
	else:
		_camera3d.projection = Camera3D.PROJECTION_PERSPECTIVE
		# focal_length_mm (35mm-equiv, 36mm sensor) → FOV degrees; falls back
		# to an explicit fov, then the 75° default.
		var focal := float(cam_cfg.get("focal_length_mm", 0.0))
		var fov := _focal_to_fov_deg(focal) if focal > 0.0 else float(cam_cfg.get("fov", 75.0))
		# Godot Camera3D.fov is hard-limited to [1, 179]; clamp so any author /
		# runtime-tune value renders instead of being rejected (which would keep
		# the prior fov — a confusing "no visual change" when scrubbing).
		_camera3d.fov = clampf(fov, 1.0, 179.0)


## Runtime camera-intrinsic overrides from the world_clock entity's state —
## same pattern as the camera_mode override in update_follow. Lets a rule or
## debug keybind retune the camera LIVE (state_set/state_add on world_clock)
## without editing scene.json. Each key is opt-in: absent → the scene's camera
## block value stands. `cam_ortho` is an int (0 perspective / 1 orthographic).
## Static + pure (no instance state) so it's unit-testable without a shell.
static func _merge_camera_overrides(cam_cfg: Dictionary, st: Dictionary) -> void:
	if st.has("cam_ortho"):
		cam_cfg["projection"] = "orthographic" if int(st["cam_ortho"]) != 0 else "perspective"
	if st.has("cam_ortho_size"):
		cam_cfg["ortho_size"] = float(st["cam_ortho_size"])
	if st.has("cam_fov"):
		cam_cfg["fov"] = float(st["cam_fov"])
	# focal overrides fov only when positive (0 = "use fov").
	if st.has("cam_focal_mm") and float(st["cam_focal_mm"]) > 0.0:
		cam_cfg["focal_length_mm"] = float(st["cam_focal_mm"])


## Convert a 35mm-equivalent focal length (mm) to FOV in degrees on a 36mm
## sensor: fov = 2·atan(36 / (2·f)). Static + pure so it's unit-testable.
## (e.g. 18mm → 90°, 35mm → ~54.4°, 50mm → ~39.6°.)
static func _focal_to_fov_deg(focal_mm: float) -> float:
	if focal_mm <= 0.0:
		return 75.0
	return rad_to_deg(2.0 * atan(36.0 / (2.0 * focal_mm)))


func _drain_mouse_facing(cam_cfg: Dictionary):
	var tag := str(cam_cfg.get("follow_tag", ""))
	if tag == "":
		return null
	var actor := _resolve_follow_entity(tag)
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
	# Mouse-Y drives pitch by DEFAULT (2026-06-06). Was `use_pitch` default
	# false → third-person shipped with a frozen pitch (can't look up/down),
	# a recurring user frustration. Sensible default = pitch works; a game
	# that wants a fixed-pitch follow opts OUT with `use_pitch: false`.
	if bool(cam_cfg.get("use_pitch", true)):
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
	#   player's own back. Over-the-shoulder third-person style: crosshair
	#   fires from the player's point of view regardless of camera orbit.
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
		# Apply pitch too (2026-05-19). Without this the crosshair ray
		# is horizontal even when the camera tilts via mouse-up/down,
		# so the labeled target diverges from what the camera actually
		# looks at. Sign matches the camera math above:
		# mouse-down → state.pitch decreases → camera moves UP → looks
		# down. The ray fwd.y should also tilt DOWNWARD on negative
		# pitch, hence -sin(pitch).
		var pitch := float(actor.get_state("pitch", 0.0))
		var horiz := cos(pitch)
		fwd = Vector3(-sin(facing) * horiz, -sin(pitch), -cos(facing) * horiz)
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
	# Task #106: project the aim ray to screen-space so HUD can move
	# the crosshair to match the player-POV ray (not the camera POV).
	# Only in third-person (FPS uses screen-center; sentinel = -1).
	if mode == "third_person_3d" and _camera3d != null:
		var aim_world_pos: Vector3 = cam_pos + fwd * max_distance * 0.5
		var screen_pos: Vector2 = _camera3d.unproject_position(aim_world_pos)
		world_state["crosshair_screen_x"] = screen_pos.x
		world_state["crosshair_screen_y"] = screen_pos.y
	else:
		world_state["crosshair_screen_x"] = -1
		world_state["crosshair_screen_y"] = -1
	world_state["crosshair_target"] = new_target
	world_state["crosshair_target_id"] = new_target_id


# ============================================================
# UTIL — delegates to GameShell for shared helpers
# ============================================================


func _find_entity_by_tag(tag: String) -> Object:
	return _shell.call("_find_entity_by_tag", tag)


## Resolve the camera's follow target. PRESENTATION-ONLY per-peer override
## (ADR 0061 visual lockstep): when `yume_local_follow_id` is set, each window
## follows ITS OWN local character instead of the first `follow_tag` match — so
## with two `player`-tagged characters, peer A's camera follows A's actor and
## peer B's follows B's. The meta is set by lockstep_driver; it never touches sim
## state, so it can't affect the canonical hash. Falls back to follow_tag.
func _resolve_follow_entity(tag: String) -> Object:
	if Engine.has_meta("yume_local_follow_id") and _world != null:
		var fid := str(Engine.get_meta("yume_local_follow_id"))
		var ents = _world.get("entities")
		if ents is Dictionary and (ents as Dictionary).has(fid):
			return (ents as Dictionary)[fid]
	return _find_entity_by_tag(tag)


static func _to_vec2(v) -> Vector2:
	if v is Vector2:
		return v
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO
