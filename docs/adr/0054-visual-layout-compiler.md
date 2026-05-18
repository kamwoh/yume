# ADR 0054 — Visual layout compiler (image-gen → CV → JSON → engine)

_Date: 2026-05-19_
_Status: proposed_

## Context

Yume's content authoring pipeline currently has LLMs (Claude / Codex
via skills like `yume-level-designer`, `yume-asset-designer`) writing
spatial layout directly as text — entity coordinates, HUD rectangle
positions, scatter origins, panel anchors. The result is often
mediocre: positions land slightly off, density is uneven, hierarchy
is inverted, panels overlap.

Empirical evidence:
- **Aldenmere HUD**: 5+ iterations to land at a layout the user
  considered non-ugly. Each round required reading the user's prose
  feedback ("vitals should be bottom-left") and translating it to
  JSON coordinates. See memory entry
  `feedback_review_style.md` for the iteration history.
- **Aldenmere level layout**: `level-design.md` writes coordinates
  by hand; later validators caught composition issues (floating
  bushes, occluded huts, paths-not-connected) only AFTER playtest.
- **Static asset placement**: even with the existing `patterns:`
  system, the placement bias often lands wrong — see
  `feedback_compose_dont_just_generate.md` for "asset gen ≠ scene
  quality past ~10 entities."

The root cause: **LLMs reason about layout in text, not visual
space.** They commit to numbers without seeing the result. Image
generation models reason in visual space natively — composition,
balance, hierarchy, density falloff emerge naturally. They are
better spatial designers than they are spatial executors.

We already have image generation in the pipeline (nanobanana via
Gemini Flash Image) for concept art and texture references. We have
NOT used it for STRUCTURE — only for visual style.

This ADR introduces a new pipeline layer that uses image generation
specifically for spatial layout decisions, extracts structure via
computer vision, and emits the same JSON the existing engine
consumes. The engine is unchanged.

## Decision

Add a **visual layout compiler** as an upstream phase of content
authoring. The compiler operates in five stages:

```
intent (text / GDD)
    │
    ▼
[1] Semantic image generation
    Image gen produces a flat, color-coded, machine-readable layout.
    Strict prompts. The image is a parsing target, not art.
    │
    ▼
[2] CV extraction
    K-means quantize → match to legend → connected components →
    bounding boxes → centroids → mask extraction → path skeletonization.
    Output: structured scene graph (anchors + zones + paths).
    │
    ▼
[3] Coordinate transform
    Image (pixel coords, 0-W × 0-H) → world (meters, centered).
    Linear scale + recenter.
    │
    ▼
[4] Validation + repair
    Rule-driven: no overlap, paths walkable, anchors reachable,
    UI within safe margins. Repair via snap-to-zone, move-overlap,
    smooth-paths, drop-noise.
    │
    ▼
[5] Engine compile
    Emit `entities.json` / `hud.json` / `level/entities.json`.
    Existing engine consumes unchanged.
```

### Two distinct image flavors (invariant)

The compiler ALWAYS distinguishes:

| Flavor | Purpose | Style | Consumer |
|---|---|---|---|
| **Semantic layout image** | Machine extraction | Flat, color-coded, no shadows, no gradients, no labels, no decoration | CV extractor |
| **Concept screenshot** | Human art direction + Tripo3D image-to-3D reference | Beautiful, atmospheric, detailed | Designer + image-to-3D |

These are NEVER the same image. Conflating them was the empirical
failure mode in ADR 0053 (we fed concept screenshots to Tripo's rig
pipeline and the rich background geometry made the mesh unriggable).
Same family of risk applies here: a beautiful image is unparseable;
a parseable image is ugly. Generate both for different purposes.

### Color extraction via k-means quantization (per user 2026-05-19)

The naive approach — strict color thresholding against a hex-color
legend — fails when Gemini Flash Image produces near-legend colors
(anti-aliasing, slight hue drift, subtle gradients).

The robust approach: **k-means cluster the image into N color
centroids, match each centroid to the nearest legend color, extract
masks by quantized cluster ID.**

```
# Pseudocode
img = load(semantic_image)
pixels = img.reshape(-1, 3)
centroids = kmeans(pixels, n_clusters=len(legend) + 2)  # +2 for noise/edge
labels = assign_pixels_to_centroids(pixels, centroids)

# Match each centroid to nearest legend entry by CIE Lab distance
centroid_to_legend = {}
for c_id, centroid in enumerate(centroids):
    nearest = min(legend, key=lambda c: lab_distance(centroid, c.hex))
    centroid_to_legend[c_id] = nearest.name

# Now masks by legend name
masks = {}
for name in legend.names:
    cluster_ids = [c for c, n in centroid_to_legend.items() if n == name]
    masks[name] = (labels.reshape(img.shape[:2]) ∈ cluster_ids)
```

Three failure modes the quantization absorbs:
1. **Anti-aliased edges** — pixel on a boundary picks up an in-between
   color. Quantization snaps to one side or the other; subpixel
   ambiguity disappears.
2. **Slight hue drift** — Gemini outputs "warm beige" for the
   "tan/path" legend entry. Quantization picks the nearest centroid,
   matches to legend.
3. **Gradient inside a region** — a grass patch that's slightly
   darker at one corner. Both shades collapse to one cluster.

Failure modes the quantization does NOT absorb:
1. **Image generator ignored color legend entirely** (e.g. painted
   shadows in solid dark color that gets matched to "river / blue").
   Mitigation: validator catches downstream ("no river zone present"
   when one was requested → re-roll).
2. **Components touching each other** — two huts side-by-side merge
   into one connected component. Mitigation: morphological erosion
   before connected-components, OR force the image generator to
   include visible gaps via the prompt.

### Pipeline modules (`tools/visual_layout/`)

New Python package:

```
tools/visual_layout/
├── __init__.py
├── README.md
├── extractor_common.py   — k-means + legend matching + mask helpers
├── extract_ui.py         — UI wireframe → rect schema (Phase 1)
├── extract_map.py        — semantic map → anchor schema (Phase 2)
├── compile_ui.py         — rect schema → hud.json
├── compile_map.py        — anchor schema → entities.json + patterns
├── tests/                — unit tests with synthetic input
│   ├── test_quantize.py
│   ├── test_extract_ui.py
│   └── test_extract_map.py
└── legends/              — color/shape legends per use case
    ├── ui_default.json
    └── map_camp_default.json
```

Dependency: `opencv-python-headless` + `scikit-learn` (for KMeans).

### Schema (common across UI + map)

```jsonc
{
  "intent": "<the prompt that drove generation>",
  "image_path": "res://data/<game>/layouts/<hash>.png",
  "legend_used": "ui_default | map_camp_default | ...",
  "extraction": {
    "image_size_px": [1024, 1024],
    "world_size":    [100, 100],          // map only
    "screen_size":   [1920, 1080],         // ui only
    "quantization_k": 14,
    "match_threshold_lab": 25.0,
    "anchors": [
      {
        "type": "fire_pit",
        "image_px": [512, 480],
        "world_pos": [0, 0],               // map only
        "screen_rect": [1500, 40, 360, 360], // ui only
        "footprint_px": 380,
        "confidence": 0.94
      }
    ],
    "zones": [                              // map only
      {
        "type": "forest",
        "mask_path": "<hash>_forest.png",
        "area_world": 1840.0
      }
    ],
    "paths": [                              // map only
      {
        "from": "fire_pit",
        "to": "hut",
        "skeleton_pts": [[0, 0], [-12, 3], [-18, 5]],
        "length_world": 22.4
      }
    ]
  },
  "validation": {
    "passed": true,
    "warnings": [],
    "repairs_applied": []
  }
}
```

This schema lives at `data/<game>/layouts/<hash>.layout.json`
alongside the image. Both ledger-tracked (paid image gen +
extraction time cost).

### Validators

New `tools/validators/validate_layout.py`:
- For UI: rects within safe margins; no overlaps; expected components
  present (vitals, hotbar, minimap, ...); hierarchy (vitals != center).
- For map: no anchor overlap; critical anchors on grass not water;
  paths form connected graph; player spawn ≤ 5m from at least one
  anchor; bridges actually cross water; forest density coverage
  in expected range.
- Pluggable validation rules per legend type.

### New skills

| Skill | Replaces / extends | Phase |
|---|---|---|
| `yume-hud-layout` | augments `yume-asset-designer` HUD authoring | Phase 1 |
| `yume-level-layout` | augments `yume-level-designer` placement | Phase 2 |

Both skills follow the same outline:
1. Read GDD / spec for layout intent
2. Pick legend (per-game OR per-genre)
3. Generate semantic image via nanobanana with strict prompt
4. Run extractor → schema
5. Run validator
6. If validation fails: prompt the LLM to adjust + re-roll image
7. Compile schema → JSON
8. Emit + patch entity files

The existing skills (yume-asset-designer, yume-level-designer) keep
their roles for non-layout concerns (art direction, narrative
density, rule wiring). The visual-layout skills add a UPSTREAM
layout step.

### Ledger entries

New kinds:
- `visual_layout:semantic_image:<sha256(prompt+legend)>` — paid
  nanobanana image. Persists alongside `.layout.json` and the
  extracted mask images.

Re-runs with same prompt + legend skip re-pay. Editing the legend
or prompt → new hash → fresh gen.

## Consequences

### Enables

- **HUD authoring without iteration**. Aldenmere's 5-round HUD
  becomes a 1-round visual-first authoring pass.
- **Composition-aware level layouts**. Image gen naturally puts
  focal points at thirds-grid intersections, varies density, frames
  the eye — concerns yume-level-designer struggles with.
- **Visual concept-to-playable in one pipeline**. The semantic
  image + the concept screenshot can be generated from the same
  intent, giving the designer both art direction AND extractable
  structure.
- **A new authoring vocabulary**: "draw me a layout where X is here
  and Y is over there" via prompt, no coordinates needed.

### Precludes / costs

- **Adds opencv + sklearn Python deps** to `tools/`. Small
  (~30 MB combined) and well-established.
- **Iteration loop is slower than JSON-edit**. Each prompt change
  costs $0.05 + 5-10s nanobanana wait + extraction time. After
  first extraction, edits should happen in JSON, not re-roll image.
- **CV extraction can fail unpredictably** when the image generator
  ignores the legend. Validator catches; re-roll mitigates. But
  some prompts may need 2-3 re-rolls (cost: $0.10-0.15 worst case).
- **K-means cluster count tuning** per legend. Too few clusters →
  legend entries merge. Too many → noise. Empirical tuning needed
  per legend type.
- **The "beautiful but unparseable" failure mode** is real. We've
  seen it in concept-image generation — Gemini wants to add
  scenery. Mitigated via aggressive `negative_prompt` in the
  generator config + post-quantization legend match (slight drift
  recovers; total ignore doesn't).

### What other ADRs / files this touches

- **ADR 0021** (JSON over Godot): preserved. The compiler's output
  IS the canonical JSON. Engine unchanged.
- **ADR 0051** (authoring-time Python emitters): this is the
  third Python emitter (after yume_codegen + yume_assetgen).
  Lives at `tools/visual_layout/`.
- **ADR 0053** (animation pipeline): same family of capability-
  exposure pattern. Image gen / CV / engine kept in distinct layers.
- New skills: yume-hud-layout, yume-level-layout.
- New validator: `tools/validators/validate_layout.py`.
- Engine: **zero changes**. JSON consumer path is unchanged.

## Alternatives considered

### Alt A — LLM writes raw coordinates (current state)

The status quo. LLMs read prose intent + spec + their training to
emit JSON.

- Pro: no pipeline complexity. Iteration is instant.
- Pro: 100% deterministic — same prompt always yields same output.
- Con: LLM spatial reasoning is mediocre. Manual fix cycles after
  every generation.
- Con: composition (focal points, density falloff, hierarchy) emerges
  by luck.

**Rejected for first-pass layout** — the proposed compiler doesn't
*replace* LLM authoring entirely. It augments it for the spatial
layer where LLMs are weakest. LLM still drives non-spatial concerns
(rules, flavor, narrative).

### Alt B — LLM writes structured tags, designer hand-places

The LLM emits intent like `{anchors: [fire_pit, hut, drying_rack]}`
without positions. A human / Godot editor places them by hand.

- Pro: human spatial judgment is generally better than LLM's.
- Pro: zero pipeline complexity.
- Con: defeats the LLM-driven pipeline goal.
- Con: doesn't scale past 1-2 games.

**Rejected** — manual placement re-couples authoring to humans, the
opposite of Yume's framework goal.

### Alt C — LLM writes coordinates + visual-designer revises

The current pipeline post yume-game-designer + yume-game-reviewer:
LLM writes, visual-designer reviews + revises.

- Pro: leverages existing skill architecture.
- Con: requires the reviewer to articulate fixes in JSON-coordinate
  terms ("move hut 3m east, lower vitals by 40px") — which is hard.
- Con: the reviewer can SEE the bug but the fix-loop is slow.

**Rejected** — keeps the LLM as the spatial author; doesn't address
the underlying weakness. Visual-designer review is still useful for
art direction; this ADR adds a different, complementary upstream
step.

### Alt D — Use Godot's editor + JSON serialization

Use Godot's level editor to place entities, serialize to JSON.

- Pro: full WYSIWYG spatial editing.
- Pro: industry-standard pattern.
- Con: requires per-game Godot scenes (Yume's `.tscn` is intentionally
  minimal per the framework discipline).
- Con: doesn't scale to LLM-driven content generation.
- Con: visual designer can't see playable result without booting
  Godot.

**Rejected** — Yume's invariant is JSON authoring → engine consumes.
A Godot-editor step would re-add manual scene work.

## Open questions

1. **K-means cluster count selection**. Should it be:
   - Per-legend (each legend.json declares its expected k)?
   - Auto-tuned (k = legend_size + n_buffer)?
   - Elbow-method per image?
   - The first prototype will hardcode `k = len(legend) + 2`; if
     extraction quality wobbles, revisit.

2. **How many re-rolls before giving up?** Each re-roll costs $0.05.
   First prototype caps at 3 re-rolls per prompt; if validation
   still fails, log + surface to user. Per-game configurable later.

3. **Legend versioning**. When a legend changes (new component type
   added), do all prior layouts re-extract? Or stay valid against
   their original legend? First prototype: legend hash is part of
   the ledger key; layouts pin to their legend version.

4. **Concept image generation alongside semantic image**. Same
   intent → two prompts (semantic + concept). Cost: $0.10 per
   layout iteration. Worth it for the designer reference? Phase 1
   ships with only the semantic; concept image is an opt-in flag.

5. **Tile-based vs continuous extraction**. Some games (sokoban,
   chess) have grid-aligned layouts. Should the extractor support
   "snap to N-meter grid"? Phase 2 question; Phase 1 is purely
   continuous.

6. **3D layout extraction (not just top-down)**. Can image gen
   produce a side-view of a vertical layout (tower, building
   interior, vertical platformer)? Out of scope for Phase 1-2.
   Future ADR if a 3D platformer demands it.

## References

- ADR 0021 — Yume as JSON layer over Godot (canonical authoring)
- ADR 0046 — Animation via Godot AnimationPlayer (engine consumer)
- ADR 0051 — Authoring-time Python emitters (precedent for
  `tools/` Python pipelines)
- ADR 0053 — Tripo3D animation pipeline (capability-exposure pattern;
  semantic-vs-concept image split first formalized there)
- `.claude/rules/soul.md` § Composition pass — the 10-axis layout
  checklist this compiler should help land
- `feedback_compose_dont_just_generate.md` — "composition is the
  multiplier past ~10 entities" (memory)
- `feedback_review_style.md` — empirical iteration cost on
  Aldenmere HUD
- `tools/yume_assetgen/backends/nanobanana.py` — Gemini Flash
  Image backend, reusable for semantic-image generation
- OpenCV docs — connected components, morphological ops, skeletonization
- scikit-learn `KMeans` — color quantization clustering
