# ADR 0061 — Networked multiplayer: input-replicated lockstep over the deterministic I/O contract

_Date: 2026-05-30_
_Status: accepted (DECISION-ONLY — model decided; implementation deferred behind ADR 0060's determinism audit)_
_Reviewed: yume-tech-director 2026-05-31 — accept; invariant-clean, accurately grounded on 0060's shipped contract._

> **Depends on ADR 0060.** This ADR records the multiplayer *model* decision and
> reuses 0060's deliverables (one input path, `canonical_state_hash`,
> `stdio_driver`). It does NOT schedule implementation — 0060 (the I/O contract)
> must land and the determinism audit must pass before any networking work
> begins. This is the "Tier 4 / future" hold from `docs/guideline/30_framework_primitives.md:853`
> converted into a concrete, decided path — not a build order.

## Context

Yume is single-instance only today. `docs/guideline/30_framework_primitives.md:853` holds
networked multiplayer as "future work layered on top of state serialization,"
and ADR 0016 (multi-actor) explicitly scoped networking out. No networking
layer, authority model, or replication strategy exists.

ADR 0060 establishes the foundation multiplayer needs: a deterministic engine
where state at tick N is a pure function of `(initial_state, input_log[0..N])`,
a `canonical_state_hash` that proves determinism, and a single input path where
"scripted / AI / remote" input is indistinguishable from hardware input. With
that in place, multiplayer is no longer an engine problem — it is a *transport*
problem: get each peer the same inputs, let each peer reproduce the same state.

This ADR decides WHICH multiplayer model, and why, so that when the work is
scheduled the architecture is already settled.

## Decision

**Input-replicated strict lockstep**, built on ADR 0060's contract. Rollback is
a per-game opt-in for twitch genres, deferred. Implementation is NOT scheduled
here.

### The model

- Replicate **inputs**, not state. Each peer runs the same deterministic engine;
  every peer reproduces identical state from the shared input log. This IS the
  explicit-world-model contract — the same one save/load and deterministic
  replay already rely on.
  - *Implementation note (vs 0060's shipped reality):* 0060 unified input at the
    **poll/queue seam** (`InputRegistrar.poll` → `scheduler.queue_input`), NOT at
    synthesized Godot `InputEvent`s (a documented 0060 Phase 1 deviation). So a
    remote peer's input batch is injected the same way scripted/env input is — a
    per-tick `{"actions":[...]}` batch routed to `queue_input` for that peer's
    actor — not by replaying hardware `InputEvent`s. A future implementer should
    inject at that seam; do not go looking for `parse_input_event`.
- Per tick, every peer broadcasts its local input batch + its
  `canonical_state_hash` (0060 Part 1). A peer advances tick N only when it has
  all peers' inputs for tick N (the lockstep barrier — the network analogue of
  0060's stdio blocking-read barrier).
- Hash exchange is the **desync detector**: the first tick where peer hashes
  disagree names the exact divergent tick, and (via 0060's oracle tooling) the
  divergent entity. A desync becomes a debuggable bug, not a vibes-bad mystery.

### Authority

Symmetric peers (no server authority over state). Each peer is authoritative
over its OWN inputs only; state is derived identically everywhere. A peer may be
elected as input relay/host (star topology over `ENetMultiplayerPeer`) for NAT
simplicity, but it is NOT authoritative over simulation — it only forwards input
batches. This preserves replay-from-inputs.

### Transport

`ENetMultiplayerPeer` (Godot's default UDP high-level multiplayer). The wire
payload is the SAME per-tick input batch shape 0060 defined for stdio — just
framed in an RPC instead of a stdin line. The `stdio_driver` barrier-step loop
generalizes: swap "block on stdin" for "block until all peers' RPCs for tick N
arrived." Only that one driver-level swap differs from 0060.

### Latency note

At 60Hz the 16ms tick budget is tighter than typical internet RTT (30-80ms), so
peers buffer 2-4 ticks of input delay (~32-64ms). Invisible for Yume's paced
genres (turn-based, sim, merchant, farming). The genres where it is NOT
acceptable (twitch FPS, fighting) take rollback.

**Implemented (2026-05-31):** `lockstep_driver` runs `INPUT_DELAY = 3`. A peer
broadcasts its input for tick `current + INPUT_DELAY` and advances tick T only
once it already holds every peer's input for T — which, sent 3 ticks earlier,
has normally arrived, so the peer never stalls on the wire. The driver advances
on a fixed-rate accumulator (sim runs at `tick_seconds` regardless of render
FPS, capped at `MAX_CATCHUP_TICKS` per frame to avoid a spiral), so motion stays
smooth even when the GPU is slow. The earlier zero-delay loop blocked on a
reliable-RPC round-trip EVERY tick → visible stutter; this is the standard
lockstep latency-hider. Determinism is unaffected (each tick injects identical
per-peer inputs on both sides) — verified IN SYNC, byte-identical, 300 ticks.

### Rollback (deferred, per-game opt-in)

Rollback netcode = strict lockstep + client-side prediction + state rollback &
re-simulate on input arrival. It is built ON the same input-replication
transport, so lockstep is a strict prerequisite, not throwaway work. Requires:
fast full-state snapshot/restore (0060's snapshot is the basis) + bounded
re-sim cost per tick. Scoped only when a twitch game actually needs it; not now.

## Consequences

**Positive.**
- Reuses 0060 wholesale; multiplayer adds a transport, not an engine fork.
- Symmetric input-replication keeps replay-from-inputs intact — a multiplayer
  session is recordable + replayable exactly like single-player.
- Per-tick hash exchange makes desyncs precisely diagnosable.

**Negative / cost.**
- Lockstep latency = slowest peer's RTT; unacceptable for twitch genres without
  rollback.
- Determinism becomes a HARD requirement, not a nice-to-have: any nondeterminism
  0060's audit missed desyncs live players. The audit must be thorough before
  this ships.
- Cross-platform float determinism (0060's flagged hazard) becomes a real
  cross-peer hazard if peers run different archs — may constrain multiplayer to
  same-arch peers, or require fixed-point/soft-float for the sim. Open question.
  - *Hash-resolution refinement (tech-director 2026-05-31):* the desync detector's
    resolution is bounded by `canonical_state_hash`'s float formatting (`%.6f`).
    Sub-1e-6 float drift is **invisible** to the hash until it accumulates past
    that threshold (then diverges "suddenly"). For **same-arch** peers, exact
    determinism should yield bit-identical floats → identical hashes, so this is
    moot. For **cross-arch** peers, the `%.6f` granularity IS the actual
    detection floor — fold this into the open question above. (A tighter hash
    precision would catch drift earlier but also flag benign last-ULP diffs.)
- Rollback, when needed, is substantial additional work (snapshot/restore perf,
  input prediction, re-sim budget).

**Neutral.**
- Supersedes the "networked multiplayer — future" hold in
  `docs/guideline/30_framework_primitives.md:853` with a decided path (a contract-doc
  cross-reference edit is ADR-gated per `.claude/rules/docs.md`; make it when
  this ADR is accepted).
- Per ADR 0021 (Yume = JSON layer over Godot), this is a capability-exposure of
  Godot's `MultiplayerAPI` / `ENetMultiplayerPeer` — consistent with the
  "expose, don't reimplement" principle.

## Alternatives considered

- **Server-authoritative state replication** (server simulates, clients render +
  send inputs, server streams state diffs). Rejected: abandons the
  explicit-world-model contract — server state becomes truth, the input log stops
  being authoritative, replay-from-inputs breaks. Replay-from-inputs is Yume's
  whole value proposition. (Standard for action MMOs where determinism is
  impractical; not Yume's situation — the engine is already deterministic.)
- **Rollback as the default model.** Rejected as default: most Yume genres are
  paced enough that lockstep's 2-4 tick buffer is invisible; rollback's
  complexity is unjustified except for twitch genres, where it remains the
  opt-in.
- **Build multiplayer before/with the I/O contract (the original ADR 0060
  draft).** Rejected (2026-05-30, user direction): networking on an unproven-
  deterministic engine debugs desyncs that are really determinism bugs. 0060 +
  its audit must land first; this ADR waits behind it.

## Pluggability — lockstep is ONE model, not THE model (2026-05-31)

The framework must NOT be hard-wired to lockstep. Lockstep is the first netcode
*strategy* built on ADR 0060's model-agnostic foundation; it is not the
multiplayer architecture. Enforced by layering:

- **Foundation (ADR 0060, engine core):** `canonical_state_hash`, the one input
  path (`queue_input`), `advance_one_tick`, and a GENERICALLY-named seam
  `Engine` meta flag `yume_external_tick_driver` that `World._process` honors.
  The engine core has ZERO code dependency on lockstep (verified: only a comment
  mentions it).
- **Strategy (this ADR, isolated in `io/`):** `LockstepCore` + `lockstep_driver`.
  Referenced only by each other + the test. Swappable.
- **Future models plug in as SIBLINGS, not core edits:** rollback (lockstep +
  prediction + rewind), server-authoritative state replication, deterministic
  replay playback — each a new driver/core in `io/` reusing the same foundation.
  Adding one must not require touching the engine core. If a future model can't
  be expressed without core changes, that's a signal the foundation seam (not
  the model) needs an ADR.

So: implement lockstep first (it's the cleanest fit for a deterministic engine +
unblocks the explicit-world-model goals), but keep every model behind the
foundation seam so the framework is never lockstep-limited.

## Implementation — phasing (started 2026-05-31)

Now scheduled (0060's determinism audit passed same-arch: sokoban / doomarena3d
/ aldenmere deterministic; cross-arch float remains the open hazard above).
Phased like 0060 — each phase CI-testable:

- **Phase 1 — transport-agnostic lockstep core. ✅ DONE.**
  `lockstep_core.gd` (`class_name LockstepCore`): the engine side that is NOT
  the transport — the per-tick input barrier (`all_inputs_ready`), per-peer
  input injection to each peer's actor (via `scheduler.queue_input`, the ADR
  0060 poll/queue seam), one canonical tick per `step`, and the hash-ledger
  desync detector (`submit_hash` → first divergent tick). Verified in-process
  (`test_runner.gd::test_lockstep`, two minimal worlds + an in-memory relay):
  (a) identical input log ⇒ identical per-tick hash on both peers + identical
  state; (b) the barrier only clears once all peers submit; (c) a hidden
  state poke on peer B at tick K is caught by the hash exchange as a desync at
  exactly tick K. No networking. 967/0 unit.
- **Phase 2 — ENet transport. ✅ DONE (transport proven).**
  `lockstep_driver.gd` autoload (active on `--lockstep-host` / `--lockstep-join`):
  `ENetMultiplayerPeer` + `@rpc` broadcast of each tick's input batch + hash;
  feeds `LockstepCore.submit_input/submit_hash` from RPC arrivals and `step`s
  when the barrier clears (0060's stdio blocking-read → "block until all peers'
  RPCs for tick N"). `LockstepCore.step` ticks character bodies (ADR 0045
  headless integration) so motion is tick-locked, not free-running. World
  auto-ticking is suppressed from boot via an `Engine` meta flag
  (`yume_external_tick_driver`) honored by `World._process` — without it, peers
  auto-advance differing tick counts while connecting and desync at tick 0.
  **Verified — 2-process loopback on the Linux binary, `demo_sokoban`
  (determinism-clean): two ENet peers, 20 ticks, BYTE-IDENTICAL canonical hashes,
  zero desync.** The transport replicates inputs + stays in lockstep correctly.

- **Phase 2.5 — tick-lock the live scene. ✅ DONE (bit-identical live-scene
  lockstep).** Full LIVE-SCENE boot (`play.tscn`, `auto_start`) had per-frame
  state mutation OUTSIDE the lockstep tick — found via a two-walking-characters
  demo in tiny_village (~0.2m cross-peer walk drift; desync flagged correctly).
  Two sources, both fixed behind the generic `yume_external_tick_driver` flag:
  (1) **directors** (`world_boot._mount_default_directors` sets each director's
  `process_mode = DISABLED` from boot — cascades to GameShell's camera etc.);
  (2) **character bodies** (`physics_body_builder.build_character_3d` disables the
  `CharacterBodyRunner`'s 60Hz `_physics_process`/`move_and_slide`, so motion is
  driven ONLY by the tick-locked `tick_headless` in `LockstepCore.step`). With
  both gated, two ENet peers running **two walking characters** in tiny_village
  produced BYTE-IDENTICAL canonical hashes over 30 ticks, zero desync. All gates
  are flag-only → normal play unchanged (unit 967/0, scenarios green). Remaining:
  ambient-NPC RNG needs a deterministic per-entity seed for AI-heavy scenes like
  aldenmere (Phase 0 instance_patterns pattern); and tick-locked `move_and_slide`
  collision (vs pure integration) is future work for collision-heavy lockstep.
- **Phase 3 — game integration.** Per-peer actor assignment, join/leave
  lifecycle, lobby. The `LockstepCore.actor_of_peer` map is the seam.
- **Phase 4 — rollback (per-game opt-in, deferred).** Client-side prediction +
  snapshot/restore (ADR 0010 basis) + bounded re-sim, built on the same
  input-replication transport. Scoped only when a twitch game needs it.

## References

- Depends on: **ADR 0060** (deterministic I/O contract — input path, state hash,
  stdio driver). All deliverables here reuse 0060's.
- Related ADRs: 0010 (save/load — snapshot basis for rollback), 0016 (multi-actor
  — scoped networking out, now addressed here), 0021 (capability-exposure of
  Godot `MultiplayerAPI`).
- Contract: `docs/guideline/30_framework_primitives.md:853` (the "future multiplayer" hold
  this ADR decides).
- Godot APIs: `ENetMultiplayerPeer`, `MultiplayerAPI`, `@rpc`,
  `MultiplayerSynchronizer` (evaluate vs manual input-replication during impl).
- Design context: `.claude/plan/world-model-multiplayer.md`.
