# ADR 0043 — Universal input via `@lib.input.universal`

_Date: 2026-05-11_
_Status: **proposed** — awaiting tech-director review_

## Context

Yume's input bindings currently live in **two places**:

1. **`godot/project.godot` `[input]` block** — universal WASD +
   Arrow movement actions (`move_north`, `move_south`,
   `move_east`, `move_west`) with their key bindings.
2. **`data/demo_<game>/ui/input.json`** — per-game actions (E to
   interact, R to sleep, B to build, etc.) AND edge-classification
   for the universal actions (just `{"name": "move_north", "edge":
   "hold"}` — no keys, since project.godot already bound them).

This split has worked but exposes three concerns:

**Concern 1 — Invariant #1 erosion.** Invariant #1 says "all
game-specific content lives in JSON; engine reads JSON." Input
bindings ARE game-relevant (a Dvorak game might want
,/AOE not WSAD; an HJKL roguelike wants vim keys), but they live
in `project.godot` — a Godot-native, non-JSON config file. The
framework's "JSON-only content channel" claim has a soft
exception at input bindings.

**Concern 2 — Discoverability.** A new content-designer reads
`ui/input.json` and sees `{"name": "move_north", "edge":
"hold"}` with no keys. Where ARE the keys bound? The current
comment in `input_registrar.gd::_register_one` (line 88-94)
explains: "look in project.godot, the bindings are inherited."
But the per-game JSON doesn't reference project.godot — the
indirection is invisible from the data side. Authors writing
new games can't see what verbs exist without reading engine
source.

**Concern 3 — Customization friction.** A game wanting different
WASD layout (e.g., HJKL for a vim-themed roguelike) must either:
- Override at engine InputMap level (not declarative)
- Re-declare all 4 actions with explicit `keys:` in
  `ui/input.json` (loses the project.godot binding's `keys`)
- Edit project.godot directly (touches the framework template)

None of these are clean. The pattern Yume already established for
cross-game JSON reuse — ADR 0027 `@lib` references — solves this
exactly: ship the universal action set as a lib file, every game
`$include`s it by default, override per-game by re-declaring the
same action name after the include.

## Decision

**Move universal input actions out of `project.godot` and into
`data/lib/input/universal.json`. Every per-game `ui/input.json`
references it via `$include`. Drop the `[input]` block from
`project.godot`.**

### New file: `data/lib/input/universal.json`

```jsonc
{
  "_origin": "lib/input/universal.json",
  "_comment": "ADR 0043 — universal input verbs shared across all Yume games. Per-game ui/input.json $includes this to get WASD movement + stop_x/stop_y engine-injected actions without redeclaring. Authors override by listing the same action name AFTER the $include — last-writer-wins per JSON load order.",
  "actions": [
    {"name": "move_north", "edge": "hold", "keys": ["W", "Up"]},
    {"name": "move_south", "edge": "hold", "keys": ["S", "Down"]},
    {"name": "move_east",  "edge": "hold", "keys": ["D", "Right"]},
    {"name": "move_west",  "edge": "hold", "keys": ["A", "Left"]},
    {"name": "stop_x", "edge": "press", "engine_injected": true},
    {"name": "stop_y", "edge": "press", "engine_injected": true},
    {"name": "stop",   "edge": "press", "engine_injected": true}
  ]
}
```

### Per-game `ui/input.json` becomes

```jsonc
{
  "actions": [
    {"$include": "@lib.input.universal.actions"},
    {"name": "interact", "edge": "press", "keys": ["E"]},
    {"name": "sleep",    "edge": "press", "keys": ["R"]}
  ]
}
```

The `$include` operator already exists in `lib_resolver.gd` (ADR
0027) for array-splice. We just need to invoke
`LibResolver.resolve()` on the parsed input.json data before
iterating actions — a one-call change in `input_registrar.gd`.

### Engine changes

1. `input_registrar.gd::register_from_data_root` — call
   `LibResolver.resolve(spec)` after JSON parse, before iterating
   `spec["actions"]`.
2. The existing "keys-optional fallback for InputMap-already-bound
   actions" branch becomes narrower: now ONLY engine-injected
   actions hit it. Update the comment to reflect new design.

### `project.godot` changes

- Remove the entire `[input]` block.
- Update `run/main_scene` from the dead-end `world_2d.tscn` to
  `scenes/play.tscn` (the universal launcher) — friendlier for
  editor F5 launch.

### Override mechanism

A game wanting different keys (Dvorak / vim / customized) just
re-declares the action AFTER the `$include`:

```jsonc
{
  "actions": [
    {"$include": "@lib.input.universal.actions"},
    {"name": "move_north", "edge": "hold", "keys": ["H"]},
    {"name": "move_south", "edge": "hold", "keys": ["J"]}
  ]
}
```

`input_registrar.gd` already handles idempotent re-bind
(`InputMap.action_erase_events(name)` on line 114), so the second
declaration overrides the first — last-writer-wins.

### Validator

New: `tools/validate_input_universal.py`. Wired non-blocking into
`scripts/play.sh` alongside `validate_screens.py` etc. Walks every
demo's resolved `ui/input.json` (resolving `$include` references
the same way the engine does) and asserts:

- The 4 universal actions (`move_north/south/east/west`) are
  present
- `stop_x`, `stop_y`, `stop` engine-injected actions are present

If any are missing, warn (or fail in `--strict`). This catches a
game silently dropping the `$include` line.

## Consequences

### Positive

- **Invariant #1 honored** — `project.godot` no longer carries
  game-relevant config. All input bindings are JSON.
- **Discoverable** — `data/lib/manifest.json` indexes the universal
  set with a description; authors reading the manifest see what's
  available.
- **Customizable per-game** — Dvorak / vim / HJKL games override
  by re-declaring after `$include`.
- **DRY** — 16 demos × 4 actions = 64 redundant lines collapsed
  to 1 `$include` per game.
- **Symmetric with existing libs** — `@lib.cameras.X`,
  `@lib.input_bundles.X`, now `@lib.input.universal`. Same author
  vocabulary across all reusable config.

### Negative

- **Slightly less safe default** — if a game forgets the
  `$include` line, engine code that polls `move_north` silently
  no-ops (no error). Mitigated by `validate_input_universal.py`
  at sync time + by the manifest making the requirement explicit.
- **One more boot step** — `LibResolver.resolve()` runs on
  `ui/input.json` now (currently only on rules). Cost: trivial
  (the resolver is in-memory once cache is loaded; one
  `$include` ref per game = O(7) array splice).
- **Migration cost** — 16 demos' `ui/input.json` need editing
  (mechanical sed; ~20 min).

### Bug-class implications

The validator gate guards against a NEW bug class introduced by
this ADR: "game silently omits universal actions because no
`$include` line." Without the validator, this bug surfaces as
"WASD doesn't work in game X" at first playtest. With it, it
surfaces at sync time.

This is a clean post-mortem-rule application — we anticipated the
bug class the change introduces and shipped the gate alongside
it.

## Alternatives considered

### A. Keep the split as-is

The simplest path. Cost: zero. Tradeoff: keeps Invariant #1
violation indefinitely. Rejected because the lib system already
exists and the migration is small.

### B. Move WASD to per-game ui/input.json WITHOUT a shared lib

Each game declares its own 4 WASD actions in full. Cost: 64
redundant lines (16 games × 4 actions). Tradeoff: no
discoverability — each game has its own copy with possible
drift. Rejected for the DRY violation.

### C. (chosen) `@lib.input.universal` + `$include` per game

This ADR. Cost: ~1.5 hours total. Tradeoff: tiny — requires
LibResolver to run on input.json (already capable; just needs
the call site).

### D. Make WASD declaration implicit (engine auto-injects if
missing)

The engine, on detecting absence of move_north in a game's
`ui/input.json`, auto-registers the WASD defaults. Pro: zero
authoring overhead. Con: makes the engine carry game-flavored
default knowledge (violates Invariant #8 — engine = primitives +
interpreter, not opinions). Rejected.

### E. Promote project.godot config to JSON via a `framework.json`

Build a parallel JSON file at framework level
(`data/framework.json`) that declares "input bindings live here."
Engine reads it at boot. Tradeoff: introduces a NEW config layer
that isn't a lib (lib refs are reusable parts; framework.json
would be globally-applied). More architectural overhead than
ADR 0027's lib pattern. Rejected for surface-area inflation.

## References

- ADR 0027 — Cross-game parameterized templates (the `@lib`
  system this builds on)
- ADR 0040 — Camera-relative WASD (the universal action set
  this codifies)
- `godot/scripts/engine/lib_resolver.gd` — `$include` operator
  already implemented
- `godot/scripts/engine/input_registrar.gd` — site of the one-call
  change
- `.claude/rules/data-demo.md` — schema discipline (will gain a
  section pointing to the validator)

## Migration checklist

- [ ] Write `data/lib/input/universal.json`
- [ ] Update `data/lib/manifest.json` with `input` category
- [ ] Engine: `input_registrar.gd::register_from_data_root` calls
      `LibResolver.resolve()`
- [ ] Update `input_registrar.gd` line 88-101 comment to reflect
      new design
- [ ] `project.godot`: remove `[input]` block; update
      `run/main_scene` to `scenes/play.tscn`
- [ ] Migrate Aldenmere `ui/input.json` first; confirm WASD still
      works via capture
- [ ] Bulk-migrate other 15 demos' `ui/input.json`
- [ ] Write `tools/validate_input_universal.py` + wire in
      `scripts/play.sh`
- [ ] Unit test in `test_runner.gd`: assert
      `LibResolver.resolve($include @lib.input.universal.actions)`
      splices correctly
- [ ] Run full unit test suite (864 tests) — must remain green
- [ ] Run Aldenmere capture-after=2 — confirm boot clean + WASD
      functional
- [ ] Tech-director review pass

## Acceptance gate (set by tech-director on review)

- [ ] All 16 demos boot + WASD works
- [ ] No regression in unit tests (864 → 864+)
- [ ] Validator catches a deliberately-broken `ui/input.json`
      (omit `$include`, assert WARN)
- [ ] Documented in `.claude/rules/data-demo.md` under "input
      bindings"
