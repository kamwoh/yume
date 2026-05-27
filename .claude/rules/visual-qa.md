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
screen-flow gate now runs `tools/validators/validate_screens.py` at sync time AND
this rule mandates a click-flow smoke test before declaring done.

## Who must run this gate

Skills that write/modify content or code that affects rendering:

- **yume-content-designer** — entity defs + initial placements
  (entities visible at expected positions, scale, color)
- **yume-game-rules-designer** — game/goals.json (transitions, screens,
  effects fire visibly)
- **yume-systems-designer** — world/rules.json (motion, AI homing,
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

Three steps, run in sequence. **Step 0 is mandatory** — skipping it
guarantees you'll PASS or FAIL on the wrong frame.

### Step 0: frame the feature (MANDATORY before any capture)

Before invoking `--capture`, answer: **"will the feature I'm
verifying actually be in the frame from this camera?"** The
player's spawn-point view rarely frames a specific feature. The
3rd-person follow camera trails behind the player; the FPS camera
shows whatever is in front. Neither knows about your water region,
relief slope, or specular angle.

Two paths to frame the feature:

**(a) Free-cam scripted control** — for one-off verification:
- Add `--capture-input='toggle_freecam,0.3'` to enter free-cam at
  the start of the run. Minimum 0.3s hold — 0.05s isn't long
  enough for the press-edge to register (empirical 2026-05-21).
- Temporarily reposition the active `free_camera` entity's
  `state.position` / `yaw` / `pitch` in the level's entities.json
  to the target framing. Restore after the capture.

**(b) Pre-author dedicated test cameras** — for repeated checks:
- Add `free_camera` initial_instances at well-framed test points
  (over-water, oblique-relief, low-angle-profile, biome-boundary,
  etc.) named descriptively (`camera_water_test`,
  `camera_relief_oblique`).
- Use Tab to cycle between them OR set `active_camera_id` on
  world_clock to the desired test camera before capture.

### Step 0a — DERIVE world position from authoritative data (don't guess)

The world tells you where its features are. Consult these primitives
BEFORE picking a position — never improvise. The signal source is
chosen by what kind of feature you're verifying:

| Verifying… | Authoritative source | What to extract |
|---|---|---|
| Biome / ground material (water shine, dirt blend, path traffic) | `assets/layouts/<map>.png` (semantic map referenced from `scene.json.ground.mesh.shader_params.biome_map`) | Sample pixels matching the biome's reference RGB → centroid → world coord via `(x/w - 0.5) * plane_size` and `(0.5 - y/h) * plane_size`. |
| Terrain relief (heightmap displacement) | `assets/textures/*heightmap*.png` | Sample R-channel; locate (argmin, argmax) for valley and peak coords; pick a profile vantage perpendicular to their line. |
| Named entity (a specific NPC, fire_pit, well, focal anchor) | `levels/<level>/entities.json` `initial_instances` | Grep for `def == "<name>"` → read `position`. |
| Lighting / shadow direction / dawn-grazing | `scene.json.lighting.sun.direction` (Vector3) | Sun direction defines specular highlight azimuth; place camera looking along ± that axis. |
| Patterns / scattered prop clusters | `levels/<level>/entities.json` `patterns[]` (center + radius) | Pattern center is the cluster's framing target. |
| Player POV / signature beat | GDD `docs/games/<game>/GDD.md` "signature beats" section | Beat's stated location coordinates or named anchor. |
| Composition / focal point | `levels/<level>/entities.json` — entity with the largest `state.scale` OR named "fire_pit" / "well" / "shrine" | The visual anchor; place camera looking IN at it. |

**Concrete pattern (Python one-liner for biome centroids)**:

```python
from PIL import Image
img = Image.open("data/<game>/assets/layouts/<map>.png").convert("RGB")
w, h = img.size; data = img.load()
ref = (48, 112, 192)  # water ref (read from scene.json biome_color_water)
xs, ys = [], []
for y in range(0, h, 4):
    for x in range(0, w, 4):
        if sum((a-b)**2 for a,b in zip(data[x,y], ref)) < 5000:
            xs.append(x); ys.append(y)
cx, cy = sum(xs)/len(xs), sum(ys)/len(ys)
plane = 80.0  # from scene.json ground.mesh.size[0]
print((cx/w - 0.5)*plane, (0.5 - cy/h)*plane)  # → world (x, z)
```

Write the world coord down — `target = (wx, wy, wz)` — before
picking a camera angle. This becomes the LOOK-AT point. The camera
position is derived from it via the angle table below.

### Step 0b — DERIVE camera params from feature class

| Feature class | Required framing | Height | Pitch | Distance to target |
|---|---|---|---|---|
| Animation (ripples, particles, flame, weather) | Multi-frame A/B at target. Diff with `.convert('RGB')` first — PIL ImageChops drops modes silently. | 10-20m | -1.0 to -1.4 (mostly straight down) | 0 (camera above target) |
| Material differentiation (water shine vs grass matte) | Oblique so specular highlights show | 3-8m | -0.3 to -0.5 | 5-15m offset toward sun-azimuth |
| Vertex displacement / relief / hills | Low-angle profile so silhouette reveals bumps | 0.5-1.0m | -0.05 to -0.15 | 10-30m on the side, perpendicular to slope axis |
| Color blending / biome boundaries | Top-down so semantic regions show | 15-30m | -1.4 to -1.5 | 0 (directly over boundary) |
| Lighting transitions / dawn-grazing | Camera aligned with light azimuth so shadow falloff is in frame | 2-5m | -0.1 to -0.3 | 10-20m, light vector behind camera |
| HUD / screens / overlays | Player's intended camera (FPS default) — HUD is viewport-anchored not world-anchored | — | — | — |
| Scene composition / focal point | Eye-level wide from outside focal radius, looking IN | 1.6-3m | -0.05 to -0.2 | focal radius × 1.5 |

The position is then:

```
camera_pos = target + (offset_vec * distance_to_target)
camera_pos.y = height
camera_yaw = atan2(target.x - camera_pos.x, -(target.z - camera_pos.z))
camera_pitch = (from table)
```

Where `offset_vec` depends on the angle desired (sun-azimuth, slope-
perpendicular, anchor-radial). The camera always LOOKS AT the
target — yaw + pitch derived from the look vector, not guessed.

### Step 0c — Scene sanity sweep (one extra capture per session)

After framing the feature, ALSO take ONE wide overview capture
from a random vantage point (e.g. high overhead at level center,
or from a corner looking diagonally across). Inspect for
unrelated artifacts:

- Mystery cubes (missing `visual.hidden=true` on logical entities —
  see data-demo.md)
- Floating meshes (missing `y_offset` on AI-gen models)
- Z-fighting (overlapping ground decals, walls)
- Terrain holes (subdivision boundary tears in heightmap shaders)
- Pink fallback meshes (failed texture loads, broken shader params)

This is cheap insurance against the bug class where you verify the
feature correctly but ship a regression in unrelated geometry.
Empirical case 2026-05-21: free_camera defs rendered as cubes at
their initial_instance positions for the entire session before
being caught by the user. A scene sanity sweep after task #83
would have caught it before tasks #80-#82.

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
8. **Mesh bases ON the ground, not buried (added 2026-05-17)**:
   for every visible structure / tree / large prop, confirm its
   BOTTOM is flush with ground (you can see where the mesh meets
   the floor). If the bottom is below the ground plane (buried),
   that's a `visual.y_offset` missing — Tripo3D meshes have their
   pivot at the geometric center, so placing at y=0 buries the
   lower half. Empirical case 2026-05-17: aldenmere shipped 28 AI-gen
   entities (mud_hut, lean_to, well, fish_trap, market_stall, all
   trees, all foragables) with NO y_offset for 5 visual-review
   iterations because the TOP half was visible and self-assessment
   kept saying "structure visible" without checking the base. Caught
   only when user explicitly asked. Gate: run
   `tools/validators/validate_mesh_y_offset.py <game> --strict`
   before declaring a 3D scene visually-done. Static gate; sync-time
   catch.
9. **HUD direction widgets track camera rotation (added 2026-05-17)**:
   for any HUD widget that indicates direction (minimap cone, compass
   arrow, waypoint marker, target indicator), rotate the camera
   90° each direction in a capture sequence and verify the widget
   tracks. Empirical case 2026-05-17: aldenmere minimap_widget
   `_draw_view_cone` formula used CW convention while
   `camera_director.gd` rotates Camera3D Y by `facing` directly
   (Godot Y-rotation is CCW). When player looked east the cone
   pointed west. Bug shipped in feature #105 commit (2026-05-16)
   + survived a session of visual iteration because no rotation
   test existed. Gate: any HUD change that touches a
   direction-indicator widget must include 4-frame capture (face
   N/E/S/W) and visual verification.
10. **Tiled ground textures — LOW-ANGLE CLOSE-UP for the repeat grid
    (added 2026-05-27)**: any change that adds or tiles a texture on
    the ground (grass detail map, terrain albedo, decals) MUST be
    verified with a low-angle close-up capture where the ground
    surface FILLS the lower frame — NOT just an overview or mid-shot.
    A tiling texture shows a regular grid of squares at the repeat
    period, and that grid is invisible from a high/overview angle (the
    repeats are tiny) but glaring from ground level. Look for any
    repeating square/blotch pattern at a fixed spacing. Empirical case
    2026-05-27: the grass detail map shipped (commit 592f2db) tiling
    24× across the field; overview + mid captures looked fine, but a
    ground-level close-up showed an obvious ~5.8m square grid. Fix was
    a second rotated octave in the shader to break the repeat. Gate:
    tiled-texture changes verify a ground-fill close-up AND, if the
    texture is low-contrast, confirm it's actually visible (not washed
    out to flat).

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
(`tools/validators/validate_scene_directors.py`) catches this at sync time —
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

Run `tools/validators/validate_screens.py` against the game's data dir. It scans
every `transition_screen` effect across screens.json + game/goals.json
+ levels/*/rules.json + game/*_staged.json and verifies the `target` is
either a known screen id OR the special token `@previous`.

```bash
# Strict mode (exits 1 on broken refs) — agents + CI use this
python3 tools/validators/validate_screens.py demo_<name> --strict

# Non-strict (warns, exits 0) — play.sh uses this so the user can still
# play with known dangling refs. Skill agents must NOT rely on this mode.
python3 tools/validators/validate_screens.py demo_<name>
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

## HUD/UI design gate (MANDATORY for any change to hud.json or screens.json layout)

Functional QA ("does it render?") is NOT enough for HUD/UI work.
Visually ugly layouts pass functional checks all the time — every
element renders at its specified rect, no clipping, no crashes — but
the result still feels bad. Empirical: 2026-05-16 consolidated-HUD
session shipped through functional captures cleanly. User reaction:
"every hud not align now. super ugly." The consolidated layout had
all elements present at correct coordinates; it was just bad design.

When you touch `hud.json` or `screens.json` LAYOUT fields (anchor,
position, size, panel structure), apply ALL THREE gates BEFORE
declaring done:

### Gate 1 — Reference compare BEFORE authoring

If the user has previously shared a reference image (e.g. files
under `~/Downloads/ui_refs/`, or screenshots they pasted in a prior
turn), open the reference FIRST and list what's working in it:

- Where do the major elements live (corners vs center)?
- What's the visual hierarchy — what does the eye land on first?
- How much whitespace is between elements?
- What's the size relationship — primary big, secondary smaller?

Then describe how your proposed change relates to the reference.
The reference is the visual contract. You're not authoring in a
vacuum.

If no reference exists, name a well-known game in the genre and
mentally compare ("Stardew Valley uses distributed-corner HUD",
"Skyrim puts compass top-center + map M-key", etc.).

### Gate 2 — Design-heuristic VQA prompt (replaces "does it render?")

When you Read the capture, the prompt MUST include these questions
in addition to the change-specific criteria:

1. **Where does the eye land first?** Is that the most important
   element on screen? If the player's eye lands on a controls hint
   before the objective, hierarchy is inverted.
2. **Is the screen visually balanced?** Look at left vs right
   halves, top vs bottom halves. If one quadrant is dense and the
   opposite is empty, the layout is unbalanced. Distributed-corner
   HUDs almost always feel better than single-column stacks.
3. **Does each element have breathing room?** No overlapping
   widgets, no widgets touching the screen edge unintentionally,
   no widgets crammed against each other. ~10-20px gap between
   distinct widgets is a baseline.
4. **Is the visual hierarchy correct?** Primary info (objective,
   vitals) should have visual prominence (size, contrast, position).
   Secondary info (controls hint) should be quieter (smaller, dimmer,
   bottom edge).
5. **Compare to a known-good reference.** What's different? Why is
   that difference an improvement, or is it a regression?

Failure modes that PASS functional QA but FAIL design heuristics:

- All HUD elements stacked in one column (one half dense, other empty)
- Widgets at correct coords but visually overlapping due to stretch
- Widgets at correct coords but at wrong VISUAL hierarchy (controls
  hint as large as objective)
- Inconsistent widths producing jagged right/left edges
- Progress bars stretched to vbox width when authored at 140px
- Centered modal not actually centered (anchor + offset math broken)

If you can't answer YES to all 5 questions, hand back to the
designer (or invoke `yume-visual-designer`) before declaring done.

### Gate 3 — Invoke yume-visual-designer for HUD/screen layout changes

`yume-visual-designer` exists as a dedicated art-direction reviewer
(see `.claude/skills/yume-visual-designer/SKILL.md`). It's NOT
optional polish — it's the design-review counterpart to
yume-tech-director's invariant review. Functional capture-reads
miss design issues by construction.

For any change to:
- `hud.json` panel structure / anchors / positions
- `screens.json` modal layout
- New element types in control_factory.gd
- HudBuilder._build_panel or _panel_defaults changes

Invoke `yume-visual-designer` with the capture before merging.

### Empirical case 2026-05-16 — three rounds of HUD consolidation

User originally said "hud location is weird, put at right top."
Author (Claude) interpreted as "consolidate ALL HUD to top-right" and
shipped a single-column right-side stack. Captures showed all
elements present + correctly sized — functional QA passed cleanly.

User feedback: "every hud not align now. super ugly."

Author iterated to fix progress-bar stretching, adjust alignments,
tighten heights. Captures still showed "elements present + sized."
Each round: functional QA passes, user still unhappy.

Round 3, user explicitly described the right layout: "should be
left top day 1/3, autumn, time 10h. bottom left is the vital, top
right is the minimap. bottom right is the inventory thingy. top is
the indicator. bottom is the control thingy."

That's classic distributed-corner HUD (Stardew, Skyrim, every RPG).
Author had never compared the consolidated layout against any
reference game. Functional QA was running on autopilot — no design
heuristics, no reference compare, no invocation of
yume-visual-designer.

**The lesson**: design judgment is a different skill from layout
math. Both must be applied. Functional capture-read covers "does it
render?" Design heuristics + reference compare + yume-visual-designer
cover "is it good?"

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
