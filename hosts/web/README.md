# Yume web host

_Last updated: 2026-10-18_

The TypeScript interpreter of the Yume spec (ADR 0095). Godot stays the
reference interpreter. This host must give the same result for every
exact behavior (contract doc, §Two behavior classes).

## Status: phase 1, the headless core

| In this host | Not in this host yet |
|---|---|
| Entities, tags, state, relations, queries, formulas | Physics bodies, sensors (phase 3) |
| Rules with the tick phases, `once`, `once_per`, `chance` | `lod`, `scope`, `overlap` |
| Exact effects: state, spawn, remove, transform, relations, tags, arrays, emit, `advance_time`, `velocity_set` | Other motion effects, zones, `pathfind_to`, `raycast_hit` |
| The engine rules in `lib/engine_rules` | Levels (`game/flow.json`), variants, macros, actors |
| `press`, `hold`, `release`, `tick`, `wait`, `expect` | `click`, `screenshot`, UI assertions (phase 4) |

Shell effects (screens, toasts, save, audio) write a record to
`env.shellEvents` and change no other state. A feature outside phase 1
gives a `host.unsupported` or `effect.unsupported_host` warning.

## Run

Node 22.18 or later runs the TypeScript files directly. You do not need
a build step.

```bash
cd hosts/web
npm ci                 # once, for the type checker only
npm test               # unit tests (the generator vectors)
npm run typecheck
node src/cli.ts --lib=../../godot/data/lib ../../spec/conformance/*/
```

`../../scripts/conformance.sh` runs the conformance cases on this host
and on Godot.

## Layout

The files follow the Godot files, one to one, so that a reader can
compare them:

| File | Godot twin |
|---|---|
| `src/entity.ts` | `core/entity.gd` |
| `src/query.ts` | `core/query.gd` |
| `src/formula.ts` | `core/formula.gd` |
| `src/rule.ts` | `core/rule.gd` |
| `src/scheduler.ts` | `core/phase_scheduler.gd` |
| `src/effects.ts` | `core/effect_apply.gd`, `effects/effect_core.gd`, `effects/effect_resolution.gd` |
| `src/relations.ts` | `stores/relation_store.gd` |
| `src/lib_resolver.ts` | `libs/lib_resolver.gd` |
| `src/random.ts` | `util/spec_random.gd` |
| `src/world.ts` | `core/world.gd`, `coordinators/world_boot.gd`, `coordinators/world_loader.gd` |
| `src/scenario.ts` | `qa/scenario_runner.gd`, `qa/step_runner.gd` |

## When the two hosts disagree

A disagreement is a spec bug. Do not change one host to match the other
by guess. Find the behavior in the contract doc. If the contract does
not state it, add a sentence and a conformance case, then make both
hosts follow it. Phase 1 found four such bugs (ADR 0095).
