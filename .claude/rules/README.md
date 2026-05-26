# Yume path-scoped rules

These markdown files encode Yume's design invariants as **path-scoped rules**:
each one applies when editing files matching its `globs` field.

CCGS-inspired pattern (`/mnt/c/.../Claude-Code-Game-Studios/.claude/rules/`).
Adapted for Yume's seven-primitive architecture and JSON-driven runtime.

## How they work

When Claude (or any agent) edits a file under one of these globs, it should
**read the corresponding rule first** and verify its proposed change doesn't
violate any DON'T. This is enforcement-by-convention; full automatic attach
requires Claude Code editor integration.

Manual workflow:

```bash
# Before editing scripts/engine/*.gd:
cat ~/yume/.claude/rules/engine-scripts.md

# Before editing data/demo_*/*.json:
cat ~/yume/.claude/rules/data-demo.md
```

## Rules in this folder

| File | Globs | What it enforces |
|---|---|---|
| `engine-scripts.md` | `godot/scripts/engine/**` | No semantic effects, no genre code, no entity-class hierarchy |
| `data-demo.md` | `godot/data/**` | Schema discipline, formula whitelist, no hardcoded engine paths |
| `docs.md` | `docs/**` | Primitive changes need ADRs; contract doc is load-bearing |
| `tests.md` | `godot/scripts/engine/tests/**` | Tests ship with phase, no fixture-specific engine code |
| `visual-qa.md` | (skill-applied, not path-scoped) | Visual capture + Read mandatory after any rendering-affecting change; subagent prompts must include the gate |
| `post-mortem.md` | (always-on behavioral rule) | After every user-surfaced bug: fix → identify gate that should have caught it → harden gate → commit both. Skipping leaks the bug class into future sessions. |
| `soul.md` | (cross-skill workflow rule) | The 5-layer soul checklist (writing / visual / audio / kinetic / reactive) for any game with aesthetic targets like Fellowship/Narrative/Submission/Discovery/Sensation. Soul comes from layer cross-reinforcement — every signature beat must hit all 5 layers, all pulling the same emotional direction. |
| `pipeline-stability.md` | `tools/visual_layout/**` + yume-{hud,screen,map}-author skills | 2D fit-fit pipelines (HUD + screen) are STABLE — ADR required to modify the harness. 3D map/world pipeline is ACTIVE — modify freely. The live content (hud.json / screens.json) is NOT locked even when its harness is. |

Each rule file links back to relevant **invariants** from
`docs/30_framework_primitives.md`. If a rule and an invariant ever conflict,
the invariant wins — rules document enforcement, not policy.

## Static validators

Several rules above are MACHINE-ENFORCED at sync time by validators in
`tools/validators/` (relocated 2026-05-17 from `tools/`). They run
automatically from `scripts/play.sh` via `tools/validators/run_all.py`;
pass `--strict` to exit 1 on any violation (CI / agents should use
strict mode). Skip the whole bank with `SKIP_VALIDATE=1`.

To run an individual validator: `python3 tools/validators/<name>.py
<game> [--strict]`. To run the bank: `python3 tools/validators/
run_all.py <game> [--strict]`.

| Validator | What it catches | Sources |
|---|---|---|
| `validate_no_stray_scripts.py` | `.gd` files under `data/` that shadow engine classes (e.g. stale `effect_apply.gd` after a rename) | `.claude/rules/data-demo.md` § no stray .gd |
| `validate_lib_refs.py` | broken `@lib.X.Y` references — every ref must resolve through `data/lib/manifest.json` | ADR 0027 |
| `validate_input_universal.py` | every demo's `ui/input.json` must `$include @lib.input.universal.actions` or WASD silently no-ops | ADR 0043 |
| `validate_screens.py` | `transition_screen` targets must be known screen ids or `@previous`/`@root` | `.claude/rules/visual-qa.md` § screen-flow gate |
| `validate_spawn_templates.py` | every `spawn.template` must reference an existing entity def | empirical 2026-05-10 |
| `validate_level_instances.py` | every level's `initial_instances[].def` + `patterns[].def` must reference an existing entity def — catches stale legacy levels with renamed/deleted def_ids before the engine fires `[world.def_unknown]` at load | empirical 2026-05-20 |
| `validate_scene_directors.py` | every subsystem referenced by content (schedule, party, faction, ...) must have its director Node mounted in the per-game `.tscn` | `.claude/rules/data-demo.md` |
| `validate_duplicate_mutations.py` | warn when two rules across `world/rules.json` + `game/goals.json` mutate the same `(tag, field)` pair under overlapping queries | empirical 2026-05-11 |
| `validate_player_perspective.py` | undiscoverable keybinds + objective text referencing unlabeled landmarks | `yume-game-reviewer` Axis 15 |
| `validate_tick_override.py` | per-game `tick_seconds` override without a `_comment_tick` rationale | CLAUDE.md § Tick rate is the engine's heartbeat |
| `validate_rules.py` | formula references unbound bindings (incident-1 class of 2026-05-16 gather_pickup crash) + empty-effect rules + 2-binding non-contact queries + schema field-name landmines (`delta` vs `amount`, `def` vs `template`) + keyless input actions missing `engine_injected: true` + **`require:` keys must match a binding the engine actually populates for the trigger type** (2026-05-20: jump rule shipped with `require: {clock: ...}` against an input trigger; engine never sets ctx['clock'], require always failed, rule never fired) | `.claude/rules/data-demo.md` § formula context bindings, § sync-derived fields, § query vs require |
| `validate_camera_freeze.py` | every `_camera_*` function in `camera_director.gd` that captures the mouse MUST honor `screen_freeze_world` / `overlay_freeze_world` (release mouse + early-return when a modal/overlay is open). Without this, ESC opens the pause menu but the camera re-captures the cursor every frame → pause-menu buttons un-clickable. Empirical case 2026-05-20: `_camera_free_cam` shipped without the guard | `yume-tech-director` SKILL.md Invariant #10 § camera-mode extension |
| `validate_entity_state_fields.py` | state-field-name landmines that compile fine but the engine silently ignores. `state.facing` on a non-actor entity → warn (renderer reads `state.yaw` via `multimesh_director.gd:373`; `facing` is a movement-rule convention). `state.rotation` / `state.rotation_y` → error. `state.rotation_deg` / `state.heading` → warn. Empirical 2026-05-26: compose_world emitted `state.facing` for static wall rotation; 16 walls silently rendered at yaw=0 for an iteration before the user noticed in the capture | `.claude/rules/post-mortem.md` + `.claude/rules/data-demo.md` |

If you add a new gate (post-mortem step 3), prefer a static validator
over a prose rule when the check is machine-decidable. Prose rules are
guidance; validators are enforcement. Both have their place: validators
catch the exact case; prose rules explain the WHY so future authors
can extend the check to new situations.
