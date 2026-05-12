# ADR 0045 — Motion integration via Godot's CharacterBody3D

_Date: 2026-05-12_
_Status: **accepted — all sessions landed** (2026-05-13). Sessions A-E
shipped over five loop iterations. MotionIntegrator deleted; CharacterBody3D
drives all character-body motion via move_and_slide; standard_character_*
lib templates added. Tech-director review (below) gated on Conditions
1, 2, 4 — all resolved during Sessions A-B. Conditions 3, 5, 6 resolved
during per-session implementation._
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

### The kinematic vs character distinction (Condition 1)

These are TWO different Godot concepts with different lifecycles:

| `body_type` | Godot object | Created via | Motion driver |
|---|---|---|---|
| `static` | PhysicsServer3D body (RID) | `PhysicsServer3D.body_create()` + `BODY_MODE_STATIC` | none — fixed |
| `kinematic` | PhysicsServer3D body (RID) | `PhysicsServer3D.body_create()` + `BODY_MODE_KINEMATIC` | engine writes via `body_set_state(BODY_STATE_TRANSFORM, …)` |
| `rigid` | PhysicsServer3D body (RID) | `PhysicsServer3D.body_create()` + `BODY_MODE_RIGID` | physics integration with mass + forces |
| `area` | PhysicsServer3D area (RID) | `PhysicsServer3D.area_create()` | overlap detection only |
| **`character`** (NEW) | **CharacterBody3D scene Node** | **`CharacterBody3D.new()` + `add_child`** | **`move_and_slide()` in its own `_physics_process`** |

The `character` body type is fundamentally different from the others —
it is a scene Node, not a raw server body. It requires:

1. A new GDScript file: **`scripts/engine/coordinators/character_body_runner.gd`**.
   This script extends `CharacterBody3D` and holds a typed `entity_ref:
   Entity` field set at construction time. Its `_physics_process(delta)`
   reads `entity_ref.state.velocity`, clamps to `entity_ref.state.max_speed`,
   calls `move_and_slide()`, writes back `entity_ref.state.position`.

2. **No `_process` logic** — only `_physics_process`. Required for
   freeze-policy compliance (Condition 3): `PhysicsServer3D.set_active
   (false)` suspends `_physics_process` automatically but not `_process`.

3. **Scene-tree attachment**: the CharacterBody3D Node is added as a
   child of the Entity Node (Entity is already a Node child of World).
   This puts the character body inside the spatial hierarchy so
   `move_and_slide` collides correctly with sibling static bodies.

4. **Stored as Entity meta** under a new key `_physics_body` (replacing
   the existing `_physics_body_rid` — see Condition 4 below for the
   meta-rename + dispatch).

### Engine-side translation (one-time, at spawn)

For body_type ∈ {static, kinematic, rigid, area}: unchanged from ADR
0044. PhysicsBodyBuilder.build_3d creates an RID; meta key is
`_physics_body` storing the RID.

For body_type = character: **PhysicsBodyBuilder.build_character_3d**
instantiates the new `CharacterBody3D` subclass from
`character_body_runner.gd`, sets `entity_ref` to the spawning Entity,
mirrors `state.position` to `node.global_position`, calls
`entity.add_child(node)`. Meta key `_physics_body` stores the Node
reference (Variant — can hold RID or Node).

Entity setters (`set_position`, `set_velocity`) call into
`PhysicsBodyBuilder.sync_body_transform` / `sync_body_velocity`. Those
functions branch on the meta type:
- RID → existing `PhysicsServer3D.body_set_state` path
- Node (CharacterBody3D) → `node.global_position = v3` / `node.velocity = v3`

### Lifecycle: free + persist-teleport (Condition 4)

`PhysicsBodyBuilder.free_3d(entity)` must branch on the stored meta:

```gdscript
static func free_3d(entity: Entity) -> void:
    if not entity.has_meta("_physics_body"): return
    var body = entity.get_meta("_physics_body")
    if body is RID:
        PhysicsServer3D.free_rid(body)
    elif body is Node:
        body.queue_free()
    entity.remove_meta("_physics_body")
```

`SpawnManager.despawn` continues to call `free_3d` first — same
unified path; only the dispatch changes.

PERSIST-TELEPORT in SpawnManager (ADR 0044 Condition 5): when a
persistent entity gets a position override on level transition, it
calls `entity.set_position(new_pos)`. That goes through the setter
funnel; `sync_body_transform` branches on meta type (RID → body_set_state;
Node → global_position assignment).

### Meta rename: `_physics_body_rid` → `_physics_body`

The existing meta key is `_physics_body_rid`. Renaming to
`_physics_body` is honest about the value's polymorphism (Variant
holding RID or Node). One-shot rename in Session A:
- Update all `has_meta("_physics_body_rid")` checks across
  PhysicsBodyBuilder, SpawnManager, Entity._exit_tree
- Single commit, mechanical change, fully testable

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

- **One-tick rule-visibility lag for character bodies** (Condition 2).
  CharacterBody3D's `_physics_process` runs at 60Hz and writes back
  to `entity.state.position` each frame. But Yume rules read
  `entity.state.position` at the SIM TICK boundary (10Hz). Between
  sim-tick N and sim-tick N+1, a CharacterBody3D may have slid
  around a wall, climbed a step, or been pushed; the rule layer
  sees only the snapshot at tick N+1. **Authoring guidance**: for
  most games this is imperceptible (≤0.1s at default tick_seconds).
  Use `body_type: "character"` for actors whose motion is
  velocity-driven and tolerant of one-tick read-back lag (player,
  NPCs, party companions). Use `body_type: "kinematic"` with
  `velocity_set` effects for entities needing exact rule-side
  position knowledge between motion events (fast projectiles
  testing wall contact, teleport-precision puzzles).

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

### Session A — schema + character body builder + lifecycle dispatch

Adds the schema vocabulary + builder without flipping any actors.
Five concrete steps:

1. **Rename meta key**: `_physics_body_rid` → `_physics_body` across
   PhysicsBodyBuilder, SpawnManager.despawn, Entity._exit_tree. Pure
   rename, all paths still store an RID. Tests still pass.

2. **Add `_physics_body` polymorphism in dispatch sites** (Condition 4):
   - `PhysicsBodyBuilder.free_3d`: branch on `is RID` vs `is Node`.
   - `PhysicsBodyBuilder.sync_body_transform`: same branch.
   - `PhysicsBodyBuilder.sync_body_velocity`: same branch.
   - SpawnManager PERSIST-TELEPORT update: uses set_position which
     goes through the funnel; the dispatch in step 2 handles it.

3. **Create `scripts/engine/coordinators/character_body_runner.gd`**.
   Extends CharacterBody3D, holds `entity_ref: Entity`, implements
   `_physics_process` only (no `_process` — Condition 3).

4. **Add `PhysicsBodyBuilder.build_character_3d(entity, phys_cfg)`**:
   instantiates the CharacterBody3D subclass, sets entity_ref,
   adds to entity as child, stores Node in entity meta
   `_physics_body`.

5. **Add `"character"` to physics_body_builder's body_type dispatch**.
   Currently maps each body_type to an RID factory; add the
   character branch returning the Node from step 4.

**Validation**:
- All 841 unit tests still pass (meta rename is mechanical).
- One scenario test: spawn an entity with `body_type: "character"`,
  assert `entity.has_meta("_physics_body")` and
  `entity.get_meta("_physics_body") is CharacterBody3D`.
- Aldenmere boots clean (no actor has flipped to character yet —
  this is purely additive vocabulary).
- `tools/check_gdscript.sh` clean on the new files.

**Session A does NOT flip any actors.** No CharacterBody3D is created
in real gameplay yet — only by the new scenario test. The session's
purpose is to land the lifecycle plumbing correctly before any actor
actually depends on it.

### Session B — script-side velocity sync + speed clamp

Implements the `_physics_process` body of
`character_body_runner.gd`: read `entity_ref.state.velocity` into
`self.velocity`, clamp via `self.velocity = self.velocity.limit_length
(entity_ref.state.max_speed)`, call `move_and_slide()`, write back
`entity_ref.state.position = self.global_position`.

MotionIntegrator still runs in parallel — no entity has
`body_type: "character"` in real content yet (only the Session A
scenario test). So this session is also additive.

**Condition 3 gate (re-verify at code review)**: the script must
use ONLY `_physics_process`, never `_process`. Grep the file:
no `func _process` allowed.

**Condition 5 gate (must resolve in this session BEFORE Session C
can begin)**: step_runner/scenario_runner currently call
`world._motion_integrator.integrate()`. For headless tests, the
character body's `_physics_process` does NOT fire (no live physics
server in tests). Three options, pick one:
  (a) step_runner detects character bodies and calls
      `character_body_runner.tick_headless(tick_seconds)` — a new
      method on the script that performs the same velocity-read +
      position-write but WITHOUT actually calling `move_and_slide`
      (uses simple position += velocity * dt for tests).
  (b) Tests for character actors assert state fields OTHER than
      position (velocity magnitude, max_speed clamp result) that
      are deterministic without physics.
  (c) step_runner falls back to MotionIntegrator for character bodies
      too, until Session D.
This ADR recommends option (a) — keeps test semantics close to
production while avoiding the physics-server dependency.

**Validation**: same Aldenmere player demo — walks the same as
before, observable framerate. Plus: scenario test from Session A
extended to assert velocity-read + position-write fires correctly
in headless mode (verifies the Condition 5 chosen path).

### Session C — opt actors in; delete MotionIntegrator's path for them

Every actor in Aldenmere flips to `body_type: "character"`.
MotionIntegrator skips entities with a character body (the
`_physics_body` meta is a Node, not an RID — same check used by
free_3d). Hand-roll branch is dead for actors.

**Visual gate (mandatory)**: per
`.claude/rules/visual-qa.md`, this session changes how every actor's
position updates. Required captures:
- Aldenmere boot frame (entities visible, on ground)
- Player walking 2s after `move_east` (position changed; collision
  with proto-village wall still blocks correctly)
- Multi-frame comparison (t=2.0s vs t=2.3s) verifying the player
  visibly moves between frames + collision slide works against a
  wall edge

**Validation**: full Aldenmere test pass, visual capture confirms
walking + collision + clamping all match the pre-cutover demo.

### Session D — delete MotionIntegrator + the two velocity loops

The integrator's only remaining callers are 2D demos or test
scenarios — flip them too (or remove if dead). Delete
MotionIntegrator entirely. Delete `_pretick_velocity_zero` and
`_post_tick_speed_clamp` from world.gd.

**Condition 6 resolution (`_pretick_velocity_zero` replacement)**:
Audit at Session D start. Two cases:

- If ALL actors are character bodies by this point (expected case
  for Aldenmere + future games): DELETE the `_pretick_velocity_zero`
  path entirely. No lib rule replacement needed — character bodies
  read `entity.state.velocity` and use it once via move_and_slide,
  then the next sim-tick's rules write a fresh value. The
  accumulator-zero concern only existed for the hand-rolled
  MotionIntegrator path.

- If non-character actors remain that use `zero_velocity_pretick`
  state: ship a lib rule `velocity_set [0,0]` with explicit
  `before` ordering relative to every `velocity_add_relative` rule
  in `data/lib/input/universal.json` and any per-game inputs that
  $include it. Comment the rule with "do not move from this slot —
  pretick zero must fire before camera-relative WASD adds."

The simplest outcome (and the project's North Star): all actors are
character bodies, the pretick zero deletes cleanly with no
replacement.

**Validation**: 841 unit tests still pass; Aldenmere boot clean;
full scenario suite green.

### Session E — doc + lib updates

Update `docs/30_framework_primitives.md` to describe character
bodies. Update `data/lib/physics/bodies.json` with a
`standard_character_actor` template. Update CLAUDE.md's
`state.velocity` rule to point at the new flow.

## Tech-director review

See the dated review below. Verdict: **accept-with-conditions**.
Conditions 1, 2, 4 resolved inline in the Decision and Consequences
sections above (revision 2026-05-13). Conditions 3, 5, 6 are
per-session gates resolved as each session is specced. Status flipped
from "proposed" to "accepted — Session A may begin."

---

## Tech-director review (2026-05-12)

**Verdict: ACCEPT-WITH-CONDITIONS.**

The architectural direction is sound and continues the ADR 0044 trajectory
correctly. CharacterBody3D is the right Godot primitive for velocity-driven
actors; the proposed elimination of `MotionIntegrator`, `_pretick_velocity_zero`,
and `_post_tick_speed_clamp` is a legitimate reduction of hand-rolled code.
However, five structural issues must be resolved before Session A may begin.
Two are blockers. Three are conditions that gate specific sessions.

---

### Invariant-by-invariant findings

#### Invariant #1 (JSON-only content channel) — PASSES

`body_type: "character"` is a new JSON value in the `physics` block.
No game-specific GDScript added. The `max_speed` lift from state field
to a CharacterBody3D property remains JSON-declared. Content authors
continue writing JSON; engine translates it once at spawn.

**No condition.**

#### Invariant #2 (no semantic effect types) — PASSES

No new effect type strings proposed. `velocity_set` and
`velocity_add_relative` are already in the vocabulary and remain.

**No condition.**

#### Invariant #3 (no entity-class hierarchy) — PASSES

CharacterBody3D is a Godot Node, not a Yume Entity subclass.
`PhysicsBodyBuilder.build_character_3d` would create a Godot body
attached to the entity as a child/meta, not extend Entity.

**No condition.**

#### Invariant #5 (queries first-class) — PASSES

QueryLib radius queries already route through PhysicsServer3D per ADR 0044.
Character body motion does not touch the query layer.

**No condition.**

#### Invariant #8 (engine = primitives + interpreter) — PASSES WITH QUALIFICATION

`"character"` as a fifth `body_type` value is acceptable primitive
vocabulary. It maps cleanly to a Godot class (CharacterBody3D), not a
genre concept. The engine grows one new dispatch branch; all
composition stays in JSON.

The qualification: the ADR counts five body types but ADR 0044's table
on line 110 already maps `kinematic` to `CharacterBody3D` (not
`CharacterBody3D` is a kinematic body under the hood; the row says
"StaticBody3D / CharacterBody3D / RigidBody3D / Area3D"). That is an
error or ambiguity in the ADR 0044 table. The current engine code
(physics_body_builder.gd:238) maps `"kinematic"` to
`BODY_MODE_KINEMATIC`, which uses PhysicsServer3D with NO attached
CharacterBody3D scene node — this is a low-level server-side body, not
a high-level scene node. `CharacterBody3D` the scene Node is different
from `BODY_MODE_KINEMATIC` the server mode.

**CONDITION 1 (Blocker — must resolve before Session A)**: The ADR must
explicitly clarify the kinematic/character boundary:

- `body_type: "kinematic"` (existing): PhysicsServer3D body in
  `BODY_MODE_KINEMATIC`. Motion driven externally by
  `PhysicsServer3D.body_set_state(BODY_STATE_LINEAR_VELOCITY, v)` and
  transform set via `body_set_state(BODY_STATE_TRANSFORM, xform)`.
  No `_physics_process`. No `move_and_slide`. This is correct for
  NPCs/projectiles whose motion comes purely from Yume rule effects
  (`velocity_set`) with no need for the CharacterBody3D slide/floor
  detection features.

- `body_type: "character"` (new): A scene-tree CharacterBody3D Node is
  created (not a PhysicsServer3D raw body). It gets its own
  `_physics_process` that runs at 60Hz. It calls `move_and_slide()`,
  which handles collision slide, slope, step-up, floor detection.
  The distinction matters because:
  (a) `move_and_slide()` requires being in the scene tree. A raw
      `PhysicsServer3D.body_create()` RID does NOT have
      `move_and_slide()` — that method lives on the CharacterBody3D
      Node class.
  (b) The body lifecycle is fundamentally different. `free_3d()` in
      PhysicsBodyBuilder calls `PhysicsServer3D.free_rid(body)`. A
      CharacterBody3D Node must be `queue_free()`'d instead.
  (c) The snap-to-body and read-back loop described in the ADR
      (`_physics_process` reads entity.state.velocity, calls
      move_and_slide, writes back global_position) requires a
      CharacterBody3D that holds a reference to its Entity — the
      body script must be a GDScript attached to the CharacterBody3D
      Node.

The ADR's migration description conflates these two concepts throughout
Session B ("CharacterBody3D._physics_process implementation"). Session A
says "extend PhysicsBodyBuilder.build_character_3d" — but the existing
`build_3d` API creates a raw PhysicsServer3D RID, not a scene Node.
These are architecturally different things. The implementation plan
must specify:

1. Does `build_character_3d` create a CharacterBody3D Node (requiring a
   GDScript file for the body's `_physics_process`), or a raw body RID?
2. If a Node, how does it attach to the scene tree? (Entity is a Node
   child of World — the CharacterBody3D could be a child of Entity, or
   a sibling.)
3. If a Node, despawn must call `queue_free()` on it (not
   `PhysicsServer3D.free_rid()`). `PhysicsBodyBuilder.free_3d` must
   branch on body type.
4. If a Node with its own `_physics_process`, the GDScript for that
   callback is NEW engine code. It must hold a typed reference to
   `Entity` — which means the CharacterBody3D script is a new file
   under `scripts/engine/`. This is acceptable (it's interpreter code,
   not genre code), but it must be explicitly called out and its
   content described.

This is not a reason to reject. It IS a reason to require the ADR
be revised with this distinction resolved before Session A begins.

#### Invariant #9 (phase boundaries flush effects) — PASSES WITH CLARIFICATION

The ADR states the snapshot-sync model from ADR 0044 carries forward,
which is correct. However there is an interaction that the ADR does not
address:

Under ADR 0044, `advance_one_tick` starts with `_sync_state_from_bodies`
(reads physics positions into entity.state). A CharacterBody3D running
its own `_physics_process` at 60Hz will update body position 6 times
between sim-ticks. The snapshot at tick N captures wherever
`_physics_process` last wrote. That is fine for kinematic bodies, where
the engine sets position via `body_set_state`. But for a CharacterBody3D
running `move_and_slide`, the body position reflects Godot's own
collision-slid result. The entity.state.velocity that was written at
tick N-1 drives the 60Hz motion; at tick N the snapshot reads back the
resulting position. This is the intended design and it is correct. No
new ordering problem emerges.

The remaining clarification is: during the 0-to-N frames between
sim-tick N-1 and sim-tick N, the entity's `entity.state.position` (as
read by any rule query) still holds the tick N-1 snapshot. The
CharacterBody3D's actual `global_position` has already moved past that.
The position delta is not visible to rules until the next snapshot. This
means the CharacterBody3D's collision response (slide around a wall) is
invisible to rules for up to one tick. For most games this is
imperceptible (0.1s at 10Hz). Games that need sub-tick precision
(fast projectiles testing exact wall contact positions) should use
`body_type: "kinematic"` with `velocity_set` instead of `"character"`.
**This must be documented** as the tradeoff between the two body types.

**CONDITION 2**: ADR text (Consequences section) must document the
one-tick rule-visibility lag for character body position changes.
Content authors choosing `character` vs `kinematic` need this
distinction.

#### Invariant #10 (freeze policy) — PASSES

`PhysicsServer3D.set_active(false)` is already implemented in world.gd
(line 564). A CharacterBody3D scene Node's `_physics_process` is
suspended by the physics server pause — it does not fire when the server
is inactive. No new freeze plumbing needed.

However: the CharacterBody3D Node is in the scene tree. Godot's
`_process` continues to run (physics is paused but game process is not).
If the CharacterBody3D script has any `_process` logic (distinct from
`_physics_process`), that would bypass the freeze. The implementation
must use ONLY `_physics_process` for the velocity-read/move_and_slide
/position-write loop. No logic in `_process`.

**CONDITION 3**: Explicitly documented in Session B spec: the character
body script uses only `_physics_process`, never `_process`. Verified by
code review at Session B merge.

#### Invariant #11 (level-discontinuity cleanup) — BLOCKER

This is the second blocker.

The ADR notes that `SpawnManager.despawn` calls
`PhysicsBodyBuilder.free_3d(ent)`, which calls
`PhysicsServer3D.free_rid(body_rid)`. This is correct for the existing
`kinematic/static/rigid/area` body types (all raw server bodies).

A CharacterBody3D is a scene Node. It cannot be freed with
`PhysicsServer3D.free_rid()`. The correct call is `node.queue_free()`.
If a character body entity is despawned and `free_3d` tries to
`free_rid()` on what is actually a Node reference (stored as meta
`_physics_body_rid`), one of two things happens:

(a) The RID is a node's internal RID — `free_rid` frees the physics
    server body but leaves the Node orphaned in the scene tree. Memory
    leak + orphaned node.
(b) The meta actually stores the Node reference directly (not a
    RID) — then `PhysicsServer3D.free_rid(body_rid)` receives a Node,
    which is not a RID, and GDScript will error.

Either path is broken. The session plan says "Entity setter funnels stay
the same (already mirror to body per ADR 0044)" but the body lifecycle
for a CharacterBody3D Node is fundamentally different from a raw
PhysicsServer3D body.

**CONDITION 4 (Blocker — must resolve before Session A)**: The ADR must
specify the exact lifecycle model for character bodies:

1. What is stored as `_physics_body_rid` meta — the Node itself
   (typed as CharacterBody3D), a separate RID from the Node's internal
   body, or a dictionary with both?
2. `PhysicsBodyBuilder.free_3d` must branch: if the stored value is a
   Node (character body), call `node.queue_free()` and remove the meta.
   If it is an RID (kinematic/static/rigid), call `free_rid()`.
3. Alternatively: rename `_physics_body_rid` meta to `_physics_body`
   and support both types. Whichever approach, the split must be
   explicit and tested.

A Session A PR that creates CharacterBody3D nodes but passes them
through the existing `free_3d` path will either leak or crash on
level transitions. This MUST be resolved before Session A.

#### Invariant #12 (persistent-entity clobber guard) — PASSES WITH NOTE

ADR 0044 Condition 5 established that PERSIST-TELEPORT updates the body
transform. For CharacterBody3D nodes this is `node.global_position = v3`
instead of `PhysicsServer3D.body_set_state(BODY_STATE_TRANSFORM, xform)`.
Same concern as Condition 4 — the SpawnManager must branch on body type
when performing the teleport-position update.

This is already implied by the Condition 4 fix. No separate condition
needed if Condition 4 resolves the lifecycle model clearly.

---

### Test path concern — scenario_runner and step_runner

**CONDITION 5 (gates Session D)**: step_runner.gd line 183-184 and
scenario_runner.gd line 173-174 both call:

```gdscript
if world._motion_integrator != null:
    world._motion_integrator.integrate(float(world.tick_seconds))
```

The ADR acknowledges this ("bigger test refactor than ADR 0044's
collision switch") but defers it to Session D. This is acceptable
with one constraint: the test path must remain VALID through Sessions
A, B, and C. Specifically:

- Sessions A and B: MotionIntegrator still exists. Entities with
  `character` body type opted in via Session C don't exist yet
  (Session A adds one demo entity; Session B adds velocity sync for
  it). The integrator path in step_runner still fires for all other
  entities. Safe.
- Session C: Aldenmere actors flip to `character`. Their
  CharacterBody3D `_physics_process` runs at 60Hz. But step_runner
  calls `advance_one_tick()` and then manually calls
  `_motion_integrator.integrate(tick_seconds)`. In a headless test
  without a real Godot physics step, the CharacterBody3D's
  `_physics_process` does NOT fire (there is no physics server
  running in headless tests without a viewport and World3D space).
  Result: character-body entities DON'T MOVE in headless tests
  during Sessions A-C. Any scenario test that asserts position
  change for a character-body entity will fail.

This is a real gap. The ADR notes "keep a minimal test-mode integrate
helper in step_runner if needed" but does not specify what that looks
like. A concrete plan is needed before Session C begins.

**Resolution required in Session B spec**: before Session C lands,
step_runner must have a mechanism to advance character body motion
in headless mode. Options:

1. step_runner checks for character body entities and calls their
   `_physics_process(tick_seconds)` manually (if the CharacterBody3D
   script is accessible). This requires the character script to be
   callable without a live physics server (using stored velocity +
   position arithmetic, bypassing actual Godot physics calls).
2. step_runner falls back to calling MotionIntegrator.integrate for
   character-body entities too, until Session D (when they are
   confirmed to be test-safe via physics server in the test scene).
3. scenario tests for Aldenmere character-body actors are rewritten
   to assert state fields OTHER than position (e.g., velocity magnitude,
   `max_speed` clamp behavior) that are deterministic without physics.

Any of these is acceptable. The ADR must name the approach before
Session C lands, not defer it to Session D.

---

### The `_pretick_velocity_zero → velocity_set rule` transition

The ADR proposes replacing `world.gd::_pretick_velocity_zero` with a
`velocity_set [0,0]` rule in the input-lib bundle. This requires
careful evaluation.

Current behavior: `_pretick_velocity_zero` fires for ALL entities with
`state.zero_velocity_pretick=true`, BEFORE the input phase runs. This
means by the time `velocity_add_relative` rules fire, they are adding
to a guaranteed-zero velocity.

Proposed replacement: a rule with `trigger: {type: "tick"}` and effect
`{type: "velocity_set", x: 0, y: 0}`. This rule fires DURING the tick
pipeline, in whatever phase it is registered.

The ordering question is: if the velocity_set [0,0] rule fires in the
INPUT phase alongside the `velocity_add_relative` rules, which fires
FIRST? Phase ordering is stable within a phase only if rules are
explicitly ordered with `before`/`after` keys. Without such keys,
within-phase ordering is registration order (rules fire in the order
they are registered). The lib bundle ordering determines whether the
zero fires before or after the movement rules.

If the zero fires AFTER a `velocity_add_relative` rule, the actor's
velocity is zeroed AFTER movement was added — the actor does not move.
If the zero fires BEFORE, the behavior is identical to the current
`_pretick_velocity_zero`. The ADR does not specify the ordering
constraint for this rule.

This issue does not exist for `body_type: "character"` actors because
the CharacterBody3D's `_physics_process` READS entity.state.velocity
(whatever it is at tick end) and uses it to drive motion — the zero is
not needed for them; the pretick zero is a MotionIntegrator concern that
goes away with the integrator.

But the ADR's Session D says `_pretick_velocity_zero` "becomes a
one-line velocity_set [0,0] rule in the input-lib bundle." If by Session
D all actors are character bodies, there are NO actors left that need
the pretick zero — the rule is unnecessary and should simply be DELETED,
not replaced. If there are still non-character actors using
`zero_velocity_pretick`, the rule replacement requires explicit ordering.

**CONDITION 6**: Session D spec must resolve: (a) if all actors are
character bodies by Session D, delete the `_pretick_velocity_zero` path
entirely — do NOT replace with a lib rule; (b) if non-character actors
remain that use `zero_velocity_pretick`, the lib rule replacement must
declare explicit `before` ordering relative to all
`velocity_add_relative` rules in the bundle, documented with a comment.

---

### Session-by-session risk assessment

| Session | Risk level | Blocker before start? | Notes |
|---|---|---|---|
| A | MEDIUM (elevated) | Conditions 1 + 4 must resolve | Creates CharacterBody3D nodes. Body lifecycle must be correct from day one — leaked nodes on level transition will not be caught until Session C's multi-entity test. |
| B | HIGH | Condition 3 gate; also Condition 5 strategy | velocity_read/_physics_process/_write loop; must be `_physics_process` only. Test path gap begins here — character-body headless motion is broken. |
| C | HIGH | Condition 5 must be resolved BEFORE C lands | Cutover session. All Aldenmere actors flip. Any scenario test asserting position on character-body entities breaks in headless unless Condition 5 is solved. Visual capture mandatory per visual-validation gate. |
| D | MEDIUM | Condition 6 + perf benchmark (ADR 0044 Condition 11 inherited) | Deletion session. Safe only after C is verified. The test refactor for step_runner/_motion_integrator is Session D work. |
| E | LOW | None | Documentation pass. |

Session C is the riskiest commit because it is the cutover. Two
requirements before Session C merges:
1. The headless test path for character body motion is resolved
   (Condition 5).
2. Visual capture of Aldenmere walking + collision + speed-clamp
   all verified per visual-validation gate rule.

---

### Summary

**Five conditions total:**

| # | Scope | Blocks | Description |
|---|---|---|---|
| 1 | Blocker | Session A | Clarify kinematic vs character body: raw RID (PhysicsServer3D) vs Node (CharacterBody3D). Specify the GDScript file for `_physics_process`. |
| 2 | ADR text | — | Document one-tick rule-visibility lag for character body positions in Consequences section. |
| 3 | Session B spec | Session B | Character body script uses only `_physics_process`, never `_process`. Verified at Session B code review. |
| 4 | Blocker | Session A | Character body lifecycle in `PhysicsBodyBuilder.free_3d` and PERSIST-TELEPORT in SpawnManager must correctly branch on Node vs RID. |
| 5 | Session B spec | Session C | Headless test path for character body motion. Name the approach (manual physics step, integrator fallback, or non-position assertions) before Session C lands. |
| 6 | Session D spec | Session D | `_pretick_velocity_zero` replacement: either delete entirely (if all actors are character bodies) or specify explicit ordering for the lib rule. |

Conditions 1 and 4 are structural gaps that would produce hard bugs in
Session A itself (orphaned nodes, leaked bodies on level transition, or
RID/Node type errors). They must be addressed in ADR text before
implementation begins. Conditions 2, 3, 5, 6 are per-session gates that
can be resolved as each session is specced.

Once the ADR revision addresses Conditions 1 and 4, status flips to
**accepted — Session A may begin**.

The overall trajectory is correct. Eliminating `MotionIntegrator` is
the right call. The architectural boundary (CharacterBody3D for
move_and_slide actors, raw kinematic body for velocity-only actors) is
sound. The five conditions above close the implementation gaps without
requiring structural redesign.

— yume-tech-director, 2026-05-12
