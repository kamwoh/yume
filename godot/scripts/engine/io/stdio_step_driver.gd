extends Node

## ADR 0060 Phase 2 — single-env stdio stepping driver.
##
## Autoload. Activates ONLY when `--stdio-step` is in the cmdline user-args
## (zero overhead in normal play / capture / scenario runs, like CaptureRunner).
##
## A general single-env stepping loop over stdio (NOT "lockstep" — that is
## ADR 0061 multiplayer vocabulary). The blocking stdin read IS the step
## barrier: a harness writes one JSON action batch per line; the driver
## advances EXACTLY one tick and emits one state line. Deterministic by
## construction (StepRunner is the sole tick driver; World._process is
## disabled so wall-clock frames can't inject extra ticks).
##
## Protocol (newline-framed, both directions):
##   harness → driver (stdin):  {"actions": ["move_north", ...]}   one per line
##                              "" or "QUIT"  → clean shutdown
##   driver → harness (stdout): @YUMESTEP@{"tick":N,"hash":"<sha256>","state":{...}}
##     The @YUMESTEP@ sentinel lets the harness ignore Godot's boot-log noise
##     on the shared stdout. The FIRST emitted line has "ready":true (handshake).
##
## TRANSPORT NOTE (ADR 0060 Phase 2, 2026-05-31): state travels on STDOUT, not
## an inherited `--state-fd`. Godot's FileAccess WRITE mode cannot open pipes /
## FIFOs / `/dev/fd/N` (ERR_FILE_CANT_OPEN on every OS — verified), so the ADR's
## inherited-fd design is infeasible. The binary FRAME (pixel) channel — the
## only part that genuinely needs a non-stdout transport — is DEFERRED pending a
## file-vs-TCP decision; this driver is state-only. Use the NATIVE LINUX Godot
## binary: Windows-Godot-via-WSL stdin/stdout is unreliable (see CLAUDE.md).

const SENTINEL := "@YUMESTEP@"

## Optional frame (pixel) channel — ADR 0060 Part 3. When `--frame-file=<path>`
## is present, each step ALSO writes the rendered viewport to that regular file
## (overwritten per tick), and the emitted state line carries a "frame" block so
## the reader knows a fresh frame is ready. Transport is a regular FILE, not an
## inherited fd: Godot FileAccess can't write pipes/FIFOs (verified). The
## state/frame "wall" (Part 3) is preserved by MECHANISM separation — state on
## stdout (harness), frame on a file the agent is handed the path to — though
## with no agent yet there is a single consumer. Frame emission needs a real
## render context (launch with `--rendering-driver opengl3`); in pure --headless
## the viewport has no pixels. File format: store_32(width) store_32(height)
## then raw RGBA8 bytes (width*height*4) — no PNG encode (matches ADR intent).
var _frame_file: String = ""


func _ready() -> void:
	var active := false
	for arg in OS.get_cmdline_user_args():
		var s := str(arg)
		if s == "--stdio-step":
			active = true
		elif s.begins_with("--frame-file="):
			_frame_file = s.substr(13)
	if not active:
		return
	await _run()


func _run() -> void:
	# Let the scene boot: World.start() (auto_start) loads data synchronously in
	# _ready, but directors/renderer mount over a frame or two. Two frames is safe.
	await get_tree().process_frame
	await get_tree().process_frame
	var world := _find_world()
	if world == null:
		printerr("[stdio] no World node found — cannot step")
		get_tree().quit(2)
		return
	# StepRunner is the SOLE tick driver: disable World._process so the frames
	# that elapse while we block on stdin can't auto-advance a tick via
	# _tick_due (determinism). Mirrors scenario_runner's Phase 1 discipline.
	world.set_process(false)

	# Handshake — harness blocks until it sees this.
	_emit({"ready": true, "tick": int(world._tick_count), "hash": _hash(world)})

	while true:
		var line := OS.read_string_from_stdin().strip_edges()
		if line == "" or line == "QUIT":
			break
		var batch = JSON.parse_string(line)
		var actions: Array = []
		if batch is Dictionary:
			var a = (batch as Dictionary).get("actions", [])
			if a is Array:
				actions = a
		elif batch is Array:
			actions = batch
		_step(world, actions)
		var payload := {"tick": int(world._tick_count), "hash": _hash(world), "state": _state(world)}
		if _frame_file != "":
			var meta := await _write_frame()
			if not meta.is_empty():
				payload["frame"] = meta
		_emit(payload)

	get_tree().quit(0)


## Render the current state to the viewport and write it to _frame_file as
## store_32(w) store_32(h) + raw RGBA8. Returns {path,w,h} meta (empty on
## failure). Awaits one frame so the renderer redraws the just-advanced state
## before readback. The file is fully written + closed BEFORE the caller emits
## the state line, so a reader that waits for the state line never sees a
## partial frame.
func _write_frame() -> Dictionary:
	# Let the renderer redraw entity positions for the tick we just advanced.
	await get_tree().process_frame
	var vp := get_viewport()
	if vp == null:
		return {}
	var tex := vp.get_texture()
	if tex == null:
		return {}
	var img: Image = tex.get_image()  # synchronous GPU->CPU readback
	if img == null:
		return {}
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var f := FileAccess.open(_frame_file, FileAccess.WRITE)
	if f == null:
		printerr("[stdio] cannot open frame file: ", _frame_file)
		return {}
	f.store_32(w)
	f.store_32(h)
	f.store_buffer(img.get_data())
	f.close()  # close (not just flush) so the reader sees a complete file
	return {"path": _frame_file, "w": w, "h": h, "bytes": w * h * 4}


## One env step: apply the action batch as the inputs held THIS tick, advance
## exactly one tick, release. Routes through the SAME InputRegistrar.poll seam
## live play + StepRunner use (ADR 0060 Phase 1) — scripted env input is
## indistinct from a keypress. Actions are treated as a per-tick held set (the
## standard gym/RL model); press-edge nuance across steps is intentionally not
## modeled here (no frame elapses between steps under the blocking read).
func _step(world: World, actions: Array) -> void:
	for a in actions:
		if InputMap.has_action(str(a)):
			Input.action_press(str(a))
	if not _frozen(world):
		StepRunner._drive_poll(world)
	world.advance_one_tick()
	StepRunner._tick_character_bodies(world)
	for a in actions:
		if InputMap.has_action(str(a)):
			Input.action_release(str(a))


func _frozen(world: World) -> bool:
	var ws: Dictionary = world.world_state
	return int(ws.get("screen_freeze_world", 0)) != 0 or int(ws.get("overlay_freeze_world", 0)) != 0


func _hash(world: World) -> String:
	return str(DeterminismHash.canonical(world).get("hash", ""))


## JSON-safe dynamic snapshot: world_state + per-entity {state, position}.
## (Static def/properties are constant — omitted; the canonical hash covers
## the full state for determinism checks.)
func _state(world: World) -> Dictionary:
	var ents: Dictionary = {}
	var entities: Dictionary = world.scheduler.env.get("entities", {}) if world.scheduler != null else {}
	for id in entities:
		var e = entities[id]
		if e is Entity:
			ents[str(id)] = {
				"state": _jsonify((e as Entity).state),
				"position": _jsonify((e as Entity).get_planar_position()),
			}
	return {"world": _jsonify(world.world_state), "entities": ents}


## Recursively convert Godot types to JSON-native values (Vector2/3 → arrays).
func _jsonify(v):
	if v is Vector2:
		return [v.x, v.y]
	if v is Vector3:
		return [v.x, v.y, v.z]
	if v is Dictionary:
		var out: Dictionary = {}
		for k in v:
			out[str(k)] = _jsonify(v[k])
		return out
	if v is Array:
		var arr: Array = []
		for x in v:
			arr.append(_jsonify(x))
		return arr
	return v


func _emit(payload: Dictionary) -> void:
	print(SENTINEL + JSON.stringify(payload))


func _find_world() -> World:
	var root := get_tree().root
	for child in root.get_children():
		if child is World:
			return child
		for grand in child.get_children():
			if grand is World:
				return grand
	return null
