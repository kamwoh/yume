# ADR 0004 — `blocks_motion` tag for static obstacles

_Date: 2026-05-03_
_Status: proposed_

## Context

The level-designer skill (Tier 2.7) lets games declare arena
geometry — walls, pillars, cover. doomarena3d v2.5 ships 4 walls +
4 pillars + 1 floor as entities with the `wall` / `pillar` /
`structure` tags. They render correctly, frame the arena, and
serve as visual reference points.

But user playtest (2026-05-03): "the obstacle should be 'obstacle'
right? but i can pass through it." The pillars and walls are
decorative only. The motion integrator advances every entity by
its velocity each tick without checking for entity-vs-entity
collision. There is no engine vocabulary for "this entity is solid
— don't let other entities walk through it."

Adding it inside content (per-game collision rules) is wrong for
two reasons:
1. Every game with arena geometry would re-implement the same
   AABB-vs-AABB sweep. Composition fails.
2. The motion integrator is engine-built-in (not a rule); a
   collision check belongs alongside it for ordering correctness.

So this is a **primitive expansion**, not a content patch.

## Decision

Introduce a tag-driven blocking convention:

- **Tag**: `blocks_motion` — entity is a static obstacle.
- **Properties**: `aabb_extents: [hx, hy, hz]` — half-extents of an
  axis-aligned bounding box centered at the entity's position. For
  Vector2 entities, `[hx, hy]` (Z is ignored — top-down 2D arenas).
- **Engine behavior**: in `_integrate_motion`, after computing each
  moving entity's new position from velocity, sweep against all
  `blocks_motion` AABBs. If the new position would intersect, slide:
  try the X-component alone, then the Z-component alone (separate
  axes — standard "swept AABB lite"). If both blocked, stay put.
- Entities that should themselves be obstructed need no opt-in
  flag; all velocity-bearing entities are tested. (Future: opt-out
  flag `ignores_obstacles` for projectiles that should pass through
  walls — initial v1 just lets bullets get blocked too, which is
  realistic for a Doom-style FPS.)

doomarena3d's wall + pillar entity defs add `blocks_motion` tag
plus `aabb_extents` properties. No content changes elsewhere.

## Consequences

**Enables:**
- Real arena geometry — pillars give cover, walls bound movement,
  player can hide behind a column from a ranger's bullets.
- Future TD games can use `blocks_motion` for tower-occupied tiles.
- Future puzzle games (push-blocks, sokoban-3d) can check
  `blocks_motion` collisions for "can I push this box" gating.

**Costs:**
- Per-tick O(N×M) sweep (N = moving entities, M = blockers). For
  doomarena3d at peak that's ~30 × 9 = 270 checks/tick. Negligible.
  If this scales beyond ~10k tests, future work adds spatial-index
  query for blockers (already have SpatialIndex; trivial extension).
- Bullets currently treat walls as solid in this v1 — they'll stop
  at wall faces. This may surprise content authors who expect
  bullets to fly through. Mitigation: well-placed pillars + walls
  shouldn't create wedge points where bullets stack. If it becomes
  a problem, add `ignores_obstacles` opt-out tag in v2.
- Sliding behavior is approximate (no swept Minkowski). Fast-moving
  entities at oblique angles may "tunnel" through thin walls. With
  tick=0.05 and player speed 3 m/s = 0.15 m/tick, and walls 0.5 m
  thick, tunneling is possible only at extreme angles. Acceptable
  for arcade-feel. If tunneling becomes a real problem, add
  CCD-style swept check.

**Updates needed:**
- `docs/30_framework_primitives.md` — add `blocks_motion` to the
  tag-convention list under Effect / Motion.
- `.claude/rules/data-demo.md` — add an example showing
  `aabb_extents` properties for a wall.
- Tests — `tests/test_runner.gd` adds a test_blocks_motion section:
  spawn a wall, place a creature behind it, push toward wall →
  creature stops at wall, doesn't tunnel.

## Alternatives considered

**A) Full physics engine (Godot's PhysicsServer3D).** Massive
overkill for Yume's "discrete tick + JSON simulation" identity.
Pulls in collision shapes, layers, masks — none of which are
JSON-authorable. Rejected.

**B) Per-game collision rules (no engine change).** Each game
writes a tick rule that scans `tags_all: ["blocks_motion"]` and
adjusts position. Doable but: (1) every collision-aware game
duplicates the rule body; (2) timing is wrong — rule runs in
decide phase, motion integrator runs after, so collision check
fights with motion update. Rejected.

**C) Rectangular bounds clamp per-game** (existing pattern).
`creature_bounds` clamps creatures to ±21 m. Works for outer
arena bounds but doesn't help with internal pillars. The pillar
case is what motivates the new primitive.

**D) Defer to future.** Acceptable v1 — pillars stay decorative.
But user explicitly flagged the gap, and the level-designer skill
already names obstacles as obstacles. Implementing the engine
side closes the design-vs-runtime contract.

Decision: implement (C → D rejected; A → B rejected).
