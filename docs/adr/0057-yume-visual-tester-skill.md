# ADR 0057 — yume-visual-tester skill (auto-generated visual test plans)

_Date: 2026-05-22_
_Status: proposed_

## Context

ADR 0056 lands Phase A of test-driven visual QA: an assertion
library + a runner that executes hand-authored test plans. That's
sufficient to prove the assertion shape works on a single game.

It doesn't scale. Authoring `visual_test_plan.json` for every
game, every level, every iteration of /yume-design is busywork the
operator (or Claude) shouldn't be doing by hand. The plans are
mostly derivable from the world's own data:

- Trees should be taller than humans → walk entities for tree-tagged
  + character-tagged → emit a `relative_size` test per pair
- Animated rigged characters should have foot-pivot → walk entities
  for `physics.body_type=character` + .glb model → emit a
  `pivot_at_foot` test per
- Structures should not clip ground → walk for `world_prop` +
  `blocks_motion` → emit `no_clipping` per
- Recently-added entities (since last visual QA pass) should have
  every relevant assertion run on them

A small set of priors + the current scene's contents = a test plan
of 8-15 concrete tests. Generating it should be cheap.

## Decision

Add `yume-visual-tester` — a tier-2.6 in-context skill that reads:

- The game's GDD (aesthetic targets, signature beats)
- The current level's `entities.json` + def files
- The session's `git diff` (what changed since last visual QA pass)
- The visual assertion library (`data/lib/visual_qa/assertions/`)

and emits a `visual_test_plan.json` ready for the runner from ADR
0056.

### Generation strategy

The skill loads the assertion library schema, walks the entities,
and applies priors:

| Prior | Test emitted |
|---|---|
| trees / structures / props are typically taller/bigger than characters | `relative_size` per (tree_tagged, character_tagged) pair |
| characters with animated rigs (`physics.body_type=character`, `.glb` mesh) have foot-pivot | `pivot_at_foot` per animated character |
| `world_prop` + `blocks_motion` entities rest on ground | `no_floating` per |
| named NPCs in Fellowship games must be visually distinct | `distinct_silhouettes` per (named_npc pair) |
| logical/singleton entities (`tags: world_clock`, `free_camera`, zone_marker, etc.) should be invisible | `no_orphan_cubes` global sanity sweep |
| water biome present in semantic map | `specular_response` for water |
| schedule-driven NPCs face their schedule target during their slot | `rotation_facing` per |

Priors are stored in `data/lib/visual_qa/priors.json` — extensible.

### Recent-changes filter

If `git diff HEAD~N` shows changes to a subset of entities, prefer
tests targeting those entities. The plan's first N tests are the
"high signal" ones (entities that changed); the rest are the
recurring sanity battery.

### Output shape

Same `visual_test_plan.json` format from ADR 0056. The runner
doesn't know or care whether the plan was hand-authored or
generated.

## Consequences

**Positive**:
- Visual QA scales — every /yume-design iteration generates its
  own plan, no per-game authoring.
- Targeted tests on changed entities catch regressions exactly
  where they're likely.
- The priors library compounds: every new pattern recognized once
  by the LLM gets codified into a prior, so the next session
  doesn't re-derive it.

**Negative**:
- LLM cost per generation. Mitigation: cache by (game, level,
  diff_hash). Same inputs → reuse the prior plan.
- Plans can drift if priors are sloppy. Mitigation: priors land
  with concrete trigger conditions; the skill doesn't free-form
  invent tests.

**Neutral**:
- No new engine work. The runner from ADR 0056 is unchanged.
- New skill follows the existing tier-2.6 in-context-load pattern.

## Phasing (deferred until ADR 0056 ships)

- **Phase B1**: priors library (`data/lib/visual_qa/priors.json`)
  + skill draft. Acceptance: running on aldenmere produces a plan
  whose tests are sensible (no nonsense pairs, no irrelevant
  assertions).
- **Phase B2**: recent-changes filter via `git diff`. Acceptance:
  changing one entity's scale → next plan prioritizes
  `relative_size` tests involving that entity.
- **Phase B3** (= Phase C of the overall arc): wire into
  `/yume-design` iteration loop. Failing tests → targeted
  revision → re-run only failing tests, capped at 3 rounds.

## Alternatives considered

1. **Stay hand-authored** (ship ADR 0056 only). Works for a few
   demos. Doesn't scale.
2. **Static rule-based generator** (Python script, no LLM). Easier
   to debug but rigid — adding a new prior requires a code change.
   LLM-driven adapts to entity vocabularies as the framework grows.
3. **Wire generation into yume-game-reviewer**. The reviewer is
   already context-heavy; mixing concerns. New skill keeps the
   responsibilities clean.

## Status note

This ADR is proposed but **not yet implemented**. Land ADR 0056
first, validate the assertion library catches real bug classes on
aldenmere, then revisit this ADR's design — the schema may shift
once Phase A reveals what assertions actually need.
