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

# HUD widget — owns CanvasLayer + Control tree, win/lose panel, flash
# overlay, bound-element list. Built once in _ready; per-frame:
# update_bound_elements + tick_flash. WinLoseWidget reads _win_panel /
# _win_label fields through this widget.
var _hud_builder: HudBuilder = null

# Bounds visual widget (Polygon2D floor + Line2D border, 2D demos).
var _bounds_renderer: BoundsRenderer = null

# Camera widget — owns Camera2D/3D refs, all camera modes, shake state,
# snap-pending latch, FP mouse capture state. Per-frame: update_follow +
# apply_shake. Rules emit_shell_event "shake" → set_shake().
var _camera_director: CameraDirector = null

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

# Win/lose widget — owns _won / _lost / sustain counter + condition check.
var _win_lose: WinLoseWidget = null

# First-person viewmodel widget — owns weapon-mesh nodes hanging under Camera3D.
# Setup is lazy (first FP frame builds meshes); per-frame update toggles visibility.
var _viewmodel_director: ViewmodelDirector = null

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
	_viewmodel_director = ViewmodelDirector.new(self)
	_hud_builder = HudBuilder.new(self)
	_hud_builder.build(_hud_cfg)
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
	_hud_builder.update_bound_elements()
	_bounds_renderer.update_floor_tint()
	_drain_shell_events()
	_camera_director.apply_shake()
	_hud_builder.tick_flash()
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
				_hud_builder.trigger_flash(ev.get("color", "#ff0000"), int(ev.get("duration", 8)))
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
# BINDING RESOLUTION (used by HudBuilder via shell back-ref)
# ============================================================


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
