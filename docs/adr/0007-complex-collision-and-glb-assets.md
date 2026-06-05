# ADR 0007 — Complex collision: `aabb_volumes` + GLB visual assets

_Date: 2026-05-04_
_Status: **accepted with conditions** (tech-director review 2026-05-04)_

## Context

ADR 0004 introduced `blocks_motion` with a single `aabb_extents`
property — one axis-aligned box per entity. doomarena3d's walls,
pillars, and machinery work fine with this: each is a simple
prismatic shape that fits one AABB cleanly. The constraint hasn't
hurt yet.

But several near-future content directions hit the wall:

1. **Multi-shape props** (a "house" with a roof, walls, chimney
   that should each block movement). Decomposing into N entities
   per house works but inflates entity count and visually treats
   one-thing as many.
2. **Visually-rich content** (anything beyond stacked primitive
   boxes). The current `meshes.json` composite system hits a
   ceiling at "looks like Lego." For a game pitched as e.g. a
   farm-village simulation, the visual fidelity gap matters even
   though Yume's value is the simulation layer, not the renderer.
3. **AAA-flavored authoring patterns** (level designers in every
   modern engine work with imported `.glb`/`.fbx` meshes + auto-
   generated convex collision). Yume's "stack of primitive shapes"
   model is an outlier without a clear payoff.

The natural primitive expansion has two parts that are cheaper to
land together than separately:

- **Multi-AABB per entity** — one entity, multiple collision boxes.
- **External `.glb` visual asset** — load arbitrary 3D meshes from
  the Godot asset pipeline; auto-derive collision via Godot's
  `create_multiple_convex_shapes()` API at level load.

Both preserve Yume's "all gameplay-relevant data is JSON" invariant
because:
- Collision data is either authored as JSON (`aabb_volumes` array)
  OR derived at engine load-time (no human authoring step).
- `.glb` is a visual asset like `.png` — referenced by path,
  external to the data folder, same model as Yume's existing PNG
  sprite support per CLAUDE.md ("asset abstraction layers — drop
  files here, engine auto-detects").

Crucially, **no human is required in the authoring loop**. The
LLM content-designer skill writes JSON; the AI asset-gen pipeline
or a Blender export produces the `.glb`; the engine derives
collision at load. yume-qa-tester catches cases where auto-derived
collision is wrong (e.g. hollow buildings) and the loop iterates
on the asset prompt or a JSON `collision_mode` flag.

This decision is **not** about adopting Godot's PhysicsServer3D
wholesale — Yume keeps its custom swept-AABB integrator. The
`.glb` collision is reduced to a list of AABBs at load time and
stored on the entity like any other multi-AABB volume.

## Decision

Three coordinated additions to the engine surface:

### 1. `properties.aabb_volumes: [{offset, extents}, ...]`

Optional array on `blocks_motion` entities. When present, replaces
the single `aabb_extents` field. Each volume is a separate AABB
attached to the entity, in entity-local space:

```jsonc
{
  "id": "house",
  "tags": ["building", "blocks_motion"],
  "properties": {
    "aabb_volumes": [
      {"offset": [0, 1.5, 0],  "extents": [2, 1.5, 2]},
      {"offset": [0, 4.0, 0],  "extents": [0.4, 0.6, 0.4]}
    ]
  },
  "visual": {"mesh": "house_a"}
}
```

Backward compatibility: existing `aabb_extents: [hx, hy, hz]` +
`aabb_offset: [...]` continue to work — the engine treats them as
a single-element `aabb_volumes` internally. No migration needed.

Motion integrator's swept-AABB check iterates over all volumes
per blocker entity. Cost is `O(N × Σ_M(volumes_per_entity))` —
typically <2× the existing cost for normal scenes.

### 2. `visual.glb: "res://path/to/file.glb"`

New visual mode. Engine loads the GLTF asset via Godot's
`ResourceLoader.load()` (already supported for `.tscn` resources;
`.glb` works the same way once `EditorImportPlugin` has run on
the file). The instantiated mesh is parented to the entity's
visual node alongside any other visual primitives.

`.glb` files live under `godot/data/<game>/meshes/`
or a shared `godot/meshes/` library.
Path follows the same convention as PNG sprites today.

**2D renderer fallback**: `visual.glb` is 3D-only — the 3D renderer
(`entity_mesh_3d.gd`) parses it, the 2D renderer (`entity_sprite_2d.gd`)
ignores it. An entity with ONLY `visual.glb` and no 2D fallback
(`sprite_2d`/`shape`/`color`) renders as the default fallback shape
in a 2D scene (same behavior as `visual.mesh`-only entities today —
this is consistent with ADR 0002's renderer-agnostic-Entity invariant:
the Entity itself is renderer-agnostic, but visual fields are
renderer-specific by design). For cross-renderer-compatible games,
content authors should provide both `glb` (3D) and `sprite_2d`/`shape`
(2D fallback).

### 3. `properties.collision_mode: "convex_decomp" | "concave" | "single_aabb"`

Controls how engine derives collision when `visual.glb` is
present AND `aabb_volumes` is absent.

- **`convex_decomp` (default)**: At level load, engine calls
  `mesh.create_multiple_convex_shapes()` on each MeshInstance3D
  in the .glb. For each returned ConvexPolygonShape3D, computes
  the enclosing AABB (min/max over hull vertices). Stores the
  list as the entity's runtime `aabb_volumes`. Suitable for
  non-hollow shapes (buildings as exterior cover, props,
  vehicles).
- **`concave`**: Engine uses `ArrayMesh.create_trimesh_shape()`
  to produce a triangle-mesh collider. Yume's swept-AABB
  integrator can't directly use a triangle mesh, so this mode
  registers a Godot `StaticBody3D` with `ConcavePolygonShape3D`
  and queries `PhysicsServer3D.intersect_ray/shape` from the
  motion integrator. Heavier; only for content where convex
  decomp is wrong (hollow buildings, complex L-shapes the
  player walks INTO).
- **`single_aabb`**: Skip Godot API entirely; compute the .glb's
  overall bounding box. One AABB per entity. Cheapest, lowest
  fidelity — useful as a fallback or for known-axis-aligned
  shapes.

Resolution order:
1. If `aabb_volumes` present → use it, ignore `.glb` collision.
   (Hand-authored JSON wins; same path the LLM skill uses for
   `meshes.json` composites.)
2. Else if `visual.glb` present → derive per `collision_mode`.
3. Else if `aabb_extents` present → single AABB (legacy).
4. Else → no collision; entity is purely visual.

## Consequences

**Enables:**
- Multi-shape props in one entity (a chair, a house, a vehicle —
  all with multiple collision boxes; not a coordination problem
  across N entities).
- Visually-rich content via `.glb` import without Yume inventing
  its own mesh format. Designer (LLM or asset-gen) just provides
  a path.
- Cleaner content-designer output — instead of authoring 20
  separate "house wall" entities to make a building, author one
  `house` entity with 5 `aabb_volumes`.
- Future content paths (an actual village simulation, a city
  shooter, a sci-fi corridor crawler) become viable without
  further engine work.

**Costs:**
- Engine surface grows by 3 fields (`aabb_volumes`,
  `visual.glb`, `collision_mode`). Not a small expansion. Each
  is documented in `docs/guideline/30_framework_primitives.md`.
- `concave` mode introduces a SECOND physics path — Yume's
  swept-AABB integrator queries Godot's PhysicsServer3D for
  static-mesh entities. Hybrid physics. Cleanly contained: only
  the motion integrator needs to know. Other engine systems
  (rules, queries, scheduler) see entities as their AABB list
  regardless of how it was derived.
- Auto-decomp at load time adds a per-entity load cost
  (~1-10ms per `.glb` depending on triangle count). Negligible
  for typical Yume scenes (<100 obstacles per level); track if
  it ever shows up in profiling.
- LLM-driven QA loop becomes slightly more nuanced:
  yume-qa-tester needs to detect "player can't enter expected
  space" cases and recommend either a different asset or a
  `collision_mode` flip. Currently the tester's vocabulary is
  cascade-shaped (rules fire / don't fire); spatial QA is a
  small extension. Not engine work — content of the QA scenarios.

**Updates needed:**
- `docs/guideline/30_framework_primitives.md` — document `aabb_volumes`,
  `visual.glb`, `collision_mode` alongside `blocks_motion`.
- `docs/engine-reference/api-manifest.json` — auto-regen after
  engine work to surface the new fields in the canonical
  vocabulary list.
- `godot/scripts/engine/motion_integrator.gd`
  (or wherever the swept-AABB check lives) — iterate over
  `aabb_volumes`, fall through to `aabb_extents` for legacy.
- New module: `godot/scripts/engine/glb_collision.gd`
  — at level-load, walk new entities, derive collision from
  `visual.glb` per `collision_mode`, populate runtime
  `aabb_volumes`. Hooks into `World._load_entities_path`.
- `.claude/rules/data-demo.md` — append the new schema fields
  to the "DO" list with examples.
- `.claude/skills/yume-asset-designer/SKILL.md` — add
  `.glb`-aware decision branch (when to recommend a code-drawn
  composite vs an AI-gen `.glb` vs both).
- `.claude/skills/yume-content-designer/SKILL.md` — add
  `aabb_volumes` to the schema doc; default `collision_mode` is
  not authored (let engine decide).
- `godot/scripts/engine/tests/test_runner.gd`
  — new test sections: `test_aabb_volumes`,
  `test_glb_auto_decomp`, `test_concave_mode`.

**Backward compatibility:**
- All existing demos continue to work. `aabb_extents` stays
  supported; the engine treats it as a single-element
  `aabb_volumes` internally.
- No content rewrites needed. Multi-AABB and `.glb` are opt-in
  per-entity.

## Alternatives considered

### A. Multi-AABB only, no `.glb`

Just add `aabb_volumes`; keep visuals capped at `meshes.json`
composites. Cleanest minimal change. Rejected because **the
visual-fidelity question doesn't go away** — the next time a
game wants better-than-Lego art, we re-open this discussion.
Better to land both at once.

### B. Adopt Godot's PhysicsServer3D for static blocks_motion

Replace Yume's swept-AABB integrator for static obstacles with
Godot's StaticBody3D + ConvexPolygonShape3D. Hybrid physics.
Rejected because:
- Yume's integrator is small (~100 lines), well-tested, and
  predictable. Replacing it loses determinism (Godot's physics
  is non-deterministic across platforms).
- The complexity buys precision Yume doesn't currently need.
  Convex hull → enclosing AABB at load time is "good enough"
  for arena-style and sim-style games (Yume's scope).
- The `concave` `collision_mode` already provides an escape
  hatch for the rare case where AABB approximation isn't enough.

### C. Allow `.tscn` references for entities

Let `visual.scene = "res://prefabs/house.tscn"`, where the
`.tscn` packages mesh + collision + child nodes. Maximum
expressiveness; matches AAA prefab pattern.

Rejected because **`.tscn` files require the Godot editor to
author**. They contain references to scripts, nodes, signals —
all things the LLM content-designer skill cannot write
correctly. Accepting `.tscn` as content reintroduces a
human-in-the-loop step. Yume's whole point is no humans in the
content authoring loop. (Note: scene-level `.tscn` files in
`scenes/` are still allowed — those configure framing
(camera, sun, sky), not gameplay-relevant geometry.)

`.glb` is fine because it's pure geometry/material data — same
class of asset as a `.png` sprite.

### D. Convex decomposition stored as JSON

Run convex decomp offline (e.g. via a Python script using V-HACD),
emit the result as `aabb_volumes` baked into the entity def.
Rejected because:
- Adds an asset-pipeline step (LLM skill or asset-gen would
  have to invoke V-HACD).
- Decoupling "make `.glb`" from "make collision data" loses
  iteration speed: if the artist tweaks the mesh, the JSON
  collision needs regen.
- Auto-deriving at load is one fewer step in the pipeline.

### E. Status quo — primitive composites only

Keep `meshes.json` as the only visual path. Force everything
into stacked-box composites; never accept external assets.

Rejected because:
- It caps Yume's reachable content at "abstract / Lego-like
  visual style." Some games want this; many don't.
- The principle isn't "no external assets"; it's "no humans in
  authoring." External `.glb` files produced by AI asset-gen
  satisfy the latter without breaking the former.
- CLAUDE.md already documents the asset abstraction layer for
  PNG sprites — `.glb` is the 3D version of the same pattern.

## Implementation phasing

If accepted, land in two phases:

**Phase 1**: `aabb_volumes` + `single_aabb` collision_mode (no GLB
loading yet). Tests pass with existing demos. ~1-2 days work.

**Phase 2**: `visual.glb` loading + `convex_decomp` + `concave`
modes. New tests for collision auto-derivation. ~3-5 days work.

Phase 2 must ship with a `test_concave_determinism` unit test that
loads a scene with `concave`-mode entities and runs 10 consecutive
100-tick simulations, verifying bit-identical entity positions
across all runs. The test gates the `concave` mode: if it cannot
be made to pass, the `concave` mode is rolled back from the merge,
leaving only `convex_decomp` and `single_aabb` as supported modes.
Per tech-director review, the determinism assumption depends on
Godot's `intersect_ray`/`intersect_shape` queries on `StaticBody3D`
being deterministic across runs (they should be — pure geometric
queries on static geometry, no rigid-body dynamics). The unit test
proves this empirically before content authors rely on it.

This staging lets the multi-AABB capability land safely first
(it's cheap and unlocks better composite authoring) before the
larger GLB integration which has more moving parts.

## Open questions for tech-director review

1. Should `aabb_volumes` accept rotated boxes (OBB) instead of just
   axis-aligned? Marginal precision gain at cost of swept-collision
   complexity. Lean: AABB-only for v1.
2. For the `concave` path — is hybrid physics (Yume integrator +
   Godot PhysicsServer query) acceptable, or does that violate the
   "Yume keeps its own physics" principle? Lean: acceptable; the
   Godot query is read-only and the result is consumed by Yume's
   integrator, so determinism stays Yume-side.
3. Do we surface the new fields via the api-manifest auto-gen, or
   do they need explicit doc entries? Lean: both — auto-gen
   surfaces the field names, manual docs explain semantics.
4. ~~Should `meshes.json` composites get a deprecation timeline?~~
   **No** — composites stay first-class permanently. They are the
   code-drawn fallback layer that makes Yume work without external
   dependencies (per CLAUDE.md's asset abstraction principle). They
   are zero-asset-cost (pure JSON), LLM-skill-authorable end-to-end
   without an asset-gen API call, deterministic across regenerations,
   and serve a distinct abstract/low-poly aesthetic that some games
   want. `.glb` is the optional ceiling; `meshes.json` is the floor.
   Both coexist as peer visual paths, not legacy + replacement.

---

## Tech-director review

_Date: 2026-05-04_
_Reviewer: yume-tech-director_
_Verdict: **accepted with conditions**_

### Invariant checks

Ran all four invariant greps on the current engine state. All pass
cleanly:

| Invariant | Grep | Result |
|---|---|---|
| #1 (no hardcoded entity ids) | `\bentities\.get\("[^"]+"\)` | clean |
| #2 (no semantic effect types) | `damage\|need_decay\|gain_xp\|...` | clean |
| #3 (no entity subclasses) | `extends Entity\|class_name (Agent\|...)` | clean |
| #5 (queries are first-class) | shortcut tag-walks | clean |

The proposed additions DO NOT introduce any new violations. Specifically:

- `aabb_volumes` is a **property field expansion** — uses existing
  Entity.properties dict; no new class, no new effect type, no
  hardcoded ID. Same shape as `aabb_extents` from ADR 0004. ✓
- `visual.glb` slots into the existing renderer-specific-visual
  pattern (precedent: `visual.sprite_2d` for 2D, `visual.mesh` for
  3D — both renderer-specific, both consistent with ADR 0002's
  renderer-agnostic-Entity invariant since the Entity class doesn't
  change). ✓
- `collision_mode` is a property string — same shape as any other
  property field. No engine-side coupling beyond the AABB-derivation
  branch in the new `glb_collision.gd` module. ✓
- The `concave` mode's hybrid physics is contained — only the motion
  integrator's static-blocker check queries Godot's PhysicsServer3D,
  and only when `collision_mode: "concave"` is explicitly set. Other
  engine systems (rules, queries, scheduler) see only the resulting
  AABB list. ✓

### Specific concerns addressed

**1. Multi-AABB and primitive #3 (no entity hierarchy)**: Pass. This
is a property field expansion, not a new class. Backward compatibility
is clean — single-element `aabb_volumes` is semantically equivalent
to existing `aabb_extents + aabb_offset`.

**2. `.glb` and renderer-agnostic-Entity (ADR 0002)**: Pass. The
Entity class stays `extends Node`; `visual.glb` is parsed by the 3D
renderer, ignored by the 2D renderer (same as `visual.mesh` today).
Position/state/rules all stay renderer-agnostic. Concretely verified
by reading `entity_mesh_3d.gd` (handles `visual.mesh`) vs
`entity_sprite_2d.gd` (handles `visual.sprite_2d`) — these renderers
already select per-renderer fields without touching Entity itself.

**Required clarification for ADR**: an entity with ONLY `visual.glb`
and no 2D fallback (`sprite_2d`/`shape`/`color`) will render as
nothing in a 2D scene. This matches existing behavior for
`visual.mesh`-only entities and is acceptable, but the ADR should
state explicitly. **REVISION REQUEST 1** (see below).

**3. Hybrid physics for `concave` mode**: Conditional pass. The
ADR's lean ("acceptable, determinism stays Yume-side") is correct
**for static geometry**: `intersect_ray` and `intersect_shape` on
Godot StaticBody3D are pure geometric queries, deterministic across
runs given identical input. No rigid-body dynamics are involved —
those would be non-deterministic and would fail this gate.

The bounded determinism assumption depends on:
- Entities with `concave` collision being TRULY static (no motion,
  no transform updates per tick after load)
- Yume's integrator not relying on cross-platform physics behavior
  beyond the geometric query result

**REVISION REQUEST 2**: Phase 2 must include a determinism unit test
that loads a scene with `concave`-mode entities and verifies bit-
identical motion-integrator output across multiple consecutive runs.
If this test fails, the `concave` mode is rolled back; only
`convex_decomp` and `single_aabb` remain.

**4. External-asset-as-path consistency with PNG sprites**: Pass.
PNG sprites today use `visual.sprite_2d: "res://path.png"` — engine
loads via `ResourceLoader`, file lives in renderer-specific asset
folders (`sprites/` or `assets/`), gracefully falls back if missing.
`.glb` follows the same model — `visual.glb: "res://path.glb"`,
loaded via `ResourceLoader`, lives in `meshes/`, falls back to
`visual.mesh` (composite) or `visual.shape` (renderer fallback).
Pattern is consistent.

### Open questions resolutions

| # | Question | Lean | Tech-director resolution |
|---|---|---|---|
| 1 | OBB vs AABB? | AABB-only v1 | **Accepted.** OBB requires SAT collision math, ~3× the complexity for marginal precision gain. Defer to v2 if real content demands it. |
| 2 | Hybrid physics OK? | Acceptable | **Accepted with revision request 2** above (determinism test required). |
| 3 | api-manifest auto-gen vs manual docs? | Both | **Accepted.** Auto-gen surfaces field names + types; manual docs in `30_framework_primitives.md` cover semantics (what `convex_decomp` actually does, when to use `concave`, etc.). |
| 4 | meshes.json deprecation? | No, peer paths | **Accepted.** Already resolved. Composites stay first-class permanently. |

### Conditions for acceptance

Two non-blocking revision requests + three implementation gates:

**Revision requests (apply to ADR text before phase 1 starts):**

1. **Add 2D-renderer fallback note**: clarify what happens when an
   entity has ONLY `visual.glb` and is loaded in a 2D scene. Likely:
   ignored by `entity_sprite_2d.gd`, falls through to `visual.shape`
   or default circle (same as `visual.mesh`-only entities today).
   One sentence in the Decision section.

2. **Determinism test commitment for `concave` mode**: add a
   sentence to Phase 2's scope stating "phase 2 must ship with a
   `test_concave_determinism` unit test that loads a scene with
   concave-mode entities and runs 10 consecutive 100-tick simulations,
   verifying bit-identical entity positions across all runs. If this
   test cannot be made to pass, the `concave` mode is rolled back."

**Implementation gates (verify post-merge):**

1. **All four invariant greps pass post-implementation.** Same greps
   I ran here. Re-run after phase 1 lands and after phase 2 lands.
2. **Existing `test_main.tscn` continues to pass.** No regressions
   on the 230+ unit tests already in the suite.
3. **Existing demos all still work.** doomarena3d v3.0 + tinypond
   + harvestcore + multilevel must load and tick cleanly with the
   new code (their entity defs use the legacy `aabb_extents` path
   which must remain supported).

### Ordering note

Phase 1 (multi-AABB only) can proceed as soon as revision request 1
is applied. Phase 2 (`.glb` loading + auto-decomp) requires both
revision requests applied AND phase 1 merged + verified.

The ADR is otherwise sound. The visual-fidelity gap it addresses is
real, the proposed solution is consistent with existing patterns
(asset abstraction layer for `.png`, renderer-specific visual fields
for `mesh`/`sprite_2d`), and the design correctly preserves the
no-humans-in-content invariant while opening a path for
visually-richer games.

**Approved to merge phase 1 once revision request 1 is applied.**
**Phase 2 gated on revision request 2 + phase 1 verified.**
