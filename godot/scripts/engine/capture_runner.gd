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
	# 2026-05-06 ext: scripted input for visual QA.
	# --capture-input=move_east,2.0;move_north,1.0 holds each action for the
	# given seconds, then captures. Lets visual-QA loops drive game state
	# (walk player to spot, press button) before snapshot. Empty = legacy.
	# 2026-05-10 ext: `+` separator for SIMULTANEOUS actions in a single step.
	# Example: --capture-input='move_north+move_west,1.5' presses both
	# move_north AND move_west, holds for 1.5s, releases both. Lets VQA
	# capture diagonal-input states (W+A pressed together) which the
	# previous sequential format couldn't reach. Steps still separated
	# by ; for sequencing.
	var input_script := ""
	for arg in OS.get_cmdline_user_args():
		var s := str(arg)
		if s.begins_with("--capture-after="):
			delay = float(s.substr(16))
		elif s.begins_with("--capture-output="):
			output_path = s.substr(17)
		elif s.begins_with("--capture-input="):
			input_script = s.substr(16)
	if delay <= 0.0:
		return  # no capture requested — no-op
	# Detach from main scene tree timing — let the game's own _ready
	# settle before we start counting.
	await get_tree().process_frame
	# Drive scripted input before the post-input capture delay.
	if input_script != "":
		for step in input_script.split(";"):
			var parts := step.split(",")
			if parts.size() != 2: continue
			var action_spec := parts[0].strip_edges()
			var dur := float(parts[1])
			# Simultaneous actions: split on `+` to get one or more action names.
			var actions: Array[String] = []
			for raw in action_spec.split("+"):
				var name := raw.strip_edges()
				if name == "":
					continue
				if not InputMap.has_action(name):
					push_warning("[CaptureRunner] unknown action: %s" % name)
					continue
				actions.append(name)
			if actions.is_empty():
				continue
			for name in actions:
				Input.action_press(name)
			await get_tree().create_timer(dur).timeout
			for name in actions:
				Input.action_release(name)
	await get_tree().create_timer(delay).timeout
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
	get_tree().quit()
