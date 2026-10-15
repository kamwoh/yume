# Code review — ADR 0082 phase 1 (forked reviewer skills)

_Date: 2026-10-15_
_Reviewer: yume-code-reviewer_
_Subject: uncommitted `git diff HEAD` on `.claude/skills`, `tools/validators/validate_claude_config.py`, `.gitignore`, plus untracked `docs/adr/0082-forked-skills-for-isolated-phases.md`_

## Verdict

`accept-with-conditions`

## What the change does (1-2 sentences)

The change adds `context: fork` + `background: false` to six reviewer skills, gives each an `## Inputs and outputs` handoff section, and rewrites the `/yume-design` orchestrator note with a probe-and-fallback for blocked spawns. A validator check requires the handoff section on each forked skill.

The diff also adds `docs/papers/` to `.gitignore`. That line does not trace to ADR 0082.

Evidence for the fork: this review ran as a forked skill. It got its arguments and saw no chat history. The mechanism works for `yume-code-reviewer` at least.

## Questions

### Q1 — Why is the ADR `accepted (phase 1 done)` before the baseline measurement exists?

> The ADR's Measurement section says "run `/yume-design --plan-only` on the same fixed pitch before and after phase 1". Where is the "before" number?

After this diff lands, the inline baseline is gone. Only the fallback path (`forks_blocked`) can get it back. That path runs the skill bodies that now say "you run in a subagent". The phase-2 gate says "proceed only if the context drops and the review finds at least as many flaws". If nobody records the baseline first, nobody can evaluate that gate. It becomes a gate that never fires.

Also, the ADR set its own status. The pipeline says an ADR becomes `accepted` through `yume-tech-director`. Did the tech-director review this ADR?

**Author's answer needed before:** merge. Either record the baseline now (on the pre-change tree) or set the status to `accepted (phase 1 trial, baseline pending)` and say where the numbers will go.

### Q2 — Who sets the ADR status to `accepted`: the fork or the orchestrator?

> `yume-tech-director` Inputs and outputs: "On approve, also set the ADR status to `accepted`." `yume-design` step 10: "On accept → ADR status set to `accepted`, proceed."

Two owners for one write. If both run, nothing breaks. If one assumes the other did it, the ADR stays `proposed`. Pick one owner and delete the other sentence. The fork is the better owner, because the orchestrator now only sees a summary.

**Author's answer needed before:** merge.

### Q3 — Does the old "When invoked by orchestrator" return contract contradict the new one?

> `yume-game-reviewer` line 663 and `yume-shooter-reviewer` line 293 still say "Return verdict + 1-paragraph rationale". The new section says "200 words or fewer: the verdict, the output path, and the top 3 items".

A forked agent reads its whole skill body as the prompt. Two return contracts in one prompt means the agent picks one. The orchestrator relies on the output path to find the verdict file. Align the old sections (or delete them, since the new section supersedes them). `yume-merchant-reviewer` line 413 has the same section.

`yume-game-reviewer` line ~660 also says "Apply 7-axis review". The skill has 15 axes, and `yume-design` calls it a "13-axis floor". This is older rot, but the forked agent reads it as an instruction.

**Author's answer needed before:** merge.

### Q4 — Does the validator gate check the contract, or only a heading?

> The check is `"\n## Inputs and outputs\n" in text`.

An empty heading passes. The ADR says the section "names the arguments, the output file, and the return format". The check does not test any of that. A stronger check costs a few lines: inside the section, require the three bold labels `**Arguments.**`, `**Output.**`, `**Return.**`. All six skills already use these labels.

A second drift risk has no gate: the fork set in the ADR table and the fork set in `yume-design`'s note are prose lists. Phase 2 adds four more skills. What stops the orchestrator note from listing the wrong set? One option: the validator prints the set of `context: fork` skills, and `yume-design` refers to "skills with `context: fork`" instead of naming them.

**Author's answer needed before:** accept (can land as a follow-up if tracked).

### Q5 — Is the fallback probe actually falsifiable?

> "If it fails with a spawn or auth error, set `forks_blocked`."

What does a spawn failure look like through the Skill tool with `context: fork`? Does the Skill tool fall back to inline by itself, or does it return an error? If it silently runs inline, the probe never fires and the reviewer runs in the author's context with no signal. Nobody tested this path under the blocking policy. Name the expected error text, or note that it is untested.

**Author's answer needed before:** accept.

## Smells

- `.gitignore:26-29` — `docs/papers/` is out of scope for ADR 0082. Split it into its own commit.
- `README.md:246-247` — still says "a *skill* loaded into Claude's own context (Tier 2.6 — no subagents)". Now stale for the six forked skills.
- `CLAUDE.md:37` — "42 specialist skills, Tier 2.6". Same stale label. Low priority.
- `docs/adr/README.md` — the index stops at 0067. ADR 0082 is not indexed (neither are 0068-0081). Add at least 0082.
- `.claude/skills/yume-code-reviewer/SKILL.md:313` (Reference) — cites `.claude/memory/feedback_review_style.md`, which does not exist. A forked agent that follows the reference finds nothing. Pre-existing, but the fork now has no other way to get that context.
- `.claude/skills/yume-tech-director/SKILL.md` Inputs and outputs — `<topic>` in the output path is not defined. The caller in `yume-design` step 10 must guess the same `<topic>` to read the verdict. Define it (for example, the ADR slug).
- ADR 0082 line 11 — STE lint advisory: "has disabled" (quoted error text, so keep).

## Gate posture

| Change | Gate updated? | Suggestion |
|---|---|---|
| Six skills gain `context: fork` | yes, validator check 3 | Check the three labels inside the section, not only the heading (Q4) |
| Orchestrator fork/fallback protocol | no | Test or document the failure signal (Q5) |
| Tech-director writes ADR status | no | One owner (Q2) |
| Fork set listed in prose in two places | no | Derive from frontmatter (Q4) |
| ADR phase-2 gate | measurement defined, baseline missing | Record the baseline before merge (Q1) |

## Conditions for accept

- [ ] Record the inline baseline for the measurement, or mark the ADR status as baseline pending (Q1).
- [ ] One owner for setting ADR status to `accepted` (Q2).
- [ ] Align or delete the old "When invoked by orchestrator" return contracts in game, shooter, and merchant reviewers (Q3).
- [ ] Define `<topic>` for the tech-director output path.
- [ ] Move the `docs/papers/` `.gitignore` line to its own commit.
- [ ] Index ADR 0082 in `docs/adr/README.md`.

## What this review did NOT cover

- The Claude Code fork semantics themselves (`context: fork`, `background: false`). I did not re-check the docs the ADR cites. This run is one positive data point.
- The behavior under the blocking auth policy.
- The full bodies of the six skills, beyond grep for interactive steps and return contracts. No forked reviewer asks the user a question.
- Phase 2 and 3 skills.

## Resolution (2026-10-15, author)

- Baseline: the ADR now says to take the "before" run from a git worktree
  at commit `0fa42bb`. The status says "Measurement pending".
- Return format: the game, shooter and merchant reviewers now point to
  § Inputs and outputs. The game reviewer says 15 axes.
- Ownership: the tech-director owns the ADR status change. `<topic>` is
  the ADR file name, or the branch name when there is no ADR.
- Gate: the validator also checks the labels Arguments, Output and Return.
- `README.md` and the ADR index now name ADR 0082.
- `.gitignore` stays out of this commit.
