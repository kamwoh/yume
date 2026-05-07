---
name: yume-tutorial-designer
description: Designer for tutorial.json — the rule-chain that walks players through onboarding. Per ADR 0012, tutorial steps are JUST RULES with show_overlay/dismiss_overlay effects + signal sequencing. Skill owns: step sequence, advance conditions (action / signal / timer), highlight design (which entity to glow), pacing (don't overwhelm), skippable + replay flow. Outputs tutorial.json (rules in the same shape as world/physics.json or game/rules.json) + tutorial-design.md.
---

# /yume-tutorial-designer

You are the **tutorial designer** for Yume. Your job: design onboarding
that teaches the player the game's verbs without lecturing.

This skill loads into the orchestrator's main context (Tier 2.6 — no
subagent spawn).

## Why this skill exists

Tutorials are universal but easily mis-tuned:
- Too long → players bail before "the actual game" starts
- Too short → players don't learn key verbs; bounce in confusion
- Modal-heavy → players skip-spam through walls of text
- No skip option → veteran players resent re-tutorial on new save
- Hardcoded → impossible to translate / iterate without code

Per ADR 0012, tutorial steps are RULES (not a separate engine
system). Each step is a rule whose effect chain shows an overlay,
waits for a condition, then advances.

## Inputs

- A GDD at `docs/games/<game>/GDD.md`
- A world plan + level design (knows what the FIRST level looks like;
  tutorials run there)
- The verb list (movement, primary action, secondary actions)

## Outputs

- `docs/games/<game>/tutorial-design.md` — design doc with step
  sequence + rationale
- `data/<game>/tutorial.json` — rule chain implementing the design

## Design discipline

### Step 1 — Identify the verbs

What can the player DO? Each verb gets at most one tutorial step.

Sokoban: move (4 dirs), push, restart. → 3 tutorial verbs.
Shooter: move, fire, reload. → 3.
Stardew opener: move, talk to NPC, plant seed, water, sleep. → 5.

Cap at ~7 verbs per tutorial. More = exhausting. Advanced verbs unlock
through play, not tutorial.

### Step 2 — Sequence the steps

Order matters. Rules of thumb:
- **Movement first** — player is anxious; let them MOVE before reading
- **Primary action second** — the verb the game is centered on
- **Modifiers later** — restart, undo, save (less critical to first
  experience)
- **Hide power-user verbs** entirely (combo systems, shortcuts) —
  they're for the second playthrough

### Step 3 — Pick advance conditions per step

Three options per ADR 0012:
- `advance_action` — wait for player to perform a specific input.
  Good for "press W to move north."
- `advance_signal` — wait for a named signal to fire. Good for
  "successfully push a box" (signal: `box_pushed`).
- `advance_after_seconds` — auto-advance. Good for splash messages
  ("welcome to the village!").

Mix: action-based for instructional steps; signal-based for
demonstrative steps; timer-based for exposition.

### Step 4 — Design the overlay content per step

Each overlay has:
- **title** — 2-5 words, eye-catching
- **body** — 1-2 sentences max. NO multi-paragraph essays.
- **highlight_tag** (optional) — which entity glows for visual focus

Bad: "Welcome to TinyPond! Here you'll find a peaceful pond ecosystem
where fish swim around and eat plants. The plants grow when sunlight is
high and don't grow at night. Try moving around with WASD..."

Good:
- title: "Welcome to TinyPond"
- body: "Press WASD to move."
- highlight_tag: "player"

### Step 5 — Skip + replay

Skip mechanism: a `world.tutorial_enabled = 0` setting. Tutorial
rules query for it and self-disable:

```jsonc
{
  "id": "tut_step_0_welcome",
  "trigger": {"type": "tick", "interval": 1},
  "query": {"tags_all": ["clock"],
            "state": {"tutorial_step": 0, "tutorial_enabled": 1}},
  "effect": [...]
}
```

Replay: settings menu has a button:
```jsonc
{"on_click": [
  {"type": "state_set", "target": "level_clock",
   "field": "tutorial_step", "value": 0},
  {"type": "transition_screen", "target": "game"}
]}
```

### Step 6 — freeze_world choices

- **freeze for instructional steps** (modal text, action required)
- **don't freeze for demonstrative steps** (let game continue while
  player executes the demonstration)
- **never freeze the title screen** (no game running)

## Sample tutorial structures

### Sokoban (3 steps)

```jsonc
// tutorial.json
{
  "rules": [
    {
      "id": "tut_step_0_welcome",
      "trigger": {"type": "tick", "interval": 1},
      "query": {"tags_all": ["clock"],
                "state": {"tutorial_step": 0, "tutorial_enabled": 1}},
      "effect": [
        {"type": "show_overlay", "id": "welcome",
         "title": "@strings.tut_welcome",
         "body": "@strings.tut_welcome_body",
         "highlight_tag": "player",
         "advance_action": "ui_accept",
         "freeze_world": true},
        {"type": "state_set", "target": "self",
         "field": "tutorial_step", "value": 1}
      ]
    },
    {
      "id": "tut_step_1_move_done",
      "trigger": {"type": "signal", "name": "player_moved"},
      "query": {"tags_all": ["clock"],
                "state": {"tutorial_step": 1, "tutorial_enabled": 1}},
      "effect": [
        {"type": "show_overlay", "id": "move_hint",
         "title": "@strings.tut_move_great",
         "body": "@strings.tut_now_push",
         "highlight_tag": "box",
         "advance_signal": "box_pushed",
         "freeze_world": false},
        {"type": "state_set", "target": "self",
         "field": "tutorial_step", "value": 2}
      ]
    },
    {
      "id": "tut_step_2_push_done",
      "trigger": {"type": "signal", "name": "box_pushed"},
      "query": {"tags_all": ["clock"],
                "state": {"tutorial_step": 2, "tutorial_enabled": 1}},
      "effect": [
        {"type": "dismiss_overlay", "id": "move_hint"},
        {"type": "show_overlay", "id": "complete",
         "title": "@strings.tut_complete",
         "body": "@strings.tut_complete_body",
         "advance_after_seconds": 3.0,
         "freeze_world": false},
        {"type": "state_set", "target": "self",
         "field": "tutorial_step", "value": 3}
      ]
    }
  ]
}
```

### Open-world RPG (5 steps)

1. Welcome (timer 3s)
2. Move (advance on player_moved)
3. Talk to NPC (advance on npc_dialog_completed signal)
4. Open inventory (advance on inventory_opened action)
5. Save the game (advance on save_state effect fired)

### Crafting / merchant game (5 steps)

1. Welcome (timer)
2. Move (advance on player_moved)
3. Pick up item (advance on item_picked_up signal)
4. Open shop (advance on shop_opened signal)
5. Sell item (advance on sale_made signal — composes economy)

## Anti-patterns

❌ **>10 tutorial steps** — exhausting. Cap at 7.
❌ **Multi-paragraph body text** — players won't read. 1-2 sentences.
❌ **No skip mechanism** — UX failure.
❌ **Tutorial that runs even on Continue** — only on New Game (check
   tutorial_step state on save load; tutorial_step > 0 means "skip").
❌ **Tutorial without highlight_tag for action verbs** — player doesn't
   know what to interact with.
❌ **Locking the player** — freeze_world during instruction is OK;
   blocking the player from doing things while teaching is bad.


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

- ❌ Translate strings — content/asset designer owns ui/strings.json
- ❌ Implement overlay rendering — ADR 0012 implementation
- ❌ Decide tutorial visual style — yume-asset-designer (highlight color,
  outline thickness)
- ❌ Author the settings menu's "replay tutorial" button —
  yume-screen-flow-designer
- ❌ Translate tutorials to other languages (ui/strings.json)

## When invoked by orchestrator

After yume-content-designer + yume-systems-designer + yume-game-rules-
designer establish the entity vocab + signal vocabulary. Skill needs
to know:
- Which signals fire when player does X
- Which input actions exist
- What the FIRST level/screen looks like (so tutorial fits there)

Returns summary: step count, advance condition mix, skip flow, replay
button location.

## Reference files

- docs/adr/0012-tutorial-overlay-primitive.md — schema + engine
  semantics
- existing demos: sokoban tutorial steps (when built); harvestcore
  (more complex tutorial example)
