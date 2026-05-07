# Visual QA — mandatory gate for visual-touching changes

Any change that affects what the player SEES on screen must be
verified visually before declaring done. "It compiles + tests pass"
is a correctness gate; visual QA is a *playability* gate.

Empirical precedent: merchant 2026-05-07 build had 12 scenario tests
passing, qa-tester verdict "complete," but shipped invisible to the
player (camera off-screen, ESC quit instead of pause, Q dead key, all
customers radial-homing on player). All caught only by visual capture.

## Who must run this gate

Skills that write/modify content or code that affects rendering:

- **yume-content-designer** — entity defs + initial placements
  (entities visible at expected positions, scale, color)
- **yume-game-rules-designer** — game/rules.json (transitions, screens,
  effects fire visibly)
- **yume-systems-designer** — world/physics.json (motion, AI homing,
  spawn timing — all visible behaviors)
- **yume-asset-designer** — visual fields per entity, scene/hud config
  (THE visual layer — strongest gate)
- **yume-level-designer** — coordinates + level structure
- **yume-screen-flow-designer** — screens.json (every screen renders)
- **yume-tutorial-designer** — tutorial.json overlays
- **yume-juice-designer** — particles, shake, flash (visual effects)
- **yume-visual-designer** — already has this as their core role

Skills that don't touch visuals (game-designer, game-planner,
game-reviewer, merchant-reviewer, etc.) are exempt.

Engine builders (`builder` subagent) running ADRs that touch
rendering primitives: per `.claude/rules/engine-scripts.md` § visual
gate, this rule applies.

## How to invoke

Two complementary tools, run in sequence:

### Tool 1: capture

```bash
~/yume/scripts/play.sh <game-name> --capture
# OR for scripted-input flows (post-input state):
godot --path <template> scenes/<game>_3d.tscn \
  --rendering-driver opengl3 -- --game=<name> \
  --capture-after=2 --capture-input='move_east,3.0' \
  --capture-output=user://<descriptive_name>.png
```

The PNG lands at `~/.../app_userdata/Yume Framework/<name>.png` (or
the local user:// path; see `scripts/play.sh` for the resolved path).

### Tool 2: Read the PNG

```
Read("/mnt/c/Users/.../<name>.png")
```

Claude's vision will surface any visual issues. Compare against:
- The mental model the GDD / level-design / asset-design specified
- The previous capture (regression check)

## What to check (per-skill checklist)

### Content + Level + Systems designers

- Player visible at expected position (not collapsed at origin)
- All named entities from world-plan render
- Spread feels right (not bunched, not invisibly far)
- Scale sanity (player ~human-height, props proportional)
- HUD overlays correctly (no z-order bug)
- Camera framing reasonable (key entities in view)

### Asset designer

- Visual style consistent (palette + theme coherence)
- No placeholder / fallback shapes shipped (pink boxes, default cubes)
- Entity differentiation legible (player vs NPC vs enemy at glance)
- Audio cues fire at expected events (cross-check with capture-input)

### Screen + Tutorial + Juice designers

- Screen renders at all (no blank gray)
- Buttons clickable (not 0-size or off-screen)
- Text readable (size, contrast, font-availability)
- Modal screens darken background per spec
- Overlays z-ordered above world but below toasts
- Particles fire at correct positions
- Camera shake amplitude matches event severity

## When the visual gate FAILS

If capture shows a visual bug:
1. Note the specific defect (location, what's wrong)
2. Hand back to the responsible skill — don't fix-and-ship silently
3. After re-fix, re-capture and re-read

Do NOT ship with a "I'll fix next session" note for a visual bug
visible at frame 1. That commits debt that the next session may
not catch.

## Effect-chain interaction

Visual QA + effect-chain validation (per
`.claude/rules/engine-scripts.md` § effect-chain gate) are TWO
gates, not one. Visual catches "scene renders wrong"; effect-chain
catches "button click does nothing." Both required for screen +
overlay changes.

## When invoked by orchestrator

The yume-design orchestrator's qa-tester phase runs visual capture
already (Tier 2.6r). This rule extends that: every CONTENT-WRITING
phase (content-designer, asset-designer, etc.) should also do at
least one capture + read after their work, before handing off. This
catches issues earlier in the pipeline.

## When launching subagents

If you spawn a `builder` agent (or any subagent) for visual-touching
work, INCLUDE in their prompt:

```
After your implementation passes unit tests, run visual QA:
1. Sync framework: cp -r /home/kamwoh/yume/godot/. /mnt/c/.../YumeTemplate/
2. Capture: godot --path C:/.../YumeTemplate scenes/<game>_3d.tscn \
   --rendering-driver opengl3 -- --capture-after=2 \
   --capture-output=user://verify.png
3. Read the PNG and verify your change rendered correctly.
4. If broken, debug + retry (max 3) before reporting back.

The path-scoped rule .claude/rules/visual-qa.md applies to your work.
```

This is non-negotiable for: rendering-primitive changes, scene
changes, mesh/shape additions, screen/overlay/HUD changes, particle
effects, shader work.
