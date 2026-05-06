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
| [0003](./0003-harness-engineering-tier-26.md) | Harness engineering as Tier 2.6 | proposed | 2026-05-01 |
| 0004 | blocks_motion tag | accepted | 2026-05-03 |
| 0005 | raycast_hit effect | accepted | 2026-05-03 |
| 0006 | Multi-level architecture | accepted | 2026-05-04 |
| 0007 | Complex collision + GLB assets | accepted | 2026-05-04 |
| 0009 | World/game/flow separation | accepted | 2026-05-05 |
| [0010](./0010-save-load-persistence.md) | Save/load persistence | accepted (TD review) | 2026-05-06 |
| [0011](./0011-declarative-screen-flow.md) | Declarative screen flow → Godot Control exposure (foundational for shell tier) | revise — refactor under ADR 0021 | 2026-05-06 |
| [0012](./0012-tutorial-overlay-primitive.md) | Tutorial overlay primitive | accept-with-conditions (depends on 0011 refactor) | 2026-05-06 |
| [0013](./0013-settings-schema-and-config.md) | Settings schema + config (use ConfigFile) | accept-with-conditions | 2026-05-06 |
| [0014](./0014-open-world-foundational-substrate.md) | Open-world foundational substrate | accepted (conditions resolved) | 2026-05-06 |
| [0015](./0015-vehicle-physics-primitive.md) | Vehicle physics primitive (+ never-list anchor) | accepted (conditions resolved) | 2026-05-06 |
| [0016](./0016-multi-actor-framework.md) | Multi-actor framework | accepted (conditions resolved) | 2026-05-06 |
| [0017](./0017-spatial-lod-rule-scheduling.md) | Spatial-LOD rule scheduling | accepted (conditions resolved) | 2026-05-06 |
| [0018](./0018-actor-policy-interface.md) | In-process actor policy interface (split: in-process only) | accepted (conditions resolved) | 2026-05-06 |
| [0019](./0019-rule-plugin-macro-layer.md) | Rule plugin / macro layer | accepted (conditions resolved) | 2026-05-06 |
| [0020](./0020-external-agent-ipc.md) | External agent IPC (split from 0018) | proposed — deferred until first dependent game | 2026-05-06 |
| [0021](./0021-yume-as-json-layer-over-platform.md) | **Yume = JSON layer over Godot + external** (foundational) | accepted | 2026-05-06 |

## Cross-ADR review (2026-05-06, batch 0014-0019)

Tech-director cross-cutting analysis of the six ADRs proposed in
the open-world + multi-actor + agents + macros batch:

### Cumulative invariant pressure

Each ADR individually preserves invariants. Cumulatively, they add:

- 6 new engine modules (chunk_streamer, physics_response,
  actor_manager, lod_scheduler-extension, policy_interface,
  macro_expander)
- 5 new content file types (world.json, actors.json, policies/,
  macros.json, plus chunk layout)
- 5 new effect types (apply_impulse, switch_actor,
  queue_input_for_actor, plus 0019 and 0014 derivatives)

Concern: "death by a thousand cuts" on Invariant #8 (engine =
primitives + interpreter). Each new module is interpreter-shaped
(reads JSON, produces effects on existing primitives), so no
individual violation. But the engine's contract surface grows
significantly.

Verdict: not a violation. Tracked.

### Build-order critique

ADR text suggests order:
1. ADR 0019 (macros) — "small, low-risk, immediate benefit"
2. ADR 0016 (multi-actor) — foundational
3. ADR 0017 (spatial-LOD) — perf foundation
4. ADR 0015 (vehicle physics) — independent, parallel
5. ADR 0014 (open-world) — depends on 0016
6. ADR 0018 (actor policy) — depends on 0016

Tech-director recommendation:
1. **ADR 0017 (spatial-LOD) FIRST** — pure optimization, no
   contract change, lowest implementation risk. Provides immediate
   perf benefit to existing demos at scale.
2. **ADR 0019 (macros) SECOND** — clean contract design but rule-
   loader change requires regression tests across all 13 demos.
3. **ADR 0016 (multi-actor) THIRD** — foundational for 0014/0018;
   needs synthesized-default-actors mechanism to avoid dual code paths.
4. **ADR 0015 (vehicle physics) FOURTH** — independent; needs
   "never list" anchor before landing.
5. **ADR 0014 (open-world) FIFTH** — depends on 0016 + 0017; biggest
   surface change; ship after the foundations are validated.
6. **ADR 0018 (actor policy) — SPLIT and DEFER**:
   - In-process subset (Paths A + D) ships as 0018; gated behind
     0016 multi-actor.
   - External IPC subset (Paths B + C) becomes future ADR 0020 when
     first LLM/RL game is queued. Don't speculatively commit to
     subprocess + ZMQ infrastructure.

### Authoring surface explosion

Combined with shell-layer (ADRs 0010-0013, also proposed), authors
gain ~10 new file types to learn:
- save_policy.json, screens.json, tutorial.json, settings_schema.json
  (shell layer)
- world.json, actors.json, policies/, macros.json, chunks/<x>_<y>/
  (this batch)

Plus 5+ new skills to author them. Real cognitive load. Mitigation:
yume-design orchestrator + skills handle most of this for LLM-driven
content; human authors will have a learning curve.

This is not a violation; it's a feature ambition tradeoff. Logged.

### Backward compat patterns

All six ADRs follow the "if file absent, fall back to legacy" pattern.
Acceptable migration discipline. Concern: legacy paths get crufty if
not actively retired. Recommend per-ADR sunset timelines (~2-3 ADR
cycles ≈ 3 months).

### Recommended verdict for the batch

| ADR | Verdict |
|---|---|
| 0014 | accept-with-conditions |
| 0015 | accept-with-conditions (must add "never list") |
| 0016 | accept-with-conditions (synthesize default; single code path) |
| 0017 | accept-with-conditions (hysteresis required) |
| 0018 | revise — SPLIT into in-process (this) + external IPC (future 0020) |
| 0019 | accept-with-conditions (cycle detection + max-expanded-count) |

None blocked outright. Five accept-with-conditions; one needs
splitting before re-review.

If user accepts these conditions, recommended build order above
applies. Tech-director will re-verify on each ADR's implementation
PR.

### Conditions resolution (2026-05-06 update)

User reviewed the TD verdicts and chose to **address all conditions
in-place**. Each ADR now has a "Revisions per tech-director review"
section concretely resolving every condition:

- **0014**: persistent-entity-in-spatial-index spec'd; chunk-size
  unit semantics inherit from renderer; cross-chunk query semantics
  defined; save/load interaction explicit; test plan added.
- **0015**: physics never-list anchored as contract addendum (no
  continuous integration, no constraints, no soft body, no sub-tick
  CCD, no tire grip, no aerodynamics); impulse-based semantics;
  performance budget; phase ordering; reflection spec; mass>0
  contract.
- **0016**: synthesized-default-actors at load (single code path);
  per-actor input lists in actors.json; switch_actor at flush
  boundary; follow_active_actor camera mode; per-actor state on
  entity; zero migration confirmed; test plan added.
- **0017**: hysteresis (enter_radius < leave_radius); tick_slowed
  state in scheduler; determinism guidance bake into crowd-designer
  skill; lod_anchor_position cached; LOD vs stream-radius
  validation; test plan added.
- **0018**: SPLIT — in-process subset (Paths A+D) accepted as
  ADR 0018; external IPC (Paths B+C) extracted to ADR 0020 as
  deferred-until-needed.
- **0019**: depth ≤ 4 + max-expanded-effects ≤ 50; cycle detection
  at load; load-time-only expansion semantics; per-game scoping;
  automated CI Invariant #2 check; test plan + $param.field
  traversal spec.

All six ADRs now status: **accepted**. ADR 0020 is **proposed
(deferred)** — activates when a game requires external IPC.

Build order remains as recommended:
1. ADR 0017 (spatial-LOD)
2. ADR 0019 (macros)
3. ADR 0016 (multi-actor)
4. ADR 0015 (vehicle physics)
5. ADR 0014 (open-world)
6. ADR 0018 (in-process policies)
7. ADR 0020 (external IPC) — when needed

Implementation start gated on user's go-ahead.

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
