# ADR 0082 — Forked skills for isolated pipeline phases

_Date: 2026-10-15_
_Status: accepted. Phase 1 shipped 2026-10-15. Measurement done 2026-10-16 (see Results). Phase 2 (QA skills) shipped 2026-10-16._

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

### Results (2026-10-16)

We measured the review step, not a full `--plan-only` run. The setup:

- One pitch ("Lantern Keeper") with 3 seeded flaws. F1: resting at the
  shrine scores and refills oil, so standing still wins (Axes 2 and 7).
  F2: the oil lasts 72 m of walking, but each lantern is 90 m away
  (Axis 7). F3: voiced branching dialogue and online co-op as pillars
  (Axis 6). The numbers sat in different sections.
- Inline mode: one agent wrote the GDD with yume-game-designer from an
  author brief that gave a reason for each flaw. In the same context it
  read the reviewer SKILL.md and ran it. This is also the fallback path.
- Forked mode: the main session called `yume-game-reviewer` through the
  Skill tool, on the same GDD file. The inline review was moved out of
  the folder first.
- Two trials, so two GDDs and four reviews.

| | Inline t1 | Forked t1 | Inline t2 | Forked t2 |
|---|---|---|---|---|
| F1 passive win | found | found | found | found |
| F2 unwinnable oil | found | found | found | found |
| F3 out of scope | found | found | found | found (voice only) |
| Verdict | reject | reject | reject | revise |
| Review length (words) | 1607 | 2597 | 1509 | 2107 |

Main-context cost of the review step:

- Inline: the reviewer SKILL.md (about 7,100 tokens), the review that
  the context writes (about 2,200 tokens), and the reasoning. About
  9,500 tokens or more.
- Forked: the returned summary, about 300 words or 450 tokens.
- That is a drop of about 95% for this step.
- A rough estimate for the whole phase: the GDD step (game-designer
  skill plus GDD, about 4,000 tokens) does not change. The total goes
  from about 13,500 to about 4,500 tokens, or about 33%. This meets the
  ADR target of 50% or less. We did not measure a full run.

Findings:

1. Both modes found all 3 flaws. The flaws were easy enough to hit a
   ceiling, so this test shows no quality loss. It cannot show a gain.
2. The author's reasons did not hide the flaws in inline mode at this
   difficulty. Author bias did not show.
3. The forked reviews were longer and more specific. Forked t1
   computed a 577 s tour against a 360 s dawn. Forked t2 judged co-op
   in scope through ADR 0063 and named the stale "networked
   multiplayer" non-goal in the contract doc and in the reviewer skill.
   Both inline reviews took that stale non-goal as true.
4. The t2 verdicts differed (inline reject, forked revise). Both fit
   the verdict guideline, because new numbers can fix the loop.
5. Follow-up done: the reviewer skill's scope list now puts networked
   play in scope through ADR 0063. The same stale non-goal stays in
   `30_framework_primitives.md`, which is ADR-gated.

Decision rule: the context dropped, and the forked reviewer found as
many flaws. Phase 2 (QA skills) may proceed, with user approval.

## Alternatives considered

**A. Keep everything inline (status quo).** Zero work. The context cost
and the review bias stay.

**B. Custom agents in `.claude/agents/` with `skills:` preload.** This
works, and it allows a per-agent tool list and model. It adds one file per
agent. Use it later only where a phase needs a different tool set or
model, for example a cheaper model for QA log reading.

**C. Fork every skill.** This loses the interactive steps that
`yume-design` needs, and it multiplies latency. Rejected.
