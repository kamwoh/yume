# ADR 0065 — Synced animation (phase as deterministic sim state)

_Date: 2026-06-01_
_Status: accepted_

## Context

In networked play (ADR 0063/0064) a remote character should not just "play the
walk clip" — every client must see the **same pose** (same leg forward) as the
authority. Today (ADR 0046) animation is pure presentation:
`AnimationDirector` picks a clip from `state.velocity` via `animation_state_rules`
and calls `AnimationPlayer.play(clip)`; Godot's C++ then advances the clip's
**timeline locally** on each client. Result:

- **Clip** is roughly synced — it's derived from `velocity`, which the netcode
  replicates, so every client picks "walk".
- **Phase** (where in the clip — left vs right leg) is **not** synced — each
  client's `AnimationPlayer` started the clip at a different moment, so the legs
  are out of phase across clients.

User requirement (2026-06-01): "synced animation — player B must see player A's
left leg forward when it's actually forward, not just play *a* walk." That needs
the animation **phase** replicated. ADR 0064 can replicate any entity *state*
field — but the phase isn't state today (it lives in the `AnimationPlayer`), and
the dedicated server is headless (no `AnimationPlayer` → no phase to broadcast).

## Decision

Make the animation **phase a deterministic sim-state field**, so it replicates
through ADR 0064 like any other field, and drive client playback from it.

1. **`state.anim_phase` (0..1) is sim state**, advanced **in the tick** (not by
   the `AnimationPlayer`). Because it's a normalized fraction advanced by a
   content tick rule (`anim_phase = frac(anim_phase + cycle·dt)`), it is
   deterministic and **headless-friendly** — the authority computes it with no
   renderer. Clip selection stays where it is (derived from `velocity` via
   `animation_state_rules`); only the phase becomes state. (A normalized fraction
   is clip-length-agnostic, so the headless server needs no `.glb`.)
2. **Replicate it via `net.json`** (ADR 0064): add `anim_phase` to a group's
   `fields`. No new netcode — it's just another field.
3. **Clients drive playback from it**: `AnimationDirector._apply_synced_phase`
   seeks the clip to `anim_phase · clip_length` every tick instead of
   free-running. **Opt-in** — absent `anim_phase` → the `AnimationPlayer`
   free-runs exactly as before (single-player / non-networked unchanged).

So the pose = (clip from synced velocity) + (phase from replicated `anim_phase`)
→ identical on every client. The only engine change is the seek;
phase-advance is a content rule and replication is `net.json`.

## Consequences

- **Exact pose sync** with ~1 extra float per entity per snapshot.
- Animation phase is now (optionally) part of the deterministic simulation — a
  shift from ADR 0046's "animation is pure presentation." It is **opt-in per
  entity** (only entities with an `anim_phase` state field + advance rule), so
  ADR 0046's free-run model remains the default everywhere else.
- The phase advance is **content** (a tick rule), and *what* gets replicated is
  **content** (`net.json`) — consistent with Invariants #1/#8. The engine ships
  only the generic "seek to `anim_phase` if present" primitive.
- v1 advances phase at a fixed cadence (a clip loops at a steady rate). Speed-
  proportional phase (cadence ∝ movement speed, so stopping freezes the legs) is
  a content refinement — make the rule's increment a function of `velocity`.
- Non-looping clips (jump) under a wrapping phase will loop; author the advance
  rule to gate on locomotion states if that matters.

## Alternatives considered

- **Replicate nothing, free-run (status quo)** — clip matches but phase drifts
  (legs out of sync). Rejected: that's exactly what the user does not want.
- **Clip + clip-start-tick, derive phase from a synced clock** — exact, lowest
  bandwidth (send only on clip change), but needs a synced server tick in
  snapshots + client-side phase math. Deferred; `anim_phase`-per-snapshot (this
  ADR) is simpler and slots directly into ADR 0064.
- **Server reads its `AnimationPlayer` phase and broadcasts it** — impossible:
  the dedicated server is headless, it has no `AnimationPlayer`. Forcing the
  phase to be sim state (this ADR) is what makes it headless-computable.

## References

- Builds on **ADR 0064** (data-driven replication — `anim_phase` is just a field)
  and **ADR 0063** (client-server netcode).
- Extends **ADR 0046** (animation via `AnimationPlayer`) — phase becomes opt-in
  sim state for the networked case; free-run remains the default.
- Invariants **#1** (data drives everything) + **#8** (engine = primitives +
  interpreter): phase-advance + replication are content; the engine adds only the
  generic seek-to-phase.
