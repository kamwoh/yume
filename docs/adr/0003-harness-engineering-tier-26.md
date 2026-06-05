# ADR 0003 — Harness engineering as Tier 2.6

_Date: 2026-05-01_
_Status: accepted (in-flight — Tier 2.6a–2.6r shipped 2026-05-01..2026-05-09; ongoing iterative deliverables)_

## Context

Yume's stated goal is "type a description, get a game" — a text-to-game
pipeline that an LLM can drive. Tier 2 (runtime) and Tier 2.5 (pipeline
agents + skill) shipped the substrate. But honest evaluation of Yume
**as a harness for autonomous LLM agents** — not just as a target
environment for human-supervised authoring — surfaces a class of gaps
the existing tiers don't address.

A harness is the infrastructure that lets an LLM do meaningful
structured work autonomously. Properties of good harnesses:

| Property | Yume status | Grade |
|---|---|---|
| Small action space | 7 primitives + 15 effects | A- |
| Structured observations | Entity state queryable | A- |
| Verifiable outcomes | Engine runs, qa-tester checks | B+ |
| Persistent context | snapshot exists, save/load not wired | C |
| Error → retry signal | GDScript stack traces, not LLM-friendly | D |
| Tool discoverability | Hand-edited markdown docs | C- |
| Eval infrastructure | Engine: A. Skills: D (manual spec only) | C |

**Aggregate harness grade: B-** — workable with human-in-loop at every
approval gate; would derail on first schema error in autonomous mode.

The gap matters specifically for:
- Future Tier 3 LLM actors observing the world
- Reliable autonomous `/yume-design` invocation (no human gates)
- LLM-driven iteration on broken JSON (retry without human re-prompt)

## Decision

Add **Tier 2.6 — Harness Engineering** between Tier 2.5 (pipeline) and
Tier 3 (actors). Scope: close the harness loop for autonomous LLM
operation. Six deliverables (2.6a–2.6f).

Tier 2.6 is **not blocking** for human-supervised authoring (Tier 2.5
already supports that). It is **prerequisite** for any autonomous LLM
loop and for Tier 3 LLM actors that need rich observation/action
feedback.

## Consequences

**Positive:**

- `/yume-design` becomes invokable in autonomous mode (no human gates
  needed for happy path)
- Tier 3 LLM actors get structured world observation + action retry
- Test/eval infrastructure for skills (was manual)
- Cost transparency for agent invocations
- Catches the "harness gaps" hidden in 2.5 before they bite Tier 3

**Negative:**

- Adds 2-3 weeks of work that doesn't directly produce new genres or
  demos
- Some overlap with Tier 4 infra work (save/load, episode recorder)
  — need to coordinate scope carefully
- Tier 3 partially blocked until structured error feedback lands

**Neutral:**

- Reorders the roadmap: was Tier 2.5 → Tier 3; now Tier 2.5 → 2.6 → 3
- Doesn't invalidate any prior work — Tier 2.5 stands as authored

## Alternatives considered

**A. Skip — accept human-in-loop forever.** Yume stays a pleasant
LLM-assisted authoring tool but never crosses into autonomous agent
substrate. Killed because Tier 3's whole point is LLM-as-actor; without
harness improvements Tier 3 will need to invent these pieces ad-hoc and
they'll be agent-specific instead of framework-wide.

**B. Fold into Tier 3.** Make harness work part of the actor
implementation. Killed because: harness improvements benefit the
text-to-game pipeline (Tier 2.5) that already exists, not just future
actors. Earlier landing has compounding value.

**C. Defer indefinitely.** Same problem as (A) but worse — by the time
we need it, the gap will be N times bigger.

**D. Build only the most-needed pieces (e.g., just 2.6a structured
errors), skip the rest.** Considered. Rejected because the harness
properties compound — structured errors without a retry loop is half-
useful; retry without programmatic test runner can't validate fixes;
tool registry without contract validation doesn't catch drift. Better
to ship a coherent tier than 6 partial wins.

## References

- `docs/guideline/30_framework_primitives.md` — engine primitives (the action
  space the harness wraps)
- `docs/guideline/31_text_to_game_pipeline.md` — where Tier 2.6 sits in the
  bigger plan
- ADR 0001 — primitive set (the constrained action space property)
- ADR 0002 — renderer-agnostic Entity (state observation primitive)
- `task_plan.md` — Tier 2.6 deliverable list (added alongside this ADR)
- Session retrospective on harness grade (~2026-05-01)
