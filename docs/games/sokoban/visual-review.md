# Sokoban — visual review (round 1)

_Date: 2026-05-04_
_Reviewer: yume-visual-designer_
_Capture: captures/sokoban_l1_v0.1.png_
_GDD: docs/games/sokoban/GDD.md_
_Theme target: "warm parchment + dark oak + brass accents" / "quiet sorter in an old document archive" / Submission aesthetic_

## Verdict

**revise** — 0 blockers, 2 majors, 3 minors, 2 ok. The walls + box + goal nail the oak/brass palette; everything else (player, floor, scene bg) is theme-neutral or theme-contradicting. Five concrete fixes ordered below.

## Per-axis findings

### 1. Readability — **ok**

All four entity types (player, box, goal, walls) are individually distinguishable in <1 second. Game state is parseable at a glance: "1 box, 1 goal, push east." HUD text is legible against the dark bg. Walls render as a single solid border block rather than 5 distinct shelving units (the touching tile_32 sprites visually merge), but this reads acceptably as "the chamber wall" rather than confusing.

### 2. Contrast — **minor**

Player (blue, #3aa8e8) has strong contrast against dark bg — pops appropriately as primary focal point. Walls (dark brown #3a2a18) recede correctly behind the play area. Box (#a07040) and goal (#c0a040) are both warm earth-tones in similar hue and saturation — at the small goal radius (8px) they're close enough to confuse momentarily. Goal needs to differentiate as brass (more yellow-saturated) vs the box's oak.

### 3. Color harmony — **major**

GDD palette: "warm parchment + dark oak + brass."

| Element | Color | Theme match |
|---|---|---|
| Walls | #3a2a18 dark brown | ✓ oak |
| Box | #a07040 medium brown | ✓ oak crate |
| Goal | #c0a040 muted gold | ✓ brass (could be more saturated) |
| Player | #3aa8e8 cyan-blue | ✗ off-theme — cool, not warm |
| Inner floor | gray (scene bg showing through) | ✗ neutral, not parchment |
| Scene bg | dark gray | ✗ neutral, not warm-archive |
| HUD text | white | △ neutral; could be parchment-cream |

The blue player is the single loudest off-palette element. Out of 7 visible colors, 3 are theme-neutral and 1 actively breaks palette. Walls + box + goal carry the theme; player + floor + bg work against it.

### 4. Layout balance — **minor**

5×5 grid is centered with generous negative space — supports calm aesthetic well. PBG horizontally aligned on row 2 forms a "band" that the eye reads as one element, not three. For level 1 (a 1-move solution showing the verb) this band-feel is actually appropriate — it teaches "push the box from player to goal" left-to-right at a glance. But three of the five grid rows are empty gray, which feels stark rather than calm. A faint floor-tile texture (or any decoration) in the empty cells would convert "stark" into "deliberate negative space." Marginal — wouldn't fix in isolation but pairs with the floor-color fix.

### 5. Visual hierarchy — **ok**

Eye lands on player (blue circle, biggest, most-saturated) first → moves to box (brown square, second-most-prominent) → settles on goal (small yellow). Walls correctly recede. The hierarchy reads exactly as the gameplay intent: "you (player) push this thing (box) onto that thing (goal)." HUD takes peripheral position. Hierarchy is well-ordered.

### 6. HUD integration — **minor**

HUD doesn't occlude play area, info density is minimal (matches calm aesthetic), font is legible. Two issues:
- Label reads `Level: level_1` — the raw level ID is leaking through to the UI. GDD spec says `Level: <N> / 8`. Either the engine should render the level name as a number, or the HUD label format should mask it.
- HUD text is pure white. GDD's "warm parchment palette" suggests a cream-tone (#f0e0c0) would integrate the HUD into the archive theme without sacrificing legibility.

### 7. Theme coherence — **major**

Walls + box + goal succeed. The rest of the frame doesn't lean into "old archive" at all:
- Background reads as "neutral game bg," not "candle-lit library."
- Inner play area (gray) reads as "empty arena," not "parchment workspace."
- Player (blue) reads as "generic indie game player," not "quiet archive sorter."

The fiction is "you are a person in an archive sorting crates onto catalog markers." Currently visible: a chamber, three shapes, no archive flavor on the bg/floor/player. The theme is announced by the walls and undermined by everything around them.

## Concrete revision requests

Ordered by impact. All philosophy-preserving (LLM-authorable JSON edits, no humans needed).

### 1. Recolor player from cool blue to warm sepia (severity: **major**)

- **File**: `archetypes/core/templates/godot/data/demo_sokoban/entities/player.json`
- **Edit**: `"params": {"radius": 12, "color": "#3aa8e8"}` → `"params": {"radius": 12, "color": "#c89058"}`
- **Why**: Axis 3 + 7. Blue is the loudest off-theme element. Warm sepia-tan (#c89058) is in-palette (parchment-adjacent), still high-contrast against the dark walls + bg, and reads as "person in a warm-toned archive" instead of "generic blue player avatar."

### 2. Add a parchment-cream floor under the play area (severity: **major**)

- **File**: `archetypes/core/templates/godot/data/demo_sokoban/entities/floor_tile.json` *(new file)*
- **New def**: `floor_tile` — tag `["floor", "decoration"]`, visual `{"shape": "tile_32", "params": {"color": "#e8d8b0"}}` (parchment cream)
- **File**: `archetypes/core/templates/godot/data/demo_sokoban/levels/level_1/entities.json`
- **Edit**: add 9 floor_tile instances at the inner cells (1,1)-(3,3) — positions [48,48], [80,48], [112,48], [48,80], [80,80], [112,80], [48,112], [80,112], [112,112]
- **Why**: Axis 3 + 4 + 7. Inner play area currently shows the dark scene bg. A parchment-cream floor (a) makes the chamber read as "archive workspace" not "void," (b) fills the empty grid cells without adding mechanical clutter, (c) provides a warm light-tone that contrasts against dark oak walls — visually anchors the chamber.

### 3. Brighter brass goal + slightly larger (severity: **minor**)

- **File**: `archetypes/core/templates/godot/data/demo_sokoban/entities/goal.json`
- **Edit**: `"params": {"radius": 8, "color": "#c0a040"}` → `"params": {"radius": 10, "color": "#dab048"}`
- **Why**: Axis 2. Goal-vs-box are both earth-tones; brighter brass (more yellow-saturated, less brown) makes the goal pop as a "brass catalog marker" while the box reads as "oak crate." Radius 10 (slightly larger than r=8) makes the focal point more readable without dominating.

### 4. Fix HUD level label leaking raw ID (severity: **minor**)

- **File**: `archetypes/core/templates/godot/data/demo_sokoban/progression.json`
- **Edit**: `"levels": ["level_1"]` → `"levels": ["1"]` (or `"levels": ["I"]` for roman-numeral archive vibe)
- **File**: `archetypes/core/templates/godot/data/demo_sokoban/levels/level_1/` directory rename to `levels/1/` (keep file contents)
- **Alternative if rename is risky**: keep "level_1" as the folder name but add display-name mapping in HUD format string (would need engine support — defer).
- **Why**: Axis 6. `Level: level_1` reads as debug output. `Level: 1` (or `Level: I`) reads as finished UI. The cleanest fix is renaming the level identifier itself.

### 5. Warm the HUD text to parchment cream (severity: **minor**)

- **File**: `archetypes/core/templates/godot/data/demo_sokoban/hud.json`
- **Edit**: HUD labels currently use default white. Add a `"color": "#f0e0c0"` field to each label element to tint them parchment.
- *Implementation note*: requires verifying the HUD config's label-element schema supports per-element color override (most label systems do; if not, this is a small content-designer skill recommendation).
- **Why**: Axis 6 + 7. White HUD on dark bg is fine for legibility but reads as "generic UI." Parchment-cream HUD integrates the UI into the theme — the player feels like they're reading a label on parchment, not a HUD.

## Reasoning summary

The chamber's oak walls + brass goal + oak crate succeed beautifully — those three colors carry the GDD's stated palette. The remaining 60% of visible pixels (background, floor, player, HUD) are theme-neutral or theme-contradicting; the loudest is the cool blue player against an otherwise warm intended palette. Top fix is recoloring the player to warm sepia — single one-line edit that resolves the strongest dissonance. Second is adding a parchment floor — converts "empty chamber over void" into "archive workspace" and pairs with fix #1 to land the warm-archive feel in three lines of JSON. Fixes 3-5 are polish. After fixes, expect axes 3 and 7 to drop from major to ok, axes 2/4/6 to stay or improve.

---

## 6-line summary

- **Verdict**: revise (0 blockers, 2 majors, 3 minors)
- **Top fix**: player color — `#3aa8e8` (cool blue) → `#c89058` (warm sepia) — one line, biggest theme impact
- **Second fix**: add parchment-cream floor tiles under the play area — converts "empty void" into "archive workspace"
- **Working well**: walls + box + goal nail the oak palette; visual hierarchy reads correctly; readability is solid
- **Working against the theme**: scene bg is neutral gray, inner floor is bare gray, HUD is bare white — all three want warming toward parchment
- **Next**: orchestrator applies the 5 edits → re-capture → round 2 review (expect to land at accept after fixes 1-2 even if 3-5 deferred)

---

## Round 2 (2026-05-04)

_Capture: captures/sokoban_l1_v0.2.png_
_Reviewer: yume-visual-designer_

### Verdict: **accept with minor notes**

All 5 round-1 revision requests applied. Both round-1 majors resolved. Only minors remain — none blocking.

### Per-axis check (round 2)

| Axis | R1 | R2 | Notes |
|---|---|---|---|
| 1. Readability | ok | ok | Unchanged. All entities distinct. |
| 2. Contrast | minor | ok | Brass goal (#dab048, r=10) now distinct from oak box. |
| 3. Color harmony | **major** | **ok** | RESOLVED. Palette unified: dark oak (walls), sepia (player), oak (box), brass (goal), parchment (floor + HUD text). Only outer scene bg remains cool gray. |
| 4. Layout balance | minor | ok-minor | Floor tiles fill the previously-stark inner cells — converts negative space into "archive workspace." PBG row 2 alignment is fine for level 1. |
| 5. Visual hierarchy | ok | ok-minor | Player + box now closer in hue (both warm earth-tones); player is slightly less prominent than R1. Acceptable — box is the gameplay focal point ("the thing to push") so this is arguably correct. |
| 6. HUD integration | minor | ok | RESOLVED. "Level 1" clean, parchment-tone text integrates into theme. |
| 7. Theme coherence | **major** | **ok** | RESOLVED. Inner frame fully reads as warm archive (parchment + oak + brass + sepia). Outer scene bg gray remains the only off-theme element. |

### What landed

1. ✅ Player recolored #3aa8e8 → #c89058 (sepia, in-palette)
2. ✅ 9 parchment-cream floor_tile instances added under play area
3. ✅ Goal brightened (#c0a040 → #dab048, r 8 → 10)
4. ✅ Level renamed "level_1" → "1"; HUD now reads "Level 1"
5. ✅ HUD label colors set to parchment-cream (#f0e0c0 + #d8c8a0)

### Remaining minor notes (NOT blocking ship)

- Outer scene bg is still default Godot dark-gray (#404040 area). Warming it via scene-config or a backdrop entity would unify the whole frame, but this is a polish-tier fix — doesn't break the archive feel since the chamber clearly dominates the frame.
- Bottom-left controls hint is still default white (the `controls_hint` HUD field uses a separate fixed style, not the parchment label color). Future polish: if engine adds `controls_hint_color`, set it to parchment.

### Reasoning summary

Round-1 review identified 2 majors + 3 minors. Round-2 fixes resolved all 5. The visual frame now successfully delivers the GDD's stated "warm parchment + dark oak + brass" palette across all gameplay-relevant elements. The 2 remaining minor notes are scene-level concerns that don't fit the current entity-JSON edit surface — appropriate for a future round 3 if/when the engine grows scene bg-color config, or for asset-designer to take up.

Skill validation: 5/5 specific edits all landed correctly without collateral damage; round-2 verdict shifted from `revise` → `accept` after one iteration. The visual-designer loop works as designed.
