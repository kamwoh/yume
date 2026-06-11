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
##   --net-input=<action[,...]>  local peer's scripted input. A single action is
##                               held; a comma-list cycles (PATTERN_DWELL_SEC each)
##                               so the character oscillates in place.
##   --net-clients=<n>           server waits for n clients to join, then broadcasts
##                               GO (clients start capture + scripted input together)
##   --net-ticks=<n>             server runs n sim ticks, then finish + quit
##   --net-out=<path>            write result JSON (peer_id, role, actor_positions)
##   --net-visual                keep camera + renderer running (watch windows)
##   --net-snapshot-hz=<n>       state send rate (default 20; decoupled from 60Hz)

const DEFAULT_PORT := 7777
## Generous: a dedicated server + N client windows on ONE machine all load the 3D
## scene at once (GPU/CPU contention), so the first connection can take a while.
## Large enough to cover client connect-retries while the server loads. Empirical
## 2026-06-01.
const CONNECT_TIMEOUT_SEC := 120.0
## A client re-attempts the connection this many times (each ENet attempt ~5s)
## while the server is still loading a heavy scene, instead of failing instantly.
const MAX_CONNECT_RETRIES := 18
const DEFAULT_SNAPSHOT_HZ := 20.0
const DEFAULT_INTERP_DELAY := 0.1  # render this far behind, lerping (absorbs jitter)
## Demo/headless input pattern: when --net-input is a comma-list (e.g.
## move_north,move_south,move_east,move_west), the client cycles through it,
## holding each action this many SERVER TICKS. front/back + left/right with equal
## dwell cancel out → the character oscillates in place instead of walking off
## the map. A single-action --net-input is just a 1-cycle (sustained).
##
## Keyed to the SERVER tick (not each client's local clock) so every client's
## pattern advances on the ONE shared clock — both characters switch direction on
## the same tick → the side-by-side is genuinely synced. 42 ticks ≈ 0.7s @ 60Hz.
const PATTERN_DWELL_TICKS := 42
## Players spawn above the ground (safe-high) and FALL to it on join. Skip this
## long after GO before recording, so the replay never shows the sky-drop or the
## fall's transient horizontal drift (which whipped the body-yaw around). ADR 0066.
const RECORD_SETTLE_SEC := 1.5
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
var _input_pattern: Array = []  # scripted action cycle (comma-list from --net-input)
var _expected_clients := 1  # server waits for this many before broadcasting GO
var _go := false  # both/all clients spawned — start capture + scripted input
var _server_tick := 0  # CLIENT: latest authoritative tick from snapshots (shared clock)

# Record (SERVER): dump the authoritative per-tick state stream to a file, so the
# views can be RE-RENDERED offline in Movie-Maker mode (smooth 60fps regardless of
# GPU speed) — see ADR 0066. Recording starts at GO and runs _record_secs seconds.
var _record_path := ""
var _record_secs := 0.0
var _record_frames: Array = []   # [{tick, ents}] post-GO, deduped per tick
var _record_last_tick := -1
var _go_tick := 0                # server tick at GO (record window origin)

# Replay (single instance): drive entities from a recorded state file instead of
# the live wire, in Movie-Maker mode. No ENet. One run per camera view.
var _replay := false
var _replay_path := ""
var _replay_follow := ""
var _replay_frames: Array = []
var _replay_roster: Array = []
var _replay_tick_hz := 60.0
var _replay_first_tick := 0
var _replay_last_tick := 0
var _replay_t := 0.0
var _replay_spawned := false
var _replay_yaw: Dictionary = {}  # per-entity smoothed body yaw (turn toward motion)
const REPLAY_TURN_RATE := 0.15  # per-frame angle-lerp toward motion dir (~90° in ~0.25s @60fps)
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
var _player_facing_of: Dictionary = {}  # entity id -> spawn facing (server roster)
var _local_actor := ""
var _started := false
var _done := false
var _cleared := false  # pre-placed players cleared at startup (net mode)
var _connect_retries := 0  # CLIENT: connection_failed retry count
var _elapsed := 0.0
var _snap_accum := 0.0
var _pending_input: Dictionary = {}  # SERVER: peer_id -> latest action string from that client
var _last_snapshot: Dictionary = {}  # CLIENT: last applied snapshot (for the result)
var _client_clock := 0.0  # CLIENT: monotonic local time, stamps snapshot arrivals
var _snap_buffer: Array = []  # CLIENT: [{t, snap}] recent snapshots for interpolation


func _ready() -> void:
	# Accept BOTH `--flag=value` AND `--flag value` (space-separated) forms.
	# Empirical 2026-06-01: net_video.py launched the server with `--net-port`
	# and `7862` as two separate argv; the old parser only matched `--net-port=`
	# (with `=`), so the server silently bound DEFAULT_PORT (7777) while clients
	# dialed :7862 → permanent connection_failed (the long-standing "clients
	# never connect" blocker). A space-tolerant parser makes the bug class
	# impossible regardless of how a launcher spells the flag.
	var argv := OS.get_cmdline_user_args()
	var i := 0
	while i < argv.size():
		var s := str(argv[i])
		# Resolve the value for a `--name=value` OR `--name value` flag. For the
		# space form, peek argv[i+1] and bump the cursor past it.
		var val := ""
		var eq := s.find("=")
		var name := s.substr(0, eq) if eq >= 0 else s
		if eq >= 0:
			val = s.substr(eq + 1)
		elif i + 1 < argv.size():
			val = str(argv[i + 1])  # candidate for the space form; consumed below
		if s == "--net-host":
			_active = true
			_is_host = true
		elif name == "--net-join":
			_active = true
			_is_host = false
			if eq < 0:
				i += 1
			if val.contains(":"):
				_join_ip = val.get_slice(":", 0)
				_port = int(val.get_slice(":", 1))
			else:
				_join_ip = val
		elif name == "--net-port":
			if eq < 0:
				i += 1
			_port = int(val)
		elif name == "--net-input":
			if eq < 0:
				i += 1
			_input_action = val
			for a in val.split(","):
				if a.strip_edges() != "":
					_input_pattern.append(a.strip_edges())
		elif name == "--net-clients":
			if eq < 0:
				i += 1
			_expected_clients = maxi(1, int(val))
		elif name == "--net-record":
			if eq < 0:
				i += 1
			_record_path = val
		elif name == "--net-record-secs":
			if eq < 0:
				i += 1
			_record_secs = float(val)
		elif name == "--replay":
			if eq < 0:
				i += 1
			_replay_path = val
			_replay = true
		elif name == "--replay-follow":
			if eq < 0:
				i += 1
			_replay_follow = val
		elif name == "--net-ticks":
			if eq < 0:
				i += 1
			_ticks_target = int(val)
		elif name == "--net-out":
			if eq < 0:
				i += 1
			_out_path = val
		elif s == "--net-visual":
			_visual = true
		elif name == "--net-snapshot-hz":
			if eq < 0:
				i += 1
			_snapshot_hz = float(val)
		elif name.begins_with("--net-"):
			# Gate (2026-06-01): an unrecognized --net-* flag would otherwise be
			# silently ignored — the exact failure mode that hid the port-parse
			# bug for so long. Make it LOUD so a future flag/typo can't masquerade
			# as a wrong default.
			push_warning("[net] unrecognized arg '%s' — IGNORED (typo or wrong form?)" % s)
		i += 1
	# Replay mode: no ENet at all. Gate the World sim (we drive entities from the
	# recorded file) but KEEP the renderer + directors (visual seam) so the camera
	# follows + meshes render. Movie-Maker mode (--write-movie, passed to Godot
	# directly) renders every frame at a fixed fps → smooth regardless of GPU speed.
	if _replay:
		Engine.set_meta("yume_lockstep_visual", true)
		Engine.set_meta("yume_external_tick_driver", true)
		if _replay_follow != "":
			Engine.set_meta("yume_local_follow_id", _replay_follow)
		_load_replay()
		return
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
		# Tell capture_runner to hold its frame-sequence until the server's GO
		# (all clients spawned), so the video never records the pre-spawn /
		# floating / mid-join state. Cleared-meaning default is "no wait".
		Engine.set_meta("yume_net_await_go", true)
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
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(func(): _fail("server_disconnected"))
	if not _is_host:
		multiplayer.connected_to_server.connect(_on_connected_to_server)


## A client's first connection attempt fails (connection_failed) if the server is
## still loading a heavy 3D scene (its main thread can't pump ENet yet). Godot
## doesn't retry, so RETRY here — re-create the client peer — until the server is
## up or we exhaust retries. This is what makes a windowed video record reliably
## (clients keep trying through the server's load). Each ENet attempt ~5s, so the
## retries span the load. (Server never fires connection_failed.)
func _on_connection_failed() -> void:
	if _is_host:
		return
	_connect_retries += 1
	if _connect_retries > MAX_CONNECT_RETRIES:
		_fail("connection_failed after %d retries" % MAX_CONNECT_RETRIES)
		return
	print("[net] connect attempt %d failed — retrying (server may still be loading)" % _connect_retries)
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(_join_ip, _port) != OK:
		_fail("ENet create_client retry failed")
		return
	multiplayer.multiplayer_peer = peer


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
	# Once every expected client has joined (and thus spawned its player), tell
	# everyone to GO: clients start their capture sequence + scripted input at
	# the SAME moment, so the recording shows synced in-place motion from frame 0
	# rather than whatever each client was doing mid-join. Spawn RPCs above are
	# reliable + ordered, so each client has its netplayer before GO arrives.
	if not _go and _actor_of_peer.size() >= _expected_clients:
		_go = true
		_recv_go.rpc()
		print("[net] all %d client(s) spawned — GO (start capture + input)" % _expected_clients)


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
	# Generic sim-visible GO gate (2026-06-10): games that must hold their
	# match/race until every client has joined gate rules on `world.net_go`
	# (solo play defaults it to 1 in world/state.json; the net server forces
	# 0 here, then 1 at GO). Sim-side mirror of the yume_net_go Engine meta.
	if _is_host:
		var ws0 = _world.get("world_state")
		if ws0 is Dictionary:
			ws0["net_go"] = 0



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
	var facing := _spawn_facing(index)  # face the group center → players look at each other
	_server_spawn(eid, def_id, pos, facing)
	_actor_of_peer[id] = eid
	_player_def_of[eid] = def_id
	_player_pos_of[eid] = pos
	_player_facing_of[eid] = facing
	# Tell every client the new player exists; tell the joiner the existing roster
	# + which entity is THEIRS (camera + input ownership).
	_recv_spawn.rpc(eid, def_id, pos, facing)
	for other in _player_def_of:
		if str(other) != eid:
			_recv_spawn.rpc_id(id, str(other), str(_player_def_of[other]),
				_player_pos_of[other], float(_player_facing_of.get(other, 0.0)))
	_recv_assign.rpc_id(id, eid)
	print("[net] spawned %s (%s) for peer %d at %s facing=%.2f" % [eid, def_id, id, str(pos), facing])


func _despawn_player_for_peer(id: int) -> void:
	if not _actor_of_peer.has(id):
		return
	var eid := str(_actor_of_peer[id])
	_world.despawn_entity(eid)
	_actor_of_peer.erase(id)
	_player_def_of.erase(eid)
	_player_pos_of.erase(eid)
	_player_facing_of.erase(eid)
	_pending_input.erase(id)
	_recv_despawn.rpc(eid)
	print("[net] despawned %s (peer %d left)" % [eid, id])


func _server_spawn(eid: String, def_id: String, pos: Array, facing: float = 0.0) -> void:
	_world.spawn_instance(
		{"def": def_id, "id": eid, "position": pos, "state": {"position": pos, "facing": facing}}
	)


## Spawn slots — side by side near the authored spawn, offset by join index.
func _spawn_pos(index: int) -> Array:
	return [-5.0 + float(index) * 3.0, 6.2, 18.0]


## Initial facing (radians, Y-rotation; 0 = -Z/north) so spawned players look at
## the group's X-center — with two side-by-side players, they face each other.
## +X (east) = -PI/2, -X (west) = +PI/2 (Godot Y-rotation is CCW from above).
func _spawn_facing(index: int) -> float:
	var n := maxi(_expected_clients, index + 1)
	var my_x := float(_spawn_pos(index)[0])
	var sum := 0.0
	for k in range(n):
		sum += float(_spawn_pos(k)[0])
	var center_x := sum / float(n)
	if my_x < center_x:
		return -PI / 2.0
	if my_x > center_x:
		return PI / 2.0
	return 0.0


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
func _recv_spawn(eid: String, def_id: String, pos: Array, facing: float = 0.0) -> void:
	if _is_host:
		return
	# Ensure World is resolved — the spawn RPC can arrive before _client_start has
	# cached _world (RPC vs connected_to_server race); without this the spawn was
	# silently dropped -> no netplayer -> camera had nothing to follow (oblique
	# default). Empirical 2026-06-01.
	if _world == null:
		_world = _find_world()
	if _world == null:
		return
	if not _world.entities.has(eid):
		_world.spawn_instance(
			{"def": def_id, "id": eid, "position": pos, "state": {"position": pos, "facing": facing}}
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


## SERVER → ALL (incl. self): every expected client has joined + spawned. Clients
## start their capture sequence + scripted input pattern from this instant, so the
## side-by-side recording is synchronized and in-place (not mid-join motion).
@rpc("authority", "call_local", "reliable")
func _recv_go() -> void:
	_go = true
	Engine.set_meta("yume_net_go", true)
	# Sim-visible GO (see _try_clear_preplaced). Host only — it owns the sim.
	if _is_host and _world != null:
		var wsg = _world.get("world_state")
		if wsg is Dictionary:
			wsg["net_go"] = 1
	if not _is_host:
		print("[net] GO received (all spawned) — starting capture + input pattern")


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
func _recv_snapshot(snap: Dictionary, tick: int = 0) -> void:
	if not _is_host and _started:
		# Phase 2: buffer with arrival time; _render_interpolated applies it
		# INTERP_DELAY behind, lerping. (Phase 1 applied directly → stepping.)
		# `tick` is the server's authoritative tick for this snapshot — the shared
		# clock that drives the scripted patrol + cross-client frame pairing.
		_snap_buffer.append({"t": _client_clock, "snap": snap, "tick": tick})
		_last_snapshot = snap
		_server_tick = tick


## SERVER → CLIENT: final authoritative snapshot + end-of-run. Reliable so the
## client applies the exact final state before reporting (Phase 1 correctness
## check: client's applied positions must equal the server's).
@rpc("authority", "call_remote", "reliable")
func _recv_done(snap: Dictionary, tick: int = 0) -> void:
	if not _is_host and not _done:
		_server_tick = tick
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
	if _replay:
		if not _done:
			_replay_process(delta)
		return
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
		_recv_snapshot.rpc(_serialize_state(), int(_world.get("_tick_count")))
	# Record the authoritative state stream (post-GO, one frame per sim tick) so the
	# views can be re-rendered offline + smooth (ADR 0066). Finish after the window.
	if _record_path != "" and _go:
		var tk := int(_world.get("_tick_count"))
		if _go_tick == 0:
			_go_tick = tk
		var since := tk - _go_tick
		var settle := int(RECORD_SETTLE_SEC / _tick_seconds())
		if since < settle:
			return  # let the just-spawned players fall + settle (no sky-drop in the video)
		if tk != _record_last_tick:
			_record_last_tick = tk
			_record_frames.append({"tick": tk, "ents": _serialize_state()})
		if _record_secs > 0.0 and (since - settle) >= int(_record_secs / _tick_seconds()):
			_finish()
			return
	# Finish when the authoritative sim reaches the target tick count.
	if int(_world.get("_tick_count")) >= _ticks_target:
		# final authoritative state + tick to clients
		_recv_done.rpc(_serialize_state(), int(_world.get("_tick_count")))
		_finish()


func _client_process(delta: float) -> void:
	_client_clock += delta
	# PURE server-auth: read this client's input (scripted action or real keyboard)
	# + the local mouse-look facing, send it to the server, and do NOT apply it
	# locally — the server computes the outcome and we render it (interpolated).
	var actions: Array = _client_actions(delta)
	var facing := 0.0
	if _local_actor != "" and _world.entities.has(_local_actor):
		facing = float((_world.entities[_local_actor] as Entity).get_state("facing", 0.0))
	_recv_input.rpc(actions, facing)
	# Render every actor (incl. our own) from the server's authoritative snapshots.
	_render_interpolated()


## What this client sends the server this frame.
##   - before GO: "stop" (hold position at spawn until all clients have joined),
##   - scripted pattern (--net-input comma-list): cycle a direction per dwell so
##     the character oscillates in place; matching patterns across clients make
##     the side-by-side obviously synced,
##   - no pattern (interactive play): the real keyboard.
func _client_actions(_delta: float) -> Array:
	if not _go:
		return ["stop"]
	if _input_pattern.is_empty():
		return _poll_local_actions()
	# Keyed to the SHARED server tick (not a per-client clock) so every client's
	# pattern advances in lockstep → both characters switch direction on the same
	# tick. This is what makes the two windows synchronized.
	var idx := int(_server_tick / PATTERN_DWELL_TICKS) % _input_pattern.size()
	return [str(_input_pattern[idx])]


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
	# Publish the server tick this frame actually SHOWS (interpolated between the
	# two bracketing snapshots). capture_runner records it per frame; net_video
	# pairs the two clients' frames by this tick → the side-by-side shows the same
	# authoritative moment on both halves regardless of each client's render fps or
	# capture-start jitter.
	var shown_tick := int(round(lerp(float(s0.get("tick", 0)), float(s1.get("tick", 0)), alpha)))
	Engine.set_meta("yume_net_render_tick", shown_tick)
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


# ============================================================
# Record (server) + Replay-render (offline, Movie-Maker mode) — ADR 0066
# ============================================================


func _tick_seconds() -> float:
	var ts := 0.0167
	if _world != null:
		var v = _world.get("tick_seconds")
		if v != null and float(v) > 0.0:
			ts = float(v)
	return ts


func _tick_seconds_to_hz() -> float:
	return 1.0 / _tick_seconds()


## Roster the offline replay needs to spawn the dynamic players (def + spawn pose).
func _record_roster() -> Array:
	var out: Array = []
	for eid in _player_def_of:
		out.append({
			"id": str(eid),
			"def": str(_player_def_of[eid]),
			"pos": _player_pos_of.get(eid, [0, 0, 0]),
			"facing": float(_player_facing_of.get(eid, 0.0)),
		})
	return out


## REPLAY: load the recorded state file.
func _load_replay() -> void:
	if not FileAccess.file_exists(_replay_path):
		printerr("[net] replay file not found: %s" % _replay_path)
		return
	var f := FileAccess.open(_replay_path, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if not (data is Dictionary):
		printerr("[net] replay file malformed")
		return
	var d: Dictionary = data
	_replay_tick_hz = float(d.get("tick_hz", 60.0))
	_replay_roster = d.get("roster", [])
	_replay_frames = d.get("frames", [])
	if _replay_frames.size() > 0:
		_replay_first_tick = int((_replay_frames[0] as Dictionary).get("tick", 0))
		_replay_last_tick = int((_replay_frames[_replay_frames.size() - 1] as Dictionary).get("tick", 0))
	print("[net] replay loaded: %d frames, ticks %d..%d, follow=%s"
		% [_replay_frames.size(), _replay_first_tick, _replay_last_tick, _replay_follow])


## REPLAY: spawn the recorded roster once the World is up (clears any pre-placed).
func _replay_spawn() -> void:
	if not _cleared:
		_try_clear_preplaced()  # finds + caches _world, clears pre-placed players
	if not _cleared or _world == null:
		return  # world not loaded yet — try again next frame
	var first_ents: Dictionary = {}
	if not _replay_frames.is_empty():
		first_ents = (_replay_frames[0] as Dictionary).get("ents", {})
	for r in _replay_roster:
		var rd: Dictionary = r
		var eid := str(rd.get("id", ""))
		if eid == "" or _world.entities.has(eid):
			continue
		# Spawn at the FIRST RECORDED (already-landed) position, not the high server
		# spawn pos — so the camera snaps behind a grounded player with no swoop.
		var pos = rd.get("pos", [0, 0, 0])
		if first_ents.has(eid) and (first_ents[eid] as Dictionary).has("position"):
			pos = (first_ents[eid] as Dictionary)["position"]
		_world.spawn_instance({
			"def": str(rd.get("def", "")), "id": eid, "position": pos,
			"state": {"position": pos, "facing": float(rd.get("facing", 0.0))},
		})
		_replay_yaw[eid] = float(rd.get("facing", 0.0))  # seed body yaw from spawn facing
	_replay_spawned = true
	# Apply the FIRST recorded frame immediately so frame 0 already has the correct
	# pose/facing (not the roster default) — minimizes the spawn-frame T-pose / facing
	# pop. (net_video also drops the first few frames while the AnimationPlayer seeks.)
	if not _replay_frames.is_empty():
		var e0: Dictionary = (_replay_frames[0] as Dictionary).get("ents", {})
		_apply_replay_frame(e0, e0, 1.0 / _replay_tick_hz)  # prev=self → zero velocity
	print("[net] replay spawned %d entities" % _replay_roster.size())


## REPLAY per-frame: advance the recorded timeline by real (Movie-Maker fixed) dt,
## apply the nearest recorded frame's state. Movie mode renders every frame at a
## fixed fps, so the output is smooth no matter how slowly the GPU actually draws.
func _replay_process(delta: float) -> void:
	if _replay_frames.is_empty():
		_done = true
		get_tree().quit(0)
		return
	if not _replay_spawned:
		_replay_spawn()
		return  # spawn this frame; start applying next
	_replay_t += delta
	var target := _replay_first_tick + int(round(_replay_t * _replay_tick_hz))
	if target > _replay_last_tick:
		_done = true
		get_tree().quit(0)
		return
	# Nearest recorded frame INDEX to target tick (frames are tick-sorted).
	var best_i := 0
	var best_d: int = abs(int((_replay_frames[0] as Dictionary).get("tick", 0)) - target)
	for i in range(_replay_frames.size()):
		var d: int = abs(int((_replay_frames[i] as Dictionary).get("tick", 0)) - target)
		if d < best_d:
			best_d = d
			best_i = i
	# Velocity comes from the recorded NEIGHBOR tick (stable), NOT the movie-frame
	# delta — at 60fps movie vs ~60Hz record, frames alias onto duplicate ticks and
	# the per-movie-frame delta flickers 0/burst, which jittered both the body turn
	# and the walk/idle animation.
	var ents: Dictionary = (_replay_frames[best_i] as Dictionary).get("ents", {})
	var prev: Dictionary = (_replay_frames[maxi(0, best_i - 1)] as Dictionary).get("ents", {})
	_apply_replay_frame(ents, prev, 1.0 / _replay_tick_hz)


## Apply a recorded frame's ents AND derive planar velocity from the previous
## applied frame's positions — exactly what _apply_interp does for the live client,
## so the walk/idle animation state machine fires (without velocity it stays idle
## while anim_phase advances → the laggy/wrong animation). dt = movie frame delta.
func _apply_replay_frame(ents: Dictionary, prev: Dictionary, tick_dt: float) -> void:
	for id in ents:
		if not _world.entities.has(id) or not (ents[id] is Dictionary):
			continue
		var e = _world.entities[id]
		if not (e is Entity):
			continue
		var r: Dictionary = ents[id]
		for f in r:
			_apply_field(e as Entity, str(f), r[f])
		# Velocity from the recorded neighbor tick (stable, no movie-frame aliasing).
		if tick_dt > 0.0001 and r.has("position") and r["position"] is Array:
			var p1: Array = r["position"]
			var p0: Array = (prev.get(id, r) as Dictionary).get("position", r["position"])
			if p1.size() >= 3 and (p0 as Array).size() >= 3:
				var vx := (float(p1[0]) - float(p0[0])) / tick_dt
				var vz := (float(p1[2]) - float(p0[2])) / tick_dt
				(e as Entity).set_state("velocity", Vector2(vx, vz))
				# Body yaw: RECORDED TRUTH WINS. If the snapshot replicates `yaw`,
				# the server's authored body yaw was already applied above — never
				# re-derive it from motion. Empirical 2026-06-11 (autorace): this
				# override stomped the cars' recorded yaw every frame with a
				# MIRRORED heading; replay-only wrong while solo + live clients
				# were correct. Turn-toward-motion is a FALLBACK for entities
				# whose replicate set lacks yaw (the position+facing humanoid
				# default), so their bodies still face where they walk.
				if not r.has("yaw"):
					# Chirality: rotation.y = yaw makes mesh-forward
					# (-sin yaw, -cos yaw), so facing motion (vx, vz) means
					# yaw = atan2(-vx, -vz). atan2(vx, -vz) is the MIRROR —
					# latent on symmetric humanoids, fatal on cars.
					var cur := float(_replay_yaw.get(id, float((e as Entity).get_state("facing", 0.0))))
					if vx * vx + vz * vz > 0.04:  # |v| > 0.2 → moving
						cur = lerp_angle(cur, atan2(-vx, -vz), REPLAY_TURN_RATE)
						_replay_yaw[id] = cur
					(e as Entity).set_state("yaw", cur)


func _finish() -> void:
	if _done:
		return
	_done = true
	# Write the recorded authoritative state stream (server, --net-record). The
	# offline replay renders each camera view from this in Movie-Maker mode.
	if _record_path != "" and _is_host:
		var rec := {
			"tick_hz": _tick_seconds_to_hz(),
			"roster": _record_roster(),
			"frames": _record_frames,
		}
		var rf := FileAccess.open(_record_path, FileAccess.WRITE)
		if rf != null:
			rf.store_string(JSON.stringify(rec))
			rf.close()
			print("[net] recorded %d frames (%d entities) -> %s"
				% [_record_frames.size(), _record_roster().size(), _record_path])
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
