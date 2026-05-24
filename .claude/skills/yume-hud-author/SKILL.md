---
name: yume-hud-author
description: Fit-fit HUD authoring from a wireframe image. Reads the per-game context from tools/visual_layout/wireframe_to_hud.py preprocess (binding manifest + element catalog + viewport + scale factors + anchor geometry formulas) AND the wireframe PNG directly via vision, then authors a hud.json where every panel's geometry is DERIVED from its wireframe bbox (not chosen freely) and every element type comes from the engine catalog. Replaces the CV-based yume-hud-layout pipeline — the LLM IS the parser. Tier 2.7v (2026-05-19).
---

# /yume-hud-author

> **STABLE — 2D fit-fit pipeline (confirmed 2026-05-24).** This skill
> + its harness (compose_hud, wireframe_to_hud) is locked. Modifying
> the workflow requires an ADR + scenario regression tests. Active
> work on Yume's 3D map/world pipeline lives at
> `/yume-map-author` and is NOT bound by this status.
>
> Note: the live `hud.json` per-game CONTENT can keep evolving. Stable
> means "the harness produces JSON correctly." Per-game UX iteration
> is normal authoring, not a harness change.

You are the **HUD author** for Yume. You read a wireframe image and
produce a fit-fit `hud.json` — meaning the in-game HUD matches the
wireframe pixel-for-pixel (modulo the wireframe→viewport scale).

This skill is the LLM-in-the-loop layer of the wireframe-to-hud
harness. The deterministic surface (preprocess + postprocess) lives
at `tools/visual_layout/wireframe_to_hud.py`. The wisdom that turns
a wireframe into HUD JSON lives here.

## Why this skill exists (and what it replaces)

The earlier `yume-hud-layout` skill used opencv k-means to parse
wireframes. It worked for clean wireframes but failed on Gemini's
output variance: subtle color drift between regions, soft edges from
JPEG compression, regions that looked obviously-vitals to a human but
quantized into the wrong cluster.

The fix isn't a smarter parser. It's **putting Claude at the parsing
step**. Claude reads the wireframe directly via vision, knows the
schema, and produces the JSON without intermediate parsing. The CV
gives us reliable image dimensions; the LLM gives us reliable
semantic identification.

Fit-fit means: what's drawn IS the layout. No "preserve existing
panel sizes" merge step. No "pick reasonable defaults" templates.
The wireframe is the source of truth.

## When to invoke

- A `compose_hud.py` run that needs to convert a new wireframe →
  hud.json (the normal authoring path)
- Iterating on an existing wireframe — re-runs produce a fresh
  hud.json that matches the new wireframe
- New game scaffold — first HUD ever

Do **not** invoke for:
- Element-level tweaks ("change bar color from red to orange") —
  edit hud.json directly, no wireframe involved
- Adding a `binds` to a single label — direct edit

## Inputs

1. A wireframe PNG (or JPEG, see preprocess notes) at a known path
2. The game id (e.g. `demo_aldenmere`)
3. *Optional*: a previous hud.json for win/lose carry-over

## The procedure

### Step 1 — Run preprocess

```bash
python3 -m tools.visual_layout.wireframe_to_hud preprocess \
    <game> <wireframe.png>
```

This writes `/tmp/_hud_author_context.json` with everything you need:

- `wireframe.width/height/aspect_ratio`
- `viewport.width/height/aspect_ratio` (target — the in-game canvas)
- `scale_to_viewport.x/y` — multiply wireframe pixels by these to get
  viewport pixels
- `aspect_mismatch` — if true, flag in your report; geometry is
  unsafe
- `hud_anchors` — the 9 valid anchor names
- `hud_panel_fields` — what fields a panel dict accepts
- `hud_anchor_geometry` — per-anchor formula for computing
  `x_offset`/`y_offset` from a bbox (the heart of fit-fit)
- `hud_elements` — element types + their fields + sources
- `binding_manifest` — every legal `binds` path, keyed by namespace
- `binding_allow_list` — the same paths as a flat list (use for
  membership checks)
- `binding_notes` — pattern allow-rules for `world.X` and `def.X.Y`
- `authoring_rules` — repeats the constraints below

### Step 2 — Read the wireframe + the context

Use the Read tool on the wireframe PNG (Claude has vision; the PNG
is parsed natively).

Use the Read tool on `/tmp/_hud_author_context.json`.

### Step 3 — For each visible region in the wireframe

#### 3a — Identify the region's anchor

Map the bbox center to the nearest of the 9 anchor cells. The
viewport divides into a 3×3 grid; the bbox center's quadrant gives
the anchor:

| bbox.cy bucket | bbox.cx bucket | anchor |
|---|---|---|
| top 1/3 | left 1/3 | top-left |
| top 1/3 | mid 1/3 | top-center |
| top 1/3 | right 1/3 | top-right |
| mid 1/3 | left 1/3 | center-left |
| mid 1/3 | mid 1/3 | center |
| mid 1/3 | right 1/3 | center-right |
| bottom 1/3 | left 1/3 | bottom-left |
| bottom 1/3 | mid 1/3 | bottom-center |
| bottom 1/3 | right 1/3 | bottom-right |

If a region straddles two cells, pick the one its CENTER falls into.
Do not split a single region across multiple panels.

#### 3b — Identify the element type(s) inside

This is where strictness matters. **If you cannot confidently match
a region to one of the 6 catalog element types, emit nothing for
that region and flag it in the report.** Do not invent new types.
Do not approximate a doughnut chart as a `progress_bar` if the
shape is clearly a circle — flag and skip.

Visual cues per element type:

- **label** — a thin rectangular band, often with text inside in
  the wireframe (the text glyphs may render as colored marks; the
  shape is "horizontal text-line block")
- **progress_bar** — a rectangular bar, usually elongated
  horizontally, often with a fill-percentage shown via gradient or
  partial fill. Often appears in *stacks* (4-5 bars vertically =
  vitals)
- **spacer** — empty gap between elements (don't emit unless
  needed for vertical separation)
- **crosshair** — a small `+` or cross glyph at exact center,
  ~16-32px. ALSO: a small medium-grey/light square (~16-40px) at
  the EXACT center of the canvas is the wireframe convention for
  this element (the strict-template wireframe can't render text
  glyphs, so a colored square stands in for the `+`). When you see
  a tiny element at canvas-center and no other element fits, this
  is almost always crosshair — emit a `crosshair` element (its
  fields are `glyph` defaulting to "+", `size`, `color`) rather
  than a slot_grid or label.
- **minimap** — a roughly-square block (~150-220px each side) with
  internal detail (dots / regions), usually top-right or
  bottom-left corner
- **slot_grid** — a row or grid of small square cells (4-10 cells,
  ~40-60px each, separated by small gaps). Typically inventory.

Composite regions: a single panel anchor often contains *multiple*
elements (e.g. vitals = 1 title label + 4 (label + progress_bar)
pairs). Emit them all as `elements` within one panel.

#### 3c — Compute geometry deterministically

Each panel needs `width`, `height`, `x_offset`, `y_offset`. Compute
from the bbox after scaling to viewport pixels:

```
bbox_vp = {
    x:  bbox.x  * scale_to_viewport.x,
    y:  bbox.y  * scale_to_viewport.y,
    x2: bbox.x2 * scale_to_viewport.x,
    y2: bbox.y2 * scale_to_viewport.y,
}
width  = bbox_vp.x2 - bbox_vp.x
height = bbox_vp.y2 - bbox_vp.y
```

Then apply `hud_anchor_geometry[anchor]`:

| anchor | x_offset | y_offset |
|---|---|---|
| top-left | `bbox_vp.x` | `bbox_vp.y` |
| top-center | `(bbox_vp.x + bbox_vp.x2)/2 - vp.w/2` | `bbox_vp.y` |
| top-right | `-(vp.w - bbox_vp.x2)` | `bbox_vp.y` |
| center-left | `bbox_vp.x` | `(bbox_vp.y + bbox_vp.y2)/2 - vp.h/2` |
| center | `(bbox_vp.x + bbox_vp.x2)/2 - vp.w/2` | `(bbox_vp.y + bbox_vp.y2)/2 - vp.h/2` |
| center-right | `-(vp.w - bbox_vp.x2)` | `(bbox_vp.y + bbox_vp.y2)/2 - vp.h/2` |
| bottom-left | `bbox_vp.x` | `-(vp.h - bbox_vp.y2)` |
| bottom-center | `(bbox_vp.x + bbox_vp.x2)/2 - vp.w/2` | `-(vp.h - bbox_vp.y2)` |
| bottom-right | `-(vp.w - bbox_vp.x2)` | `-(vp.h - bbox_vp.y2)` |

Round to integers. These math forms match
`control_factory.gd::apply_anchor_sized_rect`'s anchor-relative
positioning — the values you emit ARE the in-engine offsets.

#### 3d — Pick element fields strictly

For each element you emit, ONLY use field names listed in
`hud_elements[i].fields`. Required fields per type:

- **label**: at least one of `text` (literal) or `binds` (path).
  Literal text must start with a capital letter or `→` per the
  formula-eval discipline in data-demo.md.
- **progress_bar**: `binds` is required. `max` defaults to 100;
  set explicitly if a vital scales differently.
- **slot_grid**: `cell_count` + `columns` + `binds` are required.
- **minimap**: `size` + `world_bounds` + `tag_colors` are required.
- **crosshair / spacer**: no required fields beyond defaults.

#### 3e — Pick binds from the manifest, never invent

Every `binds` value MUST appear in `binding_allow_list`, except:

- `world.X` is allowed if `X` is in `binding_manifest.world`
  (engine-injected fields + state_set target=world writes)
- `def.X.Y` is allowed if you've verified the entity-def `X` has
  the `Y` property in this game's `entities/` dir (rare —
  primarily used by `slot_grid` `cell_content_type: item_icon`)

If you can't find a legal bind for what the wireframe implies, emit
the element as a *static label* (text only, no binds) and flag in
the report that the binding may need authoring.

### Step 4 — Carry-over win/lose blocks

If `data/<game>/hud.json` already exists, read it and copy its
`win` + `lose` blocks verbatim into your draft. These are game
mechanics, not layout — wireframes don't capture them. Only edit
them if the user explicitly asked.

### Step 5 — Write the draft + run postprocess

Write your authored JSON to `/tmp/_hud_draft.json`. Then:

```bash
python3 -m tools.visual_layout.wireframe_to_hud postprocess \
    <game> /tmp/_hud_draft.json
```

Postprocess validates:
- Every anchor in `hud_anchors`
- Every element `type` in `hud_elements`
- Every `binds` in `binding_allow_list` (or matches `world.X` /
  `def.X.Y` patterns)

If validation fails, **fix your draft and re-run postprocess**.
Don't pass `--force` — that defeats the gate.

### Step 6 — Report

In your final user-facing message, report:

1. **Regions identified** — N regions, anchor + element types per
2. **Regions skipped** — any region you couldn't confidently
   classify, with reason
3. **Binds without authoring** — labels you emitted as literal text
   because no matching binding existed
4. **Aspect / scale notes** — call out if `aspect_mismatch: true`
   in context
5. **The applied hud.json path** — where it landed

## Strict rules (the fit-fit invariants)

1. **Geometry is derived, never chosen.** If you can't compute a
   value from the bbox using the formulas above, you don't have a
   value. Don't substitute "20" because it "feels right."
2. **Element types are catalog-only.** The 6 types in
   `hud_elements` are the entire vocabulary. New types require an
   engine ADR — not your call.
3. **Binds are manifest-only.** Same logic.
4. **Aspect mismatch is a yellow flag.** If wireframe aspect ≠
   viewport aspect (>2% drift), the geometry math no longer
   corresponds to what the player sees. Flag in the report.
5. **One panel per region.** Don't split a single visual region
   across two panels; don't merge two distinct regions into one.

## What this skill does NOT do

- Does **not** decide WHAT to put in the HUD. The wireframe + the
  user's intent decide that. You translate.
- Does **not** generate the wireframe. `compose_hud.py` owns the
  Gemini call.
- Does **not** edit win/lose conditions (carry-over only).
- Does **not** decide bar colors, palettes, fonts. Those come from
  the wireframe (if it shows them) or from defaults; let
  yume-asset-designer polish after.

## Empirical case (2026-05-19)

The earlier CV-based pipeline shipped a "consolidated HUD" round
where every panel snapped to the top-right corner because the
extractor misclassified anchor cells for borderline-cropped regions.
Three rounds of revision; user feedback "still ugly." Switching to
LLM-as-parser fixes the class of bug — the LLM sees a clearly-
top-right minimap and emits `top-right`, no quantization drift.

## Reference files

- `tools/visual_layout/wireframe_to_hud.py` — preprocess +
  postprocess (the deterministic surface this skill drives)
- `docs/engine-reference/api-manifest.json` — element catalog +
  viewport + anchor geometry (read transitively via the context)
- `godot/scripts/engine/ui/widgets/hud_builder.gd` — actual
  element-building code; if you're ever unsure of a field, this is
  authoritative
- `godot/scripts/engine/ui/control_factory.gd` —
  `apply_anchor_sized_rect` — where the geometry math is implemented
  in the engine
- `.claude/rules/visual-qa.md` — HUD/UI design gate (run after this
  skill lands to verify visual quality, not just structural
  correctness)
