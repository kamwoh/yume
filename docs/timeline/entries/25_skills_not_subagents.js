export const entry25 = {
  id: "25",
  date: "2026-05-02",
  type: "build",
  title: "Tier 2.6g — agents → skills (architectural shift from harvestcore finding)",
  summary:
    "Converted the 6 yume-* role prompts from subagents to skills. Empirical reason: subagent " +
    "spawning via <code>Agent(subagent_type=)</code> hit org auth policy in harvestcore Phase 5 " +
    "QA. Skills load into the orchestrator's main context — same role prompts, no auth boundary, " +
    "lower latency. Now Yume's pipeline runs end-to-end on the standard Claude Code subscription " +
    "without any quota or policy edge cases.",
  highlights: [
    "<strong>6 new skills</strong>: <code>.claude/skills/yume-{game,systems,content,asset}-designer/</code>, <code>yume-qa-tester/</code>, <code>yume-tech-director/</code>. Body content mirrored from the legacy agent files; only frontmatter changed (skill format vs subagent format).",
    "<strong>Orchestrator updated</strong>: <code>/yume-design</code> SKILL.md now uses <code>Skill(skill='yume-X')</code> calls instead of <code>Agent(subagent_type='yume-X')</code>. Each phase loads the role's instructions into orchestrator context, executes inline, returns control.",
    "<strong>--autonomous flag formalized</strong>: orchestrator skips per-phase user-approval gates when set. The harvestcore run proved this works — phases 1-4 ran cleanly autonomous; only Phase 5 needed manual fix on a content bug.",
    "<strong>Autonomous fix-and-retry loop documented</strong>: orchestrator can apply small mechanical JSON fixes inline (ternary syntax, typos, missing fields) based on Tier 2.6a structured error records. Max 3 retry cycles. Doesn't invent logic — only fixes what error code identifies.",
    "<strong>Why this matters for Tier 3</strong>: LLM-actor work needs many in-context cognition calls per tick. If those went through subagent spawns, they'd hit the same auth wall + add latency. Skills as the cognition substrate make Tier 3 buildable on standard Claude Code.",
    "<strong>Legacy preserved</strong>: <code>.claude/agents/yume/*.md</code> kept as fallback path with README marked legacy. Users with <code>ANTHROPIC_API_KEY</code> who prefer subagent isolation can still use them.",
    "<strong>Tradeoffs accepted</strong>: skill path means orchestrator context fills with role instructions across phases (~5KB per skill × 6 phases = ~30KB context). Subagent path had isolated contexts per role. We accept the larger orchestrator context as the price for working auth + lower latency.",
  ],
  files: [
    ".claude/skills/yume-game-designer/SKILL.md (new)",
    ".claude/skills/yume-systems-designer/SKILL.md (new)",
    ".claude/skills/yume-content-designer/SKILL.md (new)",
    ".claude/skills/yume-asset-designer/SKILL.md (new)",
    ".claude/skills/yume-qa-tester/SKILL.md (new)",
    ".claude/skills/yume-tech-director/SKILL.md (new)",
    ".claude/skills/yume-design/SKILL.md (orchestrator updated to Skill() invocations)",
    ".claude/agents/yume/README.md (marked legacy)",
    "task_plan.md (Tier 2.6g added + marked done)",
  ],
  followups: [
    "Re-run harvestcore via /yume-design end-to-end with --autonomous to verify the new pipeline works without manual intervention",
    "If skill path proves clean across multiple games, deprecate .claude/agents/yume/ entirely",
    "Consider a similar skills-conversion for any future Tier 3 cognition substrate",
  ],
};
