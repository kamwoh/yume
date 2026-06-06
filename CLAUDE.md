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
│   │   ├── world/rules.json          (world physics rules — ADR 0009)
│   │   ├── game/goals.json             (game logic — win/score/transition)
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
│   ├── 30_framework_primitives.md      (the contract — invariant-bearing)
│   ├── 31_text_to_game_pipeline.md     (Tier 2.5 strategic plan)
│   ├── 32_mda_for_yume.md              (Mechanics → Dynamics → Aesthetics)
│   ├── adr/NNNN-*.md                   (architecture decisions)
│   ├── engine-reference/               (api manifest, Godot pinning)
│   ├── games/<name>/                   (per-game GDDs, plans, reviews)
│   └── timeline/                       (decision diary)
├── scripts/play.sh                     ← Run a demo (sync + launch)
├── tools/gen_api_manifest.py           ← Regenerate engine API manifest
├── task_plan.md                        ← Index → .claude/plan/{backlog,archive}.md
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

## Tick rate is the engine's heartbeat (2026-05-16)

**The tick is the engine's clock — never change it as a balance knob.**
- Default `tick_seconds = 0.0167` (60Hz, matches Godot `physics_fps`).
  Override only per-genre + deliberately (sokoban 10Hz, shooter 120Hz),
  never per-bug.
- Too fast/slow? Scale the rule's `interval`, NOT the tick. `interval`
  is in ticks: "every second" at 60Hz = 60; "every in-game hour"
  (1hr=40s) = 2400. Changing `tick_seconds` silently rescales what every
  `interval` MEANS in real time.

**Press vs hold** = input INTENT, not genre (every game has both):
`edge: "press"` fires once on key-down (menu, use, restart);
`edge: "hold"` fires every tick held (move, sprint, aim).

**`_process` vs `_physics_process`**: display-rate work (input sampling,
camera smoothing, HUD, tick accumulator) in `_process`; fixed-rate
physics (move_and_slide, collision) in `_physics_process`. Don't mix.

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
auto-mounts 14 sibling Director Nodes (GameShell, ScreenFlow,
OverlayManager, SettingsManager, LightingDirector, PartyDirector,
ScheduleDirector, LifecycleDirector, ClassManager, FactionDirector,
TechTreeDirector, DynastyDirector, NameplateRenderer, ScreenSmokeRunner).
Sky/Sun/WorldEnvironment come from `scene.json`'s lighting block via
LightingDirector; floor plane comes from `scene.json`'s ground.mesh
block via GroundRenderer. A .tscn just pins `data_root` + picks
`renderer_script` + places a Camera.

## Generation pipelines — one orchestrator, three layers (ADR 0067)

`/yume-design` is the single entry point. A game is composed from **three
layers with disjoint file ownership**, so they never clobber each other:

| Layer | `/yume-design` flag | Owns (writes only these) | Tool |
|---|---|---|---|
| **World** (the 3D stage) | `--scene` | `scene.json`, `game/flow.json`, `world/state.json`, `levels/level_default/entities.json`, `entities/auto_gen.json`, `assets/{layouts,textures}/` | `compose_world` |
| **Game** (the play) | (always) | `world/rules/*.json`, `game/goals.json`, `entities/<slug>.json` (player + dynamic defs + instances), `hud.json`, `audio/`, `screens.json`, `ui/` | the game skills |
| **Assets** (the look) | `--with-assets` | `asset_gen.json`, `assets/generated/`, in-place `visual.*` patches | `tools.yume_assetgen` |

```
/yume-design "<pitch>"  [--scene]  [--with-assets]  [--style=] [--name=] [--autonomous]
```

- **No flags** → key-free code-drawn single-player game (the default — this
  is also the no-API-key fallback; the gen flags below DEGRADE to it).
- **`--scene`** → run `compose_world` FIRST as the World layer; the game's
  mechanics layer ONTO that world. The engine globs `entities/*.json` +
  `world/rules/*.json` and merges by id, so the game's `entities/<slug>.json`
  + `world/rules/*.json` spawn into the world's level for free — provided the
  Game layer does NOT overwrite the World-owned files above (it doesn't; the
  `/yume-design` SKILL enforces this per-phase). Needs image-gen keys.
- **`--with-assets`** → after the game is built, auto-run `yume_assetgen` to
  replace code-draw visuals with generated textures + meshes. Needs keys.

**No API keys?** `--scene` (needs `OPENAI_API_KEY`) and `--with-assets` (needs
an image key + `TRIPO_API_KEY`) are best-effort: `/yume-design` Phase 0
prechecks env and DROPS a flag whose key is missing — degrading to the
key-free code-draw game with a warning, never a crash.

**`compose_shell` is NOT run inside `/yume-design`** — the game provides the
player, movement, and camera. `/yume-create-scene` (`compose_world` +
`compose_shell`) remains the standalone tool for a scene-only *walkable
diorama* (it DOES emit a walk/jump/sprint shell). Don't run
`/yume-create-scene` on a `/yume-design` game folder — that's the one
remaining clobber (its shell overwrites the game's mechanics); use
`/yume-design --scene` to get a world for a game.

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

## Running Godot (tests / scenarios / captures)

`scripts/play.sh` is the single source of truth for `GODOT_BIN` and
`TEMPLATE_DST`. Both are env-overridable: `YUME_GODOT_BIN`,
`YUME_TEMPLATE_DST`. Source them in any other workflow:

```bash
eval "$(grep -E '^(GODOT_BIN|TEMPLATE_DST)=' scripts/play.sh)"
# Now $GODOT_BIN and $TEMPLATE_DST are set.
```

### Standard 3-step workflow

```bash
eval "$(grep -E '^(GODOT_BIN|TEMPLATE_DST)=' scripts/play.sh)"

# 1. Sync framework to template (orchestrator-only per parallel-execution discipline)
cp -r godot/. "$TEMPLATE_DST/"

# 2. cd INTO the template, then use `--path .`. The Windows Godot.exe CANNOT
#    resolve a `/mnt/c/...` path passed to `--path` from a /home CWD — it
#    aborts with "Invalid project path specified ... aborting" and prints NO
#    test output. play.sh + tools/yume_env/oracle.py both cd + `--path .` for
#    exactly this reason. NEVER use `--path "$TEMPLATE_DST"` (absolute).
cd "$TEMPLATE_DST"

# 3. Rebuild class cache if a NEW `class_name X` GDScript was added (otherwise skip)
"$GODOT_BIN" --path . --headless --import 2>&1 | tail -5

# 4. Run tests / scenarios / captures (always tee; direct stdout from the
#    Windows .exe through WSL pipes is unreliable)
"$GODOT_BIN" --path . --headless scenes/test_main.tscn 2>&1 | tee /tmp/test_out.log
"$GODOT_BIN" --path . --headless scenes/scenario_test.tscn -- --game=demo_<name> 2>&1 | tee /tmp/scen_out.log
"$GODOT_BIN" --path . --rendering-driver opengl3 scenes/<name>_3d.tscn -- --capture-after=4 --capture-output='user://x.png' 2>&1 | tee /tmp/cap.log
```

> **Invalid-project-path trap (2026-05-30).** If a run prints
> `Invalid project path specified: "/mnt/c/..." aborting` and **no
> RESULTS line**, you used the absolute `--path` form — the run never
> executed. "No output" is NOT a pass. A real run ALWAYS ends with
> `passed: NN  failed: N  total: NN`. Re-run with `cd "$TEMPLATE_DST"`
> + `--path .`. (Empirical: this silently masked an `instance_patterns`
> parse error for an hour — every "verification" aborted, read as clean.)

Unit tests should report `passed: NN  failed: 0  total: NN`. Test source:
`godot/scripts/engine/tests/test_runner.gd`; per-game scenarios in
`godot/data/demo_<name>/tests.json`. Gotchas:

- **Long runs**: test_main.tscn takes 60-120s — bump `timeout` to ≥240 or
  run in background + Monitor (`until grep -qE "passed:|RESULTS|ERROR" /tmp/f; do sleep 2; done`).
- **New `class_name X`**: run `--import` once before the test scene (else
  `Identifier "X" not declared`); verify in `.godot/global_script_class_cache.cfg`.
- **Capture path**: `user://X.png` → `/mnt/c/Users/.../AppData/Roaming/Godot/app_userdata/<project>/X.png`
  (`find /mnt/c -path "*/app_userdata/*" -name "X.png"`); Read it as a normal PNG.

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

## Soul workflow (5-layer cross-skill check)

If the GDD targets Fellowship / Narrative / Submission / Discovery /
Sensation, soul is REQUIRED — layered density across 5 channels; skip one
= a soul-shaped hole. For each signature beat, verify ALL FIVE are wired
AND pull the same emotional direction (gruff dialogue + celebratory flash
= anti-soul).

| Layer | Owner |
|---|---|
| 1. Writing | yume-flavor-writer |
| 2. Visual identity | yume-asset-designer + engine |
| 3. Audio | yume-audio-designer |
| 4. Kinetic juice | yume-juice-designer |
| 5. Reactive density | yume-game-rules-designer + tutorial |

Full checklist + reinforcement-check + empirical case: `.claude/rules/soul.md`.

## Post-mortem ritual (ALWAYS-ON — every bug must harden a skill)

User invariant: **whenever a bug appears, find WHO is responsible and
improve the skill so it can't recur.** When the user surfaces ANY bug
("doesn't work" / a trace / "why didn't this…"), don't just fix it — run
the 4-step ritual (full version + empirical precedents:
`.claude/rules/post-mortem.md`):

1. **Fix** the bug.
2. **Identify the owner** — the specific skill/rule/validator/test that
   should have caught it. No gate for this class → flag + create one.
3. **Harden the gate** — an *enforceable* check (checklist item, grep,
   validator, reviewer axis), not "be careful". Must make this exact bug
   class impossible to recur. The gate update is **not optional**.
4. **Commit both** (fix + gate) together, citing the empirical case + date.

**Step 3a**: ask "what OTHER call sites hit this class?" — fix the
underlying primitive, not just the symptom site. When the user asks **"who
is responsible?"** they're running this ritual on you — name the skill,
explain the missing gate, harden it before moving on.

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
- `.claude/plan/backlog.md` — live actionable backlog (start here); `.claude/plan/archive.md` — full history + decision log (`task_plan.md` is now just an index pointing to both)
