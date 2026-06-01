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
	# Frame-SEQUENCE capture (for video): --capture-sequence=<fps>,<seconds>
	# saves <output>_0000.png, _0001.png, ... at <fps> in REAL time (no movie mode,
	# so live networked render + interpolation stay correct), starting after the
	# --capture-after delay (lets clients connect first). Stitch with ffmpeg.
	var seq_fps := 0.0
	var seq_secs := 0.0
	# EVERY-FRAME capture (smoothest video): --capture-allframes=<seconds> grabs
	# every rendered frame for <seconds> of REAL time, buffers them in RAM, then
	# writes the PNGs after the window closes. Unlike --capture-sequence (which
	# SAMPLES at a fixed fps and so shows ~1-of-N frames → big per-frame jumps),
	# this keeps every frame → continuous motion. Deferring the PNG encode keeps
	# the per-frame cost to just the GPU readback, so the engine sustains a much
	# higher real fps. Assemble at the achieved fps (frames / seconds) for real-
	# time playback. Empirical 2026-06-01: sampled capture looked "laggy" because
	# 50 frames spanned 11s but played in 5s (2.2x fast + jumpy).
	var allframes_secs := 0.0
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
		elif s.begins_with("--capture-sequence="):
			var spec := s.substr(19).split(",")
			if spec.size() >= 2:
				seq_fps = float(spec[0])
				seq_secs = float(spec[1])
		elif s.begins_with("--capture-allframes="):
			allframes_secs = float(s.substr(20))
	if delay <= 0.0 and script_path == "" and seq_fps <= 0.0 and allframes_secs <= 0.0:
		return  # no capture requested — no-op
	await get_tree().process_frame

	# Every-frame branch (see comment above). Net mode waits for GO first.
	if allframes_secs > 0.0:
		if Engine.get_meta("yume_net_await_go", false):
			var waited := 0.0
			while not Engine.get_meta("yume_net_go", false) and waited < 180.0:
				await get_tree().create_timer(0.1).timeout
				waited += 0.1
		elif delay > 0.0:
			await get_tree().create_timer(delay).timeout
		var base_af := output_path.trim_suffix(".png")
		var imgs: Array = []
		var ticks: Array = []  # server tick each captured frame SHOWS (for cross-client sync)
		var t0_af := Time.get_ticks_msec()
		var window_ms := int(allframes_secs * 1000.0)
		while (Time.get_ticks_msec() - t0_af) < window_ms:
			await get_tree().process_frame  # one grab per frame (rock-solid coroutine resume)
			var im: Image = get_viewport().get_texture().get_image()
			if im != null:
				imgs.append(im)
				ticks.append(int(Engine.get_meta("yume_net_render_tick", 0)))
		for i in range(imgs.size()):
			(imgs[i] as Image).save_png("%s_%04d.png" % [base_af, i])
		# Sidecar: one server-tick per frame index. net_video uses it to pair the
		# two clients' frames by the SAME authoritative tick → true side-by-side sync.
		var tf := FileAccess.open("%s.ticks" % base_af, FileAccess.WRITE)
		if tf != null:
			for t in ticks:
				tf.store_line(str(t))
			tf.close()
		var got_fps: float = float(imgs.size()) / max(0.001, allframes_secs)
		print("[CaptureRunner] every-frame: saved %d frames over %.1fs (~%.1f fps)"
			% [imgs.size(), allframes_secs, got_fps])
		get_tree().quit()
		return

	# Frame-sequence branch: wait `delay` (connect), then snapshot at seq_fps.
	if seq_fps > 0.0 and seq_secs > 0.0:
		# Net mode: net_driver sets `yume_net_await_go` so we hold the sequence
		# until the server signals GO (all clients spawned) — the recording then
		# starts on synced, in-place motion, never the pre-spawn/floating state.
		# Empirical 2026-06-01: a fixed --capture-after fired mid-join → one
		# character was already off-map, so sync was unreadable.
		if Engine.get_meta("yume_net_await_go", false):
			var waited := 0.0
			while not Engine.get_meta("yume_net_go", false) and waited < 180.0:
				await get_tree().create_timer(0.1).timeout
				waited += 0.1
			print("[CaptureRunner] net GO — recording %d frames" % int(seq_fps * seq_secs))
		elif delay > 0.0:
			await get_tree().create_timer(delay).timeout
		var base := output_path.trim_suffix(".png")
		var n := int(seq_fps * seq_secs)
		var period := 1.0 / seq_fps
		for i in range(n):
			var img: Image = get_viewport().get_texture().get_image()
			if img != null:
				img.save_png("%s_%04d.png" % [base, i])
			await get_tree().create_timer(period).timeout
		print("[CaptureRunner] saved %d frames %s_NNNN.png" % [n, base])
		get_tree().quit()
		return

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
