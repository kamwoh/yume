# Yume (夢)

**Yume is a programmable, explicit _world model_** — built on Godot 4.6.1.
A world's entities and rules are written as **pure JSON**; a small interpreter
advances that world tick by tick; Godot *projects* the resulting state to pixels,
audio, HUD, or text. The engine ships a fixed set of **primitives + interpreter**
— no game-specific GDScript; you describe a world, never edit the engine
(Invariant #1 / #8; ADR 0021). **Games are one use of this — not the only one.**

> ## 🤖 Built by Claude, for Claude
> This repository was written **entirely by Claude** (Anthropic's AI) and is
> **designed to be read and operated by Claude** — its conventions, build steps,
> and run workflow live in `CLAUDE.md` and `.claude/` for exactly that purpose.
>
> **The recommended way to use Yume is to open it in [Claude Code](https://claude.com/claude-code)
> and ask, in plain English, for what you want** — "generate a game about X",
> "run the tests", "record a headless multiplayer video". Claude knows the
> fiddly invocation details (syncing, `--path .`, asset imports, the visual-QA
> gate). You *can* run the commands yourself, but it's easy to get them wrong;
> letting Claude drive is the intended, lower-friction path. See
> **[INSTALLATION.md](INSTALLATION.md)** to set up.

_Status: **pre-1.0 / experimental** (`0.x` — the 7 primitives + JSON schema
aren't frozen yet; `1.0` will freeze the contract). Last updated: 2026-06-06._

---

## What Yume is for

Yume is a **programmable explicit world model**, not just a game engine. A world
model is a transition function `f(state, action) → next_state`; Yume lets you
**write `f` as JSON** and run it:

- **JSON is the world-spec language** — entities (the state) + rules
  (`{trigger, query, effect}`, the transition function).
- **The runtime is the interpreter** — it executes that spec, ticking state forward.
- **Godot is the projection function** — state → pixels / audio / HUD / text.
  (Per ADR 0021: *expose Godot, don't reimplement it.*)

**Games are one downstream consumer.** The same substrate serves:

| Use | How |
|---|---|
| 🎮 **Games** | the Godot projection — a playable build |
| 🤖 **RL / agent-evaluation testbeds** | deterministic, seedable, gym-like stepping (ADR 0060) |
| 🏞️ **Scene / world generation** | prose → 3D scene pipelines (`/yume-create-scene`) |
| 🧠 **Training-data for neural world models** | roll a JSON world out, record `(state, action, next_state)` trajectories, train an implicit model (Dreamer/Genie-style) that approximates the same `f` at scale |

That last row is the thesis: Yume aims to be the **clean, authorable *explicit*
substrate** that bridges to the *implicit* (neural) world-model world — interpret
it directly, *and* use it as a faucet of reproducible training data. The seven
primitives (Entity / Tag / Rule / Trigger / Effect / Query / Relation) are the
**minimal universal vocabulary** for describing discrete-time worlds — which is
why the engine refuses game-specific verbs (no `damage` / `heal` / `attack`;
those are *content*, expressed by composing primitives).

📖 **Full vision:** [`docs/guideline/00_what_yume_is.md`](docs/guideline/00_what_yume_is.md).

---

## Features

What the framework can do today — JSON-authored unless noted; most rows map to
an ADR under `docs/adr/`.

| Area | Capabilities |
|---|---|
| **Core engine** (primitives + interpreter — ADR 0001, 0021) | 7 primitives (Entity / Tag / Rule / Trigger / Effect / Query / Relation); 8 trigger types (`tick`, `contact`, `signal`, `input`, `spawn`, `despawn`, `relation_changed`, `frame`); ~60 effect verbs (`state_set/add/mul/clamp`, `spawn`/`remove`/`transform`, relations, tags, velocity ×4, arrays, `pathfind_to`, `raycast_hit`, zones, shell-lifecycle); formula evaluator (whitelisted math); deterministic fixed-rate tick + phase-flush scheduler; `@lib`/`$include` cross-game reuse (ADR 0027); rule macros; deterministic scatter/ring/grid placement. |
| **Rendering & world** | 2D + 3D renderers; 8 camera modes (top-down / side-scroll / isometric / third- / first-person / fixed / free-cam, 2D & 3D); GLB meshes, kit-of-parts composites, MultiMesh decoration, trimesh static world; shaders-as-JSON; multi-biome ground from a semantic map; water surface; day/night; fog + procedural sky. |
| **Gameplay system primitives** (opt-in directors — mounted only if used) | party, schedule, class/occupation, zones, faction, tech-tree, dynasty, lifecycle/aging, vehicles, multi-actor + scripted-policy AI, pathfinding, procedural generation, grid/dynamic placement, animation. |
| **"Complete game" layer** | declarative screens/modals, save/load, tutorial overlays, settings schema, HUD-from-JSON, event→SFX audio, juice (shake/flash/particles). |
| **Physics** | Godot PhysicsServer + CharacterBody motion, AABB blockers, camera-relative WASD. |
| **Generation pipelines** (LLM-in-the-loop) | `/yume-design` is the single orchestrator — prose → full game, with `--scene` (generate a 3D world to play in) + `--with-assets` (AI textures/meshes) composing as **three disjoint-ownership layers** (World / Game / Assets — ADR 0067); no flags = key-free code-draw. Plus standalone authors: `/yume-create-scene`, `/yume-hud-author`, `/yume-screen-author`, `/yume-map-author`. **38 specialist skills**; optional codegen + AI assetgen (textures via OpenAI/Gemini, meshes + rig via Tripo3D, shaders). See [§ Generation pipeline](#generation-pipeline-prose--game). |
| **Networking & I/O** (ADR 0060–0066) | deterministic gym-like stepping env (Python) + determinism oracle; lockstep; **client-server (server-authoritative)** with data-driven `net.json` replication; synced animation; **record-then-replay smooth headless video** of N-player synced sessions (`scripts/net_video.py` — normal window / `--linux` headless, GPU, grid, 60 fps). |
| **Tooling & QA** | 24 static validators (sync gate); Playwright-style scenario tests; visual QA (Gemini + Claude vision); tech-director invariant gate. |

---

## Quick start

Set up once via **[INSTALLATION.md](INSTALLATION.md)** (Godot 4.6.1 + a Python
venv). Then — **recommended** — open the repo in **Claude Code** and just ask:

> *"Generate a game: a roguelike where vampires steal HP from light sources."*
> *"Run the engine tests."*  ·  *"Record a 4-player headless multiplayer video."*

Claude runs the right pipeline and handles the invocation details.

**Or drive it yourself** (manual fallback — demos are gitignored, generate or
copy a `demo_<name>/` first):

```bash
/yume-design "<your prose pitch>" --autonomous   # prose → full game
./scripts/play.sh <name>                         # play / capture (Windows binary)
./scripts/play.sh <name> --capture               # render a frame for visual QA
```

⚠️ Manual runs have sharp edges (the `cd "$TEMPLATE_DST" && --path .` trap, asset
`--import`, …) — see `CLAUDE.md` § "Running Godot". This is why letting Claude
drive is recommended.

---

## The model in one paragraph

A **game** is a folder of JSON under `godot/data/demo_<name>/`. The engine loads
it into **entities** (dicts with tags/properties/state/position) and **rules**
(`{trigger, query, effect}`). Each tick, the engine fires rules whose trigger
matches (a tick elapsed, a contact happened, an input arrived, a signal fired),
runs the rule's query to pick entities, and applies the effect (a primitive verb
like `state_set` / `velocity_set` / `spawn`). The renderer is a separate read-only
layer that draws entity state. **Seven primitives**: Entity, Tag, Rule, Trigger,
Effect, Query, Relation (ADR 0001).

---

## Generation pipeline (prose → game)

`/yume-design` is the **single orchestrator**. It's a *skill* loaded into
Claude's own context (Tier 2.6 — no subagents); it walks specialist skills in
sequence, and each one writes one slice of the game's JSON. A game is composed
from **three layers with disjoint file ownership**, so they never clobber each
other (ADR 0067):

```
/yume-design "<pitch>"  [--scene]  [--with-assets]  [--autonomous]

 Phase W   (--scene)        yume-scene-class-catalog ─▶ compose_scene --no-shell
   WORLD                      └─ image-gen (gpt-image) ─▶ compose_world (3D scene:
                                 biome ground, water, heightmap, placed props)
                                 + compose_shell (walk/jump/sprint + camera + .tscn)
 Phases 1-4 (always)        game-designer ─▶ game-reviewer ─▶ game-planner ─▶
   GAME                     level-designer ─▶ [combining-logic / economy / story]* ─▶
                            systems-designer ─▶ content-designer ─▶
                            game-rules-designer ─▶ asset-designer
                            (+ soul skills: flavor-writer, audio, juice, lighting,
                             screen-flow, save-policy, tutorial — as the GDD needs)
 Phase A   (--with-assets)  tools.yume_assetgen  (gpt-image concepts + Tripo3D .glb,
   ASSETS                     patches visual.* in place)
 Phase QA  (always)         qa-tester ─▶ visual-designer / visual-tester ─▶
                            gdd-coverage-tracker  (GDD = contract; no silent drops)
 on demand                  tech-director  (gates engine / new-primitive / ADR changes)
```

`*` conditional — those run only if the GDD signals crafting, an economy, or a
story. **Genre detection** swaps in strict specialists where they exist
(`shooter` / `merchant` / `racing` designers + their reviewers) on top of the
generic `game-designer` / `game-reviewer` floor.

**How the layers stay disjoint** — World writes `scene.json`,
`entities/auto_gen.json`, `assets/`; Game writes `entities/<slug>.json`,
`world/rules/*.json`, `hud.json`, goals; Assets patches `visual.*` on existing
defs. The engine globs `entities/*.json` + `world/rules/*.json` and merges by
id, so the layers compose with no merge code. **No flags = a key-free,
code-drawn single-player game** (and the graceful-degrade target when API keys
are absent).

### Standalone authoring pipelines (outside `/yume-design`)

| Slash command | Makes | Driver script(s) |
|---|---|---|
| `/yume-create-scene` | a walkable 3D scene / diorama (scene **+** walk shell) | `compose_scene` → `compose_world` + `compose_shell` (+ `compare_semantic` QA) |
| `/yume-hud-author` | `hud.json` fit to a wireframe | `wireframe_to_hud` (preprocess/postprocess) |
| `/yume-screen-author` | `screens.json` fit to a wireframe | `wireframe_to_screen` |
| `/yume-map-author` | a level's instances/patterns from a 2D sketch | `compose_map` + `wireframe_to_map` |

### Which skill drives which script

Most skills only **write JSON** — the orchestrator does the single sync + Godot
run. The skills that actually invoke a script:

| Skill | Script(s) it runs |
|---|---|
| `yume-design` | `compose_scene --no-shell` (World), `tools.yume_assetgen` (Assets), `scripts/play.sh` (QA capture) |
| `yume-create-scene` | `compose_scene` → `compose_world` + `compose_shell`, `tools.yume_assetgen`, `compare_semantic` |
| `yume-scene-class-catalog` | authors the catalog `compose_world` consumes (no run) |
| `yume-asset-designer` | `tools.yume_assetgen`, `tools/validators/run_all.py` |
| `yume-hud-author` / `screen-author` / `map-author` | `wireframe_to_{hud,screen,map}` |
| `yume-qa-tester` · `playtest` · `visual-designer` · `visual-tester` · `lighting-designer` | `scripts/play.sh` (run + `--capture`) |
| `yume-tech-director` | invariant greps + the unit suite (gate, no content) |
| _all other designers_ | write JSON only — no scripts |

Pipeline-stability tiers live in `.claude/rules/pipeline-stability.md`: the 2D
HUD/screen pipelines are **locked** (ADR required to change the harness); the 3D
scene/world + level/map pipelines are **active**.

---

## Repository layout

```
yume/
├── godot/                         ← the Godot project (engine + scaffolding)
│   ├── project.godot              ← autoloads: CaptureRunner, AudioBus, StdioStepDriver
│   ├── scenes/                    ← TRACKED scaffolding scenes only
│   │   ├── play.tscn              ← universal launcher (--game=<name>)
│   │   ├── test_main.tscn         ← engine unit tests
│   │   └── scenario_test.tscn     ← per-game scenario test runner
│   ├── scripts/engine/            ← THE ENGINE (see file map below)
│   ├── scripts/renderer_2d/       ← 2D entity renderer (read-only view)
│   ├── scripts/renderer_3d/       ← 3D entity renderer (read-only view)
│   └── data/
│       ├── lib/                   ← shared JSON libs (shapes, meshes, input, shaders) — TRACKED
│       └── demo_<name>/           ← per-game content — GITIGNORED, regenerated
├── scripts/
│   ├── play.sh                    ← run via the WINDOWS Godot binary (play/capture/tests)
│   └── run_linux.sh               ← run via the LINUX binary (headless tests + the stdio env)
├── tools/
│   ├── yume_env/                  ← ADR 0060 env: oracle.py, env.py (gym-like), test_env.py
│   ├── yume_codegen/ yume_assetgen/  ← optional authoring-time emitters
│   └── visual_layout/             ← text→2D/3D layout pipelines (HUD/screen/map)
├── docs/                          ← guideline/ (contract 30_*, architecture), adr/NNNN-*, per-game design
├── .claude/                       ← skills (yume-*) + path-scoped rules + plan/
└── CLAUDE.md                      ← full project instructions (read this for conventions)
```

---

## Engine file map (`godot/scripts/engine/`)

The engine is organized into layers. **Read top-to-bottom for a mental model:
core primitives → stores → the tick scheduler → effects → coordinators (boot +
per-frame subsystems) → directors (optional gameplay primitives) → ui →
io (input/output bridges) → qa.**

### `core/` — the seven primitives + the interpreter
| File | Role |
|---|---|
| `entity.gd` | **Primitive #1 Entity** — id, tags, properties (static), state (dynamic), position. |
| `rule.gd` | **Primitive #3 Rule** — `{trigger, query, effect}`; `from_dict` parses + validates JSON. |
| `query.gd` | **Primitive #6 Query** — declarative entity matcher (tags/state/relations/`id`/radius). |
| `phase_scheduler.gd` | **The tick loop** — 4 phases (input → decide → react) + the effect write-buffer + flushes. |
| `effect_apply.gd` | **Primitive #5 Effect** — dispatches an effect dict to a handler in `effects/`. |
| `effects/effect_core.gd` | Foundational verbs: `state_set/add/mul/clamp`, `spawn`, `remove`, `relate`, … |
| `effects/effect_motion.gd` | Motion + spatial verbs: `velocity_set`, `velocity_add_relative`, queries. |
| `effects/effect_actor.gd` | Actor-control + party verbs (switch actor, etc.). |
| `effects/effect_shell.gd` | Engine↔shell boundary verbs: `transition_level/screen`, `save/load_state`, toasts. |
| `effects/effect_adr_extensions.gd` | Later-ADR primitives (build/place, tech, zones, …). |
| `effects/effect_resolution.gd` | Shared target/value resolution for effect handlers. |
| `formula.gd` | Evaluates `"a.state.x + 10"`-style formula strings (whitelisted math). |
| `world.gd` | **Top-level orchestrator.** Owns canonical state; runs `_process` (live) + `advance_one_tick`. |
| `engine_error.gd` · `scripted_policy.gd` | Structured engine errors · in-process scripted-JSON actor AI (ADR 0018). |

### `stores/` — indices the query/relation system reads
`relation_store.gd` (**Primitive #7 Relation** — typed directed edges) ·
`spatial_index.gd` (grid-bucket hash for radius queries) ·
`zone_store.gd` (aggregated zone state, ADR 0031).

### `coordinators/` — boot + per-frame subsystems (extracted from world.gd)
`world_boot.gd` (the boot sequence `load_data()` runs — mounts directors, loads
JSON) · `world_loader.gd` (boot-time JSON parsers) · `spawn_manager.gd` (entity
spawn pipeline) · `physics_body_builder.gd` (builds CharacterBody3D etc. from a
def) · `character_body_runner.gd` (per-entity motion: velocity→position) ·
`ground_constraint.gd` / `ground_renderer.gd` / `grass_renderer.gd` (floor +
biome ground) · `actor_manager.gd` (which entity receives input, ADR 0016) ·
`level_transition_coordinator.gd` / `save_load_coordinator.gd` /
`world_reset_coordinator.gd` (the "pending" pipelines GameShell drains) ·
`variant_overlay.gd` (per-scenario variant overlays).

### `directors/` — optional gameplay primitives (mounted only if content uses them)
animation, lifecycle/aging, schedule, party, faction, class/occupation,
tech-tree, dynasty, chunk-streaming, lighting (day/night), multimesh batching.
Each is one ADR; each is a no-op when no content references it.

### `ui/` — Godot UI built from JSON (reads `hud.json` / `screens.json`)
`game_shell.gd` (the per-frame game-loop host: drives camera, HUD, **and the
pending pipelines** in live play) · `screen_flow.gd` (declarative screen/modal
stack; sets `screen_freeze_world`) · `control_factory.gd` (JSON→Godot Control
tree) · `overlay.gd` (tutorial overlays) · `settings_manager.gd` ·
`widgets/` (`hud_builder`, `camera_director`, `minimap_widget`,
`viewmodel_director`, `win_lose_widget`, `nameplate_renderer`, `bounds_renderer`).

### `io/` — input/output bridges (where the outside world meets the engine)
| File | Role |
|---|---|
| `input_registrar.gd` | Registers `ui/input.json` actions into Godot's InputMap; **`poll()`** reads action state → `scheduler.queue_input`. The one input seam. |
| `capture_runner.gd` | Autoload — `--capture-*`: render a frame / run a step-script, save PNG, quit. |
| `stdio_step_driver.gd` | Autoload — `--stdio-step`: the ADR 0060 env. stdin actions → 1 tick → stdout state (+ optional frame file). |
| `determinism_hash.gd` | `canonical_state_hash` — SHA-256 of canonical world state (the determinism contract). |
| `save_state.gd` · `audio_bus.gd` | Persistence (ADR 0010) · procedural SFX bus. |

### `qa/` — test/automation drivers (all share one execution path)
| File | Role |
|---|---|
| `step_runner.gd` | **The canonical scenario engine.** Interprets `steps[]` verbs (press/hold/click/wait/tick/expect/…). Used by scenario tests, captures, AND the env. |
| `scenario_runner.gd` | `scenes/scenario_test.tscn` entry — loads `tests.json`, runs each scenario through StepRunner. |
| `screen_smoke_runner.gd` | Per-screen headless playability smoke. |

### `libs/` + `util/`
`lib_resolver.gd` (`@lib.*` / `$include` cross-game JSON reuse, ADR 0027) ·
`macro_expander.gd` (rule macros) · `shape_lib`/`mesh_lib` (code-draw libraries) ·
`instance_patterns.gd` (declarative scatter/ring/grid placement — deterministic
per-pattern RNG) · `grid_snap` · `pathfinding` · `build_validators` · `vec3_util`.

### `renderer_2d/` + `renderer_3d/`
`entity_sprite_2d.gd` / `entity_mesh_3d.gd` — **read-only** views: each reads an
entity's `state.position` + `visual` block and draws it. Three-tier fallback
(authored mesh/sprite → shape-lib primitive → colored box). The renderer never
writes engine state.

---

## How a game runs — the flows

### Boot
```
scenes/play.tscn (or <game>_3d.tscn)  →  World._ready()
  → (auto_start) start() → load_data()
      → world_boot.run():  mount directors · register ui/input.json actions
        · load entities/ + world/rules/ + scene.json + screens.json
        · spawn initial_instances (+ expand instance_patterns)
  → GameShell + ScreenFlow + 12 other directors mounted as siblings of World
```

### Per frame (live play) — `world.gd::_process(delta)`
```
_poll_input()                  → InputRegistrar.poll → queue this frame's input
_ground_constraint.apply()
scheduler.fire_frame_tick()    → ADR 0050 per-frame content rules
if _tick_due(delta):           → drain the real-time accumulator (fixed sim rate)
    advance_one_tick()
GameShell (separate _process)  → drains pending pipelines (level/save/reset) + camera + HUD
```

### Per tick — `world.gd::advance_one_tick()`  (the canonical tick body)
```
_tick_count++                              (ws._tick — read by velocity auto-reset)
actor_manager.tick_policies()              AI (ADR 0018), if an actor_manager exists
scheduler.tick()                           ← the 4-phase rule loop (below)
lifecycle/chunk directors
trajectory + determinism-hash log          (opt-in)
```

### The phase loop — `phase_scheduler.gd::tick()`
```
input  phase: fire rules whose trigger == {input, action} for queued actions → flush
decide phase: fire tick rules (interval) → flush
react  phase: fire signal/contact rules → flush
```
Effects don't mutate state directly; they go to a write-buffer that **flushes**
at phase boundaries, so a later phase sees the earlier phase's results (the
blocker-pattern guarantee, tech-director Invariant #9).

---

## The input flow (live vs scripted vs Python env)

**All three input sources converge at the *polled action state* → `InputRegistrar.poll`
→ `scheduler.queue_input`.** They are NOT unified as synthesized `InputEvent`s —
the seam is one level below events (the `Input.is_action_pressed` / `_just_pressed`
state that real keys *and* `Input.action_press()` both set). See ADR 0060 Phase 1
notes for why (`parse_input_event` needs fragile frame-timing in the synchronous
stepping loop; `action_press` is immediate).

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

**Two JSON maps make this game-agnostic:**
- `data/<game>/ui/input.json` — **key → action name** (+ `edge: press|hold`).
  `InputRegistrar` registers these into Godot's InputMap and into the engine's
  `input_actions_press` / `input_actions_hold` poll lists.
- `data/<game>/world/rules*.json` — **action → effect**, via a rule
  `{trigger:{type:"input", action:"X"}, query:{…}, effect:[…]}`.

So the engine is the interpreter: it never knows what "move_north" *means* — it
just routes the action to whatever rule the JSON wired to it.

**Why three drivers, one seam:** live play drives ticks from `_process` (per
frame); scenario/capture/env disable `_process` and drive ticks themselves
(sole driver), so they set the action state via `action_press()` and call the
same `poll()`. Below the poll seam, a scripted key is identical to a real one.
(Caveat: scripted input does *not* flow through Godot's `_input`/`_gui_input`
event pipeline — UI buttons are driven by StepRunner's `click` verb instead.)

---

## The three runtimes

| Runtime | Binary | Used for |
|---|---|---|
| **`scripts/play.sh`** | Windows Godot (`.exe` via WSL) | play, captures, unit/scenario tests — the authoritative path |
| **`scripts/run_linux.sh`** | native Linux Godot | fast headless tests + the env; no `/mnt/c` round-trip, no WSL-pipe flakiness |
| **`tools/yume_env/env.py`** | native Linux Godot | the ADR 0060 stepping env (Python orchestrator) |

Both binaries are the same build (`14d19694e`); the Linux one exists because
Windows-via-WSL can't do reliable stdin/stdout piping or `/dev/fd`. See CLAUDE.md
for the exact invocation (always `cd "$TEMPLATE_DST"` + `--path .`, never an
absolute `--path`, which silently aborts).

### The Python env (ADR 0060)
```python
from tools.yume_env.env import YumeEnv
env = YumeEnv("demo_sokoban")          # or frames=True for pixel observations
env.reset()
obs = env.step(["move_north"])         # {"tick","hash","state"} (+ "frame" if frames=True)
env.close()
```
One stdin JSON line = exactly one tick = one stdout state line. Two **separate**
observe channels: **state** (JSON + canonical hash, on stdout — the evaluator's
"ground truth") and **frame** (raw RGBA8 to a file, opt-in — a future pixel
agent's "eyes"). Determinism is verifiable: `tools/yume_env/oracle.py` runs a
demo twice and diffs per-tick hashes.

---

## Data layer (per game, `godot/data/demo_<name>/`)

```
entities/*.json     definitions (tags/properties/state_init/visual) + initial_instances
world/rules*.json   the mechanics — {trigger, query, effect} rules
world/state.json    initial _engine/world_state singletons
game/goals.json     win/lose/score · game/flow.json multi-level progression
scene.json          camera + lighting + ground + tick_seconds
ui/input.json       key→action map      hud.json   HUD layout      screens.json  menus/modals
audio/cues.json     event→SFX           tests.json scenario tests (steps[])
```
`data/lib/` holds shared, TRACKED JSON (`shapes.json`, `meshes.json`,
`input/universal.json`, shaders) that games `$include` via `@lib.*` (ADR 0027).

---

## Known gaps / what's lacking

An honest list of where the framework is thin or demo-grade.

| Area | Gap |
|---|---|
| **Networking** (newest, most demo-grade) | Pure server-authoritative → **no client-side prediction** (your own character has round-trip input latency), no lag compensation. **LAN/localhost only** — no NAT/relay/matchmaking, no reconnection, no persistence of multiplayer state. Only the **walk-shell** is networked; the real genre games (merchant, shooter, …) aren't net-tested. |
| **Headless-render fidelity** | The truly-windowless `--headless-render` path is a custom Godot patch on **4.7-beta**, so it can't load our **4.6.1** assets (renders boxes) — needs porting to 4.6.1. The Xvfb path works (real meshes, no window) but is GPU-readback-bound in WSL (fast on a native-GPU Linux box). |
| **Animation** | No validator that a declared `animation_clip` exists in the mesh (mismatch silently falls back → "laggy"; bit us in `tiny_village`). `anim_phase` is fixed-cadence, not speed-proportional → foot-sliding at speed. No blend trees, IK, or root motion. |
| **Formula / query** | Ternary `a if c else b` is **broken** in Godot 4.6.1's Expression. `self.nearest({…})` is **not implemented** — no spatial query inside formulas (use a `contact` trigger instead). |
| **Pipelines** | The 3 generation layers no longer clobber (ADR 0067 — `/yume-design --scene` reuses `compose_world` cleanly). Remaining: re-running `compose_world`/`compose_shell` regenerates the World/shell files, so hand-edits to those (not the game's own `entities/<slug>.json` / `world/rules/`) are overwritten; and `/yume-create-scene`'s walk-shell still conflicts if run on a `/yume-design` game folder (use `--scene` instead). |
| **Authoring / UX** | No in-engine visual editor (everything is JSON + skills); input is keyboard/mouse/gamepad — **no touch/mobile** path. |
| **AI / audio** | LLM-driven NPC behavior (ADR 0020 external-agent IPC) is a seam, not a shipped feature; audio is procedural SFX + cues — music/BGM is thin. |

---

## Where to read more

- `docs/guideline/30_framework_primitives.md` — the engine contract (invariant-bearing)
- `docs/adr/` — architectural decisions (e.g. ADR 0021 expose-don't-reimplement,
  ADR 0039 step-runner, ADR 0060 deterministic I/O + env)
- `.claude/rules/` — path-scoped invariants (engine-scripts, data-demo, …)
- `CLAUDE.md` — conventions, the run workflow, the post-mortem ritual
