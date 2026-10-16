# ADR 0079 — Simulation tiers (`abstract` / `embodied`)

_Date: 2026-08-16_
_Status: accepted for phase 1 (status corrected 2026-10-16 in batch H: phase 1 shipped in commit 23921b6, and thousandgate sets `embodied_radius`. Phase 2 stays deferred)._

## Context

A living historical world wants ~1000 named people who keep existing when
the player is not looking: taking service somewhere, gaining rank, moving,
dying. Only the few dozen in the current town need bodies, meshes,
colliders, or animation.

The engine has no way to express that difference. Every entity is
equivalent: full renderer attach, full physics body, and every tick rule
scans every match. `ChunkStreamer` (ADR 0014) despawns entities outside a
radius, which is the right instinct for *props* and exactly wrong for
*people* — a despawned NPC stops existing, so a world where the cast
continues its own lives is not expressible at all.

ADR 0017 (spatial LOD) is the nearest existing tool, but it is scoped
per-rule: each rule carries its own `lod` block with its own radii and its
own hysteresis state. That answers "should this rule fire on this entity
right now"; it does not give the world a shared notion of *which entities
are currently real enough to have a body*.

**And a dead field.** `Rule.scope` has been parsed in `Rule.from_dict`
since it was written and read by **nothing** — an author setting it got
silence. `validate_engine_wiring.py` (added with ADR 0078) flags it. Its
name is exactly right for what is missing here.

## Decision

Every entity is at one of two **simulation tiers**, and rules declare
which tiers they apply to.

**Tier is DERIVED, never authored.** It comes from the entity's distance
to the LOD anchor (the active actor) against `simulation.embodied_radius`
in `scene.json`, with hysteresis so an entity pacing the boundary does not
flicker. There is deliberately no per-def override field, per the
no-escape-hatch invariant in `.claude/rules/data-demo.md`: an override
would let a def opt out of the derivation and drift.

- **`embodied`** — inside the radius. Full presentation and full rules.
- **`abstract`** — outside it. Still present in `env.entities`, still
  queryable, still holding state and relations; simulated only by rules
  that opt in.

**`Rule.scope`** — the dead field, given meaning:

| value | runs on |
|---|---|
| `""` (default) | every entity, both tiers — every existing rule, unchanged |
| `"embodied"` | only entities inside the radius |
| `"abstract"` | only entities outside it |

So a world-simulation rule (`scope: "abstract"`) advances distant lives
coarsely, while movement, collision, and animation rules
(`scope: "embodied"`) never touch entities with no body. Rules that leave
`scope` unset behave exactly as they do today, so this is inert for every
existing demo.

Omitting `simulation.embodied_radius` means every entity is `embodied` —
the pre-0079 behaviour, unchanged.

### Phase 1 (this commit)

Tier derivation, the `env` plumbing, and `scope` filtering on rule
dispatch. This is the CPU win that matters first: for a 1000-entity cast
the dominant recurring cost is rules scanning every entity every tick, and
`scope` removes it without touching any presentation code.

### Phase 2 (deferred, deliberately)

Detaching presentation from `abstract` entities — freeing the renderer
child, the physics body, and the animation player on demotion and
rebuilding them on promotion. This is where the memory and draw-call win
lives, and it is genuinely invasive: `spawn_manager` owns renderer attach,
several directors assume a stable node per entity, and promotion must be
lossless for state, relations, and position.

It is deferred rather than guessed at because **nothing has measured it
yet**. Phase 1 makes the tier real and observable, which is the
prerequisite for measuring whether Phase 2 is worth its blast radius.
This ADR is the record of the architecture; it is not a claim that
de-embodiment shipped. Following ADR 0030 / 0032 / 0033, which landed the
same way.

## Consequences

**Enables.** A cast that outlives the camera. Rules can be written at the
resolution they deserve: "every villager re-evaluates their employment
once a season" costs nothing when the villager is a data row. Combined
with ADR 0078, a distant town can run its whole economy on the calendar
clock while the player is elsewhere.

**Costs.** A second axis authors must think about, and picking the wrong
`scope` fails quietly — a rule scoped `abstract` that moves an entity does
nothing visible. The validator gate below covers the sharpest instance of
that. Tier derivation is one distance test per entity per tick, shared
across all rules via the cached anchor.

**Precludes.** Nothing existing: unset `scope` and absent
`embodied_radius` both mean "as before". It does NOT yet reduce memory or
draw calls — that is Phase 2, and this ADR is explicit rather than
implying otherwise.

**Invariant check (#8).** `scope` is a dispatch quantifier, not a semantic
verb, and tier is derived from geometry the engine already computes. The
engine never learns what an "NPC" is. A strategy game's off-screen
provinces, a factory sim's distant production lines, and an ecology sim's
unobserved populations are the same two tiers.

## Alternatives considered

**A. Extend ADR 0017's per-rule `lod` blocks instead.** Rejected: `lod` is
per-rule state with per-rule radii, so twenty rules that all mean "only
when nearby" each carry their own copy and can silently disagree. Tier is
a property of the ENTITY that many rules read; that is a different thing
wearing similar clothes. The two compose — `lod` still refines an
individual rule's cadence within a tier.

**B. Let ChunkStreamer despawn distant NPCs (today's behaviour).**
Rejected: despawn is not abstraction. A despawned NPC has no state, so it
cannot take service, age, or die while away — which is the entire feature.

**C. A per-def `sim_tier` field.** Rejected under the no-escape-hatch
invariant. It would let one def pin itself embodied, and the next author
would forget the matching fields, exactly as `_aabb_intent` did before it
was deleted.

**D. Do Phase 2 now, in the same change.** Rejected: it rewrites renderer
attach, physics-body lifetime, and several directors' assumptions on the
strength of an unmeasured guess. Phase 1 is what makes the measurement
possible.

## References

- Code: `godot/scripts/engine/core/rule.gd` (`scope`),
  `godot/scripts/engine/core/phase_scheduler.gd` (`_entity_tier`,
  `_scope_allows`), `godot/scripts/engine/coordinators/world_loader.gd`
  (`load_simulation_cfg`)
- Tests: `godot/scripts/engine/tests/test_runner.gd` → `test_sim_tiers`
- Gates: `validate_engine_wiring.py` — `scope` stops being a dead field,
  which is what flagged it. `validate_rules.py` — a rule scoped
  `"abstract"` must not use presentation effects (`velocity_*`,
  `pathfind_to`, `raycast_hit`), since those act on a body the tier is
  defined as not needing.
- Related: ADR 0017 (spatial-LOD — the per-rule cadence tool this
  composes with), ADR 0014 (chunk streaming — despawn, which this is
  explicitly not), ADR 0078 (calendar clock — the natural clock for
  abstract-tier rules), `.claude/rules/data-demo.md` § no per-def escape
  hatches
