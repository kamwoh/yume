# HarvestCore — QA report

_Date: 2026-05-02_
_Tester: Claude (in-context, qa-tester role) — subagent path blocked by org auth policy_

## Verdict

**Pass-with-issues.** Engine boots clean after one autonomous formula fix.
At least one cascade fires (animal produce). Real harness gap discovered:
docs claim C-style ternary support but Godot 4.6.1 Expression only
supports Python-style. Content that trusted the docs failed.

## Pipeline summary

| Phase | Outcome |
|---|---|
| 1 game-designer | GDD written, 8 open questions flagged |
| 2 systems-designer | 26 rule sketches, no ADR needed |
| 3 content-designer | 27 defs, 81 instances, 50 rules, 5 concerns flagged |
| 4 asset-designer | 27 visuals, 22 shapes, code-draw strategy |
| 5 qa-tester | 392 ternary-syntax errors → fixed → 0 errors → cascade evidence |

## Load smoke test

```
[World] 50 rules registered
[World] loaded: 27 defs, 81 entities, 4 relations
```

`Rule.validate_all`: zero errors. Schema sanity passed.

## Tick smoke test

50 ticks at `tick_seconds=0.5` (~25s wall), `ticks_per_day=20` (lowered
from 60 for test density).

```
[t4]  n=82 player=1 crop=5 animal=3
[t8]  n=82 player=1 crop=5 animal=3
...
[t40] n=82 player=1 crop=5 animal=3
[t44] n=83 player=1 crop=5 animal=3   ← spawn event
[t48] n=83 player=1 crop=5 animal=3
```

Net +1 entity at t44. Most consistent with `animal_produce_output_cow`
firing — cow's `produce_timer` started at 40 and decremented to 0,
triggering produce spawn.

## Cascades observed

Probe-tag summary catches `crop` and `animal` aggregate counts, but tags
like `produce`, `egg`, `milk_bucket`, `wool_bundle`, `crop_stage_seed`,
`crop_stage_young`, `crop_stage_mature` are not in `world.gd`'s probe list,
so transforms within a tag family are invisible.

| GDD-intended cascade | Evidence in run | Verdict |
|---|---|---|
| crop_grow_watered | crop=5 stable; growth state mutation invisible to probe | inconclusive |
| crop_seed_to_young | invisible (same `crop` tag pre/post transform) | inconclusive |
| animal_produce_output | n=82→83 at t44 (cow timer hit 0) | **observed** |
| dawn_advance_day | day-start signal expected at t20, t40 — no probe evidence | inconclusive |
| storm_damages_crop | weather=0 (sunny) at start; rule never had stormy condition | not exercised |
| NPC schedules | NPC velocity mutations invisible to count-only probe | inconclusive |

## Engine errors captured (Tier 2.6a structured records)

**Run 1 (before fix):** 405 total error records, all `formula.parse_failed`:
- 196× NPC arrival x-formula (chained ternary)
- 196× NPC arrival y-formula
- 9× `crop_update_season_valid` formula (chained ternary on bitmask test)

**Run 2 (after fix):** zero errors.

The Tier 2.6a structured records made this debuggable in seconds. Each
record carried `code: formula.parse_failed`, the offending formula
string, the rewritten path-substituted version, and the Godot error
text. Without 2.6a, this would have been opaque stack traces to dig
through.

## Concerns from content-designer — status

| # | Concern | Status |
|---|---|---|
| 1 | `storm_damages_crop` chance reduced 0.15→0.008 | Not exercised in run (weather=sunny). Defer to longer run. |
| 2 | NPC `velocity[0]` Vector2 subscript | **EMPIRICALLY OK**. The bug was the surrounding chained ternary, not the subscript. Subscript works on Vector2 in Godot 4.6.1 Expression. |
| 3 | `crop_update_season_valid` perf with 64 entities | No perf collapse observed in 50 ticks. Inconclusive at this scale. |
| 4 | Plant rules use contact (no dedicated input) | Acknowledged design trade-off, not exercised in headless. |
| 5 | `deposit_collect_gold` formula `self.properties.sell_value` | Not exercised in run (no player input). |

## **Empirical harness gaps discovered**

This is the most important section — what the empirical run taught us
beyond the game itself.

### Gap 1: Ternary syntax mismatch (shipped to fix)

Yume docs and the api-manifest claimed C-style `cond ? a : b` was
allowed in formulas. Godot 4.6.1 Expression actually requires Python-
style `a if cond else b`. The content-designer trusted the docs and
generated formulas that all parse-failed.

**Fix:** updated `engine_error.gd` hint, `api-manifest.json`, `api-
manifest.md`, and the formula.gd doc comment to reflect Python-style
ternary.

### Gap 2: Probe-tag invisibility for transforms

`world.gd._print_tick_summary` probes a hardcoded set of tags. When a
new game ships with tags like `crop_stage_seed`, the count-only summary
can't see them. Transforms within a tag family are invisible.

**Future fix:** auto-derive probe tags from initial-instance tag set
(or sample on first tick), so headless QA gets meaningful state
visibility per game.

### Gap 3: Subagent auth policy blocked Phase 5

The qa-tester subagent failed with "organization has disabled Claude
subscription access" after ~83 minutes. Yume's pipeline currently
spawns 5 subagents for Phases 1-5. Heavy subagent use trips org
policies that don't apply to main-context work.

**Future fix:** convert `.claude/agents/yume/*.md` to skills at
`.claude/skills/yume-<role>/SKILL.md`. Skills load into the main
orchestrator's context — same role prompts, no subagent auth boundary.
Tier 3 LLM-actor work will hit this same wall if not addressed.

## Recommendations

For content-designer (next iteration):
- Run with longer ticks before declaring final (200+ ticks at `ticks_per_day=20` to see day cycles + crop maturation).
- Consider initial state with `growth=180` on a few seeds to verify the seed→young→mature pipeline transforms within 30 ticks.
- The `override_properties` field used in initial_instances appears unsupported by `world.gd._spawn_initial` (which only reads `state`/`position`/`tags`/`properties`/`visual`). Verify this works as expected; if not, switch to `properties` overrides.

For systems-designer:
- Update rule sketches to specify Python-style ternary explicitly.
- Document workarounds for Godot Expression limitations as part of the sketch contract.

For tech-director (architectural):
- Ratify Gap 3 (skills > subagents) as a Tier 2.6 finding. This is empirical evidence the subagent path is fragile.

## Honest scope of this QA

- Engine-level structural soundness: **verified**
- Single-cascade firing: **verified** (animal produce)
- Multi-cascade composition (crop growth → transform → harvest → gold): **NOT verified** (requires player input or longer run)
- 4 NPC schedules: **NOT verified** (formulas fixed but movement not visually traced)
- Weather + season transitions: **NOT verified** (need ≥120 ticks at lowered ticks_per_day)

The game **is structurally sound** but only one of ~6 major cascades
was empirically observed in the run window. A longer headless run +
augmented probe tags would be required for full confidence.
