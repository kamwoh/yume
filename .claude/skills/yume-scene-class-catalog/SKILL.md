---
name: yume-scene-class-catalog
description: Stage 2 of the text-to-world pipeline (2026-05-25 design). Reads a scene brief + a reference photoreal aerial, and produces three artifacts that drive the rest of the pipeline — class_catalog.json (per-scene labels with hex colors and intent types: terrain_shader / terrain_displacement / object_placement), semantic_map_prompt.txt (ready to feed into openai_images /edits at stage 3), and heightmap_prompt.txt (ready to feed at stage 4). Library + override: base classes (grass, forest, water, road, house, wall, etc.) come from data/lib/semantic_palette.json with FIXED hexes so engine wiring is deterministic; per-scene additions (townhall, market, temple, etc.) draw from an extension palette of distinct colors. Empirical case: 2026-05-25 medieval-town stage-1 photoreal + stage-2 catalog generation pairs cleanly.
---

# /yume-scene-class-catalog

You are the **stage-2 author** for Yume's text-to-world pipeline.
You read a SCENE BRIEF (prose) and a REFERENCE PHOTOREAL AERIAL
(stage 1 output) and you produce the structured catalog + prompts
that drive stages 3, 4, and 5.

## When to invoke

- After stage 1 has produced a photoreal top-down reference
- Before stage 3 (semantic map gen) or stage 4 (heightmap gen)
- Whenever a new scene is being prepped for the pipeline

## When NOT to invoke

- For HUD / screen authoring → those are the locked 2D pipelines
- For single-asset prompts → yume-asset-designer
- For per-game GDD writing → yume-game-designer

## Inputs

1. **Scene brief** — one or two sentences describing the world
   (e.g. "a fortified medieval town beside a river with farmland",
   "post-apocalyptic raider settlement around a crashed cargo plane")
2. **Reference photoreal aerial** — PNG path from stage 1
3. **Optional** — game id (for context) or required-class hints
   from the GDD

## Outputs (three files)

### A. `/tmp/_class_catalog.json`

The structured class catalog. Schema:

```json
{
  "scene_brief": "<echoed from input>",
  "reference_image": "<path>",
  "image_size": [1024, 1024],
  "classes": [
    {
      "name": "grass",
      "hex": "#a0d870",
      "intent_type": "terrain_shader",
      "description": "Base ground vegetation outside the walls",
      "expected_coverage_pct": 40.0,
      "lib_origin": "base"
    },
    {
      "name": "townhall",
      "hex": "#c02040",
      "intent_type": "object_placement",
      "description": "Large central civic building, deep red roof",
      "expected_count": 1,
      "expected_size_pct": 4.0,
      "lib_origin": "extension"
    }
  ],
  "heightmap_hints": {
    "expected_topography": "mostly_flat | hilly | mountainous | coastal | crater | terraced",
    "low_regions": ["river_bed", "pond_bottom"],
    "high_regions": [],
    "elevation_range_estimate_meters": [0, 5]
  },
  "composition_notes": "octagonal wall, radial streets, river on east edge"
}
```

Field details:
- **`name`**: lowercase_snake_case. Matches an entry in
  `data/lib/semantic_palette.json` if `lib_origin == "base"`.
- **`hex`**: 6-digit hex with leading `#`. From the base lib for
  common classes; from extension_palette for per-scene classes.
- **`intent_type`**: one of:
  - `terrain_shader` — biome on the ground plane (one big mesh)
  - `terrain_displacement` — vertex displacement via heightmap (no
    color slot in semantic map — encoded in heightmap.png instead)
  - `object_placement` — spawned as Yume entities
- **`expected_coverage_pct`** (terrain_shader only): rough %
  of the image this class should cover. Helps the LLM-as-parser
  at stage 5 validate coverage.
- **`expected_count`** (object_placement only): rough count of
  instances of this class. Helps the script writer at stage 5.
- **`lib_origin`**: `"base"` (defined in semantic_palette.json) or
  `"extension"` (extension palette pick).

### B. `/tmp/_semantic_map_prompt.txt`

A ready-to-feed prompt for stage 3 (openai_images /edits with the
photoreal reference). Format:

```
TECHNICAL DIAGRAM — solid color regions only — like MS Paint with the
bucket fill tool. ZERO decoration. ZERO texture. ZERO shadows. ZERO
outlines. ZERO text. ZERO labels. ZERO icons. ZERO illustrated trees
as separate shapes. ZERO illustrations of any kind. ZERO photoreal style.

This is a CSS color palette test, NOT an illustration. Top-down 2D
layout. Each region is a perfectly FLAT solid block of ONE hex color.

The attached reference image is for LAYOUT ONLY. PRESERVE THE EXACT
SPATIAL LAYOUT (positions of every feature) but REPLACE all painted
detail with FLAT solid color blocks.

PALETTE — use ONLY these {N} hex colors, NO others:
- {hex1} {name1} — {description1}
- {hex2} {name2} — {description2}
...

ABSOLUTE RULES:
- Use ONLY these {N} hex colors. Any other color = failure.
- ZERO text, ZERO icons, ZERO trees illustrated.
- ZERO shadows, ZERO gradients, ZERO antialiasing beyond 1-2px edges.
- {W}x{H} square output.
- Output looks like a child's MS Paint sketch with the bucket fill tool.
```

(Compose by injecting the catalog's classes into the palette list.)

### C. `/tmp/_heightmap_prompt.txt`

A ready-to-feed prompt for stage 4. Format:

```
Convert the attached reference into a TERRAIN HEIGHTMAP — a grayscale
image where pixel brightness encodes GROUND ELEVATION (not building
or object height).

PIXEL CONVENTION:
- pure white (255) = highest terrain
- pure black (0) = lowest terrain (water surface, pond/river bed)
- mid grey (128) = average ground level

EXPECTED TOPOGRAPHY for this scene: {expected_topography}
{topography-specific guidance per the heightmap_hints}

WHAT TO IGNORE:
- ALL building roofs, walls, towers, columns, statues → set their
  FOOTPRINT to the SAME grey as the surrounding ground.
- ALL roads, paths, plazas → same ground grey.
- ALL surface textures → flat regions only.

WHAT TO PRESERVE:
- {low_regions} → encode as dark grey to near-black
- {high_regions} → encode as brighter grey to white
- Smooth gradients ONLY along elevation transitions

ABSOLUTE RULES:
- NO color (grayscale only, R=G=B per pixel).
- NO building bumps, NO walls as ridges, NO roads as different grey.
- {W}x{H} grayscale output.
- Looks like a topographic data file you'd feed to a vertex shader.
```

## The procedure

### Step 1 — Read the base palette

```bash
cat godot/data/lib/semantic_palette.json
```

Memorize the BASE classes (grass, forest, water_surface, cobblestone,
dirt_path, sand, snow, stone_floor, house, wall_segment, tower,
bridge, well, fountain, tree, rock) + their fixed hex codes.
Memorize the EXTENSION palette (8 distinct hexes for scene-specific
classes).

### Step 2 — Look at the reference image + read the scene brief

Identify which features are present:
- **Terrain** — what ground covers most of the image? (grass +
  forest + water are most common). What's the texture variation?
- **Topography** — flat? hills? valleys? river beds?
- **Structures** — what buildings / walls / objects are visible?
  Count them roughly.
- **Special features** — anything that needs a scene-specific class
  not in the base palette (e.g. "this game has a temple", "this
  scene has a crashed plane")

### Step 3 — Pick the class catalog

For each visible feature:

- If it matches a BASE class, use the base entry's hex + intent_type.
- If it's scene-specific, pick a hex from the EXTENSION palette:
  - `townhall` / `palace` → `#c02040` (deep red)
  - `temple` / `shrine` → `#9060c0` (purple)
  - `forge` / `workshop` → `#e08040` (orange)
  - `magical_feature` → `#20c0a0` (teal)
  - `farm` / `garden` → `#208040` (mid-green)
  - `ruin` → `#503020` (deep brown)
  - `noble_house` → `#f0e0a0` (cream)
  - `lamp` / `fire_pit` → `#f0c020` (yellow)

Per-scene addition rule: don't add more than ~5 extension classes.
The 8 base palette colors + 5-6 extensions cap the catalog at ~14
classes — past that, color separation in the semantic map gets
unreliable.

### Step 4 — Assign intent_type per class

Use the convention from semantic_palette.json's `_intent_types`:

- `terrain_shader`: anything that's GROUND COVER, not a discrete
  object. Includes grass, forest (when you want the FLOOR to read
  as forested but don't need individual tree entities), water,
  paths, plazas, cobblestone.
- `terrain_displacement`: hills, valleys, elevation features. Often
  ZERO entries — only used if the scene has real topography.
  Encoded in heightmap.png, not in semantic map color.
- `object_placement`: discrete entities — houses, walls, towers,
  bridges, statues, market stalls, fountains.

If a class could be EITHER (e.g., forest could be a green ground
biome OR individual tree entities), pick based on scene needs:
- Want player to walk between specific trees → `object_placement`
- Want a "forest texture" that the player walks on top of →
  `terrain_shader`

### Step 5 — Add heightmap hints

Look at the reference image's apparent topography:
- Mostly flat town → `mostly_flat`
- Has hills or terraces → `hilly` with bright high_regions
- River / lake / pond → set those as low_regions
- Coastal → `coastal` with the water side as low

### Step 6 — Write the three output files

`_class_catalog.json` — the structured catalog from steps 3-5.
`_semantic_map_prompt.txt` — compose the prompt by injecting the
catalog's classes into the palette list of the base template.
`_heightmap_prompt.txt` — compose the prompt by injecting the
heightmap_hints into the base template.

## Strict rules

1. **No invented base classes.** If you call a class "grass," its
   hex MUST be `#a0d870`. Authors who scan the catalog should be
   able to depend on the convention. Add a SCENE-SPECIFIC name
   (e.g. "tundra_grass") with an extension hex if you need a
   different shade.

2. **No invented hexes outside the lib.** Every hex you use is
   either a base hex or an extension hex from
   `semantic_palette.json`. NO making up colors.

3. **Limit total classes to ~14.** Past that, color separation in
   the semantic map gets unreliable. Combine adjacent concepts
   (e.g. "small_house" + "medium_house" → just "house" with a
   range of expected sizes).

4. **`terrain_displacement` classes have NO hex.** They're encoded
   in heightmap.png, not the semantic map. Mention them in
   `heightmap_hints.low_regions` or `high_regions` instead.

5. **Intent types are NOT subjective.** A wall is `object_placement`
   even if it's a long thin strip — players need it as collision
   geometry. A cobblestone road is `terrain_shader` even if you
   could imagine it as a chain of tile entities — the engine's
   biome shader handles it more efficiently.

## Worked example (medieval town)

Input:
- scene_brief: "fortified medieval town beside a river with farmland"
- reference_image: `openai_test_town_orthographic.png` (1024×1024)

Expected `_class_catalog.json`:

```json
{
  "scene_brief": "fortified medieval town beside a river with farmland",
  "reference_image": "openai_test_town_orthographic.png",
  "image_size": [1024, 1024],
  "classes": [
    {"name": "grass", "hex": "#a0d870", "intent_type": "terrain_shader", "description": "Open meadow outside the walls", "expected_coverage_pct": 35.0, "lib_origin": "base"},
    {"name": "forest", "hex": "#2a5a2a", "intent_type": "terrain_shader", "description": "Wooded perimeter around the town", "expected_coverage_pct": 15.0, "lib_origin": "base"},
    {"name": "water_surface", "hex": "#3070c0", "intent_type": "terrain_shader", "description": "River along the east edge", "expected_coverage_pct": 10.0, "lib_origin": "base"},
    {"name": "cobblestone", "hex": "#c8a878", "intent_type": "terrain_shader", "description": "Radial streets + central plaza", "expected_coverage_pct": 8.0, "lib_origin": "base"},
    {"name": "farm_field", "hex": "#208040", "intent_type": "terrain_shader", "description": "Cultivated farmland patches outside the walls", "expected_coverage_pct": 5.0, "lib_origin": "extension"},
    {"name": "house", "hex": "#a04020", "intent_type": "object_placement", "description": "Townspeople dwellings inside the walls", "expected_count": 60, "lib_origin": "base"},
    {"name": "wall_segment", "hex": "#9a9080", "intent_type": "object_placement", "description": "Octagonal stone curtain wall", "expected_count": 8, "lib_origin": "base"},
    {"name": "tower", "hex": "#707070", "intent_type": "object_placement", "description": "Round defensive tower at each wall vertex", "expected_count": 12, "lib_origin": "base"},
    {"name": "bridge", "hex": "#704020", "intent_type": "object_placement", "description": "Stone bridge crossing the river", "expected_count": 2, "lib_origin": "base"},
    {"name": "fountain", "hex": "#e040a0", "intent_type": "object_placement", "description": "Central plaza fountain", "expected_count": 1, "lib_origin": "base"},
    {"name": "townhall", "hex": "#c02040", "intent_type": "object_placement", "description": "Large central civic building", "expected_count": 1, "lib_origin": "extension"}
  ],
  "heightmap_hints": {
    "expected_topography": "mostly_flat",
    "low_regions": ["river_bed"],
    "high_regions": [],
    "elevation_range_estimate_meters": [0, 2]
  },
  "composition_notes": "octagonal wall ~60% of image width, 12 radial cobblestone streets converging on a small central plaza with a fountain, river curves along the east edge with two bridges, forest patches in the four corners, light green grass/fields outside the wall"
}
```

## What this skill is NOT

- NOT a generator of the semantic map itself — that's stage 3
  (openai_images /edits) consumed by `compose_semantic_extract`.
- NOT a generator of the photoreal reference — that's stage 1
  (`/yume-topdown-prompt` + openai_images.generations).
- NOT an extractor of entity positions — that's stage 5
  (LLM-as-script-author).
- NOT a member of the locked 2D pipelines (compose_hud / compose_
  screen). This is the ACTIVE 3D pipeline category.

## Reference files

- `godot/data/lib/semantic_palette.json` — the base palette + intent type definitions
- `tools/visual_layout/compose_map.py` — the existing semantic-map pipeline whose presets predate this skill
- `.claude/skills/yume-topdown-prompt/SKILL.md` — stage 1 sibling
- `.claude/rules/pipeline-stability.md` — confirms this is in the ACTIVE 3D category, no ADR gate for changes
