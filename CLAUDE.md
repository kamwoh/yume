# Yume (夢) — JSON-driven game framework on Godot

You are working on **Yume**: a JSON-declarative content layer over Godot
4.6.1 that lets non-programmers (and LLMs) generate working games without
writing GDScript per-game. Per ADR 0021, the engine ships a fixed verb
set (the "seven primitives" + a small interpreter); each game's mechanics
are pure JSON.

## Quick Start

This repo ships the **framework** (engine, skills, scaffolding scenes,
shared engine libraries) but NOT specific game demos. Demos live at
`godot/data/demo_<name>/` and are gitignored — generate locally via the
pipeline below or copy from another working tree.

To generate a new game from a prose pitch:

```
/yume-design "a roguelike where vampires steal HP from light sources" --autonomous
```

The `/yume-design` skill orchestrates text → GDD → world plan → level
design → rules → JSON → assets → QA. Output lands at
`godot/data/demo_<slug>/`.

To run a locally-generated demo:

```bash
./scripts/play.sh <name>            # falls back to scenes/play.tscn --game=<name>
./scripts/play.sh <name> --capture  # auto-capture for visual QA
```

## Framework structure

```
yume/
├── .claude/                            ← Skills + rules + settings
│   ├── skills/yume-*/SKILL.md          (28 specialist skills, Tier 2.6)
│   └── rules/                          (path-scoped invariants)
├── godot/    ← Godot project (engine + scaffolding; demos gitignored)
│   ├── data/                           ← shared engine libraries (TRACKED)
│   │   ├── shapes.json                 (code-draw shape library)
│   │   ├── meshes.json                 (3D mesh library)
│   │   └── sounds.json                 (procedural SFX library)
│   ├── data/demo_<name>/               (per-game content — NOT TRACKED, gitignored)
│   │   ├── entities/                   (definitions + initial instances)
│   │   ├── world/physics.json          (world physics rules — ADR 0009)
│   │   ├── game/rules.json             (game logic — win/score/transition)
│   │   ├── game/flow.json              (multi-level progression — ADR 0006)
│   │   ├── levels/<n>/                 (per-level entities + rules)
│   │   ├── world/state.json            (initial world_state)
│   │   ├── audio/cues.json             (semantic-event → SFX mapping)
│   │   ├── ui/strings.json             (localizable text)
│   │   ├── scene.json                  (camera + bounds + tick_seconds)
│   │   ├── hud.json                    (HUD elements)
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
│   ├── 30_framework_primitives.md      (the contract — invariant-bearing)
│   ├── 31_text_to_game_pipeline.md     (Tier 2.5 strategic plan)
│   ├── 32_mda_for_yume.md              (Mechanics → Dynamics → Aesthetics)
│   ├── adr/NNNN-*.md                   (architecture decisions)
│   ├── engine-reference/               (api manifest, Godot pinning)
│   ├── games/<name>/                   (per-game GDDs, plans, reviews)
│   └── timeline/                       (decision diary)
├── scripts/play.sh                     ← Run a demo (sync + launch)
├── tools/gen_api_manifest.py           ← Regenerate engine API manifest
├── task_plan.md                        ← Durable backlog
└── CLAUDE.md (this file)
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

## Key files for editing

| Edit | Path |
|---|---|
| Engine logic | `godot/scripts/engine/*.gd` |
| Game content | `godot/data/demo_<name>/*.json` |
| Scene launcher | `godot/scenes/<name>_2d.tscn` |
| New ADR | `docs/adr/NNNN-<title>.md` |
| Skill instructions | `.claude/skills/yume-*/SKILL.md` |

## Creating a new game

```
/yume-design "<prose pitch>" --name=<slug> --autonomous
```

This orchestrates:
1. yume-game-designer → GDD
2. yume-game-reviewer → 13-axis depth review
3. yume-game-planner → world plan (named NPCs, items, events)
4. yume-level-designer → spatial layout with coordinates
5. yume-systems-designer → world physics rule sketches
6. yume-game-rules-designer → win/lose/scoring rules
7. yume-content-designer → JSON content
8. yume-asset-designer → visual + audio fields
9. yume-qa-tester → headless cascade verification + visual capture

For "complete game" tier (shell, save, tutorial, settings, audio,
juice), additional skills compose: yume-screen-flow-designer,
yume-save-policy-designer, yume-tutorial-designer, yume-audio-designer,
yume-juice-designer.

## Running tests

```bash
# Sync framework to Godot test project + run unit tests
cp -r godot/. /mnt/c/.../YumeTemplate/
godot --headless --path C:/.../YumeTemplate scenes/test_main.tscn
```

Should report `passed: NN  failed: 0  total: NN`. Test source:
`godot/scripts/engine/tests/test_runner.gd`.

Per-game scenario tests:
```bash
godot --headless --path C:/.../YumeTemplate scenes/scenario_test.tscn -- --game=demo_sokoban
```

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

## Path-scoped rules

When editing files matching certain globs, **read the corresponding rule first**:

| File pattern | Rule file |
|---|---|
| `godot/scripts/engine/**` | `.claude/rules/engine-scripts.md` |
| `godot/data/**` | `.claude/rules/data-demo.md` |
| `docs/**` | `.claude/rules/docs.md` |
| `godot/scripts/engine/tests/**` | `.claude/rules/tests.md` |

See `.claude/rules/README.md` for the index.

**Visual validation gate** — when modifying rendering primitives
(control_factory, screen_flow, overlay, renderer_2d/*, renderer_3d/*,
game_shell HUD/camera sections), run `--capture` + `yume-visual-designer`
review BEFORE committing. "I'll fix it next pass" is not a merge
condition. Details: `.claude/rules/engine-scripts.md` § visual gate.
Tech-director enforces at merge gate.

**Effect-chain validation gate** — when adding/modifying effects that
touch screen / scene / save lifecycle (`transition_screen`,
`transition_level`, `reload_scene`, `save_state`, `load_state`,
`quit_app`), trace every on_click/on_press chain end-to-end. Destructive
effects must be LAST in their chain — anything queued after is silently
dropped. Details: `.claude/rules/engine-scripts.md` § effect-chain gate.

## Godot API reference (pinned)

When proposing GDScript code, verify against `docs/engine-reference/godot/`:

- `VERSION.md` — pinned to Godot 4.6.1.stable
- `current-best-practices.md` — observed working idioms (class_name, Expression, RegEx, etc.)
- `deprecated-apis.md` — Godot 3 → 4 migration hazards + LLM-cutoff trip-wires

Common LLM-era pitfalls: `Reference` (gone — use `RefCounted`),
`connect("foo", self, ...)` (gone — use `signal.connect(callable)`),
`OS.get_ticks_msec()` (use `Time.*`).

## Read More

- `docs/30_framework_primitives.md` — the engine contract (invariant-bearing)
- `docs/31_text_to_game_pipeline.md` — strategic plan + CCGS analysis
- `docs/32_mda_for_yume.md` — design vocabulary
- `docs/adr/README.md` — index of architectural decisions
- `task_plan.md` — durable backlog (mirrors session TaskList)
