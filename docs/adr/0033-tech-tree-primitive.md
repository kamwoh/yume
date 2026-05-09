# ADR 0033 — Technology-tree primitive

_Date: 2026-05-09_
_Status: proposed_

## Context

Aldenmere Phase 4 (Civilization) commits to **knowledge that
accumulates across NPCs and across generations** (world.md §"Phase 4
— Civilization"). The world bible names five tech tracks that must
all progress emergently:

- **Smithing** — smithing → ironworking → steel
- **Agriculture** — farming → irrigation → crop rotation
- **Medicine** — herbalism → surgery → vaccines
- **Magic** — four schools (elemental / divine / shadow / nature),
  each its own progression chain
- **Scholarly** — philosophy → mathematics → engineering

Phase 4's Fellowship + Narrative aesthetic specifically depends on
knowledge being **earned, transferred, and inherited** — not handed
out by the engine. A blacksmith who masters smithing rolls per-day
to discover ironworking; an apprentice gains tech only by being
bound to a master via ADR 0026's party-member relation; an heir
inherits SOME of a parent's knowledge per ADR 0034's dynasty
succession. Without this, "tech tree" collapses to a stat field
with no narrative weight.

There is no current way to author this in Yume primitives. The
closest existing shape is per-NPC `state_init` flags (`{"knows_iron":
true}`) — but that:

- Requires authoring every prereq check by hand as a query in every
  rule that gates on it (10 nodes × 5 trees × N consumer rules →
  combinatorial rule explosion)
- Does not encode the **graph** structure (which tech depends on
  which) — the prereq logic is duplicated everywhere
- Does not centralize the **discovery probability** — discovery
  rolls scatter across rules, making balance tuning a sweep over
  the entire content tree
- Does not compose with ADR 0026's master/apprentice edges — knowledge
  transfer becomes a bespoke per-pair rule
- Does not survive ADR 0034's heir succession cleanly — the
  "core_techs" set has to be enumerated by hand at each succession
  point

Per Invariant #8 (engine = primitives + interpreter), this is the
canonical shape for a new primitive: a fixed JSON schema (tech-tree
graph + per-entity `known_techs` set) + a thin interpreter
(`tech_tree.gd` exposing three effect types) + integration with
existing primitives (relations for transfer, signals for chronicle,
save_policy for persistence). All compositions — which trees exist,
which techs they contain, which classes are eligible to discover what,
which techs count as "core" for inheritance — stay in JSON.

Constraints:

- Cannot break Invariant #2 (no semantic effect types). The three
  new effects (`try_discover_tech`, `learn_from_master`,
  `pass_to_apprentice`) operate on a generic `known_techs` set;
  none of them name specific techs in engine code.
- Cannot break Invariant #3 (no entity-class hierarchy). Eligibility
  to discover smithing is a `tags_all` query on `["smith"]`, NOT a
  hardcoded class check. Any entity with the right tag rolls.
- Must compose with ADR 0026 (party-member primitive) — apprentices
  are party members of masters; transfer rule consumes the existing
  `party_member_of` relation, no new edge type.
- Must compose with ADR 0030 (occupation/class primitive) — class
  tags gate discovery eligibility; class verbs may be unlocked by
  techs (`forge_steel` verb requires `known_techs` includes `steel`).
- Must compose with ADR 0034 (dynasty / heir succession) — heir
  inherits techs flagged `core: true` in the tree definition;
  non-core techs reset.
- Must compose with ADR 0031 (zone-state primitive) — a city's
  aggregate `tech_availability` is the union over its NPCs'
  `known_techs`, queryable via existing zone-state bindings.
- Discovery probability must be **balanceable as a single number per
  node** — author tunes `discovery_chance`, not the rule firing it.
- Must persist cleanly across save/load (ADR 0010) — `known_techs`
  is just an entity state field, no special handling.

The primitive lands in Phase 4 but the schema is forward-compatible
from Phase 1 (entities can carry `known_techs: []` immediately;
discovery rules and the director only activate when content
references a tree).

## Decision

Add a **Technology-tree primitive** to the JSON schema + a thin
`TechTreeDirector` interpreter that exposes three effect types and
one query operator on the existing primitive surface.

### 1. New JSON file — `tech_trees.json`

Tech trees live in `data/<game>/tech_trees.json` (one file per
game; deferred-load if absent).

```jsonc
{
  "trees": [
    {
      "id": "smithing",
      "nodes": [
        {"id": "smithing",
         "prereqs": [],
         "discovery_chance": 0.0,        // 0 = starter; granted at content layer
         "core": true,                    // inherited by heirs
         "eligibility_tags": ["smith"]},  // who can DISCOVER this node
        {"id": "ironworking",
         "prereqs": ["smithing"],
         "discovery_chance": 0.05,        // 5% per discovery roll
         "core": true,
         "eligibility_tags": ["smith"]},
        {"id": "steel",
         "prereqs": ["ironworking"],
         "discovery_chance": 0.02,
         "core": false,                   // late-tier, lost on succession
         "eligibility_tags": ["smith"]}
      ]
    },
    {"id": "magic_elemental", "nodes": [...]},
    {"id": "agriculture",     "nodes": [...]}
  ]
}
```

Field semantics:

- `id` (per tree, per node) — string identifier; node ids are
  globally unique across the file (a node referenced in `prereqs`
  is looked up by id; cross-tree prereqs allowed).
- `prereqs` — array of node ids. Empty = starter node.
- `discovery_chance` — float [0.0, 1.0]; per-roll probability.
  Authoring guidance: 0.05 ≈ ~20 expected days for a single eligible
  NPC at 1 roll/day; 0.02 ≈ ~50 days. See § Balance.
- `core` (default `false`) — heirs inherit this node via ADR 0034;
  non-core techs reset on succession.
- `eligibility_tags` — `tags_all` filter applied to discovery
  candidates. Empty array means "any entity with the tree's
  `known_techs` set + valid prereqs."

### 2. New entity state field — `known_techs`

Entities that participate in the tech system carry:

```jsonc
"state_init": {
  "known_techs": ["smithing"]            // array of node ids
}
```

The engine treats this as an **append-only set** during normal
play (you can know more, never less — except via ADR 0034
succession which resets non-core nodes). The set semantic is
enforced by the director (duplicate `learn` is a no-op); the
storage is a plain JSON array for save/load + introspection.

### 3. Three new effect types

#### `try_discover_tech`

Rolls `discovery_chance` for one or more eligible-and-ready nodes
on the target's tree. Used by tick rules to drive emergent
discovery.

```jsonc
{
  "type": "try_discover_tech",
  "target": "self",                      // entity to award the tech to
  "tree": "smithing",                    // which tree to roll on
  "max_rolls_per_call": 1                // default 1; safety cap
}
```

Director semantics (per call):
1. Look up `target.state.known_techs`.
2. Enumerate nodes in `tree` whose: (a) `prereqs` are all in
   `known_techs`, (b) the node itself is NOT in `known_techs`,
   (c) the target's tags pass the node's `eligibility_tags`.
3. For up to `max_rolls_per_call` candidates (in declaration
   order — deterministic), roll `randf() < discovery_chance`. On
   hit: append node id to `known_techs`, emit `tech_discovered`
   signal with payload `{entity, tree, node, source: "discovery"}`.

If multiple nodes are ready, only the first that hits is awarded
per call (prevents single-tick double discovery from making the
chain trivial). Subsequent ticks roll independently.

#### `learn_from_master`

Transfers one node from a related master to the target, gated by
prereqs. Used by signal-triggered rules — typically apprenticeship
milestones.

```jsonc
{
  "type": "learn_from_master",
  "target": "self",                      // apprentice
  "master_via_relation": "party_member_of",  // ADR 0026 edge
  "tree": "smithing",                    // optional — if omitted, all trees
  "max_per_call": 1                      // default 1; lessons are one-at-a-time
}
```

Director semantics:
1. Resolve master via the named relation (ADR 0026 — apprentice's
   `party_member_of` outgoing edge points to master).
2. Compute the set difference: master's `known_techs` minus
   apprentice's `known_techs`, filtered by `tree` (if given).
3. Filter to nodes whose `prereqs` the apprentice already has
   (transfer respects the graph — you can't learn steel from a
   master who skipped ironworking).
4. Award up to `max_per_call` of those (lowest-id first for
   determinism). Emit `tech_learned` signal per award with
   `{entity, tree, node, source: "master", master_id}`.

If no master is reachable, the effect is a no-op (warns once at
load time if the apprentice has no outgoing relation but the rule
fires repeatedly — likely an authoring error).

#### `pass_to_apprentice`

Mirror of `learn_from_master`, fired from the master's perspective
(useful for signals like `master_taught_today` that originate on
the master). Resolves apprentices via the inverse of
`master_via_relation` and awards each one in turn.

```jsonc
{
  "type": "pass_to_apprentice",
  "target": "self",                      // master
  "apprentice_via_relation": "party_member_of",
  "max_apprentices_per_call": 4,
  "max_per_apprentice": 1
}
```

Equivalent to running `learn_from_master` once per apprentice; same
prereq + signal semantics.

### 4. New query operator — `state.known_techs_has`

Extends the existing `state` query to test set membership:

```jsonc
{
  "query": {
    "tags_all": ["smith"],
    "state": {"known_techs_has": "ironworking"}
  }
}
```

Returns entities whose `known_techs` array contains the named node.
Composable with other state operators (`_has` joins as another
state filter, never a top-level query field).

For the inverse — "find all entities who know X across the world" —
content authors use the existing query primitive with this
operator; no new entity-list API needed.

### 5. New formula binding — `entity.known_techs.has("X")`

Formulas (per Invariant #6) gain a single helper for set membership:

```
self.known_techs.has("ironworking")            → bool
target.known_techs.has("steel")                → bool
```

Implementation: when the formula evaluator sees `<binding>.known_techs`,
it returns the underlying array; `.has(X)` is the existing Godot
`Array.has` method exposed via `Expression`. No new primitive in
the formula evaluator — just documentation that arrays support `.has`.

### 6. Signals emitted

| Signal | Payload | Fires from |
|---|---|---|
| `tech_discovered` | `{entity, tree, node, source: "discovery"}` | `try_discover_tech` success |
| `tech_learned` | `{entity, tree, node, source: "master", master_id}` | `learn_from_master` / `pass_to_apprentice` success |
| `tech_inherited` | `{entity, tree, node, source: "heir", parent_id}` | ADR 0034 succession (fires from dynasty_manager, not this director — but documented here for completeness) |

Chronicle / story rules subscribe to these signals to log "Garron
discovered ironworking on Day 47" entries, fire toasts, update
HUD banners, etc. — same shape as every existing engine signal.

### 7. ADR 0034 (dynasty) integration — heir inheritance

When ADR 0034's `transition_player_to` (or its NPC-side
`succeed_to_heir`) fires, dynasty_manager calls into
TechTreeDirector for the inheritance step:

```
TechTreeDirector.inherit_to(heir, parent) →
  for tree in trees:
    for node in parent.known_techs intersect tree.nodes:
      if tree.node(node).core:
        heir.known_techs.append(node)  # if not already present
        emit "tech_inherited"
```

The `core: true` flag on each node is the authoring control for
generational survival. Authoring guidance: starter nodes
(`smithing`, `farming`, `herbalism`) are core — knowledge of "iron
exists" doesn't vanish when a master dies. Late-tier breakthroughs
(`steel`, `vaccines`, `crop_rotation`) are non-core — the wisdom
must be rediscovered or transferred to an apprentice BEFORE the
master dies. This creates the narrative tension Phase 4 wants:
*the master is old; if she doesn't take an apprentice this year,
her work dies with her.*

### 8. ADR 0031 (zone-state) integration — city tech availability

When ADR 0031 lands, zone-state binding gains a derived helper:

```
zone.<zone_id>.tech_availability(<tree_id>) → array of node ids
```

Returns the union of `known_techs` (filtered to the named tree)
across all entities currently inside the zone. Used by macro-
economy rules to gate production: a city without `ironworking`
known by any of its smiths cannot produce iron tools, regardless
of raw material availability.

This is computed lazily (on-query) over the zone's contained
entities; no eager aggregation needed at Phase 4 scale (≤500 NPCs
total, zones ≤50 NPCs each → 50-element union per call). If
performance demands it later, a periodic-cached variant lives
behind the same binding name without contract change.

### 9. Save/load (ADR 0010)

`known_techs` is a plain entity state array — persists automatically
under the existing entity-state save policy. No `save_policy.json`
changes required. Tech-tree definitions (`tech_trees.json`) are
content, not state — they reload from disk on each run, never
saved.

If a save references a node id that no longer exists in the
current `tech_trees.json` (author renamed/removed it post-save),
the loader drops the unknown node from `known_techs` with a
push_warning. Same fail-soft policy as ADR 0010's entity-tag
loading.

### 10. Director scheduling

`TechTreeDirector` is a thin module:
- Loads `tech_trees.json` at world boot; validates DAG structure
  (cycle detection in prereqs; node-id uniqueness).
- Registers the three effect types via the existing
  `EffectApply.register()` path.
- Exposes the inheritance helper for ADR 0034 to call.
- Holds a per-tree node lookup table (id → node-spec) for O(1)
  prereq + eligibility checks.

It does NOT tick. Discovery is driven by content-authored tick
rules (e.g., `interval: 86400` for once-per-in-game-day rolls).
This keeps invariant #8 clean: the engine doesn't decide when
discovery happens; content does.

## Consequences

### Enables

- **Single source of truth** for the tech graph — authors edit
  `tech_trees.json`, no rule rewrites
- **Centralized balance knob** — `discovery_chance` per node tunes
  era pacing without touching rules
- **Generational narrative** — `core` flag drives heir-knowledge
  loss/preservation, the engine for the "the wisdom must be passed
  on" beat
- **Cross-game reuse** — Aldenmere defines 5 trees; future games
  with tech progression import them via ADR 0027's `@lib.tech_trees.X`
- **Composes with party + class + dynasty** without bespoke wiring
  per integration

### Constrains

- Adds 3 effect types + 1 query operator + 1 implicit binding to
  the engine vocabulary — meaningful surface growth. Justified by
  the combinatorial-explosion alternative (per § Alternatives A).
- Tech-tree authoring becomes a real responsibility — Phase 4
  needs a `yume-tech-tree-designer` skill (or extension to
  `yume-systems-designer`) that owns the graph. Skill update is
  a content task, not engine work.
- Discovery balance is a real failure mode at scale. See § Balance
  + risks.

### Doesn't enable

- **Tech that requires multiple masters** ("learn steel only from a
  smith who also knows alchemy") — by design, single-master transfer.
  Authors compose multiple `learn_from_master` rules with different
  `tree` filters if needed, but the prereq graph is per-tree.
- **Tech decay / forgetting** — known_techs is append-only during
  life. A class of "you forget if you don't practice" rules belongs
  in content (`state_set known_techs = []` is allowed, but no
  engine-level decay mechanism).
- **Region-specific tech variants** ("eastern realm's smithing is
  different from western's") — each tree is global. Authors who
  need this declare separate trees (`smithing_east`, `smithing_west`)
  and gate eligibility via tags.
- **Runtime tree mutation** — `tech_trees.json` is load-time
  static. Adding a node mid-campaign requires a save migration.

## Balance — discovery probability at scale

The single most important authoring discipline for this primitive.
Bad numbers ruin Phase 4: too high → every NPC discovers
everything by Day 30 → no narrative weight. Too low → no
discoveries fire over a 200-day campaign → tech tree is dead
content.

The expected-discoveries math at scale:

```
expected_discoveries_per_era = (eligible_NPC_count) × (rolls_per_day)
                              × (campaign_days) × (discovery_chance)
```

Phase 4 reference numbers (5 kingdoms × 100 NPCs each, ~10%
eligible per tree, 1 roll/day, 200-day campaign):

| chance | NPCs eligible | days | expected total discoveries |
|---|---|---|---|
| 0.05 | 50 | 200 | 500 |
| 0.02 | 50 | 200 | 200 |
| 0.005 | 50 | 200 | 50 |

For a 3-node tree, "everyone discovers everything by Day 30" sets
in around chance ≈ 0.10. For "the breakthrough fires roughly once
per campaign" (signature moment territory), chance ≈ 0.001-0.005.

Authoring guidance baked into the future skill:
- Starter nodes: 0.0 (granted by content, not rolled)
- Mid-tier: 0.02-0.05 (multiple expected discoveries per campaign)
- Late-tier: 0.005-0.02 (rare; narrative moment)
- Legendary: 0.001-0.005 (ONE expected discovery per campaign)

QA test: a `balance_estimator` scenario test computes the expected
total per era from the JSON and warns if any tree exceeds 50
discoveries per 200-day Phase 4 campaign.

## Risks honestly named

1. **Discovery balance is the killer risk.** Even with a balance
   estimator, real campaign dynamics (population fluctuates as NPCs
   die, schedule changes per phase, eligibility-tag distributions
   shift with class system) make the "expected" math approximate.
   Mitigation: chronicle log + post-campaign QA review measure
   actual discoveries vs. expected; tune chance values as Phase 4
   ships its first playable build.
2. **Master-apprentice transfer with party-system lifecycle.** If a
   party member is removed mid-transfer (master dies, edge cuts),
   the rule should no-op cleanly. Director already returns no-op on
   missing relation; covered in test 5.
3. **Cross-tree prereqs (`steel` in `smithing` requires `mining` in
   `geology`)** — supported by spec but increases authoring
   complexity. Cycle detection at load catches accidents; explicit
   author intent is fine.
4. **save_policy interaction with `core` reclassification** — if an
   author flips a node from `core: true` to `core: false` between
   versions, existing saves keep the (now-shouldn't-be-inherited)
   node on already-inherited heirs. Acceptable — saves represent
   past play, not current spec. Documented in changelog.
5. **Engine surface growth.** 3 new effect types + 1 query op + 1
   binding helper. Tech-director review must verify these don't
   open semantically-overlapping shapes (e.g., `learn_from_master`
   and `pass_to_apprentice` are mirrors — keep them as TWO so
   each side of the relation can fire from its own perspective,
   but document that they share an implementation).

## Test plan

12 unit tests in `tests/test_runner.gd` (`_section("tech_tree
(ADR 0033)")`) plus 1 scenario test in
`data/<game>/tests.json`:

| # | Test | Verifies |
|---|---|---|
| 1 | `tech_tree.test_discovery_probability_respects_chance` | over 1000 simulated rolls at chance=0.05, observed rate is within ±20% of 0.05 |
| 2 | `tech_tree.test_prereq_blocking` | NPC with only `smithing` cannot discover `steel`; can discover `ironworking`; after gaining `ironworking`, can discover `steel` |
| 3 | `tech_tree.test_eligibility_tags` | NPC tagged `farmer` (not `smith`) cannot discover smithing-tree nodes even with chance=1.0 |
| 4 | `tech_tree.test_master_to_apprentice_transfer` | apprentice with `party_member_of` edge to master gains master's tech on `learn_from_master` call; respects prereqs |
| 5 | `tech_tree.test_master_missing_no_op` | apprentice with no outgoing `party_member_of` edge: `learn_from_master` is a no-op (no error, no signal) |
| 6 | `tech_tree.test_pass_to_apprentice_multi` | master with 3 apprentices: `pass_to_apprentice max_apprentices_per_call=4` awards each apprentice one missing tech |
| 7 | `tech_tree.test_multi_tree_independent` | NPC progresses in `smithing` AND `magic_elemental` independently; discovery in one doesn't affect the other |
| 8 | `tech_tree.test_query_known_techs_has` | `state: {known_techs_has: "steel"}` returns only entities whose array contains "steel" |
| 9 | `tech_tree.test_formula_binding_known_techs_has` | formula `self.known_techs.has("ironworking")` evaluates true/false correctly in rule context |
| 10 | `tech_tree.test_save_load_preserves_techs` | save with `known_techs: ["smithing", "ironworking"]`, reload, array survives intact |
| 11 | `tech_tree.test_signals_emitted` | `try_discover_tech` success emits `tech_discovered`; `learn_from_master` success emits `tech_learned`; payloads match spec |
| 12 | `tech_tree.test_dynasty_inheritance_core_only` | inherit_to(heir, parent) where parent knows `[smithing(core), ironworking(core), steel(non-core)]` → heir knows `[smithing, ironworking]`; emits 2 `tech_inherited` signals |

Scenario test (`data/<game>/tests.json`):
- `tech_balance_estimator`: load `tech_trees.json`, compute
  expected discoveries per tree per era from declared chances ×
  reference Phase 4 population, fail if any tree exceeds 50/era.

## Implementation plan

Phase 1 (engine, this ADR's scope):
- `scripts/engine/tech_tree.gd` (~220 LoC) — director module:
  - load + validate `tech_trees.json` (cycle detection, id
    uniqueness)
  - register 3 effect types via `EffectApply.register()`
  - `inherit_to(heir, parent)` helper exposed for ADR 0034
- `scripts/engine/query.gd` — extend `state` filter parsing with
  the `known_techs_has` operator (~10 LoC)
- `scripts/engine/effect_apply.gd` — wire the 3 new effects to
  director (~15 LoC)
- 12 new unit tests in `tests/test_runner.gd` (~150 LoC test code)
- `tools/gen_api_manifest.py` regenerates manifest with new effects
- Documentation:
  - Add ADR to `docs/adr/README.md` index
  - Cross-reference in `docs/30_framework_primitives.md` § Effects
    + § Tech-tree (new section under "domain primitives")

Phase 2 (Aldenmere content, separate ADR-implementation PRs):
- Author `data/aldenmere/tech_trees.json` for the 5 declared
  tracks
- Wire discovery rules in `data/aldenmere/levels/*/rules.json`
  (per-class tick rules)
- Add `yume-tech-tree-designer` skill OR extend
  `yume-systems-designer` skill with the discovery-balance
  authoring guidance

Phase 3 (skill discipline):
- Update `yume-content-designer` SKILL: any entity participating in
  the tech system declares `known_techs: []` in `state_init`,
  even if empty (forward-compat for save migration).
- Update `yume-economy-designer` SKILL: production rules gating on
  tech availability use `state: {known_techs_has: "X"}` (post-ADR
  0031: `zone.X.tech_availability("Y")`).
- Update `yume-story-planner` SKILL: chronicle subscriptions use
  the three new signals.

## Alternatives considered

### A) Hand-author all prereq + transfer logic per game

Don't add a primitive. Each game's `tech_trees.json` becomes a
content-only convention; authors write per-rule prereq queries
(`state: {known_smithing: true, known_ironworking: false}`) and
per-master transfer rules.

Pros: zero engine work, zero new primitive, zero new effects.
Cons: combinatorial rule explosion. A 5-tree × 4-node-each tech
graph with full discovery + transfer + inheritance support hand-
written per game requires ~100 rules per game (prereq checks,
discovery rolls, transfer events, inheritance handlers). Authors
duplicate this for every Aldenmere phase, every future tech-having
game. Balance tuning becomes a sweep across the entire rule tree,
not a single number per node. Rejected for the same reason ADR
0027 was accepted: the authoring pain is the load-bearing case.

### B) Lift tech to a sub-domain of relations (techs as edges)

Model "Garron knows ironworking" as a relation: `knows`-edge from
NPC to a `tech_node` entity. Discovery + transfer become `relate`
+ `unrelate` calls.

Pros: reuses existing relation primitive; no new state field; no
new effect types — just `relate` with type `knows`.
Cons: prereq logic becomes a graph walk (do I have `relate` edges
for all my prereqs?) — slow at query time, awkward in formulas.
Eligibility rules become "find all NPCs with edge `knows` to node
N" — works, but the framing is upside-down. The natural data shape
for "what do I know" is a SET on the entity, not a fan-out of
edges. Cross-game `@lib.tech_trees` reuse breaks because each
game spawns its own `tech_node` entity instances per tree, and
relation edges target instance ids — instance ids vary per save.
Rejected for shape mismatch + save-migration headache.

### C) Treat tech as a stat field per tech (no graph)

Skip the graph; give each NPC `state.smithing_level: 0..3`. "Tech
= a number in {0,1,2,3} per skill," prereqs are "your number is
≥ N." No discovery rolls — leveling happens by accumulating XP via
existing `state_add` rules.

Pros: zero new primitives; reuses XP math.
Cons: collapses 4 distinct nodes into 4 levels of one number.
Loses the **graph** structure (cross-tree prereqs become
impossible). Loses the discovery-as-event narrative weight (no
"breakthrough moment"; just a number ticking up). Loses the
master-apprentice transfer shape (you'd "transfer levels," which
means averaging numbers — odd). Loses the heir inheritance
distinction (`core` vs non-core has no meaning on a continuous
scale). This is the same dimensional-collapse error as
"camera-config-as-three-fov-presets" (ADR 0028 § Alternatives C):
the underlying authoring pain is structural, not numeric.

### D) Use ADR 0019 macros to template the discovery rule pattern

Author one macro `discovery_roll(class_tag, tree_id, prereqs,
chance)` that expands into the full prereq-query + state-set rule.
Reuse via macro invocations per node.

Pros: no new effect types; reuses macro infrastructure.
Cons: macros are PER-GAME (per ADR 0019 — explicit cross-game
boundary). Aldenmere's 5 trees × ~4 nodes each = 20 macro
invocations per game; reused across all games would require ADR
0028's `$params` extension applied to macros (deferred). Master
transfer + heir inheritance still need bespoke rules — macros
don't compose into the relation-walking shape `learn_from_master`
needs. The macro approach handles ~40% of the surface (discovery
rolls) but leaves 60% (transfer + inheritance + balance + queries)
unsolved. Rejected as partial.

### E) Build an external tech-resolver via ADR 0020 IPC

Sidecar process holds the graph + applies discovery / transfer /
inheritance over a JSON wire protocol.

Pros: maximally flexible — tech graph can be a database, a
constraint solver, even an LLM "what should this NPC discover next?"
Cons: ADR 0020 (external IPC) is deferred-until-needed and
explicitly NOT to be activated speculatively. Tech-tree resolution
is deterministic, fast (graph lookup), and pure — none of the
external-tool justifications (ML, expensive solver) apply.
Rejected as wrong-tier abstraction.

We picked design (the present ADR) because it matches the
authoring-pain shape (graph + per-node knob + relation-driven
transfer + heir flag) without opening new architectural questions
the alternatives drag in (graph traversal in formulas, stat
collapse, macro/cross-game boundary, IPC speculation).

## References

- `docs/games/aldenmere/world.md` § "Phase 4 — Civilization" —
  the world bible's commitment to tech-as-knowledge.
- `docs/games/aldenmere/engine_roadmap.md` § "ADR 0033 —
  Technology-tree primitive" — the sketch this ADR fills out.
- ADR 0021 (Yume = JSON layer over Godot) — the architectural
  framing this ADR fits inside (new primitive + interpreter).
- ADR 0026 (Party-member primitive) — supplies the
  `party_member_of` relation that `learn_from_master` /
  `pass_to_apprentice` traverse.
- ADR 0027 (Cross-game JSON reuse) — `@lib.tech_trees.X`
  references make tech graphs shareable across games.
- ADR 0030 (Occupation/class primitive) — class tags supply the
  `eligibility_tags` filter.
- ADR 0031 (Aggregated zone-state primitive) — derives
  `zone.X.tech_availability(tree_id)` over zone members.
- ADR 0034 (Dynasty / heir succession) — calls
  `TechTreeDirector.inherit_to` during succession; reads `core`
  flag on each node.
- ADR 0010 (Save/load persistence) — `known_techs` persists as
  ordinary entity state.
- `scripts/engine/tech_tree.gd` (this ADR; ~220 LoC) — the
  director module to be added.
- `scripts/engine/effect_apply.gd` — gains 3 new effect-type
  registrations.
- `scripts/engine/query.gd` — gains the `known_techs_has` state
  operator.
