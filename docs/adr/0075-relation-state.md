# ADR 0075 — Relation state (edge-scoped state store)

_Date: 2026-08-16_
_Status: proposed_

## Context

Primitive #7 (Relation) stores unweighted typed directed edges:
`(type, from, to)`, deduplicated, indexed both ways. An edge either
exists or it doesn't. There is no place to put a number on it.

Three unrelated content problems all turn out to be the same missing
thing:

1. **Weighted social graphs.** "How well does A know B" is a scalar per
   ordered pair. Today the only expressible form is a per-entity dict
   (`state.trust_<other_id>`), which is O(N²) inside one entity's state
   blob and — decisively — **unqueryable**: `Query`'s clause set
   (`tags_all / tags_any / tags_none / id / ids / properties / state /
   relations / radius / order_by / limit`) cannot express "every entity
   whose trust edge to me is ≥ 60", because the field name is not known
   until runtime.
2. **Stack quantities.** `relate("held_by", item, holder)` models an
   inventory, but "3 of them" has nowhere to live. Content works around
   it by spawning three entities or by shadowing a count in entity
   state, which then desynchronises from the edge.
3. **Per-location values.** A price, a supply level, or a travel cost is
   a property of the *pair* (good, market) / (town, town), not of either
   endpoint. ZoneStore (ADR 0031) covers hierarchical containment but
   not arbitrary pairs.

All three are the same gap: the edge has no state scope. Every other
storage scope in the engine already has one — `entity.state`,
`zone.state` (ADR 0031), `world_state` (ADR 0047) — with a matching
effect family (`state_*`, `zone_state_*`). Relation is the only scope
without one.

## Decision

Give every relation edge an optional `state: Dictionary`, and complete
the symmetry that already exists across the other three scopes.

**1. Storage.** `RelationStore` keeps a third index, `"type::from::to"
→ Dictionary`. Edge state is created empty, dies with the edge
(`unrelate` / `clear_entity`), and round-trips through
`snapshot()` / `restore()`.

**2. Creation.** The `relate` effect accepts an optional `state` block.
Re-relating an existing edge **merges** the block into the edge instead
of no-op'ing, so an edge can be created and seeded in either order:

```jsonc
{"type": "relate", "relation": "knows", "from": "self", "to": "b",
 "state": {"trust": 10, "met_on": 0}}
```

**3. Mutation.** Three effects, named and shaped to match the existing
families exactly — `amount` (never `delta`), `min`/`max`, and the same
`relation` / `from` / `to` resolution `relate` already uses, so every
binding (`self`, `a`, `b`, `actor`, `target`, literal ids) works
identically:

```jsonc
{"type": "relation_set",   "relation": "knows", "from": "a", "to": "b",
 "field": "trust", "value": 50}
{"type": "relation_add",   "relation": "knows", "from": "a", "to": "b",
 "field": "trust", "amount": 15}
{"type": "relation_clamp", "relation": "knows", "from": "a", "to": "b",
 "field": "trust", "min": 0, "max": 100}
```

All three are no-ops on a missing edge (they never create one — edge
creation stays `relate`'s job, so a typo'd relation name can't silently
manufacture graph structure).

**4. Query.** The `relations` clause gains a reserved `_edge` key inside
its dict form. `_edge` filters the EDGE's state using the standard
operator suffixes; every remaining key stays the nested entity query it
is today:

```jsonc
{"relations": {"knows": {"_edge": {"trust_gte": 60},
                         "tags_all": ["merchant"]}}}
```

reads "related via `knows` to some merchant-tagged entity, where that
edge's `trust` is at least 60". Absent `_edge`, behaviour is byte-for-
byte what it is today. The `_` prefix marks the engine-reserved
namespace inside a query dict, matching the existing `_comment`
convention.

**5. Not in this ADR.** Formula and HUD *read* access to edge state.
The only place a read is actually needed is rendering a row per related
entity ("this person, and how well you know them"), and the binding
shape for that is only decidable once the repeated-UI element exists.
It lands in ADR 0076, which binds each row's edge alongside the row's
entity. Deliberately deferred rather than guessed at here.

## Consequences

**Enables.** Weighted social graphs; stack quantities on `held_by`
edges; per-pair prices, distances, and travel costs; trust/threat
matrices between factions without an N² entity blob. Yume now has four
symmetric state scopes with four symmetric effect families, which makes
the vocabulary smaller to teach, not larger.

**Costs.** `RelationStore.snapshot()` element shape grows a `state` key.
`restore()` accepts elements with or without it, so **existing save
files keep loading** — a legacy element simply restores an edge with
empty state. Memory cost is one dictionary per edge that carries state;
edges without state store nothing.

**Precludes.** Edge state is not a query *source* — you cannot start a
query from "all edges with trust > 60" and get edges back; you start
from entities and filter by their edges. Making edges first-class query
subjects would mean a second `run()` surface (like `run_zones`) and is
not justified by any current content need.

**Invariant check (#8).** No new primitive: Relation stays primitive #7,
it simply gains the state scope the other three storage scopes already
have. No semantic verb: the engine never reads a field name — `trust`,
`qty`, `price` are content vocabulary, identical in kind to `hp` on
entity state. A chess game (`threatens` edges with a weight), a factory
sim (`feeds` edges with throughput), and an ecology sim (`preys_on`
edges with pressure) all want this.

## Alternatives considered

**A. A separate top-level `relation_state` query clause** —
`{"relation_state": {"knows": {"trust_gte": 60}}}`. Rejected: it cannot
compose with the entity-side filter, so "knows a *merchant* well" needs
two clauses that the engine has no way to correlate to the same edge.

**B. An explicit `{edge: ..., entity: ...}` split for the dict target.**
Rejected: it changes the meaning of every existing `relations` clause in
every shipped demo, for syntax that is no clearer than `_edge`.

**C. Keep faking it with `state.trust_<id>` on entities.** Rejected: not
queryable (see Context), O(N²) inside one entity's state, and it
desynchronises from the edge on despawn — `clear_entity` drops the edge
but leaves the mirrored field behind.

**D. A generic `properties` payload instead of `state`.** Rejected: on
entities, `properties` means "static, never mutated by rules" and
`state` means "mutated by rules". Edge payloads are mutated by rules.
Naming it `properties` would invert the established meaning of both
words.

## References

- Code: `godot/scripts/engine/stores/relation_store.gd`,
  `godot/scripts/engine/core/query.gd` (`_check_single_relation`),
  `godot/scripts/engine/core/effects/effect_core.gd` (relation effects),
  `godot/scripts/engine/core/effect_apply.gd` (dispatch)
- Tests: `godot/scripts/engine/tests/test_runner.gd` → `test_relation_state`
- Gate: `tools/validators/validate_rules.py` — field-name landmines for
  the three new effects, and `_edge` must be a Dictionary
- Contract: `docs/guideline/30_framework_primitives.md` §7
- Related: ADR 0001 (seven primitives), ADR 0031 (zone state — the
  scope this mirrors), ADR 0047 (world state as engine entity),
  ADR 0076 (repeated UI — carries the deferred read access)
