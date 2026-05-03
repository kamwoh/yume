# DoomArena — World Plan

_Date: 2026-05-03_
_Planner: yume-game-planner_
_GDD: docs/games/doomarena/GDD.md_

## Cast (named entities)

| Entity ID | Display | Tags | Role |
|---|---|---|---|
| `arena_clock` | Arena Timer | `meta`, `clock` | Singleton. Tracks elapsed, spawn_timer, pickup_timer. |
| `player` | Marine | `player`, `creature` | The protagonist. WASD-controlled. HP/ammo/score state. |
| `monster_imp` | Imp | `monster`, `enemy`, `imp` | Common foe. 1 HP. Walks toward player at 60 px/s. |
| `monster_demon` | Demon | `monster`, `enemy`, `demon` | Rare. 2 HP. Slower (40 px/s). Tougher visual. |
| `bullet` | Plasma bolt | `bullet`, `projectile` | Spawned on shoot. lifetime=24 ticks. |
| `health_pickup` | Med Kit | `pickup`, `pickup_health` | +25 HP on contact. |
| `ammo_pickup` | Ammo Crate | `pickup`, `pickup_ammo` | +5 ammo on contact. |
| `particle_spark` | Spark | `particle`, `effect` | Transient. lifetime=18, fade_with_lifetime. |
| `wall_segment` | Arena wall | `wall`, `decor` | Static decoration around arena perimeter. |
| `spawn_marker` | Spawn point | `spawn_marker` | Invisible. Monsters teleport here. |

## Key state fields

| Entity | Field | Type | Notes |
|---|---|---|---|
| `player` | `hp` | float 0-100 | Starts at 100. -10 per monster contact. +25 per health pickup. |
| `player` | `ammo` | int 0-99 | Starts at 30. -1 per shot. +5 per ammo pickup. |
| `player` | `score` | int 0-30 | Kills counter. Win at 30. |
| `player` | `velocity` | Vector2 | WASD drives via velocity_lerp. drag=4.0 → quick stop. |
| `player` | `drag` | property 4.0 | Decelerates when no input. |
| `arena_clock` | `elapsed` | float | Seconds since start. |
| `arena_clock` | `spawn_timer` | float | Counts down. New monster when ≤0. Reset to 4.0-2.0 (decreases over time). |
| `arena_clock` | `pickup_timer` | float | Counts down. New pickup when ≤0. Reset to ~7.0. |
| `monster_*` | `hp` | int 1-2 | imp=1, demon=2. |
| `monster_*` | `velocity` | Vector2 | Set by homing rule each tick. |
| `bullet` | `lifetime` | int 24 | Auto-despawn at 0 (engine). |
| `bullet` | `max_lifetime` | int 24 | For fade_with_lifetime. |
| `particle_spark` | `lifetime` | int 18 | Same. |
| `particle_spark` | `max_lifetime` | int 18 | Same. |

## Visual silhouettes (asset-designer hints)

- **Player (Marine)**: cyan armored figure, 18px circle body + small triangle "head" + tiny rectangle "gun" jutting forward. `flip_with_velocity` AND `rotate_with_velocity` (face direction of last shot).
- **Imp**: small dark-red roundish blob (12px circle), 2 yellow eye dots. Menacing but not large.
- **Demon**: bigger dark-purple angular shape (18-20px), bulky.
- **Bullet**: bright yellow streak with motion-blur trailing rect. `rotate_with_velocity` so it points where it's going. `fade_with_lifetime` for soft fade.
- **Health pickup**: white square with red cross (medical symbol).
- **Ammo pickup**: yellow box with darker yellow stripe.
- **Particle**: 3px white-yellow circle. `fade_with_lifetime`.
- **Wall segment**: red angular bar (`#a02020`).
- **Spawn marker**: invisible (1px transparent).
- **Arena clock**: invisible.

## Town layout (arena)

Arena is 640×480 px (centered on origin). Player spawns at (0, 0).

**Spawn markers** at edges (8 of them):
- N edges: (-200, -240), (200, -240)
- S edges: (-200, 240), (200, 240)
- E edges: (320, -100), (320, 100)
- W edges: (-320, -100), (-320, 100)

**Wall segments** (decorative perimeter, ~12 segments forming the border):
- Top: 4 segments along y=-240 from x=-320 to x=320
- Bottom: 4 segments along y=240
- Left: 2 segments along x=-320
- Right: 2 segments along x=320

(Actual collision is via entity_bounds rule, not wall segments. Walls are decorative.)

## Event calendar

Not a calendar game — but pressure curve over the 90-second match:

| Time | Event |
|---|---|
| t=0 | Player spawns. Spawn timer = 4.0. |
| t=4 | First monster appears. |
| t=12 | First pickup appears (random — health or ammo). |
| t=30 | Spawn rate increases: spawn_timer reset = 3.0 (was 4.0) |
| t=60 | Spawn rate maxes: spawn_timer reset = 2.0 |
| t=90 | TIMEOUT — lose. |
| score=30 | WIN — instant. |
| HP=0 | LOSE. |

## Day-1 onboarding

There's no day 1 — it's a single episode. But first few seconds:
- Frame 0: Player spawns center. Empty arena.
- Frame 24 (~4s): First imp spawns at random edge, walks toward player.
- Player learns: arrow keys shoot (test fire to see).
- Frame 48: kills first imp. Score becomes 1. Particles spawn. Camera shakes briefly.
- Frame 72: ammo pickup appears. Player learns +5 ammo on touch.
- ~10-15 seconds in: 2-3 monsters at once. Pressure starts.

HUD always visible: HP bar, ammo, kills, timer.

## Open questions (resolved)

All resolved during GDD phase. No open questions to flag.

## Cross-reference table

| entity_id | belongs to | suggested file |
|---|---|---|
| `arena_clock` | meta | `entities/arena_clock.json` |
| `player` | actors | `entities/player.json` |
| `monster_imp` | enemies | `entities/monster_imp.json` |
| `monster_demon` | enemies | `entities/monster_demon.json` |
| `bullet` | projectiles | `entities/bullet.json` |
| `health_pickup` | pickups | `entities/health_pickup.json` |
| `ammo_pickup` | pickups | `entities/ammo_pickup.json` |
| `particle_spark` | effects | `entities/particle_spark.json` |
| `wall_segment` | decor | `entities/wall_segment.json` |
| `spawn_marker` | meta | `entities/spawn_marker.json` |
| (instances) | placement | `entities/zz_instances.json` |

## Hand-off summary

- **Cast**: 10 defs (1 player, 2 monsters, 1 bullet, 2 pickups, 1 particle, 1 clock, 1 spawn marker, 1 wall)
- **Items**: 2 pickup types
- **Plants**: n/a
- **Events**: pressure curve over 90s + win/lose conditions
- **Open questions for systems-designer**: how to scale spawn rate over time (formula vs explicit thresholds — recommend formula for cleanliness)
