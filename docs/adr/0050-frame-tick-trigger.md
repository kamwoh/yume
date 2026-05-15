# ADR 0050 — `frame_tick` trigger: content-authored per-frame behaviors

_Date: 2026-05-15_
_Status: accepted (foundation only — migrations follow as separate ADRs)_

## Context

Yume's rule system fires at **sim-tick rate** — controlled by
`tick_seconds` (sokoban 0.5s, doomarena3d 0.05s, aldenmere 0.0167s).
This works for discrete-event content: hunger decay, day cycle,
combat resolution, the simulation's heartbeat.

But many engine concerns are **per-frame** — they need to run every
`_process` call, independent of the sim cadence:

| Per-frame engine code today | Why it can't be a tick rule |
|---|---|
| Mouse-delta accumulator (`world.gd::_input`) | Reads events as they arrive (60Hz+) |
| Mouse-look routing → `actor.state.facing` (CameraDirector) | Needs frame-rate to feel smooth |
| Camera shake decay | Damped lerp per frame, not per tick |
| HUD flash alpha decay | Visual frame-rate, not sim-rate |
| Fade overlay alpha tween | Same |
| Ground-clamp creature.y (GroundConstraint) | Per-frame to catch sub-tick position drift |
| Projectile despawn below ground | Same |
| Per-axis stop injection (input_registrar) | Frame-rate input → state response |

Each of these lives in engine GDScript because there was no
rule-system way to express "run every frame." That violates the
**engine = primitives + interpreter** invariant (#8): the engine
should ship the dispatch mechanism; behaviors should be content.

## Decision

Add **`frame_tick`** as a new trigger type, callable via a new
scheduler method `fire_frame_tick()` from `World._process` every
frame, independent of `tick()`.

```jsonc
{
  "id": "engine_fade_overlay_decay",
  "trigger": {"type": "frame_tick"},
  "query": {"tags_all": ["_engine"], "state": {"_fade_alpha_gt": 0}},
  "effect": {"type": "state_add", "target": "self",
             "field": "_fade_alpha", "amount": -0.05}
}
```

The cadence is the only thing different from a tick rule. Same
query / require / chance / effect machinery; same primitives.

## Implementation

Three small changes:

1. **`rule.gd`**: `frame_tick` added to `VALID_TRIGGERS` whitelist.
2. **`phase_scheduler.gd`**: new method `fire_frame_tick()` that
   pulls rules from `rules_by_trigger["frame_tick"]`, runs them via
   the existing `_fire_scan_rule` machinery, and calls
   `flush_effects()` once at the end.
3. **`world.gd::_process`**: calls `scheduler.fire_frame_tick()`
   after frame-rate engine work (input poll, ground clamp) and
   BEFORE the sim-tick gate. So per-frame rules see fresh input
   state but fire even on frames where no sim-tick occurs.

```
_process(delta):
    _poll_input()              ← read Godot input
    _ground_constraint.apply() ← engine clamp (will migrate)
    scheduler.fire_frame_tick()  ← NEW: content-authored per-frame
    if not _tick_due(delta): return
    advance_one_tick()         ← sim cadence
```

Total engine change: **~15 lines**.

## Consequences

### What's now expressible as content

The seven+ per-frame behaviors listed in Context can each migrate
to JSON rules. Pattern:

```jsonc
// data/lib/engine_rules/<concern>.json
{"rules": [{"trigger": {"type": "frame_tick"}, ...}]}
```

Auto-loaded by WorldBoot (ADR 0049). Same convention as
`engine_rules/lifetime.json`.

### Migrations are independent

This ADR ships the foundation only. Each migration is its own
follow-up commit. Order is flexible; suggested by complexity:

1. **Fade overlay alpha tween** — simplest, single field decay
2. **HUD flash decay** — same shape
3. **Camera shake decay** — single field decay
4. **Per-axis stop injection** — needs `input.held_none: [...]`
   query operator (new primitive, but small)
5. **Mouse-look routing** — needs `world.mouse_delta_x` /
   `mouse_delta_y` bindings exposed
6. **Ground clamp** — needs `state.position.y_lt` query (dot-path
   nested state — possibly a new query feature)
7. **Projectile-despawn below ground** — uses the dot-path same as
   ground clamp

Behaviors that may NOT migrate cleanly (stay engine):
- Mouse-delta accumulator itself (event-driven, irreducible Godot
  bridge per ADR 0021)
- Camera lerp follow position (high-frequency lerp + per-mode
  switching may not be worth rule-shaped expression)

### Performance

Frame_tick rules dispatch every frame. At Aldenmere's 237 entities
× 60fps, scanning entities for query match is ~14k checks/sec per
rule. At single-digit rule counts and current entity scales, this
is microseconds — same order as the engine code it replaces.

Future optimization: rules with restrictive queries (`tags_all`
filters) only iterate entities matching the tag, not all entities.
Already works via the existing scan machinery.

### Phase ordering between `frame_tick` and `tick`

- `frame_tick` fires every frame
- `tick` fires every Nth frame (when accumulator crosses tick_seconds)
- On frames where both fire, `frame_tick` fires FIRST (per `World._process`
  order). Sim-tick sees post-frame_tick state.

A frame_tick rule writing to state X is visible to the same frame's
sim-tick rule reading X. State coherence is the standard
flush-after-each-rule pattern (no new ordering invariant needed).

### Determinism

Frame_tick fires at WALL-CLOCK rate (typically 60fps). This makes
frame_tick rule outputs **non-deterministic across hardware** —
unlike sim-tick rules.

**Content authors using frame_tick must accept this.** Frame_tick
rules should be reserved for VISUAL / EPHEMERAL concerns (decay,
clamp, accumulator drain) where determinism doesn't matter.
Game-state-significant computations (combat resolution, scoring,
progression) belong on sim-tick rules where they're reproducible
across saves and frame rates.

This isn't a new constraint — Yume already has frame-rate engine
code (camera lerp, mouse accumulator) that's non-deterministic.
ADR 0050 just makes the frame-rate cadence available to content
within the same authoring discipline.

## Alternatives considered

### A. Status quo

Per-frame behaviors stay in engine GDScript. Rejected — violates
the "engine = primitives + interpreter" principle. Behaviors that
are pure data manipulation should be content.

### B. Add `_physics_process` rules

Match Godot's fixed physics rate (60Hz). Same as frame_tick at
typical settings. Rejected — coupling rule cadence to Godot's
physics tick adds an implicit dependency for content authors;
"frame" is the natural unit to expose.

### C. Compute "is this a sim-tick frame?" in each frame_tick rule

Avoid the separate cadence by having one cadence (frame rate) and
rules opt into "only fire on sim-tick frames" via a flag. Rejected
— inverts the current model (sim-tick is the discrete cadence,
frame is the continuous one). Makes sim-tick discipline weaker.

### D. Make `tick` itself frame-rate

Rejected — breaks determinism for every existing rule. Sim-tick
discipline is load-bearing for save reproducibility, scenario
tests, and turn-based authoring.

## Verification

- **Unit test**: `test_frame_tick` in `test_runner.gd` covers:
  - `frame_tick` is a valid trigger type
  - `fire_frame_tick()` fires rules that match
  - `fire_frame_tick()` does NOT fire `tick` rules
  - `tick()` does NOT fire `frame_tick` rules
  - Multiple `fire_frame_tick()` calls accumulate state correctly
  - Empty bucket is a no-op
- **Integration**: Aldenmere boots cleanly with no behavioral
  change (no frame_tick rules yet authored — primitive is
  available but unused).
- **Test count**: 840 → 847 (7 new assertions).

## Tech-director review

Accepted. Net engine LOC: **+25** (whitelist entry +
`fire_frame_tick` method + test). No new effects. No new query
operators (yet). Just a new trigger cadence using the existing
dispatch machinery.

Invariants verified:
- **#1** (JSON-only content channel): the new trigger is content-
  authorable; engine ships only the mechanism.
- **#5** (queries first-class): frame_tick rules use the same
  query system as tick rules.
- **#8** (engine = primitives + interpreter): this ADR adds a
  primitive (trigger cadence), not a behavior.
- **#9** (phase boundaries flush): `fire_frame_tick` flushes
  effects at the end; phase semantics preserved.

Migrations to JSON each become their own follow-up ADR (or
co-located within an unrelated commit when the engine code
needs other work anyway). Foundation is in place.

## References

- ADR 0049 — `engine_rules/` lib pattern (where most frame_tick
  rules will land)
- `godot/scripts/engine/core/rule.gd::VALID_TRIGGERS`
- `godot/scripts/engine/core/phase_scheduler.gd::fire_frame_tick`
- `godot/scripts/engine/core/world.gd::_process`
- `godot/scripts/engine/tests/test_runner.gd::test_frame_tick`
