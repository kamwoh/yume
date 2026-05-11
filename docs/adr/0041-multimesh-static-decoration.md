# ADR 0041 — MultiMeshInstance3D for static decoration

_Date: 2026-05-11_
_Status: accepted-pending-implementation (2026-05-11) — tech-director reviewed + 6 conditions; 1-4 reflected in this revision; 5-6 apply at engine PR merge_

## Context

Empirical case (2026-05-11, Aldenmere Three Days to Eat demo
recording): the user reported visible slowdown. Audit showed ~480
entities at peak (~211 trees + 250 grass + decoration). Each
entity goes through `entity_mesh_3d.gd::_build_mesh_children` which
creates one `MeshInstance3D` per mesh-def primitive. Tree mesh
defs have 4-6 primitives, grass has 3 — total scene tree contained
~3000 `MeshInstance3D` nodes, each costing its own draw call.

Cheap mitigations applied:

- Mesh-def `cast_shadow: false` cascading to all primitives,
  per-primitive override available. Wired in `mesh_lib.gd`.
  Flagged on `grass_tuft_3d`, `cloud_3d`, `bird_3d`.
- Tree scatter counts reduced ~60% (211 → 84) + grass 250 → 100.

Mitigations brought entity count to 234 and skipped ~300 shadow
passes per frame, but the underlying problem — N entities → N draw
calls — remains. Any future game with dense decoration (Phase 1
full village, a TD with 100 towers, a sim with 500 crops, an
open-world RPG with trees) hits the same wall.

**The fix is well-known in Godot:** `MultiMeshInstance3D`. Same
mesh, N transforms, one draw call regardless of N. Trees of the
same type render in a single draw call.

This ADR proposes adding a render-side batching layer to Yume that
detects static-decoration entities and renders them via MultiMesh
while keeping the Entity layer untouched (Entity stays for game
logic, collision AABB, crosshair_target_id, etc.).

## Decision

Add an engine module `multimesh_director.gd` that runs once after
`world.gd::_spawn_initial` completes (and again when level
transitions land):

### 1. Static detection

An entity qualifies as "static" if **all** hold:

- Its mesh def has `multimesh_eligible: true` (opt-in, default
  false — safe default to not regress existing demos).
- The mesh def declares no `animations` block (animation_director
  needs per-entity meshes — animated entities are never static).
- The entity has no `state.velocity` set, or velocity is the zero
  vector.
- The entity is not tagged `actor`, `projectile`, or `player`
  (defensive — these tags imply runtime motion).
- No tick / signal / contact rule's `effect` mutates this entity's
  `state.position`, `state.scale`, `state.yaw`, or `state.velocity`.
  Detected at world load by scanning rules for `target` resolving
  to this entity's tags AND `field` matching the mutation set.

If any check fails, the entity falls back to the per-entity
`MeshInstance3D` pipeline (current behavior). No regression for
animated villagers, moving birds, drifting clouds.

### 2. Grouping + MultiMesh build

For each (mesh_def_id, primitive_index) pair across all static
entities, build one `MultiMeshInstance3D`:

```gdscript
var mm := MultiMesh.new()
mm.transform_format = MultiMesh.TRANSFORM_3D
mm.mesh = <the primitive's Mesh resource>
mm.instance_count = <count of entities in this group>
for i, ent in static_group:
    var t := Transform3D()
    t.origin = ent.position + primitive.pos * ent.scale
    t.basis = t.basis.scaled(Vector3(ent.scale, ent.scale, ent.scale))
    t.basis = t.basis.rotated(Vector3.UP, ent.yaw)
    mm.set_instance_transform(i, t)
var mmi := MultiMeshInstance3D.new()
mmi.multimesh = mm
mmi.cast_shadow = <from mesh def + primitive>
world.add_child(mmi)
```

One MultiMeshInstance3D per primitive of each mesh def used by
static entities. Trees with 5 primitives → 5 MultiMeshInstance3Ds.
With 84 trees of the same type, that's 5 draw calls instead of 420.

### 3. Skip per-entity rendering

For static entities, `entity_mesh_3d.gd::_build_mesh_children` is
not called. The Entity node still exists (game logic, collision,
crosshair-target lookup all work), but it owns no MeshInstance3D
children — the visual comes from the MultiMesh.

`entity_mesh_3d.gd` checks `entity.has_tag("_multimesh_managed")` at
init; if true, skips its mesh-build path. multimesh_director
applies the tag during grouping.

### 4. Dynamism promotion (escape hatch)

If a static entity later becomes dynamic (e.g., a rule fires
`state_set scale=2.0` or `velocity_set`), promote it:

- Remove its slot from the MultiMesh (set transform to a zero
  scale, effectively invisible — compacting the array is too
  expensive per change).
- Remove the `_multimesh_managed` tag.
- Trigger `entity_mesh_3d._build_mesh_children` to create per-
  entity MeshInstance3Ds.
- Resume the normal per-entity render path.

Promotion is one-way (no demotion back to MultiMesh) to keep the
implementation simple. If an entity goes through a transient
dynamic phase and back, it stays in the per-entity pipeline.

**Freeze-policy (per Invariant #10):** promotion DEFERS under
`screen_freeze_world` or `overlay_freeze_world`. The director
maintains a `_pending_promotions: Array[String]` (entity ids).
When `world.gd::_on_tick` would early-return for freeze, the
director's drain method also exits without applying. On freeze
release (any tick where neither freeze flag is set), drain the
pending list. Rationale: a frozen scene shouldn't materialize
per-entity MeshInstance3Ds in the background while the player
reads a modal — visual consistency wins.

Log line: `[MULTIMESH-PROMOTE-DEFERRED] entity=<id> reason=freeze`.

### 5. Mutation-field detection set (static disqualifier)

Static detection scans every rule's effects for mutations of these
fields targeting an eligible entity. Any hit disqualifies the
entity (falls to per-entity render):

```gdscript
const MUTATION_FIELDS := ["position", "scale", "yaw", "velocity",
                          "tint", "color", "material_override"]
```

Plus: rules with `tag_add` / `tag_remove` effects targeting the
entity (or a query that matches it) disqualify too — tag changes
can re-route grouping or visual.

Per-instance tint regression: any entity whose `state.tint` at
spawn differs from the mesh-def's params disqualifies (the
multimesh shares one material; the instance with a different tint
can't be batched). Detected at the static-detection pass.

### 6. Cleanup on level transition (per Invariant #11)

`transition_level` swaps levels — the OLD level's static groups
must be freed:

- `multimesh_director.cleanup_level()` runs BEFORE `_spawn_initial`
  for the new level.
- Iterates all `MultiMeshInstance3D` nodes the director created;
  `queue_free()` each. The corresponding entities are already being
  destroyed by transition_level's swap, so the multimesh nodes are
  the only remaining reference.
- Re-runs grouping AFTER the new level's `_spawn_initial` completes.

Log line: `[MULTIMESH-CLEAR] freed N nodes from level <id>`.
Mirrors the persistent-skip / persistent-teleport log discipline.

### 5. Mesh-def opt-in

Authors mark which meshes can use MultiMesh via a top-level field:

```jsonc
{
  "conifer_tree_3d": {
    "multimesh_eligible": true,
    "primitives": [ ... ]
  }
}
```

Default false. Animated mesh defs (with `animations` block) are
implicitly false regardless.

Authors flag the obvious candidates (trees, grass, rocks, props
that never move). Animated NPCs / projectiles / moving entities
don't get the flag.

## Consequences

### Positive

- ~10× draw-call reduction for any game using static decoration.
  Aldenmere: 3000 mesh nodes → ~30 multimesh + ~200 dynamic mesh.
- Frees performance budget for richer scenes. Phase 1 v2 can have
  1000+ trees + 500 grass + crops + full village without
  re-thinking density.
- Per-instance scale + yaw still work (encoded in the MultiMesh
  per-instance Transform3D).
- Backwards-compatible — existing demos without the opt-in field
  keep their current behavior; nothing changes for them.

### Negative

- Per-instance color variation (`mesh.params` override) is
  lost — MultiMesh shares one material across all instances. If
  authors set `state.tint` to recolor individual trees, those
  entities must be non-static. Acceptable for v1 (no demo uses
  per-instance tint).
- Promotion is one-way — entities that briefly become dynamic
  (rare) stay in the per-entity path forever. Not optimal but
  simpler than two-way migration.
- Grouping math happens at world load; first frame slightly
  slower (negligible — milliseconds for 500 entities).

### Neutral

- Adds one engine module (`multimesh_director.gd`, ~200 lines).
- Adds one mesh-def field (`multimesh_eligible: true`).
- Adds one engine-managed tag (`_multimesh_managed`).

## Alternatives considered

### A) Per-entity instancing without MultiMesh

Use GeometryInstance3D's GI_MODE_STATIC. Doesn't reduce draw
calls — each MeshInstance3D still costs one draw. Misses the
core problem.

### B) Manually build a single combined Mesh per group

ArrayMesh + manual vertex merging. Custom shader for per-instance
data. Re-implements what MultiMesh does for free. Rejected — Yume
respects Godot's exposed primitives (per ADR 0021).

### C) Spatial-LOD culling

Hide entities past ~30m. Helps but doesn't help close-up density;
fundamentally a smaller scope improvement. ADR 0017 already exists
for rule scheduling; extending to renderer is feasible but
complementary to MultiMesh, not a replacement.

### D) Skip MultiMesh; ship Phase 1 with reduced density

What we currently do — pre-emptively trim entity counts. Limits
visual ambition. Soul vocabulary axis 5 ("object density ~1 per
9-12 m²") demands density; trimming undermines the framework's
positioning.

## Implementation sketch

1. **Day 1**: Build `multimesh_director.gd`. Static detection +
   grouping. No promotion yet. Test on Aldenmere — confirm trees
   render via MultiMesh, count draw calls before/after with
   `--debug-collisions` or `Engine.get_frames_drawn()` profile.
2. **Day 2**: Wire dynamism promotion. Test by scripted-firing a
   rule that mutates a tree's scale; verify the tree promotes
   correctly. Add `multimesh_eligible` to Aldenmere's `prop_tree*`
   and `prop_grass_tuft` meshes.
3. **Day 3**: Validators + skill update — `yume-asset-designer`
   skill recommends `multimesh_eligible: true` on any new
   static-decoration mesh. Add `tools/validate_mesh_perf.py` that
   warns when a high-count mesh lacks the flag.

## Risk

- **Per-instance color regression**: if a future game uses
  `state.tint` for per-instance recoloring, the multimesh path
  loses it. Mitigation: tint detection in static check (entity
  with `state.tint` set falls back to per-entity).
- **Promotion edge cases**: an entity going dynamic mid-frame
  while its MultiMesh slot is still rendering could flicker. Test
  with a scripted scenario.
- **Shadow correctness**: each multimesh primitive declares its
  own `cast_shadow` (inherited from mesh def). Verify shadows
  remain correct across the migration.

## Tech-director review pending

Per ADR discipline this proposal needs tech-director gating
before engine session. Invariant audit must pass:

- Does the new module add semantic effect types? **No** — pure
  render-side optimization.
- Does it change tick semantics? **No** — runs at world-load and
  on promotion events only.
- Does it bypass the JSON contract? **No** — opt-in field in
  mesh defs, otherwise transparent.

Expect tech-director ACCEPT with possibly conditions on:
- Promotion semantics (one-way vs two-way)
- Per-instance tint regression handling
- Test coverage requirement (scenario test that a tree mesh
  flagged eligible renders via MultiMesh, not per-entity)

## Tech-director review

_Date: 2026-05-11_
_Reviewer: yume-tech-director_
_Verdict: **accept-with-conditions**_

Invariant audit passes (#1, #2, #3, #5, #8, #9, #12 hold; #10
and #11 surface conditions noted below). The core design — pure
render-side optimization, opt-in JSON field, no new game-state
vocabulary — is sound and ADR-shaped correctly. Approving with
six conditions before engine session lands.

### Conditions for engine session

**1. Rename engine-applied tag to `__multimesh_managed`.**

Per Yume convention, engine-managed metadata uses an underscore
prefix to distinguish from content-authored tags. Existing examples:
`_origin` and `_params` (lib resolver stamps), `_pending_*` (world
state flags), `_phase` (rule context). The proposed `_multimesh_managed`
tag is engine-applied (set by the director, never by content). Must
use the same convention.

```
_multimesh_managed  →  __multimesh_managed
```

Update the ADR text + implementation.

**2. Declare promotion behavior under freeze_world.**

Per Invariant #10, every pending-state pipeline must explicitly
declare its freeze policy. State_set effects from screen buttons
DO run under freeze (per the pending-pipeline table). If such an
effect mutates a static entity's tint or scale, the director would
try to promote it mid-freeze.

Required: explicit declaration in the ADR + engine code comment.
Recommended path: **defer promotion until freeze ends.** Queue
promotion requests into a buffer; drain on freeze release.
Rationale: visual consistency — a frozen scene shouldn't be
materializing per-entity MeshInstance3Ds in the background while
the player reads a modal.

Alternative if defer is hard: allow promotion under freeze with
note that the world doesn't visually advance, only its render
topology changes. Lower preference.

**3. Cleanup on `transition_level`.**

Per Invariant #11, the OLD level's static groups must be cleaned
up. Add to the ADR + implementation:

- `transition_level` swap → multimesh_director.cleanup_level() runs
  BEFORE `_spawn_initial` for the new level.
- Iterates all `MultiMeshInstance3D` nodes created by the director;
  calls `queue_free()` on each.
- Re-runs grouping after new level's `_spawn_initial` completes.

Log line: `[MULTIMESH-CLEAR] freed N nodes from level X`. Mirrors
the persistent-skip / persistent-teleport log discipline.

**4. Expand the mutation-field detection set.**

Current ADR check: position, scale, yaw, velocity. Insufficient —
tint / color / material_override / tag mutations all violate
multimesh shared-material assumptions or change grouping. Define
as an explicit engine constant:

```gdscript
const MUTATION_FIELDS := ["position", "scale", "yaw", "velocity",
                          "tint", "color", "material_override"]
```

Plus: tag-add / tag-remove effects targeting eligible entities also
disqualify them (tag changes can re-route grouping). Document the
full set in the ADR + a one-line comment in the engine module so
it's grep-able from future skill code.

Per-instance tint regression handling: any entity with
`state.tint` set at spawn time AND a different value from the
mesh-def's params → not static (defaults differ, can't share
material). Implementation detail of static detection.

**5. Visual gate at merge.**

Per `.claude/rules/engine-scripts.md` § visual validation gate,
the engine PR for this ADR MUST include:

- Aldenmere forest capture BEFORE the change (baseline).
- Aldenmere forest capture AFTER the change (multimesh path
  active).
- Read the PNG, confirm visual parity: same tree count, same
  positions, same scales, same yaws, same shadows-on / shadows-off
  behavior. Any discrepancy = fix before merge.

Note: this isn't a static-screen visual gate (it'd look the same);
it's specifically a count-verification capture. Engine PR must
log `[MULTIMESH-BUILD] N groups, M instances total` and the
capture must show the entities rendered.

**6. Test coverage.**

Per the test discipline rule (`.claude/rules/tests.md`), add a
scenario test in `test_runner.gd`:

- Load a fixture world with 10 entities of a flagged-eligible mesh.
- Run world.gd boot sequence.
- Assert: `MultiMeshInstance3D` child count = number of primitives
  in the mesh def (each primitive → one multimesh).
- Assert: each MultiMesh's `instance_count` = 10.
- Assert: 0 `MeshInstance3D` children directly under the test
  entity nodes (the per-entity render path was skipped).
- Additional sub-test: fire a `state_set scale` effect on one
  entity, assert promotion fires + the entity now has its own
  MeshInstance3D children + the MultiMesh's slot is zero-scaled.

### Conditions for documentation

- Add `__multimesh_managed` tag to the engine-managed metadata
  list in `docs/30_framework_primitives.md` (alongside `_origin`,
  `_params`, `_phase`, `_pending_*`).
- Update `yume-asset-designer` skill to recommend
  `multimesh_eligible: true` on any new static-decoration mesh
  (trees, grass, rocks, props that never animate).
- Add to `data-demo.md` rules: when authoring a static-decoration
  mesh def, set `multimesh_eligible: true`; if authoring a mesh
  that ANIMATES (has `animations` block) or has runtime per-instance
  variation, omit the flag.

### Known limitations to document

- Per-instance per-entity tint that differs from mesh-def defaults
  forces non-static. Acceptable for v1; future ADR if a game
  needs it.
- One-way promotion. Memory accumulates if many entities go
  transient-dynamic in a long session. Acceptable for v1;
  bidirectional migration is a future ADR.
- Material instance count: each MultiMeshInstance3D has its own
  material override. The current `_make_material(color)` per
  primitive creates a fresh StandardMaterial3D — this is correct
  but means N flagged meshes use N materials. Acceptable.

### Approval timing

ADR status → **accepted-pending-implementation** once conditions
1-4 are reflected in the ADR text itself (rename, freeze policy,
cleanup, mutation field set documented). Conditions 5 (visual
gate) and 6 (test coverage) apply at engine PR merge.

When the orchestrator updates the ADR with these conditions
woven in, tech-director re-reviews briefly and stamps **accepted**
for engine session to start.
