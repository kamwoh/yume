---
description: Path-scoped rules for Yume engine tests
globs: archetypes/core/templates/godot/scripts/engine/tests/**
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
cp -r ~/yume/archetypes/core/templates/godot/. /mnt/c/.../YumeTemplate/
godot --headless --path C:/Users/.../YumeTemplate scenes/test_main.tscn
```

Output should end with `passed: NN  failed: 0  total: NN`.

## When a test fails

1. **Read the failure message** — `expect_eq` includes expected/got
2. **Don't change the test to make it pass.** If the test was correct
   before and is now wrong, the engine regressed — fix the engine.
3. **Don't disable tests** to "fix later." Disabled tests rot.
4. If the test itself was wrong, fix it AND add a comment explaining
   why the original was wrong.
