extends Node

## ADR 0061 Phase 2 — ENet transport for input-replicated lockstep.
##
## Autoload. Activates ONLY when `--lockstep-host` or `--lockstep-join=<ip:port>`
## is in the cmdline user-args (zero overhead otherwise, like CaptureRunner /
## StdioStepDriver). It is the TRANSPORT for ADR 0061: it wraps the Phase 1
## `LockstepCore` (the transport-agnostic engine side) with Godot's high-level
## multiplayer — `ENetMultiplayerPeer` + `@rpc`.
##
## Per tick, every peer broadcasts (reliable RPC) its local input batch + the
## `canonical_state_hash` of the tick it just advanced. A peer advances tick N
## only once it has every peer's input for N — the lockstep barrier, the network
## analogue of StdioStepDriver's blocking-read. The hash exchange feeds
## LockstepCore's desync detector. Replicates INPUTS, not state (ADR 0061).
##
## Flags:
##   --lockstep-host                 host (ENet server) — peer id 1
##   --lockstep-join=<ip:port>       client — connect to a host
##   --lockstep-port=<n>             port (default 7777; host + client must match)
##   --lockstep-ticks=<n>            run n lockstep ticks then write result + quit
##   --lockstep-input=<action>       optional: local peer sends this action each tick
##   --lockstep-out=<path>           write result JSON (peer_id, ticks_run,
##                                   final_hash, desync_tick, peers) then quit
##
## Use the LINUX Godot binary (same as the env — Windows-via-WSL networking +
## piping is unreliable). 2-peer loopback test: tools/yume_env/test_lockstep_net.py.

const DEFAULT_PORT := 7777
## Generous: a peer's main thread is BLOCKED while loading a heavy 3D scene
## (meshes, ground, 100s of entities) and can't pump ENet to accept/establish a
## connection until load finishes. A short timeout makes the demo flaky (one side
## gives up before the other is ready). 30s tolerates a heavy load + a human
## launching the second window by hand. Empirical 2026-05-31: 10s timed out
## intermittently with the two-character tiny_village scene (~2GB resident).
const CONNECT_TIMEOUT_SEC := 30.0
## Input-delay lockstep: a peer sends its input for tick (current + INPUT_DELAY)
## and advances tick T only once it already holds every peer's input for T —
## which (since they were sent INPUT_DELAY ticks earlier) has normally arrived,
## so the peer NEVER stalls on the wire. Trade: your own input takes effect
## INPUT_DELAY ticks later (~50ms at 60Hz) — imperceptible, and the standard
## lockstep latency-hider (vs the naive zero-delay loop that stuttered every tick).
const INPUT_DELAY := 3
## Spiral-of-death cap: never advance more than this many sim ticks in one frame
## (a long frame would otherwise try to catch up an unbounded number of ticks).
const MAX_CATCHUP_TICKS := 6

var _active := false
var _is_host := false
var _join_ip := "127.0.0.1"
var _port := DEFAULT_PORT
var _ticks_target := 20
var _input_action := ""
var _out_path := ""
var _visual := false

var _core: LockstepCore = null
var _world = null
var _local_id := 0
var _peer_set: Array = []
var _started := false
var _done := false
var _last_hash := ""
var _elapsed := 0.0
var _ts := 0.0167  # sim tick_seconds (set in _start from the world)
var _acc := 0.0  # delta accumulator for fixed-rate tick advancement
var _next_send_tick := 0  # next tick index to broadcast local input for (monotonic)


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var s := str(arg)
		if s == "--lockstep-host":
			_active = true
			_is_host = true
		elif s.begins_with("--lockstep-join="):
			_active = true
			_is_host = false
			var addr := s.substr(16)
			if addr.contains(":"):
				_join_ip = addr.get_slice(":", 0)
				_port = int(addr.get_slice(":", 1))
			else:
				_join_ip = addr
		elif s.begins_with("--lockstep-port="):
			_port = int(s.substr(16))
		elif s.begins_with("--lockstep-ticks="):
			_ticks_target = int(s.substr(17))
		elif s.begins_with("--lockstep-input="):
			_input_action = s.substr(17)
		elif s.begins_with("--lockstep-out="):
			_out_path = s.substr(15)
		elif s == "--lockstep-visual":
			_visual = true
	if not _active:
		return
	# Visual mode: keep the camera + renderer (directors) running so you can WATCH
	# two windowed instances. Motion stays tick-locked (the physics-body gate +
	# LockstepCore's tick_headless still apply), so the characters' POSITIONS are
	# deterministic; presentation directors just render them. world_boot reads
	# this flag to skip the director-gating (but NOT the physics/World gating).
	if _visual:
		Engine.set_meta("yume_lockstep_visual", true)
	# CRITICAL for cross-peer determinism: stop World._process from auto-ticking
	# from BOOT. Autoloads _ready before the scene's World, so this flag is set
	# before World ever ticks. Without it, each peer auto-advances a different
	# number of ticks while waiting for the other to connect → divergent initial
	# state (ambient tick-driven entities) → desync at lockstep tick 0. The
	# lockstep loop is the SOLE tick driver; World._process honors this flag.
	Engine.set_meta("yume_external_tick_driver", true)
	_setup_transport()


func _setup_transport() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err: int
	if _is_host:
		err = peer.create_server(_port, 7)
	else:
		err = peer.create_client(_join_ip, _port)
	if err != OK:
		_fail("ENet %s failed: err=%d" % ["create_server" if _is_host else "create_client", err])
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.connection_failed.connect(func(): _fail("connection_failed"))
	multiplayer.server_disconnected.connect(func(): _fail("server_disconnected"))
	if not _is_host:
		multiplayer.connected_to_server.connect(_on_connected_to_server)


# ============================================================
# Connection → start
# ============================================================


func _on_peer_connected(id: int) -> void:
	# Host learns each client's id here; for the 2-peer loopback test, the first
	# client completes the peer set. (A real lobby would gate on an expected
	# peer count / ready handshake — Phase 3.)
	if _is_host and not _started:
		_local_id = 1
		_peer_set = [1, id]
		_start()


func _on_connected_to_server() -> void:
	_local_id = multiplayer.get_unique_id()
	_peer_set = [1, _local_id]  # host is always id 1
	_start()


func _start() -> void:
	_world = _find_world()
	if _world == null:
		_fail("no World found")
		return
	# StepRunner-style sole-driver: disable World._process so wall-clock frames
	# can't auto-advance a tick; the lockstep loop here is the only driver.
	_world.set_process(false)
	# Keep the scene's OWN camera_mode (do not force top_down — it renders grey
	# for some scenes, e.g. tiny_village). Movement uses whatever WASD rule the
	# scene's camera_mode gates; with NO mouse input (lockstep sends only the
	# walk action) facing stays constant, so even camera-relative movement is
	# deterministic. Visual mode just nudges noon so day/night-bound lighting is
	# lit (harmless if the game has no current_hour).
	if _visual:
		for id in _world.entities:
			var e = _world.entities[id]
			if (
				e is Entity
				and (e as Entity).has_tag("world_clock")
				and (e as Entity).state.has("current_hour")
			):
				(e as Entity).state["current_hour"] = 12.0
	# Assign each peer a DISTINCT controllable character (peer i → i-th actor),
	# so two peers drive two characters. Falls back to sharing if fewer actors.
	var actors := _resolve_actors(_world)
	var amap: Dictionary = {}
	for i in range(_peer_set.size()):
		if actors.size() > 0:
			amap[_peer_set[i]] = actors[i % actors.size()]
	_core = LockstepCore.new()
	_core.configure(_local_id, _peer_set, amap)
	# Per-window camera: each peer's camera follows ITS OWN character (presentation
	# override read by camera_director._resolve_follow_entity; never touches sim
	# state, so the canonical hash is unaffected). With two `player`-tagged actors
	# this is what tells you which window controls which character.
	var local_actor := str(amap.get(_local_id, ""))
	if _visual and local_actor != "":
		Engine.set_meta("yume_local_follow_id", local_actor)
	# Tick accumulator (input-delay smoothing): advance the sim at the world's
	# fixed tick rate regardless of render FPS, so motion is smooth even when the
	# GPU is slow. Inputs are sent INPUT_DELAY ticks ahead so a peer never stalls
	# waiting on the wire (it already has the inputs for the tick it's advancing).
	_ts = float(_world.get("tick_seconds")) if _world.get("tick_seconds") != null else 0.0167
	if _ts <= 0.0:
		_ts = 0.0167
	_acc = 0.0
	_next_send_tick = 0
	_started = true
	print(
		(
			"[lockstep] started peer=%d peers=%s actors=%s ticks=%d"
			% [_local_id, str(_peer_set), str(amap), _ticks_target]
		)
	)


## Controllable characters, sorted by id (deterministic across peers): entities
## tagged `player`, else `actor`.
func _resolve_actors(world) -> Array:
	var players: Array = []
	var actors: Array = []
	for id in world.entities:
		var e = world.entities[id]
		if not (e is Entity):
			continue
		if (e as Entity).has_tag("player"):
			players.append(str(id))
		elif (e as Entity).has_tag("actor"):
			actors.append(str(id))
	players.sort()
	actors.sort()
	return players if not players.is_empty() else actors


# ============================================================
# RPC — input + hash exchange
# ============================================================


@rpc("any_peer", "call_remote", "reliable")
func _recv_input(tick: int, batch: Array) -> void:
	if _core != null:
		_core.submit_input(multiplayer.get_remote_sender_id(), tick, batch)


@rpc("any_peer", "call_remote", "reliable")
func _recv_hash(tick: int, hash: String) -> void:
	if _core != null:
		_core.submit_hash(multiplayer.get_remote_sender_id(), tick, hash)


# ============================================================
# Lockstep loop (per frame; ENet is polled by the main loop)
# ============================================================


func _process(delta: float) -> void:
	if not _active or _done:
		return
	if not _started:
		_elapsed += delta
		if _elapsed > CONNECT_TIMEOUT_SEC:
			_fail("connect timeout (no peer)")
		return

	# 1. Pre-send local input up to the INPUT_DELAY horizon (current + DELAY), once
	#    per tick. Sending ahead is what lets step 3 advance without stalling.
	_send_pending_input()
	# 2. Advance the sim at the FIXED tick rate (accumulator), as far as the
	#    barrier allows — catching up across slow frames, capped to avoid a spiral.
	_acc += delta
	var steps := 0
	while (
		_acc >= _ts
		and int(_core.current_tick) < _ticks_target
		and _core.all_inputs_ready(int(_core.current_tick))
		and steps < MAX_CATCHUP_TICKS
	):
		var r: Dictionary = _core.step(_world)
		_last_hash = str(r["hash"])
		_recv_hash.rpc(int(r["tick"]), _last_hash)
		_acc -= _ts
		steps += 1
		# current_tick advanced → push the input horizon forward immediately so a
		# multi-tick catch-up frame doesn't starve itself of inputs mid-loop.
		_send_pending_input()
	# Don't let the accumulator bank unbounded time while blocked on the barrier.
	if _acc > _ts * float(MAX_CATCHUP_TICKS):
		_acc = _ts * float(MAX_CATCHUP_TICKS)
	# 3. Finish after the target tick count.
	if int(_core.current_tick) >= _ticks_target:
		_finish()


## Broadcast local input for every tick from _next_send_tick up to the
## INPUT_DELAY horizon (current_tick + INPUT_DELAY), once each. Reliable RPC —
## a dropped input would desync, so delivery must be guaranteed.
func _send_pending_input() -> void:
	var horizon: int = int(_core.current_tick) + INPUT_DELAY
	while _next_send_tick <= horizon and _next_send_tick < _ticks_target:
		var batch: Array = [_input_action] if _input_action != "" else []
		_core.submit_input(_local_id, _next_send_tick, batch)
		_recv_input.rpc(_next_send_tick, batch)
		_next_send_tick += 1


# ============================================================
# Result / shutdown
# ============================================================


func _finish() -> void:
	if _done:
		return
	_done = true
	# Per-actor final positions — shows the characters actually WALKED (and that
	# both peers agree on where each ended up).
	var actor_pos: Dictionary = {}
	for pid in _core.actor_of_peer:
		var aid := str(_core.actor_of_peer[pid])
		if _world.entities.has(aid):
			var p = (_world.entities[aid] as Entity).get_planar_position()
			actor_pos[aid] = [snappedf(p.x, 0.001), snappedf(p.y, 0.001)]
	var result := {
		"peer_id": _local_id,
		"peers": _peer_set,
		"ticks_run": int(_core.current_tick),
		"final_hash": _last_hash,
		"desync_tick": int(_core.desync_tick),
		"actor_positions": actor_pos,
	}
	print("[lockstep] DONE %s" % JSON.stringify(result))
	if _out_path != "":
		var f := FileAccess.open(_out_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(result))
			f.close()
	# Give the last reliable RPCs a moment to flush before tearing down.
	await get_tree().create_timer(0.3).timeout
	get_tree().quit(1 if _core.has_desync() else 0)


func _fail(msg: String) -> void:
	if _done:
		return
	_done = true
	printerr("[lockstep] FAIL: %s" % msg)
	if _out_path != "":
		var f := FileAccess.open(_out_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({"error": msg, "peer_id": _local_id}))
			f.close()
	get_tree().quit(2)


func _find_world():
	var root := get_tree().root
	for child in root.get_children():
		if child is World:
			return child
		for grand in child.get_children():
			if grand is World:
				return grand
	return null
