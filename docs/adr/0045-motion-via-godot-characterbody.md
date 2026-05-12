# ADR 0045 — Motion integration via Godot's CharacterBody3D

_Date: 2026-05-12_
_Status: **proposed** — needs tech-director review_
_Type: continuation of ADR 0044 (collision via PhysicsServer3D) and
ADR 0021 (Yume = JSON layer over Godot; never reimplement what Godot
already does well)_

## Context

ADR 0044 ("Session A through E") moved **collision detection** from
hand-rolled AABB sweep in `world.gd::_integrate_motion` to
`PhysicsServer3D.intersect_shape`. The Sessions D + F notes explicitly
flagged a follow-up:

> ADR 0044 deliberately stopped at collision queries. The motion
> integration loop itself (drag → velocity → position) stayed
> hand-rolled in MotionIntegrator. Future work: lean on
> CharacterBody3D's move_and_slide to delegate the integration too.

That's this ADR.

What's still hand-rolled today:

1. **MotionIntegrator.integrate(delta)** — iterates every entity each
   frame, applies drag, integrates `position += velocity * delta`,
   calls into PhysicsServer for collision slide. ~100 lines of
   GDScript that re-implements what `CharacterBody3D.move_and_slide()`
   already does.

2. **World._pretick_velocity_zero** — for actors with the opt-in flag,
   zero the velocity each tick so camera-relative WASD's
   `velocity_add_relative` rules don't accumulate unbounded. An entity
   loop in GDScript.

3. **World._post_tick_speed_clamp** — for actors with `max_speed`,
   normalize velocity magnitude. Another entity loop. Exists to fix
   the diagonal-fastrun bug (W+D yields √2 × walk speed).

All three are content-shaped concerns (opt-in state flags drive them)
that ended up as engine-internal loops because the Godot integration
hadn't been built. CharacterBody3D handles all three natively.

## Decision

Move motion integration from Yume engine code into Godot. Each actor
entity gets a CharacterBody3D body (declared via its `physics` JSON
block, just like ADR 0044's bodies). Per-frame motion = call
`move_and_slide()` on that body. Speed clamping = body property.
Velocity reset between ticks = move_and_slide handles it via internal
`velocity` field (which we set from `entity.state.velocity` each
tick, BEFORE move_and_slide consumes it).

Concretely:

### Schema (JSON-side)

The `physics` block already declared body type per ADR 0044. For
moving actors, the body_type becomes `"character"` (a new value
alongside the existing `static`, `kinematic`, `rigid`, `area`):

```json
{
  "id": "player_def",
  "tags": ["player", "actor"],
  "physics": {
    "$extends": "@lib.physics.bodies.standard_kinematic_player",
    "body_type": "character",
    "max_speed": 3.0
  },
  "state_init": {"position": [0, 0, 0], "velocity": [0, 0]}
}
```

`max_speed` lifts into a Godot CharacterBody3D property — no
GDScript loop checking it each tick. Same for `acceleration` / `friction`
if we want them; these are body-level concerns Godot already optimizes.

### Engine-side translation (one-time, at spawn)

`PhysicsBodyBuilder.build_character_3d` creates a CharacterBody3D node,
attaches it to the Entity, mirrors `state.position` to body
`global_position` (and reverse — Entity setters already funnel through
to the body per ADR 0044's pattern).

### Per-frame loop (vanishes from world.gd)

The MotionIntegrator coordinator is **deleted**. Replaced by each
CharacterBody3D's own `_physics_process(delta)` (a Godot virtual that
fires at the physics tick rate), which:

1. Reads `entity.state.velocity` into `self.velocity` (Godot field)
2. Calls `move_and_slide()` (Godot handles drag, collision slide,
   slope, floor detection, ceiling detection — all for free)
3. Writes `self.global_position` back into `entity.state.position`

That's per-actor, in Godot's optimized C++ inner loop. World.gd's
`_process(delta)` no longer iterates entities for motion.

### Velocity loops vanish

- `_pretick_velocity_zero`: deletes. CharacterBody3D's `velocity`
  field is set FROM entity.state.velocity at the start of each
  `_physics_process`, not accumulated. Camera-relative WASD's
  `velocity_add_relative` rules still write to `entity.state.velocity`
  each tick — but the per-tick reset is just "entity.state.velocity
  = Vector3.ZERO at the start of the input phase". That's already
  a Yume primitive (`velocity_set` effect with value [0,0,0]) — moves
  to the input lib as a one-line rule. No special engine helper.

- `_post_tick_speed_clamp`: deletes. Replaced by setting Godot's
  built-in velocity clamping (we apply `velocity = velocity.limit_length(max_speed)`
  in the same `_physics_process` step that consumes velocity — one line).

### What stays in MotionIntegrator's territory

Nothing. The entire coordinator goes away. world.gd's `_process(delta)`
shrinks to:

```gdscript
func _process(delta: float) -> void:
    if scheduler == null: return
    InputRegistrar.poll(...)        # frame-rate input sampling
    _ground_constraint.apply()      # ground clamp (still ours — scene config)
    _tick_elapsed += delta          # sim-tick accumulator
    if _tick_elapsed >= tick_seconds:
        _tick_elapsed -= tick_seconds
        _tick_count += 1
        if not _frozen():
            advance_one_tick()
```

Motion is no longer in `_process`. It runs in Godot's physics step
on each actor body in parallel.

## Consequences

### Wins

- **Deletes MotionIntegrator entirely** (~140 lines)
- **Deletes `_pretick_velocity_zero` + `_post_tick_speed_clamp`**
  from world.gd (~25 lines)
- **Deletes `position_scale` dimensionality juggling** — Godot's
  CharacterBody3D works in world units directly; the renderer-side
  scale is now just renderer scaling, not motion scaling
- **Gets slope / step / floor / ceiling detection for free** — all
  CharacterBody3D features we'd otherwise hand-write
- **Velocity is finally one of Yume's seven primitives expressed
  in JSON only** — no engine-internal velocity loops; engine just
  reads body state through Entity bindings
- **`advance_one_tick` shrinks further** — drops the two velocity
  helpers; reads as a 7-line schedule
- **More consistent with ADR 0044**: physics queries go through
  PhysicsServer; motion goes through CharacterBody. Each system
  uses the right Godot tool.

### Tradeoffs

- **Two states of truth for actor position**: `entity.state.position`
  AND `body.global_position`. Already true post-ADR 0044 for
  static bodies; we mirror via Entity setters. For dynamic bodies,
  the body is now the source of truth between physics frames;
  Entity reads back at frame end. **Mitigation**: same funnel-point
  pattern (`Entity.set_position()` mirrors both directions); a
  read-only invariant for the period between `_physics_process`
  start and end.

- **Physics tick rate vs sim tick rate**: ADR 0044 resolved this
  with the snapshot-sync model — physics runs at native 60Hz, sim
  snapshots at 10Hz. CharacterBody3D's `_physics_process` runs
  at the physics rate (60Hz). For sim-rule purposes, position
  reads at the sim-tick boundary are stable (between physics
  frames). **Same model carries forward** — no new ordering question.

- **Backward compatibility for non-character entities**: existing
  ADR 0044 body types (`static`, `kinematic`, `rigid`, `area`)
  unchanged. Only actors that previously had hand-rolled motion
  via MotionIntegrator gain the `character` body type. Game JSON
  with the old shape continues to work (the entity just doesn't
  get a CharacterBody3D; it falls back to manual `state.velocity`
  read — but in practice, this branch is dead post-migration
  because every actor needs motion).

- **Test impact**: scenario_runner / step_runner currently call
  `world._motion_integrator.integrate(delta)` to advance motion in
  headless mode. They'd switch to advancing physics frames manually
  via `PhysicsServer3D.body_set_state` or stepping the physics
  server one tick. Bigger test refactor than ADR 0044's collision
  switch (which left integration intact). **Mitigation**: keep a
  minimal "test-mode integrate" helper in step_runner if needed,
  but the production path is pure Godot.

### Path-scoped invariants this touches

- **Invariant #1 (JSON-only content)**: PRESERVED. The
  `physics.max_speed` field is JSON; engine just translates to a
  Godot property.

- **Invariant #5 (queries first-class)**: PRESERVED. QueryLib's
  radius queries still go through PhysicsServer.intersect_shape
  (ADR 0044). No new query primitives.

- **Invariant #8 (engine = primitives + interpreter)**: PRESERVED
  AND STRENGTHENED. `character` is a new body_type value, but it's
  a Godot-mapped value (CharacterBody3D), not a new Yume primitive.
  The engine doesn't grow new opinions; it routes more of the
  motion story to Godot.

- **Invariant #9 (phase boundaries flush effects)**: PRESERVED.
  Sim-tick rules still produce effects → flush → next phase. Motion
  happens at Godot's physics rate between sim ticks; the snapshot-
  sync model (ADR 0044) keeps phase boundaries stable.

- **Invariant #10 (freeze policy)**: ALREADY HANDLED.
  `PhysicsServer3D.set_active(false)` (added in ADR 0044) pauses
  CharacterBody3D's `_physics_process` automatically. No new
  freeze plumbing.

## Alternatives considered

### A. Keep MotionIntegrator; just add character body translation

Half-measure. Hand-rolled motion stays in GDScript "for compatibility
with the rule system" but with a Godot fallback. Worst of both
worlds: still need MotionIntegrator, still write the velocity loops,
gain none of the Godot optimization. Rejected.

### B. RigidBody3D instead of CharacterBody3D for actors

RigidBody3D is mass-and-force driven; you `apply_force` rather than
set velocity. That's correct for projectiles + falling debris (and
ADR 0044 already has rigid_projectile template for those). But for
player + NPC actors, designers want to declare "walk at 3 m/s
when this input is held" — that's velocity-driven semantics.
CharacterBody3D is purpose-built for that exact use case.

Mix-and-match: actors use CharacterBody3D, projectiles use
RigidBody3D. Both go through PhysicsServer; ADR 0044's translation
layer extends naturally.

### C. AnimatableBody3D instead of CharacterBody3D

AnimatableBody3D is purely script-driven kinematic — you set its
position; collision detection happens but no slide. Effectively
what MotionIntegrator does today, just packaged. No win.

### D. Custom physics layer over PhysicsServer (current state)

What we have now. The collision query side was the big win (ADR
0044); the motion integration side was deferred. Continuing to
defer means MotionIntegrator stays, the two velocity loops stay,
and we keep hand-writing what Godot ships optimized.

## References

- ADR 0021 — Yume = JSON layer over Godot. **The foundational
  motivation.** Every Yume capability should be "expose Godot,
  don't reimplement".
- ADR 0044 — Physics via Godot's PhysicsServer3D. **The
  immediate predecessor.** Built the body schema + translation
  layer this ADR builds on.
- ADR 0040 — Camera-relative WASD. **The reason velocity loops
  exist** (pretick velocity zero + speed clamp). This ADR
  retires both helpers.
- ADR 0001 — Seven primitives. Velocity stays a state field
  (primitive #1's "reserved state field"); the integration is
  now Godot's responsibility.

## Migration plan (sketch — finalize during proposal review)

### Session A — schema + character body builder

Add `"character"` to `physics.body_type`. Extend
`PhysicsBodyBuilder.build_character_3d`. Entity setter funnels stay
the same (already mirror to body per ADR 0044). One actor demo
(Aldenmere player) opts in via JSON — no engine code path change
yet. **Validation**: scenario test asserting actor body type =
CharacterBody3D, entity.set_position mirrors to body.

### Session B — script-side velocity sync + speed clamp

CharacterBody3D._physics_process implementation that reads
`entity.state.velocity`, clamps to `max_speed`, calls
move_and_slide, writes back position. MotionIntegrator still runs
in parallel (no entity has `character` body_type yet, so it's a
no-op for them). **Validation**: same Aldenmere player demo —
walks the same as before, observable framerate.

### Session C — opt actors in; delete MotionIntegrator's path for them

Every actor in Aldenmere flips to `body_type: "character"`.
MotionIntegrator skips entities with a character body
(`if has_meta("_physics_body_rid"): continue`). Hand-roll branch
is dead for actors. **Validation**: full Aldenmere test pass,
visual capture confirms walking + collision + clamping all match.

### Session D — delete MotionIntegrator + the two velocity loops

The integrator's only remaining callers are 2D demos or test
scenarios — flip them too (or remove if dead). Delete
MotionIntegrator entirely. Delete `_pretick_velocity_zero` and
`_post_tick_speed_clamp` from world.gd. The pretick reset becomes
a one-line `velocity_set [0,0]` rule in the input-lib bundle.
**Validation**: 841 unit tests still pass; Aldenmere boot clean.

### Session E — doc + lib updates

Update `docs/30_framework_primitives.md` to describe character
bodies. Update `data/lib/physics/bodies.json` with a
`standard_character_actor` template. Update CLAUDE.md's
`state.velocity` rule to point at the new flow.

## Tech-director review

(To be added — needs review per the 11-invariant checklist before
Session A begins. Likely concerns: scenario_runner motion path
during the transition, position-source-of-truth between physics
frames, and `_pretick_velocity_zero` rule-form correctness.)
