# ADR 0015 — Vehicle physics primitive (mass + momentum + collision response)

_Date: 2026-05-06_
_Status: **proposed**_

## Context

The contract states "no continuous physics (driving sims, soft-body)
out of scope." This rules out Forza-tier vehicle dynamics (tire grip
slip-angles, weight transfer, suspension travel, deformation). It
does NOT rule out **arcade-level Newtonian physics**: mass + momentum
+ elastic collision.

Currently Yume's `blocks_motion` (ADR 0004) implements solid walls
that simply STOP a moving entity. This is fine for puzzle games but
fails for any game where:

- Cars hit pedestrians and the pedestrian gets knocked aside
- Two cars collide and exchange momentum
- Heavy entities push light entities
- A car bounces off a wall instead of just stopping
- Force-based effects (explosion knockback, projectile impulse)

These all share the same engine need: **collision response that
respects mass + velocity**, producing post-collision velocities for
both participants based on conservation of momentum.

This ADR adds a `physics_dynamic` tag (parallel to `blocks_motion`)
that opts an entity into mass-based collision response with other
`physics_dynamic` or `blocks_motion` entities. Static walls
(`blocks_motion` only) reflect dynamic entities; dynamic-dynamic
collisions exchange momentum.

## Decision

Add **`physics_dynamic` tag** + supporting properties + engine
collision-response handler.

### Tag + property convention

```jsonc
{
  "id": "car",
  "tags": ["car", "physics_dynamic", "blocks_motion"],
  "properties": {
    "mass": 1500.0,                      // kg-equivalent
    "restitution": 0.3,                  // 0=inelastic, 1=elastic bounce
    "aabb_extents": [25, 1.5, 12]        // existing blocks_motion convention
  },
  "state_init": {
    "facing": 0,
    "velocity": [0, 0]
  }
}
```

For static walls: `tags: ["wall", "blocks_motion"]` only — no
`physics_dynamic`. They have effective mass infinity; dynamic
entities bounce off them based on their own restitution.

For pedestrians: `tags: ["pedestrian", "physics_dynamic"]` with low
mass (~70 kg). When hit by a car (1500 kg), the pedestrian inherits a
significant velocity.

### Engine work

1. `scripts/engine/physics_response.gd` — new module:
   - On collision detection (extends current contact rule pair-match
     in scheduler), if both entities are `physics_dynamic`:
     compute conservation-of-momentum + restitution
   - If one is `physics_dynamic` and the other is `blocks_motion`-only:
     reflect the dynamic's velocity per restitution
   - Apply resulting velocities via `velocity_set` effects (queued
     into the effect buffer per existing ordering)

2. Math (2D Newtonian elastic collision):
   ```
   m1, m2 = masses
   v1, v2 = velocities (Vector2 or Vector3)
   normal = (pos1 - pos2).normalized()
   v_rel = (v1 - v2).dot(normal)
   if v_rel > 0: return  // already separating
   e = min(restitution1, restitution2)
   j = -(1 + e) * v_rel / (1/m1 + 1/m2)
   v1' = v1 + (j / m1) * normal
   v2' = v2 - (j / m2) * normal
   ```

3. Collision detection: extend existing AABB overlap check
   (`blocks_motion` already does this) to emit a "collision_pair"
   event when both entities have `physics_dynamic`. Engine then
   computes response.

4. New effect type (optional convenience):
   ```jsonc
   {"type": "apply_impulse", "target": "self", "vector": [10, 0, 0]}
   // Adds vector * (1/mass) to velocity. Used for explosions / kicks.
   ```

5. Velocity inheritance check: when a `physics_dynamic` entity is
   hit, its velocity field is mutated by the engine. Existing
   per-frame motion integration (velocity → position) handles the
   visual.

### Backward compat

Existing entities work unchanged. `physics_dynamic` is opt-in. If no
entity in a game has the tag, no collision-response code runs.

`blocks_motion`-only entities continue to act as solid walls (their
collision response = full reflection of incoming dynamic).

### Composition with existing ADRs

- **ADR 0004 (blocks_motion)** — coexists. blocks_motion is
  "occupies space"; physics_dynamic adds "responds to collisions
  Newtonianly."
- **Vehicles, projectiles, ragdolls** — all just entities tagged
  appropriately. Pedestrian struck by car: car has high mass,
  pedestrian has low mass; momentum exchange + integration → ped
  flies aside.

## Consequences

**Enables:**
- Vehicle-pedestrian interactions (GTA-flavor)
- Multi-car pile-ups
- Knockback from explosions
- Push physics (player shoves a barrel)
- Ragdoll-lite (entity gets velocity, animation swaps to "knocked
  down" sprite)

**Constrains:**
- Only AABB collisions; no convex polygon shapes. Sufficient for
  most arcade purposes.
- Mass values are gameplay numbers, not real-world physics. No
  conservation-of-energy guarantees in long simulations
  (acceptable; arcade aesthetic).
- No suspension / tire model / weight transfer. Cars feel like
  arcade-physics objects, not Forza vehicles.

**Doesn't enable:**
- Sim racing (out of scope per contract)
- Continuous-physics rope / cloth / fluid
- Realistic damage deformation

## Alternatives considered

### A. Per-game collision-response rules

Could express momentum exchange via formula effects in JSON. Tried
mentally; the math is per-pair (each collision needs both entities'
state); rule-based doesn't naturally express it. Engine code is the
right place.

### B. Integrate Box2D / Bullet

Real physics engine. Rejected: out of scope (introduces continuous
physics + scope explosion). Arcade response is sufficient.

### C. Make all `blocks_motion` entities dynamic by default

Conflates "solid" with "responds to forces." Walls would gain mass
and could be moved. Rejected: most walls are static; convenience of
opt-in tag preserves clarity.

## References

- ADR 0004 (blocks_motion tag) — orthogonal; both can coexist
- ADR 0014 (open-world substrate) — vehicles need this for
  interactive open worlds
- Yume non-goals doc — confirms continuous physics out of scope; this
  ADR is bounded to discrete-time momentum exchange

## Tech-director review

_Date: 2026-05-06_
_Reviewer: yume-tech-director_

### Invariant checks

| Invariant | Status | Notes |
|---|---|---|
| #1 JSON-only content channel | ✓ | mass / restitution are properties; tag is content |
| #2 No semantic effect types | ✓ | `apply_impulse` is generic vector→velocity; not a semantic verb |
| #3 No entity-class hierarchy | ✓ | physics_dynamic is a tag, not a class |
| #5 Queries first-class | ✓ | tag-based query for collision pair detection |
| #8 Engine = primitives + interpreter | ⚠ | adds collision-response math to engine; bounded but real |
| #9 Phase ordering | ⚠ | collision response queues velocity_set effects; need explicit phase placement |

### Concerns

1. **Where's the line on continuous physics?** This is the most
   important unanswered question. Newtonian discrete collision
   response is fine. But this ADR opens the conceptual door:
   "well, if we have mass + momentum, why not friction-aware
   sliding? Why not suspension? Why not continuous integration?"
   Without an explicit "never list," each future ADR has to
   re-litigate the boundary.

2. **`physics_dynamic` semantic ambiguity**. The ADR's narrative
   says "pedestrian inherits velocity" but the math (j/m * normal)
   gives an impulse. These are different — impulse gives a kick;
   inheritance gives full coupling. Authors will mistune unless
   the ADR is explicit.

3. **Performance budget unspecified**. Pair-resolution is
   potentially O(n²) without spatial partitioning. Spatial index
   narrows but doesn't eliminate. At 100 dynamic entities, ~5000
   potential pairs per tick. Need budget statement: "engine targets
   ≤16ms total physics-response time at 100 dynamic entities."

4. **Phase ordering interaction with Invariant #9**. Collision
   response generates velocity_set effects. Where in the tick
   pipeline do these queue? Same react phase as contact rules?
   Or separate? If react, the existing flush rules apply — fine.
   If a separate "physics phase" is added, that's a phase ordering
   change requiring its own scrutiny.

5. **`blocks_motion` integration**. ADR says dynamic vs
   blocks_motion-only = reflection. Spec the reflection: full
   elastic? restitution-modulated? If a 1500kg car hits a 1500kg
   wall (technically infinite), what's the post-velocity?
   Probably v' = -v * restitution. Make explicit.

6. **Velocity inheritance vs impulse semantics** (concern #2 detail).
   Recommend: collision response is IMPULSE-based always
   (post-velocity = pre-velocity + impulse/mass * normal). Authors
   tune mass ratios to get inheritance-like effects (heavy-on-light
   ≈ inheritance). Document this clearly so authors don't expect
   "set velocity = the other's velocity."

### Verdict

**accept-with-conditions**.

Conditions before implementation:

1. **Add explicit "never list" of physics features Yume will not
   implement**: continuous force integration over time (springs,
   suspension), constraint solvers (joints, ropes), continuous-time
   deformation (soft body), sub-tick continuous collision detection
   (CCD). State these in the ADR. This anchors future scope debates.
2. **Clarify impulse vs inheritance semantics**: math is impulse-
   based; inheritance is the perceptual outcome at heavy-vs-light
   mass ratios. Document explicitly.
3. **Performance budget**: spec ≤16ms physics-response time at 100
   dynamic entities; CI/perf test should track this.
4. **Phase ordering**: collision response runs in react phase as
   queued velocity_set effects (composes with existing flush rules).
   Don't introduce a new phase.
5. **`blocks_motion` reflection spec**: post-velocity = pre-velocity
   reflected over collision normal, scaled by restitution. Wall has
   effective mass ∞.
6. **Mass property contract**: must be > 0 (engine errors on mass=0
   for physics_dynamic entities).

This is a contract-edge ADR. The "never list" is critical. Without
it, the next ADR (0020? 0030?) erodes the boundary.
