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
