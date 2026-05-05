# ADR 0011 — Declarative screen flow (main menu, pause, settings)

_Date: 2026-05-06_
_Status: **proposed**_

## Context

Currently every Yume scene auto-starts the world: open the .tscn, the
game runs immediately. There is no:

- Title screen
- Main menu
- Pause overlay
- Settings menu
- Game-over / credits screen
- Save-slot picker

These are universal in shipping games. Players expect them. The
engine has no architecture for them — adding them ad-hoc per game
would mean GDScript per-game (violates Invariant #1: JSON-only content
channel).

Per project constraint: ALL shell behavior must be JSON-driven. The
engine ships a screen-flow interpreter; each game declares its menus
in `screens.json`.

## Decision

Add a **declarative screen-flow layer**: each game ships a
`screens.json` that describes named screens, their UI elements, and
the actions taken on element interaction. The HUD interpreter is
extended to render screens declaratively. The world is paused (or
torn down) when the active screen is not the gameplay screen.

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

### Element types (initial set)

- `label` — static or formula-bound text
- `button` — clickable, has `on_click` effect list
- `progress_bar` — already in hud.json; reused
- `image` — sprite from @assets reference
- `spacer` — vertical / horizontal padding
- `vbox` / `hbox` — container with child elements
- `settings_renderer` — delegate to settings schema (ADR 0013)
- `entity_world` — embed the world view (used by `game` screen by default)

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

### Engine work

1. `scripts/engine/screen_flow.gd` — new module; reads `screens.json`,
   maintains `current_screen` state, dispatches input to active
   screen's elements.

2. `game_shell.gd` extended:
   - On startup, if `screens.json` exists → load it, set
     `world.current_screen = starting_screen`. World ticks ONLY when
     `current_screen.freeze_world == false`.
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
