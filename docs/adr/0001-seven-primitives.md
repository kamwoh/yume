# ADR 0001 — Seven primitives + Engine = Primitives + Interpreter

_Date: 2026-04-22_
_Status: accepted_

## Context

Yume started life as a 3D agent-farming sim with hardcoded RPG-flavored
semantics: `damage` effect type, `need_decay` for hunger, brain-class
hierarchy (5 brains), inventory.gd, hp_bar.gd. It worked but was
genre-locked — every new game required new GDScript.

The user clarified the actual goal mid-2026-04: a JSON-driven
simulation framework where any simulation-shaped game (ecology,
farming, shooter, RPG, chess, survival) is expressible by JSON
composition. No genre-specific engine code.

This required deciding what the engine knows vs what data knows.

## Decision

Yume engine is built on **seven composable primitives**:

1. **Entity** — anything with state. Single class, no subtypes.
2. **Tag** — flat string membership, no hierarchy.
3. **Rule** — `{trigger, query, require?, chance?, effect}`.
4. **Trigger** — when a rule fires (`tick`, `contact`, `signal`,
   `input`, `spawn`, `despawn`, `relation_changed`, reserved
   `scheduled`).
5. **Effect** — what mutates: `state_*`, `spawn`, `remove`, `transform`,
   `relate`/`unrelate`/`transfer_relation`, `velocity_set`, `emit`,
   `tag_add`/`remove`.
6. **Query** — declarative entity match: tags, properties, state with
   operators (`_eq/_ne/_gt/_lt/_gte/_lte/_atleast/_atmost`), relations,
   radius, limit, order_by.
7. **Relation** — typed directed edge between entities. Inventory,
   ownership, containment, parent/child, party, board state.

The unifying principle is **invariant #8**: "Engine = primitives +
interpreter." For every domain Yume touches (rules, shapes, audio,
asset binding, formulas), the engine ships a fixed primitive
vocabulary in code, and all compositions live in JSON. Adding a
vocabulary item requires engine code; adding a composition requires
only JSON.

Plan and Knowledge primitives are **flagged as deferred** to Tier 3
(actors) — they're agent-side concerns, not world-side. The seven
above are sufficient for simulation-shaped games (W5 acid test
passed across 5 genres).

## Consequences

**Positive:**

- Adding new genres = JSON only. Verified across ecology, farming,
  shooter, RPG, chess (W5).
- Engine stays small (~2200 LOC) and maintainable.
- Clean test invariant: grep `scripts/engine/` for forbidden semantic
  effect names — zero matches required (W5.7 no-genre-leak).
- Renderer-agnosticism: same JSON runs in 2D and 3D scenes.

**Negative:**

- Less expressive than full game engines. Genres requiring continuous
  physics (driving sims, soft-body) or precision-timing (rhythm games)
  are out of scope.
- JSON is verbose. Authoring a complex game is many hundreds of lines
  of JSON. (Mitigation: Tier 2.5 pipeline that generates JSON from
  prose.)
- Some intuitive-feeling concepts (HP, XP, ammo) become "just state
  fields" with engine ignorance — readers need orientation that this
  is by design.

**Neutral:**

- Full chess legality is content-deep, not engine-deep. The framework
  supports it; we shipped a 4×4 mini in W5.5 and full 8×8 + perft is
  W6 content.

## Alternatives considered

**A. Stay with the 3D agent-farming sim.** Familiar, working. Genre-locked
to RPG-survival. Killed by the "any game" goal.

**B. Six primitives (no Relation).** Initial draft. Independent reviewer
caught the gap during W0 spike: `carrying: {item: count}` as a state
field breaks the queries-are-first-class invariant. Inventory, board
state, party need first-class typed edges.

**C. Build full ECS (Unity DOTS-style).** Component-based. More flexible
but heavier abstraction. Yume's 7 primitives + JSON are simpler; ECS
is overkill at this scale.

**D. Engine includes semantic effects but they're "configurable."** Tried
this in the original Yume3D — `damage` had configurable scaling, etc.
Eventually accumulates genre assumptions. Killed.

## References

- `docs/30_framework_primitives.md` — full contract doc
- `docs/timeline/entries/04_seven_primitives.js` — initial six → seven decision
- `docs/timeline/entries/03_independent_review.js` — review that caught Relation gap
- W5 acid test — 5 demos pass on identical engine code
- Commit `3cb878b` (W0 + strip), `6126503` (W1 + Tier 2.5 plan)
