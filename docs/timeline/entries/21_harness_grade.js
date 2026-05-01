export const entry21 = {
  id: "21",
  date: "2026-05-01",
  type: "review",
  title: "Honest harness-engineering evaluation → Tier 2.6 added",
  summary:
    "User asked: <em>what is Yume's harness-ness, and what's its harness engineering grade?</em> " +
    "Reframed: Yume is the substrate, not the harness — Claude Code is the harness, Yume is what " +
    "it operates on. Within that, Yume has harness-flavored properties; some are A-grade, some D. " +
    "Aggregate B-. Tier 2.6 added with 6 deliverables to close the gap before Tier 3.",
  highlights: [
    "<strong>Honest reframe</strong>: Yume isn't a harness, it's a target environment. The 6 specialist agents are prompt files, not runtime infrastructure. Claude Code provides the harness; Yume provides what gets harnessed.",
    "<strong>Property-by-property grade</strong>: small action space A-, structured observations A-, verifiable outcomes B+, persistent context C, error→retry signal D, tool discoverability C-, eval infrastructure C. Aggregate B-.",
    "<strong>Identified 6 specific gaps</strong>: (a) structured engine errors instead of stack traces, (b) programmatic test runner for skill behaviors, (c) auto-generated tool registry instead of hand-edited docs, (d) persistent workflow state across session boundaries, (e) VQA integration for visual feedback loop, (f) typed message contracts between agents.",
    "<strong>Decision (ADR 0003 proposed)</strong>: add Tier 2.6 between Tier 2.5 and Tier 3. ~2-3 weeks of work that doesn't ship new genres but unblocks autonomous LLM workflows. Tier 3 (LLM actors) becomes much more buildable after.",
    "<strong>Why tier between 2.5 and 3, not after 3</strong>: harness improvements compound. Building Tier 3 actors on top of broken closed-loop infrastructure means each agent reinvents the missing pieces ad-hoc. Investing in shared substrate first.",
    "<strong>Honest non-deliverables documented</strong>: cost/time metering deferred (nice-to-have), full retry orchestration partially covered by 2.6a+b but true LLM-driven retry is harder, replacement of Claude Code as harness explicitly out of scope.",
    "<strong>What didn't change</strong>: Tier 2 + Tier 2.5 stand as authored. ADR 0003 documents the recognition of the gap, doesn't invalidate prior work. Yume is still good as 'simulation engine for human/LLM-supervised authoring' (B+/A-). The B- grade only applies to 'closed-loop autonomous LLM substrate.'",
  ],
  files: [
    "docs/adr/0003-harness-engineering-tier-26.md",
    "docs/adr/README.md (index updated)",
    "task_plan.md (Tier 2.6 section added)",
  ],
  followups: [
    "Decide: land Tier 2.6 next, or pause + try /yume-design first to find more gaps empirically?",
    "Some 2.6 items might be low-hanging — e.g. 2.6a structured errors is mostly find-and-replace work",
    "VQA integration (2.6e) is independent of the rest — could land out of order",
  ],
};
