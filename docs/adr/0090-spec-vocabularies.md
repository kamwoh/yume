# ADR 0090 — Spec vocabularies: keys, audio channels, lighting, physics

_Date: 2026-10-18_
_Status: accepted 2026-10-18_

_Implements: ADR 0086 phase 4_

## Context

ADR 0086 makes the JSON a host-neutral spec. Four vocabularies still
take their meaning from Godot:

| Area | Today | Count |
|---|---|---|
| Key names | `"key": "Ctrl"`, parsed by `OS.find_keycode_from_string` | 85 `key` fields |
| Audio buses | `set_audio_bus_volume` with `"bus": "Master"` or `"Music"` | 2 references |
| Lighting and sky | `scene.json` fields. No list and no definitions. | About 60 field names |
| Physics | `body_type`, `collision_layer`, `collision_mask` | 53 `physics` blocks |

The survey of 2026-10-18 found five defects. Each one gave no warning:

1. Sokoban's music volume slider did nothing. Its setting wrote to a
   `Music` bus, but the engine made only `Master`, and music played on
   `Master`. The effect skipped a missing bus.
2. `set_input_mapping` bound a key by its letter (`keycode`), but
   `ui/input.json` bound keys by position (`physical_keycode`). A
   rebound key behaved differently on a non-US layout.
3. Ten scenes set `lighting.ambient.color` and `energy`. The engine
   reads only `color_day`, `color_night`, `energy_day` and
   `energy_night`, so those scenes used the default fill light.
   `compose_shell` wrote the dead fields into each new world.
4. For a sky shader, the engine replaced the `shader_params` values of
   `sky_top_color`, `sky_horizon_color`, `cloud_color` and
   `cloud_shadow_color` on every frame with its own defaults. The
   authored sky colors never showed.
5. One scene set `directional_light.energy`, which the engine does not
   read.

The owner approved option A for each of the four areas on 2026-10-18.

## Decision

Each vocabulary is a closed list in the engine file that uses it. The
validator and the api manifest read the same list. The contract
document (§Spec vocabularies) defines each name. A new name needs an
ADR.

### 1. Key names

`InputKeys` (`io/input_keys.gd`) maps each spec name to a host code:

- `A`–`Z`, `0`–`9`, `F1`–`F12`, `Numpad0`–`Numpad9`
- `Up`, `Down`, `Left`, `Right`
- `Space`, `Enter`, `Escape`, `Tab`, `Shift`, `Ctrl`, `Alt`, `Backspace`
- mouse buttons: `Left`, `Right`, `Middle`, `WheelUp`, `WheelDown`

A key name means a key position on a US keyboard. `ui/input.json` and
`set_input_mapping` both bind by position. The interpreter does not
parse key names with Godot's key table. Error code: `input.unknown_key`.

All 85 key values in content were already on the list. Nothing changed
in content.

### 2. Audio channels

`AudioChannels` (`io/audio_channels.gd`) holds three channels: `master`,
`music` and `sfx`. The engine makes a bus for each at startup. Music
plays on `music`, and sound cues play on `sfx`. Both feed `master`.
Error code: `audio.unknown_channel`.

Sokoban's two references changed to `master` and `music`.

### 3. Lighting and sky fields

`LightingDirector.FIELDS` lists the fields of each `lighting` block and
of the top-level `render` block. The contract document defines each
field by what the player sees. The exact look is host-defined. At load,
the engine reports each unknown field (`scene.unknown_field`).

Three blocks are host hints, which an interpreter may ignore: `render`,
`directional_light.shadow` and `reflection_probes`.

Two fixes come with the list:

- For a sky shader color, the day value is the `_day` field, then the
  uniform's value in `shader_params`, then the default. Before, the
  default won over `shader_params` (defect 4).
- `compose_shell` writes `ambient.color_day` and `energy_day`. A
  one-time script renamed the dead fields in 9 local scenes:
  `ambient.color` to `color_day`, `ambient.energy` to `energy_day` and
  `directional_light.energy` to `energy_noon`. It deleted nothing.

### 4. Physics

`PhysicsBodyBuilder.BODY_TYPES` holds `static`, `kinematic`, `rigid`,
`area` and `character`. `kinematic` is the default.
`PhysicsBodyBuilder.FIELDS` lists the fields of a `physics` block.

- Collision layers are names from `@lib.physics.layers`, or `"all"`.
  Bit numbers belong to the interpreter. The engine no longer accepts a
  raw number. It reports an error (`physics.unknown_layer`).
- `rigid` is host-defined. Its position does not write back to state,
  so it stays outside the conformance tests.
- An unknown body type reports `physics.unknown_body_type`.
- The `static_decoration_no_collision` preset had `"body_type": null`.
  No game used it, and the spec form is to omit the block. The preset
  is deleted.

### Enforcement

- `validate_host_neutral.py` checks 7 to 10: key and mouse button
  names, audio channels, `scene.json` lighting fields, and `physics`
  fields, body types and layer names after `$extends`.
  `tools/validators/content.py` reads each list from its engine file.
- `test_host_neutral.py` has 16 new cases.
- `test_spec_vocabularies` in `test_runner.gd` checks each table, the
  physical key binding of both paths, the music bus, the sky color
  order and the preset body types. It also scans the
  `LightingDirector` source and fails if the code reads a field that
  `FIELDS` does not list.
- `gen_api_manifest.py` prints the four lists (§Spec vocabularies).

## Consequences

**Enables:**
- A second interpreter maps 70 key names, 3 channels and 5 body types,
  with no Godot table.
- An LLM reads one closed list for each area. A wrong name fails at
  validation, not as a silent no-op.
- The authored ambient light and sky colors now show. Composed worlds
  look as their files say.

**Costs:**
- Scenes that set the dead fields now look different: the fill light
  and the sky follow the authored values.
- A new key, channel, lighting field or body type needs an ADR.

**Known gaps:**
- The `layers.json` comment promised a per-game layer file. The engine
  never read one. The comment now says that a new name is a change to
  the library file.
- The two open questions of ADR 0086 stay open: the seeded random
  generator and the order inside one tick.

## Alternatives considered

- **Web standard key names** (`KeyW`, `Digit1`, `ShiftLeft`). They are
  a published standard, but all 85 fields would change, and the names
  are longer.
- **Buses that each game lists.** This gives more freedom, but a second
  interpreter would have to support any bus layout.
- **Lighting definitions with no validator.** The five defects above
  show that an unchecked field fails with no warning.
- **Take `rigid` out of the spec.** No game uses it today, but marking
  it host-defined keeps the preset for a later ADR that writes its
  position back to state.
