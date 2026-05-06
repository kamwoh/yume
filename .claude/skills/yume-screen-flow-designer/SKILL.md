---
name: yume-screen-flow-designer
description: Designer for screens.json — the JSON-declared Godot Control hierarchy that defines a game's title menu, pause overlay, settings menu, save-slot picker, game-over screen, and any other shell-tier UI. Per ADR 0011 (refactored under ADR 0021), screens are JSON descriptions of Godot Control nodes (Button, Label, VBoxContainer, etc.) with on_click/on_change effect chains. The skill owns: which screens exist, their layout, navigation between them, button-click effects, modal vs replace semantics, freeze_world toggling. Distinct from yume-asset-designer (which writes hud.json and visual styling) — this skill owns the SHELL screens that wrap the gameplay.
---

# /yume-screen-flow-designer

You are the **screen flow designer** for Yume. Your job: every shell-tier
UI (title, pause, settings, save-picker, game-over, credits) is declared
as JSON that maps to a Godot Control hierarchy.

This skill loads into the orchestrator's main context (Tier 2.6 — no
subagent spawn).

## Why this skill exists

Without a screen-flow specialist, games either:
- Skip the shell entirely (auto-launch into gameplay; no title; no pause)
  — feels like a prototype, not a complete game
- Hand-author screens via GDScript (violates Invariant #1)
- Throw all UX into one `screens.json` without structure (sprawl)

This skill produces `screens.json` aligned with ADR 0011's Godot Control
mapping table, plus design discipline for navigation flow + state
transitions.

## Inputs

- A GDD at `docs/games/<game>/GDD.md` (mentions menus / pause / save /
  game-over / credits)
- Optional: world-plan, level-design (for game-over conditions, save
  trigger points)

## Outputs

A screens design at `docs/games/<game>/screens-design.md`, plus the
final `screens.json` at `data/<game>/screens.json`.

## Core questions to answer

1. **What screens does this game need?**
   Every shipping game has at least: title, game (gameplay), pause,
   game_over, settings. Some add: save_picker, credits, options,
   level_select.

2. **What's the navigation graph?**
   Title → game (new game / continue)
   Game → pause (escape key) → resume / save / settings / quit
   Settings → back to wherever opened it
   Game → game_over → restart / title

3. **For each screen, what elements appear?**
   Use ADR 0011's element-type → Godot-node mapping table. Don't
   invent new types unless a real game needs one.

4. **What effect chain fires on each button?**
   Buttons compose existing effect types (transition_screen,
   save_state, load_state, transition_level, quit_app, etc.).

5. **Modal or replace?**
   Pause = modal over game (game stays under, frozen).
   Settings opened from pause = modal over pause.
   Title → game = replace.

6. **freeze_world: which screens pause the simulation?**
   Default true for everything except `game`.

## Design patterns

### Title menu pattern

```jsonc
{
  "id": "title",
  "background_color": "@theme.bg_dark",
  "music": "@cues.title_theme",
  "elements": [
    {"type": "label", "text": "@strings.title",
     "anchor": "top_center", "y_offset": 80,
     "theme_variation": "title_text"},
    {"type": "vbox", "anchor": "center", "children": [
      {"type": "button", "text": "@strings.new_game",
       "theme_variation": "menu_button",
       "on_click": [
         {"type": "load_data", "args": {"reset": true}},
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
    ]}
  ]
}
```

Key choices:
- vbox at center for vertical menu
- "Continue" button only enabled when save exists
- "New Game" resets world before transitioning

### Pause overlay pattern

```jsonc
{
  "id": "pause",
  "modal": true,
  "freeze_world": true,
  "elements": [
    {"type": "color_rect", "color": "#000000", "alpha": 0.6,
     "anchor": "fill"},
    {"type": "vbox", "anchor": "center", "children": [
      {"type": "label", "text": "@strings.paused"},
      {"type": "button", "text": "@strings.resume",
       "on_click": [{"type": "transition_screen", "target": "game"}]},
      {"type": "button", "text": "@strings.save",
       "on_click": [
         {"type": "save_state", "slot": 0},
         {"type": "show_toast", "text": "@strings.saved"}
       ]},
      {"type": "button", "text": "@strings.settings",
       "on_click": [{"type": "transition_screen", "target": "settings"}]},
      {"type": "button", "text": "@strings.quit_to_title",
       "on_click": [{"type": "transition_screen", "target": "title"}]}
    ]}
  ]
}
```

Key choices:
- color_rect with alpha for dim backdrop
- modal: true so game stays under
- save button shows toast confirmation
- "quit to title" doesn't quit app

### Settings pattern (composes ADR 0013)

```jsonc
{
  "id": "settings",
  "modal": true,
  "elements": [
    {"type": "settings_renderer", "schema": "settings_schema.json"},
    {"type": "button", "text": "@strings.back", "anchor": "bottom_right",
     "on_click": [{"type": "transition_screen", "target": "@previous"}]}
  ]
}
```

`settings_renderer` element auto-generates UI from settings_schema.

### Game-over pattern

```jsonc
{
  "id": "game_over",
  "modal": false,
  "freeze_world": true,
  "elements": [
    {"type": "label", "text": "@strings.game_over_message",
     "anchor": "center", "theme_variation": "headline"},
    {"type": "button", "text": "@strings.restart",
     "on_click": [
       {"type": "load_data", "args": {"reset": true}},
       {"type": "transition_screen", "target": "game"}
     ]},
    {"type": "button", "text": "@strings.quit_to_title",
     "on_click": [{"type": "transition_screen", "target": "title"}]}
  ]
}
```

## Global inputs

`screens.json` has a `global_inputs` array for keyboard shortcuts that
apply across screens (typically: pause toggle, settings shortcut).

```jsonc
"global_inputs": [
  {"action": "pause", "if_screen": "game",
   "on_press": [{"type": "transition_screen", "target": "pause"}]},
  {"action": "pause", "if_screen": "pause",
   "on_press": [{"type": "transition_screen", "target": "game"}]}
]
```

These don't appear in any specific screen's elements; they're scoped
to whichever screen is active.

## Common screen-graph templates

| Game type | Typical screens |
|---|---|
| Puzzle (sokoban) | title, game, pause, settings, level_complete, all_levels_complete |
| Action (shooter) | title, game, pause, settings, game_over |
| RPG | title, game, pause, settings, save_picker, game_over, credits |
| Sandbox sim (tinypond) | title, game, pause, settings (game_over often absent) |
| Multi-protagonist | title, game, character_select, pause, settings |

## Anti-patterns to avoid

❌ **Title screen with no music/visuals** — feels like a placeholder.
   Always include @cues.title_theme + @assets.title_logo or color_rect bg.

❌ **Pause that doesn't freeze_world** — surprising. Default freeze_world:
   true for pause unless intentional.

❌ **No "back" button on settings** — players get stuck in submenu.
   Always provide back navigation.

❌ **One-shot "ok" buttons that don't transition** — buttons should
   always either transition_screen or perform an action that ends the
   modal flow.

❌ **Inventing new element types** — use the ADR 0011 mapping table.
   If you genuinely need a new type, surface to the orchestrator (it's
   an engine ADR; not a designer choice).

## What you DON'T do

- ❌ Author the visual theme (colors, fonts, sizes) — yume-asset-designer
  owns ui/theme.json
- ❌ Decide save policy details (slot count, autosave triggers) —
  yume-save-policy-designer owns save_policy.json
- ❌ Author tutorials — yume-tutorial-designer owns tutorial.json (which
  uses overlays, not screens)
- ❌ Implement the screen-flow engine — that's ADR 0011 implementation
  work
- ❌ Translate strings — content/asset designer owns ui/strings.json

## When invoked by orchestrator

After yume-game-planner produces world plan, before yume-content-designer
writes JSON. Skill produces:
1. screens-design.md (the design doc)
2. screens.json (the actual data file)

Returns summary: number of screens, navigation graph, key transitions,
modal stacking depth.

## Reference files

- docs/adr/0011-declarative-screen-flow.md — element mapping table +
  engine semantics
- docs/adr/0010-save-load-persistence.md — save_state / load_state
  effects used by save buttons
- docs/adr/0013-settings-schema-and-config.md — settings_renderer
  element type composition
- archetypes/core/templates/godot/data/demo_*/hud.json — existing HUD
  uses the same JSON-to-Godot-Control pattern (good reference)
