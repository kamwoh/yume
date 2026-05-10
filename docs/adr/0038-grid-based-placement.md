# ADR 0038 — Grid-based placement (Sims-style snap)

_Date: 2026-05-10_
_Status: accept-with-conditions (2026-05-10) — three conditions resolved in revision below; ready for engine session_

## Context

Empirical case (2026-05-10, Aldenmere Phase 1 playtest): the user
walked the proto-village level and reported *"the things you build all
are in weird locations."* The proximate cause was that auto-generated
content placements use continuous floats picked by the level-designer
+ content-designer pipeline, plus pattern primitives (ring / scatter /
cluster) that snap to nothing. Buildings sit at fractional positions
like (12.347, 0, 47.918) with arbitrary yaws like 0.4123 rad. Visually
the village reads as scattered junk rather than a planned settlement —
even when the placements are technically collision-clean.

The user's stated fix: *"proper fix of course"* — make the level a
**Sims-style grid**. Buildings snap to integer-meter cells; rotations
snap to 90° increments; the village reads as deliberately laid out
because every structure aligns with its neighbors.

Yume already has the placement primitives needed (ADR 0037
`build_place`, ADR 0007 `aabb_volumes`, the `instance_patterns`
expander), but no axis-of-correctness for **alignment**. Adding
per-rule snap-to-grid math is wrong (every rule duplicates the snap
formula; pattern expander has no hook; level-design time placements
remain unsnapped). The right level is the engine: declare a grid in
`scene.json`, and the engine snaps everything that lands during world
load AND every runtime `build_place` AND every preview-widget
position.

This is also a Phase 2-4 foundation. The Aldenmere multi-phase plan
calls for villages with mud-brick rows (Phase 2), city blocks (Phase
3), and kingdom-scale construction (Phase 4). All three eras want
grid-aligned settlements; the alternative — every NPC build rule
authoring its own snap — is unmaintainable at the 50-NPC,
100-build-per-day scale.

Per ADR 0021 (Yume = JSON layer over Godot), the engine should expose
grid alignment as a JSON-declarative primitive rather than baking it
into per-game content.

## Decision

Introduce an optional `grid` block in `scene.json`. When present, the
engine snaps all entity positions and yaws to the grid. When absent,
behavior is unchanged (existing 13 demos are unaffected).

### Schema

```jsonc
// scene.json — optional grid block
{
  "grid": {
    "size": 2.0,                  // cell size in meters (X+Z)
    "y_size": 0,                  // optional Y snap; 0 = DISABLED (default — floor-walking worlds pass Y through unchanged). Set to a positive value (e.g. 1.0) only for vertical-discrete worlds.
    "snap_yaw": true,             // snap yaw to multiples of yaw_increment
    "yaw_increment": 1.5707963,   // π/2 = 90°; can be π/4 (45°) etc.
    "origin": [0, 0, 0],          // grid origin offset; default [0,0,0]
    "exempt_tags": ["actor", "projectile", "particle", "animal"],
    "snap_initial": true,         // snap initial_instances on load (default true)
    "snap_patterns": false,       // snap pattern-expanded instances (default false — patterns intentionally use continuous math)
    "show_overlay": false,        // engine-rendered grid floor lines (preview/debug)
    "overlay_color": "#ffffff20"
  }
}
```

All fields optional with sensible defaults. The minimal opt-in is
`{"grid": {"size": 2.0}}` — 2-meter cells, 90° yaw snap, exempt the
default actor/projectile/particle/animal tag list.

### Snap math

```
snap_x(x) = origin.x + round((x - origin.x) / size) * size
snap_z(z) = origin.z + round((z - origin.z) / size) * size
snap_y(y) = if y_size > 0:
              origin.y + round((y - origin.y) / y_size) * y_size
            else:
              y                       // pass-through (default for floor-walking worlds)
snap_yaw(θ) = round(θ / yaw_increment) * yaw_increment
```

Pure deterministic; no randomness. `round` uses banker's rounding (Godot
default `roundf`). For yaw, the result wraps via `fposmod(θ, TAU)`.

### Application points (engine sites that snap)

The engine snaps at four sites:

1. **World load — `initial_instances`**: every instance whose def is
   not in `exempt_tags` gets its `position` and `state.yaw` snapped.
   Controlled by `snap_initial` (default true). This catches all
   level-design-time placements without per-game migration.

2. **Pattern expansion — `instance_patterns.gd`**: when
   `snap_patterns: true`, ring/grid/scatter/cluster results are
   snapped after expansion. Default `false` because patterns
   intentionally use continuous math (e.g. `scatter` with
   `min_spacing` would degenerate at small grid sizes; `ring` would
   collapse adjacent points to the same cell). Authors who want
   grid-aligned patterns either use the existing `grid` pattern or
   opt in.

3. **Runtime `build_place` (ADR 0037)**: every successful build_place
   snaps `position` and `yaw` BEFORE running validation predicates.
   This means `no_overlap` checks the snapped position — predicate
   passes iff the snapped cell is clear. Authors writing build rules
   don't supply pre-snapped coordinates; they pass the cursor's
   continuous position, the engine snaps + validates.

4. **Build preview widget (ADR 0037)**: the ghost mesh renders at the
   snapped position/yaw. As the player moves the cursor, the ghost
   "jumps" cell-to-cell — Sims-style placement feel.

### Exempt tags (entities that DON'T snap)

By default, snapping is OFF for any entity whose def has a tag in
`exempt_tags`. Defaults: `["actor", "projectile", "particle",
"animal"]`. Reasoning:

- **Player + NPCs (`actor`)**: snapping a moving entity to grid
  produces visible stutter every tick. Actors have continuous
  position; the grid is for static structures.
- **Projectiles**: same reason.
- **Particles**: same reason.
- **Animals**: AI movement looks robotic on snap.

Authors can override by listing different tags. A game wanting
chess-like gridded actors would use `exempt_tags: []` so even the
player snaps.

### Position vs state.position

Yume entities store position both as `entity.position` (Godot Node
transform) and `entity.state.position` (the engine's authoritative
copy used by formulas). Snap writes BOTH so they stay synchronized.
The motion integrator's mid-tick velocity-driven positions are NOT
snapped — only initial spawn / build_place lands at grid cells.

### Yaw storage

`state.yaw` is the canonical engine field (radians, used by ADR
0035 animation primitive + ADR 0037 AABB rotation). Snap targets
this field; the renderer reads it and orients the visual mesh.
Entities without a yaw field (most actors) are unaffected by yaw
snap.

### Grid overlay (optional)

When `show_overlay: true`, the engine renders subtle grid lines on
the ground plane (a textured MeshInstance3D using a grid shader).
Useful for development; off by default in shipped games.

The overlay is one engine module (`grid_overlay.gd`, ~80 lines)
joining the JSON-declared-Godot-widget family per ADR 0021. Falls
under the visual-validation gate per `.claude/rules/engine-scripts.md`.

### Per-game opt-in

The 13 existing demos do not declare a `grid` block, so the engine
behavior is unchanged. Aldenmere opts in by adding `grid` to its
`scene.json` (size: 2.0). Future games opt in or stay grid-free per
their design.

## Consequences

### Positive

- **Aldenmere reads as a planned village.** Buildings align;
  rotations are 90°; the "weird locations" complaint goes away.
- **Foundation for Phase 2-4 building.** Mud-brick rows (Phase 2),
  city blocks (Phase 3), kingdom-scale grids (Phase 4) all use the
  same primitive. NPCs running schedule-driven build rules
  automatically produce aligned construction without per-rule snap
  formulas.
- **Composes with `build_place` (ADR 0037).** Validation predicates
  see the snapped position, so `no_overlap` is grid-cell-aware: two
  buildings can't fight over the same cell at sub-cell precision.
  Reduces 穿模 false-positives at oblique cursor positions.
- **Backward-compat.** All 13 existing demos keep their continuous
  math by default (no grid block).
- **Design vocabulary expansion.** Future genre patterns (chess,
  sokoban, tower defense lane snap) become trivially expressible by
  adjusting `size` and `exempt_tags`.
- **Predictable AI.** NPCs deciding "build a hut here" land on a
  cell, not a fractional position. Their target is reproducible
  across save/load.

### Negative

- **Slight coordinate drift on opt-in.** Aldenmere's existing
  hand-picked positions like (12.347, 0, 47.918) snap to (12, 0, 48)
  — visually similar but exactly aligned. Some level-design
  intentionality may shift; the level-designer skill will need to
  re-author with grid-cell coordinates rather than continuous floats.
  Migration plan below.
- **Pattern primitives' continuous math conflicts.** `scatter` with
  `min_spacing < grid.size` produces collisions when snapped to grid.
  Default off (`snap_patterns: false`) avoids this; authors who want
  grid-aligned scatter opt in and accept the constraint (or use the
  existing `grid` pattern).
- **One new engine module.** `grid_snap.gd` (~50 lines static utility)
  + optional `grid_overlay.gd` (~80 lines renderer). Both are pure
  add-ons; no existing module changes shape.
- **Visual gate cost.** The overlay widget is a rendering primitive
  per `.claude/rules/engine-scripts.md`, requires `--capture` +
  `yume-visual-designer` review when implemented.

### Neutral

- **Save/load (ADR 0010)**: positions are stored as floats, restored
  as floats. Grid snap re-applies on load via `snap_initial` if
  enabled. Saves from a no-grid version of a game can be loaded with
  a new grid block — entities snap to nearest cell on the next save.
- **Cross-game JSON reuse (ADR 0027 + 0028)**: `@lib.entities.<x>`
  templates are unchanged. Grid is a per-game scene config, not a
  template property.
- **Scenario tests**: `data/<game>/tests.json` assertions on
  `state.position` need exact-cell values. Authors update test
  positions to snapped values when opting in; existing scenario
  tests are unaffected (their games don't have grid blocks).

## Alternatives considered

### A) Per-rule snap formulas in JSON

Authors write `position: "round(self.state.target_x / 2.0) * 2.0"`
in every build_place rule. Rejected:

- **Duplication.** ~30 build rules in Aldenmere alone; same formula
  pasted 30 times.
- **No initial-placement coverage.** `initial_instances` and pattern
  expansions have no Formula context to evaluate snap math.
- **Runtime cost.** Every build_place re-parses the same Formula.
- **Author error surface.** A rule that forgets to snap produces
  one-off mis-aligned entity that breaks the village's visual
  coherence. The sentinel for "is the village aligned?" must be at
  the engine, not in author discipline.

### B) Snap at the renderer only

Render the mesh at the snapped position; keep state.position
continuous. Rejected:

- **Renderer-state divergence.** `state.position` drives queries,
  formulas, AABB checks. If renderer says (12, 0, 48) but state
  says (12.347, 0, 47.918), `no_overlap` checks the wrong cell.
- **Save/load breaks.** Saves serialize state.position; restore
  produces drift across sessions.
- **AI confusion.** NPCs computing "where should I go" against
  state.position aim at a fractional spot, then visibly walk
  toward a cell that doesn't match.

### C) Grid as a content convention (not engine vocabulary)

Document "round positions to integers when authoring" in the
content-designer skill; no engine support. Rejected:

- **Doesn't solve runtime placement.** NPC schedule-driven builds at
  Phase 2-4 scale need an engine guarantee.
- **No enforcement.** Convention drifts; bugs reappear.
- **The user explicitly asked for "proper fix" — i.e., engine
  primitive, not author discipline.**

### D) Full physics tile-grid (each cell is a discrete entity)

Tile-based engine like classic Roguelikes. Rejected:

- **Too restrictive for Yume's hybrid 2D/3D + continuous-motion
  positioning.** Actors don't snap; only structures do. Mixed
  tile-grid + continuous physics is the classic two-systems
  problem.
- **Existing AABB physics (ADR 0004 / 0007) is the canonical
  collision substrate.** A grid-snap layer composes with it
  cleanly; replacing it would invalidate every demo.

### E) Grid per-level instead of per-game

Each level (per ADR 0006 multi-level system) declares its own grid.
Rejected for v1:

- **Scope creep.** Aldenmere's single level needs one grid. Future
  games with mixed grid/no-grid levels can extend later (the `grid`
  block also lives in level-specific JSON if we want — a small
  follow-up). v1 keeps the surface minimal.

Future ADR (call it 0042) could move `grid` from `scene.json` to
`levels/<name>/grid.json` for per-level granularity.

### F) Fractional grid (e.g. 0.5 m cells)

Allow `size: 0.5`. v1 supports this — `snap_math` is generic over
cell size. The default of 2.0 m matches Aldenmere's structure
footprints (mud hut ~2x2m, lean-to ~1.5x1.5m → snap to 2m grid).
Smaller cells (0.5m) approximate continuous placement; larger cells
(4m) feel chunkier. Authors pick per-game.

## References

- ADR 0001 — seven primitives + interpreter (grid is a scene-config
  primitive, not a new effect type — it's interpreter scope)
- ADR 0004 — `blocks_motion` tag + `aabb_extents` (the collision
  substrate that grid placements compose with)
- ADR 0006 — multi-level system (future per-level grid extension)
- ADR 0007 — `aabb_volumes` (yaw snap composes with rotated AABBs)
- ADR 0010 — save / load (snapped positions serialize as floats;
  re-snap on load)
- ADR 0021 — JSON layer over Godot (grid is a JSON-declared
  axis-of-correctness, not engine logic)
- ADR 0027 + 0028 — cross-game JSON reuse (`@lib` templates
  unchanged)
- ADR 0035 — animation primitive (yaw is `state.yaw`; grid snaps
  it before animation reads it)
- ADR 0037 — dynamic structure placement (`build_place` is the
  primary runtime consumer of grid snap)
- `godot/scripts/engine/world.gd::_spawn_initial` — site of
  `initial_instances` snap on load
- `godot/scripts/engine/instance_patterns.gd` — site of optional
  pattern snap
- `godot/scripts/engine/effect_apply.gd::_build_place` — site of
  runtime build snap (after ADR 0037 lands)
- `docs/games/aldenmere/phase1_GDD.md` — motivating use case
- 2026-05-10 user feedback: *"the things you build all are in
  weird locations"* + *"proper fix of course"* — the empirical
  trigger for this ADR

## Test plan

Six unit-test sections in `test_runner.gd`:

| Test | Verifies |
|---|---|
| `grid.test_snap_math_round_trip` | `snap_x(snap_x(x)) == snap_x(x)` for various x; `snap_x(12.347) == 12.0` with size=2.0; `snap_yaw(0.4) == 0.0` with yaw_increment=π/2; `snap_yaw(1.0) == π/2`. |
| `grid.test_initial_instances_snap` | scene.json has `grid: {size: 2.0}`. entities/zz_instances.json declares a hut at (12.347, 0, 47.918). After world load, entities[hut].state.position == Vector3(12, 0, 48); state.yaw is grid-snapped. |
| `grid.test_exempt_tags_skip` | Player def has tag "actor". scene.grid.exempt_tags = ["actor"]. Player initial position (5.7, 0, 5.7). After load: position is UNCHANGED at (5.7, 0, 5.7). |
| `grid.test_build_place_snaps_position` | After ADR 0037 lands. build_place at cursor position (12.347, 0, 47.918) → spawned entity at (12, 0, 48). `no_overlap` predicate evaluated at the SNAPPED position. |
| `grid.test_pattern_snap_off_default` | scene.grid present, snap_patterns: false. Ring of 6 entities at radius 5: continuous coordinates, NOT snapped. (Default behavior preserves existing pattern math.) |
| `grid.test_no_grid_block_unchanged` | scene.json has NO grid block. All initial instances retain continuous coordinates. (Backward-compat sentinel.) |

Cross-cutting assertion: after every test, no two structures have
positions within `0.5 * grid.size` of each other (would indicate
snap collision).

## Implementation sketch

```gdscript
# grid_snap.gd — pure utility module
class_name GridSnap

# CONFIG ACCESS (per tech-director Condition 1, 2026-05-10):
# Grid config travels via the flat env key `env["scene_grid"]`,
# parallel to ADR 0037's `env["scene_bounds"]` pattern. World.gd's
# _build_env() reads scene.json's grid block once at load and
# injects it. effect_apply.gd::_build_place sees the same env, so
# the runtime path needs no extra wiring. `env.scene_grid == {}`
# means grid is disabled (existing 13 demos).

static func is_enabled(env: Dictionary) -> bool:
    return not (env.get("scene_grid", {}) as Dictionary).is_empty()

static func config(env: Dictionary) -> Dictionary:
    return env.get("scene_grid", {})

static func snap_position(pos: Vector3, env: Dictionary) -> Vector3:
    if not is_enabled(env): return pos
    var c := config(env)
    var size := float(c.get("size", 1.0))
    var origin: Array = c.get("origin", [0, 0, 0])
    # Y-snap: disabled by default. Pass through unchanged unless
    # y_size > 0 (vertical-discrete worlds opt in explicitly).
    var y_raw = c.get("y_size", 0)
    var y_size := float(y_raw) if y_raw != null else 0.0
    var snapped_y: float
    if y_size > 0.0:
        snapped_y = origin[1] + round((pos.y - origin[1]) / y_size) * y_size
    else:
        snapped_y = pos.y
    return Vector3(
        origin[0] + round((pos.x - origin[0]) / size) * size,
        snapped_y,
        origin[2] + round((pos.z - origin[2]) / size) * size
    )

static func snap_yaw(yaw: float, env: Dictionary) -> float:
    if not is_enabled(env): return yaw
    var c := config(env)
    if not bool(c.get("snap_yaw", true)): return yaw
    var inc := float(c.get("yaw_increment", PI / 2.0))
    return fposmod(round(yaw / inc) * inc, TAU)

static func should_snap(def: Dictionary, env: Dictionary) -> bool:
    if not is_enabled(env): return false
    var exempt: Array = config(env).get("exempt_tags",
        ["actor", "projectile", "particle", "animal"])
    var tags: Array = def.get("tags", [])
    for t in exempt:
        if t in tags: return false
    return true

# DRIFT WARNING (per tech-director Condition 3, Gate B, 2026-05-10):
# When snapped position differs from authored by more than
# 0.1 * size, log a push_warning. Surfaces source-JSON drift in QA
# logs without requiring a separate validator. Gate A static
# validator (tools/validate_grid_alignment.py) is the preferred
# follow-up; Gate B lands in this engine session.

static func snap_position_with_drift_check(pos: Vector3, env: Dictionary,
                                           ent_id: String) -> Vector3:
    var snapped := snap_position(pos, env)
    if not is_enabled(env): return snapped
    var size := float(config(env).get("size", 1.0))
    var threshold := 0.1 * size
    var dx := abs(snapped.x - pos.x)
    var dz := abs(snapped.z - pos.z)
    if dx > threshold or dz > threshold:
        push_warning("[grid] entity '%s' position drift dx=%.3f dz=%.3f from nearest cell — consider authoring at grid coordinates" % [ent_id, dx, dz])
    return snapped


# world.gd::_build_env — inject scene_grid (Condition 1 fix)
# After `_load_ground_cfg()` and similar scene-config readers:
var _grid_cfg: Dictionary = {}     # field on World node, set in load_data
# In _build_env(): env["scene_grid"] = _grid_cfg

# world.gd::_spawn_initial — added near entity placement
if GridSnap.should_snap(def, env) and bool(_grid_cfg.get("snap_initial", true)):
    var raw_pos: Vector3 = inst.state["position"]
    inst.state["position"] = GridSnap.snap_position_with_drift_check(
        raw_pos, env, inst_id)
    if inst.state.has("yaw"):
        inst.state["yaw"] = GridSnap.snap_yaw(inst.state["yaw"], env)


# effect_apply.gd::_build_place — after position resolve, before validation
if GridSnap.should_snap(defs[blueprint], env):
    pos = GridSnap.snap_position(pos, env)
    yaw = GridSnap.snap_yaw(yaw, env)
```

`grid_overlay.gd` (optional): MeshInstance3D + ShaderMaterial that
draws grid lines as a procedural texture on a large floor quad
positioned at scene.bounds. ~80 lines. Phase A includes
`--capture` + visual-designer review.

## Migration plan — Aldenmere

Aldenmere is the only game opting in for v1. Migration:

1. **Add grid to scene.json**:
   ```jsonc
   "grid": {"size": 2.0, "snap_yaw": true}
   ```
2. **Author re-pass** (one session of yume-content-designer):
   - Round all building positions to even-meter coordinates
   - Round all yaws to multiples of π/2 (0, π/2, π, 3π/2)
   - Verify `no_overlap` for the village layout at snap (now that
     adjacent buildings can no longer share a cell, fix collisions)
   - Update `tests.json` assertions that check position to use
     snapped values
3. **Snap-on-load fallback**: even without (2), `snap_initial: true`
   auto-snaps on world load. This means the user can opt in
   immediately and the village reads correctly. The author re-pass
   is for cleanup + intentional layout, not correctness.
4. **Animals + NPCs unchanged**: their tags include `actor` /
   `animal`; they're in `exempt_tags` by default. They keep
   continuous motion.
5. **Run `tests.json` scenarios**: verify no regressions.
6. **Visual capture**: confirm village now reads aligned.

Estimated effort: 1 builder agent session (engine work, ~150 LoC
total) + 1 content-designer pass for Aldenmere migration. Total ~2
sessions, matching the user's "proper fix" estimate.

## Post-mortem gate (per tech-director Condition 3, 2026-05-10)

The motivating bug class — content-designer / level-designer
authoring continuous-float coordinates that read as "weird
locations" — must not recur in future games that opt into a grid.
`snap_initial: true` auto-corrects at runtime, but source-JSON
drift remains an authoring hazard.

**Two gates land**, in two different sessions:

### Gate B — Runtime drift warning (THIS engine session)

`grid_snap.gd::snap_position_with_drift_check` (sketch above) logs
a `push_warning` when the snapped position differs from the authored
position by more than `0.1 * grid.size`. World.gd's `_spawn_initial`
calls this variant. QA logs (and `qa-tester`) surface drift
immediately; the user-facing "weird locations" symptom is gone
because of `snap_initial`, but the warning surfaces the source-JSON
quality issue for the content-designer skill to fix.

Threshold rationale: 0.1 × size = 0.2m at default 2m grid. Smaller
drift is rounding noise from the patterns expander; larger drift is
authoring intent at fractional coordinates.

### Gate A — Static validator (FOLLOW-UP session, not blocking ADR 0038)

`tools/validate_grid_alignment.py` walks `entities/*.json` +
`levels/*/entities/*.json` for any game whose `scene.json` declares
a `grid` block. For each non-exempt entity, asserts
`abs(position - nearest_cell) < 0.01`. Exits 1 in `--strict` mode.
Wired into:
- `yume-content-designer` skill checklist (final pass before handoff)
- `yume-level-designer` skill checklist (placement table → JSON)
- `play.sh` non-strict pre-launch (warns, doesn't block)

Implementing in a follow-up session because (a) it's a tooling pass,
not engine work, and (b) Gate B is sufficient for the empirical
case (Aldenmere migration). Gate A is the future-proofing layer for
the Phase 2-4 NPC-driven build expansion.

**Skill harden** (commits with the engine session): the
`yume-content-designer` and `yume-level-designer` skills append a
section: "If the game's scene.json declares a grid block, all
authored positions MUST be on grid cells. Run
`tools/validate_grid_alignment.py --strict` (when it lands) before
declaring done. Until then, eyeball positions to be on integer
grid multiples." Date-stamped to the empirical case.

## Open questions for tech-director review

1. **Grid in scene.json vs world/state.json.** Scene config is the
   right home; world state is for runtime mutation. Confirmed scene.
2. **Snap-y default.** RESOLVED 2026-05-10 per tech-director Condition 2:
   `y_size` defaults to `0` (DISABLED). Y is snapped only when the
   author opts in by setting `y_size > 0`. Floor-walking worlds
   (Aldenmere, merchant, etc.) keep the existing ground-clamp
   behavior; vertical-discrete worlds (chess in 3D, voxel-style
   puzzle) opt in. Schema + snap math + sketch updated.
3. **Should `snap_patterns` default change from false to true?**
   Lean: false for v1 backward-compat; future demos can opt in. The
   pattern primitives' authors are opt-in callers and aware of the
   trade-off.
4. **Grid overlay default color/alpha.** `#ffffff20` (subtle white,
   alpha 32) is a starting point; visual-designer reviews on
   implementation.
5. **Per-level grid (ADR 0042 future).** Confirmed v1 stays scene-
   wide. Per-level grid is a future extension when a multi-level
   game needs mixed grid/no-grid levels.
6. **Effect-chain interaction with build_place.** `build_place` is
   not destructive; grid snap composes cleanly inside its
   resolution flow. No effect-chain gate concerns.
7. **Visual gate.** `grid_overlay.gd` is rendering — visual gate
   applies. `grid_snap.gd` is pure math — no visual gate. Confirmed
   split.

## Performance budget

| Operation | Cost | Frequency |
|---|---|---|
| `snap_position` | 6 float ops + 1 dict lookup | Per spawn / per build_place |
| `snap_yaw` | 3 float ops + 1 dict lookup | Per spawn / per build_place |
| `should_snap` | 1 dict lookup + array contains | Per spawn / per build_place |
| `grid_overlay` render | One MeshInstance3D | Per frame (when enabled) |

Phase 4 worst case: 50 NPCs × 1 build_place per 15 min × 4 ops each
= negligible. World-load snap of 1000 initial entities = ~10ms
one-time cost. Standard ADR 0017 spatial-LOD scheduling unaffected.

## Status

Proposed 2026-05-10. Awaiting tech-director review. Implementation
expected ~2 sessions (1 engine, 1 content migration).

## Tech-director review

_Date: 2026-05-10_
_Reviewer: yume-tech-director_

### Verdict: accept-with-conditions

The proposal is architecturally sound — grid is a correct scene-config
primitive, it adds no semantic effect types, it creates no entity-class
hierarchy, it composes cleanly with ADR 0037 predicates. However, **one
structural defect in the implementation sketch would produce a silent
runtime failure**, plus three conditions must be met before merge.

---

### Invariant checks

**Invariant #1 (JSON-only content channel)**

Clear. Grid is declared in `scene.json` per-game. The engine reads it;
no game-specific behavior is hardcoded in GDScript.
Grep result: 0 matches in `scripts/engine/`. No violation.

**Invariant #2 (no semantic effect types)**

Clear. ADR adds zero new effect type strings. Grid snap is invoked
inside existing spawn and `build_place` paths. The forbidden strings
(damage, need_decay, heal, etc.) are absent.
Grep result: 0 matches. No violation.

**Invariant #3 (no entity-class hierarchy)**

Clear. `grid_snap.gd` is a `static` utility; `grid_overlay.gd` is a
renderer module. Neither extends Entity. No class_name Agent/Item/etc.
No violation.

**Invariant #5 (queries are first-class)**

Clear. No `for ent in entities.values(): if ent.has_tag(...)` bypass
introduced. `should_snap()` reads a def dict, not entity collection.
No violation.

**Invariant #8 (engine = primitives + interpreter)**

Acceptable. The `grid` block in `scene.json` is a scene-config
vocabulary expansion, parallel to the existing `bounds`, `camera`,
`ground`, and `level_seed` blocks. All are JSON-declared, engine-read,
game-agnostic. The question asked in this review — "is scene-config
expansion the same discipline as adding an effect type?" — is answered
YES: both require an ADR (which this is), and both expand the fixed
vocabulary the interpreter understands. The split is correct.

---

### Findings requiring conditions before merge

#### Condition 1 — STRUCTURAL DEFECT: `env.get("scene", {})` does not work

**Severity: must-fix before implementation begins.**

The implementation sketch in the ADR (lines 350-396) uses:

```gdscript
static func is_enabled(env: Dictionary) -> bool:
    var scene: Dictionary = env.get("scene", {})
    return scene.has("grid")
```

`env` does NOT contain a `"scene"` key. Verified by reading
`world.gd::_build_env()` (line 1760): the env dict contains
`entities`, `defs`, `relations`, `spatial_index`, `world`, `parent`,
`next_id`, `error_buffer`, `screen_event_buffer`, `overlay_event_buffer`,
`zone_store`. No `scene` key.

The scene.json config is currently accessed two ways:

1. **GameShell**: reads into `_scene_cfg` (a private var on GameShell,
   line 35 of `game_shell.gd`). Not in env.
2. **World.gd**: reads on-demand per-function (e.g. `_load_ground_cfg()`
   at line 1356 reads `scene.json` from disk, caches in `_ground_y` /
   `_ground_clamp_tags` / `_ground_despawn_tags`). The pattern for
   `boundary_check` (ADR 0037) uses a separate env key `scene_bounds`
   set by the caller — see `build_validators.gd` line 170 and test
   scaffolding at `test_runner.gd` line 4525.

If implemented as sketched, `is_enabled()` returns `false` for every
call — grid snap never fires. The bug would be silent: no error, no
warning, entities just stay unsnapped. The test
`grid.test_initial_instances_snap` would fail immediately (entities
not snapped after load), catching this at test time — but the sketch
must be corrected before the implementer writes the first line.

**Required fix**: the ADR must specify a concrete mechanism for
`grid_snap.gd` to reach the grid config. Two acceptable options (the
ADR author picks one):

Option A (preferred — consistent with `_ground_cfg` pattern): World.gd
reads scene.json once at load (after `_apply_level_seed_if_set`),
caches the grid block in a private var `_grid_cfg: Dictionary`, and
passes it as `env["scene_grid"]` inside `_build_env()`. GridSnap reads
`env.get("scene_grid", {})`.

Option B (consistent with `scene_bounds` pattern): the World.gd
`_spawn_initial` path reads scene.json's grid block inline (same
on-demand read as `_load_ground_cfg()`) and passes a pre-resolved
`Dictionary` directly to `GridSnap.snap_position()` — no env
intermediary. For `build_place` in `effect_apply.gd`, the caller injects
the grid config via `env["_grid_cfg"]` at call time (parallel to
`env["_build_place_options"]` used by `ground_buildable`).

Either option is acceptable. The ADR must commit to one and update
the implementation sketch before the engine session begins.

#### Condition 2 — Open question #2 is not resolved: y-snap default is wrong for 3D floor worlds

ADR open question #2 (line 437) reads: "y_size defaults to size (2m).
Is 2m vertical too coarse?" The author's own lean is "yes for now,
but allow 0 to disable y-snap." This is filed as an open question, not
a decision — but the implementer will default to the stated `y_size = size`
which is the wrong default for every floor-walking game.

Aldenmere structures sit on Y=0 ground. A 2m Y-snap of initial
instances with Y=0 produces snap_y(0.0) = 0.0 — harmless. But any
structure placed at a fractional Y (pattern expander with Y jitter,
ADR 0006 level transition restoring slightly-drifted Y, player-driven
build_place cursor at Y=0.05 from floor contact) would snap to Y=0 or
Y=2, producing entities floating 2m off the ground.

The correct default for a floor-walking world is Y-snap disabled (the
existing `ground.y` engine primitive and motion integrator already
handle Y clamping). The schema already supports `y_size` as optional;
the missing piece is stating the default clearly.

**Required fix**: the ADR must resolve open question #2 explicitly.
Recommended decision: `y_size` defaults to `null` / `0` (disabled);
Y is snapped only when `y_size` is explicitly set. Add this to the
schema description and update the `snap_position` sketch accordingly:

```gdscript
var y_size_raw = c.get("y_size", null)
if y_size_raw == null or float(y_size_raw) <= 0.0:
    result_y = pos.y  # pass through unchanged
else:
    result_y = origin[1] + round((pos.y - origin[1]) / float(y_size_raw)) * float(y_size_raw)
```

This is a one-line schema clarification + one sketch update; low effort.

#### Condition 3 — Post-mortem gate hardening is incomplete

The motivating bug ("things you build all are in weird locations") has
a root cause: the content-designer pipeline (both `yume-content-designer`
and `yume-level-designer`) produces continuous-float coordinates and
arbitrary yaws, and there is no enforcement gate that detects when a
game has opted into grid but its authored positions are not on-grid.

The ADR's migration plan (step 2, line 413) says "author re-pass" as a
one-time fix for Aldenmere. This is correct for v1, but the same bug
class will recur on every future game that opts into a grid and then
has new content authored at fractional positions by those skills.

The `snap_initial: true` default means world-load auto-corrects — so
the bug class does not recur at runtime. However, position drift in
source JSON (authored at (12.347, 0, 47.918) when grid is 2m) wastes
level-designer intent and makes `tests.json` assertions ambiguous until
`snap_initial` re-aligns them.

**Required**: before closing this ADR as `accepted`, one of the
following gates must land:

Gate A (preferred): add a `validate_grid_alignment.py` static validator
in `tools/` that checks: for any game with `scene.json:grid.size` set,
every non-exempt entity's position in `entities/*.json` and
`levels/*/entities/*.json` is within 0.01 of a grid cell boundary.
Exits 1 in `--strict` mode. Wired into the content-designer skill
checklist as a pre-handoff check.

Gate B (acceptable if Gate A is out of scope for the engine session):
add a warning in `GridSnap.should_snap()` (or in World.gd at spawn
time) that logs a `push_warning("[grid] entity <id> position drift
<delta> from nearest cell — consider authoring at grid coordinates")`
when the snapped position differs from the authored position by more
than `0.1 * size`. This at least surfaces the drift at runtime so the
QA log catches it.

Gate B is weaker (runtime-only, not static) but is zero extra tooling
and lands in the same engine session.

**Required**: the ADR must name which gate lands and in which session.

---

### Non-blocking observations (implementation notes for the engine builder)

**Q3 (composability with ADR 0037 `build_place` — snap before
validation)**: the ordering is correct. Snap → predicate means
`no_overlap` checks the snapped cell, not the raw cursor float.
Two entities aimed at the same sub-cell position will both snap to
the same cell, and `no_overlap` will correctly fail the second
placement. This is the intended Sims-style behavior.

**Q4 (backward-compat sentinel — `test_no_grid_block_unchanged`)**: the
six unit-test sections are sufficient. The sentinel test explicitly
verifies 13-demo path. Accepted.

**Q6 (visual gate split — `grid_overlay.gd` gated, `grid_snap.gd`
ungated)**: correct. Pure math modules do not require visual capture.
Renderer modules require `--capture` + visual-designer review per
`.claude/rules/engine-scripts.md`. The ADR states this explicitly.
No concern.

**Q7 (predicate-set cap)**: grid is not a predicate; it is a
pre-validation transform. The predicate vocabulary (no_overlap,
ground_buildable, owner_in_range, boundary_check) is unchanged.
No concern.

**Q8 (save/load re-snap on load)**: acceptable for v1. One edge case
not called out in the ADR: if a save was written after world-load
(positions already snapped), and then the game's `grid.size` changes
between saves (e.g. a patch doubles grid from 2m to 4m), re-snap on
load will move entities to the new grid. This is a future authoring
hazard, not a v1 bug — the ADR correctly defers per-level grid (ADR
0042) where this matters most. No blocking concern.

**Q9 (two-system divergence — state.position vs entity.position)**: the
ADR claims both are written atomically. The implementation sketch
writes `inst.state["position"]` but does NOT show the corresponding
`entity.position` (Godot Node transform) update. In `_spawn_initial`,
the entity's Node transform is typically set from `state.position`
during spawn — the order of operations in `world.gd::load_entities_file`
determines whether snapping `inst.state["position"]` before the spawn
call is sufficient, or whether a second write to the entity's transform
is needed post-spawn. The implementer must verify this trace in
`_spawn_initial` and add a comment confirming atomicity. Not a blocking
condition (the existing spawn path already syncs transform from
state.position), but the ADR sketch should be explicit.

**Q10 (performance — ~10ms world-load snap for 1000 entities)**: the
ADR's estimate is plausible. `should_snap()` is one dict lookup + one
array-contains per entity — negligible. The one-time cost on load is
acceptable per the engine's existing O(N) spawn-loop budget. No concern.

**Alternative E (per-level grid deferred to ADR 0042)**: the v1
decision to keep grid at scene scope is correct. The per-level extension
is a clean future ADR boundary. No concern.

---

### Conditions summary

Before merge:

1. **Must-fix**: resolve the `env.get("scene", {})` structural defect.
   Update the implementation sketch to use a concrete env key (e.g.
   `env["scene_grid"]` from `_build_env()`) or an on-demand read
   pattern. State which option is chosen in this ADR.

2. **Must-fix**: resolve open question #2 explicitly. Default Y-snap to
   disabled; document in schema. Update snap_position sketch.

3. **Must-land before accepted**: name and commit to a post-mortem gate
   (Gate A static validator in `tools/` OR Gate B runtime warning in
   `grid_snap.gd`). Document which session the gate lands in.

After all three conditions are met and the tests pass (`passed: N
failed: 0`), change status to `accepted`.

