# ADR 0031 — Aggregated zone-state primitive

_Date: 2026-05-09_
_Status: proposed_

## Context

Phase 3 of Aldenmere (the macro-economy + politics phase) needs
aggregate values that live at a granularity larger than a single
entity but smaller than the whole world. Examples that motivate
this:

- `city.rice_supply` — Pendrel's market has 50 sacks of rice; the
  Brookhaven market has 8. NPCs in Pendrel see cheap rice; NPCs in
  Brookhaven see expensive rice. Same JSON rule, different scopes.
- `region.iron_demand` — the Pendrel region's smithies want iron;
  the Forest Road region (mostly farmers) doesn't. A trader rule
  reading "where is the demand?" needs region-keyed state.
- `kingdom.unrest` — civil unrest accumulates kingdom-wide and
  spills into faction behavior (per ADR 0032).

Yume's engine today has exactly two storage scopes:

| Scope | What | API |
|---|---|---|
| Entity state | Per-entity `state` dict (mutable) | `state_set/_add/_clamp` with target = entity id |
| world_state | One global dict | `state_set` with `target: "world"`; binding `world.X` |

There's nothing in between. The Aldenmere macro-economy needs
**scoped aggregates** — values that belong to a city, a region, a
kingdom — and queries that can drill down (kingdom → its regions)
or roll up (a city's parent kingdom).

We could fake it with entity state on a "zone marker" entity
tagged `city_marker` + bindings against `pendrel_marker.rice_supply`,
but that conflates two things:

1. **Entities are world objects** — they have positions, the
   spatial index sees them, motion rules can move them. A "kingdom"
   isn't an object; it's a logical container.
2. **Entities don't naturally nest.** Today's entity tree is flat
   (parent-of in the scene graph is a renderer concern, not a
   semantic one). Aldenmere's geography is nested by construction
   (kingdom → region → city → village).

We could fake it with prefix-namespacing world_state keys
(`world.pendrel_rice_supply`, `world.brookhaven_rice_supply`), but
that loses the hierarchy + makes "iterate every city's rice supply"
a string-prefix grep — not a primitive query.

What we want: a third storage scope alongside entities + world_state,
specialized for hierarchical aggregate values. Hierarchical because
Aldenmere's macro-economy roll-ups need it (region's iron supply =
sum of contained cities' iron supplies, when authored that way) and
because faction control + dynastic claims naturally nest.

We deliberately exclude:

- **Auto-aggregation** (zone iron_supply auto-recomputes from
  contained zones every tick) — too magic, performance unpredictable.
  Authors write explicit rollup rules with `tick` triggers when they
  want it.
- **Entity-zone membership relations** as a new primitive — see
  Alternatives. Position-derived membership is the working assumption;
  explicit relations stay opt-in.
- **Per-zone rule schedulers** — zone state is a STORE, not a
  scheduler. Rules continue to live in the global rule set; they
  filter by zone via query/binding.

## Decision

Add a third storage scope: **zone state**, hierarchical, accessed
via three new effects + one new query operator + one new binding
namespace. Engine module: `scripts/engine/zone_store.gd`.

### Authoring shape

```jsonc
// data/<game>/world/zones.json — optional file. Absent = no zones,
// engine behaves as today (full backward compat).
{
  "zones": [
    {
      "id": "kingdom_aldenmere",
      "type": "kingdom",
      "contains": ["region_pendrel", "region_brookhaven"],
      "state_init": {"unrest": 0, "treasury": 1000}
    },
    {
      "id": "region_pendrel",
      "type": "region",
      "contains": ["city_pendrel", "village_riverside"],
      "state_init": {"iron_supply": 100, "rice_supply": 200}
    },
    {
      "id": "city_pendrel",
      "type": "city",
      "contains": [],
      "state_init": {"iron_supply": 30, "rice_supply": 50, "population": 1200}
    }
  ]
}
```

Each zone has:
- `id` — unique string, kebab/snake-case by convention.
- `type` — string label (kingdom / region / city / village /
  district). The engine treats type as a queryable tag, not a
  hierarchy enforcement — authors decide what nests in what.
- `contains` — array of zone ids this zone owns. Forms a tree;
  cycles + multi-parenting are forbidden (see § Validation).
- `state_init` — dict of fields with their initial values. Same
  shape as entity `state_init`.

### Effects (three new vocabulary items)

```jsonc
// In any rule's effect block:
{"type": "zone_state_set",   "zone": "region_pendrel", "field": "iron_supply", "value": 0}
{"type": "zone_state_add",   "zone": "region_pendrel", "field": "iron_supply", "delta": -2}
{"type": "zone_state_clamp", "zone": "region_pendrel", "field": "iron_supply", "min": 0, "max": 999}
```

`zone` accepts either a literal id or a context binding (`a.zone_id`,
`self.home_zone`, `world.active_kingdom`). Resolves the same way
entity targets resolve today.

`field` + `value` / `delta` / `min` / `max` follow the same Formula
semantics as `state_set`/`state_add` on entities — strings are
evaluated against the rule's binding context.

### Queries (one new operator)

```jsonc
// Filter rules by zone state — fires per zone matching the filter
{
  "trigger": {"type": "tick", "interval": 60},
  "query_zone": {
    "type": "region",                       // type filter (optional)
    "state": {"iron_supply_lt": 50}         // state filter (optional)
  },
  "effect": {"type": "zone_state_add", "zone": "@matched.id",
             "field": "iron_demand", "delta": 1}
}

// Direct id (no filter — fires once per tick if zone exists)
{
  "trigger": {"type": "tick", "interval": 60},
  "query_zone": {"id": "region_pendrel"},
  "effect": [...]
}

// Hierarchical: query all zones contained by a parent
{
  "trigger": {"type": "signal", "name": "trade_route_disrupted"},
  "query_zone": {"contained_by": "kingdom_aldenmere", "type": "city"},
  "effect": {"type": "zone_state_add", "zone": "@matched.id",
             "field": "unrest", "delta": 5}
}
```

`query_zone` is a peer of `query` (entities), parallel shape:

| Filter | Meaning |
|---|---|
| `id: "X"` | direct id match |
| `type: "city"` | type-tag match |
| `contained_by: "X"` | zones whose parent (transitively or directly — see below) is X |
| `contains: "X"` | zone(s) that contain X (typically 1 result — the parent) |
| `state: {field_op: value}` | same field-comparator vocabulary as entity queries |

`contained_by` accepts a `depth` field (default 1 = direct children;
`depth: -1` or `"all"` = all transitive descendants). Default is
direct-children to match the principle of least surprise.

Per match, the rule's effect block runs with binding `@matched`
holding the zone (id, type, state, etc.) — same shape as entity
match bindings.

### Bindings (one new namespace)

`zone.<id>.<field>` — readable wherever bindings are evaluated
(rule formulas, HUD bindings, screens.json content, audio cues).

```jsonc
// HUD displaying region's iron supply
{"text": "Iron supply: {zone.region_pendrel.iron_supply}"}

// Rule formula reading zone state
{"target": "self", "field": "is_busy",
 "value": "1 if (zone.region_pendrel.iron_demand > 50) else 0"}
```

If the zone or field doesn't exist, binding resolution returns
`null` — same convention as missing entity state. (Caller decides
whether null is fine or a bug.)

### Save/load integration

ADR 0010's `save_policy.json` gains an optional key:
`"persist_zones": true | false | ["specific_zone_ids"]`. Default
true (zone state persists by default — it's analogous to
world_state, which is already persisted).

Zone state serializes as a flat dict-of-dicts:
```jsonc
{"zone_state": {"region_pendrel": {"iron_supply": 87, ...}, ...}}
```

Loading: zones declared in the current zones.json are populated
from the save; zones in the save but absent from current
zones.json are dropped (same forgiveness as entity state on
def removal). Zones in zones.json absent from the save fall back
to `state_init` values.

### Module shape

`scripts/engine/zone_store.gd` — class_name ZoneStore.

```gdscript
class_name ZoneStore
extends RefCounted

# Flat: zone_id → {state: Dict, type: String, contains: Array, parent: String}
var zones: Dictionary = {}

func load_from_dict(zones_cfg: Dictionary) -> void: ...
func has(zone_id: String) -> bool: ...
func get_field(zone_id: String, field: String): ...   # returns Variant or null
func set_field(zone_id: String, field: String, value) -> void: ...
func add_field(zone_id: String, field: String, delta: float) -> void: ...
func clamp_field(zone_id: String, field: String, lo: float, hi: float) -> void: ...
func find(filter: Dictionary) -> Array: ...           # returns Array of zone_ids
func parent_of(zone_id: String) -> String: ...        # "" if root
func descendants_of(zone_id: String, depth: int = 1) -> Array: ...
func to_save() -> Dictionary: ...
func from_save(d: Dictionary) -> void: ...
```

Owned by `World` alongside `relations`, `spatial_index`,
`world_state`. Passed into `env` so any module can read it.

### Loading order

1. Entity defs + world_state load (existing).
2. **`world/zones.json` loads** — zones registered, contains-tree
   built, cycles detected, state_init populated.
3. Save layer (if any) restores zone_state on top of state_init
   (existing pattern for world_state).
4. Rules load (existing) — Rule.validate_all now includes "if rule
   uses query_zone or zone_state_*, the referenced zones must
   exist or be dynamically resolved (allowed).".

### Module size

Estimated ~180 LoC including the find filter, descendant traversal,
and save serializer. ~25 LoC of validation in Rule.validate_all
extension. ~30 LoC of effect dispatch wiring in effect_apply.gd.
~40 LoC of binding resolver extension. ~20 LoC of save_state.gd
integration. **Total ~295 LoC engine.**

### Test coverage (Phase 1 spec)

| Test | Verifies |
|---|---|
| `zone_state.test_state_set_get_round_trip` | `zone_state_set` followed by binding `zone.X.Y` returns the set value (any JSON type) |
| `zone_state.test_state_add_delta_math` | `zone_state_add` with positive + negative + formula deltas mutates correctly; missing field auto-initializes to 0 |
| `zone_state.test_state_clamp_min_max` | `zone_state_clamp` enforces both bounds; clamping a missing field is no-op |
| `zone_state.test_query_zone_by_id_and_type` | `query_zone {id: X}` fires once; `query_zone {type: "city"}` fires per matching zone |
| `zone_state.test_query_zone_state_filter` | `query_zone {state: {iron_supply_lt: 50}}` filters correctly |
| `zone_state.test_hierarchical_descendants` | `contained_by: kingdom_X` with default depth=1 returns direct children; depth=-1 returns transitive descendants |
| `zone_state.test_bindings_in_hud_and_rules` | `zone.region_pendrel.iron_supply` resolves in rule formulas AND in HUD text bindings |
| `zone_state.test_save_load_round_trip` | zone state serializes via save_state, restores on load_state, missing-from-save zones fall back to state_init |
| `zone_state.test_cycle_detection_at_load` | zones.json with `A contains B; B contains A` is rejected with structured EngineError + clear path |
| `zone_state.test_no_zones_file_backward_compat` | demos with no zones.json load + run cleanly; query_zone in their rules with no matches is a no-op (not an error) |

10 unit tests. (Roadmap estimated 8; the cycle-detection + backward-
compat tests are added because they're the canonical regression
risks for any new optional file.)

### Validation

`tools/validate_zones.py` (new, modeled after
`tools/validate_screens.py`):

- Cycle detection in `contains` tree. Fail with the cycle path.
- Multi-parent detection (zone X is in two zones' `contains`).
  Fail.
- Unknown ids in `contains`. Fail.
- For each rule that uses `zone_state_*` effect with a literal `zone`
  field — verify the zone exists. Dynamic bindings (`a.zone_id`,
  `world.active_kingdom`) skip this check.
- For each rule with `query_zone {id: X}` — verify X exists.

Wired into `scripts/play.sh` non-strict pre-launch check (warn at
launch); skills + CI use `--strict` (fails fast).

## Consequences

### Enables

- **Macro-economy at scale**: NPCs in Pendrel see Pendrel's prices;
  NPCs in Brookhaven see Brookhaven's prices. One trade rule, many
  zones, no per-city duplication.
- **Faction control** (ADR 0032) can attach to zones — `zone.unrest`
  rises across a kingdom; faction AI reads it; coups + civil wars
  fire on thresholds.
- **Phase 4 dynasty** (ADR 0034) — heir inherits a kingdom's zone
  state, not just inventory. The crown gains meaning.
- **Cross-zone rule patterns** the merchant game already wanted but
  faked: "global event affects every city in the kingdom" becomes
  one `query_zone` rule.
- **HUD that adapts to where you are**: `zone.{world.current_zone}.iron_supply`
  binds to whatever zone the player is currently in. Localization
  of state without rule duplication.

### Constrains

- Zone state is a third store. Authors must remember which scope a
  field lives in. The data-demo rule already covers this for
  world_state vs entity state; we extend the same discipline to
  zones.
- Zone count is bounded by performance (see § Performance budget).
- No automatic aggregation — author writes explicit rollup rules.
  Tradeoff: predictable performance + transparent semantics, at
  the cost of a few authoring lines.
- `contained_by` queries with `depth: -1` are O(zones) per fire;
  use sparingly. The validator can warn on suspicious patterns.

### Doesn't enable

- Per-zone tick scheduling. Zones don't have their own clocks; they
  follow the world clock. Rules schedule themselves.
- Zone-local rules. All rules are global; zones are queryable
  scopes. (If per-zone rule packs ever need to exist, that's a
  future ADR — likely the "occupation pack" generalization
  mentioned in `aldenmere/world.md`.)
- Entity-zone membership as a primitive. Entities can carry
  `home_zone: "pendrel"` in their state — that's content, not
  engine. See § Risks.
- Continuous spatial zoning (a polygon → "in this zone if your
  position is inside"). That's a future ADR if needed; today's
  membership is symbolic-only (the entity declares its zone in
  state).

## Performance budget

Zone counts in Aldenmere's planned scope:

| Scope | Counts | Notes |
|---|---|---|
| Phase 1 | 0 zones | no zones.json, no overhead |
| Phase 2 | ~5 zones (3-5 villages, no nesting yet) | trivial |
| Phase 3 | 1 kingdom × 3 regions × 5 cities = ~15 zones | one country |
| Phase 4 | 5 kingdoms × ~3 regions each × ~8 cities each = ~125 zones | full continent |
| Theoretical ceiling | 1 kingdom × 10 regions × 50 cities = 500 zones | hard cap; validator warns above this |

Per-tick costs (Phase 4 worst case, 60Hz):

- `zone.X.field` binding lookup: O(1) — flat dict. **<1µs each.**
- `query_zone {id: X}` direct: O(1).
- `query_zone {type: "city"}`: O(zones) — small constants. ~125
  iterations × ~10ns dict access ≈ 1.25µs.
- `query_zone {contained_by: kingdom, depth: -1}`: O(descendants).
  ~25 in Phase 4 worst case. ~250ns.
- Per-tick aggregation rules (e.g. "every region recomputes its
  rice supply from contained cities" once a minute): O(zones × avg_children),
  ~125 × 8 = 1000 ops. Even at 60Hz that's 60K ops/sec ≈ negligible.

**Total budget at Phase 4**: well under 1ms/tick, dominated by
existing entity rules. No need for spatial-LOD-style scoping on
zones — they're cheap.

If a future game pushes >500 zones, the flat-dict store stays
fine; the bottleneck would shift to descendant queries. We'd revisit
with cached descendant lists at that point.

## Migration

Existing demos: zero-effort. No `zones.json` = no zones loaded;
`zone_state_*` effects + `query_zone` queries that nobody writes
have no overhead. Save schema: existing saves don't have a
`zone_state` key; loader treats absence as empty + falls back to
`state_init` for any zones the new demo declares. Forward-compatible.

Aldenmere build sequence:
- **Phase 1**: ship engine module + tests; do NOT author zones.json
  yet (Phase 1 has 1 village, no need).
- **Phase 2**: optional zones.json with 3-5 village entries (purely
  for save-forward compat with Phase 3).
- **Phase 3**: full zones.json with kingdom + regions + cities;
  macro-economy rules reference them.
- **Phase 4**: continent-wide zones.json with multiple kingdoms.

Per-game scoping: zones.json is per-game (not a lib catalog yet).
If multiple games want to share kingdom-shaped zone templates, ADR
0027/0028 (`@lib.zones.standard_kingdom` with $params) covers it
without engine changes.

## Alternatives considered

### A) Use a magic `zone_marker` entity per zone

Tag a hidden non-rendered entity `kingdom_aldenmere`, store
`unrest` + `treasury` in its `state` dict, query with
`tags_all: ["kingdom_marker"]`.

Pros: zero new engine work. Existing entity primitives cover it.
Cons: conflates "world objects" with "logical containers." Spatial
index sees them (or has to special-case-skip them). Hierarchy is
ad-hoc — `parent_zone` becomes a state field instead of a
declared structure. Cycle detection becomes the author's problem.
Bindings stay clunky (`pendrel_marker.rice_supply` instead of
`zone.region_pendrel.rice_supply` — but the marker pattern means
the marker entity could move, get destroyed by a stray rule, or
be despawned during a level transition).

This works for ad-hoc games. For Aldenmere's Phase 3-4 scope it's
fragile.

### B) Prefix-namespace world_state keys

Pack everything into `world_state`: `world.pendrel_iron_supply`,
`world.brookhaven_iron_supply`, `world.kingdom_aldenmere_unrest`.
Rules iterate via string-prefix grep over world_state.

Pros: zero new engine vocabulary.
Cons: no hierarchy; iteration over "every city in the kingdom" is
a string operation in JSON, not a primitive query. Save policy
either persists everything or splits by hand. The world_state dict
balloons. Authoring is verbose; refactoring (rename a region)
requires global string replace. A primitive escape pattern.

### C) Add zones to the entity store but flag them with a special tag

Treat zone as a special tag (`is_zone: true`). Engine modules see
the tag and skip spatial-index registration / motion / contact.

Pros: reuses the entity primitive.
Cons: forks the engine's mental model (entity-but-not-really).
Every module that touches entities (motion, spatial_index, render,
save) needs an `if entity.has_tag("is_zone"): skip` carve-out.
That's exactly the "entity subclass via tag" anti-pattern Invariant
#3 forbids in spirit if not in letter.

### D) Defer until a real game needs it (today: zero games do)

Punt this ADR. Aldenmere Phase 3 is months away; no current demo
uses zones. Build merchant + Phase 1 with marker-entity hack;
revisit when Phase 3 is queued.

Pros: no work now.
Cons: marker-entity fakes start in Phase 1 → Phase 2 builds on
fakes → Phase 3 inherits a tangle that's harder to migrate than
just authoring against zones from the start. Save format then
needs migration. The right time to ship a foundational primitive
is BEFORE consumers depend on its absence-shape.

We picked the present design (dedicated zone_store as a third
scope, parallel to entities + world_state) because it cleanly
separates concerns, scales transparently, and the implementation
is small enough (~300 LoC) that the surface-area cost is
acceptable.

## Operator-surface boundary

This ADR adds 3 effect types (`zone_state_set/_add/_clamp`) and 1
query operator (`query_zone`). Future zone-related primitives
require new ADRs:

- Per-zone scheduling — future ADR if needed
- Continuous spatial membership (polygon zones) — future ADR if
  needed
- Auto-aggregation rules — explicitly NOT shipping; authors write
  rollup rules

Any change to the contains-tree shape (e.g. multi-parent zones,
overlapping zones) requires a new ADR. Single-parent tree is the
load-time invariant.

## References

- Code locations affected:
  - `archetypes/core/templates/godot/scripts/engine/zone_store.gd` (new)
  - `archetypes/core/templates/godot/scripts/engine/world.gd` — wire ZoneStore into env
  - `archetypes/core/templates/godot/scripts/engine/effect_apply.gd` — dispatch zone_state_*
  - `archetypes/core/templates/godot/scripts/engine/phase_scheduler.gd` — query_zone integration
  - `archetypes/core/templates/godot/scripts/engine/binding_resolver.gd` — `zone.X.Y` namespace
  - `archetypes/core/templates/godot/scripts/engine/save_state.gd` — zone_state serializer
  - `archetypes/core/templates/godot/scripts/engine/rule.gd` — validate_all extension
  - `archetypes/core/templates/godot/scripts/engine/tests/test_runner.gd` — 10 new tests
  - `tools/validate_zones.py` (new)
- Related ADRs:
  - **ADR 0009** (world/game/flow separation) — zone_state is conceptually a third "world" file (world/zones.json), parallel to world/physics.json + world/state.json.
  - **ADR 0010** (save/load) — zone_state participates via `persist_zones` policy key.
  - **ADR 0014** (open-world substrate) — chunk streaming and zones are orthogonal: chunks stream geometry, zones aggregate state. A zone may span chunks; chunks don't care about zones.
  - **ADR 0017** (spatial-LOD) — zones have no spatial extent in this ADR; LOD is irrelevant.
  - **ADR 0027** ($extends) — zone defs are JSON dicts and inherit from `@lib.zones.standard_kingdom` etc. once a catalog is authored.
  - **ADR 0028** ($params) — parameterized zone templates (population + treasury per game).
  - **ADR 0032 (proposed)** — faction primitive will read + mutate zone state to express "faction X controls zone Y." Built atop this ADR.
  - **ADR 0033 (proposed)** — tech-tree may track per-zone tech-spread.
  - **ADR 0034 (proposed)** — dynasty inheritance includes zone-control transfer.
- Discussions / reviews:
  - `docs/games/aldenmere/world.md` — Phase 3 macro-economy scope
  - `docs/games/aldenmere/engine_roadmap.md` § ADR 0031 sketch — original ask
  - This ADR refines the sketch + adds save/load, validator, and operator-surface boundary per ADR 0028's review-pattern precedent.

## Implementation plan

### Phase 1 — engine + tests (this ADR)

1. Author `zone_store.gd` with the API above (~180 LoC).
2. Wire into `world.gd`:
   - Load `world/zones.json` after entity defs + before save layer.
   - Pass `zone_store` into `env`.
3. Extend `effect_apply.gd` with three new dispatch branches.
4. Extend `phase_scheduler.gd` with `query_zone` resolution
   (parallel to entity `query`).
5. Extend `binding_resolver.gd` with `zone.<id>.<field>` lookup.
6. Extend `save_state.gd` with `persist_zones` policy + serializer.
7. Extend `rule.gd::validate_all` with zone reference checks.
8. Author 10 unit tests in `test_runner.gd`.
9. Author `tools/validate_zones.py`.
10. Wire validator into `scripts/play.sh` (non-strict warn).

### Phase 2 — Aldenmere consumption

Phase 3 of Aldenmere build authors `world/zones.json` with the
kingdom + regions + cities tree. Skill update:
- `yume-systems-designer`: zone-state effects in macro-economy rules
- `yume-economy-designer`: zone-keyed pricing curves
- `yume-content-designer`: per-NPC `home_zone` field

### Phase 3 — catalog (deferred)

After ≥2 games use zones, lift common zone shapes into `data/lib/zones/`
(per ADR 0027). E.g. `@lib.zones.standard_kingdom` with $params
for treasury starting amount + initial unrest.

## Risks honestly named

1. **Entity-zone relationship is symbolic.** This ADR doesn't
   define how an entity "belongs to" a zone — that's content
   (entity declares `home_zone: "pendrel"` in state). Rules that
   need "every NPC in zone X" iterate entities filtered by
   `state.home_zone == X`. This works but is an O(entities) scan
   per rule fire. If Phase 4 makes this hot, we add a relation
   primitive (`entity_in_zone` indexed edge) — that's a future ADR.
   Position-based membership (polygon containment) is also a
   future ADR; deliberately deferred.
2. **Authoring discipline**: three storage scopes (entity / world /
   zone) is more cognitive load. Mitigation: data-demo rule + skill
   updates make the convention clear; each scope has a distinct
   binding namespace prefix that signals where a value lives.
3. **Cycle-detection edge cases**: multi-parenting (zone X listed
   in two parents' `contains`) is detected at load. Self-cycles
   trivially. Diamond patterns (X contained by both Y and Z, Y
   and Z both contained by W) are forbidden — strict tree only.
   The validator + load-time check both fire.
4. **Save schema drift**: adding a zone in v2 of a game means v1
   saves load with that zone falling back to state_init. Removing
   a zone in v2 means v1 saves' zone state for the dropped zone is
   silently discarded. This matches existing entity-state-on-def-
   removal behavior; surfaced explicitly in save_policy
   documentation.
5. **Performance ceiling**: 500 zones is the soft cap before
   descendants_of(depth=-1) becomes nontrivial. Validator warns
   above 250 zones; hard-fails above 1000. Real games aren't
   expected to need anywhere near this.

## Tech-director review

_Pending — request review before implementation start._

Expected invariant checks (#1 JSON-only, #2 no semantic effects,
#3 no entity classes, #5 queries first-class, #8 primitives +
interpreter, #9 phase ordering, #10 freeze-policy, #11 level-
discontinuity, #12 persistent-clobber). Anticipated concerns:

- Three-store mental model — covered by namespace prefix.
- query_zone parallelism with query — covered by mirror shape.
- Save/load determinism — covered by stable iteration order
  (zones serialize in declaration order from zones.json).
- Rule.validate_all extension surface — minimal, additive.

After tech-director gates → upgrade to **accepted** → implement
Phase 1 → land alongside Phase 1 of Aldenmere build.
