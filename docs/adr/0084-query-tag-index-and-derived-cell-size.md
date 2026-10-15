# ADR 0084 — Query tag index and a derived spatial cell size

_Date: 2026-10-15_
_Status: accepted 2026-10-16, implemented (revision 3, after two tech-director reviews)_

## Context

On 2026-10-15 batch C profiled all 12 demo scenes (300 ticks each,
headless). Two demos ran over the 16.7 ms tick budget: `autorace_3d`
(24.8 ms) and `aldenmere_3d` (22.6 ms). Commit `abc6b78` removed the
formula cost (lazy snapshots, a RegEx cache, an early exit for spent
`once` rules). The median tick fell by about 40%, to 12.7 ms and
11.8 ms. After that fix, `Query.run` takes 84% of the tick in both demos:

| Demo | Tag queries per tick | Cost | Matches per query | Radius queries per tick | Cost |
|---|---|---|---|---|---|
| `autorace_3d` (466 entities) | 20 | 10.8 ms | 0.6 | 2 | 0.3 ms |
| `aldenmere_3d` (291 entities) | 21 | 7.6 ms | about 1.8 | 14 | 4.1 ms |

Two causes:

1. **No tag index.** A query without `radius` scans every entity and
   calls `matches()` on each. In GDScript that costs about 1.3 µs per
   entity. `autorace` scans 466 entities 20 times per tick to find fewer
   than one match per query.
2. **A fixed cell size.** `SpatialIndex.cell_size` is 64. That suits
   `sokoban`, the one demo in pixel units. The other demos use metres:
   the aldenmere world spans x -65..40 and z -40..35, so it has 3 x 2
   cells. Its query radii are 1.5 to 5, plus three contact rules with
   40 and 50. A small-radius query still checks almost every entity
   (0.29 ms each).

## Decision

### 1. A lazy tag index inside `QueryLib`

**Epoch.** `Entity` gets a static counter `tag_epoch`. A real tag change
bumps it: a `tags` setter, `Entity.create`, `add_tag` (only when the tag
is new) and `remove_tag` (only when the tag was there). A contact rule
that re-adds the same tag each tick then forces no rebuild.
`multimesh_director.gd` writes `tags` in place at two sites. Both change
to `add_tag` / `remove_tag`.

**Index.** `QueryLib.run` keeps an index in `env["_tag_index"]`. For each
tag it holds an array of entities. Each entity also gets its ordinal: its
position in `env.entities`. The index records the `tag_epoch` and the
entity count it was built at, and rebuilds (one pass over
`env.entities.values()`) when either differs. The level transition and
the reset take entries out of the same dictionary, which changes the
count. New entities bump the epoch. So both cases trigger a rebuild.

**Candidates.** A query with `radius` keeps the spatial path, as today,
even when it also has tags. Every contact rule's `b` query is that case,
so contact results keep their order, their `once_per_a` and `limit`
picks and their `chance` rolls. Without `radius`, a query with
`tags_all` takes the smallest tag array, and a query with only
`tags_any` takes the union of its arrays. Other queries scan everything,
as today. The candidate list keeps three properties of
the full scan:

- **No duplicates.** A def can list a tag twice, and a `tags_any` union
  can hold an entity twice. The build skips a repeat, and the union
  removes repeats.
- **The same order.** `run()` returns entities in `env.entities`
  insertion order, and callers depend on it (`limit` without `order_by`,
  `once_per_a`, effect target picks). Each tag array is built in that
  order, and a union sorts by ordinal.
- **Live entities only.** Each candidate must pass
  `env.entities.get(ent.instance_id) == ent` (identity, because ids are
  reused across levels and by forced-id spawns), then the full
  `matches()` check.

**Assumption.** No query runs between `Entity.create` and the insert into
`env.entities`. No engine path does that today. A query in that window,
with a removal at the same time, would keep the count equal and miss the
new entity. The dynamic gate below would show it.

**Rebuild bound.** Effects apply at phase flushes, so a tick rebuilds at
most once per flush that spawned or changed tags (about 5 per tick at
worst). That is still far fewer scans than one per query. A one-shot
caller of `_build_env()` (debug paths) pays one build on its first query.

**Gates.**

- Static: a new check in `tools/validators/` fails on any in-place write
  to `.tags` outside `core/entity.gd`. It covers `append`, `erase`,
  `clear`, `insert`, `remove_at`, `assign` and the others.
- Dynamic: `QueryLib.verify_index = true` makes each index query also
  run the full scan that it replaces, and push an `EngineError` when the
  two **ordered** arrays differ. Radius queries do not use the index, so
  the gate does not compare them. The test runner and the scenario runner set it.
- Unit tests cover spawn, despawn, tag add and remove, and a repeat
  `add_tag`. They also cover a direct `tags` assignment, a def with a
  duplicate tag, `tags_any` order, and an env built by hand.

No content changes.

### 2. The cell size comes from the rules

**Which radii.** Only `query.radius` of rules counts, contact and other
triggers alike. A contact rule with no `radius` counts its default of
1.0. Formula radii and tutorial zone radii do not count. Radii that the
engine adds (such as the actor manager's 200) do not count either.

**When.** `register_rules` and `append_rules` set a dirty flag. The size
is computed once, when the flag is set and the rule set is complete.
That happens after boot plus `load_level`, after a level transition,
after a reset and after a save load. It is not computed in each
`register_rules` call.

**Value.** Twice the median radius, clamped to 1..64. With no literal
radius, it stays 64.

**Re-bucket.** When the size changes, `SpatialIndex` re-inserts each id
that is already in `entity_cells`, at the new size. It adds no new ids,
so entities that the index skips today (such as `_engine`) stay out. Without that, entities placed
at the old size sit in the wrong cells. A static entity (a fire pit)
then never matches a radius query again.

**Large radii.** `query_radius_ids` visits every cell in the box today,
even empty ones. When the box spans more cells than the grid holds, it
iterates the occupied cells instead and filters them by the box. The cost
becomes the smaller of the two. Without this, `doomarena3d` chase rules
(`radius: 1000`, one query per monster per tick) would go from about
1,100 to about 15,900 probes at the new size. With it, any cell size is
safe.

Expected values: `sokoban` 24 (radius 12), `doomarena3d` 16, `aldenmere`
6 (median 3.0). Six demos have no literal radius and keep 64.

## Consequences

**Positive:**

- A tag query costs about the size of its smallest tag array, not the
  world size.
- Small-radius queries in 3D demos check a few cells. Large radii cost at
  most the number of occupied cells.
- No change to any content file and no new field.

The gains are measured after the change, not assumed. The profile
harness from batch C runs on the same scenes before and after.

**Negative:**

- A flush that spawns or changes tags rebuilds the index once.
- An engine change that writes `tags` in place breaks the index. The
  static gate catches that before a test runs.
- The index adds one array entry per tag per entity.
- A new cell size changes the order of spatial candidates (cell order,
  then insertion order). `once_per_a` and `limit` without `order_by` can
  then pick another entity. Today every `once_per_a` rule in the demos
  has a single-entity `b` (the player), so nothing changes now. All
  scenario suites run again.

## Alternatives considered

**A. Hooks at every entity add and remove site** (spawn manager, effect
spawn, reset, level transition, chunk streamer, boot). Exact and with no
rebuild, but all 6 sites must stay right, and tests that build `env` by
hand would need the hooks too.

**B. A `scene.json` field for the cell size.** Simple, but each game must
know a value that its rules already imply. Rejected: it is an override
field.

**C. Keep scanning.** Two demos stay near or over the budget at p95.

## Results (2026-10-16)

The batch C harness ran old and new engine scripts in turn, 3 rounds of
600 ticks per scene. The table gives the median of the 3 runs.

| Scene | Cell size | Median tick | p95 tick |
|---|---|---|---|
| `autorace_3d` | 64 → 6.7 | 12.95 → 2.14 ms (-83%) | 24.7 → 3.9 ms |
| `aldenmere_3d` | 64 → 6.0 | 13.11 → 4.06 ms (-69%) | 28.9 → 7.6 ms |
| `doomarena3d` | 64 → 2.4 | 5.18 → 3.56 ms (-31%) | 16.1 → 7.2 ms |
| `sokoban_2d` | 64 → 24 | 0.58 → 0.31 ms (-46%) | 0.87 → 0.67 ms |

The aldenmere runs include the `tag` data fix of commit `60d3f46`.

**Deviations from the decision.**

- The expected size for `doomarena3d` was 16. The real median literal
  radius is 1.2, so the size is 2.4. Its `radius: 1000` chase rules take
  the occupied-cell path, so the small size costs nothing.
- The size is derived on the next tick, frame tick or calendar advance
  after a rule change, not at each named load site. This covers boot,
  a level load, a transition, a reset and a save load with one hook.

**Tests.** test_main passes 1269 of 1269 with `verify_index` on. The
scenario suites pass with no index mismatch: aldenmere 19, autorace 2,
doomarena3d 41, lightlab 2, sokoban 14, thousandgate 67. canyon fails
2 of 2 (`flame_animates`) on the old code too, so the failure is older
than this change.
