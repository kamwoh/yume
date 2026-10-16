---
description: Path-scoped rules for Yume engine tests
paths:
  - "godot/scripts/engine/tests/**"
---

# Tests — ship-with-phase invariant

Every W-phase exits with its tests in `test_runner.gd`. The runner is a
single consolidated file (currently ~900 lines, ~169 assertions). One file
is a feature, not a limitation: keeps test discovery trivial, cross-suite
helpers shared, runs as one Godot scene.

## DON'T

- ❌ **Use Godot's GUT or third-party test frameworks.** The engine is small
  enough that one file + a `_section()` helper + `expect()` / `expect_eq()`
  is sufficient. Adding a framework adds dependency surface.
- ❌ **Create test fixtures with hardcoded ids that other tests share.**
  Each test function builds its own entities, runs its assertions, and
  cleans up. No state leaks between sections.
- ❌ **Use sleep/timing in tests.** Tests run headless and synchronous —
  call `sched.tick()` directly to advance simulation; don't await
  WorldClock.

## DO

- ✅ **Add a test section per primitive or per phase.** Naming convention:
  `test_<thing>` for primitive (e.g. `test_entity`, `test_query`),
  `test_<phase>_cascade` for end-to-end (e.g. `test_w2_integration`,
  `test_rpg_cascade`).
- ✅ **Build self-contained env dicts.** Tests don't instantiate `World`
  (which expects a scene tree). They build:

  ```gdscript
  var entities: Dictionary = {}
  var defs: Dictionary = {...}
  var rs := RelationStore.new()
  var sx := SpatialIndex.new()
  var env: Dictionary = {
      "entities": entities, "defs": defs,
      "relations": rs, "spatial_index": sx,
      "world": {}, "parent": null, "next_id": {"_": 0},
  }
  var sched := PhaseScheduler.new(env)
  sched.register_rules([Rule.from_dict({...})])
  ```

- ✅ **Free created Entity nodes** at end of each section to keep the
  Godot ObjectDB clean. (Some leaks tolerable — they're warnings, not
  failures.)
- ✅ **Cover both happy path and rejection.** Chess test covers legal
  move (happy) AND illegal move (require fails AND query.state.turn
  filters). Both paths verify the rule shape.
- ✅ **Cascade tests over single-effect tests.** A single rule firing is
  weak evidence; a multi-step state-mutation chain proves the engine
  composes correctly.

## Adding a new test section

```gdscript
# In _ready, add:
test_my_new_thing()

# Below test_renderer_parity (or wherever logically grouped), add:
func test_my_new_thing() -> void:
    _section("my_new_thing (Wx.y)")
    # ... assertions ...
```

Then sync to the test project and run:
```bash
eval "$(grep -E '^(GODOT_BIN|TEMPLATE_DST)=' scripts/play.sh)"
cp -r godot/. "$TEMPLATE_DST/" && cd "$TEMPLATE_DST"
"$GODOT_BIN" --path . --headless scenes/test_main.tscn
```

Output should end with `passed: NN  failed: 0  total: NN`.

## When a test fails

1. **Read the failure message** — `expect_eq` includes expected/got
2. **Don't change the test to make it pass.** If the test was correct
   before and is now wrong, the engine regressed — fix the engine.
3. **Don't disable tests** to "fix later." Disabled tests rot.
4. If the test itself was wrong, fix it AND add a comment explaining
   why the original was wrong.

## Scenario steps that advance the simulation must settle the screen layer

`step_runner`'s `tick` and `wait` both run sim ticks. Only `wait` drained
ScreenFlow's screen-event buffer, so a screen change emitted by a RULE
(`refresh_screen`, `transition_screen`, `show_toast` from a rule effect)
was invisible to every scenario — they all use `tick`.

The gap hid itself: button-driven transitions still worked, because
ScreenFlow dispatches a button's `on_click` chain directly rather than
through the buffer. Screens therefore looked well covered while the
entire rule→screen direction was untested.

**Rule**: any new step verb that calls `_advance(world)` MUST also call
`_tick_frame_observers(world)` before returning. A new UI node that
reads input in its own `_process` MUST join that helper (2026-10-16:
the overlay manager was missing, so no scripted step could close a
tutorial overlay). If a verb deliberately does
not (a raw-sim probe), say so in a comment.

**Gate**: `demo_thousandgate`'s four `contract_*` scenarios exercise
rule-emitted `refresh_screen` end-to-end — accept a contract, assert the
board rebuilt without it. They fail if the drain is removed from either
verb.

**Empirical 2026-08-17**: a contract board's accept rule ended in
`refresh_screen`. The rebuild was correct and the re-query matched, but
it drained after the whole scenario finished; four scenarios failed
pointing at contract state while the defect was in the harness.
