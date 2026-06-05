# ADR 0044 — Physics via Godot's PhysicsServer3D

_Date: 2026-05-11_
_Status: **approved — Session A may begin** (2026-05-12). All 11 tech-director conditions resolved in the ADR text. Tick-ordering uses snapshot-sync model (60Hz physics, 10Hz sim snapshot). Freeze policy uses `PhysicsServer3D.set_active(false)`. See "Condition resolutions" section for the 9 detailed clarifications._
_Type: foundational reversal of ADR 0004; alignment with ADR 0021_

## Context

Yume's foundational architectural commitment is ADR 0021:

> "Yume engine should NOT reimplement continuous physics in
> GDScript / JSON formulas. Yume content CAN declare physics scenes
> that delegate to Godot's built-in physics engine."

In practice, ADR 0004 (`blocks_motion` tag, 3 days BEFORE ADR 0021
landed) introduced a hand-rolled axis-aligned bounding-box (AABB)
collision system in `world.gd::_integrate_motion`. It's ~150 lines
of GDScript that:

- Sweeps every velocity-bearing entity against every
  `blocks_motion`-tagged entity's AABB each tick
- Resolves overlap by separate X-axis and Z-axis attempts
  (poor-man's swept AABB)
- Ignores rotation (axis-aligned only)
- Ignores Y-axis (XZ-plane only)
- Has no concept of mass, friction, restitution, or continuous
  collision detection

When ADR 0021 was written, this was a known gap. The intended
direction was "expose PhysicsServer3D" but a migration path was
never proposed. In the ~8 days since ADR 0021, the hand-rolled
system has stayed in place and grown:

- ADR 0024 (pathfinding) reimplemented A* on a discretized grid —
  another reimplementation of a thing Godot does
  (`NavigationServer3D`)
- ADR 0038 (grid placement) layered grid snap on top of AABB
- Aldenmere's wolves use the system at radius 40m + max_speed clamp
- Sokoban uses tile-aligned AABB blocking
- Multilevel demo uses static walls

The framework is now in the awkward position where:

1. **The constitution says** delegate physics to Godot
2. **The code does** reimplement physics in GDScript
3. **Every new game** adds requirements (rotated walls, slopes,
   friction, projectile tunneling protection, mesh colliders, etc.)
   that push the hand-rolled system further toward "rebuild a worse
   Bullet/Jolt clone"

This is the classic foundation-vs-practice drift. Each delay makes
the eventual migration larger.

### What the hand-rolled system CANNOT do today

- Rotated bounding boxes (OBB)
- Convex / mesh / cylinder / capsule colliders
- Continuous collision detection (fast entities tunnel through thin walls at low tick rates)
- Mass / friction / restitution / damping
- Layers + masks (filter which entities can collide with which)
- Slopes / stairs / step-up logic
- Joints (hinges, springs, sliders)
- Area sensors (auto-detect overlap)
- Y-axis collision (floor is implicit at y=0; entities can't have meaningful elevation)
- Soft bodies / ropes / fluids
- Pathfinding mesh (ADR 0024's grid A* is a partial reimplementation; NavigationServer3D + NavMesh is the canonical replacement)

### What Godot's PhysicsServer3D provides for free

- All of the above, in tested C++ code
- Spatial-hash broadphase faster than `scripts/engine/stores/spatial_index.gd`
- Built-in Jolt option in Godot 4.x — single-thread deterministic, faster than Bullet
- Editor tooling (CollisionShape3D gizmos, RigidBody3D inspector)
- Documentation + community + decades of Bullet/Jolt accumulated experience

## Decision

**Migrate Yume to delegate all physics to Godot's PhysicsServer3D
via JSON-declared collision shapes and body types.** Hand-rolled
AABB collision, motion integrator, and SpatialIndex radius queries
become thin wrappers over PhysicsServer3D API. ADR 0004 is
superseded.

### JSON schema (per-entity physics declaration)

Entity defs gain a `physics` block:

```jsonc
{
  "id": "wolf_3d",
  "tags": ["animal", "predator"],
  "properties": { "...": "..." },
  "state_init": { "...": "..." },
  "physics": {
    "body_type": "kinematic",
    "collision_shape": {"type": "capsule", "radius": 0.4, "height": 1.2},
    "collision_layer": ["animal"],
    "collision_mask":  ["wall", "player", "animal"],
    "mass": 30.0,
    "friction": 0.5,
    "restitution": 0.0,
    "linear_damp": 1.0
  }
}
```

| Field | Meaning | Maps to Godot |
|---|---|---|
| `body_type` | `static` / `kinematic` / `rigid` / `area` | StaticBody3D / CharacterBody3D / RigidBody3D / Area3D |
| `collision_shape.type` | `box` / `sphere` / `capsule` / `cylinder` / `convex` / `mesh` | BoxShape3D / SphereShape3D / etc. |
| `collision_shape.size` / `radius` / `height` / `points` | shape-specific dims | resource fields on Shape3D subclass |
| `collision_layer` | array of layer names | resolved via per-game layer-name table to Godot layer bits |
| `collision_mask` | array of layer names this body interacts with | resolved same way |
| `mass`, `friction`, `restitution`, `linear_damp`, `angular_damp`, `gravity_scale` | physics material properties | Standard PhysicsMaterial + body fields |

The layer-name table lives at `data/lib/physics_layers.json` (per
ADR 0027 lib pattern) so games can declare named layers (`player`,
`wall`, `enemy`, `projectile`, ...) without managing bit masks.

### Body-type semantics

| `body_type` | Behavior | Use case |
|---|---|---|
| `static` | Doesn't move; pushes others | Walls, floors, immovable obstacles. Replaces `blocks_motion` tag. |
| `kinematic` | Moved by code (`velocity_set` effect), not by physics | Player, NPCs (engine controls their motion, but they collide). |
| `rigid` | Moved by physics (gravity, forces, impulses) | Projectiles, falling debris, dynamic objects. |
| `area` | No collision response; just overlap detection | Trigger zones (campfire warmth aura, damage zones, sensors). |

### Effects → PhysicsServer3D routing

Existing effect types route to physics-server calls:

| Current effect | New routing |
|---|---|
| `velocity_set` | `body.set_linear_velocity(v)` (kinematic + rigid) |
| `velocity_set_relative` (ADR 0040) | Same with basis transform |
| `state_set field=position` | Kinematic: `body.global_position = v`. Rigid: warn (positions are sim-state, not authored). |
| `raycast_hit` | `PhysicsServer3D.intersect_ray()` |
| `pathfind_to` (future) | `NavigationServer3D.map_get_path()` — replaces ADR 0024 |

New effect types (added by this ADR):

| New effect | Maps to |
|---|---|
| `apply_force` | `body.apply_central_force(v)` (rigid only) |
| `apply_impulse` | `body.apply_central_impulse(v)` (rigid only) |
| `set_collision_enabled` | `body.set_collision_enabled(bool)` — disable collision temporarily |

### Tick ordering — snapshot-based sync (revised 2026-05-11)

Yume's sim runs at 10 Hz. Godot physics runs at 60 Hz by default
(`Engine.physics_ticks_per_second`, configurable). **Physics runs
on its own clock; sim snapshots positions at sim-tick boundaries.**

**Why not lockstep at 10 Hz**: lowering `physics_ticks_per_second`
to 10 would force physics to step in giant chunks (0.1s each), risking:
- Continuous collision detection failures (fast projectiles tunnel
  through walls between 100ms steps)
- Loss of visual smoothness (entities snap-move every 100ms unless
  camera lerp masks it)
- Coupling Yume's design constraint (sim tick rate) to a
  physics-engine constraint (it doesn't need to)

**Snapshot sync mechanism**:

```gdscript
# world.gd::advance_one_tick (called every sim-tick, ~10Hz)
func advance_one_tick() -> void:
    # 1. Read body positions into entity.state at tick start —
    #    snapshot is coherent across ALL phases that follow.
    _sync_state_from_bodies()

    # 2. Existing tick pipeline (unchanged from today).
    if actor_manager: actor_manager.tick_policies(scheduler.env)
    scheduler.tick()   # phase1 input → flush → drain decide →
                       # phase2 decide → flush → drain react flush →
                       # phase3 react → flush
    # During scheduler.tick, ALL rule queries see the same snapshot
    # of state.position. Invariant #9 holds because positions
    # don't change during a sim-tick.

    # 3. After all rules fire, write back any state changes that
    #    affect physics bodies.
    _sync_bodies_from_state()

# Between sim-ticks, Godot physics integrates at 60Hz naturally.
# Rigid bodies move based on velocity / forces / impulses.
# Kinematic body positions only change when we explicitly set them.
```

**Invariant #9 preserved**: within a single `advance_one_tick`,
state.position is fixed at the snapshot value. All phases see
identical positions. Physics-driven position changes accumulate
between sim-ticks; they become visible at the NEXT tick's
snapshot.

**Side benefits**:
- Smooth 60Hz visual motion (rigid bodies + kinematic bodies move
  continuously between sim-ticks)
- Continuous collision detection works (Godot can detect tunneling
  with sub-100ms timesteps)
- Camera lerp in game_shell is OPTIONAL, not a workaround
- No need to override Godot's physics rate

**Special case — kinematic position writes**:
When a rule does `state_set field=position` on a kinematic-body
entity, the write-back step uses `body.global_position = v` so the
body teleports (Godot kinematic bodies don't auto-integrate
position; explicit set is the right semantics). For rigid bodies,
direct position writes are unusual — warn at effect time.

**Special case — velocity_set effects**:
Phase 1 issues `velocity_set` → effect_apply routes to
`body.set_linear_velocity(v)`. The body's velocity changes
immediately. Subsequent rules in phase 2/3 querying
`entity.state.velocity` get the new value (sync hook reads body
velocity into state right after the effect applies, OR rules
should query body directly — TBD in Session B).

### What gets deleted

```
godot/scripts/engine/world.gd
  - _integrate_motion (~150 lines) → replaced by PhysicsServer3D
  - _build_aabb_snapshot (~50 lines) → no longer needed
  - position-set spatial_index updates → bodies are auto-tracked

godot/scripts/engine/stores/spatial_index.gd
  - Whole file (~200 lines) → replaced by Area3D / PhysicsServer3D queries

godot/scripts/engine/util/pathfinding.gd  [ADR 0024]
  - Whole file → replaced by NavigationServer3D (DEFERRED to ADR 0045)
```

**Note**: Pathfinding migration is intentionally deferred to a
separate ADR (0045) to keep this one focused. ADR 0024's A* grid
keeps working under ADR 0044 — the two systems are independent.

### What gets thinned

```
godot/scripts/engine/world.gd
  - _on_tick: calls scheduler.tick + lifecycle/schedule directors (unchanged)
  - _spawn_initial: now also creates PhysicsServer3D body for each entity
    with a `physics` block declared
  - _despawn_entity: free physics body
```

### Backward compatibility — what happens to `blocks_motion` + `aabb_extents`?

Three options:

**Strict** — Delete the tag. Every game's entity defs must declare
`physics` block. Migration is mandatory.

**Translation** — Engine sees `blocks_motion` tag + `aabb_extents`
property at load and SYNTHESIZES a `physics: {body_type: "static",
collision_shape: {type: "box", size: aabb_extents}}` block. Old
games keep working unchanged.

**Hybrid** — Translation for first N months, then deprecate with
warning, then delete.

**Recommendation: Translation.** Lowest migration cost; old games
keep running. Strict mode encourages new games to declare `physics`
explicitly. Migration is opportunistic, not blocking.

### Migration plan

Per-demo work:

1. **No-op demos** (zero collision):
   - chess, ecology, ecology_deep, harvestcore, tinypond, farming — these don't have walls. Nothing changes.
2. **Wall-only demos** (translation fires automatically):
   - sokoban, multilevel, merchant, rpg, doomarena, doomarena3d, towerdef3d, fpsgarden, shooter, aldenmere — translation layer maps `blocks_motion` + `aabb_extents` to static body + box shape. No JSON edits required.
3. **Opt-in upgrades** (per-game, optional):
   - Aldenmere: wolves can become rigid bodies with mass for collision response
   - Sokoban: boxes can become rigid bodies for momentum (or keep kinematic)
   - DoomArena: projectiles get continuous collision detection (no tunneling)

Engine work order (multi-session):

1. **Session A — schema + translation layer.** Read `physics` block,
   synthesize from legacy `blocks_motion` + `aabb_extents` if not
   present. Build PhysicsServer3D body per entity at spawn. NO
   behavior change yet — existing motion integrator still runs.
2. **Session B — route velocity_set + position to body.** Effects
   now mutate the physics body. Motion integrator becomes a no-op
   for entities with a physics body declared.
3. **Session C — collision via PhysicsServer3D.** Disable the
   hand-rolled AABB sweep in `_integrate_motion`. Bodies collide
   via physics. Verify acid demos still work.
4. **Session D — delete hand-rolled code.** `_integrate_motion`
   AABB sweep, `_build_aabb_snapshot`, SpatialIndex radius
   queries that physics now subsumes (radius queries → Area3D or
   `PhysicsServer3D.intersect_shape`). Update tests.
5. **Session E — performance + tuning.** Benchmark Aldenmere's
   ~250 entities. Tune layer masks. Document patterns for new
   games.

### Consequences

**Positive**

- ADR 0021 honored — Yume "exposes Godot through JSON" as the
  constitution requires. Foundation aligned with practice.
- Capability surface expands enormously: rotated colliders, mesh
  collision, continuous CD, joints, area sensors, friction,
  mass — all available without engine work.
- `SpatialIndex.gd` deleted (~200 lines). `_integrate_motion`
  shrinks dramatically. Net engine code goes DOWN, not up.
- Performance improves on dense games — Godot's spatial hash is
  C++, beats GDScript dict-walk at high entity counts.
- Editor tooling — CollisionShape3D gizmos visible in Godot
  editor when authors inspect a game scene.
- Future-proof: when a game wants soft bodies, fluids, ropes —
  they're already available, just declare the body type.

**Negative**

- One-time migration cost — Session A through D. Estimated
  ~5-8 hours of engine work spread across sessions.
- Determinism: Bullet has cross-machine float drift. Jolt option
  is better but still not bit-identical. Yume's deterministic-
  replay feature (hypothetical, not shipped) becomes harder. If
  this becomes important, the answer is "use Jolt + accept
  approximate determinism" or "snapshot positions at sim-tick
  boundaries for replay." Not a blocker — replay isn't a current
  requirement.
- New shape of bugs: physics tuning issues (entities flying,
  springs oscillating, friction wrong) become a new category of
  game-design pain. Mitigated by sensible defaults in the lib
  resolver (`@lib.physics.standard_kinematic_npc`, etc.).
- `aabb_extents` JSON authoring is replaced by `collision_shape:
  {type, ...}` — slightly more verbose. Lib templates can
  collapse this.
- Sokoban-style grid games: physics body for each box can feel
  heavy for a turn-based puzzle. The kinematic body type is the
  right answer (no physics simulation, just collision detection)
  — but it needs documenting.

**Open / TBD**

- Should pathfinding migrate to NavigationServer3D in the same
  ADR or a separate one? Recommendation: separate ADR 0045 —
  pathfinding is independent enough.
- 2D physics: PhysicsServer2D exists with the same API surface.
  Does this ADR cover 2D too, or only 3D? Recommendation: cover
  both. The schema is identical; the server is different (2D
  uses PhysicsServer2D + CharacterBody2D etc.). Engine code
  branches on `scene.json#camera_mode`.
- What happens to `effects.spatial_index_query`? Today it walks
  Yume's SpatialIndex. After migration, it queries
  `PhysicsServer3D.intersect_shape`. Schema unchanged; backend
  swaps.

## Condition resolutions (2026-05-12)

Tech-director review (2026-05-11) raised 11 conditions; 2 (tick
ordering + freeze policy) were resolved by the snapshot-sync model
revision earlier. This section addresses the remaining 9.

### Condition 1 — Invariant #5: QueryLib internal flow

After SpatialIndex is replaced, `QueryLib.run(spec)` with radius
follows this internal flow (preserves the contract from tags_all /
tags_any / tags_none / properties / state / relations / order_by /
limit semantics):

```gdscript
static func run(spec: Dictionary, env: Dictionary, ctx) -> Array:
    var candidates: Array = []
    if spec.has("radius"):
        # 1. Broadphase via Godot physics. Returns Array of body RIDs
        #    (or entity IDs after our wrapper resolves) within the
        #    sphere/box around the origin. Filters by collision_mask
        #    if the spec provides one (defaults to "all").
        var origin: Vector3 = _resolve_origin(spec, env, ctx)
        var radius: float = float(spec["radius"])
        var mask: int = _resolve_layer_mask(spec, env)
        candidates = _physics_broadphase(env, origin, radius, mask)
    else:
        candidates = env.get("entities", {}).values()
    # 2. QueryLib semantic filter — UNCHANGED. Walks candidates,
    #    rejects on tags_all/tags_any/tags_none/properties/state/
    #    relations mismatch.
    var out: Array = []
    for ent in candidates:
        if matches(ent, spec, env, ctx):
            out.append(ent)
    # 3. order_by + limit — UNCHANGED.
    if spec.has("order_by"): ...
    if spec.has("limit"): ...
    return out
```

Key: the **broadphase** is what changes (Yume SpatialIndex →
PhysicsServer3D). The **semantic filter** (tag/state matching)
stays identical. Performance argument holds only if layer masks
are tight — if every entity is on the same collision layer,
broadphase returns ALL bodies and we're back to O(N) in step 2.

Documentation: layer-mask discipline becomes a content authoring
concern. The yume-content-designer skill spec gets a new check:
"every entity def with a `physics` block declares specific
collision_layer + collision_mask — `all` masks are a smell."

### Condition 4 — Invariant #11: body cleanup on despawn

The entity-removal loop in `LevelTransitionCoordinator.do_transition`
and `WorldResetCoordinator.do_reset` (plus the `remove` effect path
in `effect_apply.gd`) must free the physics body when the entity is
destroyed. Adds to `_despawn_entity`:

```gdscript
# Inside SpawnManager (the new natural home for body lifecycle).
func despawn(inst_id: String) -> void:
    var ent = _world.entities.get(inst_id, null)
    if ent == null: return
    # ADR 0044: free the physics body BEFORE the entity Node is freed.
    var body_rid = ent.get_meta("_physics_body_rid", null)
    if body_rid != null:
        PhysicsServer3D.body_free(body_rid)
        ent.remove_meta("_physics_body_rid")
    # Existing cleanup
    if _world.relations: _world.relations.clear_entity(inst_id)
    if _world.spatial_index: _world.spatial_index.remove_entity(inst_id)
    _world.entities.erase(inst_id)
    ent.queue_free()
```

The three call sites of "remove entity" (LevelTransitionCoordinator,
WorldResetCoordinator, EffectApply.\_remove) are unified through
`SpawnManager.despawn(id)` as part of Session A. This makes
"physics body" item #N on Invariant #11's enumeration.

**Leak test** (Session A's PR): spawn 50 entities with
`physics: {body_type: "kinematic"}` declared, transition level,
assert all 50 body RIDs are freed (call `PhysicsServer3D
.body_get_object_instance_id(rid)` returns null for each).

### Condition 5 — Invariant #12: persistent-guard body sync

When a persistent entity teleports across level transitions
(`[PERSIST-TELEPORT]` log line in SpawnManager.spawn), the body's
transform must also update:

```gdscript
# In SpawnManager.spawn (Invariant #12 carve-out branch):
if inst.has("position"):
    existing.set_position(new_pos)
    if _world.spatial_index != null:
        _world.spatial_index.update_entity(inst_id, existing.get_planar_position())
    # ADR 0044: update the body's transform too. State (HP, inventory)
    # already survives untouched; just the position needs a teleport.
    var body_rid = existing.get_meta("_physics_body_rid", null)
    if body_rid != null:
        var v3 = existing.get_position()
        if v3 is Vector3:
            PhysicsServer3D.body_set_state(body_rid,
                PhysicsServer3D.BODY_STATE_TRANSFORM,
                Transform3D(Basis(), v3))
```

**Test** (Session A's PR): persistent entity in level A at (10, 0,
10) with kinematic body. Transition to level B which declares the
same id at (50, 0, 50). Assert: entity state intact (HP unchanged),
position now (50, 0, 50), body transform reflects the new position.

### Condition 6 — Session B atomicity

Session B (velocity + position routing) MUST land in a single
commit. The forbidden mid-state: some kinematic entities route
velocity through their body, others still hit `_integrate_motion`.

Acceptance criterion for the Session B PR:
1. Every entity with `physics.body_type IN [kinematic, rigid]`
   has its `velocity_set` / `velocity_set_relative` /
   `velocity_add_relative` routed to `body.set_linear_velocity`.
2. The legacy `_integrate_motion` runs ONLY for entities WITHOUT
   a physics block (translation layer ensures most have one).
3. Position writes via `state_set field=position`:
   - kinematic: `body.global_position = v3` (warp body to match
     authored position)
   - rigid: `push_warning("position writes to rigid body are
     non-physical; use velocity_set or apply_impulse")` + still
     apply the position (don't reject — let games experiment)
4. Diff is reviewable in one sitting: ~150 lines in
   `effect_apply.gd`, no semantic changes elsewhere.

### Condition 7 — New effects in effect-chain audit

`.claude/rules/engine-scripts.md` § effect-chain validation gate
gains 3 new entries:

```
apply_force         — non-destructive. Requires entity to have
                      rigid body (warn otherwise). Safe in any
                      chain position.
apply_impulse       — non-destructive. Same precondition + safety
                      as apply_force.
set_collision_enabled — non-destructive. Requires entity to have
                      any physics body (warn otherwise). Safe in
                      any chain position. Note: disabling collision
                      mid-frame lets the entity pass through walls
                      until re-enabled; use cooldowns explicitly.
```

None of these are destructive in the transition_screen/reload_scene
sense. They mutate physics state but don't queue async destruction.
No ordering constraints apply.

### Condition 8 — Translation-layer test coverage

Session A's PR ships these 4 unit tests:

```gdscript
test_blocks_motion_translates_to_static_box_3d():
    var def = {"id": "wall", "tags": ["blocks_motion"],
               "properties": {"aabb_extents": [2.0, 1.5, 0.5]}}
    var ent = _spawn_test_entity(def)
    var body = ent.get_meta("_physics_body_rid")
    expect_eq(PhysicsServer3D.body_get_mode(body),
              PhysicsServer3D.BODY_MODE_STATIC)
    # Shape extents match aabb_extents
    var shape = _get_body_shape(body)
    expect_eq(shape.size, Vector3(4.0, 3.0, 1.0))  # full extents

test_blocks_motion_2d_extents_translate_to_static_box_2d():
    # aabb_extents: [hx, hy] (2-component) → PhysicsServer2D box
    var def = {"id": "wall2d", "tags": ["blocks_motion"],
               "properties": {"aabb_extents": [10, 5]}}
    var ent = _spawn_test_entity_2d(def)
    expect(_has_2d_body(ent), "2D scene → PhysicsServer2D path")

test_blocks_motion_missing_aabb_extents_warns():
    var def = {"id": "borked", "tags": ["blocks_motion"]}
    _spawn_test_entity(def)
    expect_buffer_contains(env, "blocks_motion requires aabb_extents")
    expect_no_body(ent)

test_explicit_physics_block_wins_over_blocks_motion_tag():
    var def = {"id": "hybrid", "tags": ["blocks_motion"],
               "properties": {"aabb_extents": [1, 1, 1]},
               "physics": {"body_type": "kinematic",
                           "collision_shape": {"type": "sphere",
                                               "radius": 0.5}}}
    var ent = _spawn_test_entity(def)
    var body = ent.get_meta("_physics_body_rid")
    expect_eq(_get_body_shape(body).radius, 0.5)
    expect_eq(_get_body_mode(body),
              PhysicsServer3D.BODY_MODE_KINEMATIC)
    expect_buffer_contains(env,
        "blocks_motion tag ignored — explicit physics block takes precedence")
```

### Condition 9 — 2D coverage spec

The migration covers BOTH PhysicsServer3D and PhysicsServer2D.
The engine selects backend based on `scene.json#camera.mode`:

| Camera mode | Physics backend |
|---|---|
| `top_down_2d`, `side_scroll_2d` | PhysicsServer2D |
| `top_down_3d`, `isometric_3d`, `first_person_3d`, `third_person_3d` | PhysicsServer3D |

2D collision shapes (translates from `collision_shape.type`):

| JSON `type` | 2D shape resource |
|---|---|
| `box2d` | RectangleShape2D |
| `circle2d` | CircleShape2D |
| `capsule2d` | CapsuleShape2D |
| `polygon2d` | ConvexPolygonShape2D (future) |

2D body types (translates from `body_type`):

| JSON `body_type` | 2D body |
|---|---|
| `static` | StaticBody2D |
| `kinematic` | CharacterBody2D |
| `rigid` | RigidBody2D |
| `area` | Area2D |

The `physics` block schema is otherwise identical across 2D + 3D
(mass, friction, restitution, damping, collision_layer/mask).
Authors writing a 2D game just use `box2d` / `circle2d` etc. and
the engine wires them to PhysicsServer2D automatically.

Engine code branches once at boot: `_physics_is_2d =
scene_cfg.camera.mode in ["top_down_2d", "side_scroll_2d"]`. All
downstream physics calls dispatch on that flag.

### Condition 10 — Sokoban blocker-pattern preservation

Sokoban's "push blocked by wall" pattern (the empirical case
behind Invariant #9's react-flush guarantee) MUST work after each
session lands. The pattern:

1. Input rule: `push` action sets `box.state.being_pushed = 1`
2. Signal rule: if box adjacent to wall, set `box.state._blocked = 1`
   (uses radius query against `blocks_motion` entities)
3. Contact rule: only fire `commit_push` if `box.state._blocked != 1`

After Session C (collision via PhysicsServer3D), step 2's radius
query goes through `PhysicsServer3D.intersect_shape` instead of
`SpatialIndex.query_radius_ids`. Result must be identical. Test:

```
data/demo_sokoban/tests.json: scenario "box_push_into_wall_blocked"
  - Setup: box at (1, 0), wall at (2, 0), player at (0, 0)
  - Step: input push_east
  - Expect: box.state.position still (1, 0)
  - Expect: box.state._blocked == 1
```

This test is green in every session's PR (A through E).

### Condition 11 — Frame-time benchmark gate

Before Session D (the deletion session), measure Aldenmere idle
frame time:

```
Capture protocol:
  godot --rendering-driver opengl3 scenes/aldenmere_3d.tscn -- \
    --capture-after=10 --frame-time-log=user://aldenmere_frames.csv

Baseline (pre-migration, recorded once at Session A start):
  avg_frame_time_ms = <baseline value, populated at Session A>

Post-Session-C measurement (taken before Session D begins):
  avg_frame_time_ms = <new value>

Gate: post_ms <= 1.2 * baseline_ms (allow 20% regression budget)

If exceeded:
  - DO NOT proceed to Session D
  - Investigate broadphase layer-mask discipline first
  - If still failing, adopt Jolt physics
    (Project Settings → physics/3d/physics_engine = "Jolt") BEFORE
    Session D commits
  - Re-measure; gate must pass
```

Tools added in Session A:
  - `--frame-time-log=<path>` CLI flag that writes per-frame
    elapsed time to CSV during capture
  - `tools/benchmark_aldenmere.py` that reads the CSV and reports
    avg / p95 / p99 frame times

## Alternatives considered

### A. Keep status quo (do nothing)

Reject. Current state violates ADR 0021. Each new game compounds
the violation. Migration cost grows over time.

### B. Hand-roll more physics features

Reject. Adding OBB, slopes, friction to the hand-rolled system is
literally "rebuild Bullet/Jolt in GDScript." Already addressed by
ADR 0021's framing ("performance hopeless, stability decades").

### C. (chosen) Migrate to PhysicsServer3D with translation layer

This ADR. Honors the constitution. Translation layer makes
migration zero-cost for existing games. Per-game upgrades are
opportunistic.

### D. Migrate to PhysicsServer3D with strict cutover

Reject for now. Forcing every game to declare `physics` block
upfront is too high a coordination cost. Translation layer
captures the same eventual end-state with smoother migration.

### E. Adopt Jolt physics specifically (vs default Bullet)

Defer. Jolt is faster and more deterministic but is an opt-in
in Godot 4.x. Adopting it is a separate decision once the
migration to PhysicsServer3D lands. Engine doesn't care which
physics engine PhysicsServer3D uses under the hood — the JSON
contract is the same.

## Tech-director gate (mandatory before implementation begins)

This ADR touches the engine's foundational simulation layer. The
tech-director must verify:

1. **Invariant #1 (JSON-only content channel)** — physics is fully
   expressed in JSON `physics` blocks. No game-specific GDScript
   added.
2. **Invariant #5 (queries first-class)** — radius queries via
   `Area3D` / `PhysicsServer3D.intersect_shape` keep `QueryLib`
   semantics. No bypass.
3. **Invariant #8 (primitives + interpreter)** — adding the body-
   type / collision-shape vocabulary IS a primitive expansion.
   Acceptable BECAUSE it replaces an existing primitive (the
   hand-rolled AABB) and removes more engine code than it adds.
4. **Invariant #9 (phase boundaries flush)** — physics tick must
   integrate cleanly with PhaseScheduler. Recommendation: physics
   runs in lockstep with sim-tick (Option A above). Position
   reads after the physics step are stable for the next phase.
5. **Invariant #10 (freeze policy)** — when
   `env.screen_freeze_world=1` (modal up), physics must also
   pause. Implementation: `Engine.physics_jitter_fix = 0` +
   conditional `Engine.time_scale` while frozen, OR explicit
   `body.set_collision_enabled(false)` on all entities. Decide
   in Session A.
6. **Effect-chain validation gate** — new effects (`apply_force`,
   `apply_impulse`, `set_collision_enabled`) need entry in the
   effect-chain audit list per `.claude/rules/engine-scripts.md`.

## Migration checklist

### Session A — schema + translation
- [ ] Define `physics` block JSON schema (this ADR)
- [ ] Define `data/lib/physics_layers.json` with default layer names
- [ ] Engine: `world.gd::_spawn_initial` reads `physics` block, creates body
- [ ] Engine: translation layer — `blocks_motion` + `aabb_extents` synthesizes physics block at load
- [ ] Engine: legacy motion integrator unchanged YET; physics body exists but doesn't drive motion
- [ ] Unit tests: spawn entity with `physics` block, assert body created with correct shape
- [ ] Unit tests: spawn legacy entity with `blocks_motion`, assert translation fires
- [ ] Aldenmere boots clean, no regression

### Session B — velocity + position routing
- [ ] `velocity_set` effect routes to `body.set_linear_velocity` for kinematic + rigid bodies
- [ ] `velocity_set_relative` (ADR 0040) routes through basis-aware path
- [ ] `state_set field=position` routes to `body.global_position` for kinematic; warns for rigid
- [ ] Motion integrator becomes no-op for entities with physics body
- [ ] Unit tests + Aldenmere boot verification

### Session C — collision via physics
- [ ] Disable `_integrate_motion` AABB sweep
- [ ] All collision now routed through Godot
- [ ] Verify acid demos: sokoban (boxes stop at walls), aldenmere (wolves stop at trees), doomarena3d (projectiles stop at walls)
- [ ] Add `apply_force`, `apply_impulse`, `set_collision_enabled` effects

### Session D — deletion + tests
- [ ] Delete `world.gd::_integrate_motion` AABB sweep code
- [ ] Delete `world.gd::_build_aabb_snapshot`
- [ ] Replace `SpatialIndex.query_radius_ids` calls with `PhysicsServer3D.intersect_shape` (Area3D pattern)
- [ ] Delete `scripts/engine/stores/spatial_index.gd` (or keep as thin wrapper if other code uses it)
- [ ] Full test suite + 16-demo boot verification

### Session E — tuning + lib templates
- [ ] Author `data/lib/physics_bodies.json` with templates:
      `standard_kinematic_npc`, `static_wall`, `rigid_projectile`,
      `static_decoration_no_collision`, etc.
- [ ] Update yume-asset-designer skill to suggest physics-body
      templates per entity type
- [ ] Benchmark Aldenmere (250 entities) — assert no perf regression
- [ ] Update architecture doc sections 7, 8, 10, 12 to reflect new model
- [ ] Update `.claude/rules/data-demo.md` with `physics` block schema gate
- [ ] Update `tools/validate_*.py` to recognize new schema

## References

- ADR 0001 — Seven primitives (this ADR adds Collision Shape and Body Type as primitive vocabulary)
- ADR 0004 — `blocks_motion` tag (SUPERSEDED by this ADR)
- ADR 0009 — World/game/flow separation (physics belongs in world/rules.json semantics)
- ADR 0021 — Yume as JSON layer over Godot (foundational; this ADR finally implements its physics direction)
- ADR 0022 — (was empty placeholder; this ADR is the actual one originally anticipated as 0022 in earlier discussion)
- ADR 0024 — Pathfinding A* grid (independent; will be addressed in future ADR 0045)
- ADR 0027 — Cross-game lib references (`@lib.physics.X` templates use this)
- ADR 0040 — Camera-relative WASD (`velocity_set_relative` effect must route to physics body correctly)
- `docs/guideline/30_framework_primitives.md` — to be updated when this ADR is accepted
- `docs/33_yume_full_architecture.md` § 12 — to be REWRITTEN once this ADR lands

## Acceptance gate

- [ ] All 16 demos pass unit tests + scenario tests + visual capture
- [ ] No regression on Aldenmere's 250-entity scene (perf budget)
- [ ] Translation layer documented + tested with at least 3 legacy `blocks_motion` games
- [ ] `docs/33_yume_full_architecture.md` § 12 rewritten to reflect new direction
- [ ] Tech-director final approval per the gates listed above

---

## Tech-director review (2026-05-11)

**Verdict: ACCEPT-WITH-CONDITIONS.**

The ADR is architecturally sound and the right direction.
ADR 0021 is the foundational commitment; ADR 0004's hand-rolled
AABB is a historical violation that grows costlier with each new
game. Migration honors the constitution + removes more engine code
than it adds.

However, the ADR has three significant gaps that must be filled
BEFORE Session A begins, plus six conditions that gate Sessions
B-E. Listed below per invariant.

### Invariant-by-invariant findings

#### Invariant #1 (JSON-only content channel) — ✅ PASSES

The `physics` block schema is fully JSON-expressible. No
game-specific GDScript added. The translation layer for legacy
`blocks_motion` is engine-side (acceptable — that's the
interpreter, not content).

**No condition.**

#### Invariant #5 (queries first-class) — ⚠ NEEDS CLARIFICATION

`QueryLib.run(spec)` with radius set currently calls
`SpatialIndex.query_radius_ids`. After migration it'd call
`PhysicsServer3D.intersect_shape`. The query CONTRACT (tags_all,
properties, state, radius, order_by, limit) stays identical, but
the new backend returns ENTITY IDs from physics broadphase — those
still need to be filtered by tag/state via existing QueryLib code.

**CONDITION 1**: The ADR must specify the QueryLib internal flow:
1. Physics broadphase returns candidate body IDs within radius
2. QueryLib maps body IDs → entity IDs (via reverse lookup)
3. QueryLib filters candidates by `tags_all` / `tags_none` /
   `properties` / `state` / `relations` — UNCHANGED semantics
4. `order_by` + `limit` applied — UNCHANGED

The performance argument ("Godot spatial hash beats GDScript dict")
only holds if step 1 returns a tight candidate set. If broadphase
returns ALL bodies (because layer masks aren't tight), step 3
becomes O(N) again. Layer-mask discipline becomes load-bearing for
perf.

#### Invariant #8 (engine = primitives + interpreter) — ✅ PASSES

The ADR adds primitive vocabulary (body_type, collision_shape,
collision_layer/mask, mass/friction/restitution/damp) AND new
effects (apply_force, apply_impulse, set_collision_enabled). All
genre-agnostic, all generic over games. Adding ~30 lines of new
vocabulary while deleting ~400 lines of hand-rolled engine code is
the correct trade per Invariant #8.

The body-type enum (static/kinematic/rigid/area) is exactly the
right interpretive abstraction: it maps cleanly to Godot's body
classes without exposing internal Godot types to JSON authors.

**No condition.**

#### Invariant #9 (phase boundaries flush) — ✅ PASSES after snapshot-sync revision

Original review flagged this as a blocker assuming lockstep at
10Hz. After user pushback (2026-05-11): physics runs at native
60Hz; sim snapshots positions at tick boundaries. This is cleaner.

**Mechanism (now in ADR text):**
1. `advance_one_tick` starts with `_sync_state_from_bodies` —
   takes a position snapshot
2. All scheduler phases run against the snapshot. `state.position`
   doesn't change during a sim-tick. Invariant #9 holds.
3. After scheduler.tick completes, `_sync_bodies_from_state`
   writes back any state mutations to bodies.
4. Between sim-ticks, Godot's 60Hz physics tick integrates rigid
   bodies, moves kinematic bodies via their controllers, runs
   continuous collision detection. Sim doesn't see this until
   next snapshot.

**CONDITION 2 (mandatory in Session A)**: implement the
`_sync_state_from_bodies` + `_sync_bodies_from_state` hooks.
Add unit test:
- Spawn entity at position (0, 0, 0) with kinematic body
- Phase 1 issues `velocity_set` effect with [5, 0, 0]
- Phase 2 query reads `state.position` — must be (0, 0, 0)
  (snapshot, not live)
- Phase 3 query reads `state.position` — must be (0, 0, 0)
- After advance_one_tick returns, body has integrated some
  movement (~5 * 1/60 = ~0.083m at 60Hz physics)
- Next advance_one_tick: snapshot reads body's current position,
  state.position now reflects the move

This test exercises the snapshot semantics + protects invariant #9
explicitly.

#### Invariant #10 (freeze-policy audit) — ⚠ NEEDS FIX

The ADR mentions `Engine.time_scale=0` or per-body
`set_collision_enabled(false)`. **Both are wrong**:

- `Engine.time_scale=0` halts ALL Godot processing — animation,
  particles, audio fades, modal tweens. Breaks UX (modal expects
  to animate while world is paused).
- Per-body disable is O(N) work + forgets entities spawned
  mid-freeze.

**CONDITION 3 (mandatory in Session A)**: Freeze mechanism is
`PhysicsServer3D.set_active(false)` (or `PhysicsServer2D` for 2D
scenes). This pauses ALL physics processing — rigid bodies don't
integrate, kinematic bodies don't move, queries return stale data
— without affecting Godot's animation / tween / audio systems.

```gdscript
# In world.gd::_on_tick:
var freeze: bool = (env.get("screen_freeze_world", 0) > 0 \
        or env.get("overlay_freeze_world", 0) > 0)
PhysicsServer3D.set_active(not freeze)
if freeze:
    return  # sim suspended; pending pipelines still drain
# ... rest of tick (including advance_one_tick + snapshot sync)
```

Pending pipelines (`_pending_save_load`,
`_pending_level_transition`) that run UNDER freeze MUST NOT
trigger physics state mutations — they operate on entity dicts +
relations, not bodies. Verify in test pass.

**Empirical test to add**: title screen up (freeze on), wolf
entity exists with rigid body + initial velocity (3, 0, 0). Assert
wolf position is UNCHANGED across 10 rendered frames. Without
`PhysicsServer3D.set_active(false)`, physics keeps integrating
velocity and the wolf drifts.

#### Invariant #11 (level-discontinuity cleanup) — ⚠ NEEDS NEW CHECKLIST ITEM

When `transition_level` fires, OLD-level entities are destroyed.
Currently `world.gd::_despawn_entity` removes the Entity node from
the tree + clears spatial_index entry. After migration it must
ALSO free the corresponding PhysicsServer3D body.

**CONDITION 4 (mandatory in Session A)**:
1. Add `_despawn_entity` body-cleanup: `PhysicsServer3D.body_free(body_rid)`.
2. Add a leak test: spawn N entities with physics, transition level,
   assert `PhysicsServer3D.body_get_object_instance_id()` returns
   null for all freed bodies.
3. Add the new "physics body" item to Invariant #11's "engine state
   coupled to OLD entity" enumeration in the tech-director skill.

#### Invariant #12 (persistent-entity instance clobber guard) — ⚠ NEEDS CARVE-OUT

Persistent entities (e.g., world_clock, player carrying state)
survive `transition_level`. After migration, their physics body
must also survive. The instance-clobber guard in
`world.gd::_spawn_initial` currently does `[PERSIST-SKIP]` /
`[PERSIST-TELEPORT]`. The teleport case must update body position:

```gdscript
if entities[inst_id].has_tag("persistent"):
    if inst.has("position"):
        # PERSIST-TELEPORT: update body's transform too
        var body = _body_for_entity(inst_id)
        if body != null:
            PhysicsServer3D.body_set_state(body,
                PhysicsServer3D.BODY_STATE_TRANSFORM,
                Transform3D(Basis(), position_v3))
        continue
    # PERSIST-SKIP: state intact, no transform change
    continue
```

**CONDITION 5 (mandatory in Session A)**: persistent-guard tests
must extend to cover body-transform sync. Add to `test_runner.gd`.

### Migration plan — risk assessment

Session-by-session evaluation:

| Session | Risk | Atomic? | Notes |
|---|---|---|---|
| A — schema + translation | LOW | yes | Bodies created but inert. Cannot regress existing behavior. |
| **B — velocity routing** | **HIGH** | **must be atomic** | See CONDITION 6. |
| C — collision swap | HIGH | yes | All-or-nothing flag flip. |
| D — deletion | LOW | yes | Only runs after C is verified. |
| E — tuning | LOW | yes | Polishing pass. |

**CONDITION 6 (Session B atomicity)**: Session B routes velocity
to bodies for kinematic + rigid entities. The ADR is unclear on
how to handle the half-migrated state:
- If some entities have a physics body (kinematic NPCs) and others
  don't (pure scenery), the integrator needs to handle BOTH
  groups within the same commit. NOT split across commits.

Acceptance criterion: in the Session B PR, every entity that has
`physics.body_type IN [kinematic, rigid]` routes velocity through
the body. Every entity without a physics block keeps the legacy
path (which deletes in Session C). The mid-state where SOME
kinematic entities route to bodies + OTHERS still hit the
integrator is forbidden.

### Effect-chain validation gate — clarification

The three new effects (`apply_force`, `apply_impulse`,
`set_collision_enabled`) are NOT destructive (they don't destroy
scene state or queue async destruction). They're state-mutating in
the same class as `state_set`. **No effect-chain ordering
constraint needed.**

**CONDITION 7**: Add these to `.claude/rules/engine-scripts.md` § effect
list with explicit "non-destructive; safe in any chain position"
note. Document that they require the target entity to have a rigid
body (rigid for force/impulse; any body for set_collision_enabled).
Warn at effect_apply time if the target has no body.

### Translation strategy — APPROVED

Translation > strict cutover. Lowest migration cost. Old games
keep working.

**CONDITION 8 (test coverage for translation layer)**: Unit tests
in Session A must cover:
1. Legacy `blocks_motion` + `aabb_extents: [hx, hy, hz]` → 3D box
   static body. Assert shape extents match. Assert body is at
   entity position.
2. Legacy `blocks_motion` + `aabb_extents: [hx, hy]` → 2D box
   static body (PhysicsServer2D).
3. Entity with `blocks_motion` tag but no `aabb_extents` → engine
   warning, no body created.
4. Entity with explicit `physics` block + `blocks_motion` tag →
   `physics` block wins; tag ignored with warning.

### 2D coverage — ADR MUST EXPAND

The ADR says "cover 2D + 3D" but doesn't specify 2D shape names or
the switching logic.

**CONDITION 9**: ADR text must specify:
- 2D scenes (camera_mode `top_down_2d` / `side_scroll_2d`) use
  PhysicsServer2D + CharacterBody2D/StaticBody2D/RigidBody2D
- 2D shape types: `box2d` (RectangleShape2D), `circle2d`
  (CircleShape2D), `capsule2d` (CapsuleShape2D)
- Engine routes by `scene.json#camera.mode` at boot — picks
  PhysicsServer2D or PhysicsServer3D backend
- Schema fields (body_type, mass, friction, etc.) are identical
  across 2D + 3D — only `collision_shape.type` differs

### Pathfinding deferral — APPROVED

Splitting pathfinding into ADR 0045 is the right scoping. ADR
0024's A* grid stays load-bearing during this migration. The
`pathfind_to` effect in the ADR table marks it as "future"
correctly.

**No condition.**

### Sokoban blocker-pattern preservation — CRITICAL TEST

Sokoban's "push blocked by wall" pattern is the empirical case
that led to Invariant #9's react-flush guarantee. Under physics
migration, this pattern still needs to work:
1. Input rule: `push` action sets `box.state.being_pushed = 1`
2. Signal rule: if box adjacent to wall, set `box.state._blocked = 1`
3. Contact rule: only fire `commit_push` if `box.state._blocked != 1`

After Session C, the "box adjacent to wall" detection might come
from Godot collision (Area3D overlap) instead of `blocks_motion`
AABB. **The pattern must still work** — the test suite already
covers it. Verify no regression in Session C's test pass.

**CONDITION 10**: Sokoban scenario test for blocker pattern is
green in every session's PR (A, B, C, D, E).

### Performance budget — CRITICAL

Aldenmere ships with ~234 entities + ~96 trees with collision +
~100 grass without. After migration, total bodies ≈ 350-400 (some
trees become static bodies, kinematic NPCs add bodies, etc.).

**CONDITION 11 (gate to Session D)**: Frame time benchmark before
Session D lands. Capture Aldenmere at idle (no input) for 10
seconds:
- Average frame time pre-migration: <baseline>
- Average frame time post-Session-C: <measured>

If post-Session-C frame time is >120% of pre-migration baseline,
DO NOT proceed to Session D. Investigate broadphase layer masking
or adopt Jolt (`physics_engine = "Jolt"` in project.godot) before
committing.

### Acceptance gate update

The existing acceptance gate stands, with these additions:
- [ ] All 11 conditions above resolved
- [ ] PhysicsServer3D.set_active mechanism documented + tested for freeze
- [ ] Unit test for two-phase position consistency (Invariant #9)
- [ ] Sokoban blocker-pattern scenario green in every session PR
- [ ] Frame-time benchmark before Session D

### Summary verdict

**Accept-with-conditions.** This ADR is the right direction and is
internally well-reasoned.

**Revision pass 2026-05-11 (user pushback on lockstep)**:
- Tick ordering revised to snapshot-sync model (physics at 60Hz,
  sim at 10Hz, positions snapshot at sim-tick boundary). This is
  cleaner than original Option A lockstep.
- Invariant #9 now passes cleanly under the snapshot model.
- Invariant #10 freeze mechanism finalized as
  `PhysicsServer3D.set_active(false)`.

Remaining outstanding conditions (1, 4-11) are clarifications +
test coverage, not structural blockers. Once they resolve in ADR
text, status flips to approved.

Implementation: 5-8 hours per the ADR's original estimate. Total
multi-session migration: 1-2 weeks of intermittent engine sessions.

— yume-tech-director, 2026-05-11
— revised 2026-05-11 per user pushback on physics tick rate

### Lockstep correction note

The original tech-director review incorrectly recommended manually
stepping physics at 10Hz from within `advance_one_tick`. The user
correctly observed this is suboptimal — physics should run at its
native 60Hz for smooth motion + continuous collision detection,
with the sim taking position snapshots at tick boundaries.

The cleaner architecture (now in ADR text under "Tick ordering"):
- Physics: Godot's native 60Hz `_physics_process` — integrates
  rigid bodies, moves kinematic bodies, runs CCD
- Sim: Yume's 10Hz `advance_one_tick`, with read-snapshot at tick
  start + write-back at tick end
- All scheduler phases within a sim-tick see a coherent position
  snapshot → invariant #9 preserved
- Continuous physics between sim-ticks → smooth visuals without
  needing camera lerp workarounds

Lesson archived for future ADR reviews: **don't lower a healthy
60Hz subsystem to fit a 10Hz sim contract — bridge them with
snapshot semantics instead.**
