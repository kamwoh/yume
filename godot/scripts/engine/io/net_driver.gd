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
## Generous: a dedicated server + N client windows on ONE machine all load the 3D
## scene at once (GPU/CPU contention), so the first connection can take a while.
## 60s keeps the server from giving up ("connect timeout (no peer)") before slow
## clients finish loading + connect. Empirical 2026-06-01.
const CONNECT_TIMEOUT_SEC := 60.0
const DEFAULT_SNAPSHOT_HZ := 20.0
const DEFAULT_INTERP_DELAY := 0.1  # render this far behind, lerping (absorbs jitter)
## ADR 0064 — default replication policy when a game ships no net.json: one group
## (actor-tagged) replicating position + facing. Matches the pre-0064 hardcode.
const DEFAULT_REPLICATE := [{"query": {"tags_all": ["actor"]}, "fields": ["position", "facing"]}]
## Orientation fields use angle-lerp (wrap-aware) instead of plain lerp.
const ANGLE_FIELDS := ["facing", "yaw", "pitch", "heading"]

var _active := false
var _is_host := false
var _join_ip := "127.0.0.1"
var _port := DEFAULT_PORT
var _input_action := ""
var _ticks_target := 600
var _out_path := ""
var _visual := false
var _snapshot_hz := DEFAULT_SNAPSHOT_HZ
var _interp_delay := DEFAULT_INTERP_DELAY
var _interp_enabled := true
var _replicate: Array = []  # ADR 0064 — replication groups [{query, fields}], from net.json

var _world = null
var _local_id := 0
var _actor_of_peer: Dictionary = {}  # peer_id -> controlled actor entity id (server)
var _player_def_of: Dictionary = {}  # entity id -> def id (server roster)
var _player_pos_of: Dictionary = {}  # entity id -> spawn pos (server roster)
var _local_actor := ""
var _started := false
var _done := false
var _cleared := false  # pre-placed players cleared at startup (net mode)
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
	if not _cleared:
		_load_net_cfg()
		for eid in _player_like_ids():
			_world.despawn_entity(eid)
		_cleared = true
	return true


## Clear pre-placed players the moment the scene has loaded (called every frame
## until done). Runs for BOTH server + client, with or without a connection, so a
## disconnected client ends up with an empty world rather than the authored pair.
func _try_clear_preplaced() -> void:
	var w = _find_world()
	if w == null:
		return
	var ents = w.get("entities")
	if not (ents is Dictionary) or (ents as Dictionary).is_empty():
		return  # scene not loaded yet
	_world = w
	_load_net_cfg()
	var ids := _player_like_ids()
	for eid in ids:
		w.despawn_entity(eid)
	_cleared = true
	print("[net] cleared %d pre-placed player(s) at startup — spawn-on-join only" % ids.size())


## ADR 0064 — load the per-game replication policy from data/<game>/net.json.
## Absent → the default (actor-tagged, position+facing, 20Hz, interpolated), i.e.
## the pre-0064 behavior. Server + client both load it so they agree on the wire.
func _load_net_cfg() -> void:
	_replicate = DEFAULT_REPLICATE.duplicate(true)
	var root := str(_world.get("data_root")).rstrip("/")
	var path := root + "/net.json"
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var data = JSON.parse_string(f.get_as_text())
			f.close()
			if data is Dictionary:
				var cfg: Dictionary = data
				if cfg.has("snapshot_hz"):
					_snapshot_hz = float(cfg["snapshot_hz"])
				var interp = cfg.get("interpolation", {})
				if interp is Dictionary:
					_interp_enabled = bool((interp as Dictionary).get("enabled", true))
					_interp_delay = float((interp as Dictionary).get("delay", DEFAULT_INTERP_DELAY))
				if cfg.get("replicate", null) is Array and not (cfg["replicate"] as Array).is_empty():
					_replicate = cfg["replicate"]
	if not _interp_enabled:
		_interp_delay = 0.0  # disabled → snap to newest (no render delay, no lerp)
	print(
		(
			"[net] replication: %d group(s), snapshot_hz=%d, interp=%s/%.2fs"
			% [_replicate.size(), int(_snapshot_hz), str(_interp_enabled), _interp_delay]
		)
	)


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
	print("[net] this window (peer %d) controls + follows %s" % [_local_id, eid])


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


## ADR 0064 — serialize state per the data-driven replication config: for each
## `replicate` group, every entity matching its `query` contributes its listed
## `fields`. Self-describing per entity: id -> {field: value}. Only the declared
## fields of matched (dynamic) entities travel; static props the clients already
## have from loading the scene aren't sent.
func _serialize_state() -> Dictionary:
	var out: Dictionary = {}
	var env: Dictionary = _world.scheduler.env if _world.scheduler != null else {}
	for group in _replicate:
		var spec: Dictionary = (group as Dictionary).get("query", {})
		var fields: Array = (group as Dictionary).get("fields", [])
		for id in _world.entities:
			var e = _world.entities[id]
			if not (e is Entity) or not QueryLib.matches(e as Entity, spec, env):
				continue
			var rec: Dictionary = out.get(str(id), {})
			for f in fields:
				rec[str(f)] = _serialize_field(e as Entity, str(f))
			out[str(id)] = rec
	return out


## Serialize ONE field: `position` → [x,y,z]; anything else → its state value
## (float / Vector2 / Vector3 / int / bool / string — Godot RPC sends it typed).
func _serialize_field(e: Entity, field: String):
	if field == "position":
		var p = e.get_position()
		if p is Vector3:
			return [snappedf(p.x, 0.001), snappedf(p.y, 0.001), snappedf(p.z, 0.001)]
		if p is Vector2:
			return [snappedf(p.x, 0.001), 0.0, snappedf(p.y, 0.001)]
		return [0.0, 0.0, 0.0]
	return e.get_state(field, 0.0)


## Apply a snapshot directly (no interpolation) — used for the final state at
## end-of-run. Generic over the configured fields.
func _apply_snapshot(snap: Dictionary) -> void:
	_last_snapshot = snap
	for id in snap:
		if not _world.entities.has(id):
			continue
		var e = _world.entities[id]
		if not (e is Entity) or not (snap[id] is Dictionary):
			continue
		for f in (snap[id] as Dictionary):
			_apply_field(e as Entity, str(f), (snap[id] as Dictionary)[f])


## Apply ONE field's value to an entity. `position` → set_position (drives the
## renderer + body); anything else → set_state.
func _apply_field(e: Entity, field: String, value) -> void:
	if field == "position" and value is Array and (value as Array).size() >= 3:
		e.set_position(Vector3(float(value[0]), float(value[1]), float(value[2])))
	else:
		e.set_state(field, value)


# ============================================================
# Per-frame loop
# ============================================================


func _process(delta: float) -> void:
	if not _active or _done:
		return
	# Clean dedicated-server model: clear authored (pre-placed) players as soon as
	# the scene loads — BEFORE/regardless of connecting — so every networked player
	# is server-spawned-on-join. A DISCONNECTED client then shows an EMPTY world
	# (obviously not connected) instead of the misleading pre-placed pair (both
	# defaulting to marken). Single-player (net inactive) never reaches here, so it
	# keeps its pre-placed character. (See ADR 0063 — exposed by the both-marken
	# diagnosis 2026-06-01.)
	if not _cleared:
		_try_clear_preplaced()
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
	var moving := false
	var hold = _world.get("input_actions_hold")
	if hold != null:
		for a in hold:
			if Input.is_action_pressed(str(a)):
				out.append(str(a))
				moving = true
	var press = _world.get("input_actions_press")
	if press != null:
		for a in press:
			if Input.is_action_just_pressed(str(a)):
				out.append(str(a))
	# Stop-on-idle: World._poll_input normally injects stop_x/stop_y when keys are
	# released, which zero the velocity. The client's World is gated (no _poll_input
	# under pure server-auth), so we relay an explicit `stop` when NO hold action is
	# pressed — else velocity_set/velocity_add_relative persists and the character
	# keeps moving after release. (lib_wasd `stop` rule = velocity_set x:0 y:0;
	# harmless no-op for games without it.) Empirical 2026-06-01: morwen ran forever.
	if not moving:
		out.append("stop")
	return out


## Render remote entities at (now - INTERP_DELAY) by lerping between the two
## buffered snapshots that bracket that time — smooth motion at render FPS from
## a 20Hz snapshot stream. Also derives planar velocity so walk/idle animation
## rules (which read state.velocity) fire on replicated movement.
func _render_interpolated() -> void:
	if _snap_buffer.is_empty():
		return
	var rt := _client_clock - _interp_delay
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


## Apply the interpolated snapshot to local entities (ADR 0064: generic over the
## configured fields). Each field lerps by type; the OWNED actor keeps its LOCAL
## `facing` (responsive mouse-look — pure server-auth still owns its POSITION).
func _apply_interp(snap0: Dictionary, snap1: Dictionary, alpha: float, dt: float) -> void:
	for id in snap1:
		if not _world.entities.has(id) or not (snap1[id] is Dictionary):
			continue
		var e = _world.entities[id]
		if not (e is Entity):
			continue
		var r1: Dictionary = snap1[id]
		var r0: Dictionary = snap0.get(id, r1)
		for f in r1:
			var fs := str(f)
			# Owned actor's facing stays local (camera look) — don't overwrite it.
			if fs == "facing" and str(id) == _local_actor:
				continue
			_apply_field(e as Entity, fs, _lerp_value(fs, r0.get(f, r1[f]), r1[f], alpha))
		# Planar velocity (XZ) from position delta → drives walk/idle animation.
		if dt > 0.0001 and r1.has("position") and (r1["position"] is Array):
			var p1: Array = r1["position"]
			var p0: Array = r0.get("position", p1)
			if p1.size() >= 3 and p0.size() >= 3:
				(e as Entity).set_state(
					"velocity",
					Vector2((float(p1[0]) - float(p0[0])) / dt, (float(p1[2]) - float(p0[2])) / dt),
				)


## Type-driven interpolation between two field values. Numbers + numeric arrays
## (e.g. position) lerp; orientation fields angle-lerp (wrap-aware); non-numeric
## (string/bool) snap to the newer value. No-op (returns newer) if interp disabled.
func _lerp_value(field: String, v0, v1, alpha: float):
	if not _interp_enabled:
		return v1
	if (v1 is float or v1 is int) and (v0 is float or v0 is int):
		if field in ANGLE_FIELDS:
			return lerp_angle(float(v0), float(v1), alpha)
		if field.ends_with("phase"):
			# 0..1 cyclic (e.g. anim_phase): take the short way around the wrap so
			# the walk cycle never briefly reverses at the 1→0 boundary.
			var d := float(v1) - float(v0)
			if d > 0.5:
				d -= 1.0
			elif d < -0.5:
				d += 1.0
			return fposmod(float(v0) + d * alpha, 1.0)
		return lerpf(float(v0), float(v1), alpha)
	if v1 is Array and v0 is Array and (v1 as Array).size() == (v0 as Array).size():
		var out: Array = []
		for i in range((v1 as Array).size()):
			out.append(lerpf(float(v0[i]), float(v1[i]), alpha))
		return out
	return v1  # non-numeric → snap


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
				# Include anim_phase (snapped) so the sync check covers replicated
				# animation state, not just position (ADR 0065).
				var ph := snappedf(float((e as Entity).get_state("anim_phase", 0.0)), 0.01)
				actor_pos[str(id)] = [snappedf(p.x, 0.001), snappedf(p.y, 0.001), ph]
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
