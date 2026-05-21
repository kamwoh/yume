extends Node

## Tier 2.6r — first-class visual QA capture.
##
## Autoload. Activates only when `--capture-after=<seconds>` is in the
## cmdline user-args. Otherwise no-op (zero overhead in normal play).
##
## Usage:
##   godot --path . scenes/<game>.tscn -- --capture-after=3
##                                       --capture-output=user://shot.png
##
## After delay, captures the main viewport, saves PNG, quits engine.
## Used by:
##   - scripts/play.sh `--capture` flag (UX wrapper)
##   - yume-qa-tester skill in /yume-design Phase 5 (auto-VQA)
##   - any scene's smoke test
##
## Design: parse cmdline args ONCE in _ready; bail if no capture flag.
## Single timer + signal handler. Quits engine on save (matches existing
## headless smoke patterns).


func _ready() -> void:
	var delay := -1.0
	var output_path := "user://_capture.png"
	# 2026-05-06 ext: scripted input for visual QA via cmdline.
	# --capture-input=move_east,2.0;move_north,1.0 holds each action.
	# 2026-05-10 ext: `+` separator for SIMULTANEOUS actions.
	# 2026-05-10 ext (ADR 0039): cmdline syntax now compiles to a step list
	# and delegates to StepRunner. Same execution path as scenario tests.
	# --capture-script=<path> loads a JSON step list directly (richer than
	# fits on a cmdline — supports click, expect, screenshot, etc.).
	var input_script := ""
	var script_path := ""
	for arg in OS.get_cmdline_user_args():
		var s := str(arg)
		if s.begins_with("--capture-after="):
			delay = float(s.substr(16))
		elif s.begins_with("--capture-output="):
			output_path = s.substr(17)
		elif s.begins_with("--capture-input="):
			input_script = s.substr(16)
		elif s.begins_with("--capture-script="):
			script_path = s.substr(17)
	if delay <= 0.0 and script_path == "":
		return  # no capture requested — no-op
	await get_tree().process_frame

	# Find the World node — required for StepRunner. Look up via root since
	# capture_runner is an autoload and World is in the scene tree.
	var world := _find_world()

	# --capture-script takes precedence if present (richer); else fall back
	# to legacy cmdline parsing.
	var steps: Array = []
	if script_path != "":
		steps = _load_script(script_path)
	elif input_script != "":
		steps = _compile_cmdline_to_steps(input_script)

	if not steps.is_empty() and world != null:
		var ctx: Dictionary = {
			"verbose": false, "passed": 0, "failed": 0, "failures": [], "screenshots": []
		}
		await StepRunner.run(steps, world, ctx)
		for f in ctx.get("failures", []):
			push_warning("[CaptureRunner] step failed: %s" % str(f))

	# Settle delay before final capture (mirrors legacy behavior).
	# During settle, sample FPS each second so ADR acceptance gates can
	# track performance regressions. Skipped when delay < 1.0s — no
	# meaningful sample window.
	var fps_samples: Array = []
	if delay >= 1.0:
		var settle_start := Time.get_ticks_msec()
		var settle_ms := int(delay * 1000.0)
		while (Time.get_ticks_msec() - settle_start) < settle_ms:
			await get_tree().create_timer(1.0).timeout
			fps_samples.append(Engine.get_frames_per_second())
	elif delay > 0.0:
		await get_tree().create_timer(delay).timeout

	# Final viewport capture (the "post-script" frame).
	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		push_warning("[CaptureRunner] viewport texture unavailable")
		get_tree().quit()
		return
	var err: int = img.save_png(output_path)
	if err == OK:
		print("[CaptureRunner] saved %s" % output_path)
	else:
		push_error("[CaptureRunner] save_png error %d at %s" % [err, output_path])
	# Print FPS summary if we collected samples (used by ADR 0055 §
	# acceptance gate: ≤5% drop threshold between configs).
	if not fps_samples.is_empty():
		var lo: int = 99999
		var hi: int = 0
		var sum: int = 0
		for s in fps_samples:
			lo = mini(lo, int(s))
			hi = maxi(hi, int(s))
			sum += int(s)
		print("[CaptureRunner] FPS: min=%d max=%d avg=%d (n=%d samples over %.1fs)"
			% [lo, hi, sum / fps_samples.size(), fps_samples.size(), delay])
	get_tree().quit()


# Compile legacy `'X,2.0;Y+Z,1.5'` cmdline format into ADR 0039 step list.
func _compile_cmdline_to_steps(input_script: String) -> Array:
	var steps: Array = []
	for step_str in input_script.split(";"):
		var parts := step_str.split(",")
		if parts.size() != 2:
			continue
		var action_spec := parts[0].strip_edges()
		var dur := float(parts[1])
		# `+` joins simultaneous actions into a hold array.
		var actions: Array = []
		for raw in action_spec.split("+"):
			var name := raw.strip_edges()
			if name != "":
				actions.append(name)
		if actions.is_empty():
			continue
		var step: Dictionary = {"for": dur}
		if actions.size() == 1:
			step["hold"] = actions[0]
		else:
			step["hold"] = actions
		steps.append(step)
	return steps


# Load a JSON step list from disk. Accepts `{"steps": [...]}` or `[...]`.
func _load_script(path: String) -> Array:
	if not FileAccess.file_exists(path):
		push_warning("[CaptureRunner] capture script not found: %s" % path)
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var raw := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(raw) != OK:
		push_warning("[CaptureRunner] script JSON parse error: %s" % json.get_error_message())
		return []
	if json.data is Array:
		return json.data
	if json.data is Dictionary:
		var d: Dictionary = json.data
		if d.has("steps") and d["steps"] is Array:
			return d["steps"]
	return []


func _find_world() -> World:
	var root := get_tree().root
	for child in root.get_children():
		if child is World:
			return child
		# World may be one level deeper (under the per-game scene root).
		for grand in child.get_children():
			if grand is World:
				return grand
	return null
