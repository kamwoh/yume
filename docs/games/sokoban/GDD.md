# Sokoban: 8-level demo

_Date: 2026-05-03_
_Designer: yume-game-designer_
_Revision: round 3 — scope honestly framed as demo per reviewer Axis 8._

## One-line pitch

A small, calm puzzle: push crates around an old archive vault. Eight
hand-curated rooms, generous undo, single sitting.

## Theme / identity

**The Archive Vault**: you are a quiet sorter in an old document
archive. Crates of records (the boxes) need to be placed on their
catalog markers (the goals). The walls are oak shelving. Mistakes
aren't catastrophic — undo lets you try a different path. Visual
palette: warm parchment + dark oak + brass accents. Sound palette:
gentle wood scrape on push, soft chime on placement, hush of a quiet
library.

This is NOT a high-intensity puzzle game. It's a 20-minute
contemplative session, like sorting mail or doing a crossword over
coffee.

## Aesthetics target (revised)

| Category | Why |
|---|---|
| **Submission** | The whole point. Calm, unhurried, deliberate. Each push has weight. |
| **Challenge** | Light. Levels offer puzzle resistance but undo + restart prevent frustration spiral. |

Removed from claim: **Discovery** — only achievable with ≥30 levels
of varied mechanics; we have 8 with one mechanic. Honest scope.

Expressly NOT: Sensation (no juice — calm), Fellowship (single-player),
Narrative (no story beyond theme), Expression, Fantasy heavy lift.

## Scope honesty (REV per Axis 8)

This is a **demo / tutorial** — 8 levels, ~20 minutes first-clear.
Framed honestly: a polished short experience that demonstrates
Yume can do turn-based puzzle. Not a full puzzle game.

If user wants a "real" puzzle game (20-50+ levels, multiple
mechanics, replayable for hours), that's v2 — explicitly out of
scope here.

## Dynamics intended

- **Search the state space**: each move reaches a new state. Player
  builds a mental map of "from here, can I reach the goal?"
- **Lock-out tension (mitigated)**: pushing a box against a wall
  corner can stall progress. **Undo (Z) lets the player rewind one
  move at a time** — exploration is safe, mistakes are recoverable.
  Restart (R) is full reset.
- **Progressive teaching**: level 1 = trivial (1 box, 1 goal, no
  obstacles). Level 8 = requires non-obvious push ordering.
- **Pure deliberation**: no real-time pressure. Game advances ONLY on
  player input. This is critical to the Submission aesthetic.

Randomness: NONE. Every level is hand-designed. Skill comes from
spatial reasoning, not luck.

Typical session: ~30s per level for early levels, 1-3 minutes for
later levels. Total game length: 15-25 minutes.

## Mechanics

### Player verbs

| Verb | Trigger | Effect |
|---|---|---|
| Move N | input arrow-up (PRESS-edge) | If cell N is empty: move there. If cell N has a box AND cell beyond is empty: push the box, then move. Otherwise: no-op. |
| Move S/E/W | similar | symmetric |
| **Undo (NEW REV)** | input Z (PRESS-edge) | Revert one move: restore player.position and any-pushed-box.position to previous-tick values. Up to 16-deep undo stack (engine support: each entity stores `state.prev_position`; undo pops one). |
| Restart | input R (PRESS-edge) | Full reload of current level layout. |

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

### Level progression plan (REV — added per reviewer; updated round 3 with named signature levels + rhythm)

Concrete enumeration of what each level teaches AND its emotional
beat. The rhythm is: easy onboarding → first hook → breather → climb
→ signature → breather → climb → finale.

| Level | Name | Layout | Lesson | Beat |
|---|---|---|---|---|
| 1 | "First Crate" | 1 box, 1 goal, open 5×5 | Arrow-key movement; understand push | Onboarding |
| 2 | "Pair" | 2 boxes, 2 goals, open 6×6 | Multi-goal | Onboarding |
| 3 | "The Hallway" *(signature)* | 1 box past 1 goal in a corridor; player must push box past, double back via side aisle, pull through narrow opening | Single-move planning; "aha" of seeing the corridor's loop | First hook — memorable |
| 4 | "Quiet Shelf" *(breather)* | 2 boxes, 2 goals, open layout, no tricks | Re-establish basics after the hook | Breather |
| 5 | "Choke" | 4 boxes, 4 goals, single-cell choke point in middle | Push order critical | Climb |
| 6 | "Mind the Corners" | 3 boxes, 3 goals, dead-end branches | Avoid corner lockouts (with undo, exploration is safe) | Climb |
| 7 | "The Diamond" *(signature)* | 4 boxes in diamond pattern, 4 goals OUTSIDE the diamond; only one push-order solves it (must push south box LAST) | The pure "aha" — player will recall this one | Climax |
| 8 | "Vault Doors" *(finale)* | 5 boxes, 5 goals, asymmetric chamber. Open layout; rewards 8+ moves of pre-planning | Synthesis of all prior lessons | Finale |

The 3 named signature levels (3, 7) and 1 explicit breather (4) give
the 22-minute experience a shape — onboarding → hook → breather →
climb → climax → finale — instead of a monotonic difficulty curve.

Level-designer can fine-tune cell counts, but the **named beats are
fixed**.

### Replay vector (REV — added per reviewer)

After first clear, the player can return to any cleared level and
attempt to **match or beat the par move count**:

- Each level has a `par_moves` value (designer-set; fewest moves to
  solve in expected solution path).
- HUD shows `Moves: 12 / par 9` while playing.
- Level-clear shows `Cleared in 14 moves (par 9). +1 move medal
  → silver`.
- Three medals per level: bronze (cleared), silver (within +50% of
  par), gold (par or below).
- After full game clear, the menu shows medal totals: "Sokoban
  cleared. 5 silver, 3 bronze. 0/8 gold — try again to perfect?"

This adds optimization-as-mastery without breaking the "Submission"
aesthetic (no time pressure; just move-count refinement).

### Session save (REV — added per reviewer)

- On level clear, persist `current_level = N+1` to disk
  (Godot `user://sokoban_save.json`).
- On game start, load `current_level` and resume there.
- Simple, no-conflict format: `{ "highest_cleared": N, "medals":
  [...] }`.
- If save absent (first launch): start at level 1.
- Cmdline override: `--level=<N>` for testing.

Within-level state (mid-puzzle) is NOT saved — alt-tab still discards
in-progress positions. Player just restarts the level. For a single-
sitting demo, this is acceptable.

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

HUD elements (top-left, calm sans-serif, warm parchment palette):

- `Level: <N> / 8` — current progress
- `Boxes placed: <K> / <M>` — visual feedback for partial progress
- `Moves: <total> / par <P>` — onboarding to scoring system; visible from level 2 onward (level 1 hides par to avoid distraction)
- (bottom-left, smaller) `← ↑ → ↓ Move · Z Undo · R Restart` — persistent onboarding cue. Replaces "press R to restart" minimal hint.
- (after level clear) Medal indicator: `Cleared in 14 moves · par 9 · ⭐ silver` shown on level-transition splash.

The GDD's stated **Submission** aesthetic depends on each push feeling
deliberate and acknowledged. Without per-move feedback, the game feels
silent and player loses the rhythm.

### Stuck-state UX (REV — round 2 + round 3)

With **undo (Z) added in round 3**, the stuck-state picture changes
dramatically. Layered mitigations:

1. **Undo (Z)** — primary tool. Player makes a wrong push, hits Z, tries
   another approach. Trance state preserved; no full restart needed
   for small mistakes. 16-deep stack handles "I went down the wrong
   path 8 moves ago."
2. **Restart (R)** — secondary tool, full reset. Used when undo stack
   is exhausted (>16 moves into a wrong solution path) or when player
   wants a clean slate.
3. **Move counter vs par** — implicit signal: if `Moves: 47 / par 9`
   and no goals placed, player notices they're far off. No explicit
   "you're stuck" prompt needed.
4. **Level layout pre-checked** — level-designer verifies each level
   is solvable AND its first lock-out trap is at least 5 moves deep
   (so undo can rescue most early mistakes).

V2 may add: visual indicator on a box that's pushed into a "definitely
locked" corner (heuristic: 2+ adjacent walls, no adjacent goal). For
v1, undo + par counter handle 95% of frustration cases.

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

## Honest scope (REV — round 3 update)

In scope:
- 8 hand-designed levels (3 signature, 1 breather, 4 standard) with
  curated progression beats
- Push mechanic with wall + box collision
- Goal-on-place detection + win condition per level
- **Undo (Z key, 16-deep stack)** — promoted to v1 per round 3 review
- **Restart (R key)** — full level reset
- **Move counter + par + bronze/silver/gold medals** — replay vector
- **Session save** — persist current level across game restarts
- **Theme**: "The Archive Vault" — quiet sorter, parchment + oak

Out of scope (explicitly):
- Ice tiles / switches / portals (v2)
- Procedural level generation
- Real-time pressure / time limits
- Mid-puzzle save (alt-tab discards in-progress moves)
- Auto-detect lock-out (v2 — undo + restart cover 95% of cases)

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

## Aesthetic-mechanic match validation (REV — round 3 update)

Self-check:

- **Submission**: ✓ no time pressure; pure deliberation. Player
  advances the world by their own choice. Theme + warm palette + soft
  audio support trance state. Undo prevents anxiety from breaking it.
- **Challenge (light)**: ✓ each level is a spatial puzzle requiring
  planning. Lock-outs exist but undo + restart prevent frustration
  spiral. Optimization-as-mastery via par-move medals adds skill
  ceiling without urgency.

(Discovery removed — see Aesthetic target section. Honest scope.)

_Respects framework invariants #1–#8 from `docs/30_framework_primitives.md`._
