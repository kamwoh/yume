# Yume (夢) — JSON-driven game framework on Godot

You are working on **Yume**: a JSON-declarative content layer over Godot
4.6.1 that lets non-programmers (and LLMs) generate working games without
writing GDScript per-game. Per ADR 0021, the engine ships a fixed verb
set (the "seven primitives" + a small interpreter); each game's mechanics
are pure JSON.

## Quick Start

This repo ships the **framework** (engine, skills, scaffolding scenes,
shared engine libraries). It does NOT ship game demos. Demos live at
`godot/data/demo_<name>/` and are gitignored.

```
/yume-design "<prose pitch>" [--scene] [--with-assets] [--style=] [--name=<slug>] [--autonomous]
./scripts/play.sh <name>            # run a demo (falls back to scenes/play.tscn --game=<name>)
./scripts/play.sh <name> --capture  # auto-capture for visual QA
```

`/yume-design` is the single entry point (ADR 0067). It composes a game from
three layers with disjoint file ownership: **World** (`--scene`,
`compose_world`), **Game** (always, the game skills), and **Assets**
(`--with-assets`, `yume_assetgen`). A flag whose API key is missing degrades
to the key-free code-drawn game. The layer/file ownership table lives in the
`yume-design` skill.

Do NOT run `/yume-create-scene` on a `/yume-design` game folder. Its shell
overwrites the game's mechanics. Use `/yume-design --scene` to get a world
for a game.

## Framework structure

```
yume/
├── .claude/                            ← Skills + rules + settings
│   ├── skills/yume-*/SKILL.md          (40 specialist skills, Tier 2.6)
│   └── rules/                          (path-scoped invariants)
├── godot/    ← Godot project (engine + scaffolding; demos gitignored)
│   ├── data/                           ← shared engine libraries (TRACKED)
│   │   ├── shapes.json                 (code-draw shape library)
│   │   ├── meshes.json                 (3D mesh library)
│   │   └── sounds.json                 (procedural SFX library)
│   ├── data/demo_<name>/               (per-game content — NOT TRACKED, gitignored)
│   │   ├── entities/                   (definitions + initial instances)
│   │   ├── world/rules/*.json          (ALL rules — globbed + merged; ADR 0009 rev 2026-05-16)
│   │   │                               (legacy single-file `world/rules.json` +
│   │   │                                `game/goals.json` still load — 2 demos use them —
│   │   │                                but the directory form is canonical for new games)
│   │   ├── game/flow.json              (multi-level progression — ADR 0006)
│   │   ├── levels/<n>/                 (per-level entities + rules)
│   │   ├── world/state.json            (initial _engine entity state — ADR 0047)
│   │   ├── world/zones.json            (zone-state primitive — ADR 0031, optional)
│   │   ├── audio/cues.json             (semantic-event → SFX mapping)
│   │   ├── ui/strings.json             (localizable text)
│   │   ├── scene.json                  (camera + lighting + ground + tick_seconds)
│   │   ├── screens.json                (title/pause/etc. — ADR 0011, optional)
│   │   ├── save_policy.json            (what persists — ADR 0010, optional)
│   │   ├── settings_schema.json        (settings — ADR 0013, optional)
│   │   └── tutorial.json               (overlay sequencing — ADR 0012, optional)
│   ├── scripts/engine/                 (engine: rule, query, effect, scheduler, etc.)
│   ├── scenes/                         (TRACKED scaffolding only)
│   │   ├── play.tscn                   (universal launcher — `--game=<name>`)
│   │   ├── test_main.tscn              (engine unit tests)
│   │   └── scenario_test.tscn          (per-game scenario test runner)
│   └── project.godot
├── docs/                               ← Documentation (active)
│   ├── guideline/                      (30 contract · 31 pipeline plan · 32 MDA · 33 architecture)
│   ├── adr/NNNN-*.md                   (architecture decisions)
│   ├── engine-reference/               (api manifest, Godot pinning)
│   ├── games/<name>/                   (per-game GDDs, plans, reviews)
│   └── timeline/                       (decision diary)
├── scripts/play.sh                     ← Run a demo (sync + launch)
├── tools/gen_api_manifest.py           ← Regenerate engine API manifest
└── CLAUDE.md (this file)

(Planning workspace — `task_plan.md`, `.claude/plan/{backlog,archive}.md`,
`docs/`-bound design notes — is the author's LOCAL, gitignored scratch; not
in a fresh clone. The framework's shared config lives in CLAUDE.md +
`.claude/rules/` + `.claude/skills/`.)
```

## How the engine works

Yume is **primitives + interpreter** (Invariant #8). The engine ships a
fixed vocabulary in GDScript; all game-specific behavior lives in JSON.

**Seven primitives** (ADR 0001):

1. **Entity** — JSON dict with id, tags, properties, state, position
2. **Tag** — string membership label (no class hierarchy)
3. **Rule** — `{trigger, query, effect}` triple
4. **Trigger** — when (tick / contact / signal / input / spawn / despawn / relation_changed)
5. **Effect** — what (state_set / spawn / remove / transform / relate / velocity_set / emit / ... — full list in `docs/engine-reference/api-manifest.json`)
6. **Query** — entities matching tags + state + radius + relations
7. **Relation** — typed directed edge between entities

**ADR 0021** (foundational): Yume = JSON layer over Godot. Engine never
reimplements what Godot already does well — it EXPOSES Godot's
capabilities through JSON-declarative primitives. Each new capability
is a "capability-exposure ADR" (e.g. ADR 0011 for Control nodes, ADR
0010 for FileAccess+JSON, future ADR 0022 for PhysicsServer3D).

## Two clocks: the heartbeat and the calendar (2026-05-16, amended 2026-08-16)

The engine has **two** clocks. They are syntactically distinct so a rule
can never ambiguously belong to both — `interval` on `tick`, `every` on
`scheduled`. Picking the wrong one fails quietly (the rule fires at the
wrong rate rather than erroring), so pick deliberately.

**1. The heartbeat — `trigger: tick`, counted in ticks.**

**The tick is the engine's clock — never change it as a balance knob.**
- Default `tick_seconds = 0.0167` (60Hz, matches Godot `physics_fps`).
  Override only per-genre + deliberately (sokoban 10Hz, shooter 120Hz),
  never per-bug.
- Too fast/slow? Scale the rule's `interval`, NOT the tick. `interval`
  is in ticks: "every second" at 60Hz = 60. Changing `tick_seconds`
  silently rescales what every `interval` MEANS in real time.

Use it for anything that must feel continuous: movement, collision,
input, animation, camera.

**2. The calendar — `trigger: scheduled`, counted in calendar units
(ADR 0078).**

Calendar units have **no real-time duration**. They advance only when an
`advance_time {units: N}` effect says so, which runs the `scheduled`
bucket N times synchronously — the world genuinely simulates those units
while the player waits a fraction of a real second.

```jsonc
{"trigger": {"type": "scheduled", "every": 30}}   // every 30th unit
{"type": "advance_time", "units": 6}              // travel costs 6 days
```

`advance_time` does NOT run the `tick` bucket. What a unit MEANS (a day,
a turn, a production cycle) is content's decision — the engine has no
idea. Use it for action-cost time: travel, training, resting, and
long-horizon world simulation.

Do NOT express calendar time on the heartbeat. At 60Hz an in-game day is
`interval: 57600`, and there is no `interval` value at all that can say
"advance six days now".

**Press vs hold** = input INTENT, not genre (every game has both):
`edge: "press"` fires once on key-down (menu, use, restart);
`edge: "hold"` fires every tick held (move, sprint, aim).

**`_process` vs `_physics_process`**: display-rate work (camera
smoothing, HUD) in `_process`; fixed-rate work (move_and_slide,
collision, **the sim-tick accumulator** — ADR 0068, **and the input
poll** — ADR 0069) in `_physics_process`. Input polls once per physics
step so a held key fires once per sim tick at ANY render fps — polling
per frame made hold strength frame-rate-dependent (autorace W/S dead at
8 fps vs per-tick drag, 2026-06-11). Rules, body integration, and input
share the physics clock so they can never skew under load. Don't mix.

## Key files for editing

| Edit | Path |
|---|---|
| Engine logic | `godot/scripts/engine/*.gd` |
| Game content | `godot/data/demo_<name>/*.json` |
| Scene launcher | `godot/scenes/<name>_<dim>.tscn` (thin stub: World + Camera + data_root) |
| New ADR | `docs/adr/NNNN-<title>.md` |
| Skill instructions | `.claude/skills/yume-*/SKILL.md` |
| Python rule emitter | `tools/yume_codegen/` (optional; emits same JSON shape) |
| Asset-gen pipeline | `tools/yume_assetgen/` (textures + meshes via Backend) |

Per-game `.tscn` files are intentionally minimal (~12 lines). WorldBoot
auto-mounts 9 sibling Director Nodes (GameShell, ScreenFlow,
OverlayManager, SettingsManager, LightingDirector, ScheduleDirector,
LifecycleDirector, NameplateRenderer, ScreenSmokeRunner).
Sky/Sun/WorldEnvironment come from `scene.json`'s lighting block via
LightingDirector; floor plane comes from `scene.json`'s ground.mesh
block via GroundRenderer. A .tscn just pins `data_root` + picks
`renderer_script` + places a Camera.

## Running Godot (full procedure: `docs/engine-reference/running-godot.md`)

```bash
eval "$(grep -E '^(GODOT_BIN|TEMPLATE_DST)=' scripts/play.sh)"
cp -r godot/. "$TEMPLATE_DST/" && cd "$TEMPLATE_DST"
"$GODOT_BIN" --path . --headless --import          # only after a NEW class_name or new assets
"$GODOT_BIN" --path . --headless scenes/test_main.tscn 2>&1 | tee /tmp/test_out.log
"$GODOT_BIN" --path . --headless scenes/scenario_test.tscn -- --game=demo_<name> 2>&1 | tee /tmp/scen_out.log
```

- ALWAYS `cd "$TEMPLATE_DST"` and use `--path .`. An absolute `--path` aborts
  with "Invalid project path" and prints no test output.
- A real run ALWAYS ends with `passed: NN  failed: N  total: NN`. No output
  is NOT a pass.
- `test_main.tscn` takes 60-120 s. Use a timeout of 240 s or more.

## Yume design principles

### 1. Data drives everything (Invariant #1)
All game-specific behavior is JSON. The engine has no game-specific
GDScript. Adding a new game = writing JSON; never editing engine code.

### 2. Engine = primitives + interpreter (Invariant #8)
The engine is a fixed verb set. New game wants behavior X? Either
compose existing verbs OR propose a new primitive via ADR. Never bake
game-specific logic into engine code.

### 3. Expose, don't reimplement (ADR 0021)
Godot already does UI, audio, physics, animation, particles, pathfinding.
Yume EXPOSES these through JSON primitives. We compose Godot's
capabilities; we don't replicate them.

### 4. Test-driven engine
Every primitive lands with unit tests in `test_runner.gd`. Every game
demo gets scenario tests covering core verbs. Visual gate (capture +
review) for any rendering primitive. Effect-chain gate for any
state-mutating effect.

## Behavioral posture (karpathy-guidelines)

Apply on every non-trivial change:

1. **Think Before Coding** — surface assumptions, present alternatives, ask when unclear
2. **Simplicity First** — minimum code that solves the problem, no speculative abstractions
3. **Surgical Changes** — touch only what traces to the request, don't drive-by-refactor
4. **Goal-Driven Execution** — define success criteria up front, loop until verified

See `karpathy-guidelines` skill for details.

## Collaboration protocol

When making non-trivial changes, follow **Question → Options → Decision → Draft → Approval**:

1. **Question.** State what's being decided in one sentence. Include known constraints.
2. **Options.** Present 2-3 alternatives. For each: cost, blast radius, tradeoff.
3. **Decision.** State which one and why. Brief.
4. **Draft.** Show the change — file paths, key snippets, the diff shape. Don't apply yet.
5. **Approval.** Wait for explicit go-ahead before writing files / running destructive commands.

Skip 1-3 for trivial edits (typo, single-line fix). New primitives,
deletions, schema changes, infra moves require all five.

## Rules (`.claude/rules/`, index: `.claude/RULES_INDEX.md`)

Only `post-mortem.md` loads on every turn. The other rules load in FULL
when you work on a file that matches their `paths:` frontmatter. The
one-line essences below exist so that you know a rule applies before
its files load. Do not copy rule content into this file.

| Rule | Loads for | One-line essence |
|---|---|---|
| `post-mortem.md` | every turn | Every user-found bug: fix → name the gate that should have caught it → harden that gate (enforceable check, not "be careful") → commit both. **The gate is not optional.** |
| `soul.md` | `docs/games/**`, demo data | Games targeting Fellowship / Narrative / Submission / Discovery / Sensation need all 5 layers (writing, visual, audio, juice, reactive) on every signature beat, all pulling the same direction. |
| `visual-qa.md` | content, scenes, renderers, UI, asset/layout tools | Any change to what the player SEES: frame the feature, capture, read with 3-5 falsifiable criteria. "Tests pass" is correctness, not playability. |
| `engine-scripts.md` | `godot/scripts/engine/**` | No semantic effects, no entity subclasses, no genre code. Plus the visual gate and the effect-chain gate (destructive effects LAST). |
| `data-demo.md` | `godot/data/**` | Schema discipline: field-name landmines, formula bindings per trigger, no per-def escape hatches. |
| `pipeline-stability.md` | `tools/visual_layout/**` + HUD/screen/map author skills | 2D HUD/screen pipelines are LOCKED (ADR to modify). 3D map/world pipelines are active. |
| `tests.md` | `godot/scripts/engine/tests/**` | Tests ship with the phase; no third-party framework; never disable a failing test. |
| `docs.md` | `docs/**` | The contract doc is ADR-gated. Date living docs. |

`tools/validators/validate_claude_config.py` fails if a rule uses `globs:`
(Claude Code ignores it). Empirical case 2026-10-15: all rules used
`globs:`, so all 9 files loaded on every turn.

## Godot API reference (pinned)

When proposing GDScript code, verify against `docs/engine-reference/godot/`:

- `VERSION.md` — pinned to Godot 4.6.1.stable
- `current-best-practices.md` — observed working idioms (class_name, Expression, RegEx, etc.)
- `deprecated-apis.md` — Godot 3 → 4 migration hazards + LLM-cutoff trip-wires

Common LLM-era pitfalls: `Reference` (gone — use `RefCounted`),
`connect("foo", self, ...)` (gone — use `signal.connect(callable)`),
`OS.get_ticks_msec()` (use `Time.*`).

## Authoring-time Python emitters (ADR 0051)

JSON stays canonical; two OPTIONAL `tools/` emitters produce it (mix with
hand-authoring freely):
- **`tools/yume_codegen/`** — typed rule/entity/screen/lib_ref builders;
  catches recurring bug classes (brace-wrapped bindings, wrong binding
  names, schema landmines) at author-time. `python3 -m tools.yume_codegen`
  = smoke test.
- **`tools/yume_assetgen/`** — AI texture+mesh pipeline; reads
  `data/<game>/asset_gen.json`, scans `*_prompt` fields, dispatches to a
  backend (openai_images / tripo3d / …), patches defs with `res://` paths.
  `python3 -m tools.yume_assetgen <game> [--dry-run|--init]`.

Engine support: `entity_mesh_3d.gd` reads `visual.albedo_texture` +
dict-form `material_overrides` ({albedo_color, albedo_texture,
normal_texture, roughness, metallic}). See each package's README.

## Read More

- `docs/guideline/30_framework_primitives.md` — the engine contract (invariant-bearing)
- `docs/guideline/31_text_to_game_pipeline.md` — strategic plan + CCGS analysis
- `docs/guideline/32_mda_for_yume.md` — design vocabulary
- `docs/adr/README.md` — index of architectural decisions
- `docs/adr/0046-animation-via-godot-animation-player.md` — animation primitive
- `docs/adr/0051-authoring-time-python-emitters.md` — codegen + assetgen rationale
- `tools/yume_codegen/README.md` — rule/entity/screen JSON builders
- `tools/yume_assetgen/README.md` — texture + mesh generation flow
- Planning/backlog/decision-log is the author's LOCAL workspace (`task_plan.md` + `.claude/plan/`, gitignored) — not in a fresh clone.
