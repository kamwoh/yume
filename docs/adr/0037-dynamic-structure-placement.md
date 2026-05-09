# ADR 0037 — Dynamic structure placement (`build_place` effect)

_Date: 2026-05-09_
_Status: proposed_

## Context

Aldenmere Phase 1 ("Survival") is a player + NPC build loop. Within
the first 30 in-game days the village constructs ~4 named structure
classes — lean-to (sleep shelter), mud hut (winter shelter), fire pit
(warmth radius), fish trap (food source) — and the GDD calls for these
to be PLACED dynamically by either the player (via build menu + cursor)
or by NPCs running schedule rules. Phases 2-4 scale this dramatically:
mud-brick houses, walls, granaries, smithies (Phase 2); cities of
~10 villages × ~20 buildings each (Phase 3); kingdom-scale construction
(Phase 4). NPCs are expected to construct continuously — every Phase 4
NPC eventually builds something.

Current engine vocabulary doesn't support this. The `spawn` effect
(per `effect_apply.gd::_spawn`) creates an entity from a def template
and inserts it into the spatial index AT WHATEVER POSITION the rule
supplies — with no validation. Concretely:

1. **No overlap check.** A rule can `spawn template="mud_hut"
   position=[10, 0, 10]` even when the position is already occupied
   by a wall, tree, or another villager's mud hut. The new entity's
   `aabb_volumes` (per ADR 0007) immediately overlap an existing
   blocker. The motion integrator (per ADR 0004) cannot resolve a
   moving entity that STARTS embedded in a blocker — it slides on
   each axis attempt and stays put. Result: 穿模 (clipping) — the
   player or NPC walks INSIDE the new building because they were
   standing where it spawned.
2. **No buildable-ground check.** A rule can spawn a structure on
   water, on a cliff edge, on the underside of a hill, or off the
   level boundary. There's no terrain-aware placement gate.
3. **No range check.** A rule can spawn a structure 100 m from its
   builder — there's no "the builder must be next to the build site"
   constraint.
4. **No preview UI.** During cursor-driven placement the player has
   no ghost mesh, no validation feedback, no rotation control. The
   merchant game's player-driven shop currently spawns entities
   directly from button clicks with no preview — acceptable for
   a fixed shop interior, untenable for an open-world build loop.
5. **No multi-tick construction.** A mud hut should not appear
   instantly — it takes a half-day of villager-time to build. Today
   the only path is "spawn the finished entity," which strips the
   simulation layer (the construction site itself is content the
   game wants to render — half-built walls, carrying logs, etc).

The bug class is fundamentally collision-shaped: ANY content that
reaches `spawn` with a colliding position produces a 穿模 trap. As
Aldenmere scales from 8 NPCs (Phase 1) to 500 NPCs (Phase 4), the
expected per-day spawn count grows from ~1-2 to ~50+. Without
engine-side validation, every author-written or AI-derived build
rule is one buggy formula away from shipping a stuck-NPC bug.

This is a **primitive expansion**, not a content patch — same
reasoning as ADR 0004 (`blocks_motion`): every game with dynamic
construction would re-implement the same overlap sweep, and the
collision check belongs alongside the spawn integrator (not in a
content rule that fires AFTER the entity already exists in the
spatial index). The merchant game's existing static buildings
(cottages, walls in `demo_merchant/levels/`) work because they're
hand-placed at level-design time and ALL conflicts are caught by
the level-designer skill. Once placement moves to runtime, the
gate must move into the engine.

Per ADR 0021 (Yume = JSON layer over Godot), the engine should
EXPOSE collision-aware placement, not reimplement Godot's physics.
But the existing `blocks_motion` substrate (ADR 0004 / 0007) is
already custom AABB math — `build_place` validation queries the
SAME spatial_index that the motion integrator uses, reusing the
existing collision substrate without introducing a second physics
path. When ADR 0022 (Godot collision migration) eventually lands,
`build_place` migrates with `blocks_motion` — single migration
boundary.

## Decision

Introduce a new effect type `build_place` and four named validation
predicates that compose declaratively. The engine validates BEFORE
spawning; if any predicate fails, the entity is NOT spawned and the
`on_invalid` effect chain runs. If all pass, the entity spawns and
the `on_success` chain runs (typically just `[]` since spawn-trigger
rules already fire). Construction can be instant (default) or
multi-tick (via `construction_ticks`). A separate preview-rendering
mode lets cursor-driven UIs show a ghost mesh that updates per
frame as the cursor moves.

### Effect shape

```jsonc
{
  "type": "build_place",
  "blueprint": "prop_lean_to",                // entity def to spawn (string OR formula)
  "position": "self.state.target_position",   // where (formula resolving to Vector3 or [x,y,z])
  "yaw": "self.state.target_yaw",             // optional rotation (radians); defaults 0
  "validate": ["no_overlap", "ground_buildable", "owner_in_range"],
  "owner": "self",                            // context binding for owner_in_range; defaults "self"
  "max_range": 4.0,                           // for owner_in_range predicate (meters); defaults 3.0
  "construction_ticks": 0,                    // 0 = instant (default); >0 = multi-tick
  "on_success": [...effect chain...],         // optional, runs after successful spawn
  "on_invalid": [...effect chain...]          // optional, runs if any predicate fails
}
```

### Validation predicates (FIXED SET — engine vocabulary)

Predicates are **engine-coded primitives**, not JSON-registered
plugins. This is deliberate per ADR 0021 / ADR 0028's "operator
surface boundary" reasoning: predicates are vocabulary; loops +
late-binding belong in rules + Formula, not in a load-time
predicate registry. Adding a fifth predicate requires another ADR.

| Predicate | Pass condition |
|---|---|
| `no_overlap` | The blueprint's `aabb_volumes` (or `aabb_extents`) at `position`+`yaw` do not intersect any existing entity tagged `blocks_motion`. Yaw rotates the AABB list before sweep. |
| `ground_buildable` | The position has an entity tagged `ground_buildable` within `ground_check_radius` (default 0.5 m, configurable). Negative/positive Y tolerance configurable via `ground_y_tolerance` (default 0.5 m). Caller must place ground tiles tagged `ground_buildable` for this to pass. |
| `owner_in_range` | The `owner` binding's planar position is within `max_range` of `position`. If `owner` resolves to nothing, the predicate fails. |
| `boundary_check` | Position is within the level's bounds (per `scene.json:bounds`). |

The list is **the complete v1 set**. Future ADR 0040+ may extend it
(e.g. `requires_resource` for material-cost gating, `path_clear` for
"don't block existing pathfinding lanes") — each addition is a
primitive expansion ADR, same gate as adding a new effect type.

### Resolution flow (engine-side, in `effect_apply.gd::_build_place`)

```
1. Resolve blueprint (string or formula → def lookup)
2. Resolve position (formula → Vector3)
3. Resolve yaw (formula → float; default 0)
4. For each predicate in validate[]:
     if predicate fails:
       fire on_invalid chain (if any)
       return {placed: false, reason: predicate_name}
5. Spawn entity (delegate to existing _spawn path; same lifecycle)
6. Apply yaw to spawned entity (state.yaw = yaw)
7. If construction_ticks > 0:
     set state.build_in_progress = construction_ticks
     add tag "under_construction"
     (existing tick rules drive completion via state_add)
   Else:
     entity is complete; finished tag applied
8. Fire on_success chain
9. Return {placed: true, instance_id: <new_id>}
```

### Multi-tick construction

When `construction_ticks > 0`, the spawned entity gets:
- Tag `under_construction` (queries can find half-built sites)
- State `build_in_progress: <N>` (decrements via tick rule the
  game authors)
- State `build_progress_target: <N>` (initial value, for UI)

The game's content authors write a tick rule to decrement
`build_in_progress` and a finalization rule that fires when it
hits zero (typically: remove `under_construction` tag, add
`finished` tag, fire `construction_complete` signal). The engine
provides the schema; the game owns the pacing. This stays
consistent with Invariant #2 (no semantic effect types) — there
is no `complete_construction` effect; it's `tag_remove` +
`tag_add` + `emit`.

### Preview mode (cursor-driven UI)

Player-driven build flows need a ghost mesh that follows the
cursor and changes color based on validation. This is rendering,
not effect-time. Add a sibling system: a `build_preview` widget
configured per-actor in `scene.json`:

```jsonc
{
  "build_preview": {
    "enabled": true,
    "actor_state_field": "build_blueprint",  // when non-empty, show preview
    "position_field": "build_target_position",
    "yaw_field": "build_target_yaw",
    "validate": ["no_overlap", "ground_buildable", "owner_in_range"],
    "valid_color": "#80ff80",
    "invalid_color": "#ff8080"
  }
}
```

When `actor.state[actor_state_field]` is non-empty, a transparent
ghost-instance of the blueprint def is rendered at the named
position/yaw fields. Per frame, the engine re-runs the same
validation predicates and tints the ghost (multiplied modulate)
green/red. Player input rules write to the state fields (cursor
drives `build_target_position`; mousewheel rotates `build_target_yaw`;
B-key sets `build_blueprint`; confirm fires the `build_place` effect;
cancel clears `build_blueprint`).

The preview widget is engine code (per ADR 0021's "expose Godot
nodes as JSON-declared widgets" pattern, like nameplate_renderer
and minimap_widget). NPCs running schedule-driven build rules
don't use preview — they fire `build_place` directly with the
position they decided.

### State-field convention (content discipline)

For consistency across games, recommended state fields on a
build-capable actor:

| Field | Purpose |
|---|---|
| `build_blueprint` | Currently selected blueprint id ("" = no build mode) |
| `build_target_position` | Cursor-resolved Vector3 (player) OR AI-decided spot (NPC) |
| `build_target_yaw` | Rotation in radians |
| `build_in_progress_id` | Instance id of the under-construction entity (if multi-tick) |

Recommended; not engine-enforced. Authors picking different field
names for game-specific reasons just supply them in the
`build_preview` config and rule effect formulas.

### Cancel / refund semantics

`build_place` doesn't itself debit resources or refund — those are
content rules. Standard pattern:

```jsonc
// Player builds: debit logs THEN call build_place.
// If build_place fails, on_invalid refunds the logs.
{
  "id": "player_build_lean_to",
  "trigger": {"type": "input", "action": "build_confirm"},
  "query": {"tags_all": ["player"], "state": {"build_blueprint_eq": "prop_lean_to"}},
  "effect": [
    {"type": "state_add", "target": "self", "field": "logs", "amount": -3},
    {"type": "build_place",
     "blueprint": "self.state.build_blueprint",
     "position": "self.state.build_target_position",
     "yaw": "self.state.build_target_yaw",
     "validate": ["no_overlap", "ground_buildable", "owner_in_range"],
     "on_invalid": [
       {"type": "state_add", "target": "self", "field": "logs", "amount": 3},
       {"type": "show_toast", "text": "Cannot build here"}
     ],
     "on_success": [
       {"type": "state_set", "target": "self", "field": "build_blueprint", "value": ""}
     ]}
  ]
}
```

The on_invalid chain is the refund site. Authors who want
"validate first, debit second" can compose: a check rule that
sets `state.build_valid` based on predicate evaluation (via a
separate query-only path — future extension), and a separate
input rule that gates on `build_valid`. v1 ships with the simpler
debit-then-attempt-with-refund pattern.

### Engine module placement

Implementation lives in `effect_apply.gd::_build_place` (sibling
to `_spawn`). Predicates are static functions in a new
`build_validators.gd` module:

```
godot/scripts/engine/
├── effect_apply.gd          # adds _build_place dispatch entry
├── build_validators.gd      # NEW: 4 predicate functions
└── build_preview_widget.gd  # NEW: per-actor ghost-mesh renderer
```

api-manifest.json regenerates to expose the new effect + the
`build_preview` scene.json block + the four predicate names.

## Consequences

### Positive

- **Phase 1 ships without 穿模.** Player builds + NPC schedule
  builds are collision-clean from day 1. The bug class — "build
  rule produced an entity overlapping a blocker, motion integrator
  can't resolve" — is gated at the engine.
- **Phases 2-4 scale safely.** Whatever AI build behavior the
  schedule primitive (ADR 0029) produces, all build attempts go
  through the same validator. NPCs deciding via formula or LLM
  policy can't ship a 穿模.
- **Reuses existing collision substrate.** Same `aabb_volumes`,
  same spatial_index, same yaw convention as ADR 0004 / 0007.
  No new physics path.
- **Compositional.** Authors choose which predicates to apply;
  a "magical" build effect could skip `ground_buildable`; a
  "godmode" build effect could skip `owner_in_range`. The fixed
  predicate set + JSON composition keeps Invariant #8 clean.
- **Multi-tick path is content-driven.** Engine provides schema;
  pacing/animation/material-cost are JSON.
- **Preview widget is one engine module.** Like nameplate_renderer
  and minimap_widget, ghost-mesh rendering joins the JSON-declared-
  Godot-widget family per ADR 0021.

### Negative

- **New effect type.** Vocabulary surface grows by one entry.
  Documented in api-manifest + `30_framework_primitives.md`.
- **Four new predicate names.** Predicate vocabulary is now 4
  entries; future ADRs extend by ADR-gated additions (same as
  effect vocabulary).
- **Ghost-mesh rendering is a NEW renderer-primitive.** Per
  `.claude/rules/engine-scripts.md` § visual gate, the preview
  widget requires a `--capture` + `yume-visual-designer` review
  before merging. Risk: ghost-mesh tinting may interact with
  existing materials in ways that look wrong (e.g. PBR materials
  ignoring modulate). Mitigation: the ghost-mesh uses a dedicated
  ShaderMaterial that respects the valid/invalid color tint
  regardless of the source material; visual gate verifies.
- **Predicate evaluation per-frame for preview.** ~constant time
  per query (spatial_index is grid-bucketed) but multiple builders
  in Phase 4 mean multiple ghost meshes. Budget below.
- **Multi-tick state pollution.** `under_construction` tag +
  `build_in_progress` state add 2 fields per spawned-and-still-
  building entity. Acceptable.

### Neutral

- **Existing demos unchanged.** No demo currently uses `build_place`.
  All current demos place entities at level-design time via
  `initial_instances`, which doesn't go through this code path.
  Zero migration.
- **Backward-compat with `spawn`.** Authors who want raw, unvalidated
  spawn (e.g. fireball projectiles, dropped items) keep using
  `spawn`. `build_place` is the OPT-IN gate for placement that
  cares about collision/range/ground.

## Alternatives considered

### A) Keep using `spawn` and trust authors to validate

Authors write a tick rule that `query`s overlap candidates before
spawning. Rejected for two reasons:

1. **Validation logic isn't expressible in JSON queries.** AABB-
   intersection requires axis-extent math against rotation; queries
   only support tag/state/radius/relation filters. Authors would
   need a separate Formula expression per axis per blueprint —
   in practice, every game would need its own engine helper.
2. **Bug class manifest.** The merchant project has no `spawn`-at-
   runtime validation today (cottages are static). The bug shows
   up the FIRST time a game places dynamically, which is exactly
   Phase 1. By that point ~30 build rules across player + NPC paths
   exist, each a chance to ship the bug. Centralization is the
   right level.

### B) Use Godot's PhysicsServer3D for collision validation

Spawn the entity, immediately query Godot for overlaps, despawn
if invalid. Rejected because:

1. **Two-physics path.** Yume's swept-AABB integrator (ADR 0004)
   is the canonical path for entity-vs-entity blocking. Adding a
   second path (Godot collision queries) for placement only opens
   the door to disagreement: "Godot says no overlap, integrator
   says overlap" is a debugging nightmare.
2. **Spawn-then-despawn is wrong lifecycle order.** The engine
   would briefly create + destroy entity nodes per failed
   placement attempt. Spawn-trigger rules would fire even on
   failures. The validation gate must run BEFORE spawn, not
   after.
3. **ADR 0007 already commits to AABB approximation.** When
   ADR 0022 (Godot collision migration) lands, both ADR 0004 +
   ADR 0007 + this ADR migrate together. Single boundary.

### C) Separate `place_blueprint` + `complete_construction` effects

Two effects: `place_blueprint` writes the validation result + the
ghost entity; `complete_construction` finalizes it after multi-tick
delay. Cleaner separation of concerns; adds vocabulary. Rejected
because:

- Validation logic still needs centralization — same problem as
  Option A.
- The construction-completion is already JSON-expressible via
  `tag_add` + `tag_remove` + `state_set` + `emit` (Invariant #2
  forbids semantic effect names anyway).
- One effect with composable predicates is simpler.

### D) Predicates as JSON-registered plugins (resolver-style)

Make predicates extensible via `data/lib/build_validators/<name>.json`,
each declaring a query shape + a pass condition formula. Rejected
because:

- Per ADR 0021 / ADR 0028's operator-surface reasoning,
  vocabulary belongs in engine code. Plugin-style predicates
  recreate Turing-completeness pressure at the validator layer
  (which is exactly what `Formula` already does for fire-time
  checks; predicates are LOAD-TIME placement gates and want a
  different scope).
- Authors needing custom validation can compose existing
  predicates + write a tick-rule precondition that sets a
  `build_valid` state field, then gate `build_place` on it.

### E) Multi-AABB rotation via SAT (full Separating-Axis-Test)

For yaw≠0 placements, ADR 0007's AABB volumes become OBBs (oriented
bounding boxes). Full SAT collision is the precise check.
Rejected for v1: per ADR 0007's open question #1, OBB collision
adds ~3× the complexity for marginal precision. v1 axis-aligns the
yaw-rotated AABB list (uses the rotated-AABB enclosing box —
slightly conservative; rare false-fail at oblique yaws). Future
ADR migrates to SAT if content demands.

## References

- ADR 0001 — seven primitives + interpreter (effect = primitive
  expansion path)
- ADR 0004 — `blocks_motion` tag + `aabb_extents` (collision substrate)
- ADR 0007 — `aabb_volumes` + `.glb` collision (multi-volume support
  used by ADR 0037's overlap predicate)
- ADR 0011 — declarative screen flow (the build-menu screen will
  use this; outside ADR 0037 scope)
- ADR 0021 — Yume = JSON layer over Godot (predicates as engine
  vocabulary, not registered plugins; preview widget composes Godot
  rendering)
- ADR 0028 — `$params` operator-surface cap (same reasoning for
  predicate set: 4 is the v1 surface; future additions are
  ADR-gated)
- `godot/scripts/engine/effect_apply.gd::_spawn` — existing spawn
  path; `_build_place` shares its lifecycle (renderer attach,
  spatial-index update, spawn-trigger dispatch)
- `godot/scripts/engine/spatial_index.gd::query_radius` — existing
  spatial query the no_overlap predicate calls
- `godot/scripts/engine/nameplate_renderer.gd` /
  `minimap_widget.gd` — pattern for the new
  `build_preview_widget.gd`
- `docs/games/aldenmere/world.md` + `phase1_GDD.md` — the
  motivating use case
- `docs/games/aldenmere/engine_roadmap.md` — sequencing context
  (this is Phase 1 BLOCKING)

## Test plan

Twelve unit-test sections in `test_runner.gd`. Every test must
verify the 穿模 prevention contract: after the test, no entity is
embedded in a blocker.

| Test | Verifies |
|---|---|
| `build_place.test_valid_placement` | Empty area + all predicates pass → entity spawns with correct def, position, yaw. Spatial-index has the new entity. on_success chain fired. on_invalid did NOT fire. |
| `build_place.test_overlap_rejected` | Pre-place a wall at (10,0,10). Attempt build at (10,0,10). Predicate `no_overlap` fails → no entity spawned, spatial-index unchanged, on_invalid chain fired with reason="no_overlap". |
| `build_place.test_overlap_clearance` | Pre-place wall AABB-extents [1,1,1] at (10,0,10). Attempt build with extents [1,1,1] at (12.5,0,10). Distance > sum of half-extents → predicate passes. Build succeeds. |
| `build_place.test_yaw_rotates_aabb` | Pre-place wall at (10,0,10) with extents [3,1,1]. Attempt build of identical-shape blueprint at (10,0,15) with yaw=π/2 (rotated 90°). Without yaw it'd fit (Z gap=5, Z-extent sum=2); with yaw the rotated AABB sweeps to extents [1,1,3] and fits even better. Should succeed; verify rotated-AABB math. Then attempt with yaw=0 + position (10,0,11.5) → fails (AABBs touch in Z). |
| `build_place.test_ground_buildable` | Pre-place ground tile tagged `ground_buildable` at (10,0,10). Build at (10,0,10) → passes. Build at (50,0,50) where no ground exists → predicate fails, on_invalid fires with reason="ground_buildable". |
| `build_place.test_owner_in_range` | Owner at (0,0,0) with max_range=4. Build at (3,0,0) → passes. Build at (5,0,0) → fails with reason="owner_in_range". Build with owner=null binding → fails. |
| `build_place.test_boundary_check` | scene.bounds = [-50, 50] on each axis. Build at (49,0,49) → passes. Build at (60,0,49) → fails with reason="boundary_check". |
| `build_place.test_multi_predicate_compose` | All 4 predicates active. Setup so 3 pass + `owner_in_range` fails. Verify on_invalid fires with reason naming the failing predicate, no entity spawned. (Predicates evaluate left-to-right; first failure short-circuits.) |
| `build_place.test_construction_ticks` | construction_ticks=10. Build → entity spawned WITH tag `under_construction` and state.build_in_progress=10. Tick 5 times via game-content rule that decrements → state.build_in_progress=5, tag still present. Tick 5 more times → game's finalization rule removes tag, fires emit "construction_complete". |
| `build_place.test_motion_integrator_no_clipping` | After valid build_place, position a moving NPC adjacent to the new structure with velocity pointing INTO it. Tick. NPC stops at AABB face — does NOT clip. (穿模 contract.) Repeat with the position the build was REJECTED at — verify NPC is still where it was, not embedded. |
| `build_place.test_preview_validation_does_not_spawn` | Preview widget queries predicates per-frame. Verify no entity is created during preview ticks; only tint-color changes based on validation result. Move cursor over a blocker → tint switches to invalid_color; over empty + ground → tint to valid_color. |
| `build_place.test_no_def_error` | blueprint="nonexistent" → structured EngineError EFFECT_BUILD_PLACE_NO_DEF (mirrors EFFECT_SPAWN_NO_DEF), no on_success or on_invalid chain runs. |

Cross-cutting assertion (run after every test): grep for any
entity whose AABB intersects another `blocks_motion` entity's AABB.
Result must be empty. This is the 穿模 sentinel.

## Implementation sketch

Pseudocode for the core dispatch + predicates (~80 lines):

```gdscript
# effect_apply.gd — new dispatch arm
"build_place":           return _build_place(effect, env, context)

static func _build_place(e: Dictionary, env: Dictionary, ctx: Dictionary) -> Dictionary:
    var defs: Dictionary = env.get("defs", {})
    var blueprint := str(_value(e.get("blueprint", ""), env, ctx))
    if not defs.has(blueprint):
        EngineError.raise(env, EngineError.EFFECT_BUILD_PLACE_NO_DEF,
            "build_place: no def '%s'" % blueprint,
            {"rule_id": ctx.get("_rule_id", ""), "field": "effect.blueprint",
             "got": blueprint, "known_defs": defs.keys()},
            "Add a definition with id '%s' to entities.json." % blueprint)
        return {"placed": false, "reason": "no_def"}

    var pos: Vector3 = _resolve_v3(_position(e.get("position", [0,0,0]), env, ctx))
    var yaw := float(_value(e.get("yaw", 0.0), env, ctx))
    var owner_binding := str(e.get("owner", "self"))
    var max_range := float(e.get("max_range", 3.0))
    var validate: Array = e.get("validate", [])

    # Run predicates left-to-right; first fail short-circuits.
    for pname in validate:
        var ok := BuildValidators.check(pname, defs[blueprint], pos, yaw,
                                        owner_binding, max_range, env, ctx)
        if not ok:
            _apply_chain(e.get("on_invalid", []), env, ctx)
            return {"placed": false, "reason": pname}

    # Validation passed → delegate to existing spawn path with overrides.
    var overrides := {"position": pos, "state": {"yaw": yaw}}
    if int(e.get("construction_ticks", 0)) > 0:
        var ticks := int(e["construction_ticks"])
        overrides["state"]["build_in_progress"] = ticks
        overrides["state"]["build_progress_target"] = ticks
        overrides["_extra_tags"] = ["under_construction"]
    var spawn_result := _spawn({"type": "spawn", "template": blueprint,
                                 "overrides": overrides}, env, ctx)
    var inst_id: String = spawn_result.get("spawned_id", "")

    _apply_chain(e.get("on_success", []), env, ctx)
    return {"placed": true, "instance_id": inst_id}


# build_validators.gd — predicate dispatch
class_name BuildValidators

static func check(name: String, def: Dictionary, pos: Vector3, yaw: float,
                  owner: String, max_range: float,
                  env: Dictionary, ctx: Dictionary) -> bool:
    match name:
        "no_overlap":        return _no_overlap(def, pos, yaw, env)
        "ground_buildable":  return _ground_buildable(pos, env)
        "owner_in_range":    return _owner_in_range(owner, pos, max_range, env, ctx)
        "boundary_check":    return _boundary_check(pos, env)
        _:
            push_warning("build_place: unknown predicate '%s'" % name)
            return false

static func _no_overlap(def: Dictionary, pos: Vector3, yaw: float, env: Dictionary) -> bool:
    # Resolve def's aabb_volumes (or aabb_extents fallback per ADR 0004 / 0007).
    var volumes := _resolve_volumes(def)
    # Rotate each volume's offset around Y by yaw; rotate extents to enclosing-AABB
    # of the yaw-rotated box (v1 conservative axis-aligned approximation; SAT
    # is future ADR per Alternative E).
    var max_radius := _enclosing_radius(volumes)
    var sx = env.get("spatial_index", null)
    var entities: Dictionary = env.get("entities", {})
    if sx == null: return true
    var planar := Vector2(pos.x, pos.z)
    var candidates: Array = sx.query_radius_ids(planar, max_radius + 4.0)
    for cid in candidates:
        var ent = entities.get(cid, null)
        if ent == null or not ent.has_tag("blocks_motion"): continue
        if _aabb_pair_overlaps(volumes, pos, yaw, ent): return false
    return true

static func _ground_buildable(pos: Vector3, env: Dictionary) -> bool:
    var sx = env.get("spatial_index", null)
    var entities: Dictionary = env.get("entities", {})
    if sx == null: return false
    var ids: Array = sx.query_radius_ids(Vector2(pos.x, pos.z), 0.5)
    for cid in ids:
        var ent = entities.get(cid, null)
        if ent != null and ent.has_tag("ground_buildable"):
            var ent_y := float(ent.get_state("position", Vector3.ZERO).y)
            if abs(ent_y - pos.y) < 0.5: return true
    return false

static func _owner_in_range(owner: String, pos: Vector3, max_range: float,
                            env: Dictionary, ctx: Dictionary) -> bool:
    var owner_ent = ctx.get(owner, null)
    if owner_ent == null: return false
    var op := owner_ent.get_planar_position()
    return op.distance_to(Vector2(pos.x, pos.z)) <= max_range

static func _boundary_check(pos: Vector3, env: Dictionary) -> bool:
    var bounds: Dictionary = (env.get("scene", {}) as Dictionary).get("bounds", {})
    var minv: Array = bounds.get("min", [-INF,-INF,-INF])
    var maxv: Array = bounds.get("max", [INF,INF,INF])
    return (pos.x >= minv[0] and pos.x <= maxv[0] and
            pos.z >= minv[2] and pos.z <= maxv[2])
```

Preview widget (separate file, ~120 lines) instantiates a
MeshInstance3D with a ShaderMaterial that multiplies a tint color
over the source material; runs the same `BuildValidators.check`
loop per frame; updates position/yaw/tint based on the configured
state fields.

## Performance budget

| Operation | Cost | Frequency |
|---|---|---|
| `no_overlap` predicate | O(K) where K = blockers within (max_radius + 4m) of position. Spatial index returns K~10 typically; AABB-pair overlap is O(volumes × volumes). | Per build attempt + per preview frame |
| `ground_buildable` | O(L) where L = entities within 0.5 m of position; typically <5. | Per build attempt + per preview frame |
| `owner_in_range` | O(1) — single distance check. | Per build attempt + per preview frame |
| `boundary_check` | O(1) — 6 float comparisons. | Per build attempt + per preview frame |
| Preview ghost-mesh | One MeshInstance3D per active builder; <10 active builders peak Phase 4. Negligible vs world geometry. | Per frame |
| Multi-tick rule cost | One tick rule per under_construction entity; same cost as any tick rule. | Per tick |

Phase 4 worst case: 50 NPCs each evaluating one build attempt per
day (~1 attempt per 15 min real-time per NPC). At 60 fps × 10 active
preview attempts × 4 predicates × O(K~10) spatial queries =
~24,000 operations/sec. Well below frame-budget threshold. Standard
ADR 0017 spatial-LOD scheduling applies — distant NPCs run their
build evaluations at lower frequency.

## Migration / backwards-compat

- **Existing demos**: zero impact. None use `build_place` today.
  All current spawns go through `spawn` and stay there. Authors
  who want to migrate from `spawn` to `build_place` opt in
  per-rule.
- **`spawn` stays in vocabulary.** It's the right primitive for
  un-validated lifecycle (projectiles, particles, dropped items,
  level-design-time placement that's already validated by the
  level-designer skill). `build_place` is the runtime-validated
  variant.
- **Save/load (ADR 0010)**: under_construction entities are
  ordinary entities with an extra tag + state fields. They serialize
  + restore through the existing path. Resuming a save with a
  half-built mud hut continues at the same `build_in_progress`
  value.
- **Cross-game JSON reuse (ADR 0027 + 0028)**: `@lib.entities.<x>`
  blueprints work as build_place targets unchanged.

## Open questions for tech-director review

1. **Predicate-set cap**. Should ADR 0037 explicitly declare the
   4 v1 predicates as the COMPLETE set (mirroring ADR 0028's
   operator-surface boundary)? Lean: yes — future predicates
   need their own ADR. Add to Decision section if accepted.
2. **OBB vs axis-aligned-enclosing for yaw-rotated builds**.
   v1 ships axis-aligned-enclosing (slight false-fail at oblique
   yaws). Acceptable? Lean: yes for Phase 1 (most builds at yaw=0
   or π/2 anyway); revisit if Phase 4 content needs it.
3. **Construction tick rules — engine-provided vs game-authored?**
   v1 leaves pacing to game JSON. Should engine ship a default
   "decrement build_in_progress per tick, fire complete at zero"
   rule that games OPT INTO? Lean: yes as a pre-built macro (per
   ADR 0019 macro layer), shipped in `@lib.rules.construction_tick`.
   Out of ADR 0037 scope; mention as follow-up.
4. **Preview ghost-mesh determinism**. The preview widget runs
   per-frame predicate evaluation. Does this produce
   non-deterministic state across sessions if predicates touch
   spatial_index? Lean: no — predicates are read-only queries;
   state mutation only happens when the player confirms (a
   user-input event). Determinism preserved.
5. **`build_place` inside macros**. Can a macro (per ADR 0019)
   expand into a `build_place` effect? Lean: yes, no special
   handling needed; macros are load-time vocabulary substitution.
6. **Visual gate**. Per `.claude/rules/engine-scripts.md`, the
   ghost-mesh widget is a rendering primitive. Phase A of
   implementation must include `--capture` + `yume-visual-designer`
   review of the preview-mode UI. Confirmed required.
