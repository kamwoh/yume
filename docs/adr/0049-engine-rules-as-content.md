# ADR 0049 — engine_rules: always-on engine behaviors expressed as JSON rules

_Date: 2026-05-15_
_Status: accepted_

## Context

Yume's invariant #8 is "engine = primitives + interpreter." But several
"always-on engine behaviors" violated this — they shipped as hardcoded
GDScript scans in `world.gd::advance_one_tick`:

- `_decrement_lifetimes()` — O(N) scan, decrements `state.lifetime`, despawns at 0
- (other candidates: `_ground_constraint.apply()`, but mixed feasibility)

The lifetime scan was the cleanest case. It's a pure data manipulation
behavior (decrement field, conditional despawn) that's trivially
expressible as primitive rules — no different in shape from a content
author's hunger-decay rule. Yet it lived in engine code as a special
case.

This violated the principle. The engine shipped a behavior that
content could express. New engine-shape behaviors would accumulate as
more special-case scans over time.

## Decision

Introduce `data/lib/engine_rules/` — a directory whose contents
WorldBoot auto-loads as global rules before any per-game rules. The
engine ships no behavior implementation here; just the auto-load
mechanism and a set of rule files that express the previously
hardcoded behaviors in pure JSON.

```jsonc
// data/lib/engine_rules/lifetime.json
{
  "rules": [
    {
      "id": "engine_lifetime_decrement",
      "trigger": {"type": "tick", "interval": 1},
      "query": {"state": {"lifetime_gt": 0}},
      "effect": {"type": "state_add", "target": "self",
                 "field": "lifetime", "amount": -1}
    },
    {
      "id": "engine_lifetime_despawn",
      "trigger": {"type": "tick", "interval": 1},
      "query": {"state": {"lifetime_eq": 0}},
      "effect": {"type": "remove", "target": "self"},
      "after": ["engine_lifetime_decrement"]
    }
  ]
}
```

`world.gd::_decrement_lifetimes()` deleted. The two rules above do the
identical work, dispatched by the scheduler like any other rule.

WorldBoot's `_load_engine_rules()` enumerates every `.json` in
`data/lib/engine_rules/` and registers via the standard rules-loading
path (`world._loader.load_rules_file`). Auto-included — not opt-in —
because these are engine-shaped invariants, not per-game choices.

## Consequences

### Engine code shrinks

- `world.gd`: −26 lines (`_decrement_lifetimes` body + call site)
- `world_boot.gd`: +20 lines (`_load_engine_rules` phase)
- Net: engine LOC down; behaviors moved to a single 30-line JSON file.

### Future engine-shape behaviors land as JSON

The rule for the rule: if you're tempted to add a per-tick scan in
`world.gd` over entities to do data-manipulation work, write it as a
rule in `data/lib/engine_rules/` instead. The engine's job is to ship
the scheduler + query + effect dispatch; behaviors compose from those.

Candidates currently in engine code that COULD migrate (deferred until
each is the next-good-step):
- `_ground_constraint.apply()` — clamp creature.y to ground.y +
  despawn projectiles. The despawn part is rule-shaped (`state:
  {position.y_lt: -1}` → remove). The clamp part needs a primitive
  for "set one component of a Vector field" that doesn't quite exist.
- `actor_manager.tick_policies()` — runs scripted AI policies. The
  per-policy logic is complex GDScript, not data manipulation.
  Stays engine.
- `_tick_lifecycle_director()` — ages + stage transitions. Complex
  state machine. Stays engine.

The boundary is now clearer: **data manipulation → JSON; complex
control flow / external integration → engine.**

### Slight phase-ordering shift (load-bearing-but-fine)

Before: `_decrement_lifetimes()` ran AFTER `scheduler.tick()` in
`advance_one_tick`. Content rules saw pre-decrement values.

After: lifetime decrement fires DURING `scheduler.tick`'s decide phase.
Content rules in earlier-phase positions see pre-decrement values
(unchanged); content rules in later-phase positions see post-decrement
(new). In practice no content rule reads OTHER entities' lifetimes, so
the difference isn't observable.

If a future content rule needs to read lifetime AFTER the engine's
decrement, it specifies `after: ["engine_lifetime_decrement"]`. Standard
mechanism, no special case.

### Edge-case semantic change

The previous `_decrement_lifetimes()` skipped entities with
`lifetime <= 0` entirely (so `lifetime: 0` from `state_init` meant
immortal). The new rule despawns any entity with `lifetime == 0`.

Verified no in-tree content uses `lifetime: 0` as an init value — the
"immortal-at-zero" quirk wasn't relied on. ADR documents the shift
explicitly so future games can't trip on it.

### Performance

Rule dispatch overhead per tick is higher than the direct GDScript
scan (query evaluation + binding setup + effect dispatch vs raw dict
lookups). At Aldenmere's ~237 entities both are microseconds; at the
~50-bullet doomarena3d ceiling both are negligible. If a future
particle-heavy game hits real cost, the optimization path is groups +
call_group (the "ADR 0050"-shape future work I sketched in
`docs/group-dispatch-flow.md`) — not "move back to engine code."

## Alternatives considered

### A. Status quo (engine-side scan)

Rejected. Violates Invariant #8 — the engine shouldn't ship behaviors
expressible as primitives.

### B. Hand-roll per-game lifetime rules

Each game that wants lifetime decay writes its own rules. Rejected —
this is engine-level "transient TTL" semantics; every game needs it
consistently. Auto-loading prevents the "forgot to include the bundle"
silent bug.

### C. Magic engine_rules namespace via $extends / $include

Per-game files could `$include` from `@lib.engine_rules.lifetime`. More
explicit. Rejected — engine-shipped behaviors should be invisibly
present, not opt-in surface area for content authors. The auto-load
captures the "always present" semantic correctly.

### D. Move to groups + call_group (per group-dispatch-flow.md)

This would handle "K of N entities need work" efficiently. Better at
scale. Rejected for THIS ADR — overlapping concerns. ADR 0049
establishes the engine_rules pattern; group optimization is independent
and can come later when there's a real performance need.

## Tech-director review

Accepted. Net engine LOC: −26. No new primitives. No new effect types.
No new query operators. Just an auto-load mechanism for a directory
of standard rule files.

Invariants verified:
- **#1** (JSON-only content channel): engine_rules ARE content
  (primitive rules + standard effects), not engine code.
- **#5** (queries first-class): the two new rules use `_gt` and `_eq`
  operators already supported by query.gd.
- **#8** (engine = primitives + interpreter): this ADR is the
  invariant becoming load-bearing. Behaviors expressible as primitives
  no longer live in engine code.
- **#9** (phase boundaries flush): lifetime rules fire in the decide
  phase; standard `after:` ordering keeps decrement-before-despawn.

Tests: 840 unit pass (unchanged from ADR 0048 baseline). Doomarena3d
scenarios at 25/16 pass/fail — same as before this ADR; failures are
pre-existing motion-test brittleness unrelated to lifetime.

## References

- `data/lib/engine_rules/lifetime.json` — the new rule file
- `godot/scripts/engine/coordinators/world_boot.gd::_load_engine_rules`
- `docs/group-dispatch-flow.md` — future optimization sketch (groups)
- ADR 0047 — `world_state` as `_engine` entity (precedent for the
  "JSON-shape this instead of engine-special-case" thinking)
- ADR 0048 — `velocity_add_relative` auto-reset (immediate prior
  precedent for "fix the primitive's semantic" thinking)
