---
description: Stability tiers for Yume's three text-to-X generation pipelines under tools/visual_layout/
globs: tools/visual_layout/**, .claude/skills/yume-hud-author/**, .claude/skills/yume-screen-author/**, .claude/skills/yume-map-author/**
---

# Pipeline stability — what's locked vs active

Yume has three sibling pipelines under `tools/visual_layout/`, all
following the same LLM-as-parser pattern (prompt → Gemini image →
preprocess context → LLM authors draft → postprocess validates +
splices). Their stability differs and modifying them requires
different discipline.

## STABLE — locked, ADR required to modify

These pipelines are 2D fit-fit (input space = output space). The
harness is settled; validators close known schema gaps; scenario
regression tests cover them.

- **HUD pipeline** — `compose_hud.py`, `wireframe_to_hud.py`,
  `/yume-hud-author`. Confirmed stable 2026-05-24.
- **Screen pipeline** — `compose_screen.py`,
  `wireframe_to_screen.py`, `/yume-screen-author`. Confirmed
  stable 2026-05-24.

### Modifying a stable pipeline

Before touching any file in the stable surface:
1. **Author an ADR** in `docs/adr/` describing the workflow change,
   the empirical case motivating it, and the contract change (if
   any) to the postprocess-validated JSON shape.
2. **Verify** `tools/visual_layout/tests/test_screen_chain_validator.py`
   (and any other regression tests under
   `tools/visual_layout/tests/`) still pass.
3. **Update the stability banner** in the affected files' docstrings
   if the surface boundary changes.

If a request is to fix a bug in a stable pipeline:
- If the bug is in the HARNESS (parser fails on valid input,
  postprocess silently accepts invalid output): ADR + fix.
- If the bug is in the LIVE CONTENT (`hud.json` / `screens.json`
  per-game UX issues — #102–#106 in task_plan): edit the JSON
  directly. NOT a harness change.

The boundary between "harness" and "content":
- Harness = code under `tools/visual_layout/`, skill files,
  schema validators
- Content = `data/<game>/hud.json`, `data/<game>/screens.json`,
  Gemini prompts for per-game decoration

Content can evolve freely. Harness is locked.

## ACTIVE — under development, no stability lock

These pipelines are structurally harder (3D output, multi-consumer,
composition concerns) and still settling. Modify freely with the
usual discipline (post-mortem ritual, validators, scenario tests).

- **Map / world pipeline** — `compose_map.py`,
  `wireframe_to_map.py`, `/yume-map-author`.

### Why this is harder than 2D

- 2D input (semantic map PNG) → 3D output (world coords, scene)
- Multi-consumer: same map drives entity placement + ground shader
  biomes (ADR 0055) + (TBD) lighting/fog + (TBD) audio zones
- 10 composition axes from `soul.md` only apply to spatial worlds
- Camera + cinematic framing are part of the output, not just
  a viewport projection

### Where map/world work belongs

New work goes in `tools/visual_layout/compose_map.py` +
`wireframe_to_map.py` + `/yume-map-author` skill, or in NEW
sibling stages alongside (e.g. a future `compose_scene_cinema`
for lighting/fog/camera generation from the same semantic map).

Do NOT touch the HUD/screen surface while working on map/world.
If a generalization seems to require touching all three, that's
the signal to author an ADR scoping the change to the harness
contract first.

## Empirical case (2026-05-24)

User explicitly requested stability lock on 2D pipelines before
beginning 3D map/world work: "lets make sure the hud and screen
are confirmed category first so we make sure we dont touch them
accidentally, map is the thing we want to focus now."

The 2D pipelines had reached a settled state after
- 2026-05-19: compose_hud rewired to LLM-as-parser
- 2026-05-20: Tier 2.7v three-sibling release
- 2026-05-21: scenario regression tests added
- 2026-05-23: visual-designer pass + 4 new screen presets

Locking them prevents accidental drift while map/world iterates.

## What this rule is NOT

- Not a freeze on the live `hud.json` / `screens.json` per-game
  content. Game authors keep editing those.
- Not a freeze on adding new screen presets to `compose_screen.py`
  PRESETS dict. Adding a preset is content authoring, not a
  harness change. The preset dict's SHAPE is locked; the entries
  are open.
- Not a freeze on bug fixes to the harness — but every bug fix
  goes through the post-mortem ritual + lands with an ADR if it
  changes the workflow contract.
