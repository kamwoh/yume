# ADR 0084 review: tech-director

_Date: 2026-10-15_
_Reviewer: yume-tech-director_
_Input: `docs/adr/0084-query-tag-index-and-derived-cell-size.md` (untracked, status `proposed`). No code diff._
_Baseline: commit `abc6b78`._

## Verdict: REVISE

The direction is sound. The contract already says "Engine chooses
spatial index / scan strategy" (`30_framework_primitives.md:398`). Thus
neither part adds vocabulary, and no invariant blocks the idea. The draft has
five problems. Part 2 has one blocker that drops matches and one performance
regression. The Part 1 safety argument has two holes. One statement about
the level transition is false. Change these in the ADR text before
implementation. The status stays `proposed`. The user decides.

## Top items

1. **Blocker: Part 2 must rebucket the spatial index.** A cell size
   change without a rebuild hides static entities from radius queries.
2. **Part 2 makes "radius 1000 = anywhere" about 15 times slower.**
   `query_radius_ids` must stop when the cell span is larger than the
   number of occupied cells.
3. **The Part 1 argument "a stale index can only add candidates that the
   checks reject" is false.** Duplicate candidates pass every check.
   Specify dedupe and insertion order.

## Invariant checks

| Invariant | Result | Evidence |
|---|---|---|
| #1 JSON-only content | Holds | No content file changes. No game id in the design. |
| #2 No semantic effects | Holds | No new effect type. |
| #3 No entity hierarchy | Holds | `Entity` gets a static counter only. |
| #5 Queries first-class | Holds | The index lives inside `QueryLib.run`. Callers do not change. |
| #8 Primitives + interpreter | Holds | Pure strategy change. The contract allows it (line 398). |
| #9 Phase flushes | Not touched | Effects still buffer and flush at phase boundaries. |
| #10 Freeze policy | Not touched | No new `_pending_*` pipeline. |
| #11 Level discontinuity | **Gap** | The index and the cell size are engine state that survives `transition_level`. The ADR describes the wrong mechanism (item D). |
| #12 Persistent clobber | Holds | The guard in `spawn_manager.gd:95-134` does not change. |
| Visual gate | Not applicable | Headless logic, no rendered surface. |
| Effect-chain gate | Not applicable | No lifecycle effect changes. |
| Tests + demos | Not run | No code exists yet. The implementation must pass `test_main.tscn` and the scenario runner for all 12 demos. |

## Part 1: the tag index

### A. Tag write sites (verified)

Writes to `Entity.tags` outside `entity.gd`, non-test:

- `directors/multimesh_director.gd:133` `me.tags.append(MANAGED_TAG)`
- `directors/multimesh_director.gd:404` `e.tags.erase(MANAGED_TAG)`
- `coordinators/world_boot.gd:120` `ent.tags = ["_engine", "persistent"]` (assignment, the setter catches it)

Writes inside `entity.gd`: `create` (line 75), `_apply_overrides`
(line 107), `add_tag` (166), `remove_tag` (170). All four mutate in
place. A GDScript property setter does NOT fire on `tags.append()`, so
each of these needs an explicit bump. The ADR names `create`, `add_tag`
and `remove_tag`. `_apply_overrides` runs only from `create`, so the
bump in `create` covers it if the bump comes last.

Tests: 18 direct assignments in `test_runner.gd` (lines 2888 to 11537),
for example `e_tree.tags = ["tree", "decorative"]`. The setter catches all
of them. No test mutates `tags` in place.

Callers of `add_tag` / `remove_tag`: `effect_core.gd:475,482`,
`effect_actor.gd:116,162`, `lifecycle_director.gd:308,311`.

Alias exposure (read-only today, but a hole for the future):
`formula.gd:248` (`cur = ent.tags`) and `actor_manager.gd:240,269` pass
the live array into formula and policy dicts. A mutation through these
references bypasses the epoch.

The ADR claim about the two multimesh sites is true and complete.

### B. Counterexample to "a stale index can only add candidates that the checks reject"

The checks (`matches()` plus membership) reject a WRONG entity. They do
not reject a RIGHT entity that appears twice.

- `Entity.create` does not dedupe def tags (`entity.gd:74-75`). A def
  with `"tags": ["enemy", "enemy"]` puts the entity twice in the `enemy`
  list. The query returns it twice. Today the scan returns it once.
- The `tags_any` union of two lists returns an entity with both tags
  twice.

Both duplicates pass `matches()`. A contact rule then fires its effects
twice for one pair.

**Required change:** build each entity's tag set without duplicates. For
`tags_any`, either dedupe or drop the branch. No demo rule uses
`tags_any` today (`grep -rn tags_any data/demo_*/{world,levels,game}` = 0),
so dropping it is the simpler option (Simplicity First).

### C. Result order is behavior

`run()` returns entities in `env.entities` insertion order. Callers
depend on it: `limit` without `order_by`, effect target picks, and
`once_per_a` (the first `b` wins, `phase_scheduler.gd:519-552`). A
tag list built by one pass over `all.values()` keeps that order. A
`tags_any` union of concatenated lists does not.

**Required change:** state that every candidate list keeps insertion
order. The `verify_index` gate must compare ordered arrays, not sets.
Otherwise the gate cannot see an order drift.

### D. The level transition and the reset do NOT rebuild `env.entities`

The ADR says: "The index lives in `env`, so the level transition and the
reset (which rebuild `env.entities`) also rebuild the index." That is
false.

- `level_transition_coordinator.gd:178` and
  `world_reset_coordinator.gd:63` erase entries in place from the same
  dictionary.
- The scheduler env lives for the whole session
  (`world.gd:310`, and `level_transition_coordinator.gd:212` writes to
  `_world.scheduler.env`).

The index stays right for a different reason: a removal changes the
count, and each new entity bumps the epoch. Rewrite the sentence so the
Invariant #11 audit names the real mechanism.

### E. Where the epoch and count signature can fail

I checked every add site (`spawn_manager.gd:166`, `effect_core.gd:258`,
`world_boot.gd:126`, `scenario_runner.gd:265`). Each one calls
`Entity.create` (or `Entity.new` plus a `tags` assignment) just before
the insert. No query runs between the create and the insert. No path
inserts an `Entity` object that was created earlier. So I found no
counterexample in engine code today. Two latent holes remain:

1. The bump happens at create, not at insert. Suppose a future change
   adds a query between the two, for example in a grid-snap hook. A
   removal in the same window then keeps the count equal, and the index
   drops the new entity.
2. An object re-inserted after a removal (a pooling or chunk-cache
   change) with no tag change keeps both values equal.

The membership check must be identity: `all.get(ent.instance_id) == ent`,
not `all.has(id)`. Ids are reused across levels and by `_forced_id`
spawns.

### F. Rebuild frequency

Effects buffer and apply at phase flushes, so a tick rebuilds at most
once per flush that changed tags or spawned. That is about 5 per tick in
the worst case. State this bound in the ADR.

`add_tag` must bump only on a real change. Otherwise a contact rule
that re-adds the same tag each tick forces a rebuild each tick (the
aldenmere `villager_enters_fire_radius` pattern).

Every `_build_env()` call makes a new dictionary (`world.gd:905`).
One-shot callers (`world.gd:779,803`, the loaders) pay a full rebuild
per call. That is a small regression on debug paths only. Note it, or
skip the index when the env has no prior index and the call is
one-shot.

### G. Gate: make it static as well as dynamic

`verify_index` catches a bypass only on paths that tests exercise. Add a
static gate that fails on any in-place `tags` mutation outside
`entity.gd`:

```bash
grep -rnE '\.tags\.(append|erase|clear|push_back|push_front|insert|remove_at|assign|resize|sort|reverse|fill|pop_back|pop_front)\(' \
  godot/scripts --include=*.gd | grep -v 'core/entity.gd'
```

It must print nothing. Put it in `tools/validators/` or in
`engine-scripts.md`, per the post-mortem rule ("enforceable check").

## Part 2: the derived cell size

### H. Blocker: a cell size change needs a full rebucket

`SpatialIndex` stores `entity_cells[id]` as a `Vector2i` computed with
the cell size at insert time (`spatial_index.gd:34-47`).

Order at boot (`world_boot.gd:256-282`): global rules register, then
root entities spawn and enter the index, then `load_level` appends the
level rules. At a transition (`level_transition_coordinator.gd:183-196`)
the persistent entities stay in the index while the rules re-register.
So the cell size changes after entities are bucketed.

Counterexample: aldenmere. Entities go in at cell size 64. The derived
size becomes 6. A radius query computes its cell range with 6 and looks
in cells that hold nothing. Moving entities go back to the right cell on their next
`set_position`. Static entities never move: `fire_pit`, shelters and the
market. `villager_enters_fire_radius` (b = `fire_pit`) then never
matches. This drops matches. It is not only a performance problem.

**Required change:** a cell size change calls `clear()` and re-inserts
every entity with a position. Compute the size once after all rules for
the session load (boot plus `load_level`). Do not compute it in each
`register_rules` / `append_rules` call. Boot alone calls these 5 or more
times.

### I. Large radii get much slower

`query_radius_ids` visits every cell in the bounding box, including empty
cells. The cost is `(2r / cell + 1)^2` probes.

| Demo | Literal query radii | Median | Derived cell | Probes for r = 1000 (now → derived) |
|---|---|---|---|---|
| `doomarena3d` | 1.0, 1.2 x4, 8.0, 1000 x5 | 8.0 | 16 | about 1,100 → 15,900 |
| `sokoban` | 12 x5, 1000 x2 | 12 | 24 | about 1,100 → 7,100 |

The doomarena `radius: 1000` rules are contact chase rules
(`world/rules.json:404,431`, `levels/*/rules.json`). They run one radius
query per monster per tick. The derivation makes each one about 15 times
more expensive.

Also, the median is unstable here. One more `radius: 1000` rule in
doomarena moves the median to 504 and the cell size to the 64 clamp.

**Required change:** in `query_radius_ids`, when the span of cells is
larger than `grid.size()`, iterate the occupied cells and filter by the
cell range. The cost becomes `min(span, occupied cells)`. With that
change any cell size is safe, and the choice of statistic matters less.

### J. Which radii count

- Count only `query.radius` of rules (contact and non-contact). A naive
  walk over every `radius` key also counts `tutorial.json` zone radii
  (aldenmere lines 129 and 307: `"zone": {..., "radius": 4}`). Those are
  not query radii.
- A contact rule with no `radius` uses 1.0 (`phase_scheduler.gd:515`).
  Count that default, because it is the radius the query uses. No demo
  omits it today.
- Radii that the engine adds (`actor_manager.gd:257` uses 200) and
  formula radii do not count. Item I makes this safe.

### K. Check of the ADR numbers against the data

- Aldenmere query radii are 1.5, 1.5, 1.5, 2, 2, 3, 5, 5, 40, 50, 50.
  The ADR says "radii of 2 to 5". The 40 and 50 radii are contact rules
  (`wolf_pursue_villager`, `schedule_walk_to_fire`,
  `schedule_walk_to_market`) and run each tick. The true median is 3.0,
  so the cell is 6, not 8. A radius-50 query at cell 6 probes about 289
  cells and still returns most of the world. The claim "4.1 ms to under
  1 ms" depends on how the 14 radius queries split between small and
  large radii. Measure it. Do not assume it.
- The aldenmere extent is x -65..40, z -40..35: 3 x 2 cells at 64, not
  2 x 2. That does not change the conclusion.
- 2D pixel demos: only `sokoban` uses pixel units (positions 16..304,
  tile 32). Cell 24 suits its radius-12 queries. The other 11 demos use
  metres (`position_scale: 1.0`). Six of them have no literal radius and
  keep 64.

### L. Order change from a new cell size

The spatial candidate order is cell order, then insertion order inside
the cell. A new cell size changes the order. `once_per_a` and `limit`
without `order_by` can then pick a different entity. Today every
`once_per_a` rule in the demos has a single-entity `b` (the player), so
nothing changes now. State this in Consequences, and re-run all scenario
tests.

## Side finding (outside this ADR)

Aldenmere `tag_add` / `tag_remove` effects use `"tags": [...]`. The
engine reads only `"tag"` (`effect_core.gd:475,482`). Thousandgate uses
`"tag"` as it should. Affected: `03_needs_warmth.json:363,385`,
`05_fire.json:51,58,124,131`, `08_buildings.json:44,51,105,112`. The
effects add or drop the empty tag `""`, so the `at_fire`, `burning` and
construction tag chains do nothing. This is a field-name landmine that
`data-demo.md` or a validator should catch. It needs its own fix and
post-mortem.

## Conditions for approval

1. Part 2 specifies a full rebucket on a cell size change, and computes
   the size once per rule set (item H).
2. `query_radius_ids` caps its probes at the occupied cell count
   (item I).
3. Part 1 specifies dedupe, insertion order, identity membership, and
   bump-on-real-change. Drop or fix `tags_any` (items B, C, E, F).
4. The level transition sentence names the real mechanism (item D).
5. `verify_index` compares ordered results. A static grep gate blocks
   in-place `tags` writes (item G).
6. The implementation passes `test_main.tscn` and all demo scenarios,
   and re-profiles `autorace_3d`, `aldenmere_3d` and `doomarena3d`.

## Re-review (revision 2)

_Date: 2026-10-15_
_Input: `docs/adr/0084-query-tag-index-and-derived-cell-size.md`, revision 2 (untracked, status `proposed`). No code diff._

### Verdict: APPROVE WITH CONDITIONS (text only)

Revision 2 resolves all three top items and items A to L. It adds two
gaps and leaves one ambiguity that changes behavior if an implementer
reads it literally (item N1). All three are ADR text fixes. No
invariant breaks. I do not change the status. The user decides.

### Top items from the first review

| Item | Result | Evidence |
|---|---|---|
| 1. Rebucket on a cell size change | Resolved | "Re-bucket" paragraph: clear, then re-insert. See N3 for the set to re-insert. |
| 2. Large radii | Resolved | "Large radii" paragraph: iterate occupied cells when the box spans more cells than the grid holds. |
| 3. Duplicates and order | Resolved | "Candidates" list: no duplicates, the same order (union sorts by ordinal), identity membership. |

### Items A to L

| Item | Result | Evidence |
|---|---|---|
| A. Tag write sites | Resolved | "Epoch" names both `multimesh_director.gd` sites (133, 404) and moves them to `add_tag` / `remove_tag`. A re-run of the grep finds no new site. The alias holes (`formula.gd:248`, `actor_manager.gd:240,269`) stay open. They were a note, not a condition. |
| B. Duplicate candidates | Resolved | The build skips a repeat tag. The `tags_any` union drops repeats. A unit test covers a def with a duplicate tag. |
| C. Result order | Resolved | Tag arrays are built in `env.entities` order. The union sorts by ordinal. `verify_index` compares ordered arrays. See N1 for radius queries. |
| D. Level transition text | Resolved | The text now says the transition and the reset erase entries from the same dictionary (count changes) and new entities bump the epoch. That matches `level_transition_coordinator.gd:178` and `world_reset_coordinator.gd:63`. |
| E. Signature holes | Partly resolved | Identity membership is specified. Latent hole E.1 (a query between `Entity.create` and the dictionary insert, plus a removal in the same window) is not mentioned. No engine path does this today (`spawn_manager.gd:166`, `effect_core.gd:258`, `world_boot.gd:126`, `step_runner.gd:265`). Add one line under Negative: "the index assumes no query runs between `Entity.create` and the insert". Not blocking. |
| F. Rebuild bound | Resolved | "Rebuild bound" states about 5 per tick. `add_tag` / `remove_tag` bump only on a real change. One-shot `_build_env()` cost is noted. |
| G. Static and dynamic gates | Resolved | Static validator in `tools/validators/` plus ordered `verify_index`. The list "and the others" is vague. The validator must also match `append_array(` and `remove(`, which my first list missed. |
| H. Rebucket and compute once | Resolved, with gaps | See N2 and N3. |
| I. Large radii | Resolved | See top item 2. Order note in N4. |
| J. Which radii count | Resolved | Only rule `query.radius`. Contact default 1.0 counts. Formula, tutorial zone and engine-added radii do not count. |
| K. Numbers | Resolved | Aldenmere is now 3 x 2 cells, radii 1.5 to 5 plus 40 and 50, median 3.0, cell 6. The "under 1 ms" claim is gone. The ADR says the gains are measured after the change. |
| L. Order change | Resolved | Consequences, Negative, last bullet. |

### New items in revision 2

**N1. Precedence between the radius path and the tag path (must fix).**
The "Candidates" text says a query with `tags_all` takes the smallest
tag array and "other queries scan everything, as today". It does not say
what a query with BOTH `radius` and tags does. Every contact rule is
that case: `_fire_contact_rule` adds `radius` to the `b` spec and calls
`QueryLib.run` (`phase_scheduler.gd:532-534`). Today that path returns
spatial order (cell order, then insertion order in the cell). If the tag
array wins, every contact `b` list changes to insertion order. That
changes `once_per_a` picks, `limit` picks and which pair takes which
`chance` roll (`phase_scheduler.gd:541`). Also, `verify_index` "runs the
full scan" as its reference. For a radius query the full scan gives
insertion order. Thus the gate flags each radius query with two or more
matches as a false mismatch.

Required text: "A query with `radius` keeps the spatial path
unchanged. The tag index serves only queries without `radius`.
`verify_index` compares each query against the path it replaces." A
smallest-of-both choice is not acceptable, because the order would then
depend on population.

**N2. The cell size must also recompute after a reset and a save load
(should fix).** The "When" paragraph names boot and the level
transition. Two more paths append rules: `world_reset_coordinator.gd:78`
and `world.gd::_do_load` both call `load_level`, which calls
`load_rules_files_for(..., true)` (`level_transition_coordinator.gd:230`).
A missed recompute keeps an old size. That is consistent (one size
for all buckets), so it is only a performance gap, not a correctness
fault. The simplest fix covers all paths: `register_rules` and
`append_rules` set a dirty flag, and the first radius query after it
computes the size and rebuckets once. That also keeps item H ("not in
each `register_rules` call").

**N3. Re-insert the ids already in the index, not "every entity with a
position" (should fix).** Today an entity enters the index only through
`update_entity` (spawn manager, effect spawn, step runner,
`Entity.set_position` when the parent is the World). The `_engine`
entity (`world_boot.gd:120-126`) joins with `add_child` and no
`set_position`. "Every entity with a position" is a different set from
the current one. The rebucket must change cells only, not membership.
Specify: re-insert each id in `entity_cells` at its entity's current
planar position.

**N4. The large-radius branch also changes order (note).** The cell-box
loop returns cells in x-then-y order. The occupied-cells loop returns
them in `grid` key order. So the same query can return a different order
when the population changes. This is deterministic and belongs to the
item L class. Add it to the same Negative bullet. The scenario suites
re-run anyway.

### Side finding status

Still open. Aldenmere `tag_add` / `tag_remove` still use `"tags": [...]`
(`03_needs_warmth.json:363,385`, `05_fire.json:51,58,124,131`,
`08_buildings.json`). It is outside this ADR. It affects the profile:
when the fix lands, `at_fire` and `burning` toggle for real, and each
toggle is a real tag change that triggers an index rebuild. Fix the data
before the "after" profile of `aldenmere_3d`. Otherwise the measurement
misses the real tag churn.

### Conditions for approval (revision 2)

1. Specify the radius-vs-tag precedence and the `verify_index` reference
   path (N1).
2. Recompute the size on every rule set change, by a dirty flag or an
   equivalent (N2).
3. Rebucket the ids in `entity_cells` only (N3).
4. Add the E.1 assumption and the N4 order note to Negative.
5. Unchanged from the first review: the implementation passes
   `test_main.tscn` and all demo scenarios, and re-profiles
   `autorace_3d`, `aldenmere_3d` and `doomarena3d`. The profile runs
   with `verify_index` off.
