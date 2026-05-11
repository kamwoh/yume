# Visual QA — mandatory gate for visual-touching changes

Any change that affects what the player SEES on screen must be
verified visually before declaring done. "It compiles + tests pass"
is a correctness gate; visual QA is a *playability* gate.

Empirical precedent: merchant 2026-05-07 build had 12 scenario tests
passing, qa-tester verdict "complete," but shipped invisible to the
player (camera off-screen, ESC quit instead of pause, Q dead key, all
customers radial-homing on player). All caught only by visual capture.

Second precedent (2026-05-08): merchant pause-menu / haggle / funeral
buttons all wired `transition_screen target='_close'`, an author
convention the engine never recognized — every dismiss button silently
warned instead of popping the modal. 11 broken buttons across 13
screens, 488 unit tests + 12 scenarios passed cleanly because headless
tests don't fire on_click. The user hit it on first play. Fix:
screen-flow gate now runs `tools/validate_screens.py` at sync time AND
this rule mandates a click-flow smoke test before declaring done.

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

### Tool 2: Read the PNG with a CONTEXT-SPECIFIC prompt

A naive `Read("/path/to.png")` produces a generic description. That
misses what you're actually checking — and Claude's vision picks up
on the QUESTION asked, not just the image.

**Every VQA invocation must construct a prompt that answers**:

1. **What did I just change?** (e.g. "Added a haggle screen with
   3 bands + slider. Bound to customer.gold_value.")
2. **What state is the capture in?** (e.g. "After 2s wait + walking
   east to a customer, the haggle screen should be open.")
3. **What specifically am I verifying?** (e.g. "Are the 3 band
   colors RED/YELLOW/GREEN distinguishable? Is the slider bound
   correctly so dragging changes the displayed offer?")
4. **What would be a fail?** (e.g. "Bands all same color = fail.
   Slider missing = fail. Customer name not visible = fail.")

The prompt structure:

```
Read("/path/to.png")

Then ask Claude:
"This capture is from <game-name> after <change-summary>.
Expected scene state: <what should be on screen now>.
Verify specifically:
1. <criterion 1 — concrete, falsifiable>
2. <criterion 2>
3. <criterion 3>
Failure modes to flag if present:
- <specific anti-pattern that's likely given this change>
- <regression vs previous capture if doing diff>
Report: PASS / FAIL with the criterion that failed + observed evidence."
```

The question SHAPES what Claude looks at. Generic "does it look
right" misses bugs the focused question would catch.

## Baseline environmental checks (MANDATORY, always runs first)

**Empirical lesson, 2026-05-07**: Session 1's merchant_3d capture
showed the player + NPCs against a tan-gradient sky and we (orchestrator
+ all builder agents) said "PASS" — but the scene had NO Ground node.
The sky's `ground_horizon_color` gradient looked LIKE a floor at first
glance, so context-specific change-prompts (which asked about entity
visibility, scale, camera) returned PASS without anyone noticing the
floor was structurally missing. Took THE USER pointing it out.

**Fix**: every visual capture MUST run this baseline checklist BEFORE
the change-specific prompt. If any baseline fails, FAIL the gate
regardless of what the change-prompt says.

### For 3D scenes — required baseline criteria

1. **Ground plane visible**: a flat surface (not the sky's gradient)
   under the entities? Entities cast SHADOWS on a real surface?
2. **Sky / horizon present**: distinguishable from ground (color +
   shape change at horizon line)?
3. **Lighting working**: directional light direction visible in shadow
   angles? Ambient not zero (shadowed faces still partially lit)?
4. **Player visible at expected position**: not collapsed at origin,
   not below ground, not floating?
5. **HUD readable**: text + bars rendered, not clipping off-screen?
6. **No placeholder geometry**: no untextured pink boxes, no default
   cubes, no missing-mesh warning planes?
7. **At least one named entity visible (added 2026-05-08)**: any
   sky+ground capture WITHOUT entities is a FAIL even if criteria
   1-6 pass — entities being invisible is a regression class
   masquerading as "empty scene". Look for ANY non-HUD non-ground
   non-sky pixel: a building silhouette, a capsule (NPC), a sphere
   (item), a colored prop. If the entire 3D viewport is just sky
   gradient + flat ground horizon, FAIL the gate. Empirical case:
   2026-05-08 — `Basis.looking_at(_, _, true)` typo flipped Camera3D
   forward axis; pendrel/brookhaven shipped looking exactly correct
   (sky + ground present, lighting working) but with the camera
   pointing 180° away from all entities. Static baseline 1-6 missed
   it; this entity-presence check catches it.

### For 2D scenes — required baseline criteria

1. **Floor color visible**: bounds polygon rendered (not blank gray)?
2. **HUD readable**: text + bars rendered?
3. **Camera positioned over content**: entities in viewport, not at
   (0,0) when they're at (1500, 2400)?
4. **No placeholder shapes**: pink-fallback or grey-box visible
   anywhere?

### Reference-template comparison check

If your change creates or modifies a `.tscn` scene file: compare
node-list against the canonical reference for the renderer mode:

- 3D scenes: compare against `godot/scenes/doomarena3d.tscn` OR
  `godot/scenes/towerdef3d.tscn` — list missing nodes. Canonical
  3D scene needs at minimum: World, WorldEnvironment, Sun
  (DirectionalLight3D), **Ground (MeshInstance3D + PlaneMesh +
  Material)**, GameShell, ScreenFlow, OverlayManager,
  SettingsManager, LightingDirector (for ADR 0025), Camera3D.
- 2D scenes: compare against `godot/scenes/play.tscn`. Needs at
  minimum: World, GameShell, ScreenFlow, OverlayManager,
  SettingsManager, Camera2D.

Write the comparison into your VQA prompt:

```
"After creating <name>_3d.tscn, compare its node structure to
godot/scenes/doomarena3d.tscn. List any nodes present in doomarena3d
but missing in <name>_3d, OR any required node types absent. Required
3D nodes: WorldEnvironment, DirectionalLight3D, MeshInstance3D
(Ground), Camera3D. FAIL if any required node type is missing,
even if the capture renders something plausible."
```

This catches the merchant-no-floor class of bugs at frame 1, not
3 sessions later.

## Context-specific prompt examples (by change type)

### After adding/modifying entity defs (content-designer)

```
"After adding 5 NPC types (warrior/mage/archer/townie/noble) to
Pendrel city:
1. Are 5 visually distinguishable NPCs visible (different shirt
   colors per archetype)?
2. Player still has hat + green shirt + skin face?
3. NPCs at expected scale (~1.7m, similar to player height)?
Fail flags: all NPCs same color, NPCs floating off-ground,
NPCs collapsed to origin."
```

### After camera/scene-config change (asset-designer)

```
"After switching from top_down_3d to isometric_3d camera mode:
1. Can I see entity BODIES (not just hat-tops)?
2. Is the perspective tilted ~30-45° (an HD-2D JRPG HD-2D feel)?
3. Are shadows visible on the ground plane?
4. Are buildings 3D-shaped (visible walls + roof) not flat tiles?
Fail flags: still seeing only sphere-tops, sky filling >50% frame,
no shadows."
```

### After screen-flow change (screen-flow-designer)

```
"After implementing the haggle screen (signature merchant verb):
1. Is the haggle modal centered with darkened background?
2. Are 3 bands (RED/YELLOW/GREEN) visually distinct?
3. Is the slider Control element visible and labeled?
4. Are 3 buttons (Accept/Counter/Reject) reachable + labeled?
5. Is customer name + offered price visible above the slider?
Fail flags: blank modal, 0-size buttons, all bands same color,
slider clipped off-screen, no customer info."
```

### After animation change (ADR 0035 — mesh-def animations / animation_state_rules)

**Single-frame captures CANNOT verify animation.** They show one instant.
A frozen-mid-stride limb and a properly-animated limb look identical in
one frame. Any change to:

- `mesh_def.animations` block (tracks, keyframes, state names)
- `mesh_def.animation_state_rules` (state-selection logic)
- `animation_director.gd` (interpreter)
- mesh primitives with `name` field (addressable pieces)

REQUIRES at least **two captures separated in time**, with the entity
visibly in motion (or whatever state the animation depends on):

```bash
# Frame A at t=2s
godot ... --capture-after=2.0 --capture-output='user://anim_A.png'

# Frame B at t=2.3s (0.3s later — captures a different point in the
# animation cycle; walk duration is typically 0.5-1.0s so 0.2-0.4s
# gives a visible phase shift)
godot ... --capture-after=2.3 --capture-output='user://anim_B.png'
```

Then **read BOTH PNGs and compare**:
- Frame A: arm forward, leg back?
- Frame B: arm back, leg forward (mid-stride swap)?
- If both identical → animation isn't firing, OR entity isn't in the
  expected state (e.g., velocity below threshold for walk).

**Read prompt template** for the comparison:

```
"Compare anim_A.png (t=2.0s) and anim_B.png (t=2.3s). The entity
<name> at position <p> should be walking toward <target>.

1. Is the entity visible in both frames?
2. Is its position different between A and B? (Walking)
3. Are limb positions DIFFERENT in A vs B? (Animation firing)
4. If yes to 1+3 but no to 2 — entity isn't moving but limbs animate
   (maybe stuck against blocks_motion?).
5. If yes to 1+2 but no to 3 — entity moves but limbs frozen
   (animation_state_rules not selecting walk, OR ScheduleDirector /
   ambient_wander not setting velocity, OR animation_director not
   ticking).
6. Fail flag: identical-looking entity across both frames + no
   position delta + no limb delta → motion not happening at all
   (likely missing director node or missing rule)."
```

**Empirical case 2026-05-11**: silent-idle fix in `villager_3d` shipped
after a single capture-after=2 verified boot-clean. Multi-frame test
was skipped. Could not have detected that ScheduleDirector wasn't
mounted in `aldenmere_3d.tscn` — villagers were perfectly still in
the still frame, which is exactly what the silent-idle change was
SUPPOSED to do. Author was confidently wrong. User had to ask "did you
actually check?" before the gap surfaced.

**The gate**: any animation-affecting change must include at least one
multi-frame comparison capture in the verification log before declaring
done. Skipping this gate = false confidence.

### After scene-tree change (mounting / unmounting engine director nodes)

Adding or removing a `<Director>` Node in a per-game `.tscn` (e.g.,
ScheduleDirector, PartyDirector, FactionDirector) changes whether a
subsystem fires at runtime. Single-frame capture won't show it.

For ADDED directors:
- Capture a scene where the director's effect is visible (e.g.,
  ScheduleDirector added → capture an NPC walking via schedule).
- 2-frame sequence per the animation-gate pattern above.

For REMOVED directors:
- Capture the game booting cleanly (no missing-method errors in stderr).
- Run scenario tests if they cover the subsystem.

**Empirical case 2026-05-11**: `aldenmere_3d.tscn` shipped without
ScheduleDirector mounted. All NPCs sat motionless. Villager schedule
blocks existed in defs but engine had no node to drain them. Surfaced
only when the user asked about animation. A pre-launch validator
(`tools/validate_scene_directors.py`) catches this at sync time —
see `.claude/rules/data-demo.md` § scene-director audit (to be added
alongside this gate).

### After juice/effect change (juice-designer)

```
"After adding screen-shake on enemy kill + red flash on damage:
This is frame N+1 after a player_attack input was queued at N.
1. Is the screen visibly shaken (camera offset from baseline)?
2. Is there a red flash overlay (alpha-blended red rect)?
3. Is the enemy entity removed from the frame?
4. Is the toast 'Hit' visible briefly?
Fail flags: no shake (amplitude=0), flash too long (still red
3+ frames later), enemy still present (kill rule didn't fire)."
```

### After level-layout change (level-designer)

```
"After arranging Pendrel city — player at (47, 0, 75), shop at
(59, 0, 75), market 3 stalls at ~(75, 0, 94):
1. Is the player visible center-screen?
2. Is the shop building to the EAST (right) of player?
3. Are 3 supplier stalls visible to the NORTH-EAST?
4. Spread feels like a town (~10-30m radius), not bunched at
   origin or scattered to horizon?
Fail flags: empty world (camera off), all entities clumped at
origin, shop on wrong side, no spread sense."
```

### Multi-stage capture (after scripted input)

```
"This is the THIRD capture in a sequence:
- t0: player at (47, 0, 75) facing east
- t1: walked east 3.5s → expected at (~57, 0, 75)
- t2 (this capture): waited 10s → customers should have walked
  in + sale rule fired

Verify:
1. HUD shows 'Sold today: ≥1' (sale rule triggered)?
2. HUD gold > 500g starting (sale added gold)?
3. No customer entity visible (removed after sale)?
Fail flags: Sold today still 0 (customer didn't reach player),
gold unchanged (sale rule effect didn't fire)."
```

## Prompt construction rule of thumb

**Bad** ❌: "Does this look ok?"
**Bad** ❌: "Verify visual quality."
**Bad** ❌: "Is the game rendering?"

**Good** ✓: "After change X, check criteria 1-4 with these specific
fail flags."

Aim for 3-5 falsifiable criteria + 2-3 specific fail flags per VQA
prompt. Each criterion should be answerable with PASS/FAIL by
looking at the image. If you can't write a fail flag, you don't
know what you're checking.

## Screen-flow gate (MANDATORY for any skill touching screens.json or rule effects)

The visual capture catches "scene renders wrong" but not "button click
does nothing because target is unrecognized." This gate has two layers:

### Layer 1 — static validator (cheap, runs at sync time)

Run `tools/validate_screens.py` against the game's data dir. It scans
every `transition_screen` effect across screens.json + game/rules.json
+ levels/*/rules.json + game/*_staged.json and verifies the `target` is
either a known screen id OR the special token `@previous`.

```bash
# Strict mode (exits 1 on broken refs) — agents + CI use this
python3 tools/validate_screens.py demo_<name> --strict

# Non-strict (warns, exits 0) — play.sh uses this so the user can still
# play with known dangling refs. Skill agents must NOT rely on this mode.
python3 tools/validate_screens.py demo_<name>
```

Wired into `scripts/play.sh` as a non-blocking pre-launch check. Set
`SKIP_VALIDATE=1` to bypass.

**Skills that MUST run --strict before declaring done**:
- yume-screen-flow-designer (writes screens.json)
- yume-game-rules-designer (rule effects often fire transitions)
- yume-tutorial-designer (overlay → screen handoffs)
- any skill that splices a `*_staged.json` into the active config

### Layer 2 — click-flow smoke test (engine work — Session 6 scope)

Static validator can't catch effect-chain bugs (effects after a
destructive transition silently dropped — see § effect-chain gate in
`.claude/rules/engine-scripts.md`). For full coverage:

1. Boot the game with `--capture-input='ui_accept,N'` to fire ui_accept
   N times, walking through advance_action='ui_accept' overlays + the
   default-focused button on each screen.
2. Capture stdout to a log.
3. `grep -E "push_warning|SCRIPT ERROR|Parse Error" /tmp/play.log` —
   any match is a fail.

This catches: latent rule-fired transitions to never-built screens,
mistyped action names, broken on_change handlers, missing effects.

The `--smoke-screens` mode that walks every screen + every button
programmatically is Session 6 engine work. Until it lands, run the
boot+ui_accept variant manually after any change to screens.json or
screen-firing rules.

## Per-skill prompt cheat sheets

(Reference templates per skill. Compose your specific prompt by
combining the relevant section + the change description.)

### Content + Level + Systems designers — base criteria

- Player visible at expected position (not collapsed at origin)
- All named entities from world-plan render at expected positions
- Spread feels right (not bunched, not invisibly far)
- Scale sanity (player ~human-height, props proportional)
- HUD overlays correctly (no z-order bug)
- Camera framing reasonable (key entities in view)

Add change-specific criteria on top.

### Asset designer — base criteria

- Visual style consistent (palette + theme coherence)
- No placeholder / fallback shapes shipped (pink boxes, default cubes)
- Entity differentiation legible (player vs NPC vs enemy at glance)
- Lighting matches scene.json lighting block expectations
- Audio cues fire at expected events (cross-check with capture-input)

### Screen + Tutorial + Juice designers — base criteria

- Screen renders at all (no blank gray)
- Buttons clickable (not 0-size or off-screen)
- Text readable (size, contrast, font-availability)
- Modal screens darken background per spec
- Overlays z-ordered above world but below toasts
- Particles fire at correct positions
- Camera shake amplitude matches event severity

## Using the `visual-qa` skill (Gemini Flash + Claude vision)

The standalone `visual-qa` skill (different from this rule) accepts
a custom prompt parameter. When invoking it for regression detection
or aggregated multi-model review:

```
Skill(skill="visual-qa", args="<custom prompt> path=<png>")
```

Same prompt-construction discipline applies. The aggregator runs
both Gemini Flash + Claude vision against the same prompt, then
reports per-model verdicts. Disagreement between the two = signal
to look more carefully.

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

## When launching subagents — race-free architecture

CRITICAL: when MULTIPLE builder agents run in parallel (per yume-design
parallel-execution discipline), they share `/mnt/c/.../YumeTemplate/`.
If each agent runs `cp -r → godot`, the cp's race-overwrite each
other and godot processes see mixed state → non-deterministic tests
and corrupt captures. Empirically observed (Session 2 nearly hit
this — got lucky from accidental serialization).

**Rule for parallel builder agents**:
- ✅ DO write source files in `/home/kamwoh/yume/godot/` (their
  owned files only, per file-ownership pre-allocation)
- ❌ DO NOT `cp -r` to YumeTemplate
- ❌ DO NOT run godot binary
- ❌ DO NOT run unit tests OR visual QA

**Rule for orchestrator**:
- Wait for ALL parallel agents to complete
- Run a SINGLE `cp -r` sync to YumeTemplate
- Run unit tests once (after integration)
- Run visual QA once (after integration), with context-specific
  prompts per the integrated state

This means parallel agents report back staged files only. The
orchestrator validates the integrated whole.

**Rule for solo / sequential builder agents**:
- May `cp -r` + run godot themselves (no race risk)
- Visual QA per the standard pattern

**Pattern for parallel-agent prompt** (use this in their
instructions, not the previous version):

```
After your implementation completes:
1. Verify your written files exist with correct content
2. DO NOT sync to YumeTemplate (the orchestrator owns sync)
3. DO NOT run godot or any test/capture commands
4. Report back: files written + line counts + any concerns

The orchestrator will sync once, run unit tests, run visual QA
across the integrated state, and report whether YOUR change
landed correctly.
```

For solo / sequential agent prompts (when only 1 agent at a time
modifies the source tree), the previous sync+godot pattern is fine.

This is non-negotiable for parallel execution: rendering-primitive
changes, scene changes, mesh/shape additions, screen/overlay/HUD
changes, particle effects, shader work — ALL require orchestrator-
owned validation when parallelized.
