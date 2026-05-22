# ADR 0056 — Visual assertion library + capture-per-test runner

_Date: 2026-05-22_
_Status: accepted_

## Context

Visual review today has two failure modes:

1. **Too generic.** `yume-visual-designer`'s 7+10-axis rubric is
   designed to grade ANY frame — palette / composition / hierarchy.
   But "is `tree_oak_01` taller than `player_marken`?" is a yes/no
   question about THIS game's entities; the rubric can't ask it,
   so scale mismatches ship.

2. **Fixed coverage misses game-specific bugs.** A pre-planned shot
   battery captures the SAME N angles per game. A desert game
   doesn't have water; a sokoban game doesn't have trees. Either
   the battery wastes shots or misses what matters.

What's missing: visual checks that are GENERATED from this game's
actual contents, then verified one by one. Like unit tests, but for
what the player would see.

Empirical drivers:

- 2026-05-21 free_camera cubes shipped invisible to the player-FPS
  view; only caught when free_cam moved near one. A
  `no_orphan_cubes` assertion would have caught it on round 1.
- 2026-05-18 dwarf-bush pattern floated 1.15m above ground because
  `y_offset_mesh` wasn't scaling with `state.scale`. A
  `no_floating` assertion would have caught it.
- 2026-05-18 morwen animated mesh floated 0.85m because legacy
  `y_offset` wasn't cleared on pivot change. A `pivot_at_foot`
  assertion would have caught it.

Each of these was post-mortem'd into a static validator or rule —
but only AFTER the bug. A visual assertion library would catch the
bug class on first visual QA, before it ships.

## Decision

Land **Phase A** of the test-driven visual QA pipeline (Phase B,
the auto-generator skill, lands as separate ADR 0057):

### Piece A1 — Visual assertion library

`data/lib/visual_qa/assertions/<name>.json` — one file per assertion
class. Each declares:

```jsonc
{
  "id": "relative_size",
  "description": "...",
  "params_schema": {
    "entity_a": "entity_id_or_def",
    "entity_b": "entity_id_or_def",
    "expected": "taller | shorter | similar"
  },
  "framing": {"rule": "side_profile", "subject": "both_in_frame"},
  "prompt_template": "Entity A is {entity_a_label} at world {pos_a}. Entity B is {entity_b_label} at {pos_b}. In this image, is A {expected} than B? Answer PASS or FAIL with one sentence of pixel-height evidence.",
  "common_fix": "state_init.scale on the smaller entity, or check visual.y_offset_mesh for stale pivot offset."
}
```

Starter set (Phase A):
1. `relative_size` — A taller/shorter/similar to B
2. `no_clipping` — A's mesh doesn't pass through B
3. `rotation_facing` — entity rotated toward a target
4. `no_floating` — entity's base touches ground (no gap below)
5. `distinct_silhouettes` — A and B visually distinguishable
6. `no_orphan_cubes` — no mystery cubes in sanity-sweep frames
7. `specular_response` — material responds to lighting as expected
8. `pivot_at_foot` — character mesh base on ground, not mid-y

Each assertion's `framing.rule` indexes into the table from
`.claude/rules/visual-qa.md` Step 0b — so the camera math is shared
across assertions, not reinvented per-assertion.

### Piece A2 — Test plan format

`visual_test_plan.json` — list of concrete test instances:

```jsonc
{
  "game": "demo_aldenmere",
  "level": "level_proto_village",
  "tests": [
    {"id": "rel_size_tree_player",
     "assertion": "relative_size",
     "params": {"entity_a": "tree_oak_01", "entity_b": "player_marken", "expected": "taller"}},
    {"id": "no_clip_hut_ground",
     "assertion": "no_clipping",
     "params": {"entity_a": "shelter_mud_hut", "entity_b": "ground"}},
    {"id": "morwen_faces_fire",
     "assertion": "rotation_facing",
     "params": {"entity": "npc_morwen", "target": "fire_pit"}},
    {"id": "sanity_no_cubes_NE",
     "assertion": "no_orphan_cubes",
     "params": {"shot": "wide_NE"}}
  ]
}
```

Phase A: plans are hand-authored. Phase B (ADR 0057): generated
from GDD + entities + diff.

### Piece A3 — Test runner (`tools/visual_qa/run_plan.py`)

Python orchestrator. For each test:

1. Look up the assertion's framing rule + the entity params
2. Resolve entities → world positions (grep level entities.json)
3. Compute camera pose from `Step 0a/0b` tables
4. Drive Godot once: spawn a free_camera at the computed pose,
   toggle freecam via `--capture-input='toggle_freecam,0.3'`,
   capture, restore
5. Render the assertion's `prompt_template` with resolved labels +
   positions
6. Output: `visual_test_report.md` listing each test, its PNG
   path, the rendered prompt, and a slot for the verdict

Phase A: the verdict step is human/Claude-in-session (read the
report, walk each test, mark PASS/FAIL). Phase B/C wires this into
an automated assertion-checker pass.

## Consequences

**Positive**:
- Game-specific bugs (scale mismatch, clipping, floating, mystery
  cubes) become catchable by name, not by luck.
- Each bug class added to the library prevents the same class in
  every future game. The library compounds.
- The `framing` field bakes Step 0a/0b camera math into reusable
  units — operators stop reinventing camera poses per test.
- Failures are surgical: assertion id + params name the entity to
  fix and the bug class. Specialists don't guess.

**Negative**:
- Hand-authored test plans don't scale beyond a few demos. Phase B
  (ADR 0057) addresses this with an LLM generator.
- Each test is one Godot run (~3-5s). At 8-15 tests per plan, a
  full pass is ~30-90s. Acceptable for now; batch-capture in a
  single Godot run is a Phase C optimization.
- Assertion library needs ongoing maintenance — tied to the
  post-mortem ritual (each new bug class adds an assertion).

**Neutral**:
- No new engine primitive. Reuses existing `--capture-input`,
  `--capture-after`, `--capture-output` machinery + the
  free_camera entity-model from the 2026-05-21 refactor.
- New runner under `tools/visual_qa/` follows the existing
  authoring-tools convention (ADR 0051).

## Alternatives considered

1. **Fixed shot battery** (prior draft of this work). Solves "what
   to capture" but not "what to check." Rejected — would still
   ship scale-mismatch bugs.
2. **Pure rubric-reviewer extension** — add per-bug-class axes to
   yume-visual-designer. Rubric is for subjective grading;
   binary assertions deserve binary tests. Doesn't scale.
3. **Hand-authored `tests.json` per game** (mirror of engine
   scenario tests). Doesn't adapt to new entities. Phase A's plan
   IS hand-authored, but Phase B replaces that.
4. **VLM-as-Judge with no specific assertions** — show Claude the
   capture, ask "anything wrong?" Vague feedback that can't drive
   targeted revision.

## Acceptance gate (Phase A)

- 8 starter assertion JSONs land under `data/lib/visual_qa/assertions/`.
- `tools/visual_qa/run_plan.py` runs a hand-authored plan on
  aldenmere and produces `visual_test_report.md` with PNG paths +
  rendered prompts.
- At least one test in the aldenmere plan catches a real bug class
  (e.g., the `no_orphan_cubes` assertion correctly flagged the
  pre-fix free_camera cubes — would catch them again if regressed).

## Related

- `.claude/rules/visual-qa.md` § Step 0a/0b/0c — provides the
  camera-framing math this ADR reuses.
- `.claude/rules/data-demo.md` § logical/singleton entities need
  visual.hidden — same bug class the `no_orphan_cubes` assertion
  guards against at visual QA time (the data-demo rule guards at
  authoring time).
- ADR 0057 — the auto-generator skill that produces test plans
  without human authoring.
