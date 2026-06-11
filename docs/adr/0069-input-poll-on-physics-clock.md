# ADR 0069 — Input poll on the physics clock

_Date: 2026-06-11_
_Status: accepted_

## Context

The engine's documented input contract (CLAUDE.md § press vs hold) is:
`edge: "hold"` **fires every tick held**. The implementation polled
`InputRegistrar.poll` from `World._process` — the **display** clock —
while ADR 0068 moved the sim-tick gate to `_physics_process` — the
**physics** clock (fixed 60Hz, catch-up under load).

At render rates below the tick rate, those clocks diverge: a held key
queued one input event per **rendered frame**, while rules fired per
**tick**. On a machine rendering 8–19 fps, a held `accel` fired 8–19×/s
against a 60×/s simulation.

This was latent for as long as no rule applied a per-tick force
*opposing* held input. Empirical case (2026-06-11, autorace): a
`coast_drag` rule (speed −0.05/tick toward zero) was added alongside a
hold-driven throttle (+0.13/press). At 60 fps: net +0.08/tick, as
designed. At the user's ~8–19 fps: drag removed 3.0 speed/s while the
throttle added 1.0–2.5/s — **net negative; W and S were unresponsive**,
steering (no opposing force) still worked. The headless scenario suite
passed throughout, because StepRunner drives the poll once per tick —
the documented contract — making the bug invisible to every automated
gate and reproducible only in live low-fps play.

## Decision

Move the live input poll to the physics clock, restoring the documented
hold contract at any frame rate:

1. `World._poll_input()` is called from `_physics_process`, once per
   physics step, after the freeze gate and before the tick gate. Catch-up
   steps (multiple `_physics_process` calls per rendered frame under
   load) each poll — held keys correctly fire once per recovered tick.
   Godot tracks `is_action_just_pressed` separately for physics frames,
   so press-edges still fire exactly once.
2. `_process` keeps display-rate work only: ground-constraint apply and
   `fire_frame_tick` (ADR 0050). The freeze-skip semantics for the poll
   (the 2026-05-16 inventory-flash fix) move with it unchanged.
3. Sole-driver harnesses (`scenario_runner`, `test_runner`'s step-runner
   world) disable `_physics_process` alongside `_process` — with both
   the tick gate (ADR 0068) and the poll (this ADR) on the physics
   clock, disabling `_process` alone no longer guards determinism.

`InputRegistrar.poll` itself is unchanged — same seam, same dedup, same
actor resolution. StepRunner is unchanged (it always polled per tick;
live play now matches it).

## Consequences

- Input strength is frame-rate-independent: a held key contributes the
  same per-tick impulse at 8 fps and at 144 fps. Content may now safely
  author per-tick forces (drag, decay, regen) against held input.
- Input latency is unchanged in practice (physics also runs at 60Hz).
- Scripted (StepRunner) and live play now share both the injection path
  (ADR 0060) and the cadence — one less scripted/live divergence class.
- For games with `tick_seconds` < physics step (e.g. 120Hz sims), holds
  fire once per physics step, not per tick — same as the previous
  best-case behavior; noted as a known limit, not a regression.
- Gate: `test_runner.gd` test_step_runner #15 drives `_physics_process`
  directly with a held action and asserts one fire per step.

## Alternatives considered

- **Content-side workaround** (gate drag on a "recently pressed"
  timestamp): patches one demo, leaves the broken primitive — every
  future per-tick force vs held input re-hits the bug. Rejected per
  post-mortem rule step 3a (fix the primitive, not the symptom site).
- **Held-action latch in the scheduler** (poll per frame, scheduler
  re-fires latched holds per tick): equivalent result, more machinery,
  and a second source of truth for "is the key down". Rejected.
- **Status quo + document the limit**: the limit contradicts the already
  documented contract and produces hardware-dependent gameplay. Rejected.
