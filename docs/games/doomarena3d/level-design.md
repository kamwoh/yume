# DoomArena3D — level design (v2)

_Date: 2026-05-04_
_Designer: yume-level-designer_
_GDD: docs/games/doomarena3d/GDD.md (v2.5)_
_Supersedes: previous level-design (4 pillars, sparse) — flagged "feels open / not real cover" by playtest_

## Map dimensions

- **World units**: 44 m × 44 m (XZ), 6 m visual ceiling
- **Camera framing**: first-person, FOV 78°, eye-height 1.6 m
- **Visible bounds**: ±22 m on X and Z (perimeter walls)
- **Spawn ring radius**: 18 m (just inside walls)
- **Boss spawn**: framed at (0, 0, +16) — back-center of arena
- **Player start**: (0, 0, 0) — straddling the chamber divider gap

## Spatial pattern rationale

**Two-zone closed arena with chamber divider** (evolution of the
"closed arena with cover" pattern from the skill library). The first
pass used 4 sparse pillars in 44×44m and felt open — long sightlines
everywhere, ranger fire impossible to break, no spatial memory across
runs. v2 introduces a **partial interior wall at z=0** that splits
the arena into Forward Zone (z<0) and Back Zone (z>0), with passages
on the left/right sides of the divider (gaps at x∈[-6,+6]). Plus
**8 pillars** (was 4) clustered into front-row + back-row patterns
per zone, and **4 industrial machinery crates** (1.5m³ box cover
pieces) per zone for theme reinforcement and additional cover
density.

This converts the arena from "central player + sparse cover" into
"central player + tactical chambers." The divider creates real
choke points (player must commit to a side passage), the pillars +
machinery give the player something to LEARN over multiple runs ("I
always die near the back-right machinery," "the divider gap is
where rangers catch me"). Boss spawn at (0, 0, 16) — visually
framed by the back-zone pillars + machinery — turns the boss arrival
into a ceremonial back-chamber moment instead of a random spawn.

Containment Chamber 7 fiction supports the design: the divider is
"the inner containment partition," forward zone is "incoming
processing," back zone is "core containment + the breach point."
Industrial machinery = "ore-processing equipment" / "fallen
pipework" / "control consoles." Walls + warning-stripe banding stay.

## Placements

### Perimeter walls (4)

Same as v1. Frame the arena.

| Wall | Position | Size (X×Y×Z) | Rationale |
|---|---|---|---|
| `wall_north` (wall_ns) | (0, 0, +22) | 44 × 3 × 0.5 | +Z bound (back of arena, behind boss spawn) |
| `wall_south` (wall_ns) | (0, 0, -22) | 44 × 3 × 0.5 | -Z bound (in front of player at start) |
| `wall_east` (wall_ew)  | (+22, 0, 0) | 0.5 × 3 × 44 | +X bound |
| `wall_west` (wall_ew)  | (-22, 0, 0) | 0.5 × 3 × 44 | -X bound |

### Chamber divider (2 segments)

A partial wall at z=0 with a 12m central gap (x ∈ [-6, +6]). Each
segment is 16m long × 3m tall × 0.5m thick. Forces players moving
between zones to pass through the central gap OR navigate around
the divider via the side passages near the perimeter walls (which
the divider doesn't reach — gaps from x=±22 to x=±14 each side).

Wait — divider ends at x=±14, perimeter wall at x=±22, so there are
also 8m-wide passages on left and right between divider and outer
wall. Three passage points: center gap + 2 side passages.

| Element | Position (center) | Size | Rationale |
|---|---|---|---|
| `divider_west` (wall_panel_short_ns) | (-14, 0, 0) | 16 × 3 × 0.5 | West half of divider — forces forward/back transitions |
| `divider_east` (wall_panel_short_ns) | (+14, 0, 0) | 16 × 3 × 0.5 | East half of divider, mirrors west |

(Need new mesh `wall_panel_short_ns` for the 16m length. Same colors
as full wall — rust + warning stripes — to read as "same chamber
material.")

### Pillars (8 — 4 forward zone, 4 back zone)

Asymmetric within each zone so each pillar is recognizable. Forward
zone is closer to player start; back zone holds the boss-spawn area.

| Pillar | Position | Zone | Rationale |
|---|---|---|---|
| `pillar_FL1` | (-9, 0, -6)   | Forward, left-mid | First cover the player meets walking forward + left from start. Teaches "use cover" within first 5s. |
| `pillar_FL2` | (-6, 0, -15)  | Forward, left-far | Far-left forward — flanking lane for player who wants to push forward aggressively. |
| `pillar_FR1` | (+11, 0, -8)  | Forward, right-mid | Mirrors FL1 on right side. Asymmetric depth (-8 vs -6) so pillars are distinguishable. |
| `pillar_FR2` | (+8, 0, -16)  | Forward, right-far | Mirrors FL2. |
| `pillar_BC1` | (-13, 0, +4)  | Back, near-divider west | Just past divider on entry — first back-zone cover after passing through. |
| `pillar_BC2` | (+11, 0, +6)  | Back, near-divider east | Asymmetric counterpart to BC1. |
| `pillar_BL`  | (-6, 0, +13)  | Back, left of boss area | Frames the back-left of the boss spawn area at (0,0,+16). |
| `pillar_BR`  | (+8, 0, +15)  | Back, right of boss area | Frames the boss spawn area's right side. |

All pillars: 1m × 3m × 1m, blocks_motion + aabb_extents [0.5, 1.5, 0.5].

### Industrial machinery (4 — 2 forward, 2 back)

Larger cover pieces. Visually distinct from pillars: thicker boxy
form with rust + warning-stripe banding. Mechanically: 1.5m × 1.5m
× 1.5m, blocks_motion. Theme: "ore-processing units" / "containment
machinery."

| Element | Position | Zone | Rationale |
|---|---|---|---|
| `machinery_FL` | (-15, 0, -10) | Forward, far-west | Alongside west wall, fills the western flank of forward zone. Player can hide behind from rangers spawning at +X. |
| `machinery_FR` | (+15, 0, -12) | Forward, far-east | Mirror of FL with offset Z so layout is asymmetric. Eastern flank cover. |
| `machinery_BL` | (-15, 0, +10) | Back, far-west | Western back zone cover. Forces player to commit to a side when navigating to boss area. |
| `machinery_BR` | (+13, 0, +12) | Back, far-east | Eastern back-zone cover. Pairs with BL to channel player into center for boss approach. |

### Spawn ring (where enemies appear)

Existing rule formula picks random angle on radius-18 ring. v2
keeps this behavior — but the divider + pillars now mean enemies
spawning at +Z must navigate around to the player. Forward-zone
spawns are direct attacks; back-zone spawns funnel through the
divider gap (or side passages).

Spawn types:
- imps / demons / rangers: `cos(randf() * 6.28318) * 18` for X/Z (full ring)
- pickups: `(randf() - 0.5) * 36` for X/Z (anywhere in arena)

### Boss spawn (REV — ceremonial)

Was: random angle on radius-16 ring (could spawn anywhere). Now:
**fixed at (0, 0, +16)** — back-center of arena, framed by pillar_BL
+ pillar_BR + machinery_BL + machinery_BR. Player has to turn
around to face the boss. The pillars + machinery form a visual
"chamber" containing the boss arrival.

Update boss_spawn_check rule's position formula:
```jsonc
"position": [0, 0, 16]    // was: ring radius 16, random angle
```

### Player start

| Element | Position | Rationale |
|---|---|---|
| `player` | (0, 0, 0) | Center of arena, on the divider gap. Player can see both zones equally at start. Default facing=0 = -Z (south wall ahead) — initial enemies in calm phase spawn at +Z (behind player) or sides; player has to scan + turn. |

### Floor (visual only — no blocks_motion, ground primitive handles Y)

| Element | Position | Size | Rationale |
|---|---|---|---|
| `floor` | (0, 0, 0) | 44 × 1 × 44 | Industrial steel-grate plate. Top at Y=-0.05 to avoid z-fighting with wall bottoms at Y=0. |

## Pacing notes

- **Imp travel time** (radius 18, speed 3.5 m/s): ~5.1s spawn → contact (back-zone spawns longer due to navigating divider).
- **Demon travel time** (radius 18, speed 2.5 m/s): ~7.2s direct, ~9-10s via divider.
- **Ranger walk-in time** (radius 18 → 6, speed 2 m/s): ~6s walk-in. Rangers spawning in back zone may stop at the divider's far side and fire through the gap — interesting "hold the line" tactical moment.
- **Boss travel time** (from 0,0,+16 to 0,0,0, speed 1.5 m/s): ~10.7s. Slow ominous approach via divider gap or side passage.
- **Choke point density**: 3 passage points (center gap + 2 side passages), each ~6-8m wide. Medium density. Player can choose route per run.
- **Danger zones**: divider passages (rangers fire through gap), back zone center (boss approach), forward-zone open lanes between pillars.
- **Safe zones**: behind any pillar relative to current threat direction; behind machinery on the flanks.
- **Visual readability**: with 8 pillars + 4 machinery + 2 dividers visible from center, the player has many landmarks. After 3-4 runs they'll start naming them informally ("the forward-left pillar," "the boss machinery").

## Risks / known issues

1. **Line-of-sight gap**: engine doesn't yet ray-test for AI sightline.
   Rangers fire at any player within radius 8 regardless of pillar/wall
   between them. Pillars + walls block ranger BULLETS (per ADR 0004 +
   ADR 0005), so cover still works for the player even if the ranger's
   targeting is omniscient. Future work: a `raycast_hit`-based AI
   sightline check before ranger fires would close this gap. Tracked
   as future ADR — for v2 the cover-for-bullets is enough Doom-feel.
2. **Divider-trap for fast bullets**: at v2.5 we landed swept-AABB
   collision. Rocket at 14 m/s × 0.05s tick = 0.7m/tick. Divider is
   0.5m thick. Tunneling possible but rare per swept-segment test.
   Should be fine.
3. **Boss-bias for player**: spawning boss at fixed (0,0,+16) means
   players who learn the layout know exactly where to point the
   rocket. That's intentional — boss spawn is a SIGNATURE moment, not
   a mystery. Keeps "you'll remember this" rhythm.
4. **Asymmetry confusion**: 8 pillars + 4 machinery in deliberately-
   asymmetric positions may feel cluttered to first-time players.
   Mitigation: distinct pillar names suggest readability; controls
   hint adds enough framing.

## Validation against GDD aesthetic

- **Challenge**: 8 pillars + 4 machinery + 3 passage points create
  REAL tactical decisions. Where do I retreat? Which side of the
  divider do I commit to? Where's the safest spot to reload? Compare
  to v1's "center is safe / 4 pillars are landmark-only" — v2 makes
  geometry a first-class strategic axis.
- **Sensation**: more cover = more visceral firefights. Bullets
  sparking off pillars (post-3D-AABB) read as IMPACTS, not phasing-
  through. Boss spawn at framed back-center with red flash + roar
  has spatial weight — the back chamber FEELS like the boss's lair.
- **Submission**: spatial memory now has 12+ landmarks (8 pillars +
  4 machinery + divider gap + 4 walls + boss area) instead of 4. By
  run 3-4, the player has internalized "the map" — that's the trance
  layer of Submission. The 90s loop becomes a known dance through
  named geometry rather than wandering an open void.

---

**Summary**:
- Dimensions: 44 m × 44 m, 2 zones via chamber divider with 3 passage points
- Walls: 4 perimeter
- Divider: 2 segments (each 16m, with 12m central gap + 8m side passages)
- Pillars: 8 (4 forward zone, 4 back zone, asymmetric)
- Machinery: 4 (1.5m³ blocks_motion crates, 2 per zone)
- Boss spawn: ceremonial fixed at (0, 0, +16)
- Aesthetic match: Challenge (cover decisions), Sensation (real impacts), Submission (spatial memory)
