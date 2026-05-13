extends Node
class_name GameShell

## Generic JSON-driven game shell (Tier 2.6h).
##
## Reads `<data_root>/scene.json` and `<data_root>/hud.json` and builds:
##   - Pond/world bounds visual (Polygon2D floor + Line2D border)
##   - Camera2D follow-tag behavior + zoom
##   - HUD CanvasLayer with Label / ProgressBar elements bound to entity state
##   - Controls hint label
##   - Win / lose condition watchers + restart-on-R
##
## This script is **engine** code (universal). Per-game customization lives
## entirely in JSON. Adding a new game = writing scene.json + hud.json,
## never editing GDScript or .tscn.
##
## Wiring: GameShell expects to be a child of a Node whose script is
## `World` (the data-driven simulation host). Scene structure:
##   World (root, type=Node, script=res://scripts/engine/core/world.gd)
##   ├─ GameShell (this node)
##   └─ Camera2D
## GameShell creates its own children at runtime: PondFloor, PondBorder,
## HUD CanvasLayer with Control children.
##
## Schema sketch (see docs/30 ... eventually):
##   scene.json: {tick_seconds, camera: {follow_tag, lerp, zoom},
##                bounds: {min, max, floor_color, border_color, border_width}}
##   hud.json:   {panels: [{anchor, elements: [...]}],
##                controls_hint, win, lose}

# ------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------

var _scene_cfg: Dictionary = {}
var _hud_cfg: Dictionary = {}

# Runtime references built in _ready
var _world: Node = null  # parent (World instance)
var _hud_layer: CanvasLayer = null
var _win_panel: Panel = null
var _win_label: Label = null

# Bounds visual widget (Polygon2D floor + Line2D border, 2D demos).
var _bounds_renderer: BoundsRenderer = null

# Camera widget — owns Camera2D/3D refs, all camera modes, shake state,
# snap-pending latch, FP mouse capture state. Per-frame: update_follow +
# apply_shake. Rules emit_shell_event "shake" → set_shake().
var _camera_director: CameraDirector = null

# Tier 2.6l — screen flash overlay state (HUD-tier; not camera). Rules
# emit_shell_event "flash" → fills overlay color for `_flash_remaining`
# frames, then fades.
var _flash_overlay: ColorRect = null
var _flash_remaining: int = 0
var _flash_color: Color = Color(1, 0, 0, 0.5)

# Screen-fade overlay (separate CanvasLayer above HUD so fades cover
# everything: world, HUD, overlays). Driven by `screen_fade` effect and
# by `transition_level` with `fade_duration > 0`.
#
# State machine for fade-driven transitions:
#   IDLE       — no transition pending
#   FADING_OUT — alpha lerping toward 1.0; on completion, sets
#                env._pending_level_transition so World swaps next tick,
#                then enters FADING_IN.
#   FADING_IN  — alpha lerping back to 0.0; on completion, returns to IDLE.
# Plain `screen_fade` effects bypass the state machine — they just retarget
# alpha + duration without queuing a transition.
var _fade_layer: CanvasLayer = null
var _fade_overlay: ColorRect = null
var _fade_alpha: float = 0.0
var _fade_target_alpha: float = 0.0
var _fade_duration_remaining: float = 0.0
var _fade_color: Color = Color(0, 0, 0, 1)
const FADE_PHASE_IDLE := 0
const FADE_PHASE_OUT := 1
const FADE_PHASE_IN := 2
var _fade_phase: int = FADE_PHASE_IDLE
var _fade_pending_target: String = ""
var _fade_half_duration: float = 0.0

# Per-element binding state — { Control_node : binding_spec_dict }
var _bound_elements: Array = []

# Win/lose widget — owns _won / _lost / sustain counter + condition check.
var _win_lose: WinLoseWidget = null

# ============================================================
# LIFECYCLE
# ============================================================


func _ready() -> void:
	_world = get_parent()
	if _world == null or not _world.has_method("_build_env"):
		push_error("GameShell must be a child of a World node")
		return
	_camera_director = CameraDirector.new(self)
	_camera_director.bind_cameras(_world)
	_load_configs()
	# Apply tick_seconds override if specified
	if _scene_cfg.has("tick_seconds") and _world.get("tick_seconds") != null:
		_world.set("tick_seconds", float(_scene_cfg["tick_seconds"]))
	_bounds_renderer = BoundsRenderer.new(self)
	_bounds_renderer.build(_scene_cfg)
	_win_lose = WinLoseWidget.new(self)
	_build_hud()
	_build_fade_overlay()
	# Wire shell_event_buffer into the world's env so EffectApply._emit_shell_event
	# has somewhere to push. Scheduler holds the env reference.
	var sched = _world.get("scheduler")
	if sched != null and sched.get("env") != null:
		var env: Dictionary = sched.env
		if not env.has("shell_event_buffer"):
			env["shell_event_buffer"] = []


func _process(delta: float) -> void:
	if _win_lose.is_ended():
		# After freeze, only listen for restart or quit
		if Input.is_action_just_pressed("ui_accept") or Input.is_key_label_pressed(KEY_R):
			get_tree().reload_current_scene()
		if Input.is_key_label_pressed(KEY_ESCAPE) or Input.is_key_label_pressed(KEY_Q):
			get_tree().quit()
		return
	# Game-level pipelines (owned by GameShell since 2026-05-12 per the
	# "world = sim, game_shell = game" principle). Drain FIRST each frame —
	# pending save/load/transition/reset effects queued by rules need to
	# apply before any UI binding refresh.
	_drain_game_pipelines()
	_handle_pause_input()
	_camera_director.update_follow(_scene_cfg)
	_update_bound_elements()
	_bounds_renderer.update_floor_tint()
	_drain_shell_events()
	_update_shake_and_flash()
	_update_fade(delta)
	_win_lose.check(_hud_cfg)


## Drain game-level pending pipelines (level transition, save/load,
## world reset). These were previously called from world.gd::_process tick branch,
## moved to GameShell._process on 2026-05-12 per the principle "world
## handles entities + actions (sim), game_shell handles game stuff."
##
## Runs every frame regardless of freeze — this is the intentional
## behavior so "Save" / "Travel" / "New Game" buttons on freeze-world
## screens (pause menu, title screen, dialog modals) still work.
## Per Invariant #10's audit: save/level always drained under freeze;
## reset now joins them (was previously "unclear — needs audit",
## resolved by alignment).
##
## Ordering matters: level FIRST (most disruptive), save SECOND (may
## need to capture post-level state), reset LAST (wipes everything).
func _drain_game_pipelines() -> void:
	if _world == null:
		return
	var sched = _world.get("scheduler")
	if sched == null or sched.env == null:
		return
	var env: Dictionary = sched.env
	if _world._level_transitions != null:
		_world._level_transitions.process_pending(env)
	if _world._save_load != null:
		_world._save_load.process_pending(env)
	if _world._world_reset != null:
		_world._world_reset.process_pending(env)


## ESC handling. First press: release captured mouse (so user can click
## the window's X to close, or alt-tab away). Second press while cursor
## is already visible: quit the game. Q also quits anytime.
##
## ADR 0011: when ScreenFlow has an active non-game screen (title, pause,
## settings), defer ESC to it — GameShell stops handling input. ScreenFlow
## owns the pause flow via global_inputs.
##
## Tracked via _esc_was_pressed so we only fire once per keypress, not
## every frame the key is held.
var _esc_was_pressed: bool = false


func _handle_pause_input() -> void:
	# Defer to ScreenFlow when a screen is active (other than the gameplay one)
	var ws: Dictionary = (_world.get("world_state") as Dictionary) if _world != null else {}
	var current_screen := str(ws.get("current_screen", ""))
	if current_screen != "" and current_screen != "game":
		_esc_was_pressed = Input.is_key_label_pressed(KEY_ESCAPE)
		return
	if Input.is_key_label_pressed(KEY_Q):
		get_tree().quit()
		return
	var esc := Input.is_key_label_pressed(KEY_ESCAPE)
	if esc and not _esc_was_pressed:
		# Press-edge: toggle cursor capture, or quit if already free
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			get_tree().quit()
	_esc_was_pressed = esc


# ============================================================
# CONFIG LOADING
# ============================================================


func _load_configs() -> void:
	var root := str(_world.get("data_root"))
	if root == "":
		return
	root = root.rstrip("/")
	# ADR 0027: ensure lib cache is populated BEFORE scene.json/hud.json
	# parsing — Godot _ready order fires this child's lifecycle before
	# the parent World runs its load_data(). Idempotent: World will call
	# init_cache again later but the second call is a no-op.
	LibResolver.init_cache(root)
	_scene_cfg = _read_json(root + "/scene.json")
	_hud_cfg = _read_json(root + "/hud.json")


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	if not (data is Dictionary):
		return {}
	# ADR 0027: route scene.json / hud.json / etc. through lib resolver
	# so `$extends: @lib.cameras.X` and `@lib.X.Y` refs expand to the
	# preset values before consumption.
	var resolved = LibResolver.resolve(data)
	if resolved is Dictionary:
		return resolved as Dictionary
	return data as Dictionary


# ============================================================
# CAMERA FOLLOW
# ============================================================


## Tier 2.6l — drain shell events that rules emitted via emit_shell_event.
## Each event is a Dictionary with at least {"event": "shake"|"flash"|...}.
## Unknown events are silently ignored (forward-compatible).
func _drain_shell_events() -> void:
	if _world == null:
		return
	var sched = _world.get("scheduler")
	if sched == null:
		return
	var env: Dictionary = sched.env
	var buf: Array = env.get("shell_event_buffer", [])
	if buf.is_empty():
		return
	env["shell_event_buffer"] = []
	for ev in buf:
		var name := str(ev.get("event", ""))
		match name:
			"shake":
				var intensity := float(ev.get("intensity", 4.0))
				var duration := int(ev.get("duration", 8))
				_camera_director.set_shake(intensity, duration)
			"flash":
				var color = ev.get("color", "#ff0000")
				_flash_color = _color(color)
				if not _flash_color.a or _flash_color.a == 0.0:
					_flash_color.a = 0.5
				_flash_remaining = int(ev.get("duration", 8))
			"play_sound":
				# Tier 2.6n — forward to AudioBus autoload. Silent when
				# AudioBus isn't loaded (headless/scenario tests).
				# ADR 0009 Phase 2b: @-prefix resolution. If sound name
				# starts with `@cues.`, look up via audio/cues.json. Lets
				# rules emit semantic event names; cue table maps to
				# concrete sounds. Swap audio palette without changing
				# rules.
				var sound_name := str(ev.get("name", ""))
				if sound_name == "":
					continue
				if sound_name.begins_with("@"):
					sound_name = _resolve_at_ref(sound_name)
					if sound_name == "":
						continue
				var bus = get_node_or_null("/root/AudioBus")
				if bus != null and bus.has_method("play"):
					bus.play(sound_name)
			"play_music":
				# 2026-05-08 — looped BGM via AudioBus._music_player.
				# Idempotent: same name re-play is a no-op (already playing).
				var music_name := str(ev.get("name", ""))
				if music_name == "":
					continue
				if music_name.begins_with("@"):
					music_name = _resolve_at_ref(music_name)
					if music_name == "":
						continue
				var bus_m = get_node_or_null("/root/AudioBus")
				if bus_m != null and bus_m.has_method("play_music"):
					bus_m.play_music(music_name)
			"stop_music":
				var bus_s = get_node_or_null("/root/AudioBus")
				if bus_s != null and bus_s.has_method("stop_music"):
					bus_s.stop_music()
			"screen_fade":
				# Standalone alpha tween — does NOT engage the fade-transition
				# state machine. Just retargets alpha + duration; per-frame
				# lerp in _update_fade applies it.
				var alpha := float(ev.get("alpha", 1.0))
				var duration := float(ev.get("duration", 0.0))
				var color = ev.get("color", "#000000")
				_fade_color = _color(color)
				_fade_target_alpha = clamp(alpha, 0.0, 1.0)
				_fade_duration_remaining = max(duration, 0.0)
				if _fade_duration_remaining <= 0.0:
					_fade_alpha = _fade_target_alpha
			"transition_level_fade_request":
				# 3-phase state machine: fade out, swap mid-fade, fade in.
				# Skip if already mid-transition (idempotent under repeated
				# trigger fires).
				if _fade_phase == FADE_PHASE_IDLE:
					var target := str(ev.get("target", ""))
					if target == "":
						continue
					var dur := float(ev.get("fade_duration", 0.5))
					# 2026-05-08: when fade_duration=0 (instant swap),
					# DO NOT touch fade state. A preceding screen_fade
					# in the same drain may have raised alpha to mask
					# the swap; overriding here would expose it. Just
					# queue the level swap + camera snap, leave fade
					# alone.
					if dur <= 0.0:
						if _world != null:
							var sched_inst = _world.get("scheduler")
							if sched_inst != null and sched_inst.get("env") != null:
								(sched_inst.env as Dictionary)["_pending_level_transition"] = target
						_camera_director.set_snap_pending()
						continue
					var color = ev.get("color", "#000000")
					_fade_color = _color(color)
					_fade_pending_target = target
					_fade_half_duration = max(dur * 0.5, 0.0)
					_fade_target_alpha = 1.0
					_fade_duration_remaining = _fade_half_duration
					_fade_phase = FADE_PHASE_OUT


## Apply shake offset + flash alpha. Camera shake lives in CameraDirector;
## flash overlay is HUD-tier and stays here. Both decay each frame.
func _update_shake_and_flash() -> void:
	_camera_director.apply_shake()
	if _flash_overlay != null:
		if _flash_remaining > 0:
			var t: float = float(_flash_remaining) / 12.0
			_flash_overlay.color = Color(
				_flash_color.r, _flash_color.g, _flash_color.b, _flash_color.a * clamp(t, 0.0, 1.0)
			)
			_flash_remaining -= 1
		elif _flash_overlay.color.a > 0.0:
			_flash_overlay.color = Color(0, 0, 0, 0)


## Build a dedicated CanvasLayer above the HUD (layer=20 vs HUD's 10) that
## holds a single full-rect ColorRect for screen fades. Separate from the
## flash overlay (which lives inside the HUD CanvasLayer) so fades can hide
## HUD too — a level transition with fade should black-out everything.
func _build_fade_overlay() -> void:
	_fade_layer = CanvasLayer.new()
	_fade_layer.layer = 20
	add_child(_fade_layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade_layer.add_child(root)
	_fade_overlay = ColorRect.new()
	_fade_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade_overlay.color = Color(_fade_color.r, _fade_color.g, _fade_color.b, 0.0)
	root.add_child(_fade_overlay)


## Per-frame fade lerp + state-machine progress. delta is real seconds.
##
## When _fade_duration_remaining > 0, lerp alpha toward target by the
## per-frame fraction. When it hits 0, alpha snaps to target and the
## state machine advances (if engaged):
##   FADING_OUT done → fully black: queue level transition, flip to FADING_IN
##   FADING_IN done  → fully clear: return to IDLE
func _update_fade(delta: float) -> void:
	if _fade_overlay == null:
		return
	if _fade_duration_remaining > 0.0:
		var step: float = min(delta, _fade_duration_remaining)
		var t: float = step / _fade_duration_remaining
		_fade_alpha = lerp(_fade_alpha, _fade_target_alpha, t)
		_fade_duration_remaining -= step
		if _fade_duration_remaining <= 0.0:
			_fade_alpha = _fade_target_alpha
			_fade_duration_remaining = 0.0
			_advance_fade_phase()
	# Apply current alpha + color to overlay every frame (cheap; lets
	# external state edits like color swaps land immediately).
	_fade_overlay.color = Color(
		_fade_color.r, _fade_color.g, _fade_color.b, clamp(_fade_alpha, 0.0, 1.0)
	)


## Called when _fade_duration_remaining hits zero. Drives the
## transition_level state machine forward; no-op for plain screen_fade.
func _advance_fade_phase() -> void:
	match _fade_phase:
		FADE_PHASE_OUT:
			# Mid-transition: fully black. Queue the level swap; world.gd
			# processes _pending_level_transition between ticks. Then flip
			# into FADING_IN to bring the new level back into view.
			if _world != null and _fade_pending_target != "":
				var sched = _world.get("scheduler")
				if sched != null and sched.get("env") != null:
					(sched.env as Dictionary)["_pending_level_transition"] = _fade_pending_target
			_fade_pending_target = ""
			# Camera must snap to the new player position (next frame); the
			# old smooth-follow lerp would interpolate from the OLD level's
			# coords to the new level's coords, exposing empty terrain.
			_camera_director.set_snap_pending()
			_fade_target_alpha = 0.0
			_fade_duration_remaining = _fade_half_duration
			_fade_phase = FADE_PHASE_IN
			if _fade_duration_remaining <= 0.0:
				_fade_alpha = 0.0
				_fade_phase = FADE_PHASE_IDLE
		FADE_PHASE_IN:
			_fade_phase = FADE_PHASE_IDLE


# ============================================================
# FIRST-PERSON VIEWMODEL (Tier 2.6r)
# ============================================================
# Doom/CSGO-style "weapon in hand" rendering. Configured via
# scene.json's camera.viewmodel block:
#   "viewmodel": {
#     "follow_state": "current_weapon",
#     "offset": [0.3, -0.25, -0.5],
#     "weapons": {
#       "1": {"mesh": "viewmodel_plasma"},
#       "2": {"mesh": "viewmodel_shotgun"},
#       "3": {"mesh": "viewmodel_rocket"}
#     }
#   }
# Each weapon's mesh is built once at first-person setup; runtime swap
# just toggles visibility based on actor's `follow_state` field value.

var _viewmodel_root: Node3D = null
var _viewmodel_meshes: Dictionary = {}  # str(state value) → Node3D


func _setup_viewmodel(cam_cfg: Dictionary) -> void:
	if _viewmodel_root != null:
		return
	if _camera_director._camera3d == null:
		return
	var vm_cfg = cam_cfg.get("viewmodel", null)
	if not (vm_cfg is Dictionary):
		return
	var weapons = vm_cfg.get("weapons", null)
	if not (weapons is Dictionary) or weapons.is_empty():
		return
	_viewmodel_root = Node3D.new()
	_viewmodel_root.name = "Viewmodel"
	_camera_director._camera3d.add_child(_viewmodel_root)
	var offset_arr: Array = vm_cfg.get("offset", [0.3, -0.25, -0.5])
	if offset_arr.size() >= 3:
		_viewmodel_root.position = Vector3(
			float(offset_arr[0]), float(offset_arr[1]), float(offset_arr[2])
		)
	var lib := MeshLib.load_from_file("res://data/meshes.json")
	for key in weapons.keys():
		var w = weapons[key]
		if not (w is Dictionary):
			continue
		var mesh_name := str(w.get("mesh", ""))
		if mesh_name == "" or not lib.has(mesh_name):
			continue
		var mesh_def := lib.get_mesh(mesh_name)
		var mesh_node := Node3D.new()
		mesh_node.name = "vm_%s" % str(key)
		mesh_node.visible = false
		var params: Dictionary = MeshLib.merge_params(mesh_def, w.get("params", {}) as Dictionary)
		MeshLib.build_primitives_into(mesh_node, mesh_def.get("primitives", []), params)
		_viewmodel_root.add_child(mesh_node)
		_viewmodel_meshes[str(key)] = mesh_node


func _update_viewmodel(actor, cam_cfg: Dictionary) -> void:
	if _viewmodel_root == null:
		return
	var vm_cfg = cam_cfg.get("viewmodel", null)
	if not (vm_cfg is Dictionary):
		return
	var follow_state := str(vm_cfg.get("follow_state", ""))
	if follow_state == "" or actor == null:
		return
	var current_v = (actor as Entity).get_state(follow_state, "")
	# Coerce numeric state values to string for dict lookup
	var current := str(int(current_v)) if current_v is int or current_v is float else str(current_v)
	for key in _viewmodel_meshes:
		(_viewmodel_meshes[key] as Node3D).visible = (str(key) == current)


# Tracks whether we've done the initial cursor capture for first-person.
# Without this, the FPS camera mode would auto-recapture every frame and
# fight ESC's release.
var _fp_initial_capture_done: bool = false

# Last-frame camera mode — used to detect transitions in/out of FP so we
# can capture/release the mouse cursor exactly once per transition (rather
# than every frame, which would fight ESC). 2026-05-08.
var _camera_mode_last: String = ""

## Drain accumulated mouse motion → update actor.state.facing (yaw) and
## optionally state.pitch. Returns the actor entity (or null). Mouse-y
## controls pitch only if cam_cfg.use_pitch is true (clamped to ±π/2 - 0.1).
##
## When cursor is VISIBLE (user paused via ESC), discard accumulated
## delta without applying — prevents camera snapping on resume.
# ============================================================
# HUD CONSTRUCTION
# ============================================================


## ADR 0021/0044/0045 audit (2026-05-13): JSON-driven Control construction
## is the CORRECT pattern — engine reads hud.json, instantiates Godot
## Controls (Label / ProgressBar / Panel / VBoxContainer / ColorRect),
## applies per-element style overrides. NOT replaceable by Theme +
## PackedScene: that would tie HUD authoring to .tscn files (Godot editor)
## instead of JSON, breaking the LLM-content-generation pipeline.
## Per-element `add_theme_*_override` is Yume's use of Godot's Theme system,
## not a reinvention. The audit is documented here so the next reviewer
## doesn't ask the same question.
func _build_hud() -> void:
	if _hud_cfg.is_empty():
		return
	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 10
	add_child(_hud_layer)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(root)

	# Panels
	for panel_cfg in _hud_cfg.get("panels", []):
		_build_panel(root, panel_cfg as Dictionary)

	# Controls hint (bottom-left). ADR 0009 Phase 2c: @-prefix resolution.
	var hint := str(_hud_cfg.get("controls_hint", ""))
	if hint.begins_with("@"):
		var resolved_hint := _resolve_at_ref(hint)
		if resolved_hint != "":
			hint = resolved_hint
	if hint != "":
		var hl := Label.new()
		hl.text = hint
		hl.position = Vector2(20, 0)
		hl.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
		hl.offset_top = -90
		hl.offset_bottom = -20
		hl.offset_right = 360
		_apply_label_style(hl, 14, Color(0.9, 0.95, 1, 0.85))
		root.add_child(hl)

	# Tier 2.6l — full-screen flash overlay for damage / impact feedback
	_flash_overlay = ColorRect.new()
	_flash_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_overlay.color = Color(0, 0, 0, 0)
	root.add_child(_flash_overlay)

	# Win / lose panel (hidden until triggered)
	_win_panel = Panel.new()
	_win_panel.set_anchors_preset(Control.PRESET_CENTER)
	_win_panel.size = Vector2(520, 240)
	_win_panel.position = Vector2(-260, -120)
	_win_panel.visible = false
	root.add_child(_win_panel)

	_win_label = Label.new()
	_win_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_win_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_win_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_apply_label_style(_win_label, 28, Color(1, 0.95, 0.7, 1))
	_win_panel.add_child(_win_label)


func _build_panel(root: Control, panel_cfg: Dictionary) -> void:
	var vbox := VBoxContainer.new()
	var anchor := str(panel_cfg.get("anchor", "top-left"))
	match anchor:
		"top-left":
			# y=50 (was 20) to leave room for top-center objective banner
			# above it. Banner occupies y=[12,44]; this starts at y=50.
			vbox.position = Vector2(20, 50)
			vbox.size = Vector2(360, 240)
		"top-right":
			# Author-overridable width: default 200 px (just enough for a
			# 180-px minimap with 10px padding). Vbox is right-aligned so
			# children sit flush against the screen's right edge.
			# Empirical case 2026-05-10: Aldenmere only had a minimap in
			# top-right; with a 360-wide vbox (default-aligned LEFT)
			# the minimap sat ~200px from the right edge — looked
			# "ugly", "not in the corner". Tightened to 200 + alignment
			# END so children hug the right edge.
			var w_tr: float = float(panel_cfg.get("width", 200))
			vbox.set_anchors_preset(Control.PRESET_TOP_RIGHT)
			vbox.offset_left = -(w_tr + 10)
			vbox.offset_top = 12
			vbox.offset_right = -10
			vbox.offset_bottom = 12 + float(panel_cfg.get("height", 320))
			vbox.alignment = BoxContainer.ALIGNMENT_END
		"bottom-left":
			vbox.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
			vbox.offset_left = 20
			vbox.offset_top = -240
			vbox.offset_right = 380
			vbox.offset_bottom = -20
		"center":
			# Centered overlay — for crosshairs, target reticles, etc.
			# VBox sits in the middle of the screen; child elements stack
			# but typical use is a single element (one crosshair). Box
			# half-size defaults to 32 px; override with `width` + `height`
			# in panel_cfg for larger reticles or stacked center HUD.
			var w: float = float(panel_cfg.get("width", 64))
			var h: float = float(panel_cfg.get("height", 64))
			vbox.set_anchors_preset(Control.PRESET_CENTER)
			vbox.offset_left = -w * 0.5
			vbox.offset_top = -h * 0.5
			vbox.offset_right = w * 0.5
			vbox.offset_bottom = h * 0.5
			vbox.alignment = BoxContainer.ALIGNMENT_CENTER
		"top-center":
			# Single-line objective banner along the top edge. Default
			# height 32 (just one row), keeping it ABOVE the top-left
			# day/time stack which starts at y=20 and extends down. If
			# top-center bottom = 32 and top-left first row at y=20-44,
			# they'd overlap on x where they cross. Mitigation: top-left
			# is reserved for x∈[20,380]; top-center centers — at any
			# resolution wider than 760px they don't overlap. For
			# narrower viewports, author can override width to be smaller.
			# Empirical case 2026-05-10: Aldenmere objective banner was
			# 600px wide centered, day-text at top-left was 360px from
			# x=20. At 960px viewport, banner spans [180,780], day
			# spans [20,380] — overlap on [180,380]. Now: y separated
			# (banner 12-44, day-stack starts at 50).
			var w_tc: float = float(panel_cfg.get("width", 760))
			var y_top: float = float(panel_cfg.get("y_offset", 12))
			var h_tc: float = float(panel_cfg.get("height", 32))
			# PRESET_CENTER_TOP anchors the vbox to the top-middle of the
			# viewport (anchor x=0.5, y=0); offsets are relative to that
			# centerpoint so width = offset_right - offset_left = w_tc.
			# Empirical case 2026-05-10: using PRESET_TOP_WIDE stretched the
			# vbox full-viewport-width regardless of offsets, leaving Labels
			# default-left-aligned at x=-w*0.5 (off-screen left). FP-mode
			# crosshair-target text and objective banner both invisible.
			vbox.set_anchors_preset(Control.PRESET_CENTER_TOP)
			vbox.offset_left = -w_tc * 0.5
			vbox.offset_top = y_top
			vbox.offset_right = w_tc * 0.5
			vbox.offset_bottom = y_top + h_tc
			vbox.alignment = BoxContainer.ALIGNMENT_CENTER
		"bottom-center":
			# Centered along bottom edge. Used for controls hint strip.
			# PRESET_CENTER_BOTTOM anchors to the bottom-middle of the
			# viewport (anchor x=0.5, y=1); offsets relative so width =
			# offset_right - offset_left = w_bc. See top-center note above
			# for the empirical bug fixed 2026-05-10.
			var w_bc: float = float(panel_cfg.get("width", 920))
			vbox.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
			vbox.offset_left = -w_bc * 0.5
			vbox.offset_top = -40
			vbox.offset_right = w_bc * 0.5
			vbox.offset_bottom = -10
			vbox.alignment = BoxContainer.ALIGNMENT_CENTER
		"bottom-right":
			# Mirror of bottom-left.
			vbox.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
			vbox.offset_left = -380
			vbox.offset_top = -240
			vbox.offset_right = -20
			vbox.offset_bottom = -20
		"center-left":
			# Vertically centered, anchored to left edge. Used for vitals
			# stacks that should track the screen's vertical middle.
			vbox.set_anchors_preset(Control.PRESET_LEFT_WIDE)
			vbox.offset_left = 20
			vbox.offset_top = -120
			vbox.offset_right = 220
			vbox.offset_bottom = 120
		"center-right":
			vbox.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
			vbox.offset_left = -220
			vbox.offset_top = -120
			vbox.offset_right = -20
			vbox.offset_bottom = 120
	root.add_child(vbox)

	# Centered anchors expect their child labels to render horizontally
	# centered inside the vbox. Default Label alignment is LEFT, which
	# pushes text to the container's left edge — invisible-feeling for
	# centered panels. Pass an alignment hint to _build_element.
	var center_children := anchor in ["center", "top-center", "bottom-center"]
	for elem_cfg in panel_cfg.get("elements", []):
		_build_element(vbox, elem_cfg as Dictionary, center_children)


func _build_element(parent: Container, cfg: Dictionary, center_h: bool = false) -> void:
	var t := str(cfg.get("type", ""))
	match t:
		"label":
			var lbl := Label.new()
			_apply_label_style(lbl, int(cfg.get("size", 18)), _color(cfg.get("color", "#ffffff")))
			# Static text — set immediately (binding-less labels would
			# otherwise render empty since _apply_binding_to_node only
			# fires when `binds` is set). Per data-demo.md text discipline:
			# format strings start with capital letter or → to bypass
			# the formula evaluator.
			if cfg.has("text"):
				lbl.text = str(cfg["text"])
			# Per-label `align` hint overrides panel default. Values:
			# "left" / "center" / "right".
			var align := str(cfg.get("align", ""))
			if align == "center" or (align == "" and center_h):
				lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			elif align == "right":
				lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			parent.add_child(lbl)
			_bound_elements.append({"node": lbl, "cfg": cfg})
		"progress_bar":
			var pb := ProgressBar.new()
			# Honor explicit width/height when authored; default 280x16 otherwise.
			var pb_w: float = float(cfg.get("width", 280))
			var pb_h: float = float(cfg.get("height", 16))
			pb.custom_minimum_size = Vector2(pb_w, pb_h)
			pb.max_value = float(cfg.get("max", 100))
			pb.show_percentage = false
			parent.add_child(pb)
			_bound_elements.append({"node": pb, "cfg": cfg})
		"spacer":
			var sp := Control.new()
			sp.custom_minimum_size = Vector2(1, int(cfg.get("height", 8)))
			parent.add_child(sp)
		"crosshair":
			# Simple text-based crosshair — uses a Label with a glyph.
			# Cheap, theme-able, no extra draw code. For richer reticles,
			# extend later with a Control + custom _draw.
			var ch := Label.new()
			ch.text = str(cfg.get("glyph", "+"))
			_apply_label_style(ch, int(cfg.get("size", 28)), _color(cfg.get("color", "#ffffff")))
			ch.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			ch.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			parent.add_child(ch)
		"minimap":
			# Drawn-dot top-down map. Live entity positions projected
			# into widget pixel space each frame. See minimap_widget.gd
			# for spec docs (size / world_bounds / tag_colors / etc.).
			var mm := MinimapWidget.new()
			mm.configure(cfg)
			mm.bind_world(_world)
			parent.add_child(mm)
			_bound_elements.append({"node": mm, "cfg": cfg})


func _apply_label_style(lbl: Label, font_size: int, color: Color) -> void:
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 4)
	lbl.add_theme_font_size_override("font_size", font_size)


# ============================================================
# HUD UPDATES (per-frame, evaluates bindings)
# ============================================================


func _update_bound_elements() -> void:
	for entry in _bound_elements:
		var node: Node = entry["node"]
		var cfg: Dictionary = entry["cfg"]
		# Minimap self-redraws per frame from live world.entities;
		# no string binding needed.
		if node is MinimapWidget:
			(node as MinimapWidget).tick()
			continue
		var binding := str(cfg.get("binds", ""))
		if binding == "":
			continue
		var value = _resolve_binding(binding)
		if value == null:
			continue
		_apply_binding_to_node(node, cfg, value)


## Resolve a binding path like "player.score" → numeric value.
## Lookup: first entity tagged with the root segment, get_state(field).
## Special root "world" → reads env.world dict.
func _resolve_binding(path: String):
	var parts := path.split(".")
	if parts.size() < 2:
		return null
	var root := str(parts[0])
	var field := str(parts[1])

	if root == "world":
		var w: Dictionary = _world.get("world_state") as Dictionary
		return w.get(field, null) if w != null else null

	var ent := _find_entity_by_tag(root)
	if ent == null:
		return null
	if ent.has_method("get_state"):
		return ent.get_state(field, null)
	return null


func _apply_binding_to_node(node: Node, cfg: Dictionary, value) -> void:
	if node is Label:
		var lbl: Label = node
		# format_phases: array of strings, picked by float [0, 1]
		if cfg.has("format_phases"):
			var phases: Array = cfg["format_phases"]
			if phases.size() > 0 and (value is float or value is int):
				var idx: int = clamp(int(float(value) * phases.size()), 0, phases.size() - 1)
				lbl.text = str(phases[idx])
				return
		# format with {} placeholder. ADR 0009 Phase 2c: @strings.x.y
		# refs resolve via ui/strings.json. Falls back to literal text
		# if ref unresolved.
		var fmt := str(cfg.get("format", "{}"))
		if fmt.begins_with("@"):
			var resolved := _resolve_at_ref(fmt)
			if resolved != "":
				fmt = resolved
		lbl.text = fmt.replace("{}", str(_format_value(value)))
	elif node is ProgressBar:
		var pb: ProgressBar = node
		var v := float(value)
		pb.value = v
		# color_lerp: [low_color, high_color] — interpolate by value/max
		if cfg.has("color_lerp"):
			var arr: Array = cfg["color_lerp"]
			if arr.size() == 2:
				var lo := _color(arr[0])
				var hi := _color(arr[1])
				pb.modulate = lo.lerp(hi, clamp(v / pb.max_value, 0.0, 1.0))


func _format_value(v) -> String:
	if v is float:
		return "%d" % int(v)  # round to int by default for HUD
	return str(v)


# ============================================================
# UTIL
# ============================================================

# ADR 0009 Phase 2b/2c — content-indirection caches. Both lazy-loaded
# on first @-resolve; lazy because most games may not use either layer.
var _cue_cache: Dictionary = {}
var _cue_cache_loaded: bool = false
var _strings_cache: Dictionary = {}
var _strings_cache_loaded: bool = false


## Resolve `@<namespace>.<key>` reference. Two namespaces today:
##   @cues.<name>      → audio/cues.json["cues"][name] (Phase 2b)
##   @strings.<a.b.c>  → ui/strings.json[a][b][c]      (Phase 2c)
## Returns "" if namespace unknown, file missing, or key not found
## (silent fallback — caller decides what to do).
func _resolve_at_ref(ref: String) -> String:
	var rest: String = ref.substr(1)
	var dot: int = rest.find(".")
	if dot < 0:
		return ""
	var ns: String = rest.substr(0, dot)
	var key: String = rest.substr(dot + 1)
	match ns:
		"cues":
			if not _cue_cache_loaded:
				_load_cue_cache()
			return str(_cue_cache.get(key, ""))
		"strings":
			if not _strings_cache_loaded:
				_load_strings_cache()
			return _resolve_dotted_string(_strings_cache, key)
	return ""


## Walk a dotted path through a dict-of-dicts. e.g. "hud.level_label"
## → cache["hud"]["level_label"]. Returns "" if any segment missing.
static func _resolve_dotted_string(cache: Dictionary, key: String) -> String:
	var parts: PackedStringArray = key.split(".")
	var cur = cache
	for part in parts:
		if not (cur is Dictionary):
			return ""
		if not (cur as Dictionary).has(part):
			return ""
		cur = (cur as Dictionary)[part]
	return str(cur) if cur != null else ""


func _load_cue_cache() -> void:
	_cue_cache_loaded = true
	var spec := _read_json_file_in_data("audio/cues.json")
	var cues = spec.get("cues", {})
	if cues is Dictionary:
		_cue_cache = cues


func _load_strings_cache() -> void:
	_strings_cache_loaded = true
	# ADR 0009 Phase 2c: ui/strings.json is the localization layer.
	# Schema is freeform nested dict; @strings.x.y.z walks the path.
	# Future: ui/strings.<lang>.json for locale switching.
	_strings_cache = _read_json_file_in_data("ui/strings.json")


## Read a JSON file under data_root. Returns {} on any failure
## (missing file, parse error, non-dict root). Used by lazy-loaders.
func _read_json_file_in_data(rel_path: String) -> Dictionary:
	if _world == null:
		return {}
	var dr = _world.get("data_root")
	var root := (str(dr) if dr != null else "").rstrip("/")
	if root == "":
		return {}
	var path := root + "/" + rel_path
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		return {}
	if not (json.data is Dictionary):
		return {}
	return json.data


func _find_entity_by_tag(tag: String) -> Object:
	if _world == null:
		return null
	var entities: Dictionary = _world.get("entities") as Dictionary
	if entities == null:
		return null
	for ent in entities.values():
		if ent != null and ent.has_method("has_tag") and ent.has_tag(tag):
			return ent
	return null


static func _to_vec2(v) -> Vector2:
	if v is Vector2:
		return v
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO


static func _color(v) -> Color:
	if v is Color:
		return v
	if v is String:
		return Color(str(v))
	return Color.WHITE
