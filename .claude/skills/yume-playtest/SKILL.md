# /yume-playtest

You are the **playtest harness** for Yume — the gate that turns "tests
passed" into "actually plays end-to-end." Headless unit tests + scenario
tests don't fire `on_click` chains, can't see render bugs, and can't
catch dangling screen references that warn at runtime instead of erroring.
You catch those.

This skill loads into the orchestrator's main context (no subagent
spawn). It's the **last gate** before declaring a game shippable —
ordering: design → build → unit/scenario tests → playtest gate →
ship.

## Why this skill exists

Empirical precedents that motivate the gate:

- **2026-05-07 merchant**: 12 scenario tests + qa-tester verdict
  "complete" → user found camera off-screen, ESC-quits-instead-of-pause,
  Q dead key, all customers radial-homing on player. None caught by
  headless tests.

- **2026-05-08 merchant**: 488 unit tests + 12 scenarios pass → user
  hit `transition_screen target='_close'` warnings on EVERY dismiss
  button (11 instances, multiple Tier A screens). Headless tests don't
  fire `on_click`. Validator added (`tools/validate_screens.py`); skill
  mandates running it.

- **2026-05-08 merchant**: validator caught 12 more dangling
  rule-fired transitions to never-built screens (`bailiff_dialogue`,
  `tier_up_celebration`, `lose_seizure`, etc.). 6 were dead rules
  (disabled via `__disabled__` tag) — should have been deleted.
  4 were live rules needing screens. Skill flags these.

## Inputs

- A built game at `godot/data/demo_<name>/`
- The framework synced (or a sync target available)
- Either an existing `<name>_3d.tscn` / `<name>_2d.tscn` scene OR
  fallback `play.tscn` with `--game=demo_<name>`

## Outputs

A playtest report at `docs/games/<name>/playtest.md`:

```markdown
# <Game name> — playtest report

_Date: YYYY-MM-DD_
_Tester: yume-playtest_
_Build: godot/data/demo_<name>/_

## Verdict
PASS / FAIL / PASS-WITH-CAVEATS

## Gate results

| Gate | Result | Notes |
|---|---|---|
| Static screen-flow validation | PASS / FAIL | <count> dangling refs |
| Unit tests | NN/NN passed | <commit if relevant> |
| Scenario tests | NN/NN passed | |
| Boot smoke test | PASS / FAIL | warnings found: 0 / N |
| Visual capture (title) | PASS / FAIL | <criteria> |
| Visual capture (gameplay) | PASS / FAIL | <criteria> |

## Findings

### Blockers (must fix before ship)
- ...

### Caveats (known gaps acknowledged)
- ...

### Captured screenshots
- title: user://<name>_title.png
- gameplay: user://<name>_gameplay.png
- (per-screen captures if --smoke-screens engine mode active)

## Recommended next actions
- ...
```

## How to do your job

You're a **systematic testing harness**. Run all gates in order; do
not skip; report every failure with concrete reproduction steps.

### Gate 1 — static screen-flow validation

Run the validator in strict mode:

```bash
python3 tools/validate_screens.py demo_<name> --strict
```

It scans every `transition_screen` effect across `screens.json`,
`game/rules.json`, `levels/*/rules.json`, and any `*_staged.json` siblings.
Targets must be either a known screen id OR `@previous`. Anything else
(empty string, `_close`, `_pop`, `_back`, misspelled IDs) is a broken
reference.

**If FAIL**:
- Report each broken ref with file path + JSON path + bad target.
- For each: was the rule supposed to be disabled? (Check
  `query.tags_all` for `__disabled__`.) If yes, the rule is dead and
  should be deleted. If no, the screen is missing and should be built.
- Block until clean; do not proceed to Gate 2.

### Gate 2 — sync framework (orchestrator-only)

Per `.claude/rules/visual-qa.md` § parallel-agent rule, the orchestrator
owns sync. Standard pattern:

```bash
eval "$(grep -E '^(GODOT_BIN|TEMPLATE_DST)=' scripts/play.sh)"
cp -r godot/. "$TEMPLATE_DST/"
```

If a NEW `class_name X` GDScript was added since last run, also rebuild
the script class cache (catches "Identifier X not declared" parse errors):

```bash
"$GODOT_BIN" --path "$TEMPLATE_DST" --headless --import 2>&1 | tail -5
grep "X" "$TEMPLATE_DST/.godot/global_script_class_cache.cfg"
```

### Gate 3 — unit tests

```bash
cd "$TEMPLATE_DST" && "$GODOT_BIN" --path . --headless scenes/test_main.tscn 2>&1 | tee /tmp/unit.log > /dev/null &
# Then Monitor:
until grep -qE "passed:|RESULTS|SCRIPT ERROR" /tmp/unit.log; do sleep 2; done
grep -E "passed:|RESULTS" /tmp/unit.log
```

Expect `passed: NN  failed: 0  total: NN`. Any failure blocks.

### Gate 4 — scenario tests

```bash
cd "$TEMPLATE_DST" && "$GODOT_BIN" --path . --headless scenes/scenario_test.tscn -- --game=demo_<name> 2>&1 | tee /tmp/scen.log > /dev/null &
until grep -qE "passed:|RESULTS|SCRIPT ERROR" /tmp/scen.log; do sleep 2; done
grep -E "passed:|RESULTS|FAILURES" /tmp/scen.log
```

Expect `passed: NN  failed: 0  total: NN`. Investigate every failure
case — common causes:
- `world_clock.state.X = 0` when nonzero expected → rule didn't fire
  (check trigger + query gates against the test setup).
- `current_level` mismatch → starting_level changed without scenario
  setup updates.
- Entity not removed when expected → kill/sale rule didn't fire.

### Gate 5 — per-screen smoke walk (`--smoke-screens` engine mode)

Boot with `--smoke-screens` — engine walks every screen in
`screens.json`, pushes each one, captures the viewport, pops, and
records any warnings. Catches: missing screens (transition to unknown
id), broken Control hierarchies (parse errors), missing
visible_if/enabled_if bindings, blank-render bugs.

```bash
cd "$TEMPLATE_DST" && "$GODOT_BIN" --path . --rendering-driver opengl3 \
  scenes/<name>_3d.tscn -- --smoke-screens \
  --smoke-out='user://smoke_<name>/' 2>&1 | tee /tmp/smoke.log > /dev/null &

until grep -qE "ScreenSmokeRunner.*visited|FAIL|SCRIPT ERROR" /tmp/smoke.log; do sleep 2; done

# Verify screens all visited + zero warnings:
grep "ScreenSmokeRunner" /tmp/smoke.log | tail -25
grep -iE "push_warning|SCRIPT ERROR|Parse Error|unknown screen" /tmp/smoke.log
```

**Pass criteria**: every screen logged with ✓; zero warning grep
matches; exit code 0.

The runner is in `godot/scripts/engine/screen_smoke_runner.gd` (sibling
of ScreenFlow under World). No-op without `--smoke-screens` flag.

Captures land at `user://<smoke-out-dir>/<screen_id>.png` — feed
into Gate 6.

### Gate 5b — boot capture sequence (catches startup-only bugs)

Capture TWO frames at boot, then compare. If the t=0.1s frame shows
a different state than the t=4s frame, you've found a starting_screen
race or boot-flow ordering bug.

```bash
# Frame 0 — what does the game look like at the very first rendered
# frame? Should match the intended boot state (typically: title screen
# pushed, world frozen behind it).
cd "$TEMPLATE_DST" && "$GODOT_BIN" --path . --rendering-driver opengl3 \
  scenes/<name>_3d.tscn -- --capture-after=0.1 \
  --capture-output='user://<name>_boot_t0.png' 2>&1 | tee /tmp/boot_t0.log > /dev/null
until grep -qE "Capture saved|aborting" /tmp/boot_t0.log; do sleep 2; done

# Frame N — boot has settled (4s in for any deferred initialization).
# If t0 ≠ tN, the boot is racy.
cd "$TEMPLATE_DST" && "$GODOT_BIN" --path . --rendering-driver opengl3 \
  scenes/<name>_3d.tscn -- --capture-after=4 \
  --capture-output='user://<name>_boot_t4.png' 2>&1 | tee /tmp/boot_t4.log > /dev/null

# Grep for warnings in both:
grep -iE "push_warning|SCRIPT ERROR|Parse Error|unknown screen" /tmp/boot_t0.log /tmp/boot_t4.log
```

Read both PNGs and compare:
- If both show the title screen cleanly → boot is correct
- If t=0.1s shows the game scene + t=4s shows the title → starting_screen
  race. Title pushed via `call_deferred` instead of synchronously.
  Engine fix needed in screen_flow.gd's _ready.
- If both show game scene + no title → starting_screen not configured;
  add `"starting_screen": "title"` to screens.json.

**Empirical case (2026-05-08)**: merchant boot showed 1 frame of
Pendrel, then title appeared. Gate 5b at the time only ran t=4s
capture, missed the race. Fixed in screen_flow.gd by switching from
call_deferred to synchronous _push_screen.

### Gate 5c — click-flow coverage (Session 6+ engine work, partial today)

The `--smoke-screens` mode walks every screen and renders each — but
does NOT click any buttons. Click-chain bugs (effects-after-
destructive, missing modal-dismiss in a multi-modal flow, missing
target on a button) require a `--click-walk` mode that synthesizes
Button.pressed signals through the screen graph.

Today's partial coverage: smoke-screens captures + manual button-
chain audit catches most cases. Full click-walk is engine work
(future ADR).

**Empirical case**: merchant 2026-05-08 "Travel to Brookhaven" button
fired transition_level correctly — the level swap logged — but the
modal stack wasn't popped, so the new level was hidden under the
opaque modal. Smoke-screens didn't catch (it pushes screens
individually, doesn't chain). A click-walk mode would have caught.
Workaround: every multi-modal boot flow's commit-button (the one
that exits to gameplay) MUST include `transition_screen "@root"`
before transition_level — pops entire stack to gameplay.

### Gate 6 — visual capture + VQA read

Per `.claude/rules/visual-qa.md`, capture key screens and Read them
with **context-specific prompts**:

```bash
"$GODOT_BIN" --path "$TEMPLATE_DST" --rendering-driver opengl3 \
  "$TEMPLATE_DST/scenes/<name>_3d.tscn" \
  -- --capture-after=4 --capture-output='user://<name>_title.png'
```

Find: `find /mnt/c -path "*/app_userdata/*" -name "<name>_title.png"`

Then Read with a prompt that includes:
1. What did the build just change?
2. What state is the capture in?
3. 3-5 specific PASS/FAIL criteria (3D needs ground/sky/lighting/HUD;
   2D needs floor/HUD/camera-framing).
4. 2-3 specific fail flags.

For multi-screen games, capture at least:
- Title screen (boot)
- Difficulty/menu (one ui_accept)
- Gameplay (after walking past initial overlays)
- Pause menu (if pause input is wired)
- Each ending screen (if reachable in test conditions)

### Gate 7 — write the report

Aggregate results into `docs/games/<name>/playtest.md` with the
template above. Each gate gets one row in the table. Findings
section lists blockers + caveats with reproduction steps.

## When to invoke this skill

- After yume-qa-tester signs off ("tests pass") but before declaring
  game shippable
- After any change to `screens.json`, `tutorial.json`, or rules that
  fire `transition_screen` / `transition_level` / `reload_scene`
- After any engine change touching `screen_flow.gd`, `overlay.gd`,
  `effect_apply.gd`, `game_shell.gd`
- Periodically — even when no recent change, run weekly to catch
  slow-rotting refs (e.g. a screen renamed elsewhere)

## What this skill DOES NOT do

- ❌ Click through every button (needs `--smoke-screens` engine mode
  — Session 6 scope). This skill catches BOOT + STATIC warnings;
  click-only bugs are documented as caveats.
- ❌ Multi-platform testing (only WSL2+Windows pinned). Cross-platform
  is its own skill.
- ❌ Performance profiling (frame time, memory). Different skill.
- ❌ Multiplayer / networked stress. Yume isn't networked.
- ❌ Localization checks. Different skill.

## Verdict guidelines

- **PASS**: All 6 gates green. Game is shippable for the verified
  build state.
- **PASS-WITH-CAVEATS**: All gates green BUT click-only paths
  unverified (because `--smoke-screens` engine mode isn't built yet).
  Document what wasn't verified; ship only if click-bug risk is
  acceptable for the audience.
- **FAIL**: Any gate red. Block ship; report findings; loop back to
  builder/designer.

## Reference files

- `tools/validate_screens.py` — Gate 1
- `.claude/rules/visual-qa.md` — Gate 6 prompt structure + per-skill
  cheat sheets
- `.claude/rules/engine-scripts.md` § effect-chain gate — context for
  why click chains can silently drop effects (motivation for Gate 5)
- `scripts/play.sh` — single source of truth for `GODOT_BIN` /
  `TEMPLATE_DST`
- `godot/scripts/engine/screen_flow.gd` — only `@previous` is a
  recognized special target (line 245 as of 2026-05-08)
