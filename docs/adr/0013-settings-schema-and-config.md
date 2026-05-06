# ADR 0013 — Settings schema + config persistence

_Date: 2026-05-06_
_Status: **accepted (conditions resolved 2026-05-06; ADR 0011 refactor landed)**_

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

## Tech-director review (2026-05-06, post-ADR-0021 framing)

### Invariant checks

| Invariant | Status | Notes |
|---|---|---|
| #1 JSON-only content channel | ✓ | settings_schema.json is content |
| #2 No semantic effect types | ✓ | apply_setting and friends are mechanical |
| #8 Engine = primitives + interpreter | ⚠ | persistence path conflicts with ADR 0021 — see below |

### Re-evaluation under ADR 0021

This ADR explicitly mentions Godot's `AudioServer` + `InputMap` for
the apply-setting effects. Good. But the PERSISTENCE path
(`user://config.json` via custom JSON I/O) reimplements what Godot's
**`ConfigFile`** is literally designed for.

`ConfigFile` is the standard Godot pattern for this exact use case:
- Section + key-value structure (perfect fit for settings categories)
- Cross-session persistence at `user://`
- `.ini`-style format that's human-editable + standard
- `ConfigFile.load()` / `ConfigFile.save()` are the API

Custom JSON I/O for settings is reimplementation per ADR 0021. Using
ConfigFile is the right move.

(Note: ADR 0010's save data is different — that's nested entity
state, not flat key-value. JSON is correct there. But settings ARE
flat key-value.)

### Required refactor

1. **Replace `user://config.json` with `user://settings.cfg` via
   ConfigFile.**
   - Persistence: `ConfigFile.set_value("audio", "master_volume", 0.7)`
   - Load: `ConfigFile.get_value("audio", "master_volume", 0.7)` —
     last arg is default
   - File: `user://settings.cfg` (`.cfg` is Godot's convention for
     ConfigFile)

2. **Settings UI rendering composes with ADR 0011's refactor.**
   The `settings_renderer` element in ADR 0011's screens.json
   should iterate the schema + generate Godot Control hierarchy
   (Slider for slider type, CheckBox for bool, OptionButton for
   enum, special handler for key_binding).

3. **`apply_setting` effect dispatches to existing engine effects.**
   The schema's `apply` block can use existing primitives:
   - `state_set target=world` (already exists)
   - `set_audio_bus_volume` (new — wraps AudioServer.set_bus_volume_db)
   - `set_input_mapping` (new — wraps InputMap manipulation)

   Only the AudioServer + InputMap wrappers are NEW Yume effects.
   Both are thin Godot exposures, ADR-0021-compliant.

### Concerns

1. **Schema validation**. settings_schema.json must validate at
   load — types are valid (slider/bool/enum/key_binding); `min ≤
   default ≤ max` for sliders; enum options non-empty. Engine
   errors at load if invalid.

2. **Migration when schema changes**. If author adds a new setting
   to the schema, existing user configs won't have it. Engine must
   apply schema default. Already handled by ConfigFile's default-
   value pattern. ✓

3. **Reset to defaults**. Settings menu should have a "Reset"
   button. Implementation: iterate schema; for each setting, run
   `apply` with the default value. Effect chain.

4. **Per-actor key bindings**. Per ADR 0016 (multi-actor),
   different actors have different input devices. Settings should
   distinguish "global key bindings" vs "per-actor remap." Current
   ADR doesn't make this distinction. Recommend: settings_schema
   for global; per-actor maps stay in actors.json. Document the
   split.

5. **Localization of setting labels**. `@strings.cat_audio` etc.
   resolve at render time. ✓ already in plan.

### Verdict

**Status: accept-with-conditions.**

Conditions:

1. **Use Godot's `ConfigFile` for persistence**, not custom JSON.
   Replace `user://config.json` with `user://settings.cfg`.
2. **Settings UI rendering composes with ADR 0011's refactor**
   (settings_renderer element in screens.json).
3. **Spec the new effect types** (`set_audio_bus_volume`,
   `set_input_mapping`) as thin Godot wrappers; document in
   api-manifest.
4. **Spec global vs per-actor key remap** distinction per ADR 0016
   composition.
5. **Schema validation at load** with structured errors.
6. **Test plan**: settings persist across session restart;
   per-effect apply runs correctly; reset-to-defaults works.

After conditions resolved, this ADR is a clean composition: JSON
declares the schema; Godot's ConfigFile + AudioServer + InputMap +
Control hierarchy do the work.

### Tier framing

T5 (gameplay experience / shell layer) — yes. Settings are platform-
level UX.

### Cross-ADR observation: Godot UI exposure capability

User asked whether ADRs 0010-0013 collectively represent a "Godot
UI exposure capability" that should land as ADR 0029. After review:

**Answer: ADR 0011 IS that foundational capability** (after
refactor). Its "JSON declares Godot Control hierarchy + button
clicks dispatch effect chains" pattern IS the Godot UI exposure.

ADR 0012 (overlays) and ADR 0013 (settings UI) compose with it —
they reuse the same JSON-to-Control mechanism.

ADR 0010 (save/load) is separate — it's data-layer infrastructure
that uses Godot's FileAccess + JSON, not UI.

So no new ADR 0029 needed. The split is:
- ADR 0010: data-layer infrastructure (save/load + Godot FileAccess)
- ADR 0011 (refactored): UI capability — JSON-to-Godot-Control
  primitive (foundational)
- ADR 0012: composes 0011 for overlays
- ADR 0013: composes 0011 for settings UI + uses ConfigFile

This is the cleanest organization. Land 0011 first (refactored);
0012 + 0013 follow naturally.

## Conditions resolved (2026-05-06)

ADR 0011 refactor landed (status: accepted). This ADR's conditions
addressed:

### 1. Use Godot's ConfigFile — RESOLVED

Replace `user://config.json` with `user://settings.cfg` via Godot's
`ConfigFile` class.

```gdscript
# Persistence
var cfg := ConfigFile.new()
cfg.load("user://settings.cfg")  # OK if doesn't exist
cfg.set_value("audio", "master_volume", 0.7)
cfg.save("user://settings.cfg")

# Load with default
var v = cfg.get_value("audio", "master_volume", 0.7)
```

Section name = setting category id; key = setting key (without the
category prefix). The schema-to-section mapping is automatic.

### 2. UI composes with ADR 0011 — RESOLVED

The `settings_renderer` element type (added to ADR 0011's element
mapping table) reads `settings_schema.json` and generates Godot
Control hierarchy via the factory:

| Setting type | Generated Control |
|---|---|
| slider | HSlider with Label (name) + SpinBox (current value) |
| bool | CheckBox |
| enum | OptionButton populated from `options` |
| key_binding | Button with text = current binding; clicking
  enters "press a key" mode |

All instantiated via control_factory; styled via ui/theme.json.
Settings menu is just another screen (typically modal over title or
pause).

### 3. New effect types spec'd — RESOLVED

Two new mechanical effect types (thin Godot wrappers):

```jsonc
{"type": "set_audio_bus_volume", "bus": "Master", "linear": 0.7}
// Maps to AudioServer.set_bus_volume_db(bus_idx, linear_to_db(linear))

{"type": "set_input_mapping", "action": "move_north", "key": "W"}
// Maps to InputMap.action_erase_events + InputMap.action_add_event
// with new InputEventKey constructed from key string
```

Both are bounded; ADR 0021 compliant (thin Godot exposure).

Documented in api-manifest.json (CI auto-detects).

### 4. Global vs per-actor key remap — SPEC'D

Per ADR 0016 (multi-actor) composition:

- **Global key remap** (this ADR's settings) → modifies project-level
  InputMap. Single-player games use only this.
- **Per-actor input map** (ADR 0016's actors.json) → unchanged by
  settings; per-actor `input_actions_press` / `input_actions_hold`
  declare WHICH actions exist; settings remaps the keyboard binding
  PER PLAYER.

For multi-protag games (e.g. P1 keyboard + P2 gamepad), each
actor's `input_device` field in actors.json picks the device; the
GLOBAL InputMap controls the keyboard mapping.

If a future game needs PER-ACTOR keyboard remap (P1 uses WASD,
P2 uses IJKL on same keyboard), that's a future ADR — out of scope
for this one.

### 5. Schema validation — SPEC'D

At settings_schema.json load:

- Each setting must have: `key`, `type`, `default`
- For `slider`: `min` ≤ `default` ≤ `max`; `step > 0` if specified
- For `enum`: `options` is non-empty array; `default` must be in `options`
- For `key_binding`: `default` is a valid Godot key string
- Engine errors at load if any check fails (structured EngineError)

### 6. Test plan — SPEC'D

1. **Settings persist across session**: change master_volume to 0.3;
   exit; restart; settings.cfg has master_volume=0.3; engine applies
   on boot.
2. **Apply runs on change**: change music_volume; AudioServer's
   Music bus volume_db reflects new value.
3. **Reset to defaults**: button calls reset; all settings return
   to schema defaults; settings.cfg updated.
4. **Schema validation**: malformed schema (slider with min > max)
   fails to load with structured error.
5. **Default applied for missing settings**: schema has new setting
   not in user's existing settings.cfg; default applied; written
   back on next save.

## Final verdict

**Status: accepted.**

All conditions resolved. Implementation gated on:
- ADR 0011 implementation landing (provides control_factory +
  settings_renderer support)
- Engine work: `settings_manager.gd` module +
  set_audio_bus_volume / set_input_mapping effects

Independent of ADRs 0014-0020.
