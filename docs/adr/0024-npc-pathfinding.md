# ADR 0024 — NPC pathfinding via Godot's NavigationServer3D

_Date: 2026-05-07_
_Status: accepted (shipped — `scripts/engine/pathfinding.gd`, 2026-05-09)_

## Context

The kingdom-sim merchant game ships with 50+ named NPCs walking
Pendrel city on daily schedules (GDD: `docs/games/merchant/GDD.md`).
Each NPC needs to route from a home tile to a workplace tile, then
to a market tile, then to an inn — past buildings, fences, and other
NPCs. Yume's current motion stack is:

1. `velocity_set` / `velocity_set_relative` effects — write a Vector2/Vector3
   into `entity.state.velocity`.
2. `World._integrate_motion` — each frame, advance position by velocity.
3. `blocks_motion` AABB slide (ADR 0004) — if the new position
   intersects a static obstacle, slide along separate XZ axes.

This is fine for shooter creatures (homing imps in doomarena3d,
which want to push into the player along a roughly-straight line) and
for top-down arcade movement. It **breaks** as soon as you ask:
"NPC, walk from this corner of the city to the OTHER corner, going
**around** these four buildings." Straight-line + axis slide deadlocks
in any concave corridor; the NPC pushes against a wall, slides to the
end, hits the perpendicular wall, and stops — never reaching the goal.

Per ADR 0021, Yume's policy is **expose, don't reimplement**. Godot
4.6.1 ships a complete navigation stack:

- `NavigationServer3D` — global navigation map registry, async path
  queries, agent avoidance.
- `NavigationRegion3D` — node that contributes a `NavigationMesh`
  resource into a navigation map.
- `NavigationMesh` — polygon set defining walkable surfaces.
- `NavigationAgent3D` — node attached to a moving body that holds a
  current `target_position` and exposes `get_next_path_position()`
  (the next waypoint to head toward).

We need a JSON-declarative interface to this stack. Reimplementing A*
in pure GDScript is rejected by ADR 0021 and would also miss the
RVO-style avoidance built into NavigationAgent3D.

## Decision

Add three pieces of vocabulary to the engine, all wired to
NavigationServer3D / NavigationRegion3D / NavigationAgent3D:

### 1. Engine-recognized tag — `walkable_floor`

Entities with this tag contribute a walkable rectangle to the level's
NavigationMesh. The rectangle is computed from `entity.position` (XZ
center) and `properties.aabb_extents` (XZ half-extents — the Y extent
is ignored; the floor is always at `position.y`). At least one entity
with this tag must exist for pathfinding to be enabled in a level.

### 2. Engine-recognized tag — `pathfinding_obstacle`

Entities with this tag punch a hole in the walkable region. Same
geometry source as `walkable_floor` (`position` + `aabb_extents`).
**Distinct from `blocks_motion`**: a wall typically wants both
(blocks pushing AND blocks routing through), but a low fence might
have `blocks_motion` only (motion integrator handles it) or
`pathfinding_obstacle` only (NPCs path around it but bullets fly
over). Authors mix-and-match per intent. The primitives compose.

### 3. New effect — `pathfind_to`

```json
{
  "type": "pathfind_to",
  "target": "self",
  "destination_x": 100.0,
  "destination_y": 0.0,
  "destination_z": -50.0,
  "speed": 2.0
}
```

Each invocation:

1. Lazily attaches a `NavigationAgent3D` child to the target entity
   (idempotent — re-uses an existing agent if present).
2. Sets `agent.target_position = (destination_x, destination_y, destination_z)`.
3. Reads `agent.get_next_path_position()` — the next waypoint along
   the computed path.
4. Computes direction = `(next_path_point − entity.position).normalized()`,
   then sets `entity.velocity = direction * speed`.
5. The existing `_integrate_motion` step advances the entity along
   that velocity; the existing `blocks_motion` slide is a safety net
   for edge cases where the navmesh doesn't perfectly cover collision
   geometry.

Per-tick invocation pattern (typical NPC walks):

```jsonc
{
  "id": "npc_walk_to_workplace",
  "trigger": {"type": "tick", "interval": 1},
  "query": {"tags_all": ["villager"], "state": {"goal_x_exists": 1}},
  "effect": {
    "type": "pathfind_to",
    "target": "self",
    "destination_x": "self.state.goal_x",
    "destination_y": "self.state.goal_y",
    "destination_z": "self.state.goal_z",
    "speed": 2.0
  }
}
```

`destination_x/y/z` and `speed` accept formula bindings, so the
destination can be data-driven from NPC schedule state without
hardcoding coordinates in rules.

### Engine wiring

A new module `scripts/engine/pathfinding.gd` (a `RefCounted`,
following `EffectApply` / `Query` style) exposes three static methods:

- `build_navmesh_for_level(env)` — called from `World._load_level`
  AFTER entities are loaded. Scans `env.entities` for `walkable_floor`
  and `pathfinding_obstacle` tags, constructs a `NavigationMesh`
  resource by tessellating the union of walkable rectangles minus
  obstacle rectangles, instantiates a `NavigationRegion3D` node as a
  child of `env.parent` (the World), assigns the mesh, and stores
  the region reference in `env._navigation_region` so it can be
  destroyed on level transition. No-op if no `walkable_floor`
  entities exist (legacy levels keep old behavior).

- `attach_agent_to_entity(env, entity)` — idempotent. If `entity`
  doesn't already have a `NavigationAgent3D` child, creates one,
  binds it to the level's navigation map, sets sensible defaults
  (`path_max_distance = 1.0`, `target_desired_distance = 0.5`).

- `tick_pathfind(env, entity, dest_x, dest_y, dest_z, speed)` —
  ensures agent is attached, sets target_position, reads the next
  path point, and writes velocity onto the entity. Called by
  `EffectApply._pathfind_to`.

`EffectApply.apply()` adds a `"pathfind_to"` arm to its match
dispatch that delegates to `Pathfinding.tick_pathfind`.

`World._load_level` calls `Pathfinding.build_navmesh_for_level(env)`
after `_load_entities_path` returns. `World._do_level_transition`
deletes the existing region (`env._navigation_region.queue_free()`)
before the new level loads.

### 2D fallback

Yume's 2D demos use straight-line motion + `blocks_motion`. The
pathfinding stack is **3D-only** in v1: `pathfind_to` is a no-op
(does not raise, does not modify velocity) when the target entity's
position is a Vector2. `build_navmesh_for_level` skips work when no
`walkable_floor` entities exist — and 2D games simply don't tag any.

NavigationServer2D + NavigationRegion2D exist in Godot but require
parallel plumbing. Deferred to a follow-up ADR if a 2D game needs
pathfinding.

## Consequences

### Enables

- 50+ NPCs walking around buildings in kingdom-sim without hand-authored
  waypoint routes.
- RVO-style local avoidance between NPCs (NavigationAgent3D handles
  it via `avoidance_enabled = true` — defaults on).
- Dynamic obstacles: tagging an entity `pathfinding_obstacle` at
  spawn rebuilds nothing per-frame, but the navmesh CAN be rebuilt
  on a tick rule if the game wants doors or movable furniture.
- Composability with existing tags: `blocks_motion` for collision,
  `pathfinding_obstacle` for routing, `projectile` for stop-dead —
  any combination is legal.

### Precludes

- Free-form 3D navigation (flying, swimming, climbing) — v1 is XZ
  plane only. NavigationMesh in 4.6 supports 3D in principle but our
  level-build code projects to a flat surface.
- Path post-processing (smoothing, lookahead) — we follow whatever
  NavigationAgent3D returns. If results look jagged, tune
  `agent.path_max_distance` per-game.

### Tests ship with the change

Per `.claude/rules/tests.md`, new primitives land with unit tests:

1. `test_pathfind_builds_navmesh` — env with `walkable_floor` +
   `pathfinding_obstacle` entities; after `build_navmesh_for_level`,
   a NavigationRegion3D child of env.parent exists with a
   NavigationMesh whose vertex/polygon counts match the geometry.

2. `test_pathfind_to_routes_around_obstacle` — entity at origin with
   destination on the far side of an obstacle. After
   `tick_pathfind` runs, the entity's velocity points toward an
   intermediate waypoint (NOT a straight line through the obstacle).

3. `test_pathfind_no_op_on_2d` — entity with a Vector2 position;
   `pathfind_to` doesn't raise and doesn't mutate velocity.

## Alternatives considered

**A. Pure-GDScript A* on a grid.** Rejected per ADR 0021 — Godot
ships a tested navigation stack with avoidance; reimplementing it
duplicates surface area and likely regresses on edge cases (steiner
points, dynamic regions). Also slower for 50+ agents.

**B. Straight-line + retry on stuck.** Rejected — empirically looks
broken with many agents (NPCs visibly walk into walls and stop).
The merchant game's "city feels alive" success criterion fails
without real routing.

**C. Single global "follow waypoint chain" effect.** Each NPC
schedule pre-bakes a waypoint chain at level load; the engine just
walks the chain. Rejected — doesn't handle dynamic obstacles
(another NPC standing in your path), avoidance, or schedule
re-planning. Also pushes A* into level-design tooling, which is
where ADR 0021 says it shouldn't go.

**D. Use Godot's CharacterBody3D + move_and_slide() instead of
custom motion integrator.** Larger refactor. ADR 0004's slide is
working for the existing demos and isn't broken — only
pathfinding is missing. Keep the motion integrator as the
collision layer; layer NavigationAgent3D as the routing layer
on top. If a future ADR retires the custom integrator, this design
still holds.

## References

- ADR 0004 — `blocks_motion` tag + AABB slide (motion-resolution
  layer this design composes with).
- ADR 0021 — Yume as JSON layer over Godot (the policy that
  forbids reimplementing NavigationServer3D).
- Godot docs: `NavigationServer3D`, `NavigationAgent3D`,
  `NavigationRegion3D`, `NavigationMesh`.
