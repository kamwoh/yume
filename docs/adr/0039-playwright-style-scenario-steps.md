# ADR 0039 — Playwright-style scenario steps (unified test + VQA driver)

_Date: 2026-05-10_
_Status: accept-with-conditions (2026-05-10) — five conditions resolved in revision below; ready for engine session_

## Context

Yume currently has **two parallel input-driving systems** with similar
intent but divergent syntax:

1. **Scenario tests** (`scenario_runner.gd`) — JSON `tests.json` files
   per game with the schema:
   ```jsonc
   "actions": [
     {"tick": 1, "input": "move_north"},
     {"tick": 5, "input": "move_north"},
     {"tick": 10, "input": "move_north"}
   ],
   "ticks": 20
   ```
   Authors specify which tick each input fires on. To express "hold W
   for 1.5s" they must enumerate every tick the action repeats — a
   game with `tick_seconds=0.1` needs 15 entries to cover 1.5s. Empirical
   pattern in `data/demo_aldenmere/tests.json`: 4 ticks per "hold"
   step (1, 5, 10, 15) — author counts on the engine's hold-edge
   semantics to fill the gaps. Brittle; off by 1 → test fails.

2. **Capture-input** (`capture_runner.gd`) — `--capture-input` cmdline
   flag for visual QA:
   ```
   --capture-input='move_east,2.0;move_north+move_west,1.5'
   ```
   Authors specify duration in seconds. Just landed (2026-05-10) the
   `+` separator for simultaneous actions. Easier to author for
   continuous input, but lacks expressiveness: no UI clicks, no
   assertions, no mid-test screenshot. Used only for one-shot capture.

Empirical case (2026-05-10): user asked to debug WASD diagonals.
Scenario tests passed (engine moves correctly in world coords) but the
user perceived the iso-camera screen mapping as wrong. To verify
visually, I tried to capture each diagonal — but captures landed on
the title screen because `capture-input` has no `click("New Campaign")`
primitive. The test couldn't get past the menu. This is a missing
verb, not a missing capability — Godot's screen flow already
dispatches button clicks; the test driver just doesn't expose it.

Both systems also lack:

- **Click by text/id** (UI buttons)
- **Wait for state** (e.g., "wait until player.position.z < 0")
- **Mid-test screenshot** (capture state at an intermediate point)
- **Press without auto-release** (start holding W, do other things,
  release later)
- **Assertions in capture mode** (visual QA can verify state, not just
  produce a PNG)
- **Composability** — both runners walk a flat list; can't share a
  reusable "title-to-gameplay" prefix across tests

The fix isn't more flags on each runner. The fix is **one shared
step vocabulary** consumed by both runners — Playwright-style. Each
verb maps to a small set of engine calls. Both `scenario_runner.gd`
and `capture_runner.gd` delegate to the same `step_runner.gd` module.
Authors learn one DSL; the engine has one bug surface.

This composes with future work: the `--smoke-screens` mode mentioned
in `.claude/rules/visual-qa.md` (walk every screen + every button
programmatically) becomes trivial — it's just a step list emitted by
a screen-graph traversal.

## Decision

Introduce **scenario steps** as the unified vocabulary for driving
the engine in headless tests, capture sessions, and future regression
smoke tests. Steps replace the `actions[] + ticks` schema with a flat
ordered list of verb dictionaries. The old schema continues to work
via an auto-detection shim; existing demos migrate at their own pace.

### Step vocabulary (FIXED v1 SET — 9 verbs)

| Verb | Form | Behavior |
|---|---|---|
| `press` | `{"press": "action_name"}` | Single press-edge; fires the action once on the next tick. Equivalent to old `{"tick": N, "input": "X"}` semantics. |
| `hold` | `{"hold": "action_name", "for": 1.5}` OR `{"hold": ["a", "b"], "for": 1.5}` | Press the action(s), advance time by `for` seconds, release. Array → simultaneous multi-key. The default verb for hold-edge actions like WASD. |
| `release` | `{"release": "action_name"}` | Release a previously-held action. Used when a `press` was issued without `for` (held indefinitely until matching release). |
| `click` | `{"click": "New Campaign"}` OR `{"click": {"id": "btn_new_game"}}` OR `{"click": {"text": "Quit"}}` | Locate a UI Control by visible text or id; fire its `on_click` chain. String form is shorthand for `{"text": "..."}`. |
| `wait` | `{"wait": 0.5}` OR `{"wait": {"ticks": 5}}` OR `{"wait": {"seconds": 0.5}}` | Advance time without input. Number form = seconds. |
| `tick` | `{"tick": 5}` | Advance N scheduler ticks deterministically. Use when test logic depends on exact tick count, not real-time seconds. |
| `screenshot` | `{"screenshot": "wa_diag.png"}` OR `{"screenshot": {"path": "user://x.png", "label": "post-attack"}}` | Save current viewport to PNG. Step runner records label for diagnostics. |
| `expect` | `{"expect": [...assertion list...]}` | Run one or more assertions against current state. Uses existing assertion vocabulary (`entity_count`, `entity_field`, `world_field`) — extends with `ui_present` / `ui_hidden` for screen visibility. |
| `key` | `{"key": "Escape"}` OR `{"key": {"keycode": "Enter", "duration": 0.2}}` | Raw keyboard event escape hatch. Used when an action vocab isn't bound (e.g. dismissing a modal whose button isn't in InputMap). |

The set is **complete for v1**. **Binding rule** (per tech-director
Condition 1, 2026-05-10): future additions to the step vocabulary
require a dedicated ADR with tech-director review. No verb may land
by PR alone. Same gate as effect type expansion — keeps the
vocabulary disciplined.

### Schema example

Aldenmere's WASD diagonal test, before and after:

**Before** (current, brittle):
```jsonc
{
  "name": "wasd_diagonal_w_plus_a_NW",
  "actions": [
    {"tick": 1, "input": "move_north"}, {"tick": 1, "input": "move_west"},
    {"tick": 3, "input": "move_north"}, {"tick": 3, "input": "move_west"},
    {"tick": 6, "input": "move_north"}, {"tick": 6, "input": "move_west"},
    {"tick": 10, "input": "move_north"}, {"tick": 10, "input": "move_west"}
  ],
  "ticks": 15,
  "assertions": [
    {"type": "entity_field", "select": "first", "query": {"tags_all": ["player"]},
     "field": "state.position.z", "op": "<", "value": 5.0},
    {"type": "entity_field", "select": "first", "query": {"tags_all": ["player"]},
     "field": "state.position.x", "op": "<", "value": 5.0}
  ]
}
```

**After** (proposed):
```jsonc
{
  "name": "wasd_diagonal_w_plus_a_NW",
  "steps": [
    { "hold": ["move_north", "move_west"], "for": 1.5 },
    { "expect": [
        { "entity_field": {"query": {"tags_all": ["player"]},
                           "field": "state.position.z", "op": "<", "value": 5.0} },
        { "entity_field": {"query": {"tags_all": ["player"]},
                           "field": "state.position.x", "op": "<", "value": 5.0} }
    ]}
  ]
}
```

Authoring is shorter; intent is clearer; off-by-one tick brittleness
is gone. The capture-input version of the same scenario is a different
scenario whose last step is `screenshot` instead of `expect`:

```jsonc
{
  "name": "vqa_wasd_w_plus_a",
  "steps": [
    { "click": "New Campaign" },        // dismiss title
    { "wait": 1.0 },                    // settle
    { "hold": ["move_north", "move_west"], "for": 1.5 },
    { "screenshot": "user://wasd_wa.png" }
  ]
}
```

Same step vocabulary; same runner. Authors learn one DSL.

### Engine module layout

```
godot/scripts/engine/
├── step_runner.gd          # NEW: 9-verb dispatcher (~200 LoC)
├── scenario_runner.gd      # EXISTING: refactored to delegate to step_runner
├── capture_runner.gd       # EXISTING: refactored to delegate to step_runner
├── world.gd                # EDIT: factor _on_tick body into advance_one_tick()
├── control_factory.gd      # EDIT: propagate JSON id → Control.name
└── tests/test_runner.gd    # unit tests for each verb
```

**Tick-advance discipline (per tech-director Condition 4, 2026-05-10):**
the step runner MUST NOT have its own private `_advance_one_tick` —
that diverges from `world._on_tick`'s actual tick body and produces
a test suite that lies about live-play behavior. Required refactor in
`world.gd`:

```gdscript
# Public method that runs ONE complete tick body (extracted verbatim
# from _on_tick lines 798-828). Includes scheduler.tick(),
# actor_manager.tick_policies, LifecycleDirector.tick,
# _decrement_lifetimes, process_pending_level_transition,
# process_chunk_streaming, process_pending_save_load,
# process_pending_actor_switch, process_pending_world_reset,
# motion integration. Single source of truth — both the live
# clock callback and the step runner use this.
func advance_one_tick() -> void:
    # ... factored body of _on_tick (minus the freeze-check + verbose) ...

# Original tick callback now delegates after the freeze check.
func _on_tick(count: int) -> void:
    # ... freeze check unchanged ...
    advance_one_tick()
    if verbose and count % 4 == 0:
        _print_tick_summary(count)
```

`step_runner.gd` calls `world.advance_one_tick()` per tick advance.
Scenario tests now exercise the same execution path as live play —
no more "passes headless, fails in browser" class of bug.

**Click → ScreenFlow drain (per tech-director Condition 4 follow-up):**
`btn.pressed.emit()` queues effects in `screen_event_buffer` but
that buffer is drained by `ScreenFlow._process` (a Godot frame
callback). Headless tests don't tick `_process` — the click's
`transition_screen` would never fire. Step runner's `click` verb
must explicitly drain the buffer after `pressed.emit()` and BEFORE
the next step:

```gdscript
btn.pressed.emit()
var screen_flow := world.get_node_or_null("/root/ScreenFlow")
if screen_flow != null and screen_flow.has_method("_drain_screen_events"):
    screen_flow._drain_screen_events()
world.advance_one_tick()  # let queued effects (e.g. transition_level) land
```

If `_drain_screen_events` is private, expose a public wrapper
(e.g. `screen_flow.drain()`); the existing private name was
designed for the per-frame caller.

`step_runner.gd` is the canonical executor. It exposes:

```gdscript
class_name StepRunner

# Run a step list against a World.
# Returns {passed: int, failed: int, failures: Array}.
static func run(steps: Array, world: World, ctx: Dictionary = {}) -> Dictionary
```

`ctx` carries cross-step state (held actions, screenshot count,
default screenshot dir, etc.). Both runners construct their own ctx,
call `StepRunner.run`, report results.

### Backward compatibility (auto-detection shim)

The new field is `"steps": [...]`. The old field is `"actions": [...]`
+ `"ticks": N` + `"assertions": [...]`. Both schemas live in the same
`tests.json`; per-scenario detection picks one:

```gdscript
# scenario_runner.gd::_run_one
if sc.has("steps"):
    StepRunner.run(sc["steps"], world, ctx)  # new path
elif sc.has("actions"):
    push_warning("[scenario] '%s' uses legacy actions[] schema — migrate to steps[] (deprecated as of ADR 0039, removal at ADR 0050 or last-demo-migration)" % name)
    _run_legacy(sc, world)  # existing logic, preserved verbatim
else:
    push_warning("[scenario] '%s' has neither 'steps' nor 'actions'" % name)
```

All 13 existing demos keep working. New demos / migrating demos use
`steps`. Within a single `tests.json`, individual scenarios can mix
formats.

**Sunset trigger (per tech-director Condition 5, 2026-05-10):** the
legacy `actions[]` schema is deprecated as of ADR 0039. Removal lands
at **ADR 0050 OR when the last demo's tests.json migrates to
`steps[]`**, whichever comes first. The runtime `push_warning` above
makes the deprecation visible at every test run so the migration
state is observable. Not "indefinite" — the schema has a known end.

### Capture-input legacy syntax

The existing `--capture-input='move_east,2.0;X+Y,1.5'` cmdline format
maps cleanly to the new step vocabulary:

```
'X,2.0'      → {"hold": "X", "for": 2.0}
'X+Y,1.5'    → {"hold": ["X", "Y"], "for": 1.5}
'X,2;Y,1'    → [{"hold": "X", "for": 2}, {"hold": "Y", "for": 1}]
```

`capture_runner.gd` keeps the cmdline flag, parses it into a step
list, delegates to `StepRunner.run`. A new flag `--capture-script=<path>`
loads a step JSON file directly (richer scenarios than fit on a
cmdline).

### `click` selector resolution

`click("Start")` searches the active screen + overlay stack for a
Control whose text == "Start". The walk:

1. Get top-of-stack from `ScreenFlow` (if any).
2. Walk its Control tree depth-first.
3. Match on `text` property (Button, Label-with-on_click) or on
   `name` (Control id) or on a `data_id` meta key.
4. If match and Control is a Button or has an `on_click` callable,
   fire `pressed.emit()` (Godot signal — runs the on_click chain
   wired by `screen_flow.gd`).
5. If no match, log a structured EngineError (see below).

**Engine prerequisite (per tech-director Condition 2, 2026-05-10):**
`control_factory.gd::_apply_common` does NOT currently propagate the
JSON `id` field to `Control.name` — Godot auto-names the node
`"Button"`, `"Button2"`, etc. The `{"click": {"id": "btn_new_game"}}`
selector form requires this assignment. Add to `_apply_common`:

```gdscript
# Propagate JSON id to Control.name so step_runner click selectors
# can locate by id. Error on collision rather than auto-suffixing —
# duplicate ids in screens.json are an authoring bug, not engine
# scope to silently mangle.
if spec.has("id"):
    var json_id := str(spec["id"])
    if parent != null and parent.has_node(json_id):
        push_error("[control_factory] duplicate Control id '%s' under %s" %
            [json_id, parent.get_path()])
    node.name = json_id
```

This change is part of ADR 0039's engine session, not a separate
ADR — it's the minimum prerequisite for the click verb to work as
specified.

Selector forms accepted:

| Form | Meaning |
|---|---|
| `"click": "New Campaign"` | shorthand, equivalent to `{"text": "New Campaign"}` |
| `"click": {"text": "Quit"}` | exact-text match |
| `"click": {"id": "btn_new"}` | match by Control name (Yume's screen-flow assigns these from JSON `id` fields) |
| `"click": {"text": "Quit", "screen": "title"}` | scope to a specific screen — protects against duplicate text across modals |

Author convention: prefer `id` for tests that should be resilient to
text changes; prefer `text` for tests that document the user-facing
flow (a localization rename should break the test that verifies the
button label).

### `expect` assertion forms

Old assertions had a flat shape with `type` discriminator:

```jsonc
{"type": "entity_count", "query": {...}, "op": ">=", "value": 1}
```

New `expect` accepts the same shapes plus a more compact form:

```jsonc
// Old form (still works inside expect):
{ "entity_count": {"query": {...}, "op": ">=", "value": 1} }

// Compact form (sugar over entity_field):
{ "player.state.hp": {">=": 80} }
{ "player.state.position.z": {"<": 0} }
{ "world.day": {"==": 5} }
```

The compact form: `{<entity_or_world>.<dotted.path>: {<op>: value}}`.
Resolved by splitting on first `.`, treating the prefix as either
`world` (top-level world_state) or as a `tags_all: [<tag>]` query
(if the entity has a unique tag — the common case for player /
world_clock / etc.).

UI assertions:

```jsonc
{ "ui_present": "New Campaign" }      // active screen has this Control
{ "ui_hidden": "Pause Menu" }         // not on top of stack
{ "screen_active": "title" }          // top-of-stack screen id
```

### Error reporting

When a step fails (action unknown, click target missing, expect
violated), `StepRunner` reports a structured `EngineError`:

| Code | Meaning |
|---|---|
| `STEP_UNKNOWN_VERB` | step has no recognized verb key |
| `STEP_UNKNOWN_ACTION` | press/hold references unregistered InputMap action |
| `STEP_CLICK_NOT_FOUND` | selector matched no UI Control |
| `STEP_CLICK_AMBIGUOUS` | selector matched multiple controls; suggest narrowing |
| `STEP_EXPECT_FAILED` | assertion mismatch (with expected vs actual) |
| `STEP_RELEASE_NOT_HELD` | release without prior press |
| `STEP_INVALID_DURATION` | wait/hold `for` is non-positive |

EngineErrors flow through the existing `env.error_buffer` and surface
in qa-tester's run report.

### Determinism

Steps that take time (`hold for`, `wait seconds`) advance the engine
by `round(seconds / tick_seconds)` ticks. For `hold for 1.5` with
tick_seconds=0.1, that's 15 ticks (release happens after the final
tick). For `wait 0.05` with tick_seconds=0.1, that's 1 tick (rounded
up from 0.5). **Round, not floor** — chosen so sub-tick durations
don't silently advance zero ticks (which would make a `wait 0.05`
test step a no-op surprise). Deterministic given the same
tick_seconds; reproducible across runs. `wait ticks` and `tick`
verbs are fully tick-discrete (no floating-point residual).

`screenshot` is non-deterministic in renderer output (GPU drivers
differ) but the input + state path before it is deterministic. PNG
diff is a future feature; v1 just saves.

## Consequences

### Positive

- **One vocabulary across tests + capture + future regression smoke.**
  Authors learn the verbs once. Bug surface is one runner.
- **Brittle tick-counting goes away.** `hold X for 2` replaces
  `[{tick:1,input:X},{tick:5,input:X},{tick:10,input:X}]`.
- **UI clicks work in tests.** "Click New Campaign then walk north"
  is one scenario — the missing primitive that blocked Aldenmere
  visual QA.
- **Scenarios + visual captures share authoring work.** A regression
  test ("post-bug-fix, user can dismiss title and walk to shop") is
  the same step list whether run as scenario assertions or as a
  visual capture.
- **Compact assertion shorthand** (`player.state.hp >= 80`) shrinks
  test bodies by 50% in practice.
- **Composability foundation.** Future `include: "@lib.steps.title_dismiss"`
  pattern (per ADR 0027 cross-game JSON reuse) lets games share
  setup prefixes.
- **Backward-compat is total.** Existing 13 demos' tests.json files
  unchanged; old runner path preserved verbatim.

### Negative

- **One new engine module** (`step_runner.gd` ~200 LoC). Two
  refactors (`scenario_runner.gd`, `capture_runner.gd`).
- **Learning cost.** Authors who know the old `actions` schema
  re-learn. Mitigated by: old schema still works; documentation
  shows side-by-side migration; Aldenmere's tests.json migrates as
  the canonical example.
- **Click selector ambiguity.** Two buttons with the same text
  (e.g. "Continue" on title + on pause) need explicit `screen:`
  scoping. ADR mandates the `STEP_CLICK_AMBIGUOUS` error so authors
  can't accidentally rely on undefined order.
- **Verb proliferation pressure.** "Just one more verb" creep. ADR
  caps v1 at 9 verbs; future additions go through ADR.

### Neutral

- **Determinism unchanged.** Tick-discrete advance is deterministic;
  screenshot non-determinism limited to PNG output, same as today.
- **Save/load (ADR 0010).** Unaffected — steps don't change save
  semantics.
- **Variant override (ADR 0009).** Per-scenario `variant` field
  survives schema migration; lives at scenario top level alongside
  `name` and `steps` (not inside `steps`).

## Alternatives considered

### A) Just extend `actions[]` with seconds

Add a `duration` field to action entries:
```jsonc
"actions": [{"input": "move_north", "duration": 1.5}]
```

Rejected:

- Doesn't solve the vocabulary divergence (capture-input still
  separate).
- Doesn't add `click`, `wait`, `expect`, `screenshot`. The empirical
  bug (no click in capture-input) recurs.
- Half-migration is uglier than full migration.

### B) Just extend `--capture-input` cmdline syntax

Add `--capture-input='click=New Campaign;hold=move_north,1.5'`. Make
capture rich; leave scenario tests alone.

Rejected:

- Cmdline syntax doesn't scale beyond ~3 steps. JSON is the right
  shape for richer flows.
- Doesn't unify with scenario tests; divergence persists.
- Hard to compose / share step prefixes.

### C) GDScript test files

Allow `tests/<name>.gd` per-game with a fluent API (`world.click("X").hold("W", 1.5).expect(...)`). Rejected:

- Violates Invariant #1 (JSON-only content channel). Every game
  ships GDScript test code → engine path drift.
- Authors are expected to be content-designer LLMs / non-coders. JSON
  is reachable; GDScript is not.
- The benefit (Turing-complete test logic) is solvable via JSON
  composition + a small set of imperative verbs (which is what this
  ADR proposes).

### D) Defer until cross-game JSON reuse for steps lands

Ship richer step composition (`include: "@lib.steps.X"`) in the same
ADR. Rejected:

- Composition layer can land later as ADR 0040 or so; v1 doesn't
  need it for Aldenmere unblocking.
- Scope creep; smaller ADR is faster to land + review.

### E) Mirror Playwright's full API verbatim

Add `mouse_move`, `drag`, `wait_until`, `expect_snapshot`, etc.
Rejected for v1:

- Yume games are mostly keyboard-driven; mouse + drag are rare.
- Each verb is a primitive expansion; smaller surface = stronger
  invariants. Future ADRs can extend.

## References

- ADR 0001 — seven primitives + interpreter (steps are an
  interpreter expansion, not a new game-rule effect — they don't
  bleed into the runtime contract)
- ADR 0011 — declarative screen flow (click selectors walk the
  ScreenFlow stack)
- ADR 0021 — Yume = JSON layer over Godot (steps wrap Input,
  ButtonPressed, viewport.get_image — JSON exposing existing Godot
  capabilities)
- ADR 0027 — cross-game JSON reuse (future composition path:
  `include: "@lib.steps.X"`)
- `godot/scripts/engine/scenario_runner.gd` — current scenario
  runner; refactor target
- `godot/scripts/engine/capture_runner.gd` — current capture runner;
  refactor target
- `godot/data/demo_aldenmere/tests.json` — canonical migration target
  (Aldenmere is the empirical motivator)
- `.claude/rules/visual-qa.md` § stage-driven visual QA — current
  workaround pattern this ADR replaces with first-class verbs
- 2026-05-10 user feedback: *"the input simulation should be an
  abstraction, like xxx.click xxx.hold xxx.press etc."* — the ADR
  trigger

## Test plan

Twelve unit-test sections in `test_runner.gd`:

| Test | Verifies |
|---|---|
| `step.test_press` | `{"press": "X"}` queues a single press-edge input on the next tick. |
| `step.test_hold` | `{"hold": "X", "for": 1.0}` with tick_seconds=0.1 advances 10 ticks; X is held during all 10; released after. |
| `step.test_hold_multi` | `{"hold": ["X", "Y"], "for": 1.0}` holds both simultaneously. Setting up a per-axis-preserving rule confirms vector composition (NW = X-axis + Y-axis combined). |
| `step.test_release` | `press` without `for` → `wait` → `release` correctly tracks a held action across multiple steps. |
| `step.test_wait_seconds_vs_ticks` | `{"wait": 1.0}` advances `1.0 / tick_seconds` ticks. `{"wait": {"ticks": 5}}` advances exactly 5. |
| `step.test_tick` | `{"tick": 3}` advances 3 ticks regardless of tick_seconds. |
| `step.test_click_by_text` | Build a screen with a "Start" button. `{"click": "Start"}` fires its `on_click` chain (verify world state changed). |
| `step.test_click_ambiguous` | Two buttons with text "Continue" on different screens → STEP_CLICK_AMBIGUOUS error unless scoped via `screen:`. |
| `step.test_click_not_found` | Selector matches nothing → STEP_CLICK_NOT_FOUND error; subsequent steps don't fire. |
| `step.test_screenshot` | `{"screenshot": "user://t.png"}` writes a PNG; file exists; size > 0. |
| `step.test_expect_compact_form` | `{"expect": [{"player.state.hp": {">=": 50}}]}` resolves the path correctly via tag-based query. |
| `step.test_legacy_actions_still_work` | A scenario with old `actions[] + ticks + assertions` runs via the legacy path; a sibling scenario with `steps[]` runs via the new path; both pass independently. |

End-to-end: convert `data/demo_aldenmere/tests.json` to use `steps`
for at least 3 of the 7 WASD scenarios; run the full suite; verify
13/13 passes with mixed legacy + new format.

## Implementation sketch

```gdscript
# step_runner.gd — pure dispatcher (~200 LoC)
class_name StepRunner

static func run(steps: Array, world: World, ctx: Dictionary = {}) -> Dictionary:
    if not ctx.has("held"): ctx["held"] = []         # action names currently held
    if not ctx.has("passed"): ctx["passed"] = 0
    if not ctx.has("failed"): ctx["failed"] = 0
    if not ctx.has("failures"): ctx["failures"] = []

    for step in steps:
        if not (step is Dictionary): continue
        var verb := _detect_verb(step)
        match verb:
            "press":      _do_press(step, world, ctx)
            "hold":       _do_hold(step, world, ctx)
            "release":    _do_release(step, world, ctx)
            "click":      _do_click(step, world, ctx)
            "wait":       _do_wait(step, world, ctx)
            "tick":       _do_tick(step, world, ctx)
            "screenshot": _do_screenshot(step, world, ctx)
            "expect":     _do_expect(step, world, ctx)
            "key":        _do_key(step, world, ctx)
            _:
                EngineError.raise(world.scheduler.env,
                    EngineError.STEP_UNKNOWN_VERB,
                    "Unknown step verb: %s" % step.keys(),
                    {"step": step}, "")

    # Auto-release any still-held actions at end of scenario.
    for action in ctx["held"]:
        Input.action_release(action)
    ctx["held"].clear()
    return ctx


static func _do_hold(step: Dictionary, world: World, ctx: Dictionary) -> void:
    var spec = step["hold"]
    var actions: Array[String] = []
    if spec is Array:
        for a in spec: actions.append(str(a))
    else:
        actions.append(str(spec))
    var seconds := float(step.get("for", 0.0))
    if seconds <= 0:
        EngineError.raise(world.scheduler.env, EngineError.STEP_INVALID_DURATION,
            "hold requires positive 'for' seconds", {"step": step}, "")
        return
    for a in actions:
        if not InputMap.has_action(a):
            EngineError.raise(world.scheduler.env, EngineError.STEP_UNKNOWN_ACTION,
                "Unknown action: %s" % a, {"step": step}, "")
            continue
        Input.action_press(a)
    var ticks := int(round(seconds / world.tick_seconds))
    for i in range(ticks):
        world.advance_one_tick()       # canonical tick body — see Engine module layout
    for a in actions:
        Input.action_release(a)


static func _do_click(step: Dictionary, world: World, ctx: Dictionary) -> void:
    var selector = step["click"]
    var sel: Dictionary = (selector if selector is Dictionary
                            else {"text": str(selector)})
    var screen_flow := world.get_node_or_null("/root/ScreenFlow")
    var matches := _find_controls(screen_flow, sel)
    if matches.is_empty():
        EngineError.raise(world.scheduler.env, EngineError.STEP_CLICK_NOT_FOUND,
            "click selector matched nothing", {"selector": sel}, "")
        return
    if matches.size() > 1 and not sel.has("screen"):
        EngineError.raise(world.scheduler.env, EngineError.STEP_CLICK_AMBIGUOUS,
            "click selector matched %d controls; add 'screen' to disambiguate"
              % matches.size(), {"selector": sel}, "")
        return
    var btn: Button = matches[0]
    btn.pressed.emit()
    # ScreenFlow's event buffer is drained per-frame by its _process;
    # headless tests don't tick _process, so drain explicitly here so
    # transition_screen / transition_level / load_state queued by the
    # button's on_click chain land BEFORE the next step.
    if screen_flow != null and screen_flow.has_method("drain"):
        screen_flow.drain()
    world.advance_one_tick()


# scenario_runner.gd::_run_one — refactored
if sc.has("steps"):
    var step_ctx := {"data_root": data_root}
    var result := StepRunner.run(sc["steps"], world, step_ctx)
    passed += result["passed"]
    failed += result["failed"]
    failures.append_array(result["failures"])
elif sc.has("actions"):
    _run_legacy(sc, world)        # existing logic, untouched


# capture_runner.gd::_ready — refactored
var step_list: Array = _parse_capture_input(input_script)
StepRunner.run(step_list, world)
```

## Migration plan — Aldenmere first

1. **Engine session 1** (this ADR's implementation):
   - Land `step_runner.gd` with all 9 verbs + unit tests.
   - Refactor `scenario_runner.gd` to detect `steps` vs `actions`.
   - Refactor `capture_runner.gd` to delegate to StepRunner.
   - Add `--capture-script=<path>` cmdline flag.
   - All 13 demos' existing `tests.json` continue to work
     unchanged.

2. **Aldenmere migration session** (immediately after):
   - Convert `data/demo_aldenmere/tests.json` to use `steps`
     for the 7 WASD scenarios.
   - Add 3 new VQA-oriented scenarios (`vqa_*`) that exercise
     `click("New Campaign")` + diagonal hold + screenshot — the
     bug class that motivated this ADR.
   - Verify all 7 WASD scenarios pass + the 3 VQA scenarios
     produce the expected PNGs at the expected paths.

3. **Future** (out of scope for this ADR):
   - Migrate the 12 other demos' tests.json on a per-game basis.
   - Consider sunsetting the legacy `actions[]` schema in a future
     ADR once all demos migrate.
   - Add `wait_until` verb (poll a state field until a predicate
     passes) for tests that depend on async cascades.
   - Add `include: "@lib.steps.X"` composition (depends on ADR 0027
     extension to step files).

## Open questions for tech-director review

1. **Verb-set cap (mirroring ADR 0028 / 0037 operator-surface
   reasoning)**: should ADR 0039 explicitly declare the 9 v1 verbs
   as the COMPLETE set? Lean: yes — future verbs need their own ADR.
2. **`expect` compact form ambiguity**: `{"player.state.hp": {">=": 50}}`
   relies on `player` being a unique tag. Multi-player games would
   match multiple entities. ADR proposes `select: "first"` default
   (matching old assertion behavior). Acceptable, or should multi-
   match be an error?
3. **Click selector — Control vs. JSON id**: should the selector match
   the Control's `name` (Godot-side, post screen_flow build) OR the
   JSON `id` field used to author the screen? They're usually the
   same but screen_flow is allowed to mangle (uniqueness suffix).
   Lean: ADR mandates screen_flow set Control.name = JSON id verbatim,
   error on collision rather than mangling.
4. **Determinism of `wait seconds`**: floor vs. round when converting
   to ticks. `wait 0.05` with tick_seconds=0.1 → 0 ticks (floor) or
   1 tick (round)? Lean: round, but document.
5. **Effect-chain interaction**: `click` fires a button's `on_click`
   chain — that chain may include destructive effects
   (`transition_screen`, `reload_scene`). Step runner advances ONE
   tick after click, which gives the chain time to land. Sufficient,
   or do we need configurable post-click ticks?
6. **Visual gate**: `screenshot` writes a PNG. Pure data write — no
   rendering primitive change. Visual gate doesn't apply. Confirmed.
7. **Backward-compat lifetime**: ADR proposes "indefinite" for the
   legacy schema. Lean: declare deprecation in the ADR, plan removal
   for ADR 0050 or whenever the last demo migrates.

## Performance budget

Steps execute synchronously; each verb is O(1) work + O(N) tick advance
where N is the duration / tick_seconds. Aldenmere's 7 WASD scenarios
total ~100 ticks of advance — sub-second on the test runner. Visual
captures dominated by PNG encoding (~50ms per frame). No regression
vs. existing runners.

## Status

Proposed 2026-05-10. Awaiting tech-director review. Implementation
expected ~2 sessions: 1 engine (step_runner + refactors + unit tests),
1 Aldenmere migration + 3 new VQA scenarios.

## Tech-director review

_Reviewed: 2026-05-10_
_Verdict: **accept-with-conditions**_

All five standard greps ran clean before this ADR's code lands (nothing to
grep yet — the module does not exist). The review covers the ADR text and
implementation sketch as written.

### Invariant checks (pre-land baseline)

```
grep -rE '\bentities\.get\("[^"]+"\)'  → 0 matches  (Invariant #1 holds)
grep -rE 'type.*damage|heal|gain_xp…' → 0 matches  (Invariant #2 holds)
grep -rE 'extends Entity|class_name (Agent|Item|…)' → 0 matches  (Invariant #3 holds)
```

These must be re-run after `step_runner.gd` lands. Pass criteria unchanged.

---

### Q1 — Invariant #1 (JSON-only content channel)

PASS. Step lists live in `tests.json` (per-game content, already gitignored
data territory). `step_runner.gd` is a test-driver engine module, not
game-specific GDScript. No entity IDs are hardcoded. The boundary is clean.

### Q2 — Invariant #2 (no semantic effect types)

PASS. Steps (`press`, `hold`, `click`, etc.) are test-driver vocabulary, not
engine effect `type` strings. They never appear in `rules.json` or
`physics.json`. They do not enter `effect_apply.gd`'s dispatch path. The
surface is orthogonal to the effect primitive layer.

### Q3 — Invariant #8 (engine = primitives + interpreter; ADR gating)

PASS with condition. The 9 verbs are a primitive expansion of the
*test-driver interpreter*, not the game-rule interpreter. They do not change
tick semantics, effect dispatch, or query evaluation. The ADR correctly
requires future verbs to pass through an ADR. That gate must be written into
the ADR text explicitly as a binding rule:

**Condition C1**: Add the following sentence to the Decision section under
"Step vocabulary (FIXED v1 SET — 9 verbs)": "Future additions to this verb
set require a dedicated ADR with the same tech-director review gate. No verb
may be added by PR without an ADR." This makes the cap enforceable, not just
aspirational.

### Q4 — Click selector: Control.name = JSON id verbatim, error on collision

CONCERN — requires condition. Reading `control_factory.gd`, the `id` field
from JSON element specs is **not currently assigned to `Control.name`**.
`_apply_common` (line 236) sets `anchor`, `x_offset`, `y_offset`, `width`,
`height`, and size flags — there is no `node.name = spec["id"]` assignment.
The only explicit `node.name` assignment in the file is `"SettingsRenderer"`
on line 73 (the settings_renderer special case). Godot auto-assigns names
like `"Button"`, `"Button2"`, etc. on `add_child`.

The click selector's `{"id": "btn_new_game"}` path in `_do_click` would
walk the Control tree looking for `node.name == "btn_new_game"` — and it
would never match under current `control_factory.gd` behavior.

**Condition C2**: Before `step_runner.gd` ships, `control_factory.gd` must
be patched to assign `node.name = str(spec["id"])` whenever the element spec
contains an `"id"` field. The collision-error semantics the ADR proposes
(error rather than mangle) require this assignment to happen. The patch is
~3 lines in `_apply_common` after the existing `spec.has("anchor")` block.
Include a unit test asserting `node.name == spec_id` after build.

The `data_id` meta key mentioned in the ADR's click-walk pseudocode (step 3:
"match on `text` property ... or on `name` (Control id) or on a `data_id`
meta key") suggests a fallback path. That's acceptable as belt-and-suspenders
but does not substitute for the `node.name` assignment — the `id`-selector
form in the API says it matches by Control name, so Control name must be set.

### Q5 — Determinism: floor vs. round on wait seconds → ticks

ACCEPT the round decision with a required documentation fix.

The ADR uses `round` in `_do_hold` (implementation sketch line 520:
`int(round(seconds / world.tick_seconds))`). However, the Determinism section
(line 302) says "floor(seconds / tick_seconds)". These contradict.

**Condition C3**: Align the Determinism section with the implementation.
Change line 302's "floor(seconds / tick_seconds)" to "round(seconds /
tick_seconds)" and add a note: "Authors holding for a duration not evenly
divisible by tick_seconds should prefer multiples of tick_seconds to avoid
rounding artifacts." Both `wait seconds` and `hold for` must use the same
rounding policy — document them together in the Determinism section.

### Q6 — Effect-chain interaction: one tick after click sufficient?

CONCERN — requires condition. `btn.pressed.emit()` fires the `on_click`
chain synchronously inside `screen_flow.gd`'s dispatcher. However,
destructive effects (`transition_screen`, `transition_level`, `reload_scene`)
are *enqueued* into `env.screen_event_buffer` and drained in
`ScreenFlow._process`. That draining happens in the Godot process frame, not
in `_advance_one_tick`.

The `_advance_one_tick` implementation sketch calls:
`scheduler.tick()` + `_decrement_lifetimes()` + `process_pending_level_transition()`.

This is **incomplete**. Actual `world._on_tick()` (lines 798-828 of
`world.gd`) also calls: `actor_manager.tick_policies`, `LifecycleDirector.tick`,
`process_chunk_streaming`, `process_pending_save_load`,
`process_pending_actor_switch`, `process_pending_world_reset`. The
`screen_event_buffer` is drained in `ScreenFlow._process` (a Godot frame
callback), which does NOT run during `_advance_one_tick` at all — so
`transition_screen` effects fired by a `click` may not resolve before the
next step executes.

For a `click` whose `on_click` chain contains only state-mutating effects
(no destructive transitions), one tick is sufficient. For chains that contain
`transition_screen` or `transition_level`, one tick is NOT sufficient because
the screen swap has not processed.

**Condition C4**: The implementation must either:

(a) After `btn.pressed.emit()`, drain `env.screen_event_buffer` synchronously
(call `_drain_screen_events()` directly on the ScreenFlow node, or process it
in-place) before advancing the tick. This makes click+screen-transition
deterministic without depending on a process frame.

(b) OR expose a `post_click_ticks` parameter on the `click` verb (default 1),
so authors can write `{"click": "Start", "post_click_ticks": 2}` when their
chain includes a deferred destructive effect.

Option (a) is preferable — it keeps the API simple and makes click
deterministic. If `_drain_screen_events` is not accessible from `step_runner`
without a reference to the ScreenFlow node, add a
`world.drain_screen_events()` forwarding method to `world.gd`.

**Also**: the `_advance_one_tick` helper must mirror `world._on_tick` fully —
not a subset of it. Factor this as a `world.advance_one_tick()` public method
on `World` that `_on_tick` calls internally, so that `step_runner` calls
`world.advance_one_tick()` and both paths stay in sync. This is the
"factor into a world.advance_tick() method" option raised in the ADR's Open
Question 9. Tech-director position: **this refactor is mandatory**, not
optional. A diverged private `_advance_one_tick` in step_runner will drift
from `_on_tick` as new phases land (chunk streaming, lifecycle, etc.) and
produce scenario tests that pass headlessly but behave differently from live
play. That is an invariant violation of test-as-documentation.

### Q7 — Backward-compat lifetime: deprecate now vs. future-ADR trigger

CONDITION. "Indefinite" is not acceptable as written — it removes pressure to
migrate and creates permanent dual-code-path maintenance. The ADR must set a
concrete deprecation trigger.

**Condition C5**: Replace "A future ADR may sunset the legacy path once all
demos migrate. For v1, both coexist indefinitely." with: "The legacy
`actions[]` schema is deprecated as of ADR 0039. New scenarios must use
`steps`. Existing demos migrate at their own pace. The legacy path will be
removed when the last demo's `tests.json` has no `actions` key — or by ADR
0050, whichever comes first. The `_run_legacy` code path must print a
deprecation warning on each invocation: `push_warning('[scenario] legacy
actions[] schema used in %s; migrate to steps' % sc.get('name', '?'))`."

### Q8 — Schema drift risk: variable verb shapes

ACCEPT. The variability is ergonomically justified. `hold` has `for`;
`click` has either a string or a dict with `text`/`id`/`screen`. The shapes
match their natural semantics — forcing all verbs to one shape would produce
ugly JSON. The `_detect_verb` dispatch on the dict key (rather than a `type`
discriminator) means authors can't accidentally write an unknown shape that
silently no-ops; the STEP_UNKNOWN_VERB error catches it. Acceptable for v1.

One constraint: the ADR must state that **no verb key name may collide with
common entity-spec field names** (`id`, `tags`, `state`, `type`, `position`).
Currently none do. The collision risk is low but should be documented as a
future-verb naming constraint.

### Q9 — world.advance_tick() refactor

Already addressed under Q6 / Condition C4. To restate the binding ruling:
`_advance_one_tick` **must** be a method on `World`, not a static private
in `step_runner`. Call it `world.advance_one_tick()`. The method's body is
the same sequence as `_on_tick` (minus the WorldClock's timer signal path —
the method is called directly by the test driver). `_on_tick` becomes:

```gdscript
func _on_tick(count: int) -> void:
    if freeze: ...return
    advance_one_tick()
    if verbose and count % 4 == 0: ...
```

The public method guarantees that scenario tests and live play execute
identical tick logic.

### Q10 — Screenshot determinism (no PNG diff for v1)

ACCEPT. PNG output non-determinism is a GPU driver property; the input-path
is deterministic. v1 saves the PNG for human review; pixel-diff comparison is
a future feature. Document this explicitly in the ADR (it is already noted at
line 308). No condition.

---

### Post-mortem ritual check

The motivating bug: `capture_runner.gd` had no `click()` primitive, so
visual QA of title-screen-gated scenarios required manual workarounds. The
post-mortem ritual requires:

1. Fix: the `click` verb in this ADR is the fix.
2. Gate owner: `capture_runner.gd` — its design surface did not include
   UI-interaction primitives. The missing gate was in `yume-qa-tester`'s
   capture workflow, which had no checklist item verifying that every
   required user interaction (button clicks to reach gameplay) was
   expressible in the capture script.
3. Gate hardened: ADR 0039's test plan includes `step.test_click_by_text`
   and `step.test_click_not_found` unit tests, and the migration plan adds
   3 VQA scenarios that exercise `click("New Campaign")` as the canonical
   post-title-screen entry point. This gates the specific bug class.
4. Missing secondary hardening: `yume-qa-tester`'s SKILL.md should add a
   checklist item: "For any game with a title screen (`starting_screen` !=
   gameplay), the VQA capture script must include a `click` step to dismiss
   the title before capturing gameplay state. Verify this before declaring
   the capture scenario authored." This prevents the next game from silently
   shipping a capture that photographs the title screen instead of gameplay.

**The ADR satisfies steps 1-3 of the ritual. Step 4 (skill hardening in
`yume-qa-tester`) is a required follow-on — it is not blocking ADR
acceptance but must land in the same implementation session.**

---

### Conditions summary (all must be resolved before merge)

| # | Condition | Where to fix |
|---|---|---|
| C1 | Add binding sentence: future verbs require an ADR with tech-director review | ADR §Decision, verb-set table |
| C2 | `control_factory.gd` must assign `node.name = str(spec["id"])` when `id` is present; include unit test | `control_factory.gd` + `test_runner.gd` |
| C3 | Align Determinism section to use `round` (not `floor`); document both `wait` and `hold` consistently | ADR §Determinism |
| C4 | `_advance_one_tick` must be `world.advance_one_tick()` public method mirroring full `_on_tick` sequence; `click` must drain `screen_event_buffer` synchronously after `pressed.emit()` | `world.gd` + `step_runner.gd` |
| C5 | Deprecate legacy `actions[]` schema with a concrete sunset trigger (ADR 0050 or last-demo-migrated); add `push_warning` on legacy-path invocation | ADR §Backward compat + `scenario_runner.gd` |

None of the conditions block the ADR from proceeding to implementation — they
must be incorporated into the implementation session, not a separate follow-on.
The test plan already covers the happy paths; C2 and C4 add coverage for the
two structural gaps identified above.

### Final verdict

**Accept with conditions C1-C5.** The architectural direction is correct:
one DSL, one executor, backward-compatible shim, 9-verb fixed set with ADR
gating for expansion. The two structural issues (Control.name not assigned by
current control_factory, _advance_one_tick divergence from _on_tick) are
implementation-sketch gaps that must close before the module ships. Update
ADR status to `accepted` once C1, C3, C5 are written into the ADR text and
the implementer acknowledges C2 and C4 as implementation obligations.

_Reviewed by: yume-tech-director, 2026-05-10_
