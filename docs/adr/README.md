# Architecture Decision Records (ADRs)

ADRs document **load-bearing decisions** for Yume: choices that shape
the engine, primitive set, or pipeline in ways that downstream code +
content depend on.

Format: `NNNN-short-title.md` — zero-padded sequence, kebab-case title.
Sequence is by chronology of acceptance.

Status: `proposed` / `accepted` / `superseded by ADR-MMMM`.

## When to write an ADR

- **Adding a primitive** to the contract (e.g., `Plan` or `Knowledge`
  in Tier 3) → ADR.
- **Changing tick semantics** (e.g., adding a 5th phase) → ADR.
- **Renaming or removing a vocabulary item** (effect type, query
  operator) → ADR.
- **Strategic pivots** (e.g., the W5.0 review's "promote renderer_3d"
  decision) → ADR.
- **Schema changes** to data files (entities/rules/shapes) that break
  existing demos → ADR.

## When to NOT write an ADR

- Bug fixes that restore documented behavior — just fix it.
- Adding a new demo (`data/demo_<name>/`) — it's content, not architecture.
- Adding new content (entities, rules, shapes) within existing schema.
- Test additions.
- Doc clarifications that don't change semantics.

## Index

| ID | Title | Status | Date |
|---|---|---|---|
| [0001](./0001-seven-primitives.md) | Seven primitives + Engine = Primitives + Interpreter | accepted | 2026-04-22 |
| [0002](./0002-renderer-agnostic-entity.md) | Entity extends Node (renderer-agnostic) | accepted | 2026-05-01 |

ADRs land alongside the contract change they justify. PR review is the
gate. If a PR's diff materially changes engine vocabulary or pipeline
shape, the reviewer should ask "where's the ADR?"

## Format

```markdown
# ADR NNNN — short title

_Date: YYYY-MM-DD_
_Status: proposed / accepted / superseded by ADR-MMMM_

## Context

Why this decision is being made. What problem, what constraints.
Be specific — capture the situation that forced the choice.

## Decision

What we're doing. One paragraph max.

## Consequences

Positive, negative, neutral. What this enables, what it precludes,
what other things change.

## Alternatives considered

Options A, B, C — and why they weren't chosen.

## References

- Code locations affected
- Related ADRs
- Discussions / reviews
```
