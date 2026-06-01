extends Node

## ADR 0063 Phase 1 — client-server multiplayer (authoritative + state replication).
##
## The TWITCH counterpart to ADR 0061's lockstep. Where lockstep replicates
## INPUTS and every peer simulates deterministically, this replicates STATE: one
## peer (the host) is the AUTHORITATIVE server — it runs the full Yume sim
## (World ticks normally) — and clients do NOT simulate; they apply the server's
## state snapshots and render them. No cross-machine determinism is required (the
## server is the single source of truth), so this works with Godot's 3D physics
## as-is (the wall that blocks rollback).
##
## Phase 1 = correctness only: full state snapshots at SNAPSHOT_HZ, client
## applies them directly. No interpolation (Phase 2) or client-side prediction
## (Phase 3) yet — so remote motion is steppy and the local player has input
## latency. Those phases hide the latency; Phase 1 proves the replication.
##
## Transport (ADR 0021 — expose Godot): ENetMultiplayerPeer + @rpc, the same
## stack lockstep_driver uses. Activates ONLY on --net-host / --net-join (zero
## overhead otherwise). Sibling driver under the pluggable io/ seam: the CLIENT
## sets `yume_external_tick_driver` (World doesn't run the authoritative sim);
## the SERVER does not (it IS the sim).
##
## Flags:
##   --net-host                  host = authoritative server (peer id 1)
##   --net-join=<ip:port>        client — connect to a host
##   --net-port=<n>              port (default 7777; host + client must match)
##   --net-input=<action>        local peer's input each frame (demo/headless)
##   --net-ticks=<n>             server runs n sim ticks, then finish + quit
##   --net-out=<path>            write result JSON (peer_id, role, actor_positions)
##   --net-visual                keep camera + renderer running (watch windows)
##   --net-snapshot-hz=<n>       state send rate (default 20; decoupled from 60Hz)

const DEFAULT_PORT := 7777
const CONNECT_TIMEOUT_SEC := 30.0
const DEFAULT_SNAPSHOT_HZ := 20.0
## Phase 2 — render remote entities INTERP_DELAY behind the latest snapshot,
## interpolating between the two bracketing snapshots. The delay (2 snapshot
## periods at 20Hz) absorbs jitter + the sub-tick send rate so motion is smooth
## at render FPS instead of stepping at the snapshot rate. Standard entity lerp.
const INTERP_DELAY := 0.1
## Phase 3 — reconcile the locally-predicted owned actor toward the server's
## authoritative position. Below SNAP_THRESHOLD (m) the prediction is trusted as-is
## (no jitter at rest / on LAN where prediction ≈ server); a larger divergence
## (mispredicted collision, packet loss) is corrected by blending at RECONCILE_RATE
## per frame. (Full input-replay reconciliation — replaying unacked inputs from the
## acknowledged snapshot — is a later refinement; this v1 removes local input lag.)
const RECONCILE_RATE := 0.25
const SNAP_THRESHOLD := 0.05

var _active := false
var _is_host := false
var _join_ip := "127.0.0.1"
var _port := DEFAULT_PORT
var _input_action := ""
var _ticks_target := 600
var _out_path := ""
var _visual := false
var _snapshot_hz := DEFAULT_SNAPSHOT_HZ

var _world = null
var _local_id := 0
var _peer_set: Array = []
var _actor_of_peer: Dictionary = {}  # peer_id -> controlled actor entity id
var _local_actor := ""
var _started := false
var _done := false
var _elapsed := 0.0
var _snap_accum := 0.0
var _pending_input: Dictionary = {}  # SERVER: peer_id -> latest action string from that client
var _last_snapshot: Dictionary = {}  # CLIENT: last applied snapshot (for the result)
var _client_clock := 0.0  # CLIENT: monotonic local time, stamps snapshot arrivals
var _snap_buffer: Array = []  # CLIENT: [{t, snap}] recent snapshots for interpolation
var _owned_server_pos = null  # CLIENT: latest authoritative pos of the owned actor (Vector3)


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var s := str(arg)
		if s == "--net-host":
			_active = true
			_is_host = true
		elif s.begins_with("--net-join="):
			_active = true
			_is_host = false
			var addr := s.substr(11)
			if addr.contains(":"):
				_join_ip = addr.get_slice(":", 0)
				_port = int(addr.get_slice(":", 1))
			else:
				_join_ip = addr
		elif s.begins_with("--net-port="):
			_port = int(s.substr(11))
		elif s.begins_with("--net-input="):
			_input_action = s.substr(12)
		elif s.begins_with("--net-ticks="):
			_ticks_target = int(s.substr(12))
		elif s.begins_with("--net-out="):
			_out_path = s.substr(10)
		elif s == "--net-visual":
			_visual = true
		elif s.begins_with("--net-snapshot-hz="):
			_snapshot_hz = float(s.substr(18))
	if not _active:
		return
	if _visual:
		Engine.set_meta("yume_lockstep_visual", true)  # reuse the visual seam (keep directors)
	# Phase 3: the client RUNS the sim locally — but only to PREDICT its own actor
	# (responsive input). Remote actors are overwritten each frame with
	# interpolated server state, and the owned actor is reconciled toward the
	# server's authority; the server stays the source of truth. So we do NOT gate
	# the client's World.
	#
	# Scope (tiny_village + similar): only player actors are dynamic, so local
	# prediction of "everything" is harmless (remotes get overwritten; nothing
	# else moves). For AI-heavy games the client must predict ONLY the owned actor
	# and treat NPCs as server-authoritative (interpolated) — a later refinement;
	# until then, predicting non-owned dynamic entities locally would drift from
	# the server. Documented in ADR 0063.
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
	# Assign each peer a distinct controllable actor (sorted for a stable map).
	var actors := _resolve_actors(_world)
	for i in range(_peer_set.size()):
		if actors.size() > 0:
			_actor_of_peer[_peer_set[i]] = actors[i % actors.size()]
	_local_actor = str(_actor_of_peer.get(_local_id, ""))
	# Per-window camera: each peer's camera follows its OWN actor (presentation
	# override; never touches sim state). Same mechanism as ADR 0061's visual demo.
	if _visual and _local_actor != "":
		Engine.set_meta("yume_local_follow_id", _local_actor)
	_started = true
	print(
		(
			"[net] started role=%s peer=%d actors=%s ticks=%d snapshot_hz=%d"
			% [
				"server" if _is_host else "client",
				_local_id,
				str(_actor_of_peer),
				_ticks_target,
				int(_snapshot_hz),
			]
		)
	)


## Controllable characters, sorted by id (stable across peers): `player`-tagged,
## else `actor`-tagged. (Same resolution as lockstep_driver.)
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
# RPC — client→server input, server→client state
# ============================================================


## CLIENT → SERVER: the client's current input. The server holds the latest per
## peer and injects it each sim tick (queue_input dedups per tick). Reliable: a
## dropped input on a held action just re-arrives next frame, but ordering keeps
## press/release coherent.
@rpc("any_peer", "call_remote", "reliable")
func _recv_input(action: String) -> void:
	if _is_host and _started:
		_pending_input[multiplayer.get_remote_sender_id()] = action


## SERVER → CLIENT: an authoritative state snapshot. The host has authority over
## this RPC; clients apply it. Unreliable-ordered: snapshots supersede each other,
## so a dropped one is simply skipped (the next is newer) — never re-sent stale.
@rpc("authority", "call_remote", "unreliable_ordered")
func _recv_snapshot(snap: Dictionary) -> void:
	if not _is_host and _started:
		# Phase 2: buffer with arrival time; _render_interpolated applies it
		# INTERP_DELAY behind, lerping. (Phase 1 applied directly → stepping.)
		_snap_buffer.append({"t": _client_clock, "snap": snap})
		_last_snapshot = snap
		# Phase 3: record the owned actor's authoritative position for reconciliation.
		if _local_actor != "" and snap.has(_local_actor):
			var a: Array = snap[_local_actor]
			if a.size() >= 3:
				_owned_server_pos = Vector3(float(a[0]), float(a[1]), float(a[2]))


## SERVER → CLIENT: final authoritative snapshot + end-of-run. Reliable so the
## client applies the exact final state before reporting (Phase 1 correctness
## check: client's applied positions must equal the server's).
@rpc("authority", "call_remote", "reliable")
func _recv_done(snap: Dictionary) -> void:
	if not _is_host and not _done:
		_apply_snapshot(snap)
		_finish()


# ============================================================
# State serialization (server) / application (client)
# ============================================================


## Serialize the DYNAMIC entities (the movers — `actor`-tagged) as
## id -> [x, y, z, facing]. Static props don't move, so clients keep them at
## their loaded positions; only movers are replicated. (Phase 4 generalizes to
## any changed entity + delta compression.)
func _serialize_state() -> Dictionary:
	var out: Dictionary = {}
	for id in _world.entities:
		var e = _world.entities[id]
		if not (e is Entity) or not (e as Entity).has_tag("actor"):
			continue
		var p = (e as Entity).get_position()
		var v3 := Vector3.ZERO
		if p is Vector3:
			v3 = p
		elif p is Vector2:
			v3 = Vector3((p as Vector2).x, 0.0, (p as Vector2).y)
		var facing := float((e as Entity).get_state("facing", 0.0))
		out[str(id)] = [
			snappedf(v3.x, 0.001), snappedf(v3.y, 0.001), snappedf(v3.z, 0.001),
			snappedf(facing, 0.0001),
		]
	return out


## Apply a server snapshot to local entities (CLIENT). set_position drives the
## renderer (entity_mesh_3d reads get_position each frame) + mirrors the body
## transform; facing drives mesh yaw. Phase 1 applies directly (steppy); Phase 2
## interpolates between snapshots for smoothness.
func _apply_snapshot(snap: Dictionary) -> void:
	_last_snapshot = snap
	for id in snap:
		if not _world.entities.has(id):
			continue
		var e = _world.entities[id]
		if not (e is Entity):
			continue
		var a: Array = snap[id]
		if a.size() >= 3:
			(e as Entity).set_position(Vector3(float(a[0]), float(a[1]), float(a[2])))
		if a.size() >= 4:
			(e as Entity).set_state("facing", float(a[3]))


# ============================================================
# Per-frame loop
# ============================================================


func _process(delta: float) -> void:
	if not _active or _done:
		return
	if not _started:
		_elapsed += delta
		if _elapsed > CONNECT_TIMEOUT_SEC:
			_fail("connect timeout (no peer)")
		return
	if _is_host:
		_server_process(delta)
	else:
		_client_process(delta)


func _server_process(delta: float) -> void:
	# Inject every peer's current input for ITS actor each frame. queue_input
	# dedups (action, actor) per tick, so frame-rate queuing fires once per tick.
	if _input_action != "" and _local_actor != "":
		_world.queue_input(_input_action, {"actor": _local_actor})
	for pid in _pending_input:
		var actor := str(_actor_of_peer.get(pid, ""))
		var act := str(_pending_input[pid])
		if actor != "" and act != "":
			_world.queue_input(act, {"actor": actor})
	# Broadcast a state snapshot at the network rate (decoupled from 60Hz sim).
	_snap_accum += delta
	var period: float = 1.0 / max(1.0, _snapshot_hz)
	if _snap_accum >= period:
		_snap_accum = 0.0
		_recv_snapshot.rpc(_serialize_state())
	# Finish when the authoritative sim reaches the target tick count.
	if int(_world.get("_tick_count")) >= _ticks_target:
		_recv_done.rpc(_serialize_state())  # final authoritative state to clients
		_finish()


func _client_process(delta: float) -> void:
	_client_clock += delta
	# Phase 3 PREDICTION: apply the local input to the owned actor locally (the
	# client's World sims it this frame → instant response) AND send it to the
	# server. Real keyboard input reaches the owned actor via World._poll_input;
	# the scripted demo action is queued here.
	if _input_action != "":
		if _local_actor != "":
			_world.queue_input(_input_action, {"actor": _local_actor})
		_recv_input.rpc(_input_action)
	# Remotes: interpolate from server snapshots (owned actor is skipped — predicted).
	_render_interpolated()
	# Reconcile the predicted owned actor toward the server's authority.
	_reconcile_owned()


## Pull the locally-predicted owned actor toward the latest authoritative server
## position. On LAN (prediction ≈ server) the error is below SNAP_THRESHOLD and
## this is a no-op; a real divergence (mispredicted collision, loss) blends in at
## RECONCILE_RATE so it converges without a visible snap.
func _reconcile_owned() -> void:
	if _owned_server_pos == null or _local_actor == "":
		return
	if not _world.entities.has(_local_actor):
		return
	var e = _world.entities[_local_actor]
	if not (e is Entity):
		return
	var cur = (e as Entity).get_position()
	if not (cur is Vector3):
		return
	var err: float = (cur as Vector3).distance_to(_owned_server_pos)
	if err <= SNAP_THRESHOLD:
		return
	(e as Entity).set_position((cur as Vector3).lerp(_owned_server_pos, RECONCILE_RATE))


## Render remote entities at (now - INTERP_DELAY) by lerping between the two
## buffered snapshots that bracket that time — smooth motion at render FPS from
## a 20Hz snapshot stream. Also derives planar velocity so walk/idle animation
## rules (which read state.velocity) fire on replicated movement.
func _render_interpolated() -> void:
	if _snap_buffer.is_empty():
		return
	var rt := _client_clock - INTERP_DELAY
	var s0 = null
	var s1 = null
	for e in _snap_buffer:
		if float(e["t"]) <= rt:
			s0 = e
		if float(e["t"]) >= rt:
			s1 = e
			break
	if s0 == null:
		s0 = _snap_buffer[0]
	if s1 == null:
		s1 = _snap_buffer[_snap_buffer.size() - 1]
	var dt := float(s1["t"]) - float(s0["t"])
	var alpha := 0.0
	if dt > 0.0001:
		alpha = clampf((rt - float(s0["t"])) / dt, 0.0, 1.0)
	_apply_interp(s0["snap"], s1["snap"], alpha, dt)
	# Prune: keep the entry just before rt plus everything newer.
	while _snap_buffer.size() > 2 and float(_snap_buffer[1]["t"]) < rt:
		_snap_buffer.pop_front()


func _apply_interp(snap0: Dictionary, snap1: Dictionary, alpha: float, dt: float) -> void:
	for id in snap1:
		# Phase 3: the owned actor is PREDICTED locally (not interpolated) — skip it.
		if str(id) == _local_actor:
			continue
		if not _world.entities.has(id):
			continue
		var e = _world.entities[id]
		if not (e is Entity):
			continue
		var a1: Array = snap1[id]
		var a0: Array = snap0.get(id, a1)
		if a1.size() < 3 or a0.size() < 3:
			continue
		var pos := Vector3(
			lerpf(float(a0[0]), float(a1[0]), alpha),
			lerpf(float(a0[1]), float(a1[1]), alpha),
			lerpf(float(a0[2]), float(a1[2]), alpha),
		)
		(e as Entity).set_position(pos)
		if a1.size() >= 4 and a0.size() >= 4:
			(e as Entity).set_state("facing", lerp_angle(float(a0[3]), float(a1[3]), alpha))
		# Planar velocity (XZ) for animation_state_rules; near-zero when at rest.
		if dt > 0.0001:
			(e as Entity).set_state(
				"velocity",
				Vector2((float(a1[0]) - float(a0[0])) / dt, (float(a1[2]) - float(a0[2])) / dt),
			)


# ============================================================
# Result / shutdown
# ============================================================


func _finish() -> void:
	if _done:
		return
	_done = true
	# Per-actor positions — for the server, its authoritative truth; for the
	# client, the state it APPLIED. Phase 1 correctness: these must match.
	var actor_pos: Dictionary = {}
	for pid in _actor_of_peer:
		var aid := str(_actor_of_peer[pid])
		if _world != null and _world.entities.has(aid):
			var p = (_world.entities[aid] as Entity).get_planar_position()
			actor_pos[aid] = [snappedf(p.x, 0.001), snappedf(p.y, 0.001)]
	var result := {
		"peer_id": _local_id,
		"role": "server" if _is_host else "client",
		"actor_positions": actor_pos,
	}
	print("[net] DONE %s" % JSON.stringify(result))
	if _out_path != "":
		var f := FileAccess.open(_out_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(result))
			f.close()
	await get_tree().create_timer(0.3).timeout  # let the final reliable RPC flush
	get_tree().quit(0)


func _fail(msg: String) -> void:
	if _done:
		return
	_done = true
	printerr("[net] FAIL: %s" % msg)
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
