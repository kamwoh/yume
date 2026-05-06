# ADR 0011 — Declarative screen flow (Godot Control exposure for shell tier)

_Date: 2026-05-06_
_Status: **accepted (refactored 2026-05-06 under ADR 0021 framing)**_

## Context

Currently every Yume scene auto-starts the world: open the .tscn, the
game runs immediately. There is no:

- Title screen
- Main menu
- Pause overlay
- Settings menu
- Game-over / credits screen
- Save-slot picker

These are universal in shipping games. Players expect them. Adding
them ad-hoc per game would mean GDScript per-game, violating
Invariant #1 (JSON-only content channel).

Yume's existing `hud.json` already solves a sibling problem
correctly: JSON declares element specs (label, progress_bar, etc.);
`game_shell.gd` instantiates Godot `Control` nodes from those specs;
binding rules update Control properties from entity state each tick.
This works.

Per ADR 0021 (Yume = JSON layer over Godot + external), the same
pattern should apply to FULL SCREENS (title / pause / settings /
game-over). JSON declares Godot Control hierarchies + which effects
fire on user interaction; engine instantiates the actual Godot
nodes. We don't render UI ourselves — Godot does. We don't handle
clicks ourselves — Godot's `Button.pressed` signal does. We don't
manage focus ourselves — Godot's Control focus chain does.

This ADR is the **foundational shell-tier capability**: a generalized
"JSON declares Godot Control hierarchy" mechanism that ADRs 0012
(overlays) and 0013 (settings UI) compose on top of.

## Decision

Add a **declarative screen-flow layer**: each game ships a
`screens.json` that describes named screens as Godot Control
hierarchies. Engine reads JSON, instantiates a `CanvasLayer` per
screen, populates it with Control nodes from the JSON spec, and
wires user interactions (button clicks, key inputs) to dispatch
Yume effect chains.

This is **JSON-declared Godot UI**, not a Yume-internal UI renderer.
We expose Godot's mature UI; we do not reimplement it.

### File layout

```
data/<game>/
├── screens.json           # screen graph + transitions + UI elements
└── ... (existing files)
```

### `screens.json` schema

```jsonc
{
  "_comment": "Sokoban screen graph: title → game → pause → settings.",
  "starting_screen": "title",

  "screens": [
    {
      "id": "title",
      "background_color": "#2a2418",
      "background_shape": "@assets.title_logo",
      "music": "@cues.title_theme",
      "elements": [
        {"type": "label", "text": "@strings.title",
         "anchor": "top_center", "y_offset": 80, "font_size": 56},
        {"type": "button", "text": "@strings.new_game",
         "anchor": "center", "y_offset": -40, "width": 200,
         "on_click": [
           {"type": "transition_screen", "target": "game"}
         ]},
        {"type": "button", "text": "@strings.continue",
         "enabled_if": "world.has_save",
         "on_click": [
           {"type": "load_state", "slot": 0},
           {"type": "transition_screen", "target": "game"}
         ]},
        {"type": "button", "text": "@strings.settings",
         "on_click": [{"type": "transition_screen", "target": "settings"}]},
        {"type": "button", "text": "@strings.quit",
         "on_click": [{"type": "quit_app"}]}
      ]
    },

    {
      "id": "game",
      "elements": []
      // empty = the world renders normally; HUD overlay rendered as usual
    },

    {
      "id": "pause",
      "modal": true,           // overlays "game" without tearing it down
      "freeze_world": true,    // tick advancement paused
      "background_color": "#000000",
      "background_alpha": 0.7,
      "elements": [
        {"type": "label", "text": "@strings.paused",
         "anchor": "top_center", "y_offset": 80},
        {"type": "button", "text": "@strings.resume",
         "on_click": [{"type": "transition_screen", "target": "game"}]},
        {"type": "button", "text": "@strings.save",
         "on_click": [
           {"type": "save_state", "slot": 0},
           {"type": "show_toast", "text": "@strings.saved", "duration": 2.0}
         ]},
        {"type": "button", "text": "@strings.main_menu",
         "on_click": [{"type": "transition_screen", "target": "title"}]}
      ]
    },

    {
      "id": "settings",
      "modal": true,
      "elements": [
        {"type": "settings_renderer", "schema": "settings_schema.json"}
        // delegates to ADR 0013's settings interpreter
      ]
    }
  ],

  "global_inputs": [
    {"action": "pause", "if_screen": "game",
     "on_press": [{"type": "transition_screen", "target": "pause"}]},
    {"action": "pause", "if_screen": "pause",
     "on_press": [{"type": "transition_screen", "target": "game"}]}
  ]
}
```

### Element type → Godot node mapping

The CORE OF THE REFACTOR. Each JSON element type maps to a Godot
Control class. Engine instantiates the Godot node, sets common
properties (anchor, position, size), applies type-specific properties.

| JSON `type` | Godot node class | Notes |
|---|---|---|
| `label` | `Label` | text resolves @strings.X; size/color from theme |
| `button` | `Button` | text + `pressed` signal → `on_click` effect chain |
| `image` | `TextureRect` | texture loaded from `@assets.X` reference |
| `progress_bar` | `ProgressBar` | binding rules update value (same as hud.json) |
| `vbox` | `VBoxContainer` | recurses on `children` array |
| `hbox` | `HBoxContainer` | recurses on `children` array |
| `margin` | `MarginContainer` | for padding around child |
| `spacer` | `Control` with `custom_minimum_size` | vertical/horizontal gap |
| `slider` | `HSlider` / `VSlider` | for settings sliders (composes ADR 0013) |
| `checkbox` | `CheckBox` | for boolean settings |
| `option_button` | `OptionButton` | for enum settings (dropdown) |
| `text_input` | `LineEdit` | for free text input |
| `key_binding` | custom Control wrapping `Button` | "press a key" UX (ADR 0013) |
| `settings_renderer` | (special) | reads settings_schema.json; generates the element subtree per setting type |
| `entity_world` | `SubViewportContainer` + `SubViewport` | embeds the live world view; used by the `game` screen |
| `color_rect` | `ColorRect` | solid background or modal dim; `color` + `alpha` |

This table is the contract. Adding a new element type = adding a row
+ engine support. Engine never invents UI primitives; it only maps
to Godot nodes that already exist.

### Common properties (apply to all element types)

```jsonc
{
  "type": "...",
  "anchor": "center",          // top_left, top_center, top_right,
                               // center, bottom_left, etc.
  "x_offset": 0,
  "y_offset": 0,
  "width": 200,                // optional; auto if omitted
  "height": 40,                // optional
  "size_flags_h": "fill",      // shrink_begin, shrink_center, shrink_end, fill, expand
  "size_flags_v": "fill",
  "theme_variation": "menu_button",  // optional; references ui/theme.json
  "tooltip": "@strings.X",
  "visible_if": "world.has_save",    // formula; engine applies to .visible
  "enabled_if": "world.has_save"     // formula; engine applies to .disabled
}
```

These map directly to Godot Control properties. No invention.

### New effect types

```jsonc
{"type": "transition_screen", "target": "<screen_id>"}
{"type": "show_toast", "text": "@strings.X", "duration": 2.0}
{"type": "quit_app"}
{"type": "load_data", "args": {"reset": true}}  // re-init world from JSON
```

`save_state` / `load_state` (ADR 0010), `show_overlay` /
`dismiss_overlay` (ADR 0012), `apply_setting` (ADR 0013) compose
naturally with screens.

### World freeze semantics

- `screen.freeze_world: true` (e.g. pause, settings) → engine skips
  `scheduler.tick()` while this screen is active. Renderer still draws
  the world (so pause shows the frozen scene behind the modal). Input
  goes to screen elements only.
- `screen.freeze_world: false` (default for `game`) → world ticks
  normally.
- `screen.modal: true` → screen overlays the previous one rather than
  replacing. Closing the modal returns to the underlay.

### Theme integration

Screens (and HUD) styling lives in `ui/theme.json` (per-game,
optional). Engine converts to a Godot `Theme` resource at load and
applies to all instantiated Controls.

```jsonc
// ui/theme.json
{
  "_comment": "Visual theme for all UI Controls in this game.",
  "default_font_size": 18,
  "colors": {
    "background": "#2a2418",
    "primary": "#dab048",
    "secondary": "#a07040"
  },
  "variations": {
    "menu_button": {
      "font_size": 22,
      "min_size": [200, 50],
      "color_normal": "#dab048",
      "color_hover": "#fdd068"
    },
    "tutorial_overlay": { ... }
  }
}
```

Engine generates a Godot `Theme` resource: each variation becomes a
type-variation that elements reference via `theme_variation`. This
exposes Godot's existing Theme system; doesn't reinvent.

### How user interaction → effect chains

The link between Godot's signal system and Yume's effect pipeline:

1. JSON declares `{"type": "button", "on_click": [<effect list>]}`
2. Engine instantiates `Button` node, sets text, adds to scene
3. Engine connects `button.pressed` to a Callable that:
   - Builds a context dict from current screen state
   - Iterates the on_click effect list
   - Dispatches each effect via existing `effect_apply.apply()`
4. Effects flush at end-of-tick like any other effect

Same pattern works for:
- `LineEdit.text_submitted` → on_submit effect chain
- `HSlider.value_changed` → on_change effect chain (with new value
  in context)
- `CheckBox.toggled` → on_toggle effect chain

The Godot signal IS the input event. Yume's effect pipeline IS the
response. Engine glues them.

### Engine work

1. `scripts/engine/screen_flow.gd` — new module:
   - Reads `screens.json` at world load
   - Maintains `world.current_screen` (string state)
   - Listens for `transition_screen` effects and rebuilds the active
     screen's Control subtree
   - Maintains modal stack (Array of screen ids)

2. `scripts/engine/control_factory.gd` — new module:
   - Maps JSON element specs to Godot Control instances per the
     mapping table
   - Recursively builds child hierarchies for containers
   - Connects user-interaction signals to effect-chain dispatchers
   - Applies theme variation if specified

3. `game_shell.gd` extended:
   - On startup, if `screens.json` exists → instantiate starting
     screen via control_factory; mount under a top-level CanvasLayer
   - World ticks ONLY when `current_screen.freeze_world == false`
   - Renders screen UI (labels, buttons) above the world view.
   - Routes input through screen's `on_click` for buttons + global
     inputs.

3. New effect types in `effect_apply.gd`:
   `transition_screen`, `show_toast`, `quit_app`, `load_data`.

4. `world.world_state["current_screen"]` exposed as binding.

### Backward compat

Existing demos work unchanged. `screens.json` is OPTIONAL — if
absent, engine auto-launches the world (current behavior). The
"complete game" upgrade is opt-in by adding the file.

## Consequences

**Enables:**
- Title / pause / main-menu architecture with zero per-game GDScript
- Pause = freeze_world + modal overlay. Universal pattern.
- Settings menu (composes with ADR 0013)
- Save-slot UI (composes with ADR 0010)
- Game-over / credits screens are just more screens

**Constrains:**
- Screens are stateless — UI element state (e.g. "which option is
  highlighted") lives in world_state, not the screen. Awkward for
  complex menus but keeps the model coherent.
- No animation between screens in v1. (Fade-in / slide transitions
  are visual polish, not architecture; future ADR or asset-designer
  work.)
- Modal stacking limited to 2 deep in v1 (game → pause → settings).
  Deeper requires explicit modal stack support; defer.

**Doesn't enable:**
- Mouse drag, drag-and-drop, scrollable lists. Add as new element
  types when a game needs them.
- 3D menus (HoloLens-style spatial UI). Not in scope.

## Alternatives considered

### A. Per-game GDScript for menus

Reject: violates Invariant #1. Already shipped one engine without
this discipline; the win is precisely that menus stay JSON.

### B. Use Godot's Control nodes directly via .tscn

Each game would have a per-game .tscn for its menu. Rejects the
"data not scenes" Yume principle. Also makes the menus impossible to
LLM-generate via /yume-design.

### C. Treat screens as Entity-tagged "screen"

Screens-as-entities has the right philosophical shape but creates
churn in the entity dictionary (every screen + every UI element is
an entity). Cleaner to keep them as content config, like `hud.json`.

### D. Single ADR for shell + save + tutorial + settings

We considered one mega-ADR. Each piece IS independent — different
trigger, different consumer skill, different review concern.
Splitting lets tech-director gate them separately.

## References

- Invariant #1 (JSON-only content channel) — `docs/30_framework_primitives.md`
- ADR 0010 (save/load) — composes via `save_state` / `load_state`
  effects on screen buttons
- ADR 0012 (overlays) — tutorial overlays compose with screens
- ADR 0013 (settings) — settings_renderer element delegates to
  settings interpreter
- Existing `hud.json` — provides element types this ADR extends

## Tech-director review (2026-05-06, post-ADR-0021 framing)

### Invariant checks

| Invariant | Status | Notes |
|---|---|---|
| #1 JSON-only content channel | ✓ | screens.json is content |
| #2 No semantic effect types | ✓ | transition_screen / show_toast are mechanical |
| #8 Engine = primitives + interpreter | ⚠⚠ | conflicts with ADR 0021 — see below |

### Major concern: reimplementation under ADR 0021

This ADR was drafted BEFORE ADR 0021 (Yume = JSON layer over Godot +
external) was accepted. Re-reading it under that framing reveals a
problem:

The proposed `screens.json` interpreter essentially **reimplements
menu UI** that Godot already does well:
- `Button` → already a Godot Control
- `Label` → already a Godot Control
- `VBoxContainer`/`HBoxContainer` → already a Godot Control
- Theme + styling → already Godot Theme system
- Focus management, keyboard nav → Godot Control's built-in
- `CanvasLayer` for modals → already a Godot node

Yume's existing HUD already does this correctly: `hud.json` declares
elements; `game_shell.gd` instantiates Godot Control hierarchy from
the JSON. Per ADR 0021, this is the right pattern.

This ADR's text talks about "rendering screen UI" as if Yume engine
has its own UI renderer. It doesn't (and shouldn't, per ADR 0021).
The interpreter should INSTANTIATE Godot Control nodes, not render
text + handle clicks itself.

### Required refactor

The ADR needs to explicitly frame `screens.json` as **a JSON
declaration of Godot Control hierarchies**, not a custom UI renderer.

Specifically:

```jsonc
{"type": "button", "text": "@strings.new_game",
 "on_click": [{"type": "transition_screen", "target": "game"}]}
```

Engine translation:
1. Instantiate Godot `Button` node
2. Set `text` property (resolve `@strings.X` reference)
3. Connect `pressed` signal to a callable that invokes the
   `on_click` effect chain via existing scheduler.queue_input or
   direct effect dispatch
4. Add to current screen's CanvasLayer

Same authoring outcome as the proposed ADR. Different engine work
(node instantiation + signal wiring, NOT custom rendering +
custom click detection).

This is the SAME PATTERN as `hud.json` already uses. Consistent.

### Element type → Godot node mapping

| JSON `type` | Godot node |
|---|---|
| `label` | Label |
| `button` | Button |
| `image` | TextureRect |
| `vbox` | VBoxContainer |
| `hbox` | HBoxContainer |
| `progress_bar` | ProgressBar |
| `spacer` | Control with custom_minimum_size |
| `settings_renderer` | dynamic — generates Control hierarchy from settings_schema |
| `entity_world` | (special — the World subviewport, not a Control) |

This mapping table must be in the ADR. Engine code maps JSON `type`
to Godot constructor; sets common properties (anchor, position,
size); applies type-specific properties.

### Concerns beyond the framing issue

1. **Theme integration**: Godot has a Theme resource for consistent
   styling. ADR doesn't mention it. Should screens.json reference
   a theme file (e.g. `data/<game>/ui/theme.tres` or similar)?
   Or should theme be configurable via `ui/theme.json` that the
   engine converts to a Theme resource? Decide.

2. **Modal stack**: ADR mentions modal: true for pause overlays.
   Implementation: stack CanvasLayers; topmost has input focus.
   Godot's CanvasLayer + Control mouse_filter handles this naturally.

3. **freeze_world semantics**: when current screen has
   freeze_world: true, scheduler.tick() shouldn't run. Implementation:
   game_shell checks current_screen.freeze_world before invoking
   tick(). Trivial.

4. **enabled_if formula evaluation**: button might be disabled
   based on world state (`enabled_if: "world.has_save"`). Engine
   evaluates the formula; sets Button's `disabled` property.

### Verdict

**Status: revise.**

Refactor needed:

1. **Reframe ADR explicitly under ADR 0021**: screens.json is
   "JSON declaration of Godot Control hierarchies that translates
   to live Control nodes at runtime."
2. **Add element-type → Godot-node mapping table** (above).
3. **Spec Theme integration** (likely a separate `ui/theme.json`
   that engine converts to Godot Theme resource).
4. **Spec freeze_world implementation** (game_shell checks before
   tick; mark current screen modal stack).
5. **Spec the on_click → effect chain dispatch** (Button.pressed
   signal → invoke effect list via scheduler).

After refactor, this ADR effectively BECOMES the "Godot UI exposure"
foundational capability — the same pattern hud.json already uses,
applied to full screens. ADRs 0012 (overlays) + 0013 (settings UI)
COMPOSE on top of this primitive.

### Tier framing

User's "T5 gameplay experience / shell layer" classification holds
exactly. Screens are the most visible part of game-shell.

Re-reviewer needed after refactor lands.
