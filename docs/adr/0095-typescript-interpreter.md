# ADR 0095 — A second interpreter in TypeScript, on three.js

_Date: 2026-10-18_
_Status: accepted 2026-10-18_

_Related: ADR 0086 (host-neutral spec), ADR 0088 (formula language), ADR 0090 (spec vocabularies), ADR 0091 (articulated bodies), ADR 0092 (sensors)_

## Context

ADR 0086 made the JSON a host-neutral spec, with Godot as the reference
interpreter. All five phases are done. No second interpreter exists, so
the spec is neutral only on paper. A second host is the only real test.

The owner asked on 2026-10-18 whether three.js is a better backend than
Godot. The answer was: not as a replacement, but yes as a second host.

- **Godot is stronger** at rendering speed for large 3D scenes, and it
  includes physics, UI, audio, navigation and animation.
- **A web host is stronger** at distribution. A game opens from a link in
  one second. A Godot web export is a large WASM download and needs
  special server headers.
- **JavaScript runs the interpreter logic faster than GDScript.** Rules,
  queries and formulas are the hot path of a rule-heavy game.
- **Rapier**, a WASM physics library, has multibody joints with motors,
  and it can be deterministic across machines.

Three.js is a renderer only. Rogue Engine adds an editor and a component
system on top of three.js. Yume does not need either, because the JSON
spec has that role. So this ADR uses plain three.js.

### Facts found while scoping

1. **The conformance suite is not in a fresh clone.** The contract says
   that `tests.json` scenarios are the conformance suite. But demos are
   gitignored, and only three demos keep tracked tests (sokoban,
   lanterns, doomarena3d). They also hold paid generated assets.
2. **Randomness is not portable.** `randf()` in formulas and the rule
   `chance` field call Godot's global generator. ADR 0086 left this
   question open.
3. **Some formula functions differ between hosts.** For example, Godot
   `round(-2.5)` is -3, and JavaScript `Math.round(-2.5)` is -2. The
   formula language (ADR 0088) names the functions but not every edge.
4. **The exact layer is small.** `core/` holds about 6,200 lines of
   GDScript: entity, rule, query, formula, the scheduler and the effects.
   The full engine is about 28,000 lines without renderers and tests.
5. **Contact is exact.** A `contact` rule pairs entities by radius
   through the spatial index, not through physics. So a TypeScript host
   can match it exactly.

## Decision

Build a TypeScript interpreter in four phases. Each phase ends when a
stated set of conformance cases pass on both hosts.

### 1. Where the code lives

- `hosts/web/`: the TypeScript interpreter. It is an npm package with
  Node for headless runs and Vite for the browser.
- `spec/conformance/<case>/`: small tracked games, each with a
  `tests.json`. They use only code-drawn content, so they hold no
  generated assets.
- The Godot scenario runner reads a conformance case by path. CI runs
  the TypeScript host on every case, because Node runs in CI and Godot
  does not.

### 2. Phases

| Phase | Scope | Done when |
|---|---|---|
| 1. Headless core | Entity, tags, state, relations, formulas and queries. Rules with all 9 triggers, the 4 tick phases, the calendar clock and contact by radius. The exact effects (state, zone, spawn, remove, transform, relations, tags, arrays, emit, advance_time). Shell effects (screens, toasts, save) write to an event log and change no state outside it. A scenario runner reads `tests.json`. | Every `spec/conformance` case passes on both hosts. The sokoban tests pass. |
| 2. Browser viewer | three.js draws entities from the code-built mesh library (`meshes.json`), the `scene.json` ground, lighting and camera presets. Keyboard input comes from `ui/input.json`. | Sokoban is playable in a browser. A capture passes the visual-QA baseline. |
| 3. Physics | Rapier for the `physics` block, articulated bodies (ADR 0091) and sensors (ADR 0092). | The rover demo drives in a browser, and its tests pass with their margins. |
| 4. Shell | HUD and screens as HTML, procedural audio (`sounds.json`) with WebAudio, then the library shaders. | The doomarena3d tests pass. |

### 3. Exact-behavior pins (part of phase 1)

Phase 1 writes each pin into the contract doc, with a conformance case
for each one:

- **Randomness.** The spec names one seeded generator (xoshiro128**,
  which uses only 32-bit operations). A seed comes from `scene.json`, or
  from the scenario. `randf()` and `chance` read it in a stated order.
  Godot replaces its global `randf()` with the same generator. This also
  closes the lockstep gap of ADR 0091.
- **Formula edges.** `round` rounds half away from zero. Division by
  zero, `pow` of a negative number, and `sqrt` of a negative number
  each get one stated result.
- **Motion in the tick.** A body with no physics block moves by its
  velocity. The contract states where that step runs in the phase
  order. This closes the second open question of ADR 0086.

### 4. What stays with Godot

Godot stays the reference interpreter. The Godot test suite, the
authoring skills and every demo stay as they are. When the two hosts
disagree on a behavior, that is a spec bug. The contract doc then gets
a sentence and a conformance case, and both hosts follow it.

## Consequences

**Enables:**
- Games that open from a link, with no install.
- A real proof that the spec is host-neutral, from a conformance suite
  that is in every clone and runs in CI.
- Seeded randomness on both hosts, which makes replays and lockstep
  deterministic.
- A later robot profile on MuJoCo (WASM) that reads the same robot JSON.

**Costs:**
- A second code base to keep in step. Each new spec feature then needs
  work on both hosts, or a clear note that one host does not have it
  yet.
- Phase 1 changes Godot too: the seeded generator and the formula edges.
- Node and npm become dev tools of the repo.

**Risks:**
- The exact layer may hold Godot behavior that no document states, for
  example Dictionary order or int and float mixing in state. Phase 1
  finds these one at a time. Each one becomes a pin.

## Alternatives considered

- **Replace Godot with three.js.** About 28,000 lines to rewrite, and
  the rewrite loses the reference that the tests check against.
- **Godot web export only.** No second interpreter, so the spec stays
  untested. The download is large.
- **Rogue Engine.** Its editor and component model overlap with the
  spec. Plain three.js gives the same renderer with less to learn.
- **Renderer first.** A visual demo comes sooner, but nothing proves
  that the two hosts agree. A headless core first gives that proof.
- **Ban random rules from conformance tests.** Simpler, but many games
  use `chance`, and replays stay non-deterministic.

## Owner decisions (2026-10-18)

1. The code lives in `hosts/web/` in this repo.
2. The spec names one seeded generator, and Godot uses it too.
3. The headless core comes first.

## Phase 1 findings (2026-10-18)

The headless core passes the nine conformance cases on both hosts. The
14 sokoban scenarios pass on the new host, and CI runs them. Phase 1 is
done. Work on the new host found five defects in the reference:

1. **Randomness was not portable.** Fixed by the spec generator.
2. **Engine rules were lost.** The game's first rules file cleared the
   `lib/engine_rules` bundles, so the lifetime primitive (ADR 0049) did
   nothing in any game with its own rules.
3. **A radius query returned grid order.** Queries now return world
   order, and a distance sort keeps world order for ties.
4. **A held press-edge key fired on every tick** in scenarios, but once
   in live play. The input steps now follow live play, and the contract
   states them.
5. **A level swap removed the `_engine` entity** when `persistent_tags`
   did not name `persistent`. After that swap, each rule that queried
   world state matched nothing, and no error showed. The swap now always
   keeps `_engine`.

Each fix landed with a gate in `test_runner.gd` and a conformance case.

## Phase 2 progress (2026-10-18)

Sokoban is playable in a browser: `node hosts/web/src/serve.ts`. The
viewer draws the 2D shape library with three.js and fits the 2D camera
to the floor. It reads the keys from `ui/input.json` and shows the HUD
labels as HTML. A capture of level 2 passes the 2D visual-QA baseline.
The live loop has its own Node tests.

The 3D path followed on 2026-10-19. The viewer draws `meshes.json`, GLB
models, the ground color, the sun, the sky, fog and the four 3D camera
modes. It picks 3D from the `scene.json` camera mode. A capture of
doomarena3d has the same geometry and framing as the Godot capture.
Pixel samples of its sky, floor and walls agree within a few units.

Two findings came from the comparison:

- With a sky, Godot ignores `lighting.ambient`. The ambient light
  comes from the sky at full energy, because Godot applies
  `ambient_light_energy` only when the sky contribution is below 1.
  The viewer does the same. Content that sets `ambient` next to `sky`
  has no effect on Godot either.
- A shader sky gives its colors through `shader_params` and the
  day/night table of the lighting director, not through the procedural
  defaults.

Phase 2 is done for the spec fields that a browser can draw with
three.js alone. These stay open and move to phase 4: CSG ops, the
library shaders (ground, sky), heightmaps, GLB animations, the
viewmodel, SSAO and glow. Articulated links need phase 3.

## Phase 3 findings (2026-10-19)

The physics host runs on Rapier (`hosts/web/src/physics_rapier.ts`).
The rover demo passes its 34 checks on the new host. It drives in a
browser, and its autopilot steers it away from walls there. Two new
conformance cases pass on both hosts. `physics_robot` checks an
articulated body with sensors, with margins. `motion_effects` checks the
relative velocity effects and `raycast_hit`, which are exact. The
doomarena3d and lanterns tests also pass on the new host.

Rapier gives choices that Godot fixes. The host follows Godot:

- **Collision pairs.** Godot pairs two bodies when the layer of either
  one is in the mask of the other. Rapier needs both. A contact hook
  applies the Godot rule.
- **Motors.** Godot applies a capped motor impulse in each solver
  iteration, between the contact solves. Rapier's JS motor has no cap.
  An impulse before each step was too weak. Ground friction spun the
  light wheel back, and a turn in place drifted 0.09 m (the margin is
  0.05 m). A motor target that moves by a capped amount limited the
  wheel acceleration instead of the torque, and a wheel could not
  reverse. The host now takes 8 substeps for each step in a world with
  motors, with the capped impulse before each one. The drift is 0.03 m.
- **Ray queries.** A body joins the queries at the next physics step, on
  both hosts.

Three facts about the reference came out of the port. They are not
defects, but the contract does not state them yet:

1. A rigid body writes nothing back to entity state. Its motion is
   invisible to rules and to the renderer.
2. A scenario run steps the physics server only in a world with an
   articulated body. In other worlds, character bodies move by Euler
   integration with no collision. Rigid bodies do not move.
3. A velocity effect on an entity with no velocity starts from the zero
   2D vector, even when the position is 3D. The `motion_effects` case
   pins this.

These stay open: the `base` footprint of `from_visual_mesh`, and the
hinge `limit` sign. The Godot hinge motor runs against the right-hand
rule. The sign of its limits thus needs a check against a real step
before a robot uses limits.

## Phase 4 progress (2026-10-19)

The doomarena3d tests pass on the new host since phase 3, so the done
condition of phase 4 is met headlessly. Phase 4 goes on in slices, for
the parts that a player sees and hears.

The shell slice has screens with modal stacks and global inputs,
overlays, toasts, fades and the hit flash. It also has the freeze of the
live clock, HUD bars and the crosshair. Sokoban plays from its title screen in a browser. New
Game, the tutorial overlay, pause and resume all work with the keyboard.

The port found a defect in the reference. `reset_world` loaded the
starting level's rules again with no clear. After a reset in level 1,
each of its rules ran twice for each tick. After a reset from level 2,
the rules of level 2 kept running in level 1. A level swap clears the
rules first. The fix moved that step into one helper,
`reload_global_rules`, which the swap and the reset both call. The
`reset_world` conformance case checks it on both hosts.

The port also found that a load from a save never swaps the level. The
load writes the saved `current_level` into world state, then compares
it with `current_level`, which reads that same world state (ADR 0047).
So a Continue from a save in level 3 shows level 1 under the name of
level 3. The save slice fixed it: the load reads the level before the
state write. The `save_load` conformance case failed on Godot before the
fix and passes on both hosts after it.

The save slice: `save_state`, `load_state`, the autosave on a level swap
and `has_save`. Where a save lives is host-defined. A scenario run keeps
saves in memory for the process, and the viewer keeps them in
`localStorage`. Sokoban's Continue button works in a browser.

The audio slice: the sounds of `sounds.json`, made by the same synthesis
at the same 22050 Hz, play through WebAudio. Rules name sounds through
`@cues.*`. A melody loops on the music slot. A browser starts audio
only after a key or a click.

The animation slice: the state rules of `animation_director.gd` pick a
clip, and three.js's mixer cross-fades to it. A GLB's clips loop, as in
the reference. Library meshes get their clips from the translator's
rules. The lanterns player stands in its idle pose and walks with a walk
cycle in a browser.

The shader slice: `sky_clouds` and the two ground shaders, ported line
for line. A ground shader patches the standard material, so it keeps
the lighting of every other mesh. One host difference showed at once.
Godot's texture UV (0, 0) is the image's top-left corner, so the host
loads shader textures with no vertical flip. Before that fix, the
lanterns path was mirrored. The lanterns grass was less saturated than in
the Godot capture. The cause was the `lighting.adjustments` block
(contrast 1.18, saturation 1.34), which the viewer ignored with no note.
Godot's `apply_bcs` now runs on the tonemapped sRGB frame: the grass
sample went from 114, 156, 74 to 117, 186, 50, against Godot's 88, 174,
54. In linear space the colors crushed, so that order is wrong.
The depth fog then followed Godot's formula, 1 - exp(-density ×
distance), with the fog color pulled toward the sky by
`aerial_perspective`. three.js squares the distance. The far trees came
close to the Godot capture. A near roof stays darker than in Godot
(148, 129, 90 against 200, 168, 103), with no known cause yet.

More of phase 4 followed. It added the settings rows and their apply
chains, and the first-person viewmodel. It also added the CSG ops
`lathe`, `extrude` and `sweep`, and the grass blades and flowers. A boolean CSG group (`csg` subtract or
intersect) is not in the host yet. No content uses one.
