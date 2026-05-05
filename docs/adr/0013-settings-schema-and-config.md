# ADR 0013 — Settings schema + config persistence

_Date: 2026-05-06_
_Status: **proposed**_

## Context

A "complete game" exposes player-tunable settings: volume, key
bindings, video options, accessibility (color-blind mode, reduced
motion, font scaling). Currently Yume has no such surface; per-
project hardcoded values bake in choices the player can't change.

Settings have specific requirements:

1. **Persistence across sessions** — distinct from save/load
   (per-game progress); settings are global per-machine.
2. **Per-game customization** — different games surface different
   settings (a TD might add "auto-rotate camera"; a sokoban doesn't).
3. **Schema-driven UI** — the settings menu auto-renders from the
   schema (no per-game GDScript).
4. **Runtime effect** — changing a setting updates engine state
   (volume change → audio bus level changes immediately).
5. **Accessibility-first** — color-blind palettes + reduced-motion +
   font scaling must be tracked AND consumed by renderer.

Per project constraint: schema in JSON, current values in JSON,
runtime UI rendered from schema.

## Decision

Add a **schema-driven settings layer**: each game ships a
`settings_schema.json` declaring categories + settings. Engine
maintains current values in `user://config.json` (cross-session
persistence per-machine). The settings UI is rendered from the
schema via the screen-flow interpreter (ADR 0011). Setting changes
are pushed into `world_state.config_*` so any rule or renderer can
read them.

### File layout

```
data/<game>/
├── settings_schema.json   # what settings exist, types, defaults
└── ... (existing)

user://config.json
{
  "master_volume": 0.7,
  "music_volume": 0.5,
  "color_blind": "off",
  ...
}
```

### `settings_schema.json` schema

```jsonc
{
  "_comment": "Sokoban settings — minimal initial set.",

  "categories": [
    {
      "id": "audio",
      "label": "@strings.cat_audio",
      "settings": [
        {"key": "master_volume",
         "type": "slider",
         "label": "@strings.set_master_volume",
         "min": 0.0, "max": 1.0, "step": 0.05, "default": 0.7,
         "apply": [
           {"type": "set_audio_bus_volume", "bus": "Master", "linear": "value"}
         ]},
        {"key": "music_volume",
         "type": "slider",
         "label": "@strings.set_music_volume",
         "min": 0.0, "max": 1.0, "step": 0.05, "default": 0.5,
         "apply": [
           {"type": "set_audio_bus_volume", "bus": "Music", "linear": "value"}
         ]}
      ]
    },
    {
      "id": "controls",
      "label": "@strings.cat_controls",
      "settings": [
        {"key": "remap.move_north",
         "type": "key_binding",
         "label": "@strings.set_move_north",
         "default": "W",
         "apply": [
           {"type": "set_input_mapping", "action": "move_north", "key": "value"}
         ]}
      ]
    },
    {
      "id": "accessibility",
      "label": "@strings.cat_accessibility",
      "settings": [
        {"key": "color_blind",
         "type": "enum",
         "label": "@strings.set_color_blind",
         "options": ["off", "deuteranopia", "protanopia", "tritanopia"],
         "default": "off",
         "apply": [
           {"type": "state_set", "target": "world",
            "field": "color_blind", "value": "value"}
         ]},
        {"key": "reduced_motion",
         "type": "bool",
         "label": "@strings.set_reduced_motion",
         "default": false,
         "apply": [
           {"type": "state_set", "target": "world",
            "field": "reduced_motion", "value": "value"}
         ]},
        {"key": "font_scale",
         "type": "slider",
         "label": "@strings.set_font_scale",
         "min": 0.8, "max": 2.0, "step": 0.1, "default": 1.0,
         "apply": [
           {"type": "state_set", "target": "world",
            "field": "font_scale", "value": "value"}
         ]}
      ]
    }
  ]
}
```

### Setting types (initial set)

| Type | Value | UI |
|---|---|---|
| `slider` | float in `[min, max]` | drag-slider |
| `bool` | true / false | checkbox |
| `enum` | one of `options` | dropdown |
| `key_binding` | physical key (`"W"`, `"Space"`) | press-to-bind |

Future additions when needed: `int_slider`, `text_input`, `color`.

### `apply` blocks

Each setting has an `apply` effect list. When the setting changes,
the engine runs these effects. The special token `"value"` in the
effect dict resolves to the new setting value.

Engine effect types used:
- `state_set target=world` — pushes value into world_state for rules
  / renderer to read
- `set_audio_bus_volume` — Godot AudioServer integration
- `set_input_mapping` — Godot InputMap integration

### Runtime flow

1. **Boot**: engine reads `user://config.json`. If missing or any
   setting unset, applies schema defaults. Each setting's `apply`
   block runs.
2. **Player opens settings menu** (a screen per ADR 0011 with
   `settings_renderer` element): UI rendered from schema; current
   values read from world_state.
3. **Player changes a setting**: engine writes new value to
   `user://config.json` AND runs the `apply` block AND mirrors into
   `world_state`.
4. **Reset to defaults**: button in settings UI runs each setting's
   defaults through `apply`.

### Engine work

1. `scripts/engine/settings_manager.gd` — new module:
   - Loads `settings_schema.json` + `user://config.json` at boot
   - Applies defaults to unset values
   - Provides `get(key)` / `set(key, value)` API
   - Persists changes to `user://config.json` on `set`

2. `world.gd` integration:
   - At boot (after `load_data`), invoke
     `settings_manager.apply_all()` so every setting's `apply` block
     runs. World_state mirrors all setting values via `state_set
     target=world`.

3. New effect types in `effect_apply.gd`:
   - `set_audio_bus_volume` — Godot AudioServer integration
   - `set_input_mapping` — Godot InputMap integration
   - (existing) `state_set target=world` — already supported, used
     for pushing settings into world bindings

4. `screen_flow.gd` (ADR 0011) recognizes `settings_renderer` element
   type — auto-renders the schema as a 2-column UI (label + control
   per setting, grouped by category).

5. Renderer integration:
   - `world_state.color_blind` read by 2D + 3D renderer; if non-
     "off", apply palette swap on color values
   - `world_state.reduced_motion` read by entity_sprite_2d.gd;
     skips shake / particle / sparkle effects
   - `world_state.font_scale` read by HUD label rendering

### Backward compat

Existing demos work unchanged. `settings_schema.json` is OPTIONAL.
Without it, no settings menu is shown (ADR 0011's
`settings_renderer` element renders empty), and no `apply` blocks
fire (defaults take effect from each setting's hard-coded fallback in
the engine — for now: master_volume=1.0, all flags off).

## Consequences

**Enables:**
- Complete-game settings UX
- Accessibility surface (color-blind / reduced-motion / font-scale)
- Per-game extension (TD games can add "auto-buy ammo"; sokoban
  doesn't)
- Settings persist across sessions (cross-session per-machine)
- Settings expose to rules: a renderer can read
  `world.reduced_motion` and skip particles

**Constrains:**
- Settings are flat key-value (no nested config). Sufficient for
  shipped games' needs; restructure if a game needs tree-shaped
  config.
- `user://config.json` is per-machine, not per-user. Cloud sync
  out of scope.
- Apply blocks run synchronously; long-running setting changes
  (e.g. "rebuild lighting") aren't supported. Add async if needed.

**Doesn't enable:**
- Per-save settings (e.g. game-difficulty). Difficulty modes are
  per-save; that's variants (ADR 0009 Phase 2d), not settings.
- Engine-wide settings shared across games. Each game has its own
  schema; if multiple games share a launcher, they each need their
  own config.

## Alternatives considered

### A. Hardcode settings in GDScript

Reject: violates Invariant #1.

### B. Use Godot's `ProjectSettings` / `ConfigFile`

ConfigFile is fine for the on-disk format (in fact we may use it
internally). The DECLARATION (schema, defaults, UI) must be JSON for
LLM-generability + cross-game customization.

### C. Settings as world_state keys with no schema

Could just write to world_state directly and let games hardcode menu
buttons. Misses: type validation (slider min/max), persistence
(world_state resets per session), schema-driven UI rendering.

### D. One unified config primitive: variants + settings + saves all
share the same shape

Tempting. Rejected: variants apply at LOAD time and don't change
during play; settings change at runtime; saves are full state
snapshots. Different lifecycles. Forcing one shape would make all
three awkward.

## References

- Invariant #1 (JSON-only content channel)
- ADR 0009 Phase 2d — variants (different concern: per-save game-
  difficulty)
- ADR 0011 — screens host the settings menu
- Godot 4.6 AudioServer + InputMap APIs (verify in
  `docs/engine-reference/godot/`)
