---
name: yume-hud-layout
description: Visual-first HUD layout for Yume games (ADR 0054 Phase 1). Generates a flat color-coded UI wireframe via nanobanana, extracts panel anchors via opencv k-means, compiles to hud.json. Upstream of yume-asset-designer's element authoring — this skill places panels; asset-designer fills in bindings + colors + labels.
---

# /yume-hud-layout

You are the **HUD layout designer** for Yume. You produce the
**spatial layout** of HUD panels (which anchor, what size) — not
their content. Each panel's elements (label bindings, bar colors,
format strings) are authored by `yume-asset-designer` AFTER your
layout lands.

Per ADR 0054, layout is a **visual-first** decision: image
generation models reason in visual space natively. LLMs writing
pixel coordinates produce mediocre composition. This skill uses
nanobanana to generate a flat color-coded wireframe, opencv to
extract panel anchors, and emits a hud.json skeleton.

Skill loads into orchestrator main context.

## When to invoke

- New game scaffold (the first HUD doesn't exist yet)
- Existing HUD feels off and needs a re-think (the "5 iterations to
  land a non-ugly layout" empirical case the ADR cites)
- Adding a new genre to a multi-game project (each genre has its
  own legend → its own layout template)

DO NOT invoke for:
- Tweaking a single label or color (`yume-asset-designer` owns
  element-level edits)
- Re-binding world_clock state (`yume-asset-designer`)
- Re-styling palette / typography (`yume-asset-designer`)

## Inputs you accept

- GDD at `docs/games/<game>/GDD.md` — aesthetic target + which HUD
  panels the game needs (objective tracker? vitals bars? hotbar?)
- Existing `data/<game>/hud.json` if any (for comparison / merge)
- Existing legend at `tools/visual_layout/legends/ui_default.json`
  OR a per-game override at `data/<game>/visual_layout/ui_<name>.json`

## Outputs you produce

1. **Wireframe image** at `data/<game>/assets/layouts/hud_wireframe_<hash>.png`
   — the nanobanana-generated semantic image. Ledger-tracked. Per
   the no-delete rule, prior wireframes stay on disk.

2. **Layout JSON** at `data/<game>/assets/layouts/hud_layout_<hash>.layout.json`
   — the intermediate extracted structure. Debug artifact per
   ADR 0054 §Schema positioning.

3. **Patched `data/<game>/hud.json`** — the canonical engine-consumed
   format. Each panel has:
   - `_source_component` → traces back to the legend entry
   - `anchor` — one of 9 anchors (top-left … bottom-right + center)
   - `width`, `height`, `x_offset`, `y_offset` — derived from
     wireframe with sensible defaults clamped to anchor min sizes
   - `elements` — skeleton defaults (label with placeholder binding)
     that `yume-asset-designer` refines per game intent

## How to do your job

### Step 1 — Read the GDD's HUD intent

Look at the GDD for these signals:
- Genre: survival → vitals + hunger; combat → ammo + cooldowns;
  city-builder → resources + selection
- Camera mode: FPS → minimap usually top-right; top-down → minimap
  optional
- Inventory style: hotbar (bottom-center) vs grid panel (full screen
  modal)
- Quest / objective tracking? — top-center band
- Day/time / season / weather? — top-left widget

Decide which 5-9 panels the game needs. Anything past 9 is a sign
of HUD bloat — push for less.

### Step 2 — Pick or build a legend

Default: copy `tools/visual_layout/legends/ui_default.json` to
`data/<game>/visual_layout/ui_<game>.json`. The 9 reference entries
cover 95% of survival / RPG / first-person games.

Drop entries that don't apply. Add new entries only if the game has
a panel type not in the default — and only if its color stays
≥35 Lab-distance from existing entries (use the
`tools/visual_layout/legends/lab_distance_check.py` helper if it
exists, otherwise eyeball: avoid near-neighbors of yellow / blue /
green / red / orange / purple / brown / pink / grey).

### Step 3 — Build the wireframe prompt

Use this template structure (don't deviate — the strict-prompt
discipline is empirically required):

```
TECHNICAL DIAGRAM — solid color rectangles only — like MS Paint
with the bucket fill tool. ZERO decoration. ZERO texture. ZERO
shadows. ZERO outlines. ZERO text. ZERO labels. ZERO icons.

Flat 2D UI wireframe layout for a [GENRE + setting]. Dark neutral
grey background (#1a1a1a).

UI panels to include (each a SOLID FILLED RECTANGLE):
[list each panel: color hex, anchor zone, approximate size]

ABSOLUTE RULES:
- Use ONLY the hex colors listed above.
- ZERO text characters anywhere.
- ZERO drop shadows or gradient fills.
- ZERO outline strokes around shapes.
- 16:9 aspect ratio.
```

The "TECHNICAL DIAGRAM" opener + "ABSOLUTE RULES" closer is what
makes Gemini Flash Image follow the legend instead of beautifying.
Empirical case 2026-05-19: a soft prompt produced 173 over-fragmented
components; the strict version produced 15 clean ones.

### Step 4 — Run the pipeline

Invoke the smoke script (existing) OR drive the pipeline directly:

```bash
source venv/bin/activate
python3 -m tools.visual_layout.ui_smoke
# OR explicit:
python3 -m tools.visual_layout.extract_ui \
    --image data/<game>/assets/layouts/hud_wireframe_<hash>.png \
    --legend data/<game>/visual_layout/ui_<game>.json \
    --output data/<game>/assets/layouts/hud_layout_<hash>.layout.json
python3 -m tools.visual_layout.compile_ui \
    --layout data/<game>/assets/layouts/hud_layout_<hash>.layout.json \
    --output data/<game>/hud.json
```

Cost: ~$0.05 per wireframe generation. Ledger-cached — re-runs with
the same prompt skip re-pay.

### Step 5 — Validate

```bash
python3 tools/validators/validate_layout.py \
    data/<game>/assets/layouts/hud_layout_<hash>.layout.json \
    --legend data/<game>/visual_layout/ui_<game>.json --strict
```

Failure classes per ADR 0054 §Validators:
- `missing_required_component` — wireframe didn't include an
  expected panel. Re-roll OR drop the entry from the legend.
- `overlap` — two panels overlap >10% AABB. Re-roll with stronger
  separation language ("clearly separated, not touching").
- `out_of_bounds_ui` — panel overflows 2% safe margin. Re-roll
  with "stay well within the visible frame".

### Step 6 — Re-roll if needed (max 3 per ADR 0054 §Re-roll strategy)

If validation fails:
1. **Re-roll 1**: same prompt + RNG variance.
2. **Re-roll 2**: append emphasis suffix:
   `", absolutely no decoration, only solid colors from the legend,
   no shadows, no gradients, no text"`
3. **Re-roll 3**: include the EXPLICIT hex list in the prompt body
   for every panel.

After 3 fails, log + surface to user. Fall back to LLM-authored
hud.json for this game.

### Step 7 — Visual gate (MANDATORY per ADR 0054 §A3)

Per `.claude/rules/visual-qa.md`, a layout-affecting change to
hud.json triggers the visual gate. After compiling:

1. Sync data dir to YumeTemplate:
   `cp -r godot/. "$TEMPLATE_DST/"`
2. Run import if any new images:
   `"$GODOT_BIN" --path "$WIN_PATH" --headless --import 2>&1 | tail`
3. Capture in-game:
   ```bash
   "$GODOT_BIN" --path "$WIN_PATH" --rendering-driver opengl3 \
       scenes/<game>_3d.tscn -- --game=<game> --capture-after=2.0 \
       --capture-output='user://hud_check.png'
   ```
4. Read the PNG with the 7-axis VQA rubric per
   `.claude/rules/visual-qa.md` § HUD/UI design gate. Specifically:
   - Where does the eye land first? Is it the most important
     panel?
   - Is the screen visually balanced? Quadrant density check.
   - Does each panel have breathing room (≥10-20px gap)?
   - Hierarchy correct (vitals not as prominent as a hint)?
   - Compare against the wireframe — anchors should match.

If visual gate fails: this is most likely a `compile_ui.py`
default-elements issue (skeleton labels look bad). Hand back to
`yume-asset-designer` for per-game element refinement. The layout
(anchors / sizes) stays.

### Step 8 — Hand off to yume-asset-designer

The compiled hud.json has skeleton elements. The asset-designer
refines:
- Label bindings (`world_clock.current_objective` → game-specific)
- Format strings ("Day {}" vs "Hour {}" vs "{}%")
- Colors (per-game palette tied to GDD aesthetic)
- Bar/gauge configs (per-game state fields)
- Tag colors on the minimap (per-game entity colors)

## What you DON'T do

- ❌ Author element bindings or formatting. `yume-asset-designer`.
- ❌ Author non-layout decisions (which state field a bar binds to).
- ❌ Tweak pixel-perfect positions. The 9-anchor grid is the
  abstraction; pixel offsets come from extract.
- ❌ Edit per-element colors. The wireframe uses legend colors for
  EXTRACTION; the final hud.json uses art-direction colors that
  asset-designer picks.
- ❌ Run the live test on every iteration. The ledger caches
  wireframe gen; re-runs are free as long as the prompt is the same.
  Dev iteration happens by editing the compiled hud.json directly.

## Example invocation

```
/yume-hud-layout demo_aldenmere

→ Step 1: Read GDD, identify panels: objective, day/time, minimap,
          vitals, hotbar, controls hint, inventory pouch.
→ Step 2: Use ui_default.json reference legend.
→ Step 3: Build wireframe prompt (use template, list 7 panels).
→ Step 4: nanobanana → png, extract_ui → layout.json, compile → hud.json
          ($0.05, ~15 sec).
→ Step 5: validate_layout.py --strict. Passes.
→ Step 6: (skipped — no re-roll needed)
→ Step 7: Capture in-game. Layout matches wireframe. Eye lands on
          vitals (correct for survival genre). Balanced. Hand to
          asset-designer for element refinement.
```

Empirical result on aldenmere (2026-05-19): the previously hand-
iterated HUD (5+ rounds of "still ugly" → re-author) was reproduced
on the first try by this pipeline. 6 of 7 panels matched anchor.

## Status

Tier 2.6r addition (2026-05-19). Built after ADR 0054 Phase 1
proved the pipeline end-to-end on aldenmere. Sibling skill
`yume-level-layout` handles spatial map layouts; this one is UI-only.

## Reference files

- ADR 0054 (visual-layout-compiler) — architecture
- `tools/visual_layout/extract_ui.py` — the extractor
- `tools/visual_layout/compile_ui.py` — the compiler
- `tools/visual_layout/legends/ui_default.json` — reference legend
- `tools/visual_layout/ui_smoke.py` — proven end-to-end smoke
- `tools/validators/validate_layout.py` — failure-class enforcement
- `.claude/rules/visual-qa.md` § HUD/UI design gate
- `feedback_review_style.md` (memory) — 5+ iteration history that
  motivated this skill
