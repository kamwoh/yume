# Visual QA — mandatory gate for visual-touching changes

Any change affecting what the player SEES must be visually verified
before declaring done. "It compiles, tests pass" is correctness; this
gate is *playability*. Functional captures regularly pass while shipping
broken UI (merchant 2026-05-07: 12 scenario tests green, the user
loaded the game and the camera was off-screen).

## Who runs this

Skills that write/modify content or code affecting rendering:
- yume-content-designer (entity defs + initial placements)
- yume-game-rules-designer (game/goals.json — transitions, screens, effects)
- yume-systems-designer (world/rules.json — motion, AI, spawn timing)
- yume-asset-designer (visual fields per entity; scene/hud config)
- yume-level-designer (coordinates / spatial layout)
- yume-screen-flow-designer (screens.json)
- yume-tutorial-designer (tutorial.json)
- yume-juice-designer (particles, shake, flash)
- yume-visual-designer (core role)

Skills that don't touch visuals (game-designer, game-planner,
game-reviewer, ...) are exempt. Engine builders running rendering-
adjacent ADRs: per `.claude/rules/engine-scripts.md` § visual gate.

## Procedure

### Step 0 — FRAME the feature (MANDATORY before capture)

The player's spawn-point view rarely contains the specific feature
you changed. Before `--capture`, answer: **"will the feature I'm
verifying actually BE in this frame?"** Two paths:

(a) **Free-cam scripted** — `--capture-input='toggle_freecam,0.3'`
(0.3s min hold or the press-edge doesn't register). Temporarily
reposition the active `free_camera` entity's `state.position`/`yaw`/
`pitch` to the target framing; restore after.

(b) **Pre-author dedicated test cameras** — add `free_camera`
initial_instances at well-framed test points (`camera_water_test`,
`camera_relief_oblique`, etc.); set `active_camera_id` to the
desired test camera before capture.

### Step 0a — DERIVE world position from authoritative data

The world tells you where features are. Don't improvise — derive
from the right primitive:

| Verifying… | Source | Extract |
|---|---|---|
| Biome / ground material | `assets/layouts/<map>.png` (semantic, biome ref colors in `scene.json`) | sample matching pixels → centroid → world (x/w − 0.5)·plane |
| Terrain relief | `assets/textures/*heightmap*.png` | argmin/argmax of R-channel → valley + peak coords; profile vantage perpendicular |
| Named entity | `levels/<n>/entities.json` `initial_instances` | grep `def == "<name>"` → `position` |
| Lighting / shadow direction | `scene.json.lighting.sun.direction` | specular azimuth = ± sun direction |
| Pattern cluster | `levels/<n>/entities.json` `patterns[]` (center + radius) | pattern center = framing target |
| Player POV / signature beat | `docs/games/<game>/GDD.md` | beat's stated location or named anchor |
| Composition / focal point | largest `state.scale` entity OR named `fire_pit`/`well`/`shrine` | place camera looking IN at it |

```python
# Biome centroid → world coord (Python one-liner)
from PIL import Image
img = Image.open("...semantic_map.png").convert("RGB"); w,h = img.size
ref = (48, 112, 192)   # water ref from scene.json biome_color_water
data = img.load(); xs=[]; ys=[]
for y in range(0,h,4):
    for x in range(0,w,4):
        if sum((a-b)**2 for a,b in zip(data[x,y], ref)) < 5000:
            xs.append(x); ys.append(y)
cx=sum(xs)/len(xs); cy=sum(ys)/len(ys); plane=80.0
print((cx/w - 0.5)*plane, (0.5 - cy/h)*plane)  # → (wx, wz)
```

Write the target down as `target = (wx, wy, wz)` BEFORE picking
camera angle — it's the LOOK-AT point.

### Step 0b — DERIVE camera params from feature class

| Feature class | Framing | Height | Pitch | Distance |
|---|---|---|---|---|
| Animation (ripples, particles, weather) | Multi-frame A/B at target; diff with `.convert('RGB')` first (PIL ImageChops drops modes silently) | 10-20m | -1.0 to -1.4 | 0 |
| Material differentiation (water shine vs grass matte) | Oblique so specular shows | 3-8m | -0.3 to -0.5 | 5-15m toward sun-azimuth |
| Vertex displacement / relief / hills | Low-angle profile reveals bumps | 0.5-1.0m | -0.05 to -0.15 | 10-30m perpendicular to slope axis |
| Color blending / biome boundaries | Top-down so regions show | 15-30m | -1.4 to -1.5 | 0 |
| Lighting transitions / dawn-grazing | Camera aligned with light azimuth | 2-5m | -0.1 to -0.3 | 10-20m, light vector behind camera |
| HUD / screens | Player's intended camera | — | — | — |
| Scene composition / focal point | Eye-level wide from outside focal radius, looking IN | 1.6-3m | -0.05 to -0.2 | focal radius × 1.5 |

Camera position = `target + offset_vec * distance`; LOOK AT target
(yaw + pitch derived from look vector, not guessed).

### Step 0c — Scene sanity sweep (one extra capture per session)

After framing the feature, ALSO take ONE wide overview from a
random vantage. Catches unrelated regressions: mystery cubes (missing
`visual.hidden=true` per data-demo.md), floating meshes (`y_offset`),
z-fighting, terrain holes, pink fallback meshes. Empirical 2026-05-21:
free_camera defs rendered as cubes for the whole session before a
sanity sweep would've caught it.

### Step 1 — Capture

```bash
./scripts/play.sh <name> --capture
# OR for scripted-input flows:
godot --path <template> scenes/<name>_3d.tscn --rendering-driver opengl3 \
  -- --game=<name> --capture-after=2 --capture-input='move_east,3.0' \
  --capture-output=user://_named.png
```

PNG lands under `~/.../app_userdata/Yume Framework/_named.png` (or
the local user:// resolved path).

**Capture-timing note (2026-06-12, autorace)**: scripted
`--capture-input` bursts run sim ticks synchronously at boot; the
`--capture-after` settle window then COASTS in real time. For motion
before/after shots, end the script with a stop action (brake) or
capture immediately — otherwise the subject keeps moving through the
settle window and the "after" frame lies. Related: at low render fps
the sim runs slower than wall-clock (physics catch-up cap) — don't
write wall-clock timing assertions; use headless scenario ticks.

### Step 2 — Read the PNG with a CONTEXT-SPECIFIC prompt

`Read(/path.png)` then ask Claude with:

```
This capture is from <game> after <change-summary>.
Expected scene state: <what should be on screen now>.
Verify specifically:
1. <criterion 1 — concrete, falsifiable>
2. <criterion 2>
3. <criterion 3>
Failure modes to flag if present:
- <anti-pattern likely given this change>
- <regression vs previous capture>
Report PASS / FAIL with the criterion that failed + observed evidence.
```

The question SHAPES what Claude looks at. Generic "does it look ok?"
misses bugs the focused question catches. Aim for **3-5 falsifiable
criteria + 2-3 specific fail flags** per VQA. If you can't write a
fail flag, you don't know what you're checking.

**Pixel-sample, don't squint (2026-06-12)**: Read-tool previews of
captures can render washed/downscaled. Before any exposure/color
verdict (too dark, washed out, wrong tint), sample pixels — PIL crop
+ per-channel mean over the region in question — and judge the
numbers, not the preview. Empirical: a healthy autorace frame was
nearly mis-diagnosed as broken twice in one session from preview
appearance alone.

## Baseline environmental checks (MANDATORY, runs first)

Run BEFORE the change-specific prompt. If any baseline fails, FAIL
the gate regardless of what the change-prompt says. The merchant
2026-05-07 session passed change-prompts but the scene had NO ground
plane (sky's gradient was mistaken for floor) — only the user noticed.

### 3D scenes — baseline criteria

1. **Ground visible** — flat surface (not the sky's gradient) under
   entities; entities cast shadows on a real surface.
2. **Sky / horizon present** — distinguishable from ground (color +
   shape change at horizon).
3. **Lighting working** — directional light visible in shadow angles;
   ambient not zero.
4. **Player visible at expected position** — not collapsed at origin,
   not below ground, not floating.
5. **HUD readable** — text + bars rendered, not clipping off-screen.
6. **No placeholder geometry** — no untextured pink boxes, no default
   cubes, no missing-mesh warning planes.
7. **At least one named entity visible** — empty sky+ground = FAIL
   even if 1-6 pass. Catches the 2026-05-08 typo (`Basis.looking_at(_,
   _, true)` flipped Camera3D forward axis; scenes rendered "correctly"
   but pointed 180° away from all entities).
8. **Mesh bases ON ground, not buried** — every visible structure/tree/
   prop must have its BOTTOM flush with the floor. Buried = missing
   `visual.y_offset` (Tripo image_to_model meshes have pivot at
   geometric CENTER, not foot). Gate:
   `tools/validators/validate_mesh_y_offset.py --strict`.
9. **HUD direction widgets track camera rotation** — for minimap
   cones, compass arrows, target markers: 4-frame capture (face N/E/S/W)
   and verify the widget tracks. Empirical 2026-05-17: aldenmere
   minimap cone used CW convention; engine yaw is CCW; player faced
   east, cone pointed west.
10. **Tiled ground textures — low-angle CLOSE-UP for the repeat grid**
    — any tiled detail map must be verified with a ground-fill
    close-up (NOT an overview). Overview hides the repeat period;
    ground-level shows the grid. Empirical 2026-05-27: grass detail
    tiled 24× shipped clean from overview captures but showed a
    ~5.8m square grid from ground level.

### 2D scenes — baseline criteria

1. Floor color visible (bounds polygon rendered, not blank gray)
2. HUD readable
3. Camera over content (not at origin when entities are at 1500,2400)
4. No pink-fallback / grey-box visible

### Reference-template comparison check

If your change creates/modifies a `.tscn`: compare node-list against
the canonical reference for the renderer mode.
- 3D scenes: vs `godot/scenes/doomarena3d.tscn` (or `towerdef3d.tscn`).
  Must have: World, WorldEnvironment, DirectionalLight3D (Sun), Ground
  (MeshInstance3D + PlaneMesh + Material), GameShell, ScreenFlow,
  OverlayManager, SettingsManager, LightingDirector, Camera3D.
- 2D scenes: vs `godot/scenes/play.tscn`. Must have: World, GameShell,
  ScreenFlow, OverlayManager, SettingsManager, Camera2D.

VQA prompt: *"Compare X_3d.tscn node structure to doomarena3d.tscn.
List any required-node-types absent. FAIL if any missing, even if
the capture renders something plausible."*

Catches merchant-no-floor at frame 1, not session 3.

## Context-specific prompt examples (compose your own from these)

Each prompt should answer:
1. What I just changed
2. What state the capture is in (post-input, post-time, etc.)
3. What I'm verifying (3-5 falsifiable criteria)
4. What would be a fail flag (2-3 specific anti-patterns)

| Change | Verify criteria | Fail flags |
|---|---|---|
| New entities (N NPCs / props) | All N visible; visually distinguishable; expected scale + position | All same color; floating off-ground; collapsed to origin |
| Camera mode swap (top_down → iso) | Bodies visible (not just sphere-tops); ~30-45° tilt; shadows on floor; buildings have walls + roof | Still seeing sphere-tops; sky filling >50% frame; no shadows |
| Screen flow (modal, e.g. haggle) | Centered with darkened bg; bands visually distinct; slider visible+labeled; buttons reachable; customer info visible | Blank modal; 0-size buttons; bands same color; slider clipped |
| Animation (ADR 0035) | **2-frame capture (`--capture-after=2.0` and `2.3`)** required. Limbs DIFFERENT in A vs B; position changes between A and B (walking); animation_state_rules selecting walk | Identical limbs in both frames; no position delta; entity static frame-to-frame |
| Scene-tree change (mount/unmount director) | Subsystem effect visible (e.g. ScheduleDirector added → NPC walking via schedule) — 2-frame test like animation | No motion at all (likely missing director or rule) |
| Juice/effect (kill flash, shake) | Visible shake offset; flash overlay present; enemy removed; toast visible | No shake (amplitude=0); flash too long; enemy still present |
| Level layout | Player center-screen; named landmarks in expected cardinal directions; town spread feels right (10-30m, not bunched) | Empty world (camera off); clumped at origin; landmark on wrong side |
| Multi-stage capture (after scripted input) | Per-stage HUD state matches expectation (`Sold today: ≥1`, `gold > 500g`, customer gone) | Sale didn't fire; gold unchanged; player off-position |

**Animation specifically**: single-frame captures CANNOT verify
animation. Two captures at `--capture-after=2.0` and `2.3` (0.3s
apart captures a different point in a 0.5-1.0s walk cycle), read
both, diff limb positions. Empirical 2026-05-11: silent-idle "fix"
shipped after a single still frame verified clean — the fix did
nothing (ScheduleDirector wasn't mounted, NPCs were always static).
2-frame test would've caught.

## Screen-flow gate (MANDATORY for any change to screens.json or rule effects)

Visual capture catches "scene renders wrong" but NOT "button click
does nothing because target is unrecognized" (empirical 2026-05-08:
merchant had 11 broken `_close` buttons; 488 unit tests + 12
scenarios green; user hit it first play). Two layers:

**Layer 1 — static validator**: `tools/validators/validate_screens.py
<game> --strict` checks every `transition_screen` target against the
known screen ids (+ `@previous` / `@root` sentinels). Wired into
`play.sh` non-strict; agents must run --strict.

**Layer 2 — click-flow smoke** (manual until --smoke-screens lands):
boot with `--capture-input='ui_accept,N'`, capture stdout to a log,
`grep -E "push_warning|SCRIPT ERROR|Parse Error" /tmp/play.log` →
any match = fail. Catches latent rule-fired transitions to never-built
screens, mistyped action names, broken on_change handlers.

Skills that MUST run --strict: yume-screen-flow-designer, yume-game-
rules-designer (rule effects fire transitions), yume-tutorial-designer,
any skill splicing a `*_staged.json`.

## HUD/UI design gate (MANDATORY for hud.json / screens.json layout changes)

Functional QA ("does it render?") passes ugly layouts all the time.
Empirical 2026-05-16: 3 rounds of HUD consolidation — captures showed
elements present + sized; user kept saying "super ugly." Author had
never compared the layout to any reference game or invoked
yume-visual-designer.

**Three gates, apply ALL when touching layout fields (anchor,
position, size, panel structure)**:

**Gate 1 — Reference compare BEFORE authoring.** Open any reference
image the user shared (e.g. `~/Downloads/ui_refs/`) and list what's
working: where major elements live (corners vs center), visual
hierarchy (what does the eye land on first), whitespace, size
relationships. No reference → name a well-known pattern in the genre
("a farming-sim's distributed-corner HUD", "an open-world RPG's
top-center compass").

**Gate 2 — Design-heuristic VQA**. In addition to functional checks,
the Read prompt MUST ask:
1. Where does the eye land first? Is that the most important element?
2. Visually balanced? Left vs right, top vs bottom — no
   dense-quadrant + empty-opposite.
3. Breathing room? No overlapping widgets, ~10-20px gap between
   distinct widgets.
4. Visual hierarchy? Primary (objective, vitals) prominent;
   secondary (controls hint) quieter.
5. Compare to reference: what's different + is that an improvement?

Failure modes that pass functional but fail design: single-column
stacks (one half dense, opposite empty); widgets at correct coords
visually overlapping due to stretch; controls hint as large as
objective; jagged right/left edges; progress bars stretched to vbox
width when authored at 140px; "centered" modal not actually centered
(anchor + offset math broken).

**Gate 3 — Invoke `yume-visual-designer`** (the dedicated art-direction
reviewer, see `.claude/skills/yume-visual-designer/SKILL.md`). NOT
optional polish — it's the design-review counterpart to tech-director's
invariant review. Functional capture-reads miss design issues by
construction. Invoke for: `hud.json` panel structure/anchors/positions
changes; `screens.json` modal layout; new element types in
control_factory; HudBuilder._build_panel / _panel_defaults changes.

## Per-skill base criteria (cheat sheets)

**Content / Level / Systems designers** — player visible; named
entities at expected positions; spread feels right; scale sanity
(player ~human-height); HUD overlays z-order; camera framing
reasonable.

**Asset designer** — visual style consistent; NO placeholder/fallback
shapes (pink boxes, default cubes); entity differentiation legible;
lighting matches scene.json; audio cues fire at expected events.

**Screen / Tutorial / Juice designers** — screen renders at all (not
blank gray); buttons clickable (not 0-size); text readable; modals
darken background; overlays z-ordered above world but below toasts;
particles fire at correct positions; shake amplitude matches event
severity.

## Using the `visual-qa` skill (Gemini Flash + Claude vision)

```
Skill(skill="visual-qa", args="<custom prompt> path=<png>")
```

Runs both Gemini Flash + Claude vision against the same prompt;
disagreement = signal to look more carefully. Same prompt-construction
discipline.

## When the visual gate FAILS

1. Note the specific defect (location, what's wrong)
2. Hand back to the responsible skill — DON'T fix-and-ship silently
3. After re-fix, re-capture and re-read

NO "I'll fix next session" notes for frame-1-visible bugs. That's
debt the next session may not catch.

## Effect-chain interaction

Visual QA + effect-chain validation (per `.claude/rules/engine-
scripts.md` § effect-chain gate) are TWO gates, not one. Visual
catches "scene renders wrong"; effect-chain catches "button click
does nothing." Both required for screen + overlay changes.

## When invoked by orchestrator

`yume-design` orchestrator runs visual capture in the qa-tester phase
(Tier 2.6r). This rule extends that: every CONTENT-WRITING phase
should also capture+read after its work, before handing off — catches
issues earlier.

## Parallel subagent discipline — race-free architecture

When MULTIPLE builder agents run in parallel (yume-design parallel-
execution), they share `/mnt/c/.../YumeTemplate/`. Each running
`cp -r → godot` races; godot processes see mixed state →
non-deterministic tests + corrupt captures.

**Rule for parallel builders**:
- ✅ Write source files in the repo's `godot/` (owned files
  only, per file-ownership pre-allocation)
- ❌ NOT sync to YumeTemplate
- ❌ NOT run godot binary, tests, or VQA

**Rule for orchestrator**:
- Wait for ALL parallel agents to complete
- Run a SINGLE `cp -r` sync
- Run unit tests once (after integration)
- Run VQA once (after integration), prompts per integrated state

**Solo / sequential builders** may sync + run godot themselves
(no race).

This is non-negotiable for parallel execution of rendering-primitive
changes, scene changes, mesh/shape additions, screen/overlay/HUD
changes, particle effects, shader work.
