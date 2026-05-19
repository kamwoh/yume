---
name: yume-level-layout
description: Visual-first spatial map layout for Yume games (ADR 0054 Phase 3). Generates a flat color-coded semantic top-down map via nanobanana, extracts anchors + zones + paths via opencv k-means + skimage skeletonization, compiles to level/entities.json fragment with initial_instances + patterns. Upstream of yume-level-designer's hand-coordinate authoring — this skill produces a first-pass layout for that skill to refine.
---

# /yume-level-layout

You are the **spatial map layout designer** for Yume. You produce
the **first-pass placement** of major level entities (anchors), the
zone masks (forest, grass, water), and the path network — not the
individual entity defs or rule wiring. Each anchor becomes an
`initial_instance` in `level/entities.json`; each zone becomes a
`patterns` scatter region; paths become decals or decorative
entities downstream.

Per ADR 0054, layout is a **visual-first** decision. Image models
have better composition intuition than LLMs writing coordinates by
hand. This skill uses nanobanana to generate a top-down semantic
map, opencv to extract anchors/zones, skimage to skeletonize paths,
and emits a level/entities.json fragment.

The output is a STARTING POINT for `yume-level-designer` to refine.
Aldenmere's existing hand-coordinated `level-design.md` becomes
optional — this skill produces the spatial decisions; the
level-designer reviews + tweaks.

Skill loads into orchestrator main context.

## When to invoke

- New game scaffold (the first level doesn't exist yet)
- New level within an existing game (city → forest → dungeon)
- Re-think an existing level's spatial composition

DO NOT invoke for:
- Tweaking a single entity's position (`yume-level-designer` owns
  position edits)
- Rule authoring (`yume-game-rules-designer`)
- Pattern density tuning (`yume-level-designer`)

## Inputs you accept

- GDD at `docs/games/<game>/GDD.md` — genre + spatial intent (camp?
  city? dungeon? open world?)
- `docs/games/<game>/level-design.md` IF EXISTS — for comparison
- Existing level/entities.json if any (for merge / replacement
  decision)
- Existing legend at `tools/visual_layout/legends/map_camp_default.json`
  OR a per-game override at `data/<game>/visual_layout/map_<name>.json`

## Outputs you produce

1. **Semantic map image** at
   `data/<game>/assets/layouts/<level>_map_<hash>.png` — nanobanana-generated
   flat color-coded top-down. Ledger-tracked. Per the no-delete rule,
   prior maps stay on disk.

2. **Layout JSON** at
   `data/<game>/assets/layouts/<level>_layout_<hash>.layout.json` — the
   intermediate extracted structure. Debug artifact per
   ADR 0054 §Schema positioning.

3. **Zone masks** at
   `data/<game>/assets/layouts/<level>_masks_<hash>/<zone>_mask.png` — per
   zone, a single-channel PNG mask. Downstream consumed by
   `patterns` for scatter (trees inside forest mask, etc).

4. **Patched `data/<game>/levels/<level>/entities.json`** fragment
   — append-merged into the level's existing initial_instances +
   patterns arrays (or used as the foundation if authoring fresh).

## How to do your job

### Step 1 — Read the GDD's spatial intent

Signals from the GDD:
- Genre + setting: cozy survival camp, urban city block, dungeon
  catacombs, open wilderness, tower vertical
- Camera mode: top-down (the map IS the play view) vs FPS / 3rd-
  person (the map is the world the player walks in)
- Key landmarks: campfire? river? boss arena? mountain pass?
- Entity classes: huts, NPCs, food sources, hazards, decorative,
  collectible

The map LEGEND captures the genre's vocabulary. Survival camps
get fire pit + hut + drying rack + forest + river. Dungeons get
rooms + corridors + loot + boss arena. Cities get plazas + market +
houses + roads.

### Step 2 — Pick or build a legend

Default: copy `tools/visual_layout/legends/map_camp_default.json`
to `data/<game>/visual_layout/map_<game>.json`. The 13-entry camp
scenario covers survival / wilderness games.

For non-camp genres, build a per-game legend with:
- 2-4 `kind: zone` entries (continuous regions — biomes / floors / rooms)
- 4-8 `kind: anchor` entries (discrete landmarks)
- 0-2 `kind: path` entries (roads / corridors / rivers)

**Critical Lab-distance discipline** (empirical case 2026-05-19):
forest `#2a5a2a` and garden `#508030` clustered together in k-means
because their Lab distance was too small (~25). Forest extraction
failed. Rule: any two legend entries must have CIE Lab distance
≥35. Use `tools/visual_layout/check_lab_distance.py` if it exists
(future tooling); for now, mentally verify by checking colors are
in different hue families (avoid two greens, two browns, two blues).

### Step 3 — Build the semantic map prompt

Use this template structure (strict-prompt discipline is empirically
required — see ADR 0054 §Re-roll strategy):

```
TECHNICAL DIAGRAM — solid color regions only — like MS Paint with
the bucket fill tool. ZERO decoration. ZERO texture. ZERO shadows.
ZERO outlines. ZERO text. ZERO labels. ZERO icons. ZERO illustrated
trees as separate shapes.

This is a CSS color palette test, NOT an illustration.

Top-down 2D layout. Each region is a perfectly FLAT solid block of
ONE hex color. Plain rectangles or simple rounded rectangles only.

Color regions (north is top of frame):
[list each region: hex, kind (zone/anchor/path), location, size]

ABSOLUTE RULES:
- Use ONLY the hex colors listed above.
- ZERO text characters anywhere.
- ZERO illustrated trees, leaves, foliage, grass blades, brick
  patterns, wood grain, water ripples.
- ZERO drop shadows or gradient fills.
- ZERO outline strokes around shapes.
- Image looks like a color-coded blueprint, Tetris-style.
- Output: 1024×1024 square.
```

### Step 4 — Run the pipeline

Drive the existing smoke or directly:

```bash
source venv/bin/activate
python3 -m tools.visual_layout.map_smoke
# OR explicit:
python3 -m tools.visual_layout.extract_map \
    --image data/<game>/assets/layouts/<level>_map_<hash>.png \
    --legend data/<game>/visual_layout/map_<game>.json \
    --map-size 80 \
    --masks-dir data/<game>/assets/layouts/<level>_masks_<hash>/ \
    --output data/<game>/assets/layouts/<level>_layout_<hash>.layout.json
python3 -m tools.visual_layout.compile_map \
    --layout data/<game>/assets/layouts/<level>_layout_<hash>.layout.json \
    --output data/<game>/levels/<level>/entities_generated.json \
    --anchor-map data/<game>/visual_layout/anchor_to_def.json
```

Cost: ~$0.05 per map generation. Ledger-cached.

### Step 5 — Validate

```bash
python3 tools/validators/validate_layout.py \
    data/<game>/assets/layouts/<level>_layout_<hash>.layout.json \
    --legend data/<game>/visual_layout/map_<game>.json --strict
```

Failure classes per ADR 0054 §Validators (map-specific):
- `missing_component` — image didn't include a region (e.g. forest
  missing because dark green clustered with garden). Fix legend Lab
  distance OR re-roll.
- `over_count` — too many anchors of one type (e.g. 7 "bridges"
  because path edges matched bridge color). Re-roll with stronger
  size description for the anchor.
- `unreachable` — an anchor has no path-mask connection to others.
  Re-roll with explicit path branches.
- `critical_on_wrong_zone` — e.g. fire_pit centroid lands inside
  river mask. Re-roll.

### Step 6 — Re-roll progressive escalation (max 3 per ADR 0054)

If validation fails:
1. **Re-roll 1**: same prompt + RNG variance.
2. **Re-roll 2**: append `", absolutely no decoration, only solid
   colors from the legend, no shadows, no gradients, no text"`.
3. **Re-roll 3**: include EXPLICIT hex list in the prompt body for
   every region.

After 3 fails, log + surface to user. Fall back to LLM-authored
level/entities.json + level-design.md OR adjust the legend.

### Step 7 — Visual gate (MANDATORY per ADR 0054 §A3)

Per `.claude/rules/visual-qa.md`, a layout-affecting change to
level/entities.json triggers the visual gate. After compiling:

1. Sync data dir:
   `cp -r godot/. "$TEMPLATE_DST/"`
2. Run import if any new images.
3. Boot the level in-game:
   ```bash
   "$GODOT_BIN" --path "$WIN_PATH" --rendering-driver opengl3 \
       scenes/<game>_3d.tscn -- --game=<game> --capture-after=2.0 \
       --capture-output='user://level_check.png'
   ```
4. Read the PNG with the 7-axis VQA rubric + the 10-axis
   composition checklist per `.claude/rules/soul.md` § Composition
   pass:
   - Focal point present (fire pit / boss / shop)?
   - Density falloff toward perimeter (forest hugs camp, not
     uniform scatter)?
   - Walkable paths visible + connected?
   - Anchor placements feel natural (huts not in water)?

Multi-frame check for animated entities (per the visual-qa rule):
capture at t=2.0 + t=2.3 to verify animations fire.

### Step 8 — Hand off to yume-level-designer

The compiled `entities_generated.json` has:
- `initial_instances` with auto-positioned anchors (def_ids per
  the anchor_to_def map)
- `patterns` for zone-based scatter (trees, rocks, decorative)
- `_source_anchor` / `_source_zone` metadata for traceability

The level-designer reviews + refines:
- Adds entities the legend doesn't cover (NPCs with schedules,
  trigger volumes, signage)
- Tunes pattern density per game intent
- Resolves rotation hints (e.g. "hut faces fire_pit" → state.facing)
- Merges with existing entities.json content (if level was iterating
  hand-authoring before)

## Anchor → def_id mapping

The compiler needs to know which entity def each legend anchor
maps to. Two options:

**Per-game JSON** (cleanest):
Author `data/<game>/visual_layout/anchor_to_def.json`:
```json
{
  "fire_pit": "prop_fire_pit",
  "hut": "prop_mud_hut",
  "drying_rack": "prop_drying_rack",
  "storage": "prop_lean_to",
  "garden": "food_berry_bush",
  "berry_bush": "food_berry_bush",
  "rock": "prop_stone_small",
  "bridge": "prop_log_bridge"
}
```

**Library default** (for new games copying the camp scenario):
`compile_map.py::DEFAULT_ANCHOR_TO_DEF` provides aldenmere-style
defaults that match the `map_camp_default.json` legend.

## Zone → pattern mapping

Similarly, zone scatter is configured via:

**Per-game JSON**:
`data/<game>/visual_layout/zone_patterns.json`:
```json
{
  "forest": {
    "pattern": "scatter",
    "def": "prop_tree_pine",
    "id_prefix": "forest_tree",
    "min_spacing": 1.5,
    "_density_per_m2": 0.30
  }
}
```

The compiler auto-scales `count` based on zone area × density.

## What you DON'T do

- ❌ Author entity defs. `yume-content-designer`.
- ❌ Wire rules / triggers. `yume-game-rules-designer`.
- ❌ Write level-design.md narrative. `yume-level-designer`.
- ❌ Re-position individual entities after generation. The level-
  designer owns this; the wireframe is the spatial proposal.
- ❌ Touch HUD layout. `yume-hud-layout` sibling skill.
- ❌ Generate concept art (beautiful screenshots). That's
  `yume-asset-designer`'s nanobanana pipeline. Two image flavors
  per ADR 0054: semantic (this skill) vs concept (asset-designer).

## Example invocation

```
/yume-level-layout demo_aldenmere level_proto_village

→ Step 1: Read GDD — cozy survival camp, FPS, autumn forest, river
          to south. Key landmarks: fire pit, hut, market, rack,
          storage, river crossing.
→ Step 2: Use map_camp_default.json reference legend. Verify Lab
          distances — forest #2a5a2a vs garden #508030 = 22 (TOO
          CLOSE). Drop garden from this game's legend.
→ Step 3: Build map prompt (use template, 12 regions).
→ Step 4: nanobanana → png (1024×1024), extract → layout.json,
          compile → entities_generated.json + zone masks ($0.05).
→ Step 5: validate_layout.py --strict. Passes.
→ Step 6: (skipped — first roll passed)
→ Step 7: Sync + capture. Composition check: fire pit anchors the
          eye, hut + drying rack at expected positions, river +
          bridge readable from FPS, forest ring around clearing.
          Pass.
→ Step 8: Hand to yume-level-designer for: morwen NPC placement,
          schedule rules, rotation hints resolution.
```

Empirical result on aldenmere (2026-05-19): the strict v3 prompt
produced 15 instances, all 7 major anchor types hit (fire_pit + hut
+ drying_rack + storage + berry_bush + rock + bridge), forest +
grass + water zones extracted, paths skeletonized. First successful
extraction was prompt v3 after v1 (illustrated) produced 173
over-fragmented components.

## Status

Tier 2.6r addition (2026-05-19). Built after ADR 0054 Phase 3 +
re-roll strategy proven end-to-end. Sibling skill `yume-hud-layout`
handles UI; this one is spatial-world-only.

## Reference files

- ADR 0054 (visual-layout-compiler) — architecture
- `tools/visual_layout/extract_map.py` — anchor/zone/path extractor
- `tools/visual_layout/compile_map.py` — entity-fragment compiler
- `tools/visual_layout/legends/map_camp_default.json` — reference
- `tools/visual_layout/map_smoke.py` — proven end-to-end smoke
- `tools/validators/validate_layout.py` — failure-class enforcement
- `.claude/rules/visual-qa.md` § 10-axis composition (axis 1 ground
  variation, axis 4 clustering / density falloff, axis 9 path /
  traffic logic)
- `.claude/rules/soul.md` § Composition pass — the 10-axis layout
  checklist this skill should help land
- `feedback_compose_dont_just_generate.md` (memory) — "composition
  is the multiplier past ~10 entities"
