# HarvestCore

A Stardew/Harvest Moon-style core simulation game built end-to-end with
Yume's `/yume-design` pipeline as the first empirical test of flow B.

## Files

- [GDD](./GDD.md) — game design document (game-designer agent output)
- [rules-sketch.md](./rules-sketch.md) — primitive-vocabulary rule sketches (systems-designer)
- [qa-report.md](./qa-report.md) — empirical QA verdict + harness gaps discovered
- `../../godot/data/demo_harvestcore/` — JSON content
- `../../godot/scenes/harvestcore_2d.tscn` — Godot scene

## Run it

```bash
godot --path godot scenes/harvestcore_2d.tscn
```

## Pipeline summary

| Phase | Agent / Role | Output |
|---|---|---|
| 0 | orchestrator | name + paths + plan |
| 1 | yume-game-designer | GDD with MDA decomposition, 8 open questions |
| 2 | yume-systems-designer | 26 rule sketches, no ADRs needed |
| 3 | yume-content-designer | 27 defs, 81 instances, 50 rules |
| 4 | yume-asset-designer | 27 visual fields, 22 shapes, code-draw |
| 5 | (in-context) qa-tester | structural pass + 1 cascade observed + 3 harness gaps |

## Stats

- 27 entity defs / 81 instances / 50 rules / 22 shapes / 4 relations
- Rule kinds: 5 clock, 7 crop, 5 movement, 4 contact-tool, 5 harvest,
  5 plant, 5 animal, 7 NPC, 4 player-interaction, 2 deposit, 6 misc
- Effect types used: state_set, state_add, state_clamp, transform,
  spawn, remove, relate, unrelate, tag_add, tag_remove, velocity_set, emit
- Triggers used: tick, contact, signal, input, relation_changed

## Empirical findings → harness improvements shipped

1. **C-style ternary doesn't work in Godot 4.6.1 Expression** — only
   Python-style `a if cond else b` parses. Fixed in
   `formula.gd` hint, `data-demo.md`, `30_framework_primitives.md`,
   `tools/gen_api_manifest.py`.
2. **Subagent path blocked by org auth policy** — Phase 5 qa-tester
   subagent failed after 83 minutes. Workaround: run qa role in main
   context. Architectural follow-up: convert `.claude/agents/yume/*.md`
   to skills.
3. **Probe-tag invisibility for transforms** — `world.gd._print_tick_summary`
   uses a hardcoded probe-tag list; new game tags aren't visible. Future
   fix: auto-derive from initial-instance tag set.

## Known limitations of this build

- Multi-cascade composition (crop seed → young → mature → harvest → gold)
  not visually traced yet — would need ≥200 ticks at `ticks_per_day=20`
  + augmented probe tags.
- NPC schedule cycling not visually verified — formulas now parse but
  movement counts not extracted.
- Storm damage rule never exercised in test (initial weather=sunny).
- Player input rules (hoe, water, scythe, plant, deposit, feed) not
  exercised in headless mode — would need an input-injection harness.
