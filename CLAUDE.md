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

## Tick rate is the engine's heartbeat (2026-05-16)

**The tick is the engine's clock. Don't change it as a balance knob.**

- **Default `tick_seconds = 0.0167` (60Hz).** Matches Godot's
  `physics_fps`. Pick this unless you have a documented reason to
  override.
- A per-game override is legal but should be deliberate — a slow
  turn-based game (sokoban) might pick 10Hz to save cycles; a
  competitive shooter might pick 120Hz. The choice is per-genre, not
  per-bug.
- **Never reach for `tick_seconds` to "fix" pacing.** If something
  feels too fast or too slow, the answer is almost always: scale
  the relevant rule's `interval`, not the tick rate.

### Press vs hold is about purpose, not genre

Every game has both. The distinction is the input's INTENT:

- **`edge: "press"`** — discrete action. Fires once on key-down,
  ignores held state. Open / close menu, use item, restart, sleep,
  eat, talk. Holding the key longer doesn't fire again.
- **`edge: "hold"`** — continuous action. Fires every tick while
  held. Move forward, sprint, aim, drag, charge.

Sokoban's restart = press. Aldenmere's WASD = hold. Both their
inventories = press. The genre never enters the decision.

### Game-time rules scale with the tick rate

When a rule means "every N seconds of real-time" or "every in-game
hour", express that through the `interval` field:

- "Fire every second" at 60Hz = `interval: 60`.
- "Fire every 4 real-seconds" (ambient wander) at 60Hz = `interval: 240`.
- "Fire every in-game hour" (when 1 hour = 40 real-seconds) at 60Hz
  = `interval: 2400`.

If you change `tick_seconds`, you've also changed what every rule's
`interval` MEANS in real time. Don't do this lightly.

### `_process` vs `_physics_process`

- **`_process(delta)`** — display-rate work: input sampling, camera
  smoothing, HUD updates, sim-tick accumulator.
- **`_physics_process(delta)`** — fixed-rate physics: CharacterBody3D
  move_and_slide, collision queries. Aligns with `tick_seconds` when
  both are 60Hz.

Don't mix the two purposes. Put visual/UI work in `_process`,
gameplay-state physics in `_physics_process`.

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

# 2. Rebuild class cache if a NEW `class_name X` GDScript was added (otherwise skip)
"$GODOT_BIN" --path "$TEMPLATE_DST" --headless --import 2>&1 | tail -5

# 3. Run tests / scenarios / captures (always tee; direct stdout from the
#    Windows .exe through WSL pipes is unreliable)
"$GODOT_BIN" --path "$TEMPLATE_DST" --headless scenes/test_main.tscn 2>&1 | tee /tmp/test_out.log
"$GODOT_BIN" --path "$TEMPLATE_DST" --headless scenes/scenario_test.tscn -- --game=demo_<name> 2>&1 | tee /tmp/scen_out.log
"$GODOT_BIN" --path "$TEMPLATE_DST" --rendering-driver opengl3 scenes/<name>_3d.tscn -- --capture-after=4 --capture-output='user://x.png' 2>&1 | tee /tmp/cap.log
```

Unit tests should report `passed: NN  failed: 0  total: NN`. Test source:
`godot/scripts/engine/tests/test_runner.gd`. Per-game scenarios are
defined in `godot/data/demo_<name>/tests.json`.

### Long-running runs

Godot test_main.tscn often takes 60-120s and timeout 90 will SIGTERM
it before it finishes. Either bump `timeout` to ≥240, or run via
`run_in_background: true` + `Monitor` with the pattern:

```
until grep -qE "passed:|RESULTS|ERROR" /tmp/file; do sleep 2; done; tail -20 /tmp/file
```

### Class-cache rebuild — when `class_name X` is new

Symptom: `Parse Error: Identifier "X" not declared in the current
scope` even though the file exists. Run `--import` once before the
test scene; verify the cache picked it up:

```bash
grep "class_name_X" "$TEMPLATE_DST/.godot/global_script_class_cache.cfg"
```

### Capture output path

`--capture-output='user://X.png'` resolves to the platform's Godot
user-data path. On WSL2+Windows it lands under
`/mnt/c/Users/.../AppData/Roaming/Godot/app_userdata/<project_name>/X.png`.
Find with `find /mnt/c -path "*/app_userdata/*" -name "X.png"`. Read
with the Read tool — it's a regular PNG.

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

If the GDD's aesthetic target includes Fellowship / Narrative /
Submission / Discovery / Sensation, soul is REQUIRED. Soul = layered
density across 5 channels. Skipping any layer = a soul-shaped hole
the player will feel without being able to articulate.

| Layer | Owner | Asks |
|---|---|---|
| 1. Writing | yume-flavor-writer | Per-NPC voice, item flavor, barker pools |
| 2. Visual identity | yume-asset-designer + engine | Distinct silhouettes + nameplate widget |
| 3. Audio | yume-audio-designer | BGM per location, ambience, stings |
| 4. Kinetic juice | yume-juice-designer | Camera shake, flash, hit-pause, particles |
| 5. Reactive density | yume-game-rules-designer + tutorial | Barker pools shift per tier, objectives update |

For each signature beat in the GDD's "Voice & texture" section,
verify all 5 layers are wired AND pull the same emotional direction.
Mismatched layers (gruff dialogue + celebratory flash) = anti-soul.

Read `.claude/rules/soul.md` for the full checklist + reinforcement-
check workflow + the empirical merchant case (writing-only soul felt
hollow → all 4 other layers added in parallel pass).

## Post-mortem ritual (ALWAYS-ON — every bug must harden a skill)

User invariant: **whenever a bug appears, find out who is
responsible, and improve the skill so it can't recur.**

When the user surfaces ANY bug — "this doesn't work" / "still
nothing happens" / a stack trace / "why didn't this..." — do NOT
just fix it. Run the 4-step ritual from `.claude/rules/post-mortem.md`:

1. **Fix the bug.**
2. **Identify WHO is responsible.** Name the specific skill / rule /
   validator / test that should have caught it. Every bug has an
   owner — if it slipped through, the owner's gate was missing a
   check. If no gate exists for this bug class, flag the gap and
   create one.
3. **Harden the gate.** Concrete checklist item, grep command,
   reviewer axis, new validator, or new skill section. Not "be
   careful" — *enforceable*. The skill update must make this exact
   bug class impossible to recur.
4. **Commit both** — bug fix + gate hardening in the same commit,
   citing the empirical case + date.

The gate update is **not optional**. Skipping it means the same bug
class re-surfaces in a future session, in a future game, in a
future design pipeline. Read `.claude/rules/post-mortem.md` for
the full ritual + empirical precedents (every bug since 2026-05-04
followed this pattern).

Step 3a (bug-class generalization): when fixing one site, ask "are
there OTHER call sites that could trigger the same bug class?" If
yes, fix the underlying primitive, not just the symptom site.

Each gate hardening makes the system stronger. A bug that gets
fixed but not gated will re-occur. A bug that gets gated cannot
re-occur in that exact form.

**When the user asks "who is responsible?" they are running the
post-mortem ritual on you.** Answer specifically: name the skill,
explain what its gate should have included, and harden it before
moving on.

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

## Authoring-time Python emitters (ADR 0051, 2026-05-17)

JSON remains canonical. Two Python packages under `tools/` offer
**optional** emitters that produce that JSON + companion asset
files. Authors mix codegen and hand-authoring freely.

- **`tools/yume_codegen/`** — typed builders for rule / entity /
  screen / lib_ref JSON. Catches recurring bug classes
  (brace-wrapped bindings, wrong context-binding names, schema
  landmines) at author-time via `TypeError`/`ValueError` from
  keyword arguments. `python3 -m tools.yume_codegen` runs the
  30-assertion smoke test. See `tools/yume_codegen/README.md`.

- **`tools/yume_assetgen/`** — AI-assisted texture + mesh
  pipeline. Reads `data/<game>/asset_gen.json` for backend +
  style config, scans entity defs for `*_prompt` fields under
  `visual:`, dispatches to a configured backend, writes output to
  `assets/textures/`/`assets/meshes/`, then patches entity defs
  with the resolved `res://` paths. Mock backend ships; real
  ones (`openai_images`, `stable_diffusion_local`, `tripo3d`)
  slot into `tools/yume_assetgen/backends/`. CLI:
  `python3 -m tools.yume_assetgen <game> [--dry-run|--init|...]`.
  See `tools/yume_assetgen/README.md`.

Engine support for asset-gen output is in `entity_mesh_3d.gd`:
`visual.albedo_texture` (code-drawn meshes) + dict-form
`material_overrides` entries with `{albedo_color,
albedo_texture, normal_texture, roughness, metallic}` (.glb
meshes via ADR 0046 Phase B).

## Read More

- `docs/30_framework_primitives.md` — the engine contract (invariant-bearing)
- `docs/31_text_to_game_pipeline.md` — strategic plan + CCGS analysis
- `docs/32_mda_for_yume.md` — design vocabulary
- `docs/adr/README.md` — index of architectural decisions
- `docs/adr/0046-animation-via-godot-animation-player.md` — animation primitive
- `docs/adr/0051-authoring-time-python-emitters.md` — codegen + assetgen rationale
- `tools/yume_codegen/README.md` — rule/entity/screen JSON builders
- `tools/yume_assetgen/README.md` — texture + mesh generation flow
- `task_plan.md` — durable backlog (mirrors session TaskList)
