# ADR 0017 — Spatial-LOD rule scheduling (perf for crowds + open worlds)

_Date: 2026-05-06_
_Status: **accepted with conditions addressed (2026-05-06)**_

## Context

Yume's `PhaseScheduler.tick()` currently scans ALL entities each
tick for each rule. This is O(rules × entities) per tick. At Yume's
historical scale (~100 entities, ~50 rules) it's fine — 5000 checks
per tick at 20 Hz = 100k checks/sec, well within budget.

At open-world scale (target: ~1000-2000 entities) and crowd scale
(~100-500 NPCs each with their own behaviors), the math gets hostile:

- 1000 entities × 100 rules = 100k checks per tick
- At 20 Hz tick = 2M checks/sec
- Spatial-index radius queries (existing) reduce this significantly
  for radius-bounded queries; but tick-trigger rules without radius
  scan everything

The next-largest demo (harvestcore) has 6 defs × ~80 instances ×
~50 rules = ~4000 checks/tick. Adequate. Pushing 10x beyond that
without optimization will be slow.

## Decision

Add **spatial-LOD scheduling**: each rule can declare "only run me
on entities within R of an anchor point" (default anchor = active
actor's position). The scheduler uses the spatial index to narrow
the entity scan, skipping behaviors for distant entities.

This is opt-in — backwards-compatible. Rules without LOD config run
on all entities (current behavior).

### Rule schema additions

```jsonc
{
  "id": "pedestrian_walk_idle",
  "trigger": {"type": "tick", "interval": 8},
  "lod": {
    "anchor": "active_actor",
    "radius": 480,
    "fallback": "freeze"
    // freeze = entity stops moving; alternate: "tick_slowed:1.0"
    // (run rule but at 1Hz instead of 20Hz)
  },
  "query": {"tags_all": ["pedestrian"]},
  "effect": [
    {"type": "velocity_set", "value": "<random walk formula>"}
  ]
}
```

Three LOD anchors:
- `active_actor` — uses ADR 0016's active actor's position
- `camera` — uses camera's center (may differ from actor on dolly)
- `<entity_tag>` — uses entity matching tag (rare)

Three fallback modes for entities outside LOD radius:
- `freeze` — rule doesn't fire on them; they stop moving / behaving
- `tick_slowed:N` — rule still fires but at N Hz instead of full
  rate. Use for "NPCs still age over time but don't waste CPU on
  fine-grained behavior"
- `frozen_state` — explicit freeze + state_set to a "stationary"
  state field

### Engine work

1. `phase_scheduler.gd` extended:
   - On rule registration, compute `lod` config
   - On tick, for each rule, narrow entity scan via spatial-index
     `query_radius_ids` instead of `entities.values()`
   - Apply fallback mode for entities outside radius

2. New env binding: `env.lod_anchor_position` — Vector2/Vector3
   computed each tick from active actor or camera.

3. Spatial index already supports radius queries (W3.1); just call it
   for LOD-tagged rules.

4. Diagnostics: log `[lod] rule X: scanned N (was M)` so authors can
   verify their LOD config saves work.

### LOD radius defaults (for skill guidance)

- "Near player only" = 200-400 units (1-2 chunks)
- "In view" = up to camera bounds
- "Same neighborhood" = 1000+ units
- "Anywhere" = no LOD (run on all entities)

The `yume-crowd-designer` skill (when built) will have a section on
appropriate LOD radii per behavior type.

### Backward compat

Existing rules work unchanged. LOD is opt-in via the `lod` field.
Demos remain unaffected.

### Composition with existing ADRs

- **ADR 0014 (open-world)** — chunk-streaming + LOD scheduling are
  complementary. Chunks load/unload entities; LOD scheduling skips
  behaviors for entities loaded but distant.
- **ADR 0016 (multi-actor)** — `active_actor` is the default LOD
  anchor.

## Consequences

**Enables:**
- Crowds at 200-500 NPCs with selective behavior simulation
- Open-world games where pathfinding-heavy AI runs only near player
- Selective economy ticking (distant shops don't recompute prices
  every tick)
- Performance budget for rich behaviors when player is near, cheap
  fallbacks when far

**Constrains:**
- Per-rule LOD authoring is a real cognitive load — author must
  decide "should this rule run far away?" Must be honest: some
  rules MUST run globally (timekeeping; world.day += 1 per tick)
- Frozen-mode artifacts: NPCs stop completely when player walks
  away. May feel uncanny ("everyone's a statue when I'm not
  looking"). `tick_slowed` is the mitigation.

**Doesn't enable:**
- Visual LOD (different sprite quality per distance) — separate
  concern; renderer extension if needed
- True parallelism — Yume's tick is single-threaded. LOD reduces
  total work; doesn't parallelize remainder.

## Alternatives considered

### A. Engine-wide rule-frequency throttling

Run all rules at lower Hz when entity count exceeds threshold.
Crude; degrades game-feel uniformly. Better to let authors decide
per-rule.

### B. Implicit LOD (engine guesses)

"If a rule's query has tag X and player isn't near any X, skip it."
Heuristic; unreliable. Explicit config better.

### C. Spatial partitioning of the rule registration

Pre-bucket rules by their typical query type. Premature
optimization. Use general LOD instead.

## References

- W3.1 SpatialIndex — already supports radius queries
- ADR 0014 (open-world) — composable
- ADR 0016 (multi-actor) — active_actor anchor
- yume-crowd-designer skill (future) — primary consumer

## Tech-director review

_Date: 2026-05-06_
_Reviewer: yume-tech-director_

### Invariant checks

| Invariant | Status | Notes |
|---|---|---|
| #1 JSON-only content channel | ✓ | LOD config in rules (already JSON) |
| #2 No semantic effect types | ✓ | no new effects |
| #3 No entity-class hierarchy | ✓ | none |
| #5 Queries first-class | ✓ | uses spatial-index radius queries (existing) |
| #8 Engine = primitives + interpreter | ✓ | optimization on existing scheduler; no new vocabulary |
| #9 Phase ordering | ✓ | doesn't change phase ordering |

This is the cleanest ADR of the six. No new vocabulary, no new
content channels, no new dependencies. Pure optimization layer.

### Concerns

1. **LOD radius hysteresis missing**. A tick rule with
   `radius: 200` will jitter — entities at 199 units fire it; at
   201 don't. ADR 0014 (open-world) uses load_radius < unload_radius
   for chunks; same pattern needed here. Recommend: add `enter_radius`
   and `leave_radius` (or `radius` + `hysteresis`) so entities don't
   flip-flop on the boundary.

2. **`tick_slowed` implementation cost**. Per-rule per-entity tracking
   of "last fired tick" adds state. If 500 entities × 50 rules with
   tick_slowed, that's 25k state entries. Manageable but not free.
   Spec: storage location + lifecycle.

3. **Determinism implications underspecified**. `freeze` mode = entity
   stops behaving when player walks away. Acceptable for crowds
   (anonymous pedestrian doesn't matter). Not acceptable for named
   NPCs (a farming-sim villager Marie should keep aging at her shop even
   when player isn't there). Authoring guidance: freeze for crowds,
   tick_slowed for named NPCs.

4. **lod_anchor_position computation**. Computed each tick from
   active_actor or camera. Spec: ONE computation per tick, cached
   in env, reused across all LOD-tagged rules. Don't recompute per
   rule.

5. **No-LOD baseline preserved**. Rules without `lod` config run on
   all entities (current behavior). Make this explicit in the schema
   doc.

6. **Interaction with ADR 0014 streaming**. LOD scheduling AND chunk
   streaming both filter "what's near player." Risk of double-filter:
   chunk unloads entity → entity gone → LOD doesn't see it (correct).
   But what if LOD radius > stream_radius? Author assumes entity is
   visible at LOD distance, but it's been unloaded. Need: either LOD
   radius ≤ stream_radius (enforced at load), or document this is
   author's responsibility.

### Verdict

**accept-with-conditions**.

Conditions before implementation:

1. **Add hysteresis**: split `radius` into `enter_radius` /
   `leave_radius` (or use a single radius + hysteresis offset). Avoid
   boundary flip-flop.
2. **Spec tick_slowed state location** (recommend: scheduler-internal
   dictionary keyed by (rule_id, entity_id) → last_fired_tick).
3. **Document determinism implications**: freeze for anonymous,
   tick_slowed for named. Bake into yume-crowd-designer skill.
4. **Cache lod_anchor_position once per tick** in env.
5. **Validate LOD radius ≤ ADR 0014 stream_radius** at load (or warn).
6. **Test plan**: (a) entity entering/leaving LOD radius behaves
   correctly; (b) tick_slowed reduces fire frequency by expected
   factor; (c) rules without LOD config still run on all entities.

Lowest-risk ADR of the six. Reasonable to land before 0014/0015 if
user wants quick win on existing demo perf at scale.

## Revisions per tech-director review (2026-05-06)

### 1. Hysteresis to prevent boundary flip-flop

**Decision**: split `radius` into `enter_radius` and `leave_radius`:

```jsonc
"lod": {
  "anchor": "active_actor",
  "enter_radius": 200,    // entities inside this radius START firing
  "leave_radius": 240,    // entities outside this radius STOP firing
  "fallback": "freeze"
}
```

Convention: leave_radius ≥ enter_radius * 1.1 (10% hysteresis
minimum). Engine warns at load if leave_radius ≤ enter_radius.

Authoring shorthand: if only `radius` provided, engine sets
`enter_radius = radius * 0.95, leave_radius = radius * 1.05` (5%
each side).

### 2. tick_slowed state location

**Decision**: per-rule per-entity tracking lives in scheduler-
internal dictionary keyed by `(rule_id, entity_id)` →
`last_fired_tick`. Engine-private; not exposed via env.

When entity enters tick_slowed mode, scheduler computes `tick_count
- last_fired_tick >= interval_at_slowed_rate`; only fires when met.

Entries are GC'd when entity despawns (existing entity-cleanup hook).
At 500 entities × 50 LOD-tagged rules = 25k entries; ~200KB; fine.

### 3. Determinism — author guidance

**Decision**: explicit guidance on which fallback to pick by use
case (will be baked into yume-crowd-designer skill):

| Use case | Fallback |
|---|---|
| Anonymous pedestrian crowd | `freeze` (no behavior; cheap) |
| Named NPC with daily schedule | `tick_slowed:0.5` (1 tick per 2 sec) |
| Distant economy ticking (shops) | `tick_slowed:0.1` (1 tick per 10 sec) |
| Plot-critical scripted character | `frozen_state` (no behavior + visible static state) |

Engine doesn't enforce; authors decide. Skill provides the heuristic.

### 4. Cache lod_anchor_position

**Decision**: scheduler computes `env.lod_anchor_position` ONCE per
tick at start of phase processing. All LOD-tagged rules in that
tick read the cached value.

Position resolves from active_actor_id (per ADR 0016) at tick start.
If active actor switches mid-tick, the change applies next tick
(consistent with switch_actor timing in ADR 0016).

### 5. LOD radius vs ADR 0014 stream_radius

**Decision**: load-time validation that `enter_radius ≤
chunk_size.x * stream_radius` (and same for y). If a rule's LOD
radius would extend beyond loaded chunks, engine warns at load
(not error — author may have valid reason; e.g. persistent entities
beyond stream radius).

Scenario tests verify the warning fires when expected.

### 6. Test plan

1. **Hysteresis**: entity at boundary with enter=200, leave=220.
   Move entity to 210. Rule still firing. Move to 230. Rule stops.
   Move back to 210. Rule still NOT firing (must enter ≤ 200 first).
2. **tick_slowed**: rule with `tick_slowed: 0.5` (every 2 ticks)
   in slowed mode fires at ticks N, N+2, N+4, etc.
3. **No-LOD baseline**: rule without lod field runs on all entities
   regardless of distance (current behavior preserved).
4. **Cache hit**: profiler shows lod_anchor_position computed once
   per tick despite many LOD-tagged rules.
5. **Stream-radius warning**: rule with enter_radius > stream*chunk
   logs warning at load.

### Final verdict

All conditions addressed. **Status: accepted.**

Per revised build order: lands FIRST (cleanest, lowest contract
risk; provides immediate perf benefit to existing demos at scale).
