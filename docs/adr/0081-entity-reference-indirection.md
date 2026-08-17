# ADR 0081 — entity-reference indirection

_Date: 2026-08-17_
_Status: accepted_

## Context

Every effect that addresses an entity — `target`, and the `from` / `to` /
`leader` / `master_id` id fields — resolved its string through one of two
helpers in `EffectResolution`, both implementing the same two-case policy:

```gdscript
var id := str(ctx.get(key, key))   # a context binding, else a literal id
```

So a rule could say "the entity bound to `actor`" or "the entity literally
called `npc_sera_vance`". It could not say **"the entity that this other
entity's field names."**

That third form is what data-driven content actually needs. A contract knows
who posted it; an item knows who owns it; a quest knows who gave it. The
information is already in the data — the effect layer just had no way to
follow it.

Discovered while wiring a life-sim's contract board (2026-08-17). Reporting a
contract should move trust with **its own poster**. With only literal ids
available, the options were:

- **One rule per poster.** Two posters today, so four rules (on-time and late
  for each). The rule bodies are identical apart from one string. Adding a
  third poster means remembering to clone them again — and forgetting does
  not fail loudly, it just silently skips the trust change for contracts that
  NPC posted. This is the same shape as the `show_toast` one-rule-per-variant
  limitation, and it scales just as badly.
- **Denormalise the poster onto the player.** Write `active_contract_poster`
  when accepting so the report rule can read a binding. That is a cache of a
  fact the contract already owns, and caches drift.

Neither is a content problem to be worked around; both are symptoms of a
missing primitive.

## Decision

Add a third resolution form: **a dotted path rooted at a live context binding
resolves to the entity that path names.**

One new function, `EffectResolution.entity_id(v, ctx, env)`, becomes the
single place that decides what an entity reference in JSON means:

| Form | Example | Resolves to |
|---|---|---|
| context binding | `"actor"`, `"row"`, `"self"` | the bound id |
| **dotted path** | `"self.properties.poster"` | **the entity that field names** |
| anything else | `"npc_sera_vance"` | a literal id |

`target()` and `resolve_id()` both delegate to it, so all 19 id-resolving call
sites gain the capability at once. No effect needed changing; no new verb was
added. Per `.claude/rules/post-mortem.md` step 3a, the fix is at the primitive,
not at the one call site that exposed the gap.

## Consequences

**A dot is the disambiguator, and that is load-bearing.** Entity ids never
contain a dot, so no string that resolves as a literal today can be
reinterpreted by this change. The rule is deliberately narrow on both sides:
the path is followed only when the string contains a dot **and** its head is a
live context binding. A dotted string rooted at nothing (`"some.unbound.thing"`)
stays literal and never reaches the parser.

**Why not just run every id through `Formula.evaluate`.** That is the obvious
implementation and it is a trap — it reopens the bug class fixed in `caabe39`.
`Formula.looks_like_formula` accepts any lowercase-leading string, so every
plain entity id (`npc_sera_vance`, `player_1`) would be parsed as an
expression, fail, and resolve to null. The gate on "contains a dot AND head is
bound" is what keeps this precise rather than permissive.

**Enables**: a rule can act on a relationship the data describes rather than
one the rule hardcodes. Contract → poster, item → owner, quest → giver are now
one rule each, and adding an Nth poster requires no rule edits at all.

**Precludes**: nothing. Strictly additive — the two prior forms behave
identically.

**Cost**: one formula evaluation per dotted id reference, incurred only by
effects that use the new form.

## Alternatives considered

- **A dedicated `target_from: {entity, field}` payload.** More explicit, but
  it is a second syntax for a thing that already has one, and it needs adding
  to every effect that resolves an id. Worse everywhere the dotted form works.
- **Leave it to content (one rule per value).** What triggered the ADR. Scales
  with the data, fails silently when someone forgets a copy, and the failure
  surfaces as "that NPC never seems to like me" rather than as an error.
- **Denormalise onto the actor at accept time.** Cheapest to build, but stores
  a second copy of a fact and drifts the moment anything else can change it.
