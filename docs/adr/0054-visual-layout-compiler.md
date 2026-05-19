# ADR 0054 — Visual layout compiler (image-gen → CV → JSON → engine)

_Date: 2026-05-19_
_Status: accepted_

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

### Dependencies

| Package | Use |
|---|---|
| `opencv-python-headless` | Connected components, contours, morphological erode/dilate, bounding boxes |
| `scikit-learn` | `KMeans` for color quantization |
| `scikit-image` | `skeletonize` (Zhang-Suen) for path skeletonization + `rgb2lab` for CIE Lab distance |

`opencv-python-headless` (not `opencv-python`) chosen to avoid GUI
deps that don't apply to Yume's headless WSL render path. Total
install size ~50 MB.

Installation discipline: a new `tools/visual_layout/requirements.txt`
ships with the package; the README documents `pip install -r ...`
as part of first-run setup. Pinned versions follow nanobanana's
existing approach (loose minimum, no upper cap unless empirical
breakage forces it).

### Schema (common across UI + map)

```jsonc
{
  "intent": "<the prompt that drove generation>",
  "image_path": "res://data/<game>/assets/layouts/<hash>.png",
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

**Schema positioning** (post tech-director review 2026-05-19):
`.layout.json` is an **intermediate / debug artifact**, NOT a
primary source of truth. The canonical JSON the engine consumes
remains `hud.json` / `entities.json` (per ADR 0021). The compiler:
1. Extracts the layout image into `.layout.json` (intermediate)
2. Compiles `.layout.json` into the canonical `hud.json` /
   `entities.json` directly
3. Keeps `.layout.json` on disk for debugging + re-compilation
   (e.g., if you tweak a legend's world-size, you can re-derive
   without re-rolling the image)

This avoids schema-duplication drift: a future change to
`hud.json`'s rect shape automatically applies (the compiler
re-emits). The `.layout.json` is what `tools/visual_layout/` owns;
the canonical formats are unchanged.

Both files live alongside the image. Ledger-tracked (paid image
gen + extraction time cost).

### Validators

New `tools/validators/validate_layout.py`. Failure classes split
into **image-content** (the extracted scene graph is malformed —
the image didn't follow the legend or extraction produced garbage)
and **playability** (the extraction succeeded but the resulting
scene isn't playable):

**Image-content failures** (the new class — extraction step):

| Class | Detection | Mitigation |
|---|---|---|
| `missing_required_component` | Expected legend entry has zero matching mask pixels OR zero connected components above min-area threshold | Re-roll image gen; on 3rd re-roll, surface to user |
| `centroid_conflict` | Two distinct legend entries got matched to the same k-means centroid (the legend has 14 entries but quantization clustered the image into 9 with two entries collapsing) | Increase `expected_clusters`; or merge in extractor (warn) |
| `over_count` | Legend says "exactly 1 fire_pit" but extractor found 3 connected components | Pick highest-confidence by area; warn |
| `under_count` | Legend says "≥3 berry_bush" but only 1 found | Re-roll OR repair via scatter inside grass mask |
| `mask_intersects_self` | A region's mask is non-simply-connected (donut shape) when legend says it should be simply-connected | Repair via fill holes; warn |
| `noise_components` | Lots of tiny components (<5px²) suggesting JPEG artifacts or anti-aliasing leak | Drop components below min-area threshold; no warn |

**Playability failures** (existing class — schema step, applies to
any compiled layout regardless of source):

| Class | Detection | Mitigation |
|---|---|---|
| `overlap` | Two anchor footprints have ≥20% AABB intersection | Move offending anchor toward nearest grass mask centroid |
| `unreachable` | Anchor has no path-mask connection to spawn | Add repair-path via shortest A* through grass mask |
| `unwalkable_path` | Path mask is interrupted (disjoint after skeletonization) | Re-roll OR repair via grass-fill |
| `critical_on_wrong_zone` | E.g. fire_pit centroid lands inside river mask | Move to nearest grass mask centroid; warn |
| `out_of_bounds_ui` | UI rect overflows screen safe-margin | Clamp to safe rect; warn |
| `overlap_ui` | Two UI rects have ≥10% intersection | Reposition smaller toward nearest free quadrant |

Each class is falsifiable (concrete numeric thresholds) and pluggable
per legend (overridable thresholds in `legend.json`). Pluggable
validation rules per legend type via the same loader pattern as
`tools/validators/run_all.py`.

### New skills

| Skill | Replaces / extends | Phase |
|---|---|---|
| `yume-hud-layout` | augments `yume-asset-designer` HUD authoring | Phase 1 |
| `yume-level-layout` | augments `yume-level-designer` placement | Phase 2 |

### Phase / sequencing plan (post-review)

User picked "both use cases in parallel". Tech-director flagged
this as 2× surface area before the architecture is proven. Resolved
sequencing:

| Step | Scope | Duration | Output |
|---|---|---|---|
| **0** | Write `extractor_common.py` — k-means + legend match + mask helpers. Shared foundation. Unit tests with synthetic input. | ~1.5 hrs | Importable module + 4-6 tests |
| **1** | UI pipeline end-to-end: `extract_ui.py` + `compile_ui.py` + `yume-hud-layout` skill + legend + validator | ~2 hrs | Aldenmere HUD wired via compiler |
| **2** | Visual gate on Phase 1 output. Compare against current hand-authored hud.json. If extractor produces equivalent-or-better layout: declare proven. If worse: iterate before Phase 3. | ~30 min | A/B captures + decision |
| **3** | Map pipeline: `extract_map.py` (zones, anchors, paths, skeletons) + `compile_map.py` + `yume-level-layout` skill + legend + validator | ~3 hrs | Aldenmere level layout via compiler |
| **4** | Visual gate on Phase 3. Compare against current `level/entities.json`. Same A/B discipline as Phase 2. | ~30 min | Decision |

Total: ~7.5 hours. Phase 0 is mandatory before either Phase 1 or
Phase 3 — without the shared common module, the two pipelines would
diverge in subtle ways. Phase 1 + 2 must complete + verify before
Phase 3 starts; this catches architecture issues at half the cost.

### Re-roll strategy (post-review)

3 re-rolls cap per validation failure. Progressive escalation:

1. **Re-roll 1**: same prompt + same legend. RNG variance may
   resolve it.
2. **Re-roll 2**: same prompt + appended emphasis suffix (e.g.
   `", absolutely no decoration, only solid colors from the legend,
   no shadows, no gradients"`).
3. **Re-roll 3**: same prompt + EXPLICIT legend color list in body
   (e.g. `", use only these exact colors: #c0a020 for fire pit,
   #8a3030 for hut, #4a8030 for grass"`).
4. **After 3 fails**: log to ledger as `image_gen_unparseable`,
   surface to user, fall back to LLM-authored layout for this run.

Per-rerolltool budget: $0.05. Worst-case $0.20 per layout. Acceptable
for first-pass authoring (the layout is then JSON-canonical and
editable without re-rolling).

### K-means cluster count (post-review, was open question #1)

**Default**: `k = len(legend) + 2` (the +2 absorbs anti-aliased
edge pixels + JPEG-noise pseudo-clusters).

**Override**: per-legend `expected_clusters: N` in `legend.json` for
legends where empirical extraction quality wobbles.

**Auto-tune**: deferred. Not implementing elbow-method in Phase 1;
the default has worked in pixel-art game-asset extraction
prototypes outside Yume. If the default proves wrong, the override
path lets per-game tuning happen without engine changes.

### Legend authoring (post-review, A1 clarification)

Legends live at **`data/<game>/visual_layout/<legend>.json`** —
per-game content, not framework-shipped. The framework ships
**reference legends** at `tools/visual_layout/legends/` as
templates. New games either:
1. Copy a reference legend + tweak (most cases)
2. Author a custom legend from scratch (rare; needs designer
   experience with the extractor's invariants)

This matches the existing pattern: `data/lib/` ships reference
content (cameras, input bundles, motion rules); per-game `data/
<game>/` overrides. Visual-layout legends slot in identically.

### Concept image vs semantic image (A2 clarification)

This ADR commits to **Phase 1 ships semantic-only**. Concept image
generation already happens via `yume-asset-designer`'s existing
nanobanana calls (for reference images that feed Tripo3D
image-to-3D). The two pipelines stay separate:
- Semantic image → `tools/visual_layout/` → extracted JSON
- Concept image → `tools/yume_assetgen/` → mesh + texture

A future ADR may unify them (same intent prompt drives both, output
ledger-tracked together) but not in this ADR.

### Visual gate (A3 commitment)

Per `.claude/rules/visual-qa.md`, layout-affecting changes trigger
the visual gate. New skills `yume-hud-layout` and `yume-level-layout`
include the visual-qa step in their workflow:

1. Generate semantic image
2. Run extractor + validator + repair
3. Compile to hud.json / entities.json
4. **Sync to YumeTemplate**
5. **Capture in-game**
6. **Read PNG with the 7-axis rubric** (or invoke yume-visual-designer)
7. If visual review fails: hand back to the LLM-authored revision
   path OR re-roll image (depending on root cause)

This gate is mandatory. We trade LLM-spatial-error for
image-gen-spatial-error; without the gate we'd lose validation that
catches both.

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

1. **K-means cluster count** — RESOLVED 2026-05-19 (tech-director
   review). Default `k = len(legend) + 2`; per-legend override
   via `expected_clusters` field. See §K-means cluster count above.

2. **Re-roll cap** — RESOLVED 2026-05-19. 3 re-rolls max with
   progressive prompt escalation. See §Re-roll strategy above.

3. **Legend versioning**. When a legend changes (new component type
   added), do all prior layouts re-extract? Or stay valid against
   their original legend? First prototype: legend hash is part of
   the ledger key; layouts pin to their legend version.

4. **Concept image alongside semantic** — RESOLVED 2026-05-19.
   Phase 1 ships semantic-only. Concept image is a separate
   `yume-asset-designer` pipeline. Unification deferred to future
   ADR. See §Concept image vs semantic image above.

5. **Tile-based vs continuous extraction**. Some games (sokoban,
   chess) have grid-aligned layouts. Should the extractor support
   "snap to N-meter grid"? Phase 2+ question; Phase 1 is purely
   continuous.

6. **3D layout extraction (not just top-down)**. Can image gen
   produce a side-view of a vertical layout (tower, building
   interior, vertical platformer)? Out of scope for Phase 1-2.
   Future ADR if a 3D platformer demands it.

## References

- ADR 0021 — Yume as JSON layer over platform (canonical authoring)
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
