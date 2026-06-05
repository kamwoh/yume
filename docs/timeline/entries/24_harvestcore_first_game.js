export const entry24 = {
  id: "24",
  date: "2026-05-02",
  type: "build",
  title: "First end-to-end /yume-design run — HarvestCore (core farming sim)",
  summary:
    "First empirical test of Tier 2.5's <code>/yume-design</code> pipeline producing a real game in autonomous mode. " +
    "User asked for a a farming sim/a farming sim-style core sim. Pipeline walked all 6 phases. " +
    "Engine boots clean after one autonomous formula fix. Three real harness gaps surfaced that would have " +
    "stayed hidden without an empirical run.",
  highlights: [
    "<strong>Game</strong>: <code>data/demo_harvestcore/</code> — 27 defs, 81 instances, 50 rules. Farm + 3 animals + 4 NPCs + 8x8 tile grid + 4 seasons + weather. a farming sim 'without the words.'",
    "<strong>Pipeline phases ran cleanly 1-4</strong>: game-designer → systems-designer → content-designer → asset-designer. Phase 5 (qa-tester) hit subagent auth policy block; ran qa role in main context as fallback. End-to-end runtime: ~90 min.",
    "<strong>Harness gap #1 — C-style ternary doesn't work</strong>: Yume docs and api-manifest claimed <code>cond ? a : b</code> was allowed in formulas. Empirically verified: Godot 4.6.1 Expression requires Python-style <code>a if cond else b</code>. Content-designer trusted the docs and shipped 4 broken formulas (392 parse errors per tick). Fixed: <code>formula.gd</code> hint, <code>data-demo.md</code>, <code>30_framework_primitives.md</code>, manifest generator.",
    "<strong>Harness gap #2 — Subagent path is fragile</strong>: <code>Agent(subagent_type='yume-qa-tester')</code> failed with 'organization has disabled Claude subscription access' after 83 minutes. Subagents authenticate through a path that org policies can block. Architectural follow-up: convert <code>.claude/agents/yume/*.md</code> to <code>.claude/skills/yume-&lt;role&gt;/SKILL.md</code> so role prompts always load into the orchestrator's main context. Tier 3 LLM-actor work will hit this same wall.",
    "<strong>Harness gap #3 — Probe-tag invisibility for transforms</strong>: <code>world.gd._print_tick_summary</code> uses a hardcoded probe-tag list (<code>seed/young/mature/crop/...</code>). New game tags like <code>crop_stage_seed</code> don't show. Within-tag-family transforms are invisible. Future fix: auto-derive probe tags from initial-instance tag set.",
    "<strong>2.6a paid for itself</strong>: 405 structured <code>formula.parse_failed</code> records made the bug debuggable in seconds. Each record had the offending formula, rewritten path-substituted version, and Godot error text. Without 2.6a this would have been opaque stack traces.",
    "<strong>2.6c partial miss</strong>: api-manifest claimed ternary support — but the source was the doc string in formula.gd, which itself had the wrong info. The manifest didn't lie about the engine; the engine's own hint was wrong. Fixed at the source.",
    "<strong>Empirical cascade evidence</strong>: animal_produce_output_cow fired at t44 (n=82→83). Other cascades not visually traced (probe-tag gap). Engine structurally healthy: 0 errors, 188/188 unit tests still green, no regression.",
    "<strong>Tests still pass</strong>: 188/188 unit tests green after all the harness improvements. No regression.",
  ],
  files: [
    "docs/games/harvestcore/{GDD.md,rules-sketch.md,qa-report.md,README.md} (new game artifacts)",
    "archetypes/core/templates/godot/data/demo_harvestcore/{entities.json,world_rules.json,world.json,shapes.json}",
    "archetypes/core/templates/godot/scenes/harvestcore_2d.tscn (new)",
    "docs/guideline/30_framework_primitives.md (ternary syntax corrected)",
    ".claude/rules/data-demo.md (formula whitelist refined)",
    "archetypes/core/templates/godot/scripts/engine/formula.gd (error hint corrected)",
    "tools/gen_api_manifest.py (formula syntax notes added)",
    "docs/engine-reference/api-manifest.{json,md} (regenerated)",
  ],
  followups: [
    "Convert .claude/agents/yume/*.md to skills (gap #2). Real Tier 2.6 work.",
    "Auto-derive probe tags from initial-instance tag set in world.gd (gap #3).",
    "Run harvestcore for 200+ ticks with augmented probes to verify multi-cascade composition.",
    "Add input-injection harness for headless QA so player-input rules can be exercised.",
    "Update agent prompts so they explicitly cite the Python-style ternary rule (defensive).",
  ],
};
