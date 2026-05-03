# Sokoban

_Date: 2026-05-03_
_Designer: yume-game-designer_

## One-line pitch

Push boxes onto goal tiles. One step at a time. Don't push them into
corners — there's no undo.

## Aesthetics target

| Category | Why |
|---|---|
| **Challenge** | Spatial puzzle. Solving requires planning. Mistakes (boxes pushed into walls) lock the puzzle out. |
| **Discovery** | Each level teaches a new sub-mechanic or constraint. The "aha" moment when the path clicks. |
| **Submission** | Slow, deliberate pacing. Unhurried. The player thinks, then moves. Not arcade. |

Expressly NOT: Sensation (no juice — calm), Fellowship (single-player),
Narrative, Expression, Fantasy.

## Dynamics intended

- **Search the state space**: each move reaches a new state. Player
  builds a mental map of "from here, can I reach the goal?"
- **Lock-out tension**: pushing a box against a wall corner = stuck.
  No undo in v1; player must avoid traps. Each push is a commitment.
- **Progressive teaching**: level 1 = trivial (1 box, 1 goal, no
  obstacles). Level 6+ = needs ordering of pushes; some configurations
  require the player to circle around a box.
- **Pure deliberation**: no real-time pressure. Game advances ONLY on
  player input. This is critical to the Submission aesthetic.

Randomness: NONE. Every level is hand-designed. Skill comes from
spatial reasoning, not luck.

Typical session: ~30s per level for early levels, 1-3 minutes for
later levels. Total game length: 5-15 minutes.

## Mechanics

### Player verbs

| Verb | Trigger | Effect |
|---|---|---|
| Move N | input arrow-up (PRESS-edge) | If cell N is empty: move there. If cell N has a box AND cell beyond is empty: push the box, then move. Otherwise: no-op. |
| Move S/E/W | similar | symmetric |

### Grid model

- 10×10 cells per level (or smaller; level-designer decides per level).
- Each cell holds 0 or 1 of: player, box, wall.
- Goal tiles are markers on cells; multiple boxes on goals = win.
- Position stored as integer cell coordinates. Movement = +/-1 cell.

### Turn-based cadence (NEW for Yume)

Sokoban is a **strict turn-based** game: the world advances ONLY when
the player presses an arrow key. There is no real-time clock. The
engine currently runs a clock that ticks every `tick_seconds`. For
sokoban we need either:

- `tick_seconds = 0` mode: clock disabled; only manual `tick()` calls
  on player input
- OR: each input action triggers a discrete "advance one step" without
  the clock involved

**Engine gap**: this may require a small engine addition (or it may
just work via input-trigger rules with no tick rules at all). Defer
to systems-designer to identify.

### Win/lose

- **Win condition** (per level): all goal tiles have a box on them.
- **Win condition** (game): final level cleared.
- **Lose condition**: NONE in v1. (Future: limited-moves mode with
  "lose if no moves left and not solved.")
- **"Stuck" detection**: not auto-detected in v1. Player notices and
  presses R to restart. (Future: auto-detect locked states.)

### Level progression

After last goal placed → load next level. After final level → win
screen. Level transitions: state_set the level_clock entity's `level`
state, which queries spawn the new level layout.

### Level progression plan (REV — added per reviewer)

Concrete enumeration of what each level teaches:

| Level | Layout | New mechanic / lesson |
|---|---|---|
| 1 | 1 box, 1 goal, open 5×5 room | Arrow-key movement; understand push |
| 2 | 2 boxes, 2 goals, open 6×6 | Multi-goal; order matters slightly |
| 3 | 3 boxes, 3 goals, U-shape walls | Walls block; push around obstacles |
| 4 | 2 boxes, 2 goals, narrow corridor | Tight space; can't reposition easily |
| 5 | 4 boxes, 4 goals, choke point | Push order critical; one box at a time |
| 6 | 3 boxes, 3 goals, dead-end branches | Avoid dead ends; corner = lockout |
| 7 | 5 boxes, 5 goals, asymmetric layout | Plan ≥5 moves ahead |
| 8 (final) | 4 boxes, 4 goals, "circle" puzzle | Must approach from specific side; rewards spatial reasoning |

Level-designer can fine-tune cell counts, but the **teaching arc is
fixed** — each level introduces something the previous didn't.

### Per-move feedback (REV — added per reviewer)

Audio cues (use Tier 2.6n procedural sounds — see `data/sounds.json`):

| Action | Sound | Reason |
|---|---|---|
| Step (move into empty cell) | `step` (or `pickup` as proxy — soft tone) | Confirms input received; feels purposeful |
| Push (move + push box) | `push` (or `build` as proxy — heavier tone) | Distinct from step; "thunk" of resistance |
| No-op (wall in front) | `error` (low buzz) | Signals "you pressed a key but couldn't move" — important to NOT feel like input was lost |
| Box lands on goal | `pickup` (rising chime) | The satisfying "click" — emotional payoff |
| Box leaves goal | `pop` (falling tone, can reuse `error`) | Slight regret; informative |
| Level clear | `win` | Existing GDD confetti event |

If new sound entries are needed in `data/sounds.json`, asset-designer
will add them. For v1 reuse the existing 10 sounds via `step→pickup`,
`push→build`, `thud→error` mapping.

HUD elements (top-left, calm sans-serif):

- `Level: <N> / 8` — current progress
- `Boxes placed: <K> / <M>` — visual feedback for partial progress
- `Moves: <total>` — soft counter; lets player self-assess "am I lost?"
- `Press R to restart` — persistently visible

The GDD's stated **Submission** aesthetic depends on each push feeling
deliberate and acknowledged. Without per-move feedback, the game feels
silent and player loses the rhythm.

### Stuck-state UX (REV — added per reviewer)

V1 doesn't auto-detect locked states (would require non-trivial
analysis: "is any box pushed into a corner with no goal?"). Instead,
v1 mitigates with:

1. **Persistent restart hint**: HUD shows `Press R to restart` always
   visible (not hidden in a menu).
2. **Move counter**: visible `Moves: 30` lets player self-assess.
   Heuristic: if moves > 50 and no goal placed, player likely stuck.
3. **Level layout pre-checked**: level-designer must verify each level
   is solvable AND has a non-trivial path that's not obviously
   lock-out-prone (e.g., no boxes spawn already in corners).

V2 may add: auto-detect via "any box pushed into wall+wall corner that
isn't a goal" heuristic, prompt `Stuck? Press R`.

## Entity inventory

5-6 defs:

- `player` — the pusher. Has `state.position = [x, y]` cell coords.
- `box` — pushable. Has `state.on_goal = 0/1` (set when on goal tile).
- `goal` — target tile. Has no state, just position.
- `wall` — immovable. Blocks player + boxes.
- `level_clock` — singleton; tracks `level` (1-N), `boxes_on_goals`,
  `total_goals`. Drives win check + level transition.
- (Optional) `ice` — slides boxes/player past until they hit something
  (introduces in level 5+ as new mechanic).

## Rule inventory

~10 rules:

**Input → movement (4 directions × 2 cases = 4 rules with branching, OR
8 rules)**:
- `move_player_n` — input arrow_up; if cell-N is empty: state_set
  position. If cell-N has box AND cell-beyond-N is empty: push box,
  then move. Else: no-op.
- `move_player_s/e/w` — symmetric.

Engine implementation note: the "if cell empty / has box / has wall"
branching needs to be expressed as 3 separate rules with mutually
exclusive `require` clauses, OR one rule with formula-based effect.
Check engine capabilities.

**Goal detection**:
- `box_lands_on_goal` — contact (box, goal, radius 0.1 — exact cell
  match): set box.on_goal = 1, increment level_clock.boxes_on_goals.
- `box_leaves_goal` — opposite: set on_goal = 0, decrement.
  (Could be done with relation + transfer_relation pattern.)

**Win detection**:
- `level_clear` — tick (or signal-based): if boxes_on_goals ==
  total_goals → spawn confetti effects, increment level, reset board.

**Restart**:
- `player_restart` — input R: reload current level (reset all
  positions to level_clock's level layout).

## Honest scope

In scope:
- 6-8 hand-designed levels with progressive difficulty
- Push mechanic with wall + box collision
- Goal-on-place detection + win condition per level
- Restart current level (R key)

Out of scope (explicitly):
- Undo (would need state history)
- Move counter / par moves / stars
- Ice tiles / switches / portals (v2 — flagged for level-designer's
  optional richness)
- Procedural level generation
- Real-time pressure / time limits

## Open questions

- **Q1 Engine cadence?** How does Yume handle a game with NO ticks,
  only inputs? Does `tick_seconds = 0` work? Or do we need an
  "input-only" world mode? **Defer to systems-designer.**
- **Q2 Level reset method?** When player advances or restarts, do we
  remove all entities and respawn from a level template? Or use
  state_set on each entity to reset position? **Cleanest: each level is
  a sub-folder of entity defs OR a single "level_<N>.json" of
  initial_instances; engine despawns + respawns on level change.**
- **Q3 Box on goal: relation vs state?** `box.on_goal = 1` is a state
  flag. Alternatively, a `placed_on` relation between box and goal.
  Either works; state is simpler for v1.
- **Q4 Wall representation: invisible or visible?** Visible walls add
  visual clarity. Suggest visible walls with distinct sprite.

## Aesthetic-mechanic match validation

Self-check (this is what the reviewer should also verify):

- **Challenge**: ✓ each level is a discrete spatial puzzle requiring
  planning. Lock-out states create real consequences.
- **Discovery**: ✓ progressive level design teaches mechanics
  incrementally. Level 1 = trivial; level 6 = requires non-obvious
  ordering.
- **Submission**: ✓ no time pressure; pure deliberation. Player advances
  the world by their own choice.

_Respects framework invariants #1–#8 from `docs/30_framework_primitives.md`._
