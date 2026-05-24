---
name: yume-screen-author
description: Fit-fit SCREEN authoring from a wireframe image — for modal/full-cover UIs declared in screens.json (inventory, pause, settings, title menu, ending screens, ...). Sibling of yume-hud-author. Reads the per-game context from tools/visual_layout/wireframe_to_screen.py preprocess (broader 13-element catalog including interactive button/slider/checkbox + transition_screen target allow-list + effect allow-list) AND the wireframe PNG directly via vision, then authors a screen dict where every element's geometry is DERIVED from its wireframe bbox, every element type comes from the engine catalog, every `binds` is manifest-approved, every `transition_screen` target resolves, and every effect chain obeys destructive-last ordering. Tier 2.7v (2026-05-20).
---

# /yume-screen-author

> **STABLE — 2D fit-fit pipeline (confirmed 2026-05-24).** This skill
> + its harness (compose_screen, wireframe_to_screen) is locked.
> Modifying the workflow requires an ADR + scenario regression tests.
> Active work on Yume's 3D map/world pipeline lives at
> `/yume-map-author` and is NOT bound by this status.
>
> Note: the live `screens.json` per-game CONTENT can keep evolving.
> Stable means "the harness produces JSON correctly." Per-game UX
> iteration is normal authoring, not a harness change.

You are the **screen author** for Yume. You read a wireframe image of a
modal or full-cover UI and produce a fit-fit screen entry for that
game's `screens.json` — meaning the in-game screen matches the
wireframe pixel-for-pixel (modulo the wireframe→viewport scale) AND
its interactive elements wire correctly.

This is the sibling skill to `yume-hud-author`. Same harness pattern,
broader vocabulary, extra validation. The deterministic surface lives
at `tools/visual_layout/wireframe_to_screen.py`.

## Why this skill exists (vs yume-hud-author)

- **HUD** = always-on overlay during gameplay. Read-only display
  (vitals, minimap, objective, hotbar). Narrow element catalog: 6
  types, all non-interactive.
- **Screen** = modal or full-cover UI gated by player input
  (inventory open with `I`, pause with `Esc`, settings menu, title).
  Broader catalog: 13 types including `button`, `slider`,
  `checkbox`, `option_button` — interactive elements with effect
  chains.

Screens are the bigger semantic surface. A button click can fire any
effect type the engine supports (state_set, transition_screen, emit,
play_sound, ...). The skill's job is to wire those chains correctly
WITHOUT inventing actions outside what the manifest allows.

## When to invoke

- A `compose_screen.py` run that needs to convert a wireframe →
  screen entry (the normal authoring path)
- Iterating on an existing screen — re-runs replace the entry
  identified by `screen_id`
- New screen — first time a game adds e.g. an inventory or pause UI

Do **not** invoke for:
- Single-element tweaks ("rename button text") — direct edit
- Re-wiring an existing screen's effect chains without changing
  layout — direct edit (or compose with `--edit`)
- HUD changes — that's `yume-hud-author`

## Inputs

1. A wireframe PNG (or JPEG)
2. The game id (e.g. `demo_aldenmere`)
3. The target screen id (e.g. `inventory`, `pause`, `settings`)

## The procedure

### Step 1 — Run preprocess

```bash
python3 -m tools.visual_layout.wireframe_to_screen preprocess \
    <game> <wireframe.png> <screen_id>
```

This writes `/tmp/_screen_author_context.json` with:

- All of yume-hud-author's context (wireframe/viewport/scale,
  binding manifest, anchor geometry)
- `screen_elements` — the 13-type catalog (label / button / vbox /
  hbox / color_rect / spacer / image / slider / checkbox /
  option_button / slot_grid / minimap / settings_renderer)
- `screen_fields` — top-level screen dict fields
- `interaction_events` — which element types fire which events
- `existing_screen_ids` — for `transition_screen` target validation
- `transition_targets_allow_list` — existing ids + `@previous` +
  `@root` + your own `screen_id` (for self-references)
- `effect_allow_list` — every effect type the engine supports (~59)
- `destructive_effects` — the subset that destroys current state
  and MUST be last in any chain

### Step 2 — Read the wireframe + the context

Use Read on both. The wireframe is parsed natively via vision; the
context is JSON the deterministic surface assembled for you.

### Step 3 — Per visible region in the wireframe

#### 3a — Identify the region's anchor

Same 3×3 grid as hud-author: top/mid/bottom × left/center/right.
Plus `fill` for full-screen-spanning regions like a modal's dim
background.

For screens, screen_anchors uses **underscore form** (`top_left`,
`top_center`) per existing convention.

#### 3b — Identify the element type

Visual cues per type:

- **label** — flat text band. Plain rectangle, no border, no fill
  contrast.
- **button** — RECTANGLE WITH BORDER + text inside. The visible
  border (or a distinct background color block) is the cue. Often
  rounded corners or a "card" feel.
- **vbox / hbox** — invisible CONTAINER for a group of stacked
  elements. The wireframe doesn't draw vboxes directly; you infer
  one when several elements share an anchor + tight vertical (vbox)
  or horizontal (hbox) stacking.
- **color_rect** — large solid-color block, often dim/dark. Used
  for modal backgrounds (anchor=fill, semi-transparent black).
- **image** — a textured rectangle. The wireframe draws it as a
  solid block; you'd emit `image` only if the prompt or context
  explicitly indicates a sprite/texture asset.
- **slider** — a HORIZONTAL bar with a small handle (often a
  distinct dot or square at one position along the bar). Used in
  settings.
- **checkbox** — a SMALL SQUARE (often with a check/dot inside) +
  adjacent label.
- **option_button** — a button-shaped region with a dropdown
  triangle or "▼" inside, OR a fixed-width button with text that
  represents a single selected value.
- **slot_grid** — a row or grid of small square cells. ≥4 cells.
- **minimap** — square block with internal dot/region detail.
- **settings_renderer** — placeholder vbox the SettingsManager
  fills in. Only used in the settings menu screen.

The button-vs-label call is the most important judgment in screens.
If a rectangle has a visible border/fill and there's text inside, it
is a button. If it's just a plain text band, it is a label.

**If you cannot confidently match a region to one of the 13 catalog
types, emit nothing for that region and flag in the report.**

#### 3c — Compute geometry deterministically

Same formulas as hud-author:

```
bbox_vp = bbox * scale_to_viewport
width  = bbox_vp.x2 - bbox_vp.x
height = bbox_vp.y2 - bbox_vp.y
```

Apply `screen_anchor_geometry[anchor]`:

| anchor | x_offset | y_offset |
|---|---|---|
| top_left | `bbox_vp.x` | `bbox_vp.y` |
| top_center | `(bbox_vp.x + bbox_vp.x2)/2 - vp.w/2` | `bbox_vp.y` |
| top_right | `-(vp.w - bbox_vp.x2)` | `bbox_vp.y` |
| center_left | `bbox_vp.x` | `(bbox_vp.y + bbox_vp.y2)/2 - vp.h/2` |
| center | `(bbox_vp.x + bbox_vp.x2)/2 - vp.w/2` | `(bbox_vp.y + bbox_vp.y2)/2 - vp.h/2` |
| center_right | `-(vp.w - bbox_vp.x2)` | `(bbox_vp.y + bbox_vp.y2)/2 - vp.h/2` |
| bottom_left | `bbox_vp.x` | `-(vp.h - bbox_vp.y2)` |
| bottom_center | `(bbox_vp.x + bbox_vp.x2)/2 - vp.w/2` | `-(vp.h - bbox_vp.y2)` |
| bottom_right | `-(vp.w - bbox_vp.x2)` | `-(vp.h - bbox_vp.y2)` |
| fill | n/a (no offsets needed) | n/a |

Round to integers.

#### 3d — Wire interactive elements (the big difference from HUD)

For every `button` / `slider` / `checkbox` / `option_button`, decide:
*what event fires when the user interacts, and what effects run?*

- `button` fires `on_click` (list of effects)
- `slider` / `checkbox` / `option_button` fire `on_change` (list of
  effects, receives `{value: new}` in context)

**Default close-button pattern** — a button labeled "Close" / "X" /
"Back" / "Cancel" with NO further intent should always emit:

```jsonc
"on_click": [
  {"type": "transition_screen", "target": "@previous"}
]
```

That pops the modal off the screen stack and returns to whatever was
underneath. `@previous` is in `transition_targets_allow_list` by
default.

**Action buttons** — buttons labeled with a verb ("Save", "Reset",
"Apply") need their full effect chain authored. Use ONLY effect
types listed in `effect_allow_list`. If you can't confidently
determine what effect chain a button should fire, emit the button
with ONLY a `transition_screen @previous` close + flag in the report
that the chain needs hand-authoring.

**Effect-chain ordering rule (THE GATE)**:

Destructive effects (`transition_level`, `reload_scene`,
`load_state`, `quit_app`) destroy the current scene/state. **They
MUST be the LAST effect in any chain.** Anything after gets
silently dropped at end-of-frame. Postprocess validates and rejects
violations. See `.claude/rules/engine-scripts.md` § effect-chain
gate for the empirical case (sokoban "New Game" button shipped
broken because of this).

If the chain needs to do other things BEFORE the destruction (e.g.
`save_state` then `transition_level`), order them correctly.

#### 3e — Pick binds from the manifest, never invent

Same rule as hud-author. `binds` strings must appear in
`binding_allow_list`, or match `world.X` pattern with X in
`binding_manifest.world`, or `def.X.Y` if you've verified the def
field exists.

If you can't find a legal binding for a label that the wireframe
implies should be dynamic, emit the label with literal `text`
(starting with a capital letter or `→` per data-demo.md formula-eval
discipline) and flag in the report.

### Step 4 — Decide modal vs full-cover

Top-level screen fields (see `screen_fields`):

- **`modal: true`** — previous screen stays VISIBLE underneath. Use
  for pause/inventory/settings where the player should see the
  world dimmed.
- **`freeze_world: true`** — world simulation pauses while shown.
  Almost always paired with modal. Default to TRUE for
  inventory/pause/settings.
- **`background_color`** — full-cover fill color. Default `#000000`
  for full-cover; pick a dark hex like `#0e0c0a` for modals.
- **`background_alpha`** — for modal screens, dim the world (0.94 =
  almost-opaque, 0.6 = clearly see-through). Default 1.0 (full
  cover).

**Inventory / pause / settings** convention:
`{modal: true, freeze_world: true, background_alpha: 0.94}`.

**Title / ending** convention:
`{modal: false, freeze_world: false, background_alpha: 1.0}`.

If the wireframe shows a translucent overlay (dark but the world is
faintly visible), pick the modal config.

### Step 5 — Compose the screen dict

Top-level shape:

```jsonc
{
  "id": "<screen_id>",                  // matches context.screen_id
  "modal": true,                         // per step 4
  "freeze_world": true,
  "background_color": "#0e0c0a",
  "background_alpha": 0.94,
  "elements": [
    /* one per identified region, with computed geometry */
  ]
}
```

Write to `/tmp/_screen_draft.json`.

### Step 6 — Run postprocess

```bash
python3 -m tools.visual_layout.wireframe_to_screen postprocess \
    <game> /tmp/_screen_draft.json
```

Postprocess validates:
- `id` matches the context's `screen_id`
- Every element `type` in `screen_elements`
- Every `anchor` in `screen_anchors` (underscore or dash form)
- Every `binds` in `binding_allow_list` (or `world.X` / `def.X.Y`)
- Every `transition_screen` target in
  `transition_targets_allow_list`
- Every effect type in `effect_allow_list`
- Destructive effects are LAST in their chains
- vbox/hbox children recurse + validate too

If validation fails, fix the draft and re-run. Don't pass `--force`.

On success: backs up `screens.json` → `screens.json.bak`, splices
the new screen (replaces if `id` matches an existing screen,
appends otherwise).

### Step 7 — Report

User-facing message:

1. **Regions identified** — N regions, anchor + type per
2. **Regions skipped** — any region you couldn't confidently
   classify
3. **Effect chains authored** — per interactive element, what
   chain you wired
4. **Effect chains needing hand-authoring** — buttons where the
   intent wasn't clear from the wireframe (you emitted a
   placeholder close-chain)
5. **Binds without authoring** — labels emitted as literal text
6. **Modal config** — modal / freeze_world / background_alpha
   choices + rationale
7. **Aspect / scale notes** — if `aspect_mismatch: true`
8. **The applied screens.json path**

## Strict rules (the fit-fit invariants)

Same five from hud-author, plus three screen-specific ones:

1. Geometry is derived, never chosen.
2. Element types are catalog-only.
3. Binds are manifest-only.
4. Aspect mismatch is a yellow flag.
5. One element per region.
6. **`transition_screen` targets must resolve.** No
   `target: "future_screen_we_might_make"` — only existing IDs +
   `@previous` / `@root` + your own screen_id.
7. **Effect-chain destructive-last rule is non-negotiable.** Don't
   queue effects after `transition_level` / `reload_scene` /
   `load_state` / `quit_app`. Postprocess enforces.
8. **Default to safe close-chains.** A button you can't author
   meaningfully → `[{type: transition_screen, target: @previous}]`
   + flag in report. Never guess at a state mutation the wireframe
   doesn't explicitly call for.

## What this skill does NOT do

- Does **not** decide WHICH screens a game should have. The game
  designer / screen-flow-designer chooses that.
- Does **not** generate the wireframe. `compose_screen.py` owns the
  Gemini call.
- Does **not** wire `global_inputs` (top-level input → effect chain
  bindings). That's separate authoring, not per-screen.
- Does **not** invent action effects beyond what the wireframe
  shows + manifest allows. If unsure, emit close-only and flag.

## Empirical case (2026-05-20)

Built after the HUD harness shipped successfully. Same pattern,
different surface — bigger element catalog, interaction wiring,
effect-chain validation. The "destructive-last" gate already exists
as a project rule (`.claude/rules/engine-scripts.md`); this skill
enforces it at author time, not just at code review.

## Reference files

- `tools/visual_layout/wireframe_to_screen.py` — preprocess +
  postprocess
- `docs/engine-reference/api-manifest.json` — screen_elements +
  screen_anchors + screen_fields + interaction_events +
  effect catalog
- `godot/scripts/engine/ui/control_factory.gd` — element builders
  (authoritative on field names)
- `godot/scripts/engine/ui/screen_flow.gd` — screen-stack semantics,
  modal pop, freeze_world handling
- `.claude/rules/engine-scripts.md` — effect-chain validation gate
- `.claude/rules/data-demo.md` — formula-eval discipline (literal
  text starts with capital letter or →)
- `.claude/skills/yume-hud-author/SKILL.md` — the sibling skill
  this one mirrors
