extends RefCounted
class_name LockstepCore

## ADR 0061 Phase 1 — transport-agnostic lockstep state machine.
##
## Multiplayer is a TRANSPORT problem once the engine is deterministic (ADR
## 0060): get every peer the same inputs, let each peer reproduce the same
## state. This class is the ENGINE side of that — the part that is NOT the
## transport: the per-tick input barrier, per-peer input injection, and the
## per-tick hash-exchange desync detector. It knows nothing about HOW inputs /
## hashes arrive (an in-memory test relay here in Phase 1; `ENetMultiplayerPeer`
## `@rpc` in Phase 2). A driver feeds it `submit_input` / `submit_hash` and
## calls `step` when the barrier is clear.
##
## Built on ADR 0060:
##   - input injection uses `scheduler.queue_input` — the same poll/queue seam
##     live / scripted / env input converges on (NOT synthesized InputEvents;
##     see ADR 0060 Phase 1 + ADR 0061 implementation note).
##   - the per-tick hash is `DeterminismHash.canonical(world)` (0060 Part 1);
##     the FIRST tick where peers disagree names the desync (and, via the
##     oracle's per-entity hashes, the divergent entity).
##
## Lockstep model (ADR 0061): replicate inputs, not state. Every peer runs this
## same loop; identical input logs ⇒ identical state ⇒ identical hashes. A
## hash mismatch is a determinism bug, surfaced precisely instead of as drift.

var local_peer_id: int = 0
var peer_ids: Array = []  # all peers incl. local, sorted ascending (deterministic order)
var actor_of_peer: Dictionary = {}  # peer_id -> actor entity id (which entity that peer controls)
var current_tick: int = 0

# Desync detection — the earliest tick at which submitted peer hashes disagree.
var desync_tick: int = -1
var desync_info: Dictionary = {}

var _input_inbox: Dictionary = {}  # tick -> {peer_id -> Array[action_string]}
var _hash_ledger: Dictionary = {}  # tick -> {peer_id -> hash_string}


## peer_ids: every participant (including local). actor_of_peer maps each peer
## to the entity id it controls (empty/absent → inputs queued without an actor
## binding, the single-actor case).
func configure(p_local_peer_id: int, p_peer_ids: Array, p_actor_of_peer: Dictionary = {}) -> void:
	local_peer_id = p_local_peer_id
	peer_ids = p_peer_ids.duplicate()
	peer_ids.sort()  # deterministic injection order across peers
	actor_of_peer = p_actor_of_peer.duplicate()
	current_tick = 0
	desync_tick = -1
	desync_info = {}
	_input_inbox.clear()
	_hash_ledger.clear()


# ============================================================
# TRANSPORT → CORE (a driver calls these as peer data arrives)
# ============================================================


## Record one peer's input batch for a tick. `batch` is a list of action
## strings (the same per-tick `{"actions":[...]}` shape ADR 0060's env uses).
func submit_input(peer_id: int, tick: int, batch: Array) -> void:
	if not _input_inbox.has(tick):
		_input_inbox[tick] = {}
	_input_inbox[tick][peer_id] = batch.duplicate()


## The lockstep barrier: true once EVERY peer has submitted an input batch for
## `tick`. A driver must not `step` past a tick until this returns true (the
## network analogue of ADR 0060's stdio blocking-read barrier).
func all_inputs_ready(tick: int) -> bool:
	var got: Dictionary = _input_inbox.get(tick, {})
	for pid in peer_ids:
		if not got.has(pid):
			return false
	return true


## Record a peer's canonical hash for a tick (the local hash is recorded
## automatically by `step`; remote hashes arrive via the transport). Updates
## the desync detector.
func submit_hash(peer_id: int, tick: int, hash: String) -> void:
	if not _hash_ledger.has(tick):
		_hash_ledger[tick] = {}
	_hash_ledger[tick][peer_id] = hash
	_check_desync(tick)


# ============================================================
# CORE → WORLD
# ============================================================


## Advance EXACTLY one tick. Injects every peer's batch to its actor (in sorted
## peer order, for deterministic queue order), advances the world one canonical
## tick, then records + returns {tick, hash} for the just-completed tick. Caller
## MUST have confirmed `all_inputs_ready(current_tick)`.
func step(world) -> Dictionary:
	var tick := current_tick
	var batches: Dictionary = _input_inbox.get(tick, {})
	for pid in peer_ids:
		var actor_id := str(actor_of_peer.get(pid, ""))
		var batch: Array = batches.get(pid, [])
		for action in batch:
			var ctx: Dictionary = {}
			if actor_id != "":
				ctx["actor"] = actor_id
			world.scheduler.queue_input(str(action), ctx)
	world.advance_one_tick()
	var h := str(DeterminismHash.canonical(world).get("hash", ""))
	submit_hash(local_peer_id, tick, h)
	current_tick += 1
	return {"tick": tick, "hash": h}


func has_desync() -> bool:
	return desync_tick >= 0


# ============================================================
# INTERNAL
# ============================================================


## A desync is the EARLIEST tick where two submitted hashes disagree. Hashes can
## arrive out of order, so we always keep the minimum divergent tick.
func _check_desync(tick: int) -> void:
	var hs: Dictionary = _hash_ledger.get(tick, {})
	if hs.size() < 2:
		return
	var ref_hash := ""
	var have_ref := false
	for pid in hs:
		if not have_ref:
			ref_hash = hs[pid]
			have_ref = true
		elif str(hs[pid]) != str(ref_hash):
			if desync_tick < 0 or tick < desync_tick:
				desync_tick = tick
				desync_info = {"tick": tick, "hashes": hs.duplicate()}
			return
