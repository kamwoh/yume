# Host-coupling audit: where the Yume JSON depends on Godot

_Last updated: 2026-10-18_

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
| Shaders | ADR 0089 (phase 3): content names one of 5 library shaders by name, or writes a `shader_dag` graph (ADR 0058). The api manifest lists each shader's parameters. `validate_host_neutral.py` rejects `.gdshader` and `.tres` names. |
| Calendar clock | `scheduled` and `advance_time` (ADR 0078) have no host meaning. |
| Formula language | ADR 0088 (phase 2): every number is a float, and a formula calls only the 16 functions in `Formula.FUNCTIONS`. `validate_rules.py` check (12) and `Formula` reject other syntax. |
| Asset and save paths | ADR 0087 (phase 1): a path is relative to the game folder or starts with `@lib/`. `validate_host_neutral.py` rejects `res://` and `user://`. |
| Key names, audio channels, lighting fields, physics | ADR 0090 (phase 4): each is a closed list in its engine file (`InputKeys`, `AudioChannels`, `LightingDirector.FIELDS`, `PhysicsBodyBuilder.BODY_TYPES`). The contract defines each name. `validate_host_neutral.py` checks 7 to 10 reject other names. |

## Tied to Godot

| # | Area | Today | Count | Neutral form | Phase |
|---|---|---|---|---|---|
| 11 | Randomness | `randf()` in formulas uses Godot's global PRNG. `level_seed` calls Godot's `seed()`. Instance patterns use their own `RandomNumberGenerator`. | 34 `randf(` calls | Open question 1 in ADR 0086: one PRNG defined by the spec, or no random rules in conformance tests. | open |
| 12 | Tick order | Input, rules and body motion share Godot's physics clock (ADRs 0068, 0069). | All games | The spec states the order inside one tick. | open |

## Inside the interpreter (not a leak)

These Godot names appear only in engine code, not in game JSON. A
second interpreter does not need them.

- The `ui_cancel` action that closes overlays and opens the pause screen.
- Per-game `.tscn` launchers and `renderer_script`.
- `CharacterBody3D`, `RigidBody3D` and other nodes that
  `physics_body_builder.gd` makes from a `body_type`.
- The Godot bus names (`Master`, `Music`, `SFX`) behind the audio
  channels, and the Godot keycodes behind the key names.
- `AnimationPlayer`, which plays the clips inside a glTF file.

## How to update this page

- When a phase ships, remove its rows and name the commit in the
  commit message.
- When an ADR adds a field that ADR 0086 rule 3 forbids, add a row
  here with that ADR number. A new row needs a reason that the review
  accepted.
