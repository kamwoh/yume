# Parallel builder agents — full reference

_Moved from `yume-design/SKILL.md` on 2026-10-15 so that the skill loads faster. The skill links here._

## Parallel execution discipline (mid-session, deliverable-level)

The phase pipeline above is mostly sequential by design — each
phase's output is the next phase's input. But within a single
session (especially Tier A/B/C content sessions per a kingdom-sim
GDD), there are typically 3-7 deliverables that can be worked in
parallel because their file boundaries don't overlap.

Empirical case: kingdom-sim merchant Session 2 needs to ship 5
items. Sequential (single-thread) ~3-5 hours; pure parallel
(N agents) ~1.5-2 hours but high coordination cost; **hybrid
~2-3 hours with each item handled by its best-fit thread.**

### When to use parallel builders vs foreground (me)

Classify each deliverable BEFORE starting:

| Profile | Example | Best handler |
|---|---|---|
| **Cross-cutting**: touches ≥3 files, depends on full state-machine context | "4 distinct daily phases" (touches physics + game/rules + hud + scene + screen flow + state) | **Foreground (me/orchestrator)** |
| **Coupled-to-cross-cutting**: requires another in-flight cross-cutting item to land first | "Customer wants matrix" depends on "phases distinct" landing | **Foreground sequential after cross-cutting item** |
| **Self-contained UI**: writes one screen + signal-chain rules with clean file boundary | "Real haggle gauge screen" | **Builder agent (parallel)** |
| **Self-contained pattern demo**: writes new entity defs + new rules, doesn't modify existing rules | "Hire-NPC template" | **Builder agent (parallel)** |
| **Self-contained ai_policy**: writes new actor policy script + new entity, doesn't change existing actors | "Multi-shop NPC competitor" | **Builder agent (parallel)** |
| **New ADR / engine work**: ADR doc + engine module + tests | "ADR 0026 party primitive" | **Builder agent (parallel)** — file boundary is engine/ |

Litmus test for "parallel-safe":
1. Does this deliverable need to read state/files that another
   deliverable also writes? (yes → sequential)
2. Does it modify shared files (test_runner.gd, primitives doc)
   that another agent will also modify? (yes → coordinate)
3. Can I describe the deliverable's file-list in 1 sentence with
   no overlaps? (yes → parallel-safe)

### Sync race — parallel agents must NOT sync to YumeTemplate

CRITICAL constraint discovered Session 2 (2026-05-07): multiple
parallel agents each running `cp -r godot/. "$TEMPLATE_DST"/  # ← e.g. /mnt/c/
.../YumeTemplate/` race to overwrite the SAME shared template
directory. If two agents run godot binaries against this shared
template at overlapping times, godot processes see mixed source
state — non-deterministic tests, corrupt captures, file-not-found
errors mid-load.

**Rule: parallel agents WRITE source files only. They do NOT sync
to YumeTemplate. They do NOT run godot. The orchestrator (me) owns
the single integration sync + unit tests + visual QA across the
integrated state.**

This is also why parallel agents stage their rules into files like
`rules_haggle_staged.json` — the orchestrator splices them into the
appropriate `world/rules/<feature>.json` chain module AFTER all agents
land, BEFORE the single sync.

### Spawning parallel builder agents

When launching a `builder` subagent for parallel work, use this
prompt skeleton:

```
Build <deliverable name> for <game-name>.

WHY: <1-2 lines linking to GDD section>

YOUR FILES (own these, don't touch others):
- <path 1>
- <path 2>
...

DO NOT TOUCH (these are owned by me/other agents):
- <path A>
- <path B>
...

SHARED FILES — coordinate by appending only:
- <path X> — append your test sections at end, don't modify others'
- <path Y> — same, append-only

WHAT TO BUILD:
1. <step 1>
2. <step 2>
...

VERIFY:
- DO NOT sync to YumeTemplate. DO NOT run godot binary.
- DO NOT run unit tests or visual QA — orchestrator owns these
  across the integrated state.
- After writing your files, verify they parse as valid JSON / GDScript
  via Read/grep. That's your verification scope.

CONSTRAINTS:
- Per ADR 0021: expose Godot capabilities, don't reimplement
- Path-scoped rules in .claude/rules/ apply
- Visual QA gate per .claude/rules/visual-qa.md mandatory for
  visual-touching changes — construct context-specific prompt

REPORT BACK:
- Files modified + lines changed
- Test count delta (baseline → new)
- Visual QA result (PASS/FAIL with specific evidence)
- If commit: commit hash. If not (shared-file conflict expected):
  files staged for orchestrator to integrate.

Time budget: <estimate>. If blocker, surface — don't push through.
```

### Integration after parallel agents complete

When agents finish:

1. Read each agent's task-notification result
2. For each agent that committed cleanly: pull the commit message
   into your session understanding
3. For each agent that staged files (didn't commit due to shared-
   file conflicts): use `git add -p` to take their hunks cleanly,
   then commit yourself with attribution
4. Run unit tests + visual QA on the integrated state
5. Run gdd-coverage-tracker on the post-integration build
6. If any [R] still ✗: loop back per Phase 5b discipline

### When NOT to spawn parallel builders

- **Designer phases** (game-designer, planner, story-planner,
  economy-designer, level-designer): these write design docs that
  are coordination inputs to everything else. Run sequentially.
- **Reviewer phases**: read-only, but lock-stepped to design output
  they're reviewing. Sequential.
- **qa-tester + gdd-coverage-tracker**: these run AFTER all build
  work to evaluate the integrated state. Always last.
- **Single-deliverable sessions**: if the session has only 1-2
  items, spawning agents adds overhead without payoff.

### Pre-Session checklist

Before starting any content/build session:
1. List the session's deliverables from the GDD's Tier plan
2. Classify each: cross-cutting / coupled / self-contained / engine
3. Identify file boundaries per item
4. Pre-allocate ownership: foreground items + agent items
5. Write each agent's prompt with explicit DO TOUCH / DO NOT TOUCH
   file list
6. Identify shared-file coordination items (test_runner.gd,
   primitives doc, etc.) — pick a strategy (append-only, last-merge,
   or me-as-integrator)
7. Launch parallel agents in same message (multi-tool block)
8. Begin foreground work in parallel
9. Integrate when agents complete

This discipline replaces "vibes-based whether to spawn" with a
defensible decision framework. The merchant 2026-05-07 session
shipped ADR 0024 + 0025 by accidentally getting agents to step on
test_runner.gd; the integration recovery cost ~30 min. Pre-allocated
ownership prevents the recovery cost.
