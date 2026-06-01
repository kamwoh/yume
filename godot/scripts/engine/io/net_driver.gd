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
var _actor_of_peer: Dictionary = {}  # peer_id -> controlled actor entity id (server)
var _player_def_of: Dictionary = {}  # entity id -> def id (server roster)
var _player_pos_of: Dictionary = {}  # entity id -> spawn pos (server roster)
var _local_actor := ""
var _started := false
var _done := false
var _elapsed := 0.0
var _snap_accum := 0.0
var _pending_input: Dictionary = {}  # SERVER: peer_id -> latest action string from that client
var _last_snapshot: Dictionary = {}  # CLIENT: last applied snapshot (for the result)
var _client_clock := 0.0  # CLIENT: monotonic local time, stamps snapshot arrivals
var _snap_buffer: Array = []  # CLIENT: [{t, snap}] recent snapshots for interpolation


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
	# PURE server-authoritative (user choice 2026-06-01): the CLIENT computes
	# NOTHING. It sends input to the server, renders the server's authoritative
	# state (interpolated), and never simulates movement itself — so we gate the
	# client's World. The SERVER runs the sim (the only authority). Trade: the
	# client's own character has round-trip input latency (no client-side
	# prediction); accepted for simplicity + a single source of truth. The camera's
	# LOOK stays local/responsive (mouse-look orients the camera immediately); only
	# POSITION is server-driven.
	if not _is_host:
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


## DEDICATED server: the host has NO player of its own. It spawns one player per
## client on join and despawns on leave. Players are NOT pre-placed — at start the
## world is cleared of any authored player/actor instances so the only players are
## server-spawned (single-player play keeps its pre-placed actor; net mode clears).
func _on_peer_connected(id: int) -> void:
	if not _is_host:
		return
	if not _started:
		_server_start()
	if _started:
		_spawn_player_for_peer(id)


func _on_peer_disconnected(id: int) -> void:
	if _is_host and _started:
		_despawn_player_for_peer(id)


func _on_connected_to_server() -> void:
	_local_id = multiplayer.get_unique_id()
	_client_start()


## Find World + clear pre-placed players (net mode spawns every player on join).
func _find_and_clear() -> bool:
	_world = _find_world()
	if _world == null:
		_fail("no World found")
		return false
	for eid in _player_like_ids():
		_world.despawn_entity(eid)
	return true


func _server_start() -> void:
	if not _find_and_clear():
		return
	_local_id = 1
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_started = true
	print("[net] SERVER started (dedicated, no player) ticks=%d snapshot_hz=%d"
		% [_ticks_target, int(_snapshot_hz)])


func _client_start() -> void:
	if not _find_and_clear():
		return
	_started = true
	print("[net] CLIENT started peer=%d (awaiting spawn from server)" % _local_id)


## Player-def ids (defs tagged `player`), sorted — the spawnable-character roster.
func _player_defs() -> Array:
	var out: Array = []
	for did in _world.defs:
		var d = _world.defs[did]
		var tags = (d as Dictionary).get("tags", []) if d is Dictionary else []
		if tags is Array and (tags as Array).has("player"):
			out.append(str(did))
	out.sort()
	return out


## Pre-placed PLAYER instance ids — cleared at start so net spawns every player
## on join. Only `player`-tagged (NPCs tagged `actor` but not `player` stay,
## server-simmed + replicated like any other dynamic entity).
func _player_like_ids() -> Array:
	var out: Array = []
	for id in _world.entities:
		var e = _world.entities[id]
		if e is Entity and (e as Entity).has_tag("player"):
			out.append(str(id))
	return out


## SERVER: spawn a joining peer's player, assign ownership, sync the full roster.
func _spawn_player_for_peer(id: int) -> void:
	var defs := _player_defs()
	if defs.is_empty():
		printerr("[net] no player-tagged defs to spawn")
		return
	var index := _actor_of_peer.size()  # join order → which def + spawn slot
	var def_id := str(defs[index % defs.size()])
	var eid := "netplayer_%d" % id
	var pos := _spawn_pos(index)
	_server_spawn(eid, def_id, pos)
	_actor_of_peer[id] = eid
	_player_def_of[eid] = def_id
	_player_pos_of[eid] = pos
	# Tell every client the new player exists; tell the joiner the existing roster
	# + which entity is THEIRS (camera + input ownership).
	_recv_spawn.rpc(eid, def_id, pos)
	for other in _player_def_of:
		if str(other) != eid:
			_recv_spawn.rpc_id(id, str(other), str(_player_def_of[other]), _player_pos_of[other])
	_recv_assign.rpc_id(id, eid)
	print("[net] spawned %s (%s) for peer %d at %s" % [eid, def_id, id, str(pos)])


func _despawn_player_for_peer(id: int) -> void:
	if not _actor_of_peer.has(id):
		return
	var eid := str(_actor_of_peer[id])
	_world.despawn_entity(eid)
	_actor_of_peer.erase(id)
	_player_def_of.erase(eid)
	_player_pos_of.erase(eid)
	_pending_input.erase(id)
	_recv_despawn.rpc(eid)
	print("[net] despawned %s (peer %d left)" % [eid, id])


func _server_spawn(eid: String, def_id: String, pos: Array) -> void:
	_world.spawn_instance(
		{"def": def_id, "id": eid, "position": pos, "state": {"position": pos, "facing": 0.0}}
	)


## Spawn slots — side by side near the authored spawn, offset by join index.
func _spawn_pos(index: int) -> Array:
	return [-5.0 + float(index) * 3.0, 6.2, 18.0]


# ============================================================
# RPC — client→server input, server→client state
# ============================================================


## CLIENT → SERVER: the client's current input. The server holds the latest per
## peer and injects it each sim tick (queue_input dedups per tick). Reliable: a
## dropped input on a held action just re-arrives next frame, but ordering keeps
## press/release coherent.
@rpc("any_peer", "call_remote", "reliable")
func _recv_input(actions: Array, facing: float) -> void:
	if _is_host and _started:
		_pending_input[multiplayer.get_remote_sender_id()] = {"actions": actions, "facing": facing}


## SERVER → CLIENTS: a player entity exists — create it locally (so snapshots can
## position it + the renderer shows it). Reliable: clients must not miss a spawn.
@rpc("authority", "call_remote", "reliable")
func _recv_spawn(eid: String, def_id: String, pos: Array) -> void:
	if _is_host or _world == null:
		return
	if not _world.entities.has(eid):
		_world.spawn_instance(
			{"def": def_id, "id": eid, "position": pos, "state": {"position": pos, "facing": 0.0}}
		)


## SERVER → one CLIENT: this entity is YOURS (camera follows it; input relays for it).
@rpc("authority", "call_remote", "reliable")
func _recv_assign(eid: String) -> void:
	if _is_host:
		return
	_local_actor = eid
	if _visual:
		Engine.set_meta("yume_local_follow_id", eid)


## SERVER → CLIENTS: a player left — remove it locally.
@rpc("authority", "call_remote", "reliable")
func _recv_despawn(eid: String) -> void:
	if _is_host or _world == null:
		return
	if _world.entities.has(eid):
		_world.despawn_entity(eid)


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
	# Dedicated server: it owns no player, so ALL movement comes from clients'
	# relayed input. Each client's input → its actor. Set facing FIRST (the shell's
	# movement is camera-relative, so the action direction depends on it), then
	# queue each pressed action (dedups per tick).
	for pid in _pending_input:
		var actor := str(_actor_of_peer.get(pid, ""))
		if actor == "" or not _world.entities.has(actor):
			continue
		var pin: Dictionary = _pending_input[pid]
		(_world.entities[actor] as Entity).set_state("facing", float(pin.get("facing", 0.0)))
		for act in pin.get("actions", []):
			if str(act) != "":
				_world.queue_input(str(act), {"actor": actor})
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
	# PURE server-auth: read this client's input (scripted action or real keyboard)
	# + the local mouse-look facing, send it to the server, and do NOT apply it
	# locally — the server computes the outcome and we render it (interpolated).
	var actions: Array = [_input_action] if _input_action != "" else _poll_local_actions()
	var facing := 0.0
	if _local_actor != "" and _world.entities.has(_local_actor):
		facing = float((_world.entities[_local_actor] as Entity).get_state("facing", 0.0))
	_recv_input.rpc(actions, facing)
	# Render every actor (incl. our own) from the server's authoritative snapshots.
	_render_interpolated()


## Currently-pressed actions from the game's own action lists (hold + press) —
## game-agnostic (reads World.input_actions_hold/press, no hardcoded names).
func _poll_local_actions() -> Array:
	var out: Array = []
	var hold = _world.get("input_actions_hold")
	if hold != null:
		for a in hold:
			if Input.is_action_pressed(str(a)):
				out.append(str(a))
	var press = _world.get("input_actions_press")
	if press != null:
		for a in press:
			if Input.is_action_just_pressed(str(a)):
				out.append(str(a))
	return out


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
		if not _world.entities.has(id):
			continue
		var e = _world.entities[id]
		if not (e is Entity):
			continue
		var a1: Array = snap1[id]
		var a0: Array = snap0.get(id, a1)
		if a1.size() < 3 or a0.size() < 3:
			continue
		# POSITION is server-authoritative for ALL actors (incl. the owned one —
		# pure server-auth, no client prediction).
		var pos := Vector3(
			lerpf(float(a0[0]), float(a1[0]), alpha),
			lerpf(float(a0[1]), float(a1[1]), alpha),
			lerpf(float(a0[2]), float(a1[2]), alpha),
		)
		(e as Entity).set_position(pos)
		# FACING: interpolate remotes; the OWNED actor keeps its LOCAL mouse-look
		# facing (camera_director set it this frame) so the camera stays responsive
		# even though movement is server-driven.
		if str(id) != _local_actor and a1.size() >= 4 and a0.size() >= 4:
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
	# Positions of every player/actor entity — the server's authoritative truth vs
	# the client's APPLIED state. Both run the same spawn-replicated roster, so
	# these must match (correctness check). Keyed by entity id (stable across peers).
	var actor_pos: Dictionary = {}
	if _world != null:
		for id in _world.entities:
			var e = _world.entities[id]
			if e is Entity and ((e as Entity).has_tag("player") or (e as Entity).has_tag("actor")):
				var p = (e as Entity).get_planar_position()
				actor_pos[str(id)] = [snappedf(p.x, 0.001), snappedf(p.y, 0.001)]
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
