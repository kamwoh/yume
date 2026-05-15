# ADR 0034 — Dynasty / heir succession primitive

_Date: 2026-05-09_
_Status: proposed_

## Context

Aldenmere Phase 4 introduces a **multi-generational arc**: the
player character ages, eventually dies, and an heir takes over the
controlled actor. This is the capstone of the lifecycle work
established by ADR 0036 (aging) — without succession, "you die at
80" is a hard game-over screen rather than the start of an emergent
dynasty. The merchant game's "Uncle's debt → your shop" story beat
is a one-shot ancestor of this; Phase 4 generalizes it into an
arbitrary-depth heir chain across generations.

Three forces shape the ADR:

1. **Selective inheritance.** Inventory and faction reputation must
   transfer (otherwise the player loses everything they built and
   the world loses memory of their relationships). ESSENTIAL
   knowledge (core techs from ADR 0033's tech-tree) transfers so
   civilization-scale progress accumulates across generations.
   Class progress (per-class XP from ADR 0030) DOES NOT transfer —
   the heir starts class progression fresh. This is the design
   "every generation rediscovers their own path" — without it, a
   level-99 farmer's heir starts as a level-99 farmer, collapsing
   the per-generation specialization arc.

2. **Casual / test mode.** Some players (and most QA scenarios)
   want to play indefinitely without dying. An infinite-life toggle
   suppresses death without removing aging — visible aging stays as
   Discovery aesthetic flavor, but `entity_died` never fires for
   the player.

3. **Multi-heir branching.** A player with 2-3 heirs creates
   emergent dynastic stories — first-born takes over, but if they
   die in combat, second-born inherits; the player who built up
   three children sees their second arc when the eldest perishes.
   If all heirs die, game-over (true terminal state).

Today the engine has no concept of "the player-controlled actor
can change identity." ADR 0016 (multi-actor framework) gave us
`switch_actor` — the runtime ability to swap which entity receives
input + camera. ADR 0010 (save/load) gave us snapshot persistence.
ADR 0033 (tech-tree) marks core vs derived techs. ADR 0036 (aging)
emits `entity_died`. Dynasty composes these — it's the "succession
glue" that makes them a coherent multi-generational system.

User asked specifically:

> "Phase 4 — player ages, dies, heir takes over. Inventory + faction
> reputation + ESSENTIAL knowledge transfer. Class progress does NOT
> (heir starts class fresh). Optional infinite-life mode for casual
> play. Multi-heir branching for emergent dynastic stories."

## Decision

Add a **dynasty primitive** that composes existing engine primitives
with a small set of inheritance-shaped effects and a single
`dynasty_director` interpreter module. Death triggers a JSON-declared
inheritance policy that transfers selected sub-stores from the
deceased actor to the heir, then routes input + camera to the heir
via ADR 0016's `switch_actor`.

### Schema additions

#### On any actor entity (player or heir)

```jsonc
{
  "id": "player",
  "tags": ["player", "human"],
  "state": {
    "age": 47,                  // ADR 0036 — incremented by aging
    "max_age": 80,              // ADR 0036 — death threshold
    "heirs": ["heir_1", "heir_2"],   // ordered list, first-eligible takes over
    "dynasty_id": "house_aldermere"  // optional — links generations for query
  }
}
```

`heirs` is an ordered array of entity ids. The first non-dead heir
in the list takes over on death; if all are dead, the game emits a
`dynasty_extinct` signal which downstream rules can route to a
proper game-over screen.

#### On any heir entity

```jsonc
{
  "id": "heir_1",
  "tags": ["named_npc", "heir", "human"],
  "state": {
    "is_heir_to": "player",
    "age": 12,
    "dynasty_id": "house_aldermere",
    "inheritance_policy": {
      "inventory": "all",          // "all" | "none" | array of item-tag filters
      "reputation": "all",         // "all" | "none" | array of faction ids
      "core_techs": true,          // bool — ADR 0033 tech-tree filter "core_only"
      "class_progress": false,     // bool — heir starts class fresh
      "relationships": "family"    // "all" | "none" | "family"
    }
  }
}
```

The `inheritance_policy` lives on the HEIR (not the source) because
it represents "what this heir is willing/able to receive" — a child
born outside the household, for example, might have
`relationships: "none"` reflecting that they didn't grow up around
the parent's friends.

#### Settings.json toggle (per ADR 0013)

```jsonc
{
  "infinite_life": false   // if true: aging fires but entity_died is suppressed for player tag
}
```

### New effects (4 total)

All four are **composition primitives over existing stores**, not
genre-specific shortcuts. Each maps to "move data of type X from
entity A's sub-store to entity B's sub-store" — engine-generic, not
"give-the-heir-the-shop."

| Effect | Reads | Writes | Notes |
|---|---|---|---|
| `transfer_inventory` | source entity's `state.inventory` | target entity's `state.inventory` | Append-then-clear-source. Items keep their state (durability, contents). Honors `filter` payload (item-tag predicate). |
| `transfer_reputation` | source entity's `state.reputation` (faction → number) | target entity's `state.reputation` | Replace-merge. If target has existing reputation with faction X, max(source, target) wins. |
| `transfer_techs` | source entity's `state.known_techs` (array) | target entity's `state.known_techs` | Filter param: `"all"` \| `"core_only"` (reads ADR 0033's `tech_tree.core` flag) \| array of tech ids. |
| `transition_player_to` | _entity ref_ | swaps controlled actor | Calls ADR 0016's `switch_actor` under the hood + reparents camera per `follow_active_actor` mode. Optional `clear_party: true` to dismiss old party (ADR 0026). |

These effects are **NOT semantic verbs** under Invariant #2 because
they don't encode genre meaning ("damage", "level_up", "harvest").
They encode **store-to-store data movement** — the same primitive
shape as Yume's existing `state_set` (mutate one field) generalized
to "copy a sub-tree of state between entities." A factory game
(parent factory → spawned subsidiary) or a roguelike (NG+ carry-
over) would use the SAME effects with different policies. See
"Alternatives considered" §A for why we didn't fold these into
`state_set`.

### Inheritance flow (rule-level)

The succession itself is a **rule**, not a primitive. Authored in
per-game JSON, it composes the new effects:

```jsonc
// data/<game>/game/goals.json
{
  "id": "dynasty_succession_on_player_death",
  "trigger": {"type": "signal", "name": "entity_died"},
  "query": {"tags_all": ["player"]},
  "require": {
    // pick first eligible heir; ADR 0019 macro can express this concisely
    "heir": {"tags_all": ["heir"], "state": {"is_heir_to_eq": "self.id",
                                              "age_gte": 12,
                                              "life_stage_neq": "dead"}}
  },
  "effect": [
    {"type": "transfer_inventory",  "from": "self", "to": "heir"},
    {"type": "transfer_reputation", "from": "self", "to": "heir"},
    {"type": "transfer_techs",      "from": "self", "to": "heir",
     "filter": "core_only"},
    {"type": "emit", "signal": "dynasty_succession",
     "payload": {"deceased": "self.id", "successor": "heir.id"}},
    {"type": "transition_player_to", "target": "heir.id"}
  ]
}

// Fallback when no eligible heir exists
{
  "id": "dynasty_extinct_on_player_death_no_heir",
  "trigger": {"type": "signal", "name": "entity_died"},
  "query": {"tags_all": ["player"]},
  "require_not": {
    "heir": {"tags_all": ["heir"], "state": {"is_heir_to_eq": "self.id",
                                              "life_stage_neq": "dead"}}
  },
  "effect": [
    {"type": "emit", "signal": "dynasty_extinct"},
    {"type": "transition_screen", "target": "game_over"}
  ]
}
```

This keeps the engine's job narrow: **the engine provides the
transfer effects + actor swap; the GAME decides via rules when and
why succession fires.** A different game might want succession on
abdication (signal `player_abdicated`) instead of death — same
effects, different trigger.

### Engine module: `dynasty_director.gd`

Responsibilities:

1. **Register the four new effect types** in `effect_apply.gd`'s
   dispatch table. Each is ~20-30 LoC plus shared validation.
2. **Heir resolution helper**: `resolve_first_eligible_heir(player)`
   walks `state.heirs` in order, returns first non-dead entity.
   Used by both the rule's `require` (via a query op extension) and
   the `transition_player_to` effect when payload contains
   `auto_pick_heir: true`.
3. **Infinite-life suppression**: hooks `entity_died` signal at
   emit-time; if `settings.infinite_life == true` AND the dying
   entity has tag `player`, the signal is dropped (does not fire
   subscribers). Aging continues — only the death event is
   suppressed. This is the ONE point where dynasty intercepts
   another primitive's behavior; it's gated behind a settings flag
   so default behavior is unchanged.
4. **Atomic transition**: all four transfer effects + the
   `switch_actor` happen within ONE phase boundary (per ADR 0009
   freeze-policy + Invariant #9). Save/load mid-transition is
   impossible because the transition is one-tick atomic.

LoC estimate: ~190
- `dynasty_director.gd`: ~120 (4 effect impls + heir resolver +
  infinite-life hook)
- `effect_apply.gd` dispatch entries: ~20
- `effect_spec.gd` schema validation: ~30
- ADR 0036 hook for infinite-life suppression: ~20

### Save/load contract (ADR 0010 interaction)

Heir entities persist via their normal `persistent` tag (ADR 0010
§persistence-policy). The `is_heir_to` and `inheritance_policy`
fields are part of `state` and serialize automatically. The active-
actor reference (which entity is the player) is already saved by
ADR 0016 multi-actor in `world_state.active_actor_id`.

Mid-transition save is structurally impossible (atomic phase
boundary above). Save BEFORE death + load = pre-death state;
Save AFTER succession + load = post-succession with heir as actor.
No "halfway through inheritance" failure mode.

### Validation

`tools/validate_dynasty.py` (new):
- Every entity tagged `heir` must have `state.is_heir_to` set.
- Every `state.heirs` array must reference entity ids that exist in
  the same level OR are tagged `persistent` (otherwise the heir
  vanishes when its level unloads).
- Every `inheritance_policy` field uses one of the documented
  values; warn on typos.
- `transfer_techs` with `filter: "core_only"` requires ADR 0033
  tech_tree.json to declare which techs are core; validator
  cross-checks.

### Test coverage (Phase 1 spec)

10 unit tests in `test_runner.gd`:

| Test | Verifies |
|---|---|
| `dynasty.test_aging_triggers_death` | Player at age 80 + ADR 0036 lifecycle → `entity_died` fires |
| `dynasty.test_transfer_inventory_moves_all` | After succession, heir holds all source's items + source inventory empty |
| `dynasty.test_transfer_reputation_max_merge` | Heir's pre-existing rep with faction X is max'd with parent's rep |
| `dynasty.test_transfer_techs_core_only_filter` | Source has [smithing(core), masterwork(derived)]; heir gets [smithing] only |
| `dynasty.test_class_progress_not_transferred` | Source level-5 farmer; heir's farmer class_progress is empty/level-0 |
| `dynasty.test_transition_player_to_swaps_actor` | After effect, ADR 0016 active_actor_id == heir's id; camera follows heir |
| `dynasty.test_infinite_life_mode_suppresses_death` | settings.infinite_life=true; player at age 100; aging fires but `entity_died` doesn't reach subscribers |
| `dynasty.test_multi_heir_first_eligible_picked` | Player heirs=[h1, h2]; h1 dead, h2 alive → succession picks h2 |
| `dynasty.test_all_heirs_dead_extinct_signal` | Player heirs=[h1, h2]; both dead → `dynasty_extinct` signal fires; no `transition_player_to` |
| `dynasty.test_save_load_atomic_no_partial_transition` | Save mid-rule (impossible since atomic) — load yields either pre-death or post-succession state, never partial |

Bonus emergent test (counts in budget): per-generation class progress
accrues independently — playthrough scenario test (not unit test)
verifies a 3-generation chain where each generation's farmer level
is independent.

### Implementation plan

**Phase 1** (engine + tests):
- Implement `dynasty_director.gd` + 4 effects + heir resolver.
- Wire infinite-life hook into ADR 0036 lifecycle.
- 10 unit tests pass.
- Validator script + sync-time check.

**Phase 2** (catalog + skill discipline):
- Add `@lib.entities.heir_base` with default `inheritance_policy`.
- Update yume-systems-designer skill: when GDD says "dynasty" or
  "generations" or "heir," emit dynasty rules using these effects.
- Update yume-content-designer skill: heir entities require
  `is_heir_to` + `inheritance_policy`; validator enforces.
- Update yume-story-planner skill: succession is a structural
  story beat — reserve narrative slots for "old player's funeral"
  and "heir's awakening" scenes.

**Phase 3** (Aldenmere Phase 4 use):
- Aldenmere players generate heirs via Phase 3 family system.
- 5 famous-figure storylines optionally trigger on succession
  events (e.g. "the heir of the founder discovers steel").

## Consequences

### Enables
- Multi-generational gameplay arcs without engine-side hardcoding
  of "who is the player."
- Emergent dynastic stories — branching when first heir dies in
  combat reroutes the dynasty to second heir, which produces
  different downstream content.
- Casual / test play via infinite-life toggle; same JSON content
  works for both modes.
- Cross-generation civilization progression (core techs accumulate;
  per-class skill resets give each generation a fresh specialization
  arc).
- Reusable for non-Aldenmere games — a roguelike NG+ carry-over,
  a king's-line strategy game, a corporate-succession sim all use
  the same effects with different policies.

### Constrains
- Heir entities must be created BEFORE death (no auto-spawn at
  succession time). This is intentional — the player's investment
  in raising heirs IS the gameplay loop.
- Inheritance is one-shot per death. No partial / staged
  inheritance ("eldest gets gold, youngest gets house"). That
  would need a future ADR (estate-distribution primitive) if
  demand emerges.
- Active-actor swap is atomic per phase boundary — if a follow-up
  rule fires `transition_screen` before `transition_player_to`
  completes, ordering must be enforced via `before` / `after`
  rule deps. Documented in skill update.

### Doesn't enable
- Sibling-rivalry mechanics (faction split between heirs) — that's
  a content-rule pattern, not a primitive.
- Heir-by-marriage where two dynasties merge — possible in JSON via
  manually setting `is_heir_to` + tagged inheritance_policy, but
  no engine support for "marriage" as a primitive.
- Multiplayer succession (different humans control different
  heirs) — out of scope, would need ADR 0020 (external IPC).

### Cumulative invariant pressure
Adds 4 effect types + 1 engine module to Yume's interpreter
surface. Each effect is a generic store-mover, not a genre verb.
Total effect count grows from N → N+4. Surface manageable; tech-
director should re-audit at the cumulative ADR-0029-through-0036
landing point.

## Alternatives considered

### A) Fold transfers into `state_set` with a "copy_subtree" payload

We could express `transfer_inventory` as
`{"type": "state_set", "target": "heir", "field": "inventory",
"value_from": "self.state.inventory"}` plus a follow-up `state_set`
to clear the source.

**Pros**: zero new effect types; pure composition of an existing
verb.
**Cons**:
1. Three rules per transfer (copy + clear + emit signal) instead of
   one effect. Authoring tedium scales by N inheritance categories.
2. No atomic guarantee — between the copy and the clear, a save
   would catch double-state.
3. Filter semantics (`core_only` for techs, item-tag predicates for
   inventory) need either three more `state_set` variants OR a
   formula-language extension. Either grows the surface anyway.
4. No clean place for the infinite-life suppression hook.

The 4 transfer effects are coherent, atomic, store-typed — a
better factoring than fighting `state_set`'s field-at-a-time shape.

### B) Single mega-effect `succeed_dynasty(source, heir, policy)`

One effect that does ALL transfers + actor swap based on the
policy block.

**Pros**: simplest authoring; one rule fires the whole thing.
**Cons**: violates Invariant #2 (semantic effect type — encodes the
genre concept "dynastic succession" into engine vocabulary).
A roguelike NG+ would not call it "dynasty." A future game
wanting only inventory carry-over (no actor swap) is forced to
opt out via policy fields, but the effect still SOUNDS like
something it isn't.

The 4-effect breakdown lets each game compose what it needs:
inventory-only carry-over uses just `transfer_inventory`; full
dynasty uses all four. Decoupling is genre-neutral.

### C) Defer to per-game GDScript

Each game writes its own dynasty handler in GDScript.

**Pros**: zero engine work.
**Cons**: violates Invariant #1 (JSON-only content channel) AND
Invariant #8 (engine = primitives + interpreter). Aldenmere's
dynasty rules would not be portable to a future succession-
shaped game.

### D) Use macros (ADR 0019) instead of new effects

Author dynasty as a macro that expands to N `state_set` calls.

**Pros**: leverages existing primitive.
**Cons**: ADR 0019 macros are LOAD-TIME expansion of effect names
to effect-shapes. The transfer logic is RUNTIME (heir might be
dead, filter must evaluate against actual tech-tree state, etc.).
Macros are wrong-scope.

We picked the present design (4 generic transfer effects + 1
director module + JSON-driven inheritance policy) because it:

1. Stays within Invariant #2 (each effect is generic data movement,
   not a genre verb).
2. Composes existing primitives (ADR 0016 actor swap, ADR 0033
   tech filter, ADR 0036 death signal, ADR 0010 persistence).
3. Supports the 3 design forces (selective inheritance, infinite-
   life mode, multi-heir branching) without genre-specific code.
4. Reusable across games (any succession-shaped genre, not just
   civilization sims).

## Risks

1. **Multi-heir branching complexity** — emergent dynastic stories
   with N heirs × M death timings × P heir-attribute combinations
   produce a state space hard to fully test. Mitigation: 10 unit
   tests cover the core cases; scenario tests cover 3-generation
   chains; the `dynasty_extinct` fallback ensures no game is left
   in a stuck state regardless of branch.
2. **Save schema drift** — adding `state.heirs` + `is_heir_to` to
   actor entities means saves from pre-ADR-0034 builds need
   migration. Mitigation: ADR 0010's schema versioning; missing
   fields default to empty arrays / null which the rules treat as
   "no heirs" → `dynasty_extinct` → game-over. Pre-Phase-4 saves
   never trigger the rule.
3. **Atomic transition vs. expensive transfers** — a player with
   10000 items takes longer than one phase boundary to copy.
   Mitigation: profile in Phase 4 build; if transfer takes
   >16ms, batch over multiple phase boundaries with a
   `dynasty_in_progress` lock state. NOT in scope for this ADR;
   tracked as a follow-up performance concern.
4. **Cross-ADR dependency stack** — dynasty depends on 0016, 0010,
   0033, 0036. Any regression in those breaks dynasty. Mitigation:
   tech-director enforces full invariant suite on each ADR
   landing per engine_roadmap.md cross-cutting risk note.
5. **Player attachment to character** — succession is a major
   narrative beat. If transfer feels mechanical ("inventory
   teleported to heir"), the emotional weight is lost. Mitigation:
   yume-story-planner reserves "old player's funeral" + "heir's
   awakening" scenes; yume-juice-designer adds camera/audio juice
   to the transition. NOT engine work — content + skill discipline.

## References

### Code locations affected
- `godot/scripts/engine/dynasty_director.gd` — new module (~120 LoC)
- `godot/scripts/engine/effect_apply.gd` — register 4 new effects (~20 LoC)
- `godot/scripts/engine/effect_spec.gd` — schema validation (~30 LoC)
- `godot/scripts/engine/lifecycle_director.gd` (ADR 0036) — hook for infinite-life suppression (~20 LoC)
- `godot/scripts/engine/tests/test_runner.gd` — 10 new tests
- `tools/validate_dynasty.py` — new sync-time validator

### Cross-ADR dependencies
- ADR 0001 — seven primitives (this ADR adds effects, not primitives)
- ADR 0010 — save/load persistence (heir state survives across sessions)
- ADR 0013 — settings schema (`infinite_life` toggle)
- ADR 0016 — multi-actor framework (`switch_actor` is the foundation
  for `transition_player_to`)
- ADR 0019 — rule-plugin macros (succession rules can use macros for
  conciseness; not required)
- ADR 0027 — cross-game JSON reuse (`@lib.entities.heir_base`)
- ADR 0033 — technology-tree primitive (provides `core` flag for
  `transfer_techs filter: "core_only"`)
- ADR 0036 — lifecycle / aging primitive (emits `entity_died`; this
  ADR hooks the suppression for infinite-life mode)

### Discussions / reviews
- `docs/games/aldenmere/world.md` — Aldenmere world bible Phase 4 spec
- `docs/games/aldenmere/engine_roadmap.md` — Aldenmere ADR sequence
- Tech-director review pending — see "Tech-director review" section
  (to be added on review pass).

### Land target
Pre-Phase 4 build, AFTER ADRs 0030 (class), 0033 (tech-tree),
0036 (aging) per engine_roadmap.md dependency graph.
