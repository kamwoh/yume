# ADR 0078 — The calendar clock (`scheduled` trigger + `advance_time`)

_Date: 2026-08-16_
_Status: proposed_

## Context

**A bug first.** `"scheduled"` has been in `Rule.VALID_TRIGGERS`
(`rule.gd`) with **no dispatcher anywhere in `phase_scheduler.gd`**. Every
firing path reads a named bucket — `frame_tick`, `input`, `tick`,
`contact`, `overlap`, `relation_changed`, `signal`, and the lifecycle
kinds — and none of them reads `"scheduled"`. A rule declaring that
trigger registers cleanly, passes `Rule.validate_all`, passes every
validator, and **never fires**, with zero diagnostics. The vocabulary
advertised a verb the interpreter did not implement.

**Now the reason to implement it rather than delete it.** CLAUDE.md's
tick doctrine is emphatic and correct:

> The tick is the engine's clock — never change it as a balance knob.
> Too fast/slow? Scale the rule's `interval`, NOT the tick.

That doctrine assumes there is exactly one clock. For an action game
there is. But a career/life-sim has two, and they are not convertible:

- the **heartbeat** — 60Hz, drives movement, collision, input, animation;
- the **calendar** — advances by *actions*, not by seconds. Travelling
  between towns costs six days. Training costs a day. Sitting in a menu
  costs nothing at all.

Expressing the calendar on the heartbeat fails twice. First the numbers
become absurd and fragile: at 60Hz an in-game day is `interval: 57600`,
and any change to `tick_seconds` silently rescales what every such number
MEANS. Second, and fatally, there is no way to say "advance six days
*now*" — the world must actually simulate those days (factions fight,
NPCs move, prices drift) while the player waits a fraction of a second of
real time. `interval` cannot express that at any value.

The honest reading: the doctrine's *intent* — never let a number's
meaning drift under you — is right and is preserved here. Its *gap* is
the assumption of a single clock.

## Decision

Implement `scheduled` as a **second, coarse clock that has no real-time
duration at all**. It advances only when something explicitly advances
it.

```jsonc
// fires once per calendar unit
{"id": "daily_upkeep", "trigger": {"type": "scheduled", "every": 1},
 "query": {"tags_all": ["settlement"]}, "effect": [...]}

// fires every 30th unit
{"id": "monthly_council", "trigger": {"type": "scheduled", "every": 30},
 "effect": [...]}
```

```jsonc
// travel costs six days — the world simulates them, atomically
{"type": "advance_time", "units": 6}
```

- **`advance_time {units: N}`** steps the `scheduled` bucket N times,
  synchronously, inside the current effect chain. Effects are flushed
  after each unit, so unit *k+1*'s rules observe unit *k*'s results —
  the same phase ordering the heartbeat already guarantees.
- It does **not** run the `tick` bucket. The heartbeat is untouched:
  `tick_seconds` is still never a balance knob, `interval` is still
  counted in ticks, and every existing rule behaves identically.
- **`units` is counted in calendar units, not days.** The engine has no
  idea what a day is — "6 units = 6 days" is a content decision, exactly
  like `hp` or `gold`. Content that wants hours picks a finer unit.
- **Re-entrancy is a logged no-op** (`[time.reentrant_advance]`). An
  `advance_time` reached from inside a `scheduled` rule would otherwise
  recurse until the stack blew.
- The scheduler exposes the entry point through `env` as a Callable,
  mirroring the existing `env["dispatch_lifecycle"]` pattern, rather than
  putting the scheduler object into `env` (which would create a reference
  cycle with the env dictionary it already holds).

The calendar counter lives in world state, so it persists with the save
and content can bind to it.

## Consequences

**Enables.** Action-cost time: travel, training, resting, waiting — any
verb whose price is measured in world-time rather than in a resource.
The background world genuinely simulates the elapsed period instead of
skipping it. Also makes long-horizon simulation cheap: a rule that should
run "once per season" costs one dispatch per season, not a modulo test
against a 60Hz counter forever.

**Costs.** Two clocks is genuinely more to hold in your head, and the
failure mode of picking the wrong one is quiet (a rule on the wrong clock
fires at the wrong rate rather than erroring). CLAUDE.md is amended to
name both, and the two are syntactically distinct — `interval` on `tick`,
`every` on `scheduled` — so a rule cannot ambiguously belong to both.

`advance_time` with a large `units` does real work proportional to
N × (scheduled rules × matched entities). Advancing a year at daily
granularity is 365 dispatches; that is fine, but it is not free, and a
frame that does it will be long. Content that advances huge spans should
expect a hitch and cover it with a fade.

**Precludes.** A `scheduled` rule cannot observe sub-unit state changes;
that is the point of a coarse clock. Anything needing per-frame fidelity
belongs on the heartbeat.

**Invariant check (#8).** `scheduled` is a trigger and `advance_time` is
an effect — vocabulary, not semantics. The engine never learns what a
unit means. A 4X game's turns, a farming sim's days, a factory sim's
production cycles, and a roguelike's dungeon turns are the same clock.

## Alternatives considered

**A. Delete the dead `scheduled` trigger and express the calendar on the
heartbeat.** Rejected: `interval` cannot express "advance six days now",
which is the actual requirement. Deleting it would also mean writing off
a verb the vocabulary already promises.

**B. `advance_time {ticks: N}` — fast-forward the heartbeat.** Rejected:
six days at 60Hz is 31 million ticks. Even at a coarse per-genre
`tick_seconds` it is thousands of full four-phase ticks, running movement
and collision for a period in which nobody is moving.

**C. Make the calendar a content-owned entity ticked by an ordinary rule.**
This is what content does today, and it is fine for *counting* days. It
cannot make the world simulate six days atomically inside one action,
which is the whole requirement.

**D. Lower `tick_seconds` per-genre so a day is a manageable interval.**
Rejected outright — it is precisely the "tick as a balance knob" move the
doctrine forbids, and it would wreck movement and input, which need the
heartbeat.

## References

- Code: `godot/scripts/engine/core/phase_scheduler.gd`
  (`advance_calendar`, the `scheduled` bucket),
  `godot/scripts/engine/core/effects/effect_shell.gd` (`advance_time`),
  `godot/scripts/engine/core/rule.gd` (`VALID_TRIGGERS` — where the dead
  entry lived)
- Tests: `godot/scripts/engine/tests/test_runner.gd` → `test_calendar_clock`
- Gate: `tools/validators/validate_engine_wiring.py` (new) — every entry
  in `Rule.VALID_TRIGGERS` must have a matching dispatcher in
  `phase_scheduler.gd`, and every field `Rule.from_dict` parses must be
  read somewhere in the engine. This is the gate that would have caught
  `scheduled` being dead, and `scope` being an unread field.
- Doctrine: CLAUDE.md § "Tick rate is the engine's heartbeat" — amended
  to name both clocks; the original prohibition is unchanged and still
  applies to the heartbeat.
- Related: ADR 0068 (sim tick on the physics clock), ADR 0029 (schedule
  primitive — NPC time-of-day, which rides the heartbeat and is
  unaffected), ADR 0047 (world state — where the counter lives)
