# Yume web host

_Last updated: 2026-10-19_

The TypeScript interpreter of the Yume spec (ADR 0095). Godot stays the
reference interpreter. This host must give the same result for every
exact behavior (contract doc, §Two behavior classes).

## Status: phases 1 to 3 done, phase 4 in progress

| In this host | Not in this host yet |
|---|---|
| Entities, tags, state, relations, queries, formulas | |
| Rules with the tick phases, `once`, `once_per`, `chance`, `overlap` | `lod`, `scope` |
| Exact effects: state, spawn, remove, transform, relations, tags, arrays, emit, `advance_time`, `velocity_set`, `velocity_set_relative`, `velocity_add_relative`, `velocity_lerp`, `raycast_hit` | Zones, `pathfind_to` |
| Physics on Rapier (phase 3): the static, kinematic, rigid, area, character and articulated bodies, and sensors. Also `blocks_motion` boxes, GLB-sized shapes, and trimesh and heightmap ground in the viewer | The `base` footprint of `from_visual_mesh` |
| The engine rules in `lib/engine_rules` | Macros, actors, zones, `level_call` |
| Saves (ADR 0010): `save_state`, `load_state`, autosave, `has_save`. A scenario keeps them in memory, the viewer in `localStorage` | |
| Levels (`game/flow.json`), `transition_level`, variants | |
| `press`, `hold`, `release`, `tick`, `wait`, `expect` | `click`, `screenshot`, UI assertions (phase 4) |
| The browser viewer, 2D: shapes (`shapes.json`), the 2D camera and its shake, the keyboard and the mouse buttons | |
| The shell (phase 4): screens (`screens.json`) with modal stacks and global inputs, overlays, toasts, fades, the hit flash, the freeze, `reset_world`. HUD labels, progress bars and the crosshair | The minimap, `slot_grid` |
| Audio (phase 4): the procedural sounds of `sounds.json` with WebAudio, `@cues.*`, the music slot, the master, music and sfx channels | Audio files (.ogg) |
| The browser viewer, 3D: `meshes.json`, GLB models, the ground and its heightmap relief, sun, sky, fog, the 3D camera modes, mouse look, articulated links | CSG booleans (`csg` subtract and intersect), the water and toon shaders, SSAO, glow |
| Settings (ADR 0013): the rows of `settings_schema.json`, the apply chains at boot and on change, kept in `localStorage`. The first-person viewmodel. The CSG ops `lathe`, `extrude` and `sweep`. Grass blades and flowers | |
| Animation (phase 4): GLB clips under `animation_state_rules` with `clip_alias`, library-mesh `animations`, `anim_phase` | |
| Shaders (phase 4): `sky_clouds`, `ground_biome_displace`, `ground_ortho_displace` | `water_stylized`, `toon`, `shader_dag` |

Shell effects (screens, toasts, save, audio) write a record to
`env.shellEvents` and change no other state. An autosave on a level swap
also writes a record there. A feature outside phase 1
gives a `host.unsupported` or `effect.unsupported_host` warning.

## Run

Node 22.18 or later runs the TypeScript files directly. You do not need
a build step.

```bash
cd hosts/web
npm ci                 # once, for the type checker only
npm test               # unit tests
npm run typecheck
node src/cli.ts --lib=../../godot/data/lib ../../spec/conformance/*/
```

`../../scripts/conformance.sh` runs the conformance cases on this host
and on Godot.

## The browser viewer

```bash
node src/serve.ts      # then open http://localhost:8095/?game=demo_sokoban
```

The server strips the types from each `.ts` file when it serves it, so
the viewer also needs no build step. It sends the game as one JSON
bundle (`src/bundle.ts`), and the browser loads it into `MemoryFiles`.
The core never imports `node:fs`. It reads files through `src/files.ts`.

`src/live.ts` runs the live loop of the reference: one input poll for
each 1/60 s physics step, and one sim tick for each `tick_seconds`. A
press-edge key fires once for each key-down. `test/live.test.ts` checks
this. The physics host then steps the bodies. As in the reference, the
clock waits until every GLB file has loaded.

## Physics (phase 3)

`src/physics.ts` holds the seam: the interface, the closed vocabularies
and the exact parts (layer names, the tree check of an articulated
body). `src/physics_rapier.ts` implements it on Rapier
(`@dimforge/rapier3d-compat`, with its WASM inline). The viewer loads it
only for a game that declares bodies or sensors.

Motion is host-defined (ADR 0086). Where Rapier gives a choice, the host
follows Godot:

- A pair collides when the layer of either side is in the mask of the
  other. A contact hook applies this rule.
- Friction combines by the minimum. The default friction is 1, and the
  default damping is 0.1.
- A hinge motor applies a capped impulse between solves. Rapier's JS
  motor has no cap, so a world with motors takes 8 substeps for each
  step. With one substep, ground friction undid the braking of a light
  wheel, and a turn in place drifted 0.09 m.
- A new body joins the ray queries at the next physics step.
- A rigid body writes nothing back to state, as in the reference.

A scenario steps the bodies as `step_runner.gd` does. Character bodies
move by Euler integration (`tick_headless`). Only a world with an
articulated body gets one physics step for each tick. Live play adds the ground
collider of `scene.json`, which a scenario run does not have.

The viewer picks the 3D renderer when the `scene.json` camera mode is a
3D mode (`top_down_3d`, `isometric_3d`, `third_person_3d`,
`first_person_3d`). A click captures the mouse for mouse look.

### Captures for visual QA

`src/capture.ts` drives a headless Chromium over the DevTools protocol.
It waits until every GLB file has loaded, plays real key presses through
the live loop, and saves a PNG. The dev server must be running.

```bash
node src/capture.ts --game=demo_sokoban --out=shot.png --keys=Right:0.1,wait:1
```

`--keys` takes spec key names (ADR 0090) with a hold time in seconds,
and `wait:N`. The tool finds a Playwright headless shell in
`~/.cache/ms-playwright`, or takes `--browser=<path>` or `$YUME_CHROME`.

The viewer shows the starting screen of `screens.json` before the first
tick, as the reference does. A screen or an overlay with `freeze_world`
stops the live clock, and a press made during the freeze is dropped.
The keyboard reaches each screen: the first button has focus, the arrow
keys move it, and Enter or Space presses it.

## Layout

The files follow the Godot files, one to one, so that a reader can
compare them:

| File | Godot twin |
|---|---|
| `src/entity.ts` | `core/entity.gd` |
| `src/query.ts` | `core/query.gd` |
| `src/formula.ts` | `core/formula.gd` |
| `src/rule.ts` | `core/rule.gd` |
| `src/scheduler.ts` | `core/phase_scheduler.gd` |
| `src/effects.ts` | `core/effect_apply.gd`, `effects/effect_core.gd`, `effects/effect_resolution.gd` |
| `src/relations.ts` | `stores/relation_store.gd` |
| `src/lib_resolver.ts` | `libs/lib_resolver.gd` |
| `src/random.ts` | `util/spec_random.gd` |
| `src/world.ts` | `core/world.gd`, `coordinators/world_boot.gd`, `coordinators/world_loader.gd` |
| `src/scenario.ts` | `qa/scenario_runner.gd`, `qa/step_runner.gd` |
| `src/input.ts` | `io/input_registrar.gd` (the poll) |
| `src/viewer/render2d.ts` | `renderer_2d/entity_sprite_2d.gd`, the 2D part of `ui/widgets/camera_director.gd` |
| `src/viewer/render3d.ts` | `renderer_3d/entity_mesh_3d.gd`, `coordinators/ground_renderer.gd`, `directors/lighting_director.gd`, the 3D part of `camera_director.gd` |
| `src/viewer/mesh_lib.ts` | `renderer_3d/mesh_lib.gd` |
| `src/viewer/hud.ts` | `ui/widgets/hud_builder.gd` (labels, bars, crosshair, hint, win panel) |
| `src/viewer/shell.ts` | `ui/screen_flow.gd`, `ui/overlay.gd`, the event drain of `ui/game_shell.gd` |
| `src/viewer/ui.ts` | `ui/control_factory.gd` |
| `src/viewer/anim.ts` | `directors/animation_director.gd`, `directors/animation_translator.gd` |
| `src/viewer/shaders.ts` | `data/lib/shaders/*.gdshader` |
| `src/viewer/settings.ts` | `ui/settings_manager.gd`, the settings rows of `ui/screen_flow.gd` |
| `src/viewer/grass.ts` | `coordinators/grass_renderer.gd`, `data/lib/shaders/grass_blade.gdshader` |
| `src/viewer/audio.ts` | `io/audio_bus.gd`, `io/audio_channels.gd` |
| `src/save.ts` | `io/save_state.gd`, `coordinators/save_load_coordinator.gd` |
| `src/viewer/keys.ts` | `io/input_keys.gd` |
| `src/physics.ts`, `src/physics_rapier.ts` | `coordinators/physics_body_builder.gd`, `character_body_runner.gd`, `articulated_body.gd`, `sensor_array.gd` |
| `src/heightmap.ts` | `GroundRenderer.sample_y` |
| `src/glb.ts` | `PhysicsBodyBuilder._glb_bbox` |

## When the two hosts disagree

A disagreement is a spec bug. Do not change one host to match the other
by guess. Find the behavior in the contract doc. If the contract does
not state it, add a sentence and a conformance case, then make both
hosts follow it. Phase 1 found five such bugs (ADR 0095).
