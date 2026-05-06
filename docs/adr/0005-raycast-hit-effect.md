# ADR 0005 — `raycast_hit` effect (hitscan weapons)

_Date: 2026-05-04_
_Status: accepted (landed 2026-05-04)_

## Context

Yume's existing weapon model is **projectile-only**: each fire spawns
a bullet entity that flies through space, gets contact-tested per
tick, and despawns on hit / lifetime / wall. This works well for
slow projectiles (rockets, plasma) where travel time is part of the
gameplay.

It works less well for **fast bullets** — rifles, lasers, hitscan
weapons in CS:GO / Valorant / Call of Duty. At realistic muzzle
velocities (~800 m/s) a bullet would cross a 30m room in 38ms — well
under one tick at tick_seconds=0.05. The projectile entity is
visible for one tick (a flash of yellow) and then gone, but its
contact resolution is identical to a slow bullet.

Two specific problems:
1. **Hit timing**: at 22 m/s (current plasma speed), a player's bolt
   takes 1.4s to cross the arena. Visible travel = strategic depth
   (enemies dodge), but for a "rifle" it would feel sluggish.
2. **Sub-tick precision**: contact resolution happens at tick
   boundaries. A player aiming through a moving target's narrow
   window can miss because the bullet entity is one tick behind the
   aim. Hitscan weapons fix this — the hit is computed in the same
   tick the trigger fires.

A "raycast" or "hitscan" weapon casts a ray from the firer in the
aim direction, finds the first entity (or wall) hit, and applies
effects directly. No projectile entity. Standard FPS pattern.

## Decision

Add a new effect type **`raycast_hit`** to the engine. JSON shape:

```jsonc
{
  "type": "raycast_hit",
  "origin": [<x>, <y>, <z>],          // formula or array
  "direction": [<dx>, <dy>, <dz>],    // formula or array (need not be unit)
  "max_distance": 30.0,
  "tags_all": ["monster"],            // entity must match these
  "tags_none": ["dead"],               // entity must NOT match
  "respect_obstacles": true,           // raycast also tests blocks_motion AABBs
  "on_hit": [
    {"type": "state_add", "target": "hit", "field": "hp", "amount": -2},
    {"type": "spawn", "template": "particle_spark",
     "position": ["hit.state.position.x", 1.0, "hit.state.position.z"]}
  ],
  "on_miss": [
    {"type": "spawn", "template": "particle_spark",
     "position": "hit_point"}     // synthetic position at ray endpoint
  ]
}
```

Engine behavior:
1. Resolve `origin` + `direction` (formula support — typical:
   firer position + facing-derived forward vector).
2. Walk all entities matching `tags_all` / `tags_none` (with
   spatial-index narrowing if available).
3. For each candidate, compute ray-AABB intersection (treating the
   entity as a sphere with `properties.body_radius` or default 0.4
   — same convention as motion integrator).
4. If `respect_obstacles=true`, also test ray against `blocks_motion`
   AABBs. The first wall closer than the closest hit caps the ray.
5. The closest valid hit becomes the binding `hit` for `on_hit`
   effects. `hit_point` (Vector3 of the actual ray-hit position) is
   available as a magic name in `on_miss` and `on_hit`.
6. If no hit, run `on_miss` effects (typically a wall-impact spark).

## Consequences

**Enables:**
- Hitscan weapons (rifles, lasers, sniper) in shooter-genre games
  with frame-perfect timing and no visible projectile.
- AI line-of-sight checks: an `is_visible` query becomes
  `raycast_hit` with `target=player` and `respect_obstacles=true`.
- Tower-defense laser towers (continuous beam vs nearest enemy in
  range).

**Costs:**
- Per-tick O(N+M) ray-vs-sphere + ray-vs-AABB tests where N =
  candidate entities, M = blockers. Cheap (≤300 ops / firing tick
  at typical doomarena3d entity count). No per-tick cost when no
  raycast effect is active (only fires on triggered effects).
- A new effect verb means JSON authors have one more thing to
  learn. Mitigated by: pairs naturally with the existing `spawn`
  effect (use `spawn` for visible projectiles; use `raycast_hit`
  for instant). Documentation: shooter-designer skill mentions
  this in the weapon-arsenal table.
- Sub-tick "lead" tactics that work for projectile weapons (aim
  ahead of moving target) become irrelevant for hitscan weapons —
  by design.

**Updates needed:**
- `effect_apply.gd` — add `raycast_hit` dispatch + implementation
- `docs/30_framework_primitives.md` — list as effect, mark hitscan
  category
- `docs/engine-reference/api-manifest.json` — auto-regen will pick
  up the new effect from source
- `.claude/skills/yume-shooter-designer/SKILL.md` — weapon arsenal
  table can now distinguish projectile vs hitscan in the
  ballistic column
- Tests: `test_runner.gd` adds a section that fires a raycast at a
  positioned target, asserts hit, asserts wall-blocked behavior

## Alternatives considered

**A) Synthetic high-speed projectile entity.** Bullet at 1000 m/s,
lifetime 1 tick. Solves "instant hit" via single-tick traversal.
Costs: still spawns an entity, contact still computed at tick
boundary, sub-tick precision lost on fast-moving targets. Rejected.

**B) Add a "trace" trigger that scans rays each tick.** Inverts the
direction — instead of firing a ray on input, the engine traces
rays along certain configurations. Too generic; trigger types
should be event-shaped (input, contact, tick), not query-shaped.
Rejected.

**C) Defer entirely (status quo).** Yume has been shooter-shaped
fine without hitscan. Slow projectile is a design choice. Cost:
shooter-genre games that want hitscan-feeling weapons (rifle,
laser) have no way to express it. Limits genre coverage.
Rejected — shooter-reviewer's S2 (ballistic distinctness) axis
implies a richer weapon vocabulary, of which hitscan is a major
class.

## Implementation sketch (~80 lines + tests)

```gdscript
static func _raycast_hit(e: Dictionary, env: Dictionary, ctx: Dictionary):
    var origin: Vector3 = _to_vec3(_value(e.get("origin"), ctx, env))
    var direction: Vector3 = _to_vec3(_value(e.get("direction"), ctx, env))
    if direction.length() < 1e-6: return
    direction = direction.normalized()
    var max_d: float = float(_value(e.get("max_distance", 100.0), ctx, env))
    var tags_all: Array = e.get("tags_all", [])
    var tags_none: Array = e.get("tags_none", [])
    var respect_obstacles: bool = bool(e.get("respect_obstacles", true))

    # Ray-vs-blockers: cap distance
    var blocker_t: float = max_d
    if respect_obstacles:
        var blockers = World._collect_blockers_static(env)  # helper
        for b in blockers:
            var t = _ray_aabb_t(origin, direction, b)
            if t > 0 and t < blocker_t: blocker_t = t

    # Find closest entity hit
    var closest_t: float = blocker_t
    var hit_id: String = ""
    var entities = env.get("entities", {})
    for id in entities:
        var ent = entities[id]
        if not ent.matches_tags(tags_all, tags_none): continue
        var radius = ent.get_property("body_radius", 0.4)
        var t = _ray_sphere_t(origin, direction, ent.get_position(), radius)
        if t > 0 and t < closest_t:
            closest_t = t; hit_id = id

    var hit_point = origin + direction * closest_t
    var sub_ctx = ctx.duplicate()
    sub_ctx["hit_point"] = hit_point
    if hit_id != "":
        sub_ctx["hit"] = hit_id
        for sub in (e.get("on_hit", []) as Array):
            apply(sub, env, sub_ctx)
    else:
        for sub in (e.get("on_miss", []) as Array):
            apply(sub, env, sub_ctx)
```

Tests (5-8 assertions):
- ray hits entity → on_hit fires, hit binding resolves
- ray hits wall first → on_miss fires (wall caps before entity)
- ray missing all → on_miss fires
- tags_all filter excludes non-matching entities
- max_distance respects truncation

## Future extensions (not in this ADR)

- **Pierce**: pass through N entities before stopping (railgun-feel)
- **AOE on hit point**: explosion damages all entities within
  radius of hit_point (rocket-style splash)
- **Beam visualization**: spawn a transient line entity for visible
  laser effects
- **Multi-ray** (shotgun-like hitscan with spread): fire N rays in
  a cone pattern via a single effect

These compose on top of `raycast_hit` and are content-level (use
multiple effects) or future ADRs (engine-level).

## ADR 0021 compliance audit (2026-05-06)

Same audit as ADR 0004: ADR 0021 ("Yume = JSON layer over Godot +
external") was accepted 2026-05-06, after this ADR landed.

**Compliance status: PARTIAL — implementation reimplements what
Godot already provides.**

This ADR's engine implementation (`_raycast_hit` in
`effect_apply.gd`) does ray-AABB intersection in custom GDScript.
Godot has:

- `PhysicsDirectSpaceState2D.intersect_ray()` /
  `PhysicsDirectSpaceState3D.intersect_ray()` for native raycasting
- BVH-based broadphase (faster than iterating all entities)
- Returns first-hit collider with normal + position

Per ADR 0021, `raycast_hit` SHOULD compose Godot's `intersect_ray`
rather than reimplement ray-AABB math.

**Why we're not refactoring immediately:**

1. **Working code**. Tested + shipped (doomarena3d ranger fire +
   bullet trajectory).
2. **Performance is adequate at current scale**.
3. **Migration timing**. Refactor alongside ADR 0004 when ADR
   0022 (Godot rigid-body physics integration) lands. The blockers
   iteration logic is shared with blocks_motion; both convert to
   PhysicsServer queries together.

**Action**: flag as ADR 0021 compliance debt. When ADR 0022 lands,
`raycast_hit` becomes a thin wrapper over
`PhysicsDirectSpaceState.intersect_ray()`. The effect's JSON
contract (target, dx/dy, on_hit field-set) stays unchanged. Backward-
compatible from the content side.

**Status: accepted (with compliance debt logged for ADR 0022 era)**
