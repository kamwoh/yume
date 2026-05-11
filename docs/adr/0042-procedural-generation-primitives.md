# ADR 0042 — Procedural-generation primitives

_Date: 2026-05-11_
_Status: proposed (umbrella; accept-with-conditions 2026-05-11) — engine session deferred until a game pitch triggers a sibling implementation_

## Context

Yume's current "procedural" surface is the `instance_patterns.gd`
module (ADR-implied; landed earlier): scatter / cluster / ring /
grid / line / mirror, with optional `level_seed` for determinism.
That covers "scatter 40 trees randomly each playthrough" cleanly.

What it does NOT cover, per the deferred note in `task_plan.md`:

1. **Terrain heightmap / noise biomes** — ground is a single flat
   plane (`PlaneMesh` in the per-game `.tscn` scene). No Perlin /
   Simplex. No per-tile generation. Players can't have rolling hills,
   coastlines, mountain ranges, biome transitions.
2. **Room / dungeon layout generation** — Sokoban + merchant
   dungeons are hand-authored ASCII diagrams. No BSP / Wave Function
   Collapse / random-walk room generation. Roguelike floors are
   blocked on this.
3. **Infinite / streaming procedural worlds** — `chunk_streamer.gd`
   streams **pre-authored** chunks from disk. A "generate chunk on
   first visit" hook + persistent-per-chunk seed would let games
   describe a generator function in JSON instead of materializing
   every chunk explicitly.

The framework's positioning ("ambitious-density, JSON-driven, any
sim-shaped game") is hampered by these gaps. A factory sim wants a
varied terrain. A roguelike wants unique floors per run. A
sandbox-sim wants an effectively-infinite world. None ship cleanly
in Yume today.

## Decision

Split into **three sibling ADRs**, each scoped to one sub-category,
each implementable independently. This proposal is the umbrella —
ADRs 0042-A, 0042-B, 0042-C land separately as scope demands.

The umbrella declares **shared design discipline** across the three:

- JSON-declarative authoring; no game-specific GDScript.
- Deterministic via seed (mirrors `level_seed` from
  instance_patterns).
- Eligibility opt-in (mesh-def / entity-def flag) — backward-
  compatible.
- Per-chunk lazy materialization where applicable (consistent with
  `chunk_streamer.gd` design).
- Tech-director gates each sub-ADR independently before its engine
  session.

### Sibling ADRs (numbered post tech-director review 2026-05-11)

The implementable children each become their own top-level ADR
when triggered. The umbrella (this document) stays as the
architectural rationale:

1. **ADR 0043 — Terrain noise primitive** (highest universal value;
   pure render + zone primitive)
2. **ADR 0044 — Streaming procgen extension** (smallest delta —
   extends `chunk_streamer.gd`)
3. **ADR 0045 — Dungeon layout generation** (largest single-game
   value but smallest cross-game reach)

The four sections below describe each sibling as `0042-A/B/C`
historical labels; the labels map to ADRs 0043/0044/0045 at
implementation time.

Rationale: terrain noise unlocks open-world / sandbox games and any
existing 3D demo can sit on noise terrain transparently. Streaming
extension is mostly an extension of existing chunk_streamer, so
small delta. Dungeon layout is high-value for roguelikes but only
roguelikes — narrowest reach.

### 0042-A — Terrain noise primitive (this ADR proposes first)

**Goal:** a JSON-declared terrain block in scene.json (or a dedicated
`world/terrain.json`) that yields a heightmapped ground mesh at world
load. Generator is Godot's `FastNoiseLite` exposed via JSON; the
engine samples it on a grid and builds a mesh.

```jsonc
// world/terrain.json
{
  "_comment": "Terrain noise — heightmap ground generated from FastNoiseLite. Replaces the per-game .tscn scene's flat PlaneMesh ground. Authored as one block; engine builds the mesh at world load.",
  "extent": {
    "x_min": -80, "x_max": 80,
    "z_min": -80, "z_max": 80,
    "cell_size": 2.0
  },
  "height": {
    "noise": {
      "seed": 4412,
      "frequency": 0.012,
      "octaves": 4,
      "lacunarity": 2.0,
      "gain": 0.5,
      "type": "simplex"
    },
    "amplitude": 4.5,
    "offset": -0.5
  },
  "biomes": [
    {"height_lt":  0.0, "color": "#3a6a8c", "name": "water"},
    {"height_lt":  0.5, "color": "#8a7050", "name": "beach"},
    {"height_lt":  3.0, "color": "#487830", "name": "grass"},
    {"height_lt":  6.0, "color": "#5a5048", "name": "rock"},
    {                   "color": "#dad6c8", "name": "snow"}
  ],
  "blocks_motion_below": -0.2,
  "_comment_blocks_motion": "Entities can't enter cells where height < this threshold. Used for 'water blocks ground walkers' without authoring per-tile collision."
}
```

**Engine work:**

- New module `terrain_director.gd` (~250 lines): parses terrain.json,
  builds an `ArrayMesh` with per-vertex height + per-cell color
  (vertex-color material). One mesh covering the extent; one
  MeshInstance3D added to World.
- Optional `terrain_chunk.gd` integration for streaming: chunks
  generate their own slice on first visit (defers full
  materialization).
- Biome-gated rules use **zone_store (ADR 0031)** via the existing
  `in_zone:` query operator — **no new QueryLib operator**.
  terrain_director writes biome zones at world load (one zone per
  `biomes[]` entry: `terrain_water`, `terrain_grass`,
  `terrain_rock`, `terrain_snow`, etc.). Naming convention
  `terrain_<biome>` to prevent collision with hand-authored zones.
  Per tech-director review condition #1 (2026-05-11) — coupling
  QueryLib to a terrain-specific concept violates universality.
- Engine hook in `world.gd` `_integrate_motion`: clamp entity
  positions to terrain height (snap-to-surface for entities
  tagged `ground_walker`). Avoids manual y-positioning per
  entity instance.

**Per-instance positioning:** patterns (`scatter`, `cluster`) gain
optional `place_on_terrain: true` — instance positions get their y
clamped to terrain height at world-load time. Trees in a forest
scatter all follow the terrain slope without manual authoring.

**.tscn Ground interaction (per tech-director review condition #2,
2026-05-11):** when adopting terrain.json, the author manually
removes the PlaneMesh `Ground` node from the per-game `.tscn`.
Cheaper than engine-side scene-tree introspection. Documented in
the `yume-asset-designer` skill at sibling-ADR implementation
time.

### 0042-B — Dungeon layout generation (sketch)

Sibling ADR. Defer full proposal. Sketch:

- New `world/dungeon_layout.json` declares: room count, min/max
  room size, corridor width, generator algorithm (BSP / random-walk
  / WFC).
- Engine generates a 2D grid of cell types (wall / floor /
  corridor) at world load.
- Cells materialize as entity instances (wall tiles, floor tiles)
  via the existing pattern primitives.
- Deterministic via `level_seed`.

Comparable scope to ADR 0041's MultiMesh — ~2-3 days engine work
when the time comes.

### 0042-C — Streaming procgen extension (sketch)

Sibling ADR. Smallest delta. Extends `chunk_streamer.gd`:

- New `chunks/_generator/<name>.json` declares: per-chunk seed
  derivation, generator function name (registered in engine), JSON
  arguments.
- When chunk_streamer loads a chunk that has no
  `chunks/<x>_<z>/entities.json`, calls the generator function
  with `(chunk_x, chunk_z, seed)` → returns an entities-shaped
  Dictionary; loads as if it were a hand-authored chunk.
- Cache generated chunks to disk after first visit (or keep
  in-memory and re-generate on eviction — author chooses).

Comparable scope: ~1-2 days. Builds on 0042-A (terrain) and
existing `chunk_streamer`.

## Consequences

### Positive

- Open-world / sandbox games become viable in Yume.
- Roguelike floors stop being a hand-author bottleneck.
- Cross-game shared library: noise + biome patterns become reusable
  across factory / sandbox / roguelike / city-builder genres.
- All three sub-categories ship deterministically (seed-based) — same
  replay-friendliness as instance_patterns.

### Negative

- Generated geometry costs RAM. Mitigated by MultiMesh (ADR 0041)
  for batched terrain tiles + chunk_streamer eviction.
- Authors lose some hand-craft control. Eligibility opt-in keeps
  small games on flat ground; only games that opt in pay the
  authoring complexity.
- `terrain_director.gd` adds ~250 lines of engine code. New domain.

### Neutral

- Adds 1-3 new JSON config files (`world/terrain.json`,
  `world/dungeon_layout.json`, `chunks/_generator/*.json`).
- Adds 1-3 new engine modules.
- New mesh-def field: `place_on_terrain: true` (scatter / cluster
  patterns).

## Alternatives considered

### A) Continue authoring everything by hand

What we do today. Acceptable for the dozen demos in `data/demo_*/`
because each is small. Doesn't scale to "ship 10 procedurally
distinct levels per game" or "1km × 1km open world."

### B) Drop down to Godot directly via .tscn / .gd

Possible but breaks the JSON-only contract (Invariant #1). Yume's
universality argument relies on content being JSON; tipping over to
per-game GDScript for procgen erodes it.

### C) External tool generates content, imports as static JSON

Author runs a Python tool that generates `entities/_procgen.json`,
checks it in. Works for finite small worlds but loses
runtime seed variation. Acceptable interim if engine work is
deferred — already partially possible via `instance_patterns`
patterns. Doesn't solve infinite / per-run variation.

## Implementation sketch (0042-A, the first sibling)

Per-day breakdown:

1. **Day 1**: Build `terrain_director.gd`. Parse `world/terrain.json`,
   build an `ArrayMesh` from noise samples + biome lookup. Add as
   child of World at world load. Test against a tiny synthetic
   terrain.json.
2. **Day 2**: Integrate with scatter / cluster patterns —
   `place_on_terrain: true` clamps generated positions to terrain
   height. Test: an Aldenmere-style 100-tree scatter follows the
   slope without manual y-authoring.
3. **Day 3**: Motion clamp + `ground_height_lt` query operator.
   `ground_walker`-tagged entities snap to terrain height each tick.
   New query operator for biome-gated rules.

## Risk

- **Performance**: a 160m × 160m terrain at 2m cells = 80 × 80 = 6400
  vertices. Cheap. But naive per-cell generation as separate mesh
  nodes would blow draw calls — must build one big ArrayMesh (covered
  in implementation sketch).
- **Determinism edge case**: noise seed must be applied to the noise
  generator instance, not the global PRNG (FastNoiseLite has its
  own seed). Easy to miss; document + test.
- **Water-as-blocker**: when `blocks_motion_below` is declared, the
  motion integrator needs to consult the terrain — slight per-tick
  cost. Mitigated by caching terrain height per entity (recomputed
  only when entity moves into a new cell).

## Tech-director review pending

Per ADR discipline this needs gating. Invariant audit pre-check:

- **#1 JSON-only**: All three sub-ADRs author content as JSON.
  No game-specific GDScript. ✅
- **#2 No semantic effects**: No new game-state effects; pure
  content-generation primitives. ✅
- **#3 No entity hierarchy**: Generated entities use existing
  Entity + tags. ✅
- **#5 Queries first-class**: New `ground_height_lt` operator
  goes through QueryLib (extends `_compare`). ✅
- **#8 Engine = primitives + interpreter**: Engine ships the
  generators (terrain noise / dungeon BSP / chunk gen); JSON
  composes them. ✅
- **#9 Phase boundaries**: terrain_director runs at world-load only;
  no tick interaction. ✅
- **#10 Freeze policy**: terrain doesn't generate during freeze;
  ground_walker motion clamp doesn't fire under freeze (motion
  integrator already gates on freeze). ✅
- **#11 Level discontinuity**: terrain re-builds on transition_level
  if the new level's terrain.json differs. Add cleanup hook
  symmetric to ADR 0041's. ✅ (note in implementation)
- **#12 Persistent guard**: terrain is not an Entity; persistent
  tag guard doesn't apply. ✅

Expect tech-director ACCEPT with conditions on:
- Per-sibling-ADR splitting (this umbrella may not need
  implementation — the three children do)
- Scoping which sibling to start with (recommend 0042-A)
- Performance budget for terrain mesh (ArrayMesh size, vertex
  count cap)
- Backward-compat: existing demos with hand-authored .tscn ground
  must keep working (terrain.json absent = no change)

## Tech-director review

_Date: 2026-05-11_
_Reviewer: yume-tech-director_
_Verdict: **accept-with-conditions; implementation deferred until a
game pitch triggers it**_

Invariant audit passes for the umbrella structure (#1, #2, #3, #8,
#9, #10, #11, #12). Invariant #5 surfaces one concrete primitive
choice that must change before any sibling ADR (especially 0042-A)
goes to engine session — see Condition #1.

The umbrella is a useful spec artifact: it documents the design
space so future-you (or a future agent) starts from a validated
shape instead of re-deriving. Approving the umbrella itself with
three conditions; engine work stays gated.

### Conditions

**1. Drop `ground_height_lt` query operator. Route biome gating
through zone_store (ADR 0031) instead.**

Coupling QueryLib to a terrain-specific field violates the
universality claim — games without procedural terrain don't have
a ground_height. Use the existing zone primitive:

```jsonc
// Rule that only fires for entities in a grass biome
{
  "trigger": {"type": "tick", "interval": 10},
  "query": {
    "tags_all": ["rabbit"],
    "in_zone": "terrain_grass"
  },
  "effect": [ ... ]
}
```

terrain_director writes biome zones at world load (one zone per
`biomes[]` entry — e.g., `terrain_water`, `terrain_grass`,
`terrain_rock`, `terrain_snow`). Zones are first-class per ADR
0031; the `in_zone:` operator already exists.

Benefits:
- Reuses existing query primitive — no new QueryLib operator.
- Generalizes: a hand-authored game can ALSO author zones in
  `world/zones.json` to get biome-gated rules without procedural
  terrain.
- Decouples query vocabulary from rendering domain.

Naming convention: `terrain_<biome_name>` to prevent collision
with hand-authored zones in the same game. Document in the
sibling ADR (0043 when it lands).

Edit the ADR to remove the `ground_height_lt` paragraph + replace
with the zone-store routing. Note: the JSON `biomes[]` array stays;
the engine consumes it to populate zone_store at world load (not
to extend QueryLib).

**2. Document interaction with existing `.tscn` Ground PlaneMesh.**

When a game has BOTH terrain.json AND a PlaneMesh Ground node in
its scene (.tscn), the terrain mesh overlays the existing ground —
two surfaces render. This is acceptable when the terrain.json's
y_range covers the .tscn ground's y=0 (the terrain hides the plane
visually) but creates ambiguity in edge cases.

Pick one strategy and document it in the sibling ADR:
- **Author option (recommended)**: when adopting terrain.json, the
  author manually removes the Ground node from the .tscn. Document
  in `yume-asset-designer` skill. Cheaper — no engine logic.
- **Engine option**: terrain_director queries the scene tree for a
  node named "Ground" or tagged "engine_managed_ground" and removes
  or hides it before mesh build. More magic; harder to debug.

Either way, the sibling ADR must state which strategy is in force +
why.

**3. Defer implementation until a game pitch triggers it.**

Per the project's "build only what's required" discipline (visible
in the 16 demos that all ship with flat ground without complaint),
there's no current game pitch demanding procedural terrain.
Aldenmere = flat. merchant = flat. doomarena3d = flat. fpsgarden =
flat. towerdef3d = flat. The pipeline has been productive without
the primitive.

Building 0042-A speculatively would burn ~3 days that should fund
Phase 1 v2 (Aldenmere full 30-day arc) or a new game pitch. Per
Yume's tier-2.6t principle (build the primitive when the second
game wants it), the trigger is:

- A game pitch arrives that explicitly requires terrain (rolling
  hills, coastlines, biome transitions for a sandbox/sim),
- OR a roguelike pitch arrives that needs dungeon layout
  generation (triggers 0042-B / ADR 0045 sibling),
- OR a sandbox / open-world pitch needs streaming procgen
  (triggers 0042-C / ADR 0044 sibling),
- OR the user explicitly requests starting a procedural-content
  game.

When the trigger fires: tech-director re-reviews the ADR for
freshness (engine evolution may have moved primitives the ADR
references), then stamps the relevant sibling ADR `accepted` for
engine session.

### Sibling-ADR splitting (clarification)

ADR 0042 stays an UMBRELLA design document — proposed status,
architectural rationale, shared discipline. When implementation
triggers, the implementable child becomes its own top-level ADR:

- **ADR 0043** — Terrain noise primitive (was 0042-A in this umbrella)
- **ADR 0044** — Streaming procgen extension (was 0042-C)
- **ADR 0045** — Dungeon layout generation (was 0042-B)

Each child ADR cites this umbrella for shared discipline; the
umbrella stays as the "why we're doing this family of work" record.

### Backward-compat reaffirmed

terrain.json absent → terrain_director not instantiated → all
existing demos behave identically. The umbrella's promise holds.
Sibling ADRs must reaffirm this at their own time.

### Approval

ADR 0042 (umbrella) → **proposed (accepted-with-conditions)**.
Status stays `proposed` — engine session does NOT begin from this
ADR. Conditions 1-2 must be reflected in the umbrella's text now
(or noted as "deferred to sibling ADR 0043"). Condition 3 is the
trigger gate; no engine code lands until a sibling ADR is
explicitly stamped `accepted` by tech-director.

The umbrella serves as a waiting spec — useful for future-self
without committing engine bandwidth today.
