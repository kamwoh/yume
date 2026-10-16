# Engine tour

_Last updated: 2026-10-16_

This page explains how the engine is built and how a game runs. The
README gives the overview. The engine contract is
[`30_framework_primitives.md`](../guideline/30_framework_primitives.md).
The Mermaid diagrams are in
[`33_architecture.md`](../guideline/33_architecture.md).

## Repository layout

```
yume/
├── godot/                         ← the Godot project (engine + scaffolding)
│   ├── project.godot              ← autoloads: CaptureRunner, AudioBus, StdioStepDriver
│   ├── scenes/                    ← TRACKED scaffolding scenes only
│   │   ├── play.tscn              ← universal launcher (--game=<name>)
│   │   ├── test_main.tscn         ← engine unit tests
│   │   └── scenario_test.tscn     ← per-game scenario test runner
│   ├── scripts/engine/            ← THE ENGINE (file map below)
│   ├── scripts/renderer_2d/       ← 2D entity renderer (read-only view)
│   ├── scripts/renderer_3d/       ← 3D entity renderer + mesh library
│   └── data/
│       ├── lib/                   ← shared JSON libs (shapes, meshes, input, shaders) — TRACKED
│       └── demo_<name>/           ← per-game content — mostly GITIGNORED
├── scripts/
│   ├── play.sh                    ← run with the WINDOWS Godot binary (play, capture, tests)
│   ├── run_linux.sh               ← run with the LINUX binary (headless tests + the stdio env)
│   └── ci_checks.sh               ← the Python checks that CI runs
├── tools/
│   ├── validators/                ← static validators (CI and the pre-commit hook run them)
│   ├── yume_env/                  ← ADR 0060 env: oracle.py, env.py (gym-like), test_env.py
│   ├── yume_codegen/ yume_assetgen/  ← optional authoring-time emitters
│   ├── visual_layout/             ← text→2D/3D layout pipelines (HUD/screen/map)
│   └── visual_qa/                 ← objective visual test plans (3D games)
├── docs/                          ← guideline/ (contract, architecture), adr/, engine-reference/
├── .claude/                       ← skills (yume-*) + path-scoped rules
├── .github/workflows/ci.yml       ← CI: validators, engine unit tests, example scenarios
└── CLAUDE.md                      ← project instructions (read this for conventions)
```

The committed examples are `demo_sokoban`, `demo_doomarena3d` and
`demo_lanterns`. They run on a fresh clone. Other demos are local.

## Engine file map (`godot/scripts/engine/`)

Read the layers in this order: core primitives, stores, the tick
scheduler, effects, coordinators, directors, UI, I/O, and QA.

### `core/` — the seven primitives and the interpreter

| File | Role |
|---|---|
| `entity.gd` | **Primitive 1, Entity**: id, tags, properties (static), state (dynamic), position. |
| `rule.gd` | **Primitive 3, Rule**: `{trigger, query, effect}`. `from_dict` parses and checks the JSON. |
| `query.gd` | **Primitive 6, Query**: matches entities by tags, state, relations, `id` and radius. A tag index serves tag-only scans (ADR 0084). |
| `phase_scheduler.gd` | **The tick loop**: the input, decide and react phases, the effect write buffer, and the flushes. |
| `effect_apply.gd` | **Primitive 5, Effect**: sends an effect dict to its handler in `effects/`. |
| `effects/effect_core.gd` | Base verbs: `state_set/add/mul/clamp`, `spawn`, `remove`, `relate`, tags, relation state. |
| `effects/effect_motion.gd` | Motion and spatial verbs: `velocity_set`, `velocity_add_relative`, `pathfind_to`, `raycast_hit`. |
| `effects/effect_actor.gd` | Actor-control verbs: `switch_actor`, `queue_input_for_actor`. |
| `effects/effect_shell.gd` | Verbs at the engine-to-shell boundary: `transition_level/screen`, `save/load_state`, toasts. |
| `effects/effect_resolution.gd` | Shared target and value resolution for the effect handlers. |
| `formula.gd` | Evaluates formula strings such as `"a.state.x + 10"` (whitelisted math, no ternary). |
| `world.gd` | **The top-level orchestrator.** It owns the state and runs `advance_one_tick`. |
| `engine_error.gd` · `scripted_policy.gd` | Structured engine errors · scripted-JSON actor AI (ADR 0018). |

The API manifest lists all 10 triggers and all 50 effects:
[`api-manifest.json`](api-manifest.json). `gen_api_manifest.py`
generates it from the engine code, and CI fails when it is stale.

### `stores/` — indices that queries read

- `relation_store.gd`: **Primitive 7, Relation**. Typed directed edges with edge state.
- `spatial_index.gd`: grid buckets for radius queries. The cell size comes from the entity radii.
- `zone_store.gd`: zone state (ADR 0031).

### `coordinators/` — boot and per-frame subsystems

- `world_boot.gd`: the boot sequence. It mounts the directors and loads the JSON.
- `world_loader.gd`: boot-time parsers.
- `spawn_manager.gd`: the spawn pipeline.
- `physics_body_builder.gd`: builds a CharacterBody3D or another body from a def.
- `character_body_runner.gd`: per-entity motion.
- `ground_constraint.gd`, `ground_renderer.gd`, `grass_renderer.gd`: the floor and the biome ground.
- `actor_manager.gd`: which entity gets the input (ADR 0016).
- `level_transition_coordinator.gd`, `save_load_coordinator.gd`, `world_reset_coordinator.gd`: the pending pipelines that GameShell drains.
- `variant_overlay.gd`: per-scenario variants.

### Directors

WorldBoot mounts 9 directors in every game: GameShell, ScreenFlow,
OverlayManager, SettingsManager, LightingDirector, ScheduleDirector,
LifecycleDirector, NameplateRenderer and ScreenSmokeRunner. Each one does
nothing when no content uses it. `directors/` also holds the animation
director, chunk streaming and MultiMesh batching. Each director has an
accepted ADR. `tools/validators/engine_vocabulary.json` lists them, and
a validator fails on any director, effect or formula root without one.

### `ui/` — Godot UI built from JSON

- `game_shell.gd`: the per-frame host for the camera, the HUD and the pending pipelines.
- `screen_flow.gd`: the screen and modal stack from `screens.json`.
- `control_factory.gd`: JSON to a Godot Control tree.
- `overlay.gd`: tutorial overlays.
- `settings_manager.gd`: settings from `settings_schema.json`.
- `widgets/`: `hud_builder`, `camera_director`, `viewmodel_director`, `win_lose_widget`, `bounds_renderer`.

### `io/` — where the outside world meets the engine

| File | Role |
|---|---|
| `input_registrar.gd` | Registers `ui/input.json` actions in Godot's InputMap. **`poll()`** reads the action state and calls `scheduler.queue_input`. This is the one input seam. |
| `capture_runner.gd` | Autoload for `--capture-*`: renders a frame or runs a step script, saves a PNG, and quits. |
| `stdio_step_driver.gd` | Autoload for `--stdio-step`, the ADR 0060 env: stdin actions, then 1 tick, then the state on stdout. |
| `determinism_hash.gd` | `canonical_state_hash`: a SHA-256 of the canonical world state. |
| `net_driver.gd` · `lockstep_*.gd` | Server-authoritative multiplayer (ADR 0063) · lockstep (ADR 0061). |
| `save_state.gd` · `audio_bus.gd` | Persistence (ADR 0010) · the procedural SFX bus. |

### `qa/` — test drivers that share one execution path

| File | Role |
|---|---|
| `step_runner.gd` | **The scenario engine.** It runs the `steps[]` verbs (press, hold, click, wait, tick, expect, ...). Scenario tests, captures and the env all use it. |
| `scenario_runner.gd` | The `scenes/scenario_test.tscn` entry. It loads `tests.json` and runs each scenario through StepRunner. |
| `screen_smoke_runner.gd` | Visits every screen and captures it. |

### `libs/` and `util/`

- `lib_resolver.gd`: `@lib.*` and `$include` reuse across games (ADR 0027).
- `macro_expander.gd`: rule macros.
- `shape_lib.gd`: the code-draw library.
- `instance_patterns.gd`: scatter, ring and grid placement, with a fixed seed per pattern.
- `grid_snap.gd`, `pathfinding.gd`, `vec3_util.gd`: small helpers.

### Renderers

`renderer_2d/entity_sprite_2d.gd` and `renderer_3d/entity_mesh_3d.gd` are
**read-only** views. Each one reads an entity's `state.position` and its
`visual` block, and draws it. The fallback order is: the authored mesh or
sprite, then a shape-library primitive, then a colored box. A renderer
never writes engine state.

## How a game runs

### Boot

```
scenes/play.tscn (or <game>_3d.tscn)  →  World._ready()
  → (auto_start) start() → load_data()
      → world_boot.run():  mount 9 directors · register ui/input.json actions
        · load entities/ + world/rules/ + scene.json + screens.json
        · spawn initial_instances (+ expand instance_patterns)
```

### Each frame and each physics step

```
World._process(delta)           (display rate)
    _ground_constraint.apply()
    scheduler.fire_frame_tick()   → ADR 0050 per-frame content rules
World._physics_process(delta)   (fixed rate, ADR 0068 + 0069)
    _poll_input()                 → InputRegistrar.poll → queue this step's input
    advance_one_tick()            → when the sim-tick accumulator is due
GameShell._process              → pending pipelines (level, save, reset) + camera + HUD
```

### Each tick: `world.gd::advance_one_tick()`

```
_tick_count++
actor_manager.tick_policies()     scripted AI (ADR 0018), if an actor manager exists
scheduler.tick()                  the phase loop (below)
lifecycle and chunk directors
trajectory + determinism-hash log (opt-in)
```

### The phase loop: `phase_scheduler.gd::tick()`

```
input  phase: rules with trigger {input, action} for the queued actions → flush
decide phase: tick rules (interval) → flush
signals: signal rules → flush
react  phase: contact rules → flush
```

Effects do not change state directly. They go to a write buffer that
flushes at each phase boundary. So a later phase sees the results of an
earlier phase (tech-director Invariant #9).

The calendar clock is separate (ADR 0078). An `advance_time {units: N}`
effect runs the `scheduled` rules N times at once. It does not run the
tick rules.

## The input flow

All three input sources meet at the **polled action state**, then
`InputRegistrar.poll`, then `scheduler.queue_input`. They do not use
synthesized `InputEvent`s. The seam is one level below events: the
`Input.is_action_pressed` / `is_action_just_pressed` state, which real
keys and `Input.action_press()` both set. ADR 0060 phase 1 explains why.

```
 (A) LIVE PLAYER
   physical key ──► Godot InputEventKey ──► updates ┐
                                                     │
 (B) SCENARIO / CAPTURE  (StepRunner)                │   ┌───────────────────────┐
   {press/hold:"X"} → Input.action_press("X") ───────┼──►│ Godot action STATE     │
                                                     │   │ is_action_pressed /    │
 (C) PYTHON ENV  (stdio_step_driver)                 │   │ is_action_just_pressed │
   stdin {"actions":["X"]} → Input.action_press("X")─┘   └──────────┬────────────┘
                                                                     ▼
   world.gd::_poll_input() [live]  /  StepRunner._drive_poll() [B,C]
        → InputRegistrar.poll(scheduler, actor_id, press_list, hold_list, …)
              press-edge action → is_action_just_pressed     hold action → is_action_pressed
                                                                     ▼
        scheduler.queue_input("X", {"actor": <resolved actor id>})   (deduped per tick)
                                                                     ▼
   scheduler.tick() input phase: rules with trigger {input, action:"X"} fire
                                                                     ▼
        rule.query picks entities (binds self/actor) → rule.effect runs
                                                                     ▼
        e.g. velocity_set(self, …)  →  character_body_runner integrates velocity→position
```

Two JSON maps keep this independent of any game:

- `data/<game>/ui/input.json` maps a **key to an action name**, with
  `edge: press|hold`. `InputRegistrar` registers these in Godot's InputMap
  and in the engine's press and hold poll lists.
- `data/<game>/world/rules/*.json` maps an **action to an effect**, through
  a rule `{trigger:{type:"input", action:"X"}, query:{…}, effect:[…]}`.

The engine never knows what `move_north` means. It sends the action to the
rule that the JSON connects to it.

**Three drivers, one seam.** Live play ticks from `_physics_process`.
StepRunner and the env switch off the World's own processing and tick
the world themselves. They set the action state with `action_press()`
and call the same `poll()`. Below the poll seam, a scripted key is the
same as a real one. StepRunner also shows each press to the UI nodes
that read input per frame: ScreenFlow, the overlay manager and
GameShell's ESC check. Scripted input does not go through Godot's
`_input` / `_gui_input` events. StepRunner presses UI buttons with its
`click` verb instead.

## The three runtimes

| Runtime | Binary | Use |
|---|---|---|
| **`scripts/play.sh`** | Windows Godot (`.exe` through WSL) | play, captures, unit and scenario tests |
| **`scripts/run_linux.sh`** | native Linux Godot | fast headless tests and the env, with no `/mnt/c` round trip |
| **`tools/yume_env/env.py`** | native Linux Godot | the ADR 0060 stepping env (Python) |

Both binaries are the same Godot 4.6.1 build. The Linux one exists
because Windows through WSL cannot pipe stdin and stdout reliably.
CI uses a Linux build. To run Godot by hand, `cd "$TEMPLATE_DST"` and
pass `--path .`. An absolute `--path` aborts with "Invalid project
path". [`running-godot.md`](running-godot.md) has the full procedure.

### The Python env (ADR 0060)

```python
from tools.yume_env.env import YumeEnv
env = YumeEnv("demo_sokoban")          # or frames=True for pixel observations
env.reset()
obs = env.step(["move_north"])         # {"tick","hash","state"} (+ "frame" if frames=True)
env.close()
```

One stdin JSON line is one tick and one stdout state line. The env has
two separate observation channels:

- **state**: JSON plus the canonical hash, on stdout. This is the ground
  truth for an evaluator.
- **frame**: raw RGBA8 in a file, opt-in. This is the input for a future
  pixel agent.

`tools/yume_env/oracle.py` runs a demo twice and compares the hash of
each tick, so you can check determinism.

## Data layer (per game, `godot/data/demo_<name>/`)

```
entities/*.json       definitions (tags/properties/state_init/visual) + initial_instances
world/rules/*.json    the mechanics: {trigger, query, effect} rules (folder form)
world/state.json      initial world state
game/flow.json        multi-level progression (ADR 0006)
levels/<n>/           per-level entities and rules
scene.json            camera + lighting + ground + tick_seconds
ui/input.json         key → action map
hud.json              HUD layout + win/lose blocks
screens.json          menus and modals
audio/cues.json       event → SFX
tests.json            scenario tests (steps[])
```

`data/lib/` holds shared, TRACKED JSON (`shapes.json`, `meshes.json`,
`input/universal.json`, shaders). Games include it with `@lib.*`
(ADR 0027).

## Which skill runs which script

Most skills only **write JSON**. The orchestrator does the single sync
and the Godot run. These skills run a script:

| Skill | Script(s) it runs |
|---|---|
| `yume-design` | `compose_scene --no-shell` (World), `tools.yume_assetgen` (Assets), `scripts/play.sh` (QA capture) |
| `yume-create-scene` | `compose_scene` → `compose_world` + `compose_shell`, `tools.yume_assetgen`, `compare_semantic` |
| `yume-scene-class-catalog` | writes the catalog that `compose_world` reads (no run) |
| `yume-asset-designer` | `tools.yume_assetgen`, `tools/validators/run_all.py` |
| `yume-hud-author` / `screen-author` / `map-author` | `wireframe_to_{hud,screen,map}` |
| `yume-qa-tester` · `playtest` · `visual-designer` · `lighting-designer` | `scripts/play.sh` (run + capture), `tools/visual_qa/` (playtest Gate 6b) |
| `yume-tech-director` | invariant greps and the unit suite (a gate, no content) |
| _all other designers_ | write JSON only |

`.claude/rules/pipeline-stability.md` sets the pipeline tiers. The 2D
HUD and screen pipelines are **locked**: a change to the harness needs an
ADR. The 3D scene, world, level and map pipelines are **active**.
