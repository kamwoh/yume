# `/yume-design` skill — behavioral tests

These tests describe **expected behavior** of the `/yume-design` skill
for a set of fixture prompts. Each test case lists:

- **Input prompt** the user types
- **Expected outputs** (file paths created, file content shape)
- **Pass criteria** (qa-tester verdict, cascade markers)

Tests are run **manually** today — invoke `/yume-design` with the
fixture prompt and compare outputs against the spec. Future automation
(2.5h+) would invoke the skill programmatically and diff outputs.

## Why behavioral, not unit

Each agent has its own deterministic-ish role, but the skill
orchestrates LLM calls — outputs vary across runs. Unit tests don't
make sense. Behavioral tests check:

- **Pipeline shape** — all 6 phases ran (GDD → sketches → content →
  assets → QA → wrap)
- **File structure** — expected paths created
- **Schema** — generated JSON validates (`Rule.validate_all` returns 0
  errors), entities tags consistent, rules well-formed
- **Cascade outcome** — qa-tester reports the GDD's intended dynamics
  observed empirically

These check the *meta-shape* of the output, not the exact bytes.

## Test cases

### TC-01: simple farming sim

**Prompt:**
```
/yume-design "a small farming sim — a player walks around, plants seeds,
harvests crops when ripe, ties them into a counter"
```

**Expected outputs (per ADR 0009):**
- `docs/games/farming-sim/GDD.md` (or similar slug)
- `docs/games/farming-sim/rules-sketch.md`
- `godot/data/demo_farming-sim/entities/` or `entities.json`
- `godot/data/demo_farming-sim/world/physics.json`
- `godot/data/demo_farming-sim/game/rules.json` (if game has scoring/win)
- `godot/data/demo_farming-sim/scene.json`
- `godot/scenes/farming-sim_2d.tscn`
- `docs/games/farming-sim/qa-report.md`

**Schema checks:**
- entities have `definitions` array with ≥ 5 entries (player +
  seed + young + mature crop + ground or similar)
- world/physics.json has ≥ 5 rules covering:
  - movement (input → velocity_set, 4 directions)
  - crop growth (tick → state_add)
  - growth threshold transforms (seed → young → mature)
- game/rules.json (if present) covers harvest scoring (contact +
  state_add on a counter)
- All rules pass `Rule.validate_all` (0 errors)

**Cascade verification (qa-tester):**
- Crop maturation cascade fires within ~30s of headless tick
- Harvest mechanic produces measurable counter increment
- No runaway feedback loops (entity count stable or growing
  intentionally)

**Pass criteria:**
- All 6 stages completed
- All file paths exist
- Schema checks pass
- qa-report shows cascades observed
- Game runs in `world_2d.tscn` and `world_3d.tscn` (after
  `data_root` swap)

---

### TC-02: out-of-scope rhythm game (rejection path)

**Prompt:**
```
/yume-design "a rhythm game where you tap to the beat and accumulate
combo multipliers"
```

**Expected behavior:**
- Skill reads docs/30 non-goals + identifies "rhythm" as out-of-scope
- **Phase 0 (setup) refuses to proceed**, surfaces to user:
  "Yume's contract excludes precision-timing games. Rhythm needs a
  `scheduled` trigger (reserved for post-W5) + sub-tick timing
  resolution. Want to descope to a 'tap-to-grow' tick-based variant?"
- User must affirmatively pick a substitute or abort.

**Pass criteria:**
- Skill DOESN'T spend agent calls on a doomed pipeline
- Surfaces non-goal early with concrete guidance
- Offers a workable alternative or accepts user's choice to abort

---

### TC-03: extension to existing demo

**Prompt:**
```
/yume-design "extend the existing demo_ecology with a thunderstorm event
that periodically strikes random trees"
```

**Expected behavior:**
- Skill detects "extend X" + reads `docs/games/` + existing `data/demo_*`
- Phase 1 (game-designer): produces a delta GDD scoping just the
  thunderstorm addition (NOT a full ecology rewrite)
- Phase 2 (systems-designer): proposes new entity (thunderstorm) +
  rules (tick spawn lightning at random tree, transform tree to
  burning_tree). Likely needs no new primitive — composition with
  existing seven.
- Phase 3 (content-designer + systems-designer): MODIFIES
  `data/demo_ecology/entities.json` + `world/physics.json` rather than
  creating new folder
- Phase 5 (qa-tester): verifies thunderstorm fires + ignites trees,
  AND that pre-existing cascades (fire spread, predation, etc.) still
  work (no regression)

**Pass criteria:**
- Modifies-in-place (no new demo folder)
- Existing demo_ecology cascades still pass after change
- Thunderstorm dynamics verified

---

### TC-04: ambiguous prose (clarification gate)

**Prompt:**
```
/yume-design "a fantasy game"
```

**Expected behavior:**
- game-designer cannot decompose this — too vague
- Phase 1 outputs ONLY clarifying questions, no GDD:
  - "What's the core verb? (combat / exploration / building / ...)"
  - "What's the aesthetic target? (challenge / story / mystery / ...)"
  - "Single-player or multiplayer (note: MP is Tier 4)?"
  - "Any specific genre conventions you want? (D&D-like RPG, JRPG,
    roguelike, etc.)"
- Skill **does NOT proceed past Phase 1** until user provides
  enough specificity

**Pass criteria:**
- No JSON files created from a one-word prose
- Game-designer surfaces specific questions tied to non-goals + open
  decisions
- User dialog continues until prompt is GDD-able

---

### TC-05: invariant-violation attempt

**Prompt:**
```
/yume-design "a game where attacks deal damage with an effect type
called 'damage' and we want to add a new 'gain_xp' effect type"
```

**Expected behavior:**
- systems-designer reads the prose literally + identifies the
  user is asking for forbidden semantic effect types
- Phase 2 (systems-designer) refuses + explains:
  "Yume's invariant #2 forbids semantic effect types. 'damage' is
  expressible as `state_add hp -X`. 'gain_xp' is `state_add xp +X`.
  The engine knows nothing about these semantics by design — see
  ADR 0001."
- If user insists on the literal effect names, escalate to
  tech-director who refuses with the contract reference
- User must accept the existing primitive vocabulary

**Pass criteria:**
- No commit happens with `damage` / `gain_xp` as effect type strings
- Invariant grep over `scripts/engine/` continues to return zero
  matches after the run

---

## Fixture prompts (for future automation)

These prompts are stable input cases. Once 2.5h+ has a programmatic
test runner, these become CI fixtures:

```yaml
# .claude/skills/yume-design/tests/fixtures.yaml
fixtures:
  - id: TC-01
    prompt: "a small farming sim..."
    expected_phases: [GDD, sketch, content, assets, QA, wrap]
    expected_files:
      - docs/games/*/GDD.md
      - data/demo_*/entities.json
      ...
  - id: TC-02
    prompt: "a rhythm game..."
    expected_outcome: rejected_at_phase_0
    expected_reason_contains: "scheduled trigger"
  ...
```

## Manual test execution

For now (Tier 2.5 prototype state):

1. Run `/yume-design <fixture prompt>` via Claude Code
2. Walk through approval gates (approve, then verify the produced
   artifact)
3. After Phase 5 (qa-tester), check qa-report.md
4. Cross-reference output against this spec:
   - File paths match expected?
   - Schema valid?
   - Cascades observed?
5. Note discrepancies — report bugs in the relevant agent's prompt
   or the skill orchestration logic

## What's NOT in scope of these tests

- Visual quality of generated games (subjective; covered separately
  via VQA skill)
- Asset-gen output (separate workflow; Tier 2.5k tool)
- Performance benchmarking (W4.8 + future)
- Multi-session iteration on the same game (state preservation)

## Status

- Test cases: 5 documented, manually executable
- Automation: deferred. The current value is the **spec** —
  contributors can read this to understand what "good" looks like
  for the skill output.
