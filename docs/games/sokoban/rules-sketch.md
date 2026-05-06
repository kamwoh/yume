# Sokoban — rule sketches + engine gap analysis

_Date: 2026-05-03_
_Designer: yume-systems-designer_
_GDD: docs/games/sokoban/GDD.md_
_Level design: docs/games/sokoban/level-design.md_

## Primitive sufficiency check

- [x] Entity (defs + state + tags + properties)
- [x] Tag (membership: player / box / wall / goal / level_clock)
- [x] Rule (input + tick triggers)
- [x] Trigger (input PRESS-edge for arrow keys; tick for win-check)
- [?] **Effect** — state_set position works, but...
- [?] **Query** — needs "no entity at position X" check, which is the
  hard part
- [x] Relation — could use `placed_on` between box and goal
- [x] Random — not needed

**Critical question**: can existing primitives express "if target cell
is wall, don't move; if box, push if cell beyond is empty; if empty,
move"?

## Approach 1 — Signal + radius query (proposed; engine should support)

When player presses arrow:
1. Input rule fires: emit signal `player_attempt_move` with payload
   `{target_x, target_y, direction}`. No state changes yet.
2. Three signal-trigger rules listen:
   - **wall-blocks-move**: query walls within radius 0.4 of
     (target_x, target_y) using `_origin_position` from payload.
     If any wall matches, set `level_clock.last_move_blocked = 1`.
   - **box-at-target**: query boxes within radius 0.4 of target.
     If found, emit signal `attempt_push` with `{box_id, push_x, push_y}`.
   - **move-into-empty**: tick rule running ON the same phase, after
     above. If `last_move_blocked == 0` AND no `attempt_push` fired:
     state_set player position.
3. Push handling (signal `attempt_push`):
   - Query walls/boxes at (push_x, push_y).
   - If empty: state_set both player and box positions.
   - If blocked: no-op.

**Engine support needed**:
- ✓ Input → emit signal: `emit` effect can write to signal_buffer
- ✓ Signal-trigger query with `_origin_position` from payload —
  Yume already supports this pattern (used in clock-broadcast rules).
- ✓ Multiple rules per signal name — supported.

## Approach 2 — Contact-based collision with discrete velocity (alternative)

Encode movement as a one-tick velocity pulse:
1. Input rule sets player.velocity = (1, 0) for one tick (direction
   based on input).
2. Motion integrator advances position.
3. Collision contact rule (player, wall, radius < 1): revert position.
4. Push contact rule (player, box, radius < 1): also set box.velocity
   for that tick.

**Problems**:
- Motion integrator is continuous; one-tick pulses mean position
  changes by `velocity × delta` not `velocity × 1 cell`.
- Cell-snap on move-complete is fragile.
- Doesn't fit sokoban's discrete-grid model.

**Verdict**: Approach 2 is hacky. Use Approach 1.

## Approach 3 — ADR: new "cell-grid" primitive

If Approach 1 turns out insufficient (e.g. signal context-driven query
doesn't resolve `target_x` from payload as origin), the cleanest fix
is to introduce a primitive expansion:

- New query clause: `at_cell: [x, y]` — returns entities whose
  state.position matches the cell exactly.
- New effect: `move_to_cell: [x, y]` — atomic state_set position
  shorthand.
- These would generalize for ALL grid-based games (chess, sokoban,
  roguelike, turn-based strategy).

**Status**: ADR candidate. Defer until Approach 1 is empirically
ruled out by qa-tester.

## Rule inventory (using Approach 1)

**Input (4 rules)**:
- `arrow_n` — input N: emit `player_attempt_move` payload
  `{target_x: self.state.position.x, target_y: self.state.position.y - 1}`
- `arrow_s/e/w` — symmetric

**Movement resolution (3 rules)**:
- `block_if_wall` — signal `player_attempt_move`: query walls at
  `_origin_position`. If found: state_set
  `level_clock.last_move_blocked = 1`.
- `push_if_box` — signal `player_attempt_move`: query boxes at
  `_origin_position`. If found: emit `attempt_push` with payload
  `{box_id, push_x, push_y}` — where push_x/y is target + direction.
- `move_player` — tick interval 1: if
  `level_clock.last_move_blocked == 0` AND no pending push,
  state_set player position to `level_clock.last_target`.
  (Reset blocked flag and target each tick.)

**Push resolution (2 rules)**:
- `block_push_if_wall_or_box` — signal `attempt_push`: if anything
  at push_x/push_y, set `level_clock.push_blocked = 1`.
- `commit_push` — tick interval 1: if `push_blocked == 0`, state_set
  box.position AND player.position together.

**Win check (1 rule)**:
- `level_clear` — tick interval 1: query for boxes whose position
  matches a goal position (uses spatial index; radius 0.4). Count
  vs total goals; if all on goals: emit `next_level` signal.

**Level transition (1 rule)**:
- `next_level_loader` — signal `next_level`: state_add
  `level_clock.level += 1`. Spawn entities for next level (load from
  level_N entries in instances JSON).

**Restart (1 rule)**:
- `restart_input` — input `restart` (R key press-edge): re-spawn current
  level by signaling `next_level` with same level number.

## Honest assessment

This rule sketch is **complex** for what should be a simple game. The
core reason: existing engine primitives don't elegantly express
"check what's at cell (x, y)." Signal+payload+contact-radius is
a workaround.

**Recommendation**: defer Approach 1 implementation pending a quick
empirical test of whether signal payload → context-driven origin →
radius query actually works. If it does (probably yes — pattern is
used elsewhere), proceed. If not, write the ADR for cell-grid
primitives.

## Engine gap surfaced

The orchestrator hint asked us to flag this if found:

> Sokoban exposed a generic engine limitation: queries can't easily
> express "at this exact cell." The workaround via signal-payload +
> contact-style radius query exists but is verbose. A future ADR
> ("cell-grid primitives") would clean this up for all turn-based
> grid games (chess, sokoban, roguelike combat, turn strategy).

For v1 sokoban: proceed with workaround. Flag as ADR candidate.

---

## v0.1 implementation notes (2026-05-04)

Foundation built: data folder + entity defs + level_1 instances + scene
+ HUD + progression. Smoke test passes (5 defs, 20 entities, level=level_1,
no engine errors). Visual capture confirms 5×5 grid renders correctly
with PBG layout. **Conditional movement rules NOT implemented yet** —
v0.1 ships static instances only.

### Engine concerns surfaced during build

1. **shapes.json doesn't support formulas in primitive fields.** Only
   `$param_name` substitution works. A "generic square" with size param
   requires concrete-sized variants (`tile_32`, `tile_26`) instead of
   one parameterized shape. Added both to `data/shapes.json`. Minor
   asset-design wart; not blocking.

2. **state_set with Array value doesn't auto-evaluate per-element
   formulas.** `_value()` returns Array as-is; only `spawn` has special
   handling for position/velocity formula arrays. This means
   `{"type": "state_set", "field": "position", "value": ["self.state.position.x + 32", ...]}`
   does NOT work as written. **This is a real engine gap for sokoban's
   teleport-on-input movement model.**

3. **`require` clause only validates entities already named in
   context.** Can't easily express "no wall exists at target cell" —
   require needs an entity ID to check, not "scan all entities at
   position." The signal+payload+_origin_position workaround is still
   the right approach but needs empirical validation in v0.2.

### Path forward — two options

**Option A**: Push the signal-based workaround empirically. Steps:
- Input rule emits signal `attempt_move` with `_origin_position` =
  target cell coords + payload `{dx, dy}`
- Signal-trigger rule scans walls at radius 12 of origin → sets clock
  flag if found
- Signal-trigger rule scans boxes at radius 12 → emits `attempt_push`
  with target+dx,dy
- Tick rule commits move IF no flags blocked
- For position teleport: instead of state_set, use spawn+remove
  (despawn old player, spawn new at target). Wasteful but works.

Risk: complex; signal phase ordering and `_origin_position` payload
binding need empirical validation. ~2-4 hours of careful work.

**Option B (recommended)**: ADR 0008 — Cell-grid primitives. Add
explicit engine support for grid-based games:
- `state_set` accepts Array values with per-element formula
  evaluation (small change in `_value`)
- New query field `position_at: [x, y]` for "entities at exact
  position" without needing radius+origin gymnastics
- Optional `cell_grid` scene config for snap-to-grid rendering

Risk: real engine work + ADR review. ~1-2 days. But unblocks sokoban,
chess (already in tests but stubbed), tactical RPG, roguelike, any
future grid game cleanly.

I'd push Option B for the long term; Option A for a one-off proof.

### Files added in v0.1

- `godot/data/demo_sokoban/scene.json`
- `godot/data/demo_sokoban/world.json`
- `godot/data/demo_sokoban/inputs.json`
- `godot/data/demo_sokoban/hud.json`
- `godot/data/demo_sokoban/progression.json`
- `godot/data/demo_sokoban/world_rules.json` (placeholder)
- `godot/data/demo_sokoban/entities/{player,box,wall,goal,level_clock}.json`
- `godot/data/demo_sokoban/levels/level_1/entities.json`
- `godot/scenes/sokoban_2d.tscn`
- `godot/data/shapes.json` (+`tile_32`, +`tile_26`, +`filled_circle`)
- `captures/sokoban_l1_v0.1.png`

### Status

- v0.1 = playable as a "static art exhibit" (level renders, no
  interaction works yet besides Q to quit and ESC).
- v0.2 = pick A or B above; build movement; ship 8 levels.

## Open questions for content-designer

1. Level transition mechanics — how does state-set on `level_clock.level`
   actually trigger spawning new entities? May need a tick rule that
   queries for entities tagged `level_X` and removes/spawns based on
   current level.
2. Exact signal-driven movement implementation — verify
   `_origin_position` resolves from signal payload in current engine.
   If not, ADR.
3. Grid coordinate system — content-designer should pick: cell
   coordinates (integer) vs world units. Suggestion: use cell × 32 px
   as world coords; renderer displays as discrete-looking sprites.
