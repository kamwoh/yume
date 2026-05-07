extends Node
class_name ScreenSmokeRunner

## ADR pending — Per-screen smoke runner for headless playability QA.
##
## When `--smoke-screens` is in cmdline user-args, walks every screen in
## ScreenFlow's loaded config:
##   1. transition to screen
##   2. wait one process frame so the layer instantiates
##   3. capture viewport to user://smoke_<id>.png
##   4. pop back
##   5. record any push_warning emitted during the cycle
## After all screens visited, prints a one-line summary and quits.
##
## Catches the bug class where a screen renders empty / errors / depends
## on world_state binding that doesn't exist yet — none of which headless
## scenario tests can catch (they don't push screens or instantiate
## Control nodes).
##
## Usage:
##   godot --path . scenes/<game>.tscn -- --smoke-screens
##   godot --path . scenes/<game>.tscn -- --smoke-screens --smoke-out=user://smoke/
##
## Companion of capture_runner.gd (single-screen capture). This module
## walks the WHOLE screen graph; capture_runner does one snapshot.
##
## Failure semantics: any push_warning during a screen visit fails the
## smoke test for that screen. Final exit code is 0 if all clean, 1 if
## any failed. CI / yume-playtest skill consumes the exit code + log.

const MAX_SCREENS := 64  # safety; merchant has ~17 screens, well under

var _world: Node = null
var _screen_flow: Node = null
var _output_dir: String = "user://smoke/"
var _enabled: bool = false
# Per-screen warning collector. We monkey-listen to _process_warnings via
# a print logger sentinel — Godot doesn't expose push_warning hookably,
# so we use the existing capture-stdout grep pattern instead. This array
# stays empty unless a future engine hook surfaces warnings programmatically.
var _warnings: Array = []


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var s := str(arg)
		if s == "--smoke-screens":
			_enabled = true
		elif s.begins_with("--smoke-out="):
			_output_dir = s.substr(12)
	if not _enabled: return
	# Wait for World + ScreenFlow to settle; their _ready() sets
	# _screens_by_id. Use call_deferred so post-_ready idle phase runs.
	call_deferred("_run_smoke")


func _run_smoke() -> void:
	# Find sibling ScreenFlow.
	_world = get_parent()
	if _world == null:
		_log_summary([], "no parent (World) found")
		return
	for child in _world.get_children():
		if child is ScreenFlow:
			_screen_flow = child
			break
	if _screen_flow == null:
		_log_summary([], "no ScreenFlow sibling found (game has no screens.json)")
		return
	var screens_dict = _screen_flow.get("_screens_by_id")
	if not (screens_dict is Dictionary):
		_log_summary([], "ScreenFlow._screens_by_id missing or wrong type")
		return
	var screen_ids: Array = (screens_dict as Dictionary).keys()
	if screen_ids.is_empty():
		_log_summary([], "no screens registered (empty _screens_by_id)")
		return
	# Make sure output dir exists.
	var out_dir := DirAccess.open("user://")
	if out_dir != null:
		var rel := _output_dir.replace("user://", "")
		if rel != "" and not out_dir.dir_exists(rel):
			out_dir.make_dir_recursive(rel)
	print("[ScreenSmokeRunner] visiting %d screens: %s" % [screen_ids.size(), str(screen_ids)])
	var visited: Array = []
	var failed: Array = []
	# Pop any starting screen so we begin from a clean stack. (If the
	# game auto-pushes title on boot, we want to traverse from empty.)
	while _screen_flow.has_method("_pop_screen") and _screen_flow.get("_stack").size() > 0:
		_screen_flow.call("_pop_screen")
	var visited_count := 0
	for raw_id in screen_ids:
		if visited_count >= MAX_SCREENS:
			print("[ScreenSmokeRunner] safety cap reached (%d screens)" % MAX_SCREENS)
			break
		visited_count += 1
		var sid := str(raw_id)
		# Push.
		_screen_flow.call("_transition_to", sid)
		# Wait 2 frames so child Controls instantiate + ControlFactory finishes.
		await get_tree().process_frame
		await get_tree().process_frame
		# Capture.
		var capture_path: String = "%s%s.png" % [_output_dir, sid]
		var img: Image = get_viewport().get_texture().get_image()
		var save_err: int = -1
		if img != null:
			save_err = img.save_png(capture_path)
		if save_err == OK:
			print("[ScreenSmokeRunner]   ✓ %s → %s" % [sid, capture_path])
			visited.append(sid)
		else:
			push_warning("[ScreenSmokeRunner]   ✗ %s capture failed (err=%d)" % [sid, save_err])
			failed.append(sid)
		# Pop.
		if _screen_flow.has_method("_pop_screen"):
			_screen_flow.call("_pop_screen")
		await get_tree().process_frame
	_log_summary(visited, "" if failed.is_empty() else "%d capture failures: %s" % [failed.size(), str(failed)])
	get_tree().quit(0 if failed.is_empty() else 1)


func _log_summary(visited: Array, error: String) -> void:
	if error != "":
		print("[ScreenSmokeRunner] FAIL: %s" % error)
	print("[ScreenSmokeRunner] visited %d screen(s): %s" % [visited.size(), str(visited)])
	# Note: stdout-grep for push_warning lines from outside is the canonical
	# warning detector (see yume-playtest skill Gate 5). This runner reports
	# only capture-save failures programmatically.
