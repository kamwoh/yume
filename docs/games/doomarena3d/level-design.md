# DoomArena3D — level design

_Date: 2026-05-03_
_Designer: yume-level-designer_
_GDD: docs/games/doomarena3d/GDD.md_
_World plan: (none — pre-existing game; cast inferred from entity defs)_

## Map dimensions

- **World units**: 44 m × 44 m (XZ), 6 m tall (visual ceiling line)
- **Camera framing**: first-person, FOV ~75°, eye at Y = 1.6 m
- **Visible bounds**: ±22 m on X and Z (walls clamp creature movement)
- **Spawn ring radius**: 18 m (4 m inside the wall — monsters appear AT the wall plane and walk inward, never embedded inside the wall)
- **Boss spawn arc**: rear of arena, +Z hemisphere, radius 16 m

## Spatial pattern rationale

**Closed arena with asymmetric cover** (per skill library's
"Shooter / cover-based" template). The Containment Chamber 7
fiction is a 44 m × 44 m steel-walled mining-colony chamber. The
old design — flat plane with a circular bounds clamp at ±15 m —
had the right size for combat but no level: no spatial reference,
no flanking opportunities for the new ranger enemy, no signature
spawn area for the boss. This pass adds 4 perimeter walls + 4
asymmetric internal pillars. Walls frame the space and prevent the
"floating in void" feel; pillars give the player tactical pockets
to break sightlines from rangers (currently visual only — engine
doesn't yet block projectiles via wall raycasts; tracked as future
work `wall_blocks_projectile`). Asymmetry — 4 pillars positioned
at non-mirror coordinates — gives the arena character so player can
mentally map "the front-right pillar" vs "the back-left rig" within
3-4 sessions, supporting Submission's trance-loop spatial memory.
Bounds expanded from ±15 m to ±22 m: bigger arena makes the ranger's
"stop at 6 m" rule produce a real engagement pocket (12 m of walk-in
distance) rather than triggering immediately on spawn.

## Placements

### Walls (perimeter)

Walls are thin steel-paneling boxes, ~44 m long × 3 m tall × 0.5 m
thick. Positioned at the outer edge of the bounds clamp so they
visually match the movement boundary the engine already enforces.
4 walls × 1 = 4 placements.

| Wall | Position (center) | Size (X, Y, Z) | Rationale |
|---|---|---|---|
| `wall_n` (north) | (0, 1.5, +22) | (44, 3, 0.5) | Frames +Z edge; player sees a visual horizon when looking forward at facing=0. |
| `wall_s` (south) | (0, 1.5, -22) | (44, 3, 0.5) | Frames -Z edge; closes the rear arena from view. |
| `wall_e` (east)  | (+22, 1.5, 0) | (0.5, 3, 44) | Frames +X edge; gives a flanking limit for east-side rangers. |
| `wall_w` (west)  | (-22, 1.5, 0) | (0.5, 3, 44) | Frames -X edge; mirrors east — together with east enforces the "containment chamber" feel. |

### Cover pillars (interior, asymmetric)

Pillars are vertical structural columns, ~1 m × 1 m × 3 m. They're
exposed mining-colony reinforcement struts (in fiction), but
mechanically: player has somewhere to retreat behind when a ranger
locks on. Asymmetric placement so the arena has personality.

| Pillar | Position | Rationale |
|---|---|---|
| `pillar_a` | (5, 1.5, -3)   | **Close-front-right** — first piece of cover the player encounters when walking forward + right; teaches "use cover" within 5-10s of game start. |
| `pillar_b` | (-7, 1.5, 4)   | **Back-left mid** — pairs with pillar_a on the opposite quadrant; player retreating from a front-right ranger has somewhere to go. |
| `pillar_c` | (10, 1.5, 9)   | **Far-back-right "boss dais"** — sits near the boss spawn arc; when boss appears at score=25, this pillar is silhouetted in front of it, framing the moment per Axis 9 signature. |
| `pillar_d` | (-3, 1.5, -10) | **Front-far-left "ore conveyor"** — most distant cover from start; rewards player who advances aggressively, sets up a ranger flanking lane. |

Total: 4 pillars. Asymmetric quadrant distribution: 2 on +X side
(close + far), 2 on -X side (close + far), with one front + one back
on each. No pillar mirrors another exactly — each has unique
distance from origin and from the others.

### Spawn ring (where enemies arrive)

Existing rule formula: `cos(randf()*6.28318)*RADIUS, 0, sin(randf()*6.28318)*RADIUS`. Updated radius from 14 → 18.

| Element | Position | Rationale |
|---|---|---|
| Imp / demon / ranger spawns | Ring at radius 18 m, full 360° | Just inside the ±22 m wall plane; enemies materialize at the wall and walk inward, giving the player ~5 s reaction window for an imp at 3.5 m/s, ~7 s for a demon, and ~6 s before a ranger plants and fires. |
| Pickup spawns (health + ammo) | Random in ±18 m square | Inside the wall plane, can land near or far from player; keeps pickup grabbing as a movement decision per Submission tempo loop. |

### Boss spawn area

| Element | Position | Rationale |
|---|---|---|
| Boss arrival | radius 16 m, angular range +Z hemisphere (`angle = randf()*PI` so position = (16*sin(angle), 0, 16*cos(angle)))  | The "rear of the arena" — boss appears behind/to-the-side of the player's default forward facing, forcing a turn-and-orient moment. The boss dais pillar (`pillar_c`) is in this hemisphere, making the boss visually frame against industrial geometry rather than empty void. |

(If staying inside-the-current spawn-rule shape is easier for
content-designer, full-360° ring at radius 16 is acceptable — the
hemisphere variant is a polish nicety.)

### Player start

| Element | Position | Rationale |
|---|---|---|
| `player` | (0, 0, 0) | Dead center of arena. Equidistant from all walls and pillars. Standard arena pattern: spatial anchor, all cover ≤ 11 m away, all walls 22 m away. |

### Floor (visual only)

| Element | Position | Size | Rationale |
|---|---|---|---|
| `floor` (optional, decorative) | (0, -0.05, 0) | (44, 0.1, 44) | Industrial steel-grate plate covering the arena; gives the player a sense of "ground" instead of staring at void below the bounds. Color: dark steel + warning-yellow stripes per theme. Optional — engine renderer probably already has a default ground; if so, skip. |

## Pacing notes

- **Imp travel time** (radius 18, speed 3.5 m/s): ~5.1 s spawn → contact. Player has time to acquire and shoot before the imp closes.
- **Demon travel time** (radius 18, speed 2.5 m/s): ~7.2 s. Tankier but slower; player can prioritize.
- **Ranger lock-on time** (radius 18 → 6, speed 2.0 m/s): ~6 s walk-in, then plants and fires every 1.5 s. Rangers are the longest "resolve me" target.
- **Boss travel time** (radius 16, speed 1.5 m/s): ~10.7 s. Ominous slow approach. Player can shoot it on the way in but must also handle ongoing imp/demon waves.
- **Choke point density**: medium. 4 pillars in 44×44 = ~1 cover piece per 484 sq m. Plenty of open lanes between pillars (good for Sensation — visceral firefights), enough cover to break sightlines (good for Challenge — meaningful movement decisions).
- **Danger zones**: open lanes between pillars (especially the diagonal NW–SE and NE–SW lines through center). **Safe zones**: behind any pillar relative to the current ranger.
- **Visual readability**: yes — 22 m visible in any direction at FOV 75° fits in screen. Walls cap the horizon. Pillars are placed so no two pillars directly occlude each other from origin (each visible from start position).

## Risks / known issues

1. **Pillars don't currently block bullets or enemy movement.** Engine has no line-of-sight or wall-collider primitive yet. Pillars are cosmetic + spatial-reference only in v2. Tracked as future work — needs a `wall_blocks_projectile` rule + `wall_blocks_movement` rule (or the simpler approach: walls/pillars are entities with a `blocks_motion` tag, motion integrator clamps movement against their AABB). Estimated effort: medium (~1 hr engine work, ADR-able).
2. **Walls are visual only.** Same — bounds clamp at ±22 m enforces the boundary; walls are decoration that happens to match the clamp position. If the player sees an enemy walk *through* a wall edge, that's the rule firing late on the spatial index. Acceptable for v2.
3. **Asymmetric pillars create a "preferred quadrant" for boss spawn.** The boss dais (pillar_c at (10, 1.5, 9)) is in the +X+Z quadrant. If the boss spawns in the -X-Z quadrant, the framing is lost. Mitigated by limiting boss spawn to +Z hemisphere; if that's too restrictive, reroll until distance > 5 m from any pillar (pillar collision).
4. **Spawn ring at 18 m can put a ranger inside its own fire range immediately.** A ranger spawning 18 m from the player is well outside fire_range=6, so no — ranger walks in first. ✓ no actual issue.

## Validation against GDD aesthetic

- **Challenge**: 4 pillars convert open-arena combat into a shape with cover. Player must decide *which pillar* to break a ranger's sightline behind, while still managing imp closing distance and demon HP. The pillar choice is real strategy emerging from spatial layout — exactly what the round-1 reviewer flagged was missing in v1.
- **Sensation**: Walls + pillars + floor give the player visual reference points so kills, sparks, shake, and red flash all register against a real environment. The old flat void let those effects feel weightless. Now: a kill near the boss dais pillar feels like "a kill near the boss dais," memorable and locatable.
- **Submission**: Spatial memory builds across replays. After 3-4 runs the player thinks "the boss usually comes from the dais" / "I always die near pillar_d." That mental map IS the trance loop's spatial dimension. Without landmarks the trance has no rhythm.

---

**Summary**:
- Dimensions: 44 m × 44 m × 6 m, ±22 m bounds
- Walls: 4 perimeter
- Pillars: 4 asymmetric internal cover pieces (+ optional floor plate)
- Aesthetic match: arena now serves Challenge (cover decisions) + Sensation (effects against real geometry) + Submission (spatial memory across replays).
