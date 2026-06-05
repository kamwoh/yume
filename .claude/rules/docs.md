---
description: Path-scoped rules for Yume documentation
globs: docs/**
---

# Documentation — discipline

Yume's docs are load-bearing. The contract doc (`30_framework_primitives.md`)
is referenced by every code edit; the task plan tracks roadmap state. Treat
them as code: precise, versioned, audited.

## DON'T

- ❌ **Edit `docs/30_framework_primitives.md` without an ADR.** The contract
  is invariant-bearing; changes need explicit reasoning + version trail.
  Adding a primitive, changing tick semantics, renaming an effect type —
  all require ADRs in `docs/adr/`.
- ❌ **Let the backlog drift from reality.** When an item in
  `.claude/plan/backlog.md` ships, delete it (the archive keeps the
  record); when scope changes mid-flight, note the deviation in
  `.claude/plan/archive.md`.
- ❌ **Duplicate timeline entries across files.** Diary lives in
  `docs/timeline/entries/`; add a NEW entry rather than rewriting an
  existing one.

## DO

- ✅ **Cross-reference the contract.** When a doc cites a behavior or
  invariant, link back to `30_framework_primitives.md` § X.
- ✅ **Date entries.** `_Last updated: YYYY-MM-DD_` at the top of any
  living doc. Strategic-shift sections include the date.
- ✅ **Append history to `.claude/plan/archive.md`** (the former
  `task_plan.md`; root `task_plan.md` is now just an index). Live TODOs live in
  `.claude/plan/backlog.md` — delete items there when they ship; the archive
  keeps the record. Keep deferred / superseded text visible so history is
  self-explanatory.
- ✅ **Use the timeline diary** (`docs/timeline/entries/NN_*.js`) for
  major architectural decisions, reviews, or pivots. Auto-renders via
  `docs/timeline/index.html` (run `python -m http.server` from there).

## Files of special importance

| File | Why |
|---|---|
| `docs/30_framework_primitives.md` | Engine contract. Invariant-bearing. ADR-gated. |
| `docs/31_text_to_game_pipeline.md` | Tier 2.5 strategic plan. CCGS analysis + decisions. |
| `docs/33_architecture.md` | Detailed architecture reference (engine + pipelines). |
| `.claude/plan/backlog.md` | Live actionable backlog. Delete-when-shipped. |
| `.claude/plan/archive.md` | Roadmap + history + decision log. Append-mostly. |
| `docs/timeline/` | Diary. One entry per major decision. |

## ADR format (when one is needed)

`docs/adr/NNNN-short-title.md`:

```markdown
# ADR NNNN — short title

_Date: YYYY-MM-DD_
_Status: proposed / accepted / superseded by ADR-MMMM_

## Context

Why this decision is being made. What problem, what constraints.

## Decision

What we're doing.

## Consequences

What this enables, what it precludes, what other things change.

## Alternatives considered

Options A, B, C — and why they weren't chosen.
```

ADRs land alongside the code/contract change they justify. PR review is
the gate.
