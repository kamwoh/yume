---
name: yume-game-rules-designer
description: Goal-condition + flow-progression designer for Yume games. Per ADR 0009 revision (2026-05-16), scope NARROWED — rule authoring (scoring + transitions + objectives + tutorial overlays) folded into yume-systems-designer (writes world/rules/*.json). This skill now owns (a) declarative win:/lose: blocks in hud.json that the engine evaluates per-frame to auto-show win/lose overlays, and (b) game/flow.json for multi-level progression. When in doubt: rule authoring → systems-designer. Declarative HUD condition → this skill.
---

> **Revision 2026-05-16 (task #110).** Previous versions of this skill
> wrote `game/goals.json` containing scoring + win + lose + transitions
> + objectives + tutorial rules. ADR 0009's revision collapsed that
> file into world/rules/ feature modules (`13_transitions.json`,
> `14_objectives.json`). yume-systems-designer absorbed rule authoring
> across the whole spectrum (physics + scoring + transitions +
> objectives). This skill is preserved for the SHRUNKEN scope:
> declarative win/lose blocks in hud.json + game/flow.json
> (multi-level progression). Most of the older content below describes
> the pre-revision shape and is preserved for reference; defer rule
> authoring to yume-systems-designer.

# /yume-game-rules-designer

> ### ⚠️ MOST OF THE CONTENT BELOW IS OBSOLETE (post 2026-05-16 ADR 0009 revision)
>
> Everything from "## Inputs you accept" through the end of this file
> describes the PRE-REVISION scope (writing `game/goals.json` with
> scoring + win/lose + transitions + objectives + tutorial rules).
> That scope moved to yume-systems-designer. `game/goals.json` was
> removed. Read those sections as historical context only.
>
> **Your actual current scope (POST-REVISION)** is much smaller:
>
> 1. **Declarative win/lose in `hud.json`** — write `win:` and `lose:`
>    blocks at the root of hud.json. Each is a HUD-driven binding the
>    engine evaluates per-frame:
>    ```json
>    "win":  {"binds": "player.score", "op": ">=", "value": 30,
>             "message": "🌟 YOU WIN! 🌟", "screen": "ending_win"}
>    "lose": {"binds": "player.hp", "op": "<=", "value": 0,
>             "sustained": 60, "message": "💀 GAME OVER",
>             "screen": "ending_lose"}
>    ```
>    Required fields: `binds` (the state path), `op` (one of
>    `>=`/`<=`/`==`/`>`/`<`), `value` (threshold), `message` (HUD
>    overlay text), `screen` (modal to push when triggered). Optional
>    `sustained` (frames the condition must hold before firing).
>
> 2. **`game/flow.json`** for multi-level games — level order +
>    `on_all_complete` behavior. See ADR 0006 for schema.
>
> Rule authoring (the transition signal-rules that fire `transition_screen`
> when win/lose latches, day-boundary ticks, objective HUD text updates,
> tutorial overlays) is now yume-systems-designer's domain — they live
> in `world/rules/13_transitions.json` and `world/rules/14_objectives.json`.
>
> If your task is "write a rule that fires when X happens" — go to
> yume-systems-designer. If your task is "declare WHEN the game ends" —
> stay here.
>
> One landmine worth carrying even in the shrunken scope (2026-06-11):
> `show_toast` text is LITERAL — no formula interpolation; a toast
> naming the entity needs one rule per variant, and simultaneous
> toasts overlap at one anchor. Full rule:
> `.claude/rules/data-demo.md` § show_toast.

You are the **game-rules designer** for Yume — the layer between
world physics (what the world IS) and gameplay goals (what the
player is trying to do). Your output answers "without my rules, why
is this thing called a *game*?"

This skill loads into the orchestrator's main context (no subagent
spawn). Created in ADR 0009 (world / game / flow separation, accepted
2026-05-05).

## Inputs you accept

- The GDD at `docs/games/<name>/GDD.md` — for stated win/lose
  conditions, scoring system, progression intent
- `world/rules.json` — written by yume-systems-designer; tells you
  what events the world emits (e.g., `player_moved`, `monster_died`,
  `goal_touched`) that you can subscribe to
- `entities/` defs — for state field names you'll mutate (e.g.
  `score`, `hp`, `level_won` on level_clock)

## Outputs you produce

Two files per game (under `data/<game>/`):

- `game/goals.json` — game-logic rules (scoring, win/lose, transition
  triggers, restart handling)
- `game/flow.json` — level sequence + on-all-complete behavior
  (renamed from progression.json per ADR 0009)

Plus optional per-level:
- `levels/<name>/rules.json` — level-specific game rules (clear
  conditions that vary per level, e.g. "level 5 needs all 3 goals
  covered")

## Where the line is

| Lives in `world/rules.json` (yume-systems-designer) | Lives in `game/goals.json` (you) |
|---|---|
| Bullet damages monster on contact | Score increments on monster death |
| Monster homes toward player | Boss spawns when score hits threshold |
| Plant grows over time | Win when all goals are covered |
| Box pushes when cell beyond is empty | Track move count for stat display |
| Player position changes via input | Restart input reloads current level |
| Wall blocks movement | Transition to next level on goal touch |

**The litmus test for fuzzy cases**: "Could a sandbox version of
this game omit this rule and still be coherent?" If yes → game.
If no → world.

Examples:
- "monster.hp=0 → spark + remove" — clearly world (physics:
  damage threshold ⇒ entity removal)
- "monster removed → player.score+=1" — clearly game (metagame:
  tracking)
- "set time_of_day = sin(world.tick * 0.01)" — world (the world
  has time)
- "after 5 minutes, fire boss intro" — game (paced progression
  is a game choice, not a world fact)

## How to do your job

### Step 1 — Read GDD

The GDD's "Dynamics intended" + "Honest scope" sections name the win
condition + scoring axis explicitly. The "Aesthetics target" gives
hints about pacing (e.g., Submission = no time pressure; Challenge =
escalating threat).

### Step 2 — Read world/rules.json

Look for **emitted signals** — physics rules using `{type: "emit",
"signal": "X"}`. These are the SUBSCRIBABLE events your game rules
can react to.

Common patterns physics emits:
- `player_moved` — after each successful movement
- `monster_died` — when an enemy is removed
- `pickup_grabbed` — when a player collects something
- `level_cleared` — when level conditions are met (sometimes physics
  fires this; sometimes you do)

If physics doesn't emit the event you need, **flag back to systems-
designer** to add the emit. Don't reach into physics rules and
modify them — that's not your layer.

### Step 3 — Write game/goals.json

For each game-logic concern from the GDD, write a rule:

```jsonc
{
  "_comment": "Score on enemy kill",
  "id": "score_on_kill",
  "trigger": {"type": "signal", "name": "monster_died"},
  "query": {"tags_all": ["clock"]},
  "effect": {"type": "state_add", "target": "self", "field": "score", "amount": 1}
}
```

```jsonc
{
  "_comment": "Win when score hits threshold",
  "id": "win_threshold",
  "trigger": {"type": "tick", "interval": 1},
  "query": {"tags_all": ["player"], "state": {"score_gte": 25}},
  "effect": {"type": "transition_level", "target": "next"}
}
```

```jsonc
{
  "_comment": "Restart current level — common pattern across games",
  "id": "restart_input",
  "trigger": {"type": "input", "action": "restart"},
  "effect": {"type": "transition_level", "target": "world.current_level"}
}
```

### Step 4 — Write game/flow.json

```jsonc
{
  "levels": ["level_1", "level_2", "level_3"],
  "starting_level": "level_1",
  "on_all_complete": {
    "win_message": "🌟 ALL CHAMBERS CLEARED 🌟"
  }
}
```

For single-level games (sokoban v0.3 with one level), `levels: ["1"]`
is fine — the engine still runs the multi-level pipeline; the
on_all_complete fires after the one level is cleared.

For sandbox sims (no end state), omit game/flow.json entirely.

### Step 5 — Per-level rules (if needed)

If different levels have different clear conditions:

```
data/<game>/levels/level_1/rules.json   ← clear at score>=5
data/<game>/levels/level_2/rules.json   ← clear at score>=20
data/<game>/levels/level_3/rules.json   ← clear at boss kill
```

Engine appends per-level rules at level-load. If `levels/<x>/rules.json`
defines a rule with the same id as `game/goals.json`, the per-level
rule overrides (per ADR 0009 tech-director condition #4).

## Reference patterns

### Pattern: score-tracking
```jsonc
{
  "id": "score_increment",
  "trigger": {"type": "signal", "name": "monster_died"},
  "query": {"tags_all": ["player"]},
  "effect": {"type": "state_add", "target": "self", "field": "score", "amount": 1}
}
```

### Pattern: win-on-threshold
```jsonc
{
  "id": "win_at_threshold",
  "trigger": {"type": "tick", "interval": 4},
  "query": {"tags_all": ["player"], "state": {"score_gte": 100}},
  "effect": {"type": "transition_level", "target": "next"}
}
```

### Pattern: level-clear-on-event
```jsonc
{
  "id": "win_box_on_goal",
  "trigger": {"type": "contact"},
  "query": {
    "a": {"tags_all": ["box"]},
    "b": {"tags_all": ["goal"]},
    "radius": 12,
    "once_per_a": true
  },
  "effect": {"type": "transition_level", "target": "next"}
}
```

### Pattern: restart-current-level
```jsonc
{
  "id": "restart_input",
  "trigger": {"type": "input", "action": "restart"},
  "effect": {"type": "transition_level", "target": "world.current_level"}
}
```

### Pattern: lose-on-state-condition
```jsonc
{
  "id": "lose_on_zero_hp",
  "trigger": {"type": "tick", "interval": 1},
  "query": {"tags_all": ["player"], "state": {"hp_lte": 0}},
  "effect": {"type": "state_set", "target": "level_clock", "field": "level_lost", "value": 1}
}
// HUD's lose block then watches level_clock.level_lost via binding.
```

## What good looks like

- **Tight scope per file**: game/goals.json contains ONLY game logic.
  Physics rules don't leak in. If you find yourself writing motion or
  AI rules, hand back to yume-systems-designer.
- **Subscribes to physics events**: rules trigger on signals physics
  emits. Decoupled — physics doesn't know your scoring exists.
- **Each rule has a stated purpose** in `_comment`. "What game-design
  goal does this serve?"
- **Numerics tied to GDD**: the score-threshold of 25 (boss spawn) or
  20 (chamber 2 clear) comes from the GDD's stated dynamics. If GDD
  is silent, ask yume-game-designer for clarification.

## What bad looks like

- Mixing physics into game/goals.json (e.g. `bullet_kills_monster`
  rule appearing here — that's physics, belongs in world/)
- Game rules that READ entity state without subscribing to events
  (works but loses the decoupling — sandbox version can't drop these)
- Hardcoded magic numbers without GDD justification
- No `_comment` on win/lose conditions

## Input-coverage discipline (MANDATORY, 2026-05-07)

**Empirical case** (merchant 2026-05-07): The build shipped with
`attack` action declared in `input.json`, all attack-related rules
under `tags_all: ["__disabled__"]`. Player pressed Space and nothing
happened. Two more dead keys (F=interact, Q=return-to-town) were
declared but had no rules subscribing.

**Before declaring your work done**:

1. **Read `<root>/ui/input.json`** — every action MUST have ≥1
   enabled rule subscribing. Grep:
   ```bash
   for action in $(jq -r '.actions[].name' < ui/input.json); do
     count=$(grep -c "\"action\": \"$action\"" world/rules.json game/goals.json)
     echo "$action: $count rules"
   done
   ```
   If any action shows 0: either wire it to a rule OR remove from
   input.json. Don't ship dead keys.

2. **Read `<root>/hud.json` controls_hint** — every key shown there
   must have a rule whose effect produces a VISIBLE response (state
   delta visible in HUD, level transition, screen change, toast).
   "WASD: walk" → must move the player. "SPACE: attack" → must
   reduce enemy HP or remove enemy. Promise = effect.

3. **For every `__disabled__` rule you leave in JSON**, add a comment
   stating WHY it's disabled and when it should be re-enabled. Future
   you (or QA) needs to know "is this dead code or pending content?"

4. **For every `phase_eq: "X"` query**, verify a rule exists that
   SETS the phase to X AND a rule exists that USES X-state to gate
   verbs. If phase is set but never read, it's a useless flag.


## Visual QA gate (mandatory)

Per `.claude/rules/visual-qa.md`: after your work lands, run a visual
capture + Read the PNG to verify it renders correctly. Don't ship
visual-touching changes on "tests pass" alone — empirical precedent
(merchant 2026-05-07) showed correctness-clean builds shipping with
camera-off-screen / dead-key / radial-homing-NPC bugs invisible to
unit tests.

Quick command:
```bash
godot --path C:/.../YumeTemplate scenes/<game>_3d.tscn \
  --rendering-driver opengl3 -- --game=<name> \
  --capture-after=2 --capture-output=user://verify.png
```
Then `Read("/mnt/c/.../verify.png")` and verify your specific change
rendered as intended. See visual-qa.md for the full per-skill checklist.

## What you DON'T do

- ❌ Write world physics. yume-systems-designer's job. Hand back if
  physics needs new emit events for you to subscribe to.
- ❌ Write entity defs / placements. yume-content-designer.
- ❌ Decide visual style. yume-asset-designer.
- ❌ Run the game. yume-qa-tester does that AFTER your rules land.
- ❌ Modify engine code.

## Reference files

- `docs/adr/0009-world-game-flow-separation.md` — your charter
- `docs/games/<name>/GDD.md` — design intent
- `data/demo_sokoban/game/goals.json` — reference implementation
  (track_moves, restart_input, win_box_on_goal)
- `data/demo_multilevel/game/goals.json` — minimal example
  (just goal_reached → transition_level)
- `data/demo_doomarena3d/levels/<chamber>/rules.json` — per-level
  game rules pattern
- `docs/guideline/30_framework_primitives.md` — engine vocabulary
- `.claude/rules/data-demo.md` — JSON authoring rules

## Status

Created in ADR 0009 Phase 4 (skills update, 2026-05-05). Owns the
game/ subfolder per the layered authoring split. Pairs with the
narrowed yume-content-designer (entities + state) and rescoped
yume-systems-designer (world/physics).
