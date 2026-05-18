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
| `validate_scene_directors.py` | every subsystem referenced by content (schedule, party, faction, ...) must have its director Node mounted in the per-game `.tscn` | `.claude/rules/data-demo.md` |
| `validate_duplicate_mutations.py` | warn when two rules across `world/rules.json` + `game/goals.json` mutate the same `(tag, field)` pair under overlapping queries | empirical 2026-05-11 |
| `validate_player_perspective.py` | undiscoverable keybinds + objective text referencing unlabeled landmarks | `yume-game-reviewer` Axis 15 |
| `validate_tick_override.py` | per-game `tick_seconds` override without a `_comment_tick` rationale | CLAUDE.md § Tick rate is the engine's heartbeat |
| `validate_rules.py` | formula references unbound bindings (incident-1 class of 2026-05-16 gather_pickup crash) + empty-effect rules + 2-binding non-contact queries + schema field-name landmines (`delta` vs `amount`, `def` vs `template`) + keyless input actions missing `engine_injected: true` | `.claude/rules/data-demo.md` § formula context bindings, § sync-derived fields |

If you add a new gate (post-mortem step 3), prefer a static validator
over a prose rule when the check is machine-decidable. Prose rules are
guidance; validators are enforcement. Both have their place: validators
catch the exact case; prose rules explain the WHY so future authors
can extend the check to new situations.
