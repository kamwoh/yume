# ADR 0040 — Camera-relative WASD across all camera modes

_Date: 2026-05-10_
_Status: revise → accept-with-conditions (2026-05-10) — blocking defect + 3 conditions resolved in revision below; ready for engine session_

## Context

Empirical case (2026-05-10, Aldenmere Phase 1 playtest): the user
asked to debug WASD diagonals. The scenario tests showed engine
motion was correct in world coordinates (13/13 pass) — but the
visual capture revealed that the iso camera projects world axes
onto screen at 45°, so:

- World −Z (W key in current world-frame WASD) → screen UP-RIGHT
- World −X (A key) → screen UP-LEFT
- W+A pressed simultaneously → world NW direction → screen UP

The diagonal-key combinations collapse to cardinal screen directions
because the screen-projection of the world's NW direction is straight-
up. Conversely, pressing W alone gives diagonal-up-right motion on
screen — counter-intuitive for players used to Stardew/Diablo/
Hades-style WASD (where W = forward = up on screen regardless of
camera angle).

Yume's WASD lib bundle (`@lib.input_bundles.wasd_with_fp_variant`)
already has **two camera-mode variants**:

- World-frame (default, fires when `camera_mode != first_person_3d`):
  W = world −Z, A = world −X, etc. Always compass-aligned.
- First-person (fires when `camera_mode == first_person_3d`): uses
  `velocity_add_relative` reading `actor.state.facing` (mouse-driven).
  W = "where you're looking forward."

The gap: **isometric_3d, third_person_3d, and top_down_3d (with mouse
yaw) have no camera-relative variant.** Iso ships with the world-
frame variant, producing the perception bug.

This ADR adds the missing camera-relative variants for orthographic
cameras (isometric_3d, top_down_3d) — same primitive shape as the FP
variant, but with a fixed yaw determined by the camera mode rather
than a mouse-driven facing.

## Decision

Three coordinated changes:

### 1. Engine: extend `velocity_*_relative` effects with optional `facing` override

`effect_apply.gd::_velocity_set_relative` and `_velocity_add_relative`
currently read `actor.state.facing` (set by mouse-look in FP/TP modes)
for the yaw used to convert (forward, strafe) → world (x, z). Add an
optional `facing` parameter that, when present, overrides the
actor.state.facing read:

```jsonc
{
  "type": "velocity_add_relative",
  "target": "actor",
  "forward": 3.0,
  "strafe": 0,
  "facing": 0.7853982    // π/4 — fixed iso camera yaw; optional
}
```

When `facing` is omitted (existing behavior), reads
`actor.state.facing`. This is non-breaking — every existing rule
keeps working.

**Strafe-sign correction (per tech-director Condition 1, 2026-05-10):**
the existing engine has a sign-discrepancy between
`_velocity_set_relative` (`effect_apply.gd:470` —
`sx = cos(facing) * strafe`) and `_velocity_add_relative` (`:499` —
`sx = -cos(facing) * strafe`). The signs are negated. Iso variant
rules use `strafe=0` so this doesn't manifest immediately, but it
will surface for any future rule that uses non-zero strafe with
`_add_relative` (e.g., third-person strafe).

Fix: harmonize `_velocity_add_relative` to match
`_velocity_set_relative`'s convention:
```gdscript
# effect_apply.gd::_velocity_add_relative — line 499 fix
var sx := cos(facing) * strafe   # was: -cos(facing) * strafe
var sz := -sin(facing) * strafe  # was: sin(facing) * strafe
```

Add a unit test `velocity_add_relative_strafe_sign` that confirms
strafe at facing=0 produces world +X (east) for both _set_ and _add_
variants.

### 2. Engine: per-tick velocity zero opt-in

For ortho cameras with camera-relative WASD, diagonals require
`velocity_add_relative` (so two simultaneously-held keys' contributions
sum into the diagonal direction). Without a per-tick reset, velocity
would grow unbounded. FP mode handles this via `state.drag` —
orthographic floor-walkers don't typically use drag (it makes movement
feel sluggish).

Add an opt-in flag on the actor: `state.zero_velocity_pretick: true`.
Engine's `world.gd::advance_one_tick` zeros velocity for any actor
with this flag BEFORE `scheduler.tick()` runs. After the input phase's
rules add their contributions, the velocity is exactly the sum of
held-this-tick directions.

**Defect resolution (per tech-director, 2026-05-10):** the existing
per-axis idle-stop logic in `_poll_input` reads the actor's velocity
each frame (60Hz) and queues `stop_x`/`stop_y` when the relevant axis
key isn't held AND the velocity component is non-zero. With
`velocity_add_relative` setting iso-W velocity to `(-2.12, -2.12)`,
`_poll_input` between ticks sees `vx ≠ 0` AND no E/W key held →
queues `stop_x`. The scheduler fires `stop_x` LAST in input phase
(after `move_north`) → wipes x-component → W produces pure world-N
instead of world-NW.

**Fix**: in `_poll_input`, when the actor has
`state.zero_velocity_pretick=true`, SUPPRESS per-axis idle stops
(stop_x / stop_y / legacy stop). The pretick zero already handles
the "no input → zero velocity" semantic — the per-axis stops were
designed for a velocity_set world-frame model that doesn't apply to
the camera-relative add-and-pretick-zero model.

```gdscript
# world.gd::_poll_input — guard the per-axis stop block
var actor_ent = entities.get(actor_id, null)
if actor_ent is Entity:
    var pretick_zero := bool((actor_ent as Entity).get_state("zero_velocity_pretick", false))
    if not pretick_zero:
        # Existing per-axis idle stop logic (stop_x / stop_y).
        # ...
```

This is non-breaking: world-frame WASD demos don't opt into
`zero_velocity_pretick` so the existing per-axis stop logic still
runs for them.

### 3. Engine: post-input speed clamp

After the input phase fires `velocity_add_relative` rules, clamp the
actor's velocity magnitude to `state.max_speed`. Lets W+D (which
adds to magnitude √2 × per-key speed) cap at the same walking speed
as W alone, instead of walking 41% faster diagonally.

**Default per tech-director tightening (2026-05-10): `max_speed`
default is `INF` (clamp DISABLED) when the state field is absent.**
The previous draft defaulted to 3.0, which would silently cap any
opted-in actor that hadn't declared its own max_speed. The new
default makes the clamp explicit-opt-in: actors that need a speed
cap declare it; actors that don't (e.g., projectiles, mounted
travelers) are unaffected.

```gdscript
# After scheduler.tick(), before motion integration:
for actor with state.zero_velocity_pretick=true:
    var vel = actor.get_velocity()
    var max_s = float(actor.get_state("max_speed", INF))
    if max_s < INF and vel.length() > max_s:
        actor.set_velocity(vel.normalized() * max_s)
```

### 4. Lib bundle: iso variant rules

Add 4 isometric_3d-mode WASD rules to
`data/lib/input_bundles/wasd_with_fp_variant.json`, gated on
`camera_mode_eq: "isometric_3d"`. They use `velocity_add_relative`
(same shape as the FP variant) with `facing: π/4`:

```jsonc
{
  "id": "lib_wasd_move_forward_iso",
  "trigger": {"type": "input", "action": "move_north"},
  "query": {"tags_all": ["world_clock"], "state": {"camera_mode_eq": "isometric_3d"}},
  "effect": {"type": "velocity_add_relative", "target": "actor",
             "forward": 1.5, "strafe": 0, "facing": 0.7853982}
}
```

Per-key contribution is `1.5` (half the max speed of `3.0`) so that
W+D summed magnitude `1.5 * √2 ≈ 2.12 < 3` (within speed limit before
clamp) and W alone gives magnitude `1.5` — slow when you're walking
straight. Then the speed clamp normalizes UP to max_speed=3 when
the input vector reaches that magnitude. Result:

- W alone: input mag = 1.5, clamped to 3 (normalized) → world NW at speed 3
- W+D: input mag = 2.12, clamped to 3 (normalized) → world N at speed 3
- W+A+D (impossible but for robustness): clamped to max_speed

Wait — clamp to max scales UP. The right convention is: per-key
contribution = max_speed (3.0); sum can exceed max; clamp DOWN to
max_speed. So:

- W alone: forward=3.0, strafe=0 → magnitude 3, no clamp. World NW at speed 3.
- W+D: contributions sum to (0, -4.24), magnitude 4.24 > 3 → clamp to (0, -3). World N at speed 3. ✓
- W+A: contributions sum to (-4.24, 0), magnitude 4.24 → clamp to (-3, 0). World W at speed 3. ✓

Same lib bundle pattern. Update `forward: 3.0` per rule.

### 5. Aldenmere opt-in

Player entity's `state_init` gains `zero_velocity_pretick: true` +
`max_speed: 3.0`. Camera mode is already `isometric_3d` via the
`iso_top_down` preset. The 4 iso variant rules fire; the world-frame
rules don't (see narrowing below).

### Camera-mode coverage — explicit per-mode queries (per Condition 3)

Tech-director identified that the original ADR's narrowing of
world-frame rules from `camera_mode_ne: first_person_3d` to
`camera_mode_eq: top_down_3d` would break `demo_merchant`, which
V-cycles through `top_down_3d → third_person_3d → first_person_3d`.
Third-person mode would lose WASD entirely under that narrowing.

Resolution: use `camera_mode_in: [top_down_3d, third_person_3d]`
for the world-frame rules. Third-person uses world-frame WASD
(player faces a yaw via mouse but keys still address compass
directions) — preserves the existing demo_merchant behavior.

Final coverage table:

| Camera mode | Variant rules | Effect type | Facing source |
|---|---|---|---|
| `top_down_3d` | world-frame | `velocity_set` per-axis | n/a (axis-aligned) |
| `third_person_3d` | world-frame | `velocity_set` per-axis | n/a (compass keys) |
| `isometric_3d` | iso variant | `velocity_add_relative` | constant π/4 |
| `first_person_3d` | FP variant (existing) | `velocity_add_relative` | actor.state.facing (mouse) |

Future modes (quarter-iso, side-scroll, etc.) follow the same
pattern. Lib bundle structure: 4 directional × 4 camera modes = 16
rules + 3 stop rules + 2 legacy rules ≈ 21 total (was 13). The
cleanness is per-mode explicit.

## Consequences

### Positive

- **W = up on screen in iso mode.** WASD feels intuitive — Stardew /
  Diablo / Hades convention. The biggest UX win.
- **Diagonal pairs combine correctly.** W+D = screen up-right (world
  N), W+A = up-left (world W), etc. Matches player intuition.
- **All camera modes covered explicitly.** No more "iso uses world-
  frame and players have to adapt" gap.
- **Same primitive shape as FP variant.** Engine extension is small
  (one optional param + one zero-pretick flag + one speed clamp) —
  no new effect types.
- **Backward-compat.** Existing 13 demos don't opt into
  `zero_velocity_pretick` AND don't use `iso_top_down` camera, so
  their world-frame rules still fire unchanged. Aldenmere is the
  sole v1 opt-in.
- **Composable with grid placement (ADR 0038).** Camera-relative
  motion + grid-aligned spawns play together cleanly.

### Negative

- **Lib bundle grows.** 13 → ~20 rules. Each new camera-mode
  variant adds 4 rules. Manageable; future modes (quarter-iso,
  back-view, etc.) follow the same pattern.
- **Speed clamp adds one engine pass per tick.** Actor velocity
  iteration before motion integration. O(N actors). Negligible
  cost.
- **Existing scenario tests' diagonal expectations may need updates.**
  Current `wasd_diagonal_w_plus_a_NW` expects player to end NW of
  spawn. With camera-relative iso WASD, W+A → world W (pure −X),
  not NW. Aldenmere's tests need migration. World-frame demos
  (chess, sokoban, top-down farming) keep their tests verbatim.

### Neutral

- **No new effect types.** Just an optional param on existing
  effects + one flag.
- **Save/load (ADR 0010)**: `zero_velocity_pretick` is just a state
  field; serializes/restores naturally.

## Alternatives considered

### A) Engine-side input rotation in `_poll_input`

Read camera_mode + scene.json, rotate the (W/A/S/D) input vector by
the camera yaw before queueing into scheduler. World-frame rules then
fire with rotated bindings.

Rejected:

- Mixes input-policy with input-routing in engine code. The lib
  bundle is the right home for "what does W do under camera mode X."
- Doesn't compose with future input-mode variants (e.g., ASDF, JKL;,
  D-pad).
- Adds an engine state machine for input rotation that has to be
  kept in sync with camera changes.

### B) New effect types `velocity_set_camera_relative` etc.

Separate effects that read camera config directly. Rejected because:

- Doubles the velocity vocabulary; existing pattern (FP variant)
  already handles this with optional facing override.
- ADR 0028 predicate-set-cap reasoning: keep effects minimal,
  compose via JSON.

### C) Per-game `input_mode` flag in scene.json

Single flag toggles all camera-relative behavior. Rejected:

- Each camera mode has different needs (FP = mouse-driven,
  iso = fixed-yaw, top-down = no rotation). One flag can't capture
  it.
- The lib bundle's per-camera-mode variant pattern already handles
  this; just extend it.

### D) Switch Aldenmere to `top_down_3d` camera

User vetoed earlier ("why you change my camera view"). Iso is the
intended Aldenmere aesthetic. Rejected.

## References

- ADR 0001 — seven primitives + interpreter (this is interpreter-
  scope, not new effect type)
- ADR 0027 — cross-game JSON reuse (`@lib.input_bundles` pattern)
- `data/lib/input_bundles/wasd_with_fp_variant.json` — existing
  pattern, extended
- `godot/scripts/engine/effect_apply.gd::_velocity_set_relative` —
  refactor target
- `godot/scripts/engine/world.gd::advance_one_tick` — site of
  pretick velocity zero
- 2026-05-10 user feedback: *"i think it should follow the camera
  mode"* — the empirical trigger

## Test plan

Six scenario tests in Aldenmere `tests.json`:

| Test | Verifies |
|---|---|
| `cam_rel_wasd_w_alone_iso` | `hold move_north for 1.5s` → player position.x < 5 AND position.z < 5 (world NW direction at speed 3) |
| `cam_rel_wasd_w_plus_d_screen_up_right` | `hold [move_north, move_east] for 1.5s` → position.x ≈ 5 AND position.z < 5 (world N, pure −Z) |
| `cam_rel_wasd_w_plus_a_screen_up_left` | `hold [move_north, move_west] for 1.5s` → position.x < 5 AND position.z ≈ 5 (world W, pure −X) |
| `cam_rel_wasd_a_plus_s_screen_down_left` | similar; world S direction |
| `cam_rel_wasd_s_plus_d_screen_down_right` | similar; world E direction |
| `cam_rel_speed_clamp` | `hold all 4 for 1s` → velocity magnitude ≤ max_speed (clamped) |
| `cam_rel_wasd_release_key_stops` | `hold W for 1.5s; wait 0.5s` (no key) → velocity magnitude ≤ 0.01. Catches Defect #1's bug class — verifies the per-axis stop suppression works AND pretick zero correctly returns velocity to zero on key release. |

Plus 3 unit-test sections in `test_runner.gd` for the new engine pieces:

| Test | Verifies |
|---|---|
| `velocity_relative_facing_override` | `velocity_set_relative` with explicit `facing` param ignores actor.state.facing |
| `pretick_velocity_zero` | actor with `state.zero_velocity_pretick=true` has velocity zeroed at start of advance_one_tick |
| `speed_clamp` | actor velocity magnitude clamped to `state.max_speed` after input phase |

## Implementation sketch

```gdscript
# effect_apply.gd::_velocity_set_relative — facing override
static func _velocity_set_relative(e, env, ctx) -> void:
    var ent = _target(e, env, ctx)
    if ent == null: return
    var fwd := float(_value(e.get("forward", 0), ctx, env))
    var strafe := float(_value(e.get("strafe", 0), ctx, env))
    # NEW: optional facing override; falls back to actor.state.facing.
    var facing: float
    if e.has("facing"):
        facing = float(_value(e["facing"], ctx, env))
    else:
        facing = float(ent.get_state("facing", 0.0))
    # ... rest unchanged
```

```gdscript
# world.gd::advance_one_tick — pretick zero + post-input clamp
func advance_one_tick() -> void:
    # NEW: pretick velocity zero for opt-in actors.
    for id in entities.keys():
        var ent = entities[id]
        if ent is Entity and ent.get_state("zero_velocity_pretick", false):
            var vel = ent.get_velocity()
            if vel is Vector2:
                ent.set_velocity(Vector2.ZERO)
            elif vel is Vector3:
                ent.set_velocity(Vector3.ZERO)
    if actor_manager != null:
        actor_manager.tick_policies(scheduler.env)
    scheduler.tick()
    # NEW: post-input speed clamp for opt-in actors.
    for id in entities.keys():
        var ent2 = entities[id]
        if ent2 is Entity and ent2.get_state("zero_velocity_pretick", false):
            var v = ent2.get_velocity()
            var max_s = float(ent2.get_state("max_speed", 3.0))
            if v is Vector2 and v.length() > max_s:
                ent2.set_velocity(v.normalized() * max_s)
            elif v is Vector3 and v.length() > max_s:
                ent2.set_velocity(v.normalized() * max_s)
    # ... rest unchanged
```

```jsonc
// data/lib/input_bundles/wasd_with_fp_variant.json — add iso variants
{
  "id": "lib_wasd_move_forward_iso",
  "trigger": {"type": "input", "action": "move_north"},
  "query": {"tags_all": ["world_clock"], "state": {"camera_mode_eq": "isometric_3d"}},
  "effect": {"type": "velocity_add_relative", "target": "actor",
             "forward": 3.0, "strafe": 0, "facing": 0.7853982}
},
// ... 3 more directions
```

```jsonc
// data/demo_aldenmere/entities/player.json — opt in
{
  "state_init": {
    "zero_velocity_pretick": true,
    "max_speed": 3.0,
    "...other fields..."
  }
}
```

## Migration plan

1. Engine session: extend velocity_*_relative effects + add advance_one_tick
   pretick/clamp + tests.
2. Lib bundle session: add 4 iso variant rules + narrow existing
   world-frame rules to `camera_mode_eq: top_down_3d` (so iso doesn't
   double-fire).
3. Aldenmere session: opt in player + migrate scenario test
   expectations to camera-relative diagonals.
4. Visual capture: confirm W = up-on-screen empirically.

Estimated effort: 1 engine session, 1 content session.

## Open questions for tech-director review

1. **Per-tick zero is opt-in via state field — or scene-config?**
   ADR proposes state.zero_velocity_pretick on the actor. Alternative:
   scene.json `input_policy: "camera_relative"` flag. Lean: actor
   state, since multi-actor games might mix policies (player =
   relative, NPCs = world-frame for AI pathing).
2. **Speed clamp default**: max_speed=3.0 hardcoded fallback. Should
   this read from a scene-wide default? Lean: actor state (already
   per-actor for varied speed types like player vs. mounted).
3. **Existing world-frame rules need narrowing.** Current rules
   gate on `camera_mode_ne: first_person_3d`. After adding iso
   variants, they need `camera_mode_eq: top_down_3d` — otherwise
   both fire in iso mode. Migration step.
4. **Test expectations migration.** Aldenmere's 7 WASD scenarios
   currently expect world-frame results. They'll need updates for
   the new iso behavior. Same session as the lib bundle update.
5. **Backward-compat sentinel.** Confirm: top_down_2D demos
   (sokoban, chess) don't opt into zero_velocity_pretick AND don't
   set camera_mode to iso → they take the existing world-frame path
   unchanged. Verified by 13/13 demo tests passing post-migration.

## Status

Proposed 2026-05-10. Awaiting tech-director review.

---

## Tech-director review

_Date: 2026-05-10_
_Reviewer: yume-tech-director_
_Verdict: **REVISE** — one blocking defect, three conditions required before re-review_

### Invariant sweep (all four greps run against current engine tree)

**Invariant #1 (no entity ids hardcoded in engine):** PASS. No changes
touch `entities.get("<literal>")` patterns. The pretick-zero loop in
`world.gd::advance_one_tick` iterates all entities and reads
`zero_velocity_pretick` via `get_state()` — treating id as opaque,
field name as content-controlled. Clean.

**Invariant #2 (no semantic effect types):** PASS. No new effect type
strings are introduced. `velocity_add_relative` and
`velocity_set_relative` are existing primitives being extended via an
optional parameter. The iso lib bundle rules use only existing effect
types. Clean.

**Invariant #3 (no entity subclasses):** PASS. No `extends Entity`,
no `class_name Agent|Item|Projectile`. Not applicable to this change.

**Invariant #5 (queries are first-class):** PASS. No shortcut helpers
introduced.

**Invariant #8 (engine = primitives + interpreter):** The two engine
additions — the optional `facing` parameter and the pretick-zero/speed-
clamp pass — are examined below under "Engine pass review."

---

### Defect #1 (BLOCKING) — stop_x/stop_y interaction with velocity_add_relative

**Classification:** Design defect. Not caught by unit tests because no
test exercises the 60Hz `_poll_input` + 10Hz `advance_one_tick`
interleave. Verified by tracing `world.gd::_poll_input` (lines 1130–1167)
against `phase_scheduler.gd::_phase_input` (lines 232–243).

**The defect:**

`_poll_input` runs at 60Hz in `_process`. For each frame where W is
held but no E/W key is held, it queues:
1. `move_north` (hold action, queued first)
2. `stop_x` (per-axis idle, queued after the hold-actions loop, line
   1164 — fires when `ew_held == false AND absf(vx) > 0.001`)

The velocity check for `stop_x` reads the CURRENT entity velocity —
which, between ticks, is whatever the last `advance_one_tick` left it
at. In iso mode, pressing W causes `velocity_add_relative(forward=3,
facing=π/4)` to set velocity to approximately `(-2.12, -2.12)` world
units (W rotated 45° into world NW). That velocity persists across the
~9 frames between ticks. So `vx ≈ -2.12 > 0.001` → `stop_x` IS
queued every frame between ticks.

`PhaseScheduler._phase_input` does not deduplicate — it fires all
queued events in FIFO order (lines 234–243). Within each frame, the
queue order is `move_north` first, then `stop_x`. Over 9 frames,
the queue accumulates ~9 `move_north` then ~9 `stop_x` events in
interleaved order: `[N, stop_x, N, stop_x, ..., N, stop_x]`. The
final event processed is `stop_x` → `velocity_set x=0`.

Net result in `advance_one_tick` for tick N+1 with W held:
1. Pretick zero: velocity = (0, 0)
2. ~9 × velocity_add_relative(W): each ADDS (-2.12, -2.12)
   velocity accumulates — but also:
3. ~9 × velocity_set x=0 (stop_x): fires between each add
4. Final event: stop_x → velocity x-component = 0
5. Resulting velocity: (0, accumulated-z) = pure world-south motion

The iso W key produces pure world-south motion, not world-NW. The
pretick zero does not help here because the stop_x check reads
velocity BEFORE the pretick zero runs (different call sites:
`_poll_input` in `_process`, pretick zero in `advance_one_tick`).

**The ADR is silent on this interaction.** Its migration step 2
narrows the world-frame WASD rules to `camera_mode_eq: top_down_3d`
but does NOT address the stop_x/stop_y rules, which have no camera-
mode gate in the existing lib bundle.

**Required fix before re-review:**

Either (A) add `camera_mode_ne: isometric_3d` (and any other iso-
relative modes) to the `lib_wasd_stop_x` and `lib_wasd_stop_y` rule
queries, and add iso-specific stop rules for the iso variant that
zero the full vector (since pretick zero makes explicit stop rules
redundant — if no key is pressed, pretick zero already zeros velocity
before the scheduler runs, so a full-vector zero is safe); OR

(B) Make the pretick-zero semantics subsume stop_x/stop_y entirely for
opted-in actors: when `zero_velocity_pretick=true`, suppress stop_x
and stop_y injection in `_poll_input` for that actor (check the flag
at lines 1155–1167 and skip per-axis stop injection). This is the
cleaner engine path — pretick zero already handles the "no input →
velocity becomes zero" case without needing stop_x/stop_y at all.

Option B is preferred: it eliminates the interaction class entirely
for opted-in actors and aligns with the stated design intent
("without a per-tick reset, velocity would grow unbounded — FP mode
handles this via state.drag; orthographic floor-walkers don't
typically use drag"). The pretick zero IS the drag replacement.
Adding a `if actor has zero_velocity_pretick: continue` guard in
`_poll_input`'s stop injection block is a small, surgical change with
clear semantics.

The ADR must be updated to describe which stop mechanism takes over
for opted-in actors. If option B is chosen, add it to Decision §2
(engine: per-tick velocity zero) and update the implementation sketch.

---

### Condition #1 — `facing` parameter override: sign inconsistency between
the two `_velocity_*_relative` implementations

**Classification:** Pre-existing bug surface exposed by the new
`facing` override.

`effect_apply.gd` lines 456–480 (`_velocity_set_relative`) and lines
491–510 (`_velocity_add_relative`) implement strafe differently:

- `_velocity_set_relative` (line 470): `sx = cos(facing) * strafe`
- `_velocity_add_relative` (line 499): `sx = -cos(facing) * strafe`

The sign is negated between the two implementations. This was caught
previously (the FP strafe-direction bug fix 2026-05-08, noted at line
467 of `effect_apply.gd`), but the fix was applied only to `_set`
and not propagated to `_add`. The ADR adds `facing` override to both
functions — if the same `facing` value produces mirrored strafe
directions depending on which variant fires, the iso lib bundle rules
will produce inconsistent strafe behavior.

The ADR's implementation sketch (lines 280–292) only shows the `_set`
variant. The `_add` variant sketch is not shown. Before re-review,
verify that the strafe sign is consistent in both implementations
(one is wrong; the correct sign should follow from the strafe-right
definition: at `facing=0`, strafe right → world +X → `sx = cos(0) *
strafe = strafe` — positive, which matches `_set`'s convention).
If `_add` has the wrong sign, fix it as part of this ADR (it's the
same bug class).

This is a condition, not a blocker in isolation, because the iso iso
rules use `forward` only (strafe=0 for cardinal W/A/S/D). But any
future diagonal shortcut (e.g., `NE = forward=1, strafe=1`) would
silently produce the wrong direction. Fix the sign in `_add` as part
of the implementation and add a unit test that drives strafe with both
variants and confirms world-space direction.

---

### Condition #2 — ADR must specify iso stop behavior explicitly

The ADR's "Consequences → Negative" section (lines 188–191) notes
"existing scenario tests' diagonal expectations may need updates" but
does not describe what replaces stop_x/stop_y semantics for iso actors.
The test plan (lines 257–268) defines six scenario tests but does not
include a "release W while walking, confirm velocity zeroes" scenario.
Without that test, the stop interaction defect (Defect #1) would not
be caught by the planned test suite.

Required additions to the ADR before re-review:
- Describe the chosen stop mechanism for opted-in actors (pretick-zero
  subsumes it, OR camera-mode-gated stop rules).
- Add a seventh scenario test: `cam_rel_wasd_release_key_stops`
  — hold W for 1.5s, release W, wait 0.5s, confirm velocity magnitude
  ≤ 0.01 (stopped cleanly).

---

### Condition #3 — backward-compat audit for demos that cycle camera modes at runtime

The ADR states "13 existing demos" are backward-compatible because
they don't set `camera_mode=isometric_3d`. This is correct for
**static** camera modes. However, `demo_merchant` cycles camera modes
at runtime via V-key rules (confirmed at
`godot/data/demo_merchant/game/rules.json` lines 42–74): it cycles
through `top_down_3d → third_person_3d → first_person_3d → (empty)`.

After migration step 2 (world-frame rules narrowed to
`camera_mode_eq: top_down_3d`), the merchant's FP mode still works
(FP rules gated on `camera_mode_eq: first_person_3d`). But
`third_person_3d` mode currently works because `camera_mode_ne:
first_person_3d` catches it. After narrowing to `camera_mode_eq:
top_down_3d`, the merchant in third_person_3d mode loses WASD
entirely (neither world-frame nor camera-relative rules fire).

The ADR states "third_person_3d mode: already supported via FP-variant
pattern (mouse-driven facing). Same rules cover it." This is true —
the FP rules fire when `camera_mode_eq: first_person_3d`, not
`third_person_3d`. Third-person does NOT have its own camera-relative
rules in the current bundle. If the merchant V-cycles to
`third_person_3d` post-migration, WASD stops working for merchant.

Required before re-review: audit the lib bundle migration and confirm
whether `third_person_3d` mode needs explicit WASD rules added as
part of this ADR (it uses mouse-driven facing, so the FP pattern
applies — it should reuse `velocity_add_relative` with facing from
`actor.state.facing`, same as FP, just gated on
`camera_mode_eq: third_person_3d`). Alternatively, explicitly gate
the world-frame rules on `camera_mode_in: [top_down_3d,
third_person_3d]` if the third-person world-frame behavior is
acceptable. Either way, the ADR must call this out — it cannot be
deferred silently.

---

### Engine pass review (Invariant #8 check)

**`facing` optional parameter on `velocity_*_relative`:** Clean.
The parameter is a JSON-authored value that overrides an actor state
field. The engine reads it generically (`e.has("facing")` → use it,
else fall back to `actor.state.facing`). No genre logic. No hardcoded
semantics. This is exactly "expose Godot's capability through JSON-
declarative primitives." Passes Invariant #8.

**`zero_velocity_pretick` engine pass:** This is a new engine pass
inside `advance_one_tick` gated on an actor state field. The concern
is whether this is a generic primitive or domain-specific behavior.

Judgment: PASS with observation. The behavior — "zero this entity's
velocity at the start of each tick if the entity has opted in" — is
fully generic. Any game (chess with sliding pieces, ecology with
wind-drift, farming with vehicle speed) could use it. It is
analogous to `state.drag` (which the motion integrator already reads
as a per-actor state field) but applied at the tick boundary rather
than the frame boundary. The opt-in via state field (not scene-level
config, per the ADR's own reasoning at lines 360–363) is correct —
multi-actor games can mix policies.

The speed clamp is similarly generic — it is a velocity-magnitude
bound applied post-input, identical in concept to max_velocity caps
that every physics engine exposes. Gated on the same flag to avoid
touching actors that don't need it.

**One observation (not a blocker):** The speed clamp uses the same
`zero_velocity_pretick` flag as its gate (implementation sketch lines
293–319). This couples two logically independent behaviors under one
flag. A pretick-zero actor that does NOT want speed clamping (e.g.,
a thrown projectile that accumulates velocity from multiple rules but
shouldn't be capped) cannot opt out of the clamp. Consider whether a
separate `state.max_speed` being absent (null) should suppress the
clamp rather than defaulting to 3.0. The implementation sketch at
line 295 uses `get_state("max_speed", 3.0)` — if `max_speed` is
absent from state_init, it defaults to 3.0 and will silently clamp
the actor. This default should be `INF` or the clamp should be
suppressed when `max_speed` is absent. Add this to the ADR decision.

---

### ADR format check

- Status: `proposed` — correct for pre-review.
- Context: specific (empirical playtest case cited with date,
  perception bug described analytically). Good.
- Alternatives considered: three alternatives listed with rejection
  reasoning. Alternative D (camera switch) cites user veto. Good.
- References: cite ADR 0001, ADR 0027, effect_apply.gd, world.gd.
  Add the specific line numbers once implementation is known.
- Test plan: present but incomplete (see Condition #2 — missing
  release-key scenario test).

---

### Post-mortem gate hardening (per `.claude/rules/post-mortem.md`)

The bug class "WASD doesn't follow camera projection" is closed by
the lib-bundle variant pattern. The correct skill gate to harden is
`yume-systems-designer`: when authoring movement rules, the skill
must check "which camera mode is this game using?" and select the
matching input bundle variant. The gate check is:

```
For any game using isometric_3d, third_person_3d, or quarter_iso
camera: does the input bundle include camera-mode-gated
velocity_add_relative rules (NOT world-frame velocity_set)?
If no: the WASD will feel wrong on screen. Use the iso variant pattern.
```

Additionally, the `yume-level-designer` or `yume-asset-designer`
(whoever authors `scene.json` camera config) must be the one who
flags: "this camera mode requires iso-variant WASD." The decoupling
currently means a level-designer can pick `isometric_3d` in
`scene.json` without knowing it requires a different input bundle.
The gate belongs in `yume-asset-designer` SKILL.md under
"Camera mode selection" as a mandatory cross-check: for each camera
mode, cite the required input bundle variant.

---

### Summary

**Verdict: REVISE.**

One blocking defect prevents acceptance:

- **Defect #1:** `stop_x`/`stop_y` rules fire after
  `velocity_add_relative` in the input phase, zeroing the x
  component of camera-relative diagonal motion. The pretick-zero
  design does not protect against this. The ADR must resolve the
  stop mechanism for opted-in actors before implementation begins.

Three conditions must be addressed in the revised ADR text:

1. Fix or confirm the strafe-sign inconsistency between
   `_velocity_set_relative` and `_velocity_add_relative` (lines 470
   vs 499 of `effect_apply.gd`).
2. Add the "release key → confirm stop" scenario test and describe
   the stop mechanism for iso opted-in actors.
3. Audit and resolve third-person mode WASD gap created by narrowing
   world-frame rules from `camera_mode_ne: first_person_3d` to
   `camera_mode_eq: top_down_3d`.

One engine implementation detail to tighten (not a blocker but
required before implementation proceeds):

- `max_speed` absent from `state_init` should default to no clamp
  (`INF`) rather than 3.0, or the clamp should be gated on
  `state.max_speed` being explicitly set.

The core design — `facing` override as optional parameter, pretick
zero as opt-in actor state, speed clamp, lib-bundle variant pattern —
is architecturally sound and passes Invariants #1, #2, #3, #5, and
#8. The defect is in the interaction between the new design and the
existing stop injection mechanism (`_poll_input` lines 1152–1167),
which the ADR did not analyze.

Hand back to systems-designer to resolve Defect #1 and Conditions
1–3. Re-submit for review when ADR status is updated to `revised`.

