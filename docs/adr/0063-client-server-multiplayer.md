# ADR 0063 — Client-server multiplayer (authoritative + state replication + prediction)

_Date: 2026-06-01_
_Status: accepted_

## Context

ADR 0061 built **strict lockstep** (input-replication, P2P, deterministic). It
is correct for paced/deterministic genres (RTS, sim, turn-based), and it works
(byte-identical, IN SYNC). But the target genre here is **twitch action**,
networked (not localhost-only), generic enough to run on tiny_village-like 3D
scenes. Lockstep is the wrong model for that, for two compounding reasons:

1. **Input latency is fundamental to lockstep.** A peer advances tick N only
   once *every* peer's input for N has arrived → it always runs at the *slowest*
   peer's latency. Input-delay buffering (added 2026-05-31) hides jitter but
   *adds* local input lag (your press takes effect `INPUT_DELAY` ticks later).
   Invisible for sim; unacceptable for twitch.
2. **Rollback (the twitch fix for lockstep) needs FULL determinism, including
   physics.** Godot's 3D `PhysicsServer`/`move_and_slide` is **not** cross-machine
   deterministic. Yume only achieved determinism via *pure integration*
   (`tick_headless`, no real collision). A twitch 3D game with collision would
   need a custom deterministic physics engine — out of scope.

The genre + the Godot-physics reality both point at the industry-standard twitch
model: **authoritative client-server with client-side prediction and remote
interpolation** (Quake/Source/Overwatch lineage). It needs **no cross-machine
determinism** — the server is the single source of truth — which sidesteps the
Godot-physics wall entirely. Per **ADR 0021 (expose, don't reimplement)**, Godot
already ships the transport layer for this (`MultiplayerAPI`,
`ENetMultiplayerPeer`, `@rpc`, `set_multiplayer_authority`).

This is also where the "shared scene vs player-specific entity" question (raised
2026-06-01) becomes architecturally real — see the entity model below.

## Decision

Add a **client-server** multiplayer strategy as a sibling to ADR 0061's lockstep,
under the same pluggable `io/` driver seam (the multiplayer *model* stays
swappable; the engine core stays model-agnostic).

**Topology.** One peer (a player-host or a dedicated process) is the
**authoritative server**: it runs the full Yume sim (`World` ticks normally).
Other peers are **clients**: they do NOT run the authoritative sim — they apply
replicated state, render it, and predict their own player.

**Transport — expose Godot (ADR 0021).** Reuse Godot's `MultiplayerAPI` +
`ENetMultiplayerPeer` + `@rpc` + authority (the same stack ADR 0061's
`lockstep_driver` already uses). We expose Godot's networking; we do not
reimplement sockets.

**What is replicated: STATE, not inputs** (the opposite of lockstep). The server
serializes entity state and sends snapshots/diffs to clients at a network rate
(e.g. 20–30 Hz, decoupled from the 60 Hz sim tick). Reuse:
- ADR 0060 `DeterminismHash.canonical` serialization shape for the snapshot
  format (already a stable, ordered entity-state encoding).
- ADR 0010 save/load (`FileAccess`+JSON snapshot machinery) for apply-state.

> **Why NOT Godot's `MultiplayerSynchronizer`?** It replicates *Node exported
> properties*. Yume's sim state lives in **entity dictionaries**, and rules
> operate on those dicts — forcing state into synced node properties would split
> the source of truth. So we replicate dict-state via RPC snapshot/diff and still
> expose Godot's `MultiplayerAPI`/RPC/authority for the transport. (A future game
> that is genuinely node-state-first could use `MultiplayerSynchronizer` directly;
> that's a per-game choice, not the engine default.)

**The three-layer entity model** (answers the "shared vs player-specific" design
question directly):

| Layer | Owner | Replication | Yume mechanism |
|---|---|---|---|
| **Authoritative / shared** | server | server → all clients (snapshot/diff) | all entities; server's `World` is canonical |
| **Owned / predicted** | local client | client runs movement rules for ITS actor immediately, reconciles on snapshot | per-peer ownership (`actor_of_peer`, ADR 0061) |
| **Remote / interpolated** | other clients | rendered by interpolating between received snapshots | presentation-only (no sim writes) |

The firewall is the same as lockstep's canonical hash: **authoritative state is
shared; prediction + interpolation are per-client presentation that never become
the source of truth** (the server's next snapshot always wins).

**Client-side prediction** (twitch responsiveness). On input, the client runs the
movement rules for its **owned** actor *locally and immediately* (no server
round-trip), using the ADR 0060 input path. When the server snapshot arrives, the
client reconciles: if the server disagrees beyond a threshold, snap/correct (and
optionally replay buffered inputs since that snapshot). The local player feels
zero-latency; the server stays authoritative.

**Remote interpolation.** Remote entities are rendered by interpolating between
the two most recently received server snapshots (a small render-time buffer ~100
ms), so they move smoothly despite jitter and the sub-tick send rate.

**Per-peer ownership + camera** (already built in ADR 0061 follow-up): the
`actor_of_peer` map routes ownership; `yume_local_follow_id` makes each client's
camera follow its owned actor. Both carry over unchanged — they are exactly the
"player-specific" pointer + presentation layer this model needs.

**Engine seam.** ADR 0061 introduced `yume_external_tick_driver` (World stops
auto-ticking; a driver owns advancement). Client-server extends the seam with a
**client mode**: on a client, `World` does not run the authoritative sim — it
applies remote snapshots + runs *prediction only* for the owned actor. The server
runs `World` normally. Both are sibling drivers in `io/` (e.g.
`netserver_driver.gd`, `netclient_driver.gd`), keeping the engine core
model-agnostic (lockstep, client-server, and future models all plug in here).

## Consequences

**Enables:**
- Twitch multiplayer over real networks (latency hidden by prediction +
  interpolation, not eliminated by determinism).
- Works with Godot's 3D physics as-is — **no cross-machine determinism required**
  (the server runs `move_and_slide`; clients render/predict). This is the
  decisive win over rollback for 3D collision games.
- Cheat resistance (server authoritative) and scaling (more clients, dedicated
  server) that P2P lockstep/rollback can't offer.

**Costs / what it precludes:**
- **More bandwidth** than lockstep (state ≫ inputs). Mitigated by diff/delta
  compression + interest management (later phase).
- **Server CPU** runs the authoritative sim for everyone.
- **New engine infra**: client-mode `World` (apply-state instead of simulate),
  snapshot/diff serialization + send-rate scheduler, client prediction +
  reconciliation, remote interpolation buffer. Larger than ADR 0061's
  driver-only delta.
- Determinism is no longer *required* for correctness — but the deterministic
  sim (ADR 0060) is still valuable (reconciliation, replay, the snapshot format)
  and lockstep (ADR 0061) remains the right model for deterministic genres.

**Invariants preserved:**
- Content stays shared JSON (Invariant #1). Netcode is engine `io/` mechanism;
  the only authoring surface is tagging controllable actors (and optionally a
  per-entity "networked" hint). No per-instance content files.
- Pluggable-model seam (ADR 0061) holds: client-server is a sibling driver, not a
  core rewrite.

## Alternatives considered

- **Strict lockstep (ADR 0061).** Wrong for twitch (input lag + slowest-peer
  gating). Kept as the deterministic-genre strategy and the deterministic-sim
  substrate; not removed.
- **Rollback / GGPO (ADR 0061 Phase 4).** Zero local input lag, P2P, no server —
  but requires full determinism *including physics*. Godot 3D collision isn't
  deterministic, so this would force a custom deterministic physics engine.
  Viable only for pure-integration movement; rejected for collision-rich twitch
  3D.
- **Godot `MultiplayerSynchronizer` (node-property replication).** Doesn't fit
  Yume's dict-state sim cleanly (splits the source of truth). We expose Godot's
  transport/RPC/authority instead and replicate dict-state ourselves.

## Phasing

1. **Transport + authority (correctness, no smoothing). — DONE 2026-06-01.**
   Server runs the sim; client connects; server RPCs state snapshots at
   `--net-snapshot-hz` (default 20); client applies + renders. Laggy (no
   prediction/interp) but correct. `io/net_driver.gd` (autoload, active only on
   `--net-host`/`--net-join`): the client sets `yume_external_tick_driver` (no
   local sim) + applies snapshots via `Entity.set_position`/`set_state`; the
   server runs `World` normally and broadcasts `actor`-tagged entity state.
   Per-window camera + ownership reuse ADR 0061's `actor_of_peer` +
   `yume_local_follow_id`. Verified: `run_linux.sh net demo_tiny_village 300` →
   **REPLICATED ✓**, client's applied positions byte-equal the server's — and the
   two actors moved DIFFERENT distances under the server's `move_and_slide`
   collision, confirming no cross-machine determinism is needed.
2. **Remote interpolation. — DONE 2026-06-01.** The client buffers snapshots and
   renders remotes at `now - INTERP_DELAY` (0.1s), lerping position + facing
   between the two bracketing snapshots, so motion is smooth at render FPS from a
   20Hz stream. Derives planar velocity from the lerp so walk/idle animation
   rules fire on replicated movement. (`net_driver._render_interpolated`.)
3. **Client-side prediction — built then REMOVED (user choice 2026-06-01).**
   Prediction + reconciliation were implemented (client sims its own actor for
   instant response), but the user chose **pure server-authoritative**: only the
   server computes; the client sends input and renders the server's interpolated
   state (incl. its own character). The reconciliation blend toward the
   time-delayed server position also felt draggy. So the client no longer
   simulates — `yume_external_tick_driver` gates its World; it relays input +
   mouse-look facing and renders. Trade: the client's own character has
   round-trip input latency (accepted for simplicity + a single source of truth);
   only the camera LOOK stays local. The "owned/predicted" row of the entity
   model above is now "owned = server-authoritative (no prediction)". Prediction
   remains available to re-enable per-game if a twitch title needs it.
4. **Game integration — dedicated server + spawn-on-join. — DONE 2026-06-01.**
   The host is a **dedicated server with no player of its own** (fairness: every
   player is a client with equal latency). Players are **spawned on join** (not
   pre-placed): on connect the server `spawn_instance`s a player from a
   `player`-tagged def, assigns ownership, and replicates the spawn to all clients
   (`_recv_spawn`) + tells the joiner which entity is theirs (`_recv_assign`);
   on disconnect it despawns + `_recv_despawn`. Clients clear any pre-placed
   players at start (single-player keeps them; net spawns fresh) and create
   server-spawned ones locally. New engine surface: `World.spawn_instance` /
   `despawn_entity` (thin wrappers over SpawnManager). Verified: `run_linux.sh net`
   = 1 dedicated server + 2 clients → 2 players spawned, server + both clients
   agree on the full roster. Visual: `scripts/net_demo.sh` (headless server + 2
   client windows side by side).
5. **Bandwidth/scale (future).** Delta compression, interest management, lag
   compensation; lobby/ready handshake; predict-owned-only if prediction is
   re-enabled for an AI-heavy twitch game.

## References

- Depends on: **ADR 0060** (deterministic I/O — input path + canonical-state
  serialization reused for snapshots/prediction), **ADR 0010** (save/load —
  apply-state machinery), **ADR 0021** (expose Godot's `MultiplayerAPI`).
- Sibling of: **ADR 0061** (lockstep — the deterministic-genre strategy; this is
  the twitch strategy under the same pluggable `io/` seam).
- Carries over: ADR 0061's `actor_of_peer` (ownership) + the `yume_local_follow_id`
  per-peer camera (the "player-specific" presentation layer).
