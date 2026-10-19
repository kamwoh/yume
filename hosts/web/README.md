# Yume web host

_Last updated: 2026-10-18_

The TypeScript interpreter of the Yume spec (ADR 0095). Godot stays the
reference interpreter. This host must give the same result for every
exact behavior (contract doc, §Two behavior classes).

## Status: phase 1 done, phase 2 in progress

| In this host | Not in this host yet |
|---|---|
| Entities, tags, state, relations, queries, formulas | Physics bodies, sensors (phase 3) |
| Rules with the tick phases, `once`, `once_per`, `chance` | `lod`, `scope`, `overlap` |
| Exact effects: state, spawn, remove, transform, relations, tags, arrays, emit, `advance_time`, `velocity_set` | Other motion effects, zones, `pathfind_to`, `raycast_hit` |
| The engine rules in `lib/engine_rules` | Macros, actors, zones, `level_call`, saves to disk |
| Levels (`game/flow.json`), `transition_level`, variants | |
| `press`, `hold`, `release`, `tick`, `wait`, `expect` | `click`, `screenshot`, UI assertions (phase 4) |
| The browser viewer, 2D: shapes (`shapes.json`), the 2D camera, the keyboard, HUD labels | Screens, overlays, other HUD widgets (phase 4) |
| The browser viewer, 3D: `meshes.json`, GLB models, the ground color, sun, sky, fog, the 3D camera modes, mouse look | CSG ops, ground and sky shaders, heightmaps, animations, articulated links, the viewmodel, SSAO, glow |

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
npm test               # unit tests (the generator vectors)
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
this.

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

The viewer starts the game at once. Screens (`screens.json`) and
overlays are phase 4, so the title screen and the tutorial overlay do
not show. The status line shows the title of the last overlay.

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
| `src/viewer/hud.ts` | `ui/widgets/hud_builder.gd` (labels, hint, win panel) |
| `src/viewer/keys.ts` | `io/input_keys.gd` |

## When the two hosts disagree

A disagreement is a spec bug. Do not change one host to match the other
by guess. Find the behavior in the contract doc. If the contract does
not state it, add a sentence and a conformance case, then make both
hosts follow it. Phase 1 found five such bugs (ADR 0095).
