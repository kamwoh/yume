---
name: yume-scene-class-catalog
description: Stage 2 of the text-to-world pipeline (2026-05-25). Reads a scene brief + reference photoreal aerial and produces a fully-dynamic per-scene class catalog plus the stage-3/4/5 prompts. Class count is dynamic 6-32; classes named freely per genre (medieval town vs sci-fi colony vs dungeon vs alien world all get entirely different catalogs). data/lib/semantic_palette.json provides palette conventions; data/lib/extraction_strategies.json provides per-class extraction strategies (extraction_method + rotation_rule + y_anchor + primitive + canonical size) that the catalog injects into each object_placement entry so stage-5 lib_extract can dispatch by name lookup. Outputs class_catalog.json, semantic_map_prompt.txt, heightmap_prompt.txt, and scene_biome_mapping.json (for ADR 0055 engine wiring).
---

# /yume-scene-class-catalog

You are the **stage-2 author** for Yume's text-to-world pipeline.
You read a SCENE BRIEF (prose) and a REFERENCE PHOTOREAL AERIAL
(stage 1 output) and you produce the structured catalog + prompts
that drive stages 3-7.

**Every scene gets its own catalog.** A medieval town's classes
look nothing like a sci-fi colony's, which look nothing like a
dungeon's. The lib gives you conventions + a genre cheat-sheet —
NOT a fixed class list to copy. Each catalog is dynamic.

## When to invoke

- After stage 1 has produced a photoreal top-down reference
- Before stages 3 (semantic map gen) / 4 (heightmap gen) / 5 (extraction)
- Whenever a new scene is being prepped for the pipeline

## When NOT to invoke

- For HUD / screen authoring → those are the locked 2D pipelines
- For single-asset prompts → yume-asset-designer
- For per-game GDD writing → yume-game-designer

## Inputs

1. **Scene brief** — one or two sentences describing the world
2. **Reference photoreal aerial** — PNG path from stage 1
3. **Optional** — game id, genre hint, required-class list from GDD

## Outputs (FOUR files)

| File | Purpose |
|---|---|
| `/tmp/_class_catalog.json` | Per-scene catalog: classes + hex + intent_type + descriptions + counts |
| `/tmp/_semantic_map_prompt.txt` | Ready-to-feed at stage 3 (`openai_images.edits` with reference) |
| `/tmp/_heightmap_prompt.txt` | Ready-to-feed at stage 4 (`openai_images.edits` with reference) |
| `/tmp/_scene_biome_mapping.json` | For ADR 0055 engine wiring — maps each `terrain_shader` class to a biome shader slot |

## The procedure

### Step 1 — Read the conventions lib

```bash
cat godot/data/lib/semantic_palette.json
```

Note the THREE things this file gives you:
- **`intent_types`** — the only TRULY fixed part. Three types:
  `terrain_shader` / `terrain_displacement` / `object_placement`.
- **`hex_picking_algorithm`** — rules for picking distinct hexes
  (hue spacing ≥25°, sat/val rules per intent type, avoid 0/255
  extremes, etc.) + `starting_hue_anchors` for common terrain
  (grass / water / sand / snow / lava / etc.) as conventional
  defaults.
- **`genre_cheat_sheets`** — common-class suggestions per genre
  (medieval_town, sci_fi_colony, modern_city, dungeon_interior,
  alien_world, post_apocalyptic, natural_wilderness, underwater).
  Use as INSPIRATION, not a list to copy.

### Step 2 — Detect genre + scene scope

Read the brief + look at the reference image. Infer:
- **Genre** — which cheat-sheet (if any) is relevant?
  ("fortified medieval town" → medieval_town,
   "abandoned mars colony" → sci_fi_colony,
   "lush alien rainforest with bioluminescent flora" → alien_world)
- **Scope** — how many classes does this scene genuinely need?
  - Tiny scene (single room, small camp): 6-10 classes
  - Standard scene (town, dungeon, biome): 10-20 classes
  - Rich scene (city, complex landscape, multi-region): 20-32 classes
- **Topography** — flat, hilly, mountainous, multi-level, etc.
  Drives the heightmap_hints.

### Step 3 — Pick the class list (FULLY DYNAMIC)

For each feature visible in the reference:

1. Name it in lowercase_snake_case ("solar_panel", "crystal_spire",
   "townhall", "kelp_forest"). The name describes the SPECIFIC
   thing in THIS scene, not a generic placeholder.

2. Pick a hex per the algorithm in `hex_picking_algorithm`:
   - Conventional terrain (grass, water, sand, etc.) → use the
     `starting_hue_anchors` default UNLESS the scene's aesthetic
     demands a variant ("autumn forest" might want #4a6020 instead
     of #2a5a2a; "blood lake" might want #802020 instead of
     #3070c0). Override conventions when intent demands.
   - Per-scene classes (genre-specific buildings, alien flora,
     etc.) → pick a hex that satisfies pairwise distinctness
     (hue ≥25° apart from every existing class, or sat/val
     differentiation if hue overlaps).

3. Pick an intent_type:
   - `terrain_shader` — ground cover, one big plane biome
   - `terrain_displacement` — elevation feature (no hex; lives in
     heightmap_hints)
   - `object_placement` — discrete entity (specific count expected)

4. Add a `description` — what does this class represent? Stage 6
   asset gen will read it.

5. Add count/coverage estimate:
   - `terrain_shader` → `expected_coverage_pct` (rough %)
   - `object_placement` → `expected_count` (rough integer)

6. Repeat until every feature has a class. Don't over-collapse
   ("trees" vs "trees + flowers + bushes" — distinguish if the
   scene genuinely has them; don't pad if it doesn't).

### Step 4 — Sanity-check the catalog

Before writing files, verify:

- **Count**: 6 ≤ N ≤ 32 classes. If outside, adjust (combine close
  classes or split too-broad ones).
- **Hex distinctness**: pairwise hue ≥25° OR sat/val differentiation
  ≥0.25 for similar-hue pairs. The downstream extractor will
  color-threshold; ambiguous hexes break it.
- **Intent balance**: most scenes have 30-60% `terrain_shader`,
  40-60% `object_placement`, 0-10% `terrain_displacement`. If your
  catalog is 90% `object_placement`, the ground will look bare —
  reconsider what terrain biomes are present.
- **Coverage adds up**: terrain_shader percentages should sum to
  ≥80% (the rest is occluded by `object_placement` items + their
  shadows). If your percentages sum to 40%, you're missing
  background terrain.

### Step 4b — Look up extraction strategy per class

```bash
cat godot/data/lib/extraction_strategies.json
```

For each `object_placement` class in your catalog, look up its
extraction strategy. The strategy library is keyed by class name.
Three resolution paths:

1. **Exact class-name match** — `house`, `tower`, `bridge`,
   `fountain`, `wall_segment`, `tree`, `rock`, `well`, `statue`,
   `townhall`, `crystal_spire`. Use the matched entry verbatim.
2. **Alias match** — `class_aliases` maps synonyms to canonical
   entries (e.g. `small_house` → `house`, `palace` → `townhall`,
   `watchtower` → `tower`, `wooden_bridge` → `bridge`). Use the
   resolved canonical entry.
3. **No match** — for a novel class (`solar_panel`, `crystal_spire`,
   `spore_pod`, `tentacled_tree`), pick the best fit from the
   `default_strategy` block, BUT override the dimensions to match
   the class's intent. Common patterns:
   - Tall thin object (antenna, spire, lamp): override
     `primitive: prim_unit_cylinder`, `canonical_size_meters:
     [W, H, W]` with H >> W.
   - Wide flat object (panel, deck, mat): override
     `primitive: prim_unit_box`, `canonical_size_meters: [W, 0.3, D]`.
   - Round blob (boulder, pod, dome): override
     `primitive: prim_unit_sphere`.
   - Building-like: keep box primitive; pick size proportional to
     `expected_count` (rarer = larger).
   Document this as `"strategy_origin": "default_with_override"` in
   the class entry so downstream reviewers know it wasn't a clean
   lookup.

Inject the resolved strategy block INTO each class entry. The
catalog entry now looks like:

```json
{
  "name": "house",
  "hex": "#a04020",
  "intent_type": "object_placement",
  "description": "Townspeople dwellings",
  "expected_count": 60,
  "design_origin": "convention",
  "strategy": {
    "strategy_origin": "lib_exact_match",
    "extraction_method": "cluster_extract",
    "cluster_within_meters": 2.0,
    "min_area_px": 50,
    "rotation_rule": "face_nearest_road",
    "y_anchor": "heightmap_sample",
    "primitive": "prim_unit_box",
    "canonical_size_meters": [3.0, 4.0, 3.0],
    "canonical_front_axis": "-Z"
  }
}
```

`strategy_origin` values:
- `"lib_exact_match"` — class name found in `classes`
- `"lib_alias_match:<canonical>"` — found via `class_aliases`
- `"default_with_override"` — used `default_strategy` + overrides

`terrain_shader` and `terrain_displacement` classes get no
`strategy` block — they're rendered by the ground shader, not
spawned as discrete entities.

### Step 5 — Add heightmap_hints

```json
{
  "expected_topography": "mostly_flat | hilly | mountainous | coastal | crater | terraced | multi_level",
  "low_regions": ["river_bed", "pond_bottom", "crater_floor"],
  "high_regions": ["hilltop", "fortress_mound", "tower_peak"],
  "elevation_range_estimate_meters": [low_m, high_m]
}
```

For dungeons / multi-level scenes, encode the lowest/highest floor
heights here. For open-world, encode the lowest valley / highest
peak.

### Step 6 — Compose the four output files

#### A. `_class_catalog.json`

```json
{
  "scene_brief": "<echoed>",
  "reference_image": "<path>",
  "image_size": [W, H],
  "genre_hint": "medieval_town | sci_fi_colony | ...",
  "classes": [
    {"name": "<lowercase_snake>", "hex": "#rrggbb",
     "intent_type": "terrain_shader|terrain_displacement|object_placement",
     "description": "<what is this>",
     "expected_coverage_pct": <float>,    // for terrain_shader
     "expected_count": <int>,             // for object_placement
     "design_origin": "convention | per_scene_extension",
     "strategy": { ... per Step 4b — REQUIRED for object_placement, OMITTED for others ... }
    }
  ],
  "heightmap_hints": { ... per step 5 ... },
  "composition_notes": "<sentence describing layout / focal point / asymmetries>",
  "_generation_meta": {
    "skill": "yume-scene-class-catalog",
    "version": "2026-05-25b",
    "n_classes": <int>,
    "intent_breakdown": {"terrain_shader": N, "object_placement": N, "terrain_displacement": N}
  }
}
```

#### B. `_semantic_map_prompt.txt`

```
TECHNICAL DIAGRAM — solid color regions only — like MS Paint with
the bucket fill tool. ZERO decoration. ZERO texture. ZERO shadows.
ZERO outlines. ZERO text. ZERO labels. ZERO icons. ZERO illustrated
trees as separate shapes. ZERO illustrations. ZERO photoreal style.

The attached reference is for LAYOUT ONLY. PRESERVE THE EXACT
SPATIAL LAYOUT but REPLACE all painted detail with FLAT solid
color blocks. THROW AWAY the reference's visual style; keep only
its layout.

SCENE CONTEXT (from catalog):
<composition_notes>

PALETTE — use ONLY these {N} hex colors, NO others:
- {hex1} {name1} — {description1}
- {hex2} {name2} — {description2}
... (one line per class)

ABSOLUTE RULES:
- Use ONLY these {N} hex colors. Any other color = failure.
- ZERO text, ZERO icons, ZERO trees illustrated.
- ZERO shadows, ZERO gradients.
- {W}x{H} square output.
- Output: a child's MS Paint sketch, NOT a beautiful map.
```

#### C. `_heightmap_prompt.txt`

```
Convert the attached reference into a TERRAIN HEIGHTMAP — a
grayscale image where pixel brightness encodes GROUND ELEVATION,
not building or object height.

PIXEL CONVENTION:
- white (255) = highest terrain
- black (0) = lowest terrain (water, pit, void)
- mid grey (128) = average ground level

EXPECTED TOPOGRAPHY: <expected_topography>
<topography-specific guidance>

LOW REGIONS (dark to near-black): <list from heightmap_hints>
HIGH REGIONS (bright to white): <list from heightmap_hints>
ELEVATION RANGE: <low>-<high> meters

WHAT TO IGNORE:
- ALL building roofs, walls, towers, columns, statues, vehicles,
  machinery → set FOOTPRINT to SAME grey as surrounding ground.
- ALL roads, paths, plazas, surface textures → ground grey.

WHAT TO PRESERVE:
- Water bodies → dark-to-near-black with smooth bank gradient.
- Real terrain elevation → grey gradient.

ABSOLUTE RULES:
- NO color (grayscale only).
- NO building bumps, NO walls as ridges.
- {W}x{H} grayscale output.
- Topographic data file, NOT a beautiful illustration.
```

#### D. `_scene_biome_mapping.json`

Maps each `terrain_shader` class to a biome slot for ADR 0055
engine wiring. The engine's ground shader reads the semantic map +
this mapping at level load.

```json
{
  "reference_semantic_map": "/path/to/semantic_map.png",
  "reference_heightmap": "/path/to/heightmap.png",
  "biome_slots": [
    {"slot": 0, "name": "<terrain_class_name>", "hex": "#rrggbb",
     "shader_uniform_prefix": "biome_<n>", "description": "..."},
    ...
  ],
  "note": "Each biome slot maps to scene.json.ground.mesh.shader_params.biome_color_N. Stage 7 wires these into the per-game scene.json automatically."
}
```

## Strict rules

1. **No fixed class taxonomy.** A medieval town's classes are
   entirely different from a sci-fi colony's. The cheat-sheet is
   INSPIRATION, not a copy-paste list. Pick what THIS scene needs.

2. **Convention before innovation.** When a generic terrain
   (grass, water, sand, snow, lava) is in the scene, use the
   convention from `starting_hue_anchors` unless the scene's
   aesthetic demands a variant. Distinctness across games is
   useful when the engine wiring can be shared.

3. **Distinctness is enforced.** Pairwise hue ≥25° OR sat/val ≥0.25
   for similar-hue pairs. This is required by the downstream
   extractor's color-threshold step.

4. **Class count = 6-32.** Past 32, distinctness erodes. Combine
   adjacent concepts (small_house + medium_house → house) before
   adding more colors.

5. **terrain_displacement gets NO hex.** Encoded in heightmap.png,
   not in the semantic map. Mention in heightmap_hints.

6. **Intent type is objective.** A wall is `object_placement` even
   if it's a long thin strip (collision geometry). A cobblestone
   road is `terrain_shader` even if it could be thought of as
   tiles (the shader handles it more efficiently).

7. **Every object_placement class gets a `strategy` block.** Look
   up via `extraction_strategies.json` (exact name → alias →
   default-with-override). Stage-5 `lib_extract` dispatches off
   the strategy block — without it, the class can't be extracted.
   `terrain_shader` + `terrain_displacement` classes get NO
   strategy.

## Worked examples (three genres, three catalogs)

### Example 1 — Medieval town (matches what we tested)

```json
{
  "genre_hint": "medieval_town",
  "classes": [
    {"name": "grass", "hex": "#a0d870", "intent_type": "terrain_shader", "expected_coverage_pct": 30},
    {"name": "forest", "hex": "#2a5a2a", "intent_type": "terrain_shader", "expected_coverage_pct": 15},
    {"name": "water_surface", "hex": "#3070c0", "intent_type": "terrain_shader", "expected_coverage_pct": 8},
    {"name": "cobblestone", "hex": "#c8a878", "intent_type": "terrain_shader", "expected_coverage_pct": 8},
    {"name": "dirt_path", "hex": "#8a6a40", "intent_type": "terrain_shader", "expected_coverage_pct": 3},
    {"name": "farm_field", "hex": "#208040", "intent_type": "terrain_shader", "expected_coverage_pct": 6},
    {"name": "house", "hex": "#a04020", "intent_type": "object_placement", "expected_count": 60},
    {"name": "townhall", "hex": "#c02040", "intent_type": "object_placement", "expected_count": 1},
    {"name": "wall_segment", "hex": "#9a9080", "intent_type": "object_placement", "expected_count": 8},
    {"name": "tower", "hex": "#707070", "intent_type": "object_placement", "expected_count": 12},
    {"name": "bridge", "hex": "#704020", "intent_type": "object_placement", "expected_count": 2},
    {"name": "fountain", "hex": "#e040a0", "intent_type": "object_placement", "expected_count": 1}
  ]
}
```

### Example 2 — Mars colony (sci-fi)

```json
{
  "genre_hint": "sci_fi_colony",
  "classes": [
    {"name": "regolith", "hex": "#a08070", "intent_type": "terrain_shader", "expected_coverage_pct": 60},
    {"name": "ice_patch", "hex": "#c0d8e8", "intent_type": "terrain_shader", "expected_coverage_pct": 5},
    {"name": "lava_tube_floor", "hex": "#403038", "intent_type": "terrain_shader", "expected_coverage_pct": 4},
    {"name": "hab_module", "hex": "#e8e8f0", "intent_type": "object_placement", "expected_count": 8},
    {"name": "solar_array", "hex": "#202050", "intent_type": "object_placement", "expected_count": 12},
    {"name": "comms_tower", "hex": "#d0d000", "intent_type": "object_placement", "expected_count": 2},
    {"name": "drone_dock", "hex": "#20b0a0", "intent_type": "object_placement", "expected_count": 4},
    {"name": "airlock", "hex": "#e04040", "intent_type": "object_placement", "expected_count": 3},
    {"name": "rover", "hex": "#f08020", "intent_type": "object_placement", "expected_count": 2},
    {"name": "crater_marker", "hex": "#000000", "intent_type": "terrain_displacement"}
  ],
  "heightmap_hints": {
    "expected_topography": "crater_pocked",
    "low_regions": ["crater_floor", "lava_tube_entrance"],
    "high_regions": ["crater_rim"]
  }
}
```

(Note: completely different palette — silver/white hab modules,
saturated comm/airlock colors, regolith tan terrain. NONE of the
medieval-town classes apply.)

### Example 3 — Alien biolab world

```json
{
  "genre_hint": "alien_world",
  "classes": [
    {"name": "bioluminescent_moss", "hex": "#40e0c0", "intent_type": "terrain_shader", "expected_coverage_pct": 40},
    {"name": "spore_carpet", "hex": "#c040e0", "intent_type": "terrain_shader", "expected_coverage_pct": 15},
    {"name": "fungal_pool", "hex": "#a0e040", "intent_type": "terrain_shader", "expected_coverage_pct": 8},
    {"name": "crystal_field_floor", "hex": "#8040c0", "intent_type": "terrain_shader", "expected_coverage_pct": 10},
    {"name": "alien_water", "hex": "#206080", "intent_type": "terrain_shader", "expected_coverage_pct": 7},
    {"name": "crystal_spire", "hex": "#e0e0ff", "intent_type": "object_placement", "expected_count": 25},
    {"name": "spore_pod", "hex": "#ff8080", "intent_type": "object_placement", "expected_count": 40},
    {"name": "tentacled_tree", "hex": "#605040", "intent_type": "object_placement", "expected_count": 12},
    {"name": "egg_sac", "hex": "#f0e000", "intent_type": "object_placement", "expected_count": 8},
    {"name": "biofilm_dome", "hex": "#80c020", "intent_type": "object_placement", "expected_count": 5}
  ]
}
```

(Highly saturated, otherworldly palette — teal moss, magenta
spores, electric green pools. The whole color space differs from
medieval-town's earth tones.)

## What this skill is NOT

- NOT a generator of the semantic map → stage 3 (`openai_images.edits`)
- NOT the photoreal reference → stage 1 (`/yume-topdown-prompt`)
- NOT the extractor → stage 5 (`/yume-extract-author`, TBD)
- NOT a member of the locked 2D pipelines (HUD / screen)

## Reference files

- `godot/data/lib/semantic_palette.json` — palette conventions + cheat-sheets
- `godot/data/lib/extraction_strategies.json` — per-class strategy
  library (extraction_method + rotation_rule + y_anchor + primitive
  + canonical size) used in Step 4b
- `.claude/skills/yume-topdown-prompt/SKILL.md` — stage 1 sibling
- `.claude/skills/yume-extract-author/SKILL.md` — stage 5 consumer
  of the strategy blocks injected here
- `.claude/rules/pipeline-stability.md` — confirms this is in
  the ACTIVE 3D category, no ADR gate to change
