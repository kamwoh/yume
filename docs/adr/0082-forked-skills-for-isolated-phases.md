# ADR 0082 — Forked skills for isolated pipeline phases

_Date: 2026-10-15_
_Status: accepted. Phase 1 shipped 2026-10-15. Measurement pending._

## Context

`/yume-design` loads each specialist skill into the orchestrator's own
context. The note "Skills, not subagents (Tier 2.6 architecture)" in
`.claude/skills/yume-design/SKILL.md` gives the reason. Some org auth
policies blocked subagent spawns ("organization has disabled Claude
subscription access"), and that failure broke the whole pipeline.

This design has three costs:

1. **Context size.** One run loads about 10 skills, about 38k words or
   50k tokens of instructions. Each phase also adds its outputs, its Godot
   logs and its image reads. The main context fills with text that later
   phases do not need.
2. **Review independence.** The context that writes the GDD also reviews
   it. An adversarial review is weaker when the reviewer shares the
   author's reasoning.
3. **Log noise.** QA phases read long Godot logs and many captures. Only
   the verdict matters to the next phase.

Claude Code now supports two fields that solve this without a second copy
of any instructions (checked 2026-10-15 against
https://code.claude.com/docs/en/skills.md and
https://code.claude.com/docs/en/sub-agents.md, CLI 2.1.300):

- Skill frontmatter `context: fork` runs the skill in a subagent. The
  skill body becomes the subagent's prompt. The subagent does not see the
  chat history. `background: false` makes the caller wait for the result.
- Subagent frontmatter `skills:` preloads full skills into a custom agent.

Subagent limits: a subagent cannot ask the user a question. It can start
its own subagents, up to 3 levels below the main session.

## Decision

Run selected skills as **forked skills**. Add `context: fork` and
`background: false` to their frontmatter. The skill file stays the single
source of truth. We add no agent files in this ADR.

### Which skills fork

| Phase | Skills | Why fork |
|---|---|---|
| 1 — reviewers (trial) | `yume-game-reviewer`, `yume-merchant-reviewer`, `yume-shooter-reviewer`, `yume-lifesim-reviewer`, `yume-code-reviewer`, `yume-tech-director` | A fresh context has no author bias. Output is one verdict file. |
| 2 — QA | `yume-qa-tester`, `yume-playtest`, `yume-visual-designer`, `yume-gdd-coverage-tracker` | Long logs and image reads stay out of the main context. |
| 3 — builders (later, after measurement) | `yume-content-designer`, `yume-systems-designer`, `yume-asset-designer`, `yume-level-designer` | Largest context gain. Decide after phases 1-2 give data. |

These skills stay inline: `yume-design` (the orchestrator, which must talk
to the user), `yume-game-designer` (interactive when not `--autonomous`),
and the small reference skills.

### Handoff contract for a forked skill

A forked skill sees no chat history, so the files carry everything:

1. **Input.** The caller passes arguments: the game slug and the paths of
   the input files. Example: `demo_x docs/games/x/GDD.md`.
2. **Output.** The skill writes its full result to one file. Example:
   `docs/games/x/review.md`.
3. **Return.** The skill returns 200 words or fewer: the verdict, the
   output path, and the top 3 items for the caller.
4. **No Godot in parallel.** A forked skill that runs in parallel with
   another does not sync to YumeTemplate and does not run Godot. Only the
   orchestrator does that (`.claude/rules/visual-qa.md` § parallel
   subagent discipline). QA skills run one at a time, so they may run
   Godot.

### Fallback for blocked spawns

The first forked call in `/yume-design` (the Phase 1b game review) is
the probe. If the spawn fails, the orchestrator sets `forks_blocked`.
From then on it reads each forked skill's `SKILL.md` with the Read tool
and runs it inline, as before. The pipeline then works under both auth
policies, and a separate probe call costs nothing extra.

## Consequences

**Positive:**

- The main context keeps only summaries from forked phases. Target for a
  `/yume-design --plan-only` run: 50% or less of the current main-context
  tokens at the end of the review phase.
- Reviews become independent of the author's context.
- `yume-code-reviewer` and `yume-tech-director` also give independent
  reviews when the user calls them outside the pipeline.

**Negative:**

- Total tokens rise a little. Each fork reads its inputs again.
- Each fork adds latency.
- The user cannot steer a forked phase while it runs. The interactive
  approval gate moves to the point after the fork returns.
- Each forked skill needs its input and output paths written down. A
  missing path makes the fork read the wrong file or nothing.

**Gate:** `validate_claude_config.py` gets one more check. A skill with
`context: fork` must contain a section titled `## Inputs and outputs`.
That section must contain the labels `**Arguments.**`, `**Output.**` and
`**Return.**`.

## Measurement (before phase 2)

Run `/yume-design --plan-only` on the same fixed pitch before and after
phase 1. For the "before" run, use a git worktree at commit `0fa42bb`,
the last commit with inline reviewers. Record the main-context tokens after the review phase. Seed the
GDD with 3 known flaws and count how many the reviewer finds in each mode.
Phase 2 proceeds only if the context drops and the review finds at least
as many flaws.

## Alternatives considered

**A. Keep everything inline (status quo).** Zero work. The context cost
and the review bias stay.

**B. Custom agents in `.claude/agents/` with `skills:` preload.** This
works, and it allows a per-agent tool list and model. It adds one file per
agent. Use it later only where a phase needs a different tool set or
model, for example a cheaper model for QA log reading.

**C. Fork every skill.** This loses the interactive steps that
`yume-design` needs, and it multiplies latency. Rejected.
