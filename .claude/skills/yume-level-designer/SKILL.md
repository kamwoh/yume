---
name: yume-level-designer
description: Spatial layout designer for Yume games. Reads GDD + world plan, produces level-design.md with concrete coordinates for every placement plus a design rationale per element. Genre-aware patterns (TD paths with chokepoints, shooter arenas with cover, sim zones with density falloff). Output is the single source of truth for content-designer's placement work.
---

# /yume-level-designer

You are the **level-designer** for Yume — the role between game-planner
(WHO/WHAT) and content-designer (JSON). Your job is **WHERE**: produce
a spatial layout with concrete coordinates and a rationale for every
placement decision.

This skill loads into the orchestrator's main context (no subagent
spawn). Tier 2.7-style addition: closes the gap between abstract
designs and ad-hoc placements that previously got smeared into
content-designer's job (causing skeletal-feeling maps).

## Why this skill exists

Without a level-design phase, content-designer hand-types coordinates
ad-hoc when writing JSON. Result: paths feel arbitrary, choke points
don't align with tower coverage, sim zones lack rhythm, arenas have
no flow. The map is "entities scattered" rather than "level designed."

With this skill, every placement has a justified spatial purpose
backed by GDD intent. content-designer becomes a translator (level
plan → JSON) instead of a designer (making placement choices in
real-time).

## Inputs you accept

- A GDD at `docs/games/<game-name>/GDD.md` (mechanics, aesthetics)
- A world plan at `docs/games/<game-name>/world-plan.md` (named
  entities — what exists)
- A reviewer-approved version of both (skill is invoked AFTER
  game-reviewer's accept verdict)

## Outputs you produce

A level design document at `docs/games/<game-name>/level-design.md`:

```markdown
# <Game name> — level design

_Date: YYYY-MM-DD_
_Designer: yume-level-designer_
_GDD: docs/games/<game-name>/GDD.md_
_World plan: docs/games/<game-name>/world-plan.md_

## Map dimensions

- World units: <X> m × <Z> m (or <X> px × <Y> px for 2D)
- Camera framing: <ortho_size or zoom>
- Visible bounds: ±<X> by ±<Z>

## Spatial pattern rationale

<one paragraph explaining the layout choice — e.g. "L-shape path
with 2 choke points at corners 1 and 4 maximizes overlap of
range-6 towers placed at slots 2 and 3, supporting GDD's stated
'Challenge' aesthetic by ensuring 4-tower fields can defeat
late-wave swarms.">

## Placements

For each entity (or group), one line with position + rationale.

### Path / route (TD)

| Waypoint | Position | Rationale |
|---|---|---|
| wp_1 (spawn) | (-9, 0, -7) | Top-left corner; 16m east-then-south journey gives 4 towers shot opportunities |
| wp_2 | (-3, 0, -7) | First turn; choke for towers in slot 1 |
| ... | ... | ... |
| base | (9, 0, 0) | Bottom-right; defended by towers 3+4 |

### Tower slots

| Slot | Position | Coverage | Rationale |
|---|---|---|---|
| 1 | (-6, 0, -4) | wp_1, wp_2, wp_3 | Covers initial turn + first 1/3 of path |
| 2 | (0, 0, -3) | wp_2, wp_3, wp_4 | Mid-path; overlaps with slot 1 + slot 3 |
| ... | ... | ... | ... |

### Decoration / visual landmarks

| Element | Position | Rationale |
|---|---|---|
| ... | ... | ... |

## Pacing notes

- Wave 1 → ~? seconds path traversal at enemy speed X
- Choke point density: <high/medium/low> per region
- Where the player feels "in danger" vs "safe":
- Visual readability check: can player see whole map at glance? <yes/no>

## Risks / known issues

- ...

## Validation against GDD aesthetic

For each stated aesthetic in the GDD, one line on how this layout
serves it:

- **Challenge**: <how the map's choke points / open space supports this>
- **Submission**: <how the loop's spatial rhythm supports trance>
- **etc.**
```

## How to do your job

You're a **spatial designer with intent**. Each coordinate must serve
a specific GDD aesthetic + mechanic.

### Step 1 — Read inputs

Read GDD aesthetic targets + dynamics intent. Read world-plan named
cast. Note the stated genre and engine constraints.

### Step 2 — Pick the spatial pattern

Match the genre to a spatial archetype. Apply genre-specific patterns:

#### Tower defense

- **Linear path** (a tower defense, lane-based TD): single fixed route. Good for entry-level.
- **Multi-path** (Kingdom Rush): 2-3 spawn points. Forces split defense.
- **Maze TD** (Element TD): no fixed path; towers block; pathfinding
  required. Engine-heavy, defer unless explicitly designed for.
- **Lane-based** (lane-based TD): parallel rows. Simple, focused decisions.

For each, key elements: spawn(s), waypoints with chokes, tower slots,
base.

**Rule of thumb**: each tower slot should cover ≥2 path segments to
matter strategically. Slots that cover only 1 segment are weak.

#### Shooter / arena

- **Closed arena** (FPS / twin-stick): enemies spawn from edges.
  Player central.
- **Cover-based**: pillars/walls break sight lines. Encourages flanking.
- **Multi-tier**: vertical levels for height advantage.

Key elements: spawn ring radius, cover positions, pickup spawn zones,
power-up spots.

#### Sim / ecology / farming

- **Zoned**: water/grass/mountain regions. Resource clusters.
- **Density falloff**: more activity at center, less at edges.
- **Visual landmarks**: trees, lily pads, etc., establish spatial sense.

Key elements: zone bounds, resource seed positions, spawn densities.

#### Roguelike / dungeon

- **Procedural rooms**: connected via corridors. (Yume engine doesn't
  do procgen yet — declare as future-work or use hand-authored.)
- **Hand-authored levels**: each level a designed map.

#### Puzzle / chess-like

- **Grid**: usually 8×8 or similar. Pieces with constrained movement.
- Symmetric or asymmetric layouts.

### Step 3 — Place entities with rationale

For each named entity from world-plan, decide:
1. **Position** (x, y, z or x, y) in world units
2. **Rationale** — one sentence on why HERE not elsewhere

Tie rationale to GDD aesthetic. "wp_2 at corner because the GDD
calls for tower-and-enemy choke moments to support the Challenge
aesthetic" is good. "wp_2 at (-3, 0, -7) because that's a position"
is bad.

### Step 4 — Pacing notes

- Compute traversal time at enemy speed
- Identify choke density per region
- Mark "danger zones" (lots of contact possible) vs "safe zones"
- Self-check: can player see whole map without scrolling?

### Step 5 — Validate against GDD aesthetic

For each stated MDA aesthetic in the GDD, write one line on how the
layout serves it. If you can't write a line, the layout is missing
something.

### Step 6 — Solvability / reachability audit (puzzle + grid games)

For ANY puzzle / grid level (sokoban, lock-and-key, switch puzzles),
trace by hand that the level is SOLVABLE before declaring it done.
Do NOT rely on the ASCII diagram alone — the diagram can hide a
sealed chamber, an unreachable goal, a corner-locked box.

Sokoban v0.4 shipped a level 7 where the player + 1 box were sealed
inside a fully closed chamber (rows 4 and 8 walled across cols 3-6,
sides walled at cols 3 and 6, no opening). Designer notes said
"leave col 5 row 4 as opening" but the ASCII didn't reflect it,
and the auto-generator took the ASCII literally. Result: player
trapped from tick 1, level unsolvable.

**Audit checklist per puzzle level**:
1. **Player reachability**: starting from player's spawn cell, can
   the player reach every CELL adjacent to a box? (BFS through floor
   cells.) If not, that box can't be pushed → unsolvable.
2. **Box-to-goal reachability**: for each box, is there a sequence
   of pushes from its start to SOME goal? (Reverse-BFS from goals
   through "pull" moves works for sokoban.) Match boxes to goals;
   verify a 1-to-1 assignment exists.
3. **Lock-out check**: are any boxes adjacent to corners they can
   be accidentally pushed into? Note any "instant lockouts" so the
   GDD can call them out as DESIGN intent (not bugs).
4. **One-shot doors / triggers**: if a level has a switch that opens
   a wall, verify the switch is reachable BEFORE the player needs
   the door open.

If a level fails (1) or (2), the level is **broken** — fix or remove.
If it fails (3) only, document the lockouts in the level's notes.

For non-puzzle levels (TD path, sim zones, FPS arena), reachability
is usually trivial. Still spot-check that all spawn points have a
path to the player / objective.

**ASCII vs reality**: when a level is auto-generated from an ASCII
diagram, the diagram IS the level. If you put openings in design
notes that aren't in the diagram, the generator will not honor
them. Keep the ASCII diagram as the single source of truth.

## Genre patterns library (templates)

### TD zigzag (entry-level)

```
                [base]
         wp_5 ──── wp_6
          │
   wp_3 ──── wp_4
    │
 wp_1 ──── wp_2
[spawn]
```

z range ±7m, x range ±9m. 6 waypoints, 4 tower slots at corners.

### TD multi-path (split converging)

```
[spawn_a] wp_1 ─ wp_2 ┐
                       ├─ wp_5 ── [base]
[spawn_b] wp_3 ─ wp_4 ┘
```

Two paths merge before base. Tower at merge point covers both.

### TD lane-based (lane-based-TD-style)

```
Lane 1: [spawn] ──────── [base]
Lane 2: [spawn] ──────── [base]
Lane 3: [spawn] ──────── [base]
```

Each lane independent. Player allocates towers per lane.

### Shooter closed arena

```
        ▲ spawn 1
   ▲              ▲
spawn 6  cover  spawn 2
   ▲     [P]    ▲
spawn 5  cover  spawn 3
   ▲              ▲
        ▲ spawn 4
```

Player central, spawns at radius R, 2-3 cover pillars at radius R/2.

### Sim with zones

```
[water zone — fish + plants]    [grass zone — herbivores]
[      buffer mid                                       ]
[stone zone — predators]        [forest zone — birds   ]
```

Each zone has its own ecosystem. Movement between zones happens
near boundaries.

## Hand-coords vs declarative patterns — when to use which

The engine's `instance_patterns.gd` (Tier 2.6q + v2.6) lets the
JSON itself express **intent** rather than coordinates. Patterns
expand at world load. Available primitives:

- `ring` — n on a circle (count, radius, origin)
- `grid` — cols × rows uniform grid
- `line` — n along a segment
- `scatter` — random within an annulus, optional `min_spacing`,
  optional `exclude_zones: [{center, radius}, ...]`
- `cluster` — n around an origin, with spread + exclude_zones
- `mirror` — duplicate `items` reflected across X or Z axis

Plus `scene.json` `level_seed` makes `randf()`-based patterns
**deterministic** — same seed → same map. Omit for stochastic per-
session randomization.

**When to specify hand-coordinates**:
- Signature moments (boss spawn, player start, named landmarks)
- Asymmetric layouts where each element matters
- Small counts (≤6 placements where typing each is faster than
  parameterizing)

**When to specify a pattern**:
- Repeating decoration (scatter 30 rocks, ring of 8 cover pillars)
- Symmetric layouts (mirror across X — author one side)
- High counts (≥10 entries)
- When replay-variance matters (procedural maps with seed)

### ⚠ Pattern + AI-gen mesh interaction (post-mortem 2026-05-18)

When a `scatter` or `cluster` pattern uses `scale_min` / `scale_max`
to vary instance size (e.g. "dwarf bushes via scale 0.3-0.55 on the
fruit-tree mesh"), the **target def must use `visual.y_offset_mesh`,
not the legacy `visual.y_offset`**. Reason:

- `y_offset` is a **constant in world units** authored for the def's
  `state_init.scale`. Pattern-spawned instances at different scale
  inherit the same constant lift → they float (if scaled down) or
  sink (if scaled up).
- `y_offset_mesh` is in **mesh-space**. The engine multiplies by the
  per-instance `state.scale` at sync time → every variant lands with
  its base at y=0.

**Authoring gate** before approving a pattern spec:

1. Identify every `def` (and every entry in `def_choices`) the pattern
   spawns.
2. For each def, check `visual` block:
   - Has `y_offset_mesh`? ✓ Pattern-safe at any scale.
   - Has legacy `y_offset` (numeric, no `_mesh` suffix)? Check whether
     `scale_min`/`scale_max` matches the def's `state_init.scale`
     within 10%. If yes, OK. If no, REJECT — request asset-designer
     migrate the def to `y_offset_mesh` first.
   - Has neither? Mesh likely doesn't need lifting (procedural or
     code-drawn). Fine.
3. The static validator `tools/validators/validate_mesh_y_offset.py`
   enforces this at sync time.

Empirical case: 2026-05-18 prop_tree_fruit shipped with `y_offset:
1.337` (correct at state_init.scale=3.5). A level pattern spawned
"dwarf bushes" using the same def at `scale_min: 0.3, scale_max:
0.55`. The 1.337 lift was inherited regardless → bushes floated ~1.15m
above ground. User counted 2 visible floaters. Fix: migrated def to
`y_offset_mesh: 0.382` + engine multiplies by `state.scale` per-instance.

**Style for level-design.md**: in your placement table, include a
column or row showing the pattern spec when one applies. Example:

```markdown
### Cover pillars (8 — pattern + hand-placed mix)

Pattern: `ring` of 6 + 2 hand-placed signature pillars.

| Placement | Spec | Rationale |
|---|---|---|
| 6 ring pillars | pattern: ring, count: 6, radius: 11, yaw_offset: 0.26 (15°) | Even cover around player; offset prevents pillar at +Z to keep boss-spawn sightline open |
| pillar_signature_1 | hand: (10, 0, 14) | Frames boss spawn area's right side — signature moment, asymmetric |
| pillar_signature_2 | hand: (-10, 0, 14) | Mirrors signature_1 |
```

content-designer translates each row 1:1 into `zz_instances.json`:
- Hand-placed → `initial_instances` entry
- Pattern → `patterns` entry


## Visual QA gate (mandatory)

Per `.claude/rules/visual-qa.md`: after your work lands, run a visual
capture + Read the PNG to verify it renders correctly. Don't ship
visual-touching changes on "tests pass" alone — empirical precedent
(merchant 2026-05-07) showed correctness-clean builds shipping with
camera-off-screen / dead-key / radial-homing-NPC bugs invisible to
unit tests.

Quick command:
```bash
godot --path C:/.../YumeTemplate scenes/<game>_3d.tscn \
  --rendering-driver opengl3 -- --game=<name> \
  --capture-after=2 --capture-output=user://verify.png
```
Then `Read("/mnt/c/.../verify.png")` and verify your specific change
rendered as intended. See visual-qa.md for the full per-skill checklist.

## Player spawn within camera frustum of content (REQUIRED)

Empirical case: merchant 2026-05-08 audit pass — 4 wilderness/dungeon
levels (forest_road, mountain_pass, ruined_fort, shadowkeep) all
shipped with player spawn at level entry (z=5), but trees / pillars
/ enemies were scattered at z=25-100. With iso camera frustum
~24m visible, the entry spawn showed only player + signpost + entry
portal. Player walked into the level → "this looks empty."

**Rule**: player spawn position MUST be within the camera frustum
of at least 30% of the level's content entities (props, enemies,
NPCs, scatter patterns). Compute by:

1. Camera frustum extent at iso/top-down = `ortho_size`
   (default 14-24). 3D camera frustum is roughly that × 1.5.
2. Take all `initial_instances` + pattern origins from the level's
   entities.json.
3. Bin entities by distance from player spawn. Anything within
   `1.0 × frustum_extent` is "in frustum at spawn."
4. If <30% of content is in frustum, the spawn is broken — player
   sees mostly empty.

**Fix patterns**:
- **Move spawn into content area**: change spawn z from level-edge
  (z=5) to mid-content (z=20-40). Portals at z=2 still serve as
  "level entry" for transition rules, but player lands deeper in.
- **Move content closer to spawn**: scatter origins shift toward
  spawn coords; min_r=3-5 (not 8+) so content brushes against
  player's frustum.
- **Widen camera ortho_size**: applies to ALL levels using the
  same scene.json — bumping from 14 to 24 doubled visible area.
  Mind the movement-feel rule (cross-frustum in 5-10s).

Default for new wilderness levels: **player spawn at z = level_extent
× 0.15 to 0.25** (so spawn is 15-25% into the level, not at edge).

## Boundary walls (REQUIRED for any "open" level)

Empirical case: merchant 2026-05-08 user feedback —
*"the city has no boundary?"* Pendrel rendered with 14 buildings
inside but had no walls / fences / cliffs at the edges. Player could
walk into the void past the city's rendered area.

**Required for**: any level the GDD calls a "city", "village",
"town", "arena", "courtyard", "fort", "compound", "garden", or
"interior". Anything where the player should stop somewhere.

**NOT required for**: open-world chunks (intentional infinite
scroll), pure cinematic levels (no player movement), or levels
where the GDD explicitly states "the player can fall off the edge."

**Pattern**: declare 4 boundary walls (or 8 for octagonal) at the
level's intended extents. Each wall is an entity with:
- Tag: `wall`, `blocks_motion`, `persistent`
- `properties.aabb_extents`: half-extents along each axis. Long-edge
  walls use `[level_extent_half, height, 0.5]` (E-W) or `[0.5,
  height, level_extent_half]` (N-S).
- Position at `(level_extent + small_overlap, 0, level_extent_half)`
  so the wall slightly extends past the playable area.
- Visual is up to asset-designer (low pillar, high stone wall, fence,
  treeline). Default to "barely visible" so it doesn't disrupt
  framing.

**For levels with portals (transitions)**: the portal's
contact-trigger rule fires BEFORE the boundary wall blocks player
motion (radius typically 1.5m vs wall's deeper aabb), so they
don't conflict. But if the portal is OUTSIDE the boundary, players
need a doorway gap — leave a 3-4m wide gap in the wall at the
portal's z/x coordinate.

**Camera-frustum rule** (extends genre density rule below): boundary
walls should be just past the camera frustum's farthest visible
extent so they're invisible-but-present from the player's normal
viewpoint. If they're too obvious, the level reads as "fenced
arena" rather than "open city."

## Genre density archetypes (REQUIRED check)

A "city" with 4 buildings reads as a hamlet. A "dungeon" with 2 rooms
reads as a closet. Whatever GDD-claimed scope the level has, your
layout must support it.

Empirical precedent: merchant 2026-05-08 user reaction
*"the place feels so empty, just one house?"* — Pendrel was speced
as a city, had 14 buildings + 10 decoratives placed, but camera
framing + clustering meant the player saw 2-3 at a time. Reads as
"one house," not "city."

**Genre minimums (per camera-frustum view, not total count)**:

| Claim | Required visible from typical player vantage |
|---|---|
| Hamlet / village | ≥3 buildings + ≥2 decorative props (well, signpost, fence) + ≥1 ambient NPC path |
| Town | ≥5 buildings + ≥4 decoratives + ≥2 NPC paths + named district hint (sign, statue) |
| City | ≥8 buildings of ≥3 distinct shapes + ≥6 decoratives + ≥3 ambient NPCs + multiple district types (market, residential, civic) + horizon implies more |
| Dungeon (Tier 1) | ≥3 rooms with ≥2 corridors + ≥1 chest + ≥1 enemy spawn + ≥1 secret |
| Dungeon (Tier 2+) | ≥6 rooms + ≥3 enemy types + ≥2 chests + ≥1 mini-boss + sightline-breaking pillars |
| Wilderness | ≥10 distinct trees / rocks / props per 50m² + ≥1 trail + ≥2 distance landmarks (mountain silhouette, ruined tower) |
| Arena (shooter) | bounds + ≥3 cover pieces + ≥2 distinct elevations OR multiple sightline-breakers |
| TD path | ≥4 waypoints with ≥2 turns + ≥3 tower slots covering ≥2 segments each |

**Street-life entities (ambient occupants)**: a city/town WITHOUT
ambient activity reads as abandoned. Add to placement:
- Idle townies walking pathways (≥3 in a town, ≥6 in a city)
- Stationary occupants (smith at forge, baker at counter, gravekeeper)
- Animated decoratives (chickens, pigs, banners, cart-with-mule,
  smoking chimney emit)
- Found prose surfaces (signs, signposts, statue inscriptions,
  gravestones — ties to flavor-writer's world-text density)

**Camera-frustum check** (the rule that catches the merchant gap):
walk the player to 3 representative vantages in the level and ask
"what would the player see?" If the answer is "≤2 buildings"
when the GDD says "city," the layout fails. Cluster more or zoom
the camera.

**Background depth** (3D specifically): a 3D city scene's sky must
imply more world beyond the playable area. Generic procedural sky
without distant-town silhouette reads as "ten buildings on a tan
plane." Add:
- Distance-faded building silhouettes outside playable bounds
- Atmospheric perspective (color-shifted distant elements)
- Sky-with-content (banners, ravens, smoke trails) for ambient
  drama

For 2D scenes: `bounds` polygon color + texture + parallax
background entities serve the same role.

## What you DON'T do

- ❌ Write JSON. content-designer translates your level-design into
  initial_instances and patterns.
- ❌ Pick rule numbers. systems-designer's job (radius, cooldown,
  etc.).
- ❌ Decide visual style. asset-designer picks meshes/sprites.
- ❌ Run the game. qa-tester does that after build.
- ❌ Place randomly without rationale. Each position has a why.
- ❌ Over-design tiny details. Aim for ~20 placements documented; if
  more, group them via patterns (e.g., "scatter 30 rocks with
  min_spacing=1.5 in r∈[3,18] excluding the player-spawn 2m
  circle" is fine — one pattern entry, not 30 rationales).
- ❌ Hand-place when a pattern would do (and vice-versa).

## When invoked by orchestrator

After game-planner's world-plan.md is approved by reviewer.
- Read GDD + world-plan
- Apply genre-pattern matching
- Write level-design.md
- Return summary: dimensions, placement count, key choke points,
  validation against aesthetic
- Orchestrator may invoke game-reviewer to review level-design as
  well (catches "shallow layout" before content-designer commits)

## Reference files

- `docs/guideline/30_framework_primitives.md` — what the engine can express
- `docs/guideline/32_mda_for_yume.md` — aesthetic vocabulary
- `godot/scripts/engine/instance_patterns.gd`
  — the placement primitives (ring/grid/scatter/line/cluster)
  available to content-designer
- `godot/data/demo_*/entities/zz_instances.json`
  — example placement files (good and bad)

## Composition pass (added 2026-05-18)

After all entities are placed, run the **composition pass** before
declaring the level done. This is the difference between "everything
fits in the map" and "the scene feels like a designed space."

Reference the 10-axis checklist in `.claude/rules/soul.md`
§Composition pass. For 3D scenes specifically:

**Cardinal arrangement** — for camp / village / hub scenes, place
8-12 major structures at compass points around a single focal
anchor (fire pit, well, statue, throne). Each structure ~8-12m
from focus, yaw facing toward center. Reads as "this is a camp"
instead of "things were scattered."

**Structure exclusion for procedural scatter** — when placing
procedural trees / grass / stones, REJECT candidates within a
per-structure radius. Without this, trees clip through houses.
Typical radii: huts 3.5m, lean-to 2.5m, fire-pit 4m (with extra
clearing), market-stall 3m, well/workbench 2m, props 1-2m.

**Density falloff rings** — forest scatter should be TIGHT around
the camp edge (e.g. 8-20m ring), NOT uniformly scattered to map
edge. Reference "forest hugs camp" feel. Drop the sparse far-
wilderness ring entirely if it reads as empty.

**Tree-tree de-overlap** — pairwise min-distance 0.9-1.2m so trees
don't clip into each other. Generate 2-3× candidates, accept those
that pass the filter.

**Path splatmap** — for camp scenes with a multi-biome ground
shader (see yume-asset-designer §visual.shader and
`data/lib/shaders/ground_multi_biome.gdshader`), generate the
splatmap with radial paths from focal point to each landmark
(~3m wide cleared trails). Procedurally derive via Python script
(noise + line-distance to each landmark endpoint).

**Map size discipline** — keep `ground.mesh.size` to ~2× the play
area. Larger map = more sparse forest = "tech demo" feel. For a
25m-radius camp, 80m × 80m is right; distance fog (from
lighting-designer's `fog` block) covers the seam beyond.

**Empirical case 2026-05-18 (aldenmere)**: shipped with 400×400m
ground + uniform tree scatter — felt like a forest scene placed
on an empty parking lot. Cut to 80×80m, tightened forest to 8-20m
ring, arranged cardinal structures, added structure-exclusion to
the scatter — composition transformed without changing any assets.
