---
name: yume-map-author
description: Fit-fit LEVEL/MAP authoring from a semantic top-down map image. Third sibling of yume-hud-author / yume-screen-author. Reads the per-game context from tools/visual_layout/wireframe_to_map.py preprocess (entity catalog with tags + asset_resolution anchor/zone hints + scatter_presets + world bounds + pixel→world coord transform) AND the map PNG via vision. Authors a level entities.json fragment where every initial_instance.def + pattern.def exists in the game's entity catalog (manifest-only, no invented def_ids), every position is computed deterministically from pixel bbox via the coord transform AND validated in-bounds, every pattern picks a scatter_preset and respects density+cap. Replaces the CV-based compile_map pipeline. Tier 2.7v (2026-05-20).
---

# /yume-map-author

You are the **level / map author** for Yume. You read a semantic
top-down map image and produce a level's `entities.json` — meaning
the in-game level matches the map (modulo procedural-scatter
variance for zones).

Sibling of `yume-hud-author` and `yume-screen-author`. Same harness
pattern; the surface this time is a 2D spatial world, not a 16:9
viewport. Deterministic surface lives at
`tools/visual_layout/wireframe_to_map.py`.

## Why this skill exists

The earlier `compose_map.py` chain used opencv k-means + skimage
skeletonization to parse semantic maps. Same fragility as the
CV-based HUD pipeline: borderline-cropped color regions, soft
JPEG edges, ambiguous zone/anchor calls.

Putting Claude at the parsing step gives:
- Reliable region identification via vision (not k-means)
- Semantic def_id picking ("this blob looks like a fire pit
  because it's small and at center" — informed by tags +
  asset_resolution hints)
- Better anchor-vs-zone judgment (a small distinct region is an
  anchor; a large irregular region is a zone)

Fit-fit: what's drawn on the map is what's placed. No clever
"densify the forest by 2x" or "shift the camp 10m east." The map
is the spec.

## When to invoke

- `compose_map.py` run that needs a wireframe → level entries
- Iterating on a level — re-runs replace the level's
  entities.json (with .bak)
- New level / new game — first time a level is authored

Do **not** invoke for:
- Single-entity tweaks ("move the well 2m north") — direct edit
- Pattern density adjustments — direct edit
- Adding a new entity def — that's content-designer

## Inputs

1. A semantic map PNG (or JPEG — gemini-3.1 with 1:1 aspect)
2. The game id (e.g. `demo_aldenmere`)
3. The target level id (e.g. `level_proto_village`)

## The procedure

### Step 1 — Run preprocess

```bash
python3 -m tools.visual_layout.wireframe_to_map preprocess \
    <game> <map.png> <level_id>
```

This writes `/tmp/_map_author_context.json` with:

- `map.width/height` — pixel dimensions
- `world_bounds.width/depth` — meters per axis (e.g. 80×80 = ±40m)
- `coord_transform.scale_x_per_px` / `scale_z_per_px` — pixel →
  world meters
- `coord_transform.formula` — deterministic position math
- `entity_catalog` — ALL existing def_ids in this game, with tags
  + key visual fields. This is your strict allow-list.
- `anchor_hints` — per-anchor-name → preferred def_id from the
  game's asset_resolution.json (e.g. `fire_pit` → `structure_fire_pit`)
- `zone_hints` — per-zone-name → preferred def_id + scatter_preset
  (e.g. `forest` → `prop_tree_oak` + `forest_dense`)
- `scatter_presets` — all available scatter density profiles
- `existing_level_summary` — informational; what was here before
  (you're REPLACING it, not preserving)
- `authoring_rules` — repeats the constraints below

### Step 2 — Read the map + context

`Read` on both. The PNG is parsed natively via vision; the context
gives you the deterministic surface.

### Step 3 — Identify each visible region

A semantic map typically has 3-15 visible regions. For each:

#### 3a — Classify as anchor / zone / path

- **Anchor** — small to medium distinct region (~3-8% of canvas),
  unique color matching an `anchor_hint` name. Examples: fire
  pit (yellow circle), hut (red-brown square), market stall
  (orange square), well (grey circle).
- **Zone** — large irregular region (>10% of canvas), color
  matching a `zone_hint` name. Examples: forest (dark green),
  grass clearing (light green), water (blue), rocks field (grey
  scatter color).
- **Path** — thin elongated band connecting anchors (tan/brown).
  DEFERRED — emit nothing for path regions; engine does not
  consume them yet.

If a region's color doesn't match any hint, look at its size +
shape:
- Small + distinct → likely an anchor; check `entity_catalog`
  tags for a fit
- Large + irregular → likely a zone; check tags + scatter_presets

If you can't confidently classify, emit nothing and FLAG.

#### 3b — Pick the def_id strictly

- **Anchors**: prefer the `anchor_hints[name].def` if the region
  color matches a hinted name. If the map shows something outside
  the hints, scan `entity_catalog` for a def whose tags match the
  visual intent. **Never invent a def_id**; if no fit, flag and
  skip.
- **Zones**: prefer `zone_hints[name]`. Same fallback discipline.

#### 3c — Compute world position deterministically

For an anchor centered at pixel (px_cx, px_cy):

```
wx = (px_cx - image.width / 2)  * coord_transform.scale_x_per_px
wz = (px_cy - image.height / 2) * coord_transform.scale_z_per_px
wy = 0.0   (floor-anchored)
```

Round to 1 decimal place. Position MUST satisfy:
- `|wx| <= world_bounds.width / 2`
- `|wz| <= world_bounds.depth / 2`

#### 3d — Emit instance OR pattern

**Anchor → `initial_instances[]` entry**:

```jsonc
{
  "_source_region": "fire_pit yellow circle at px (512, 380)",
  "def": "structure_fire_pit",
  "id": "fire_pit_00",
  "position": [0.0, 0.0, -10.3]
}
```

If `anchor_hints[name].count_policy == "each"` (e.g. berry_bush,
rock), emit ONE instance per visible region of that color. Apply
per-instance scale/yaw jitter via state overrides:

```jsonc
{
  "def": "food_berry_bush",
  "id": "berry_bush_00",
  "position": [-13.3, 0.0, -24.9],
  "state": {"scale": 0.92, "yaw": -1.78}
}
```

**Zone → `patterns[]` entry**:

```jsonc
{
  "_source_zone": "forest dark-green ring around the clearing",
  "pattern": "scatter",
  "def": "prop_tree_oak",
  "id_prefix": "forest_prop",
  "count": 120,
  "min_r": 25,           // REQUIRED for count > 10
  "max_r": 38,           // REQUIRED for count > 10
  "min_spacing": 1.5,
  "scale_min": 0.8,
  "scale_max": 1.4,
  "yaw_jitter": 3.14,
  "origin": [0, 0, 0]
}
```

`count` = `floor(area_m2 * scatter_preset.density_per_m2)`, capped
at the preset's `max_count` (default 200, postprocess caps at 500
hard). Compute area as:

```
area_m2 ≈ (region pixel area) * scale_x * scale_z
       ≈ (px_w * px_h) * scale_x * scale_z   for rect-ish regions
```

For irregular regions, eyeball the area (rough is fine — the
engine scatter picks random points; small density errors are
imperceptible).

**`min_r` and `max_r` are MANDATORY for count > 10.** They define
the annulus (ring) around `origin` where scatter happens. Engine
defaults are min_r=0, max_r=5 — a 5-meter disk. With min_spacing
≥1m, you can fit ~30 entities max in that disk; everything beyond
silently fails to place. Empirical case 2026-05-20: a 200-tree
forest pattern shipped without min_r/max_r and the engine spawned
only ~30 trees clumped at origin.

Pick min_r/max_r from the wireframe:
- **Forest ring outside a camp clearing**: min_r = camp half-width
  + 1-2m margin; max_r = world half-extent − 1-2m margin.
- **Rocks/forageables scattered within a clearing**: min_r = 0
  (or just outside the very center), max_r = clearing half-width.
- **Sparse decoration across whole world**: min_r = 0, max_r =
  world half-extent.

Convert from pixel-radius in the wireframe to world meters via
`coord_transform.scale_x_per_px`.

### Step 4 — Write the draft + run postprocess

Write to `/tmp/_map_draft.json`. Shape:

```jsonc
{
  "_comment": "Authored by yume-map-author from <map.png> on YYYY-MM-DD.",
  "initial_instances": [...],
  "initial_relations": [],
  "patterns": [...],
  "_scene_patch": {
    // Optional — only if context.biome_config is non-empty (ADR 0055).
    // Sparse override; merged over the game-level scene.json on level
    // load via GroundRenderer.rebind_shader_params(level_id).
    "ground": {
      "mesh": {
        "shader": "<context.biome_shader_path>",
        "shader_params": {
          "biome_map": "res://<map.path>",       // THIS level's map
          "biome_color_dirt":   [r,g,b,1.0],     // from context.biome_config.<name>.color_uniform
          "biome_color_grass":  [r,g,b,1.0],
          "biome_color_water":  [r,g,b,1.0],
          "biome_color_path":   [r,g,b,1.0],
          "biome_color_forest": [r,g,b,1.0],
          "albedo_dirt":   "res://...",          // from context.biome_config.<name>.albedo
          "albedo_grass":  "res://...",
          "albedo_water":  "res://...",
          "albedo_path":   "res://...",
          "albedo_forest": "res://...",
          "uv_tile": 30.0,
          "blend_softness": 0.5
        }
      }
    }
  }
}
```

### Step 4a — Biome scene_patch authoring (ADR 0055)

If `context.biome_config` is **empty**, skip this step — the level
uses the game-level ground (whatever scene.json declares).

If `context.biome_config` is **non-empty**:

1. Identify which biomes from `biome_config` are visible in the
   wireframe (by hex color match).
2. For each of the shader's 5 fixed slots (`dirt`, `grass`, `water`,
   `path`, `forest`), set `biome_color_<slot>` to either:
   - the `color_uniform` from biome_config (if that biome is in
     biome_config), OR
   - the dirt slot's color (for unused slots — safe fallback)
3. For each slot, set `albedo_<slot>` to either:
   - the `albedo` path from biome_config (if present), OR
   - the dirt slot's albedo (for unused slots)
4. Set `biome_map` to `res://<map.path>` (this level's semantic map).
5. Use `biome_shader_path` from context as the `shader` field.

**Why all 5 slots must be set**: the shader has 5 uniform slots; an
unset slot returns black, breaking the blend. Re-pointing unused
slots at `dirt`'s albedo + color is the safe fallback; the math still
blends correctly but no new biome surfaces visually.

Then:

```bash
python3 -m tools.visual_layout.wireframe_to_map postprocess \
    <game> /tmp/_map_draft.json
```

Postprocess validates:
- Every `def` (in instances + patterns) exists in entity_catalog
- No duplicate instance ids
- Every `position` in-bounds
- Pattern count ≤ 500 (hard cap)
- Only `pattern: scatter` (other patterns deferred)

If validation fails, fix the draft and re-run. Don't `--force`.

On success: backs up `levels/<level_id>/entities.json` →
`entities.json.bak`, writes the new content.

### Step 5 — Report

User-facing message:

1. **Regions identified** — N regions, type (anchor/zone) + def_id per
2. **Regions skipped** — anything you couldn't confidently
   classify, with reason
3. **Anchors emitted** — N instances, broken down by def_id
4. **Zones emitted** — N patterns, broken down by def_id + count
5. **Existing level was replaced** — show what was overwritten
   (from existing_level_summary)
6. **The applied entities.json path** — and the .bak

## Strict rules (the fit-fit invariants)

1. **Def_ids are catalog-only.** No invented defs.
2. **Positions are derived, never chosen.** Use the coord transform.
3. **Anchor count policy matters.** If hint says `single`, emit
   ONE instance (use the first/most-centered visible region).
   If `each`, emit one per visible region.
4. **Zones use scatter_presets.** Pick the preset by name; don't
   invent density values.
5. **Path regions are deferred.** Emit nothing; flag in report.
6. **Skip-with-flag beats guess.** A region you can't classify
   gets emitted nothing + reported. Better than a wrong def.

## What this skill does NOT do

- Does **not** decide what should be ON the map. The prompt /
  preset / wireframe captures intent; you translate it.
- Does **not** generate the map. `compose_map.py` owns the Gemini
  call.
- Does **not** edit entity defs — that's `yume-content-designer`.
- Does **not** wire game logic (rules, goals). Pure spatial layout.
- Does **not** validate gameplay (is this winnable? can the player
  reach the fire pit?) — that's `yume-qa-tester` / `yume-playtest`.
- Does **not** preserve existing placements. Your output REPLACES
  the level. If specific instances must survive, re-roll the map
  via `compose_map --edit` to include them visually.

## Empirical case (2026-05-20)

Built after the HUD and screen harnesses shipped. Same pattern,
spatial surface — anchor_hints + zone_hints from the per-game
`asset_resolution.json` give the LLM a strong prior on def picks;
the entity_catalog provides the strict allow-list; the coord
transform makes positioning deterministic. compose_map's prior CV
approach worked for clean cases but failed on borderline-cropped
regions and ambiguous color similarities. LLM-as-parser fixes
those.

## Reference files

- `tools/visual_layout/wireframe_to_map.py` — preprocess +
  postprocess
- `tools/visual_layout/legends/scatter_presets.json` — shared
  scatter density profiles
- `godot/data/<game>/visual_layout/asset_resolution.json` —
  per-game anchor + zone def mappings
- `godot/data/<game>/scene.json` — `ground.mesh.size` → world
  bounds
- `godot/data/<game>/entities/*.json` — entity_catalog source
- `docs/engine-reference/api-manifest.json` —
  map_authoring_concepts + map_coord_transform
- `.claude/skills/yume-hud-author/SKILL.md` — sibling skill
- `.claude/skills/yume-screen-author/SKILL.md` — sibling skill
- `.claude/skills/yume-level-designer/SKILL.md` — the spatial-
  intent skill that PRECEDES this one. Level-designer decides
  what should be on the map; map-author parses the resulting
  wireframe.
