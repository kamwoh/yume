export const entry11 = {
  id: "11",
  date: "2026-04-28",
  type: "review",
  title: "Environment Maps paper → Plan + Knowledge as deferred primitives",
  summary:
    "User pointed at Feng et al. 2026, <em>\"Environment Maps: Structured Environmental " +
    "Representations for Long-Horizon Agents\"</em> (arxiv 2603.23610). Paper shows " +
    "structured agent representations beat raw-trace consumption (28.2% vs 14.2% baseline " +
    "on WebArena, vs 23.3% with raw trajectories).",
  highlights: [
    "Four components: <strong>Contexts</strong>, <strong>Actions</strong>, <strong>Workflows</strong>, <strong>Tacit Knowledge</strong>",
    "Mapping to Yume: Contexts → tag convention. Actions → indexed input-trigger view. Workflows → <em>missing primitive</em>. Tacit Knowledge → <em>missing primitive</em>.",
    "<strong>Two new primitives flagged as deferred</strong> (Tier 3): <em>Plan</em> (multi-step intentions: <code>{goal, abandon_if, steps[]}</code>) and <em>Knowledge</em> (declarative facts side-channel, engine ignores)",
    "Documented in contract — primitive design committed, build deferred to Tier 3 when actors need them",
    "Context + Affordance: not new primitives — helper APIs (<code>World.contexts_containing</code>, <code>World.affordances_for</code>)",
    "Total primitive count: 7 active + 2 deferred = 9",
  ],
  files: ["docs/30_framework_primitives.md (§Deferred primitives)"],
  followups: ["Tier 3 expanded with 3.4a/b/c for Plan, Knowledge, helpers"],
};
