# Code review archive

This folder collects review reports produced by `yume-code-reviewer`
(or by humans following the same shape).

## File convention

`YYYY-MM-DD-<topic>-review.md`

- `YYYY-MM-DD` — the day the review was written.
- `<topic>` — short slug naming the change (branch name, commit
  range, refactor topic, milestone).

Examples: `2026-05-16-session-review.md`, `2026-06-02-physics-cutover-review.md`.

## Review shape

See `.claude/skills/yume-code-reviewer/SKILL.md` § "How to write the
review" for the template. Each review has:

- **Verdict**: `accept` / `accept-with-conditions` / `revise` / `reject`
- **What the change does** (1-2 sentences)
- **Questions** (Socratic — `why did you...?`)
- **Smells** (file/line + suggested fix)
- **Gate posture** (table — did each behavior change update a gate?)
- **Conditions** (checklist — if `accept-with-conditions`)
- **Out of scope**

## Lifecycle

Reviews are append-only. Once written, don't edit them — append a
follow-up review or commit-cite resolution.
