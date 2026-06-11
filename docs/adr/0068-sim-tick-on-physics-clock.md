# ADR 0068 — sim tick driven by the physics clock

_Date: 2026-06-11_
_Status: accepted_

## Context

`World._process(delta)` owned the sim-tick accumulator (`_tick_due`),
firing **at most one tick per rendered frame**. Character bodies (ADR
0044) integrate in `_physics_process`, where Godot catches physics up
to wall time (up to `max_physics_steps_per_frame` iterations per
frame). The two clocks are therefore allowed to skew: when frame rate
dips below the tick rate, the rule clock slides to frame rate while
physics keeps wall pace — **multiple physics steps integrate a stale
`velocity_set` between steering decisions**.

Empirical case (2026-06-11, autorace net record): a loaded headless
server (2 clients, ~300 entities) sagged to ~15 fps. Recorded
trajectories showed speed bursts of 72–83 u/s against a 14 u/s
`top_speed` (4–5 physics steps per rule tick) and corner overshoots up
to 10.9 m off the racing line. The user saw it immediately in the
rendered clip: "suddenly so fast and not following the original path."
Solo runs never show the skew because an unloaded instance holds 60
fps and the clocks coincidentally stay 1:1 — the bug class is latent
in EVERY game and triggers under load, not under net.

The 2026-05-12 design note in world.gd ("coupling sim-ticks to frame
rate would make rule cascades hardware-dependent") states the right
invariant, but the 1-tick-per-frame cap IS frame coupling whenever
frame rate < tick rate.

## Decision

Move the sim-tick gate (freeze check + `_tick_due` +
`advance_one_tick`) from `_process` to `_physics_process`.

- `_physics_process` runs with fixed `delta` and inherits Godot's own
  physics catch-up: under load, sim ticks and body integration slow
  down **together, coherently** — they can never skew, by
  construction.
- A bounded drain loop (≤ 8 ticks per physics step) serves games whose
  `tick_seconds` is shorter than the physics step (e.g. 120 Hz tick on
  60 Hz physics), preserving their sim rate.
- Frame-rate work stays in `_process`: input polling (latency),
  `frame_tick` rules (ADR 0050), ground clamp. The
  `yume_external_tick_driver` seam (lockstep/replay drivers) gates
  both callbacks.
- `step_runner` / scenario tests call `advance_one_tick` directly —
  unchanged.

## Consequences

- Rules and physics share ONE clock; `velocity_set` is re-evaluated
  every body integration step (when tick_seconds matches physics dt).
  Record-then-replay (ADR 0066) gets a coherent tick axis even on a
  server running far below realtime.
- Under extreme load the sim dilates relative to wall time instead of
  corrupting (slower but correct beats realtime but wrong; ADR 0066
  replays at sim-time, so recordings are unaffected by dilation).
- CLAUDE.md's "tick accumulator in `_process`" note is superseded by
  this ADR.

## Alternatives considered

- **Catch-up loop in `_process`** — keeps sim wall-paced, but runs N
  rule ticks between physics steps, so only the LAST `velocity_set`
  integrates: the inverse skew (under-movement + same steering lag).
- **Scope to net-host only** — leaves the identical latent skew in
  solo play on slow machines; rejected per the no-escape-hatch
  principle (fix the primitive, not the symptom site).
- **Stamp records with physics-step count** — fixes the replay TIME
  axis but the sim itself still steered 4× late; the off-line
  excursions would remain in the data.
