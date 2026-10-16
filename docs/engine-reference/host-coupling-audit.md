# Host-coupling audit: where the Yume JSON depends on Godot

_Last updated: 2026-10-17_

ADR 0086 makes Yume a host-neutral spec, with Godot as the reference
interpreter. This page lists each place where today's JSON depends on
Godot. Each row says what a neutral form could be, and which ADR 0086
phase owns it. Remove a row when its phase ships.

Counts come from all of `godot/data/` on the author's machine: the
tracked library, the three tracked demos and the local demos.

## Already neutral

| Area | Evidence |
|---|---|
| Seven primitives, 50 effects, 10 triggers, queries | Effect and trigger names describe game actions (`state_set`, `spawn`, `relate`, `raycast_hit`). None names a Godot class. |
| UI vocabulary | Screens and HUDs use `label`, `button`, `vbox`, `hbox`, `image`, `progress_bar`, `list`, `spacer`, `color_rect`. No file names a Godot Control class. |
| Scenario tests | `tests.json` uses `press <action>`, `tick N`, and `expect` on entity fields. |
| Asset file formats | Meshes are glTF (`.glb`), images are PNG, and sounds are OGG. These are open formats. |
| Shader DAG | ADR 0058 describes shaders as a JSON graph of primitives. A compiler emits `.gdshader` today, and it could emit other shader languages. |
| Calendar clock | `scheduled` and `advance_time` (ADR 0078) have no host meaning. |

## Tied to Godot

| # | Area | Today | Count | Neutral form | Phase |
|---|---|---|---|---|---|
| 1 | Asset paths | `"mesh": "res://data/demo_x/assets/meshes/hero.glb"` | 201 references in 38 files (14 in 5 tracked files) | A path relative to the game folder or to `data/lib`. The interpreter resolves it. | 1 |
| 2 | Save paths | `user://` in one local `tests.json` | 1 file | A save slot name only. The interpreter picks the storage. | 1 |
| 3 | Formula language | Godot `Expression` parses every formula. No function list is enforced. | 14 documented helpers. Rules also call `atan2`. | A grammar, a function list and number rules in the contract document. The validator rejects other functions. | 2 |
| 4 | Number rules | Integer and float behavior follows Godot. JSON numbers load as floats, and formula literals keep their own type. | Every formula | The spec states the result of division, comparison and rounding. | 2 |
| 5 | Shaders | `"shader": "res://.../x.gdshader"` with `shader_params` | 17 references, 6 tracked `.gdshader` files | The ADR 0058 shader DAG. Hand-written `.gdshader` files become a Godot-only extension. | 3 |
| 6 | Godot resources | `"water_normal_tex": "res://.../water_normal.tres"` | 1 reference, 1 tracked `.tres` | A PNG, or a declared procedural texture. | 3 |
| 7 | Key names | `"key": "Ctrl"`, parsed by `OS.find_keycode_from_string` | 85 `key` fields | A key-name list in the spec. Each interpreter maps the list to its host. | 4 |
| 8 | Audio buses | `set_audio_bus_volume` with `"bus": "Master"` or `"Music"` | 2 references | A fixed set of channels in the spec (for example, master, music, sfx). | 4 |
| 9 | Lighting and sky | `scene.json` fields such as `sky_top_color`, `aerial_perspective`, `sun_scatter`, `energy_noon`, fog `density` | About 60 field names | Define each field by its visible result. Mark the exact look as host-defined. | 4 |
| 10 | Physics | `body_type` (`static`, `kinematic`, `rigid`, `area`, `character`), `collision_layer`, `collision_mask` | 53 `physics` blocks | Define what each body type guarantees and what the masks mean. Numeric results are host-defined. | 4 |
| 11 | Randomness | `randf()` in formulas uses Godot's global PRNG. `level_seed` calls Godot's `seed()`. Instance patterns use their own `RandomNumberGenerator`. | 34 `randf(` calls | Open question 1 in ADR 0086: one PRNG defined by the spec, or no random rules in conformance tests. | open |
| 12 | Tick order | Input, rules and body motion share Godot's physics clock (ADRs 0068, 0069). | All games | The spec states the order inside one tick. | open |

## Inside the interpreter (not a leak)

These Godot names appear only in engine code, not in game JSON. A
second interpreter does not need them.

- The `ui_cancel` action that closes overlays and opens the pause screen.
- Per-game `.tscn` launchers and `renderer_script`.
- `CharacterBody3D`, `RigidBody3D` and other nodes that
  `physics_body_builder.gd` makes from a `body_type`.
- `AnimationPlayer`, which plays the clips inside a glTF file.

## How to update this page

- When a phase ships, remove its rows and name the commit in the
  commit message.
- When an ADR adds a field that ADR 0086 rule 3 forbids, add a row
  here with that ADR number. A new row needs a reason that the review
  accepted.
