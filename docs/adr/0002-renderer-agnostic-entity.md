# ADR 0002 — Entity extends Node (renderer-agnostic)

_Date: 2026-05-01_
_Status: accepted_

## Context

W1 originally had `Entity extends Node2D`. Position lived in Node2D's
built-in `position: Vector2`. This worked for the 2D renderer
(Sprite2D as Entity child auto-inherits transform).

W5.0 (renderer_3d) review surfaced the problem: to support 3D in a
clean way, the natural move would be `entity_3d.gd` as a `Node3D`
variant of Entity. **But that violates ADR 0001 (invariant #3 — no
entity-class hierarchy).** Two Entity classes is the same anti-pattern
as Agent/Item/Projectile.

The independent W5.0 reviewer flagged this as architectural debt
incurred at W1 that would be paid at W5.0 with much higher cost
(weeks of refactoring vs days). Recommended fix: do the refactor
**now** as W1.14, before W2 builds motion + input + signal logic on
the Node2D-implicit Entity.

## Decision

Entity is `extends Node` — no positioned base, no transform of its own.
Position lives in `state.position` as Vector2 or Vector3 — pure data.

Renderer attaches a positioned child node (Sprite2D for renderer_2d,
MeshInstance3D for renderer_3d) and reads `entity.get_position()` each
`_process` to update its own `position`. Same Entity class, different
visual children.

Helpers added to Entity:
- `get_position()` → Variant (Vector2 or Vector3)
- `set_position(p)` → normalized to Vector2/Vector3
- `get_planar_position()` → Vector2 (XZ projection from Vector3)
- `get_velocity()` / `set_velocity(v)` → similar dimension-agnostic
- `snapshot()` serializes position as Array length 2 or 3

W5.0 coordinate convention: 2D `Vector2(x, y)` ↔ 3D `Vector3(x, 0, y)`.
Y in 3D is height (decorative — terrain heightmap output). Distance
and contact queries operate on planar XZ projection. This means a
`radius: 1.5` in any demo means 1.5 planar units in either renderer.

## Consequences

**Positive:**

- Same Entity class in 2D and 3D scenes. Invariant #3 honored.
- Smoke test added (`test_renderer_agnostic` — W1.14e): Entity is
  `Node`, NOT `Node2D` or `Node3D`. Position round-trips Vector2 +
  Vector3. Lets future regressions be caught immediately.
- Unblocks W5.0 (3D renderer) cleanly. World refactored to
  `extends Node` so same script powers both 2D and 3D scenes.
- Position is data — serializable, queryable, formula-readable
  via `self.state.position.x`.

**Negative:**

- Renderer must sync position each frame (`_process`). Tiny per-frame
  overhead vs Node2D's parent-transform inheritance. Acceptable at
  current entity counts (~50/scene).
- Tests using `is Node2D` / `is Node3D` need a Variant cast workaround
  for GDScript's static checker.

**Neutral:**

- Mixing 2D and 3D positions in one scene works (tests confirm) but
  isn't a design goal — pick one renderer per scene.
- 3D scenes pay a `position_scale` factor (default 0.05) to map
  pixel-scale 2D positions into 3D world units. Configurable via
  scene exports.

## Alternatives considered

**A. Stay with Entity extends Node2D + add Entity3D for 3D scenes.**
Violates ADR 0001 invariant #3. Killed.

**B. Entity extends `Node`, but position lives on a separate Transform
component.** Component-based ECS. More flexible but adds an indirection
layer Yume doesn't otherwise need. Killed — overkill at this scale.

**C. Defer to Tier 4.3 (3D as polish).** Original plan position. The
reviewer convinced us to pull renderer_3d forward into W5 because:
(a) acid test claims renderer-agnosticism — only proven across 2D
demos is a weaker claim; (b) months of colored circles erodes
motivation; (c) 2D-implicit assumptions sneak in if not caught
early. Killed in favor of W5.0 promotion.

## References

- ADR 0001 (the seven-primitives + invariant #3 decision)
- `docs/30_framework_primitives.md` § "Tick ordering" + invariant #3
- `docs/timeline/entries/16_renderer_3d_promoted.js` — W5.0 promotion
- `docs/timeline/entries/17_renderer_3d_review_fixes.js` — review that surfaced this debt
- `archetypes/core/templates/godot/scripts/engine/entity.gd` — implementation
- `archetypes/core/templates/godot/scripts/engine/tests/test_runner.gd::test_renderer_agnostic`
- Commit `a766186` (W1.14 through W5.1 landing)
