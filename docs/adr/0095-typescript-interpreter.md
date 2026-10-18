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

The headless core passes the eight conformance cases on both hosts.
Sokoban is not done yet: it needs levels (`game/flow.json`), variants
and save policies. Work on the new host found four defects in the
reference:

1. **Randomness was not portable.** Fixed by the spec generator.
2. **Engine rules were lost.** The game's first rules file cleared the
   `lib/engine_rules` bundles, so the lifetime primitive (ADR 0049) did
   nothing in any game with its own rules.
3. **A radius query returned grid order.** Queries now return world
   order, and a distance sort keeps world order for ties.
4. **A held press-edge key fired on every tick** in scenarios, but once
   in live play. The input steps now follow live play, and the contract
   states them.

Each fix landed with a gate in `test_runner.gd` and a conformance case.

