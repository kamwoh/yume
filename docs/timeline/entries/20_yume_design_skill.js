export const entry20 = {
  id: "20",
  date: "2026-05-01",
  type: "build",
  title: "Tier 2.5g + 2.5h — `/yume-design` skill + behavioral test spec",
  summary:
    "Wrote the orchestrator skill that chains the 6 specialist agents and the behavioral " +
    "test spec for it. <code>/yume-design</code> takes a prose game description, walks the " +
    "user through 7 phases (setup → GDD → sketches → content → assets → QA → wrap), " +
    "delegating to the right agent at each stage with user-approval gates between. Test " +
    "spec documents 5 fixture cases including out-of-scope rejection and invariant violations.",
  highlights: [
    "<strong>2.5g — `/yume-design` skill</strong> at <code>.claude/skills/yume-design/SKILL.md</code>. The orchestrator. 7-phase walkthrough; each phase delegates to a specific yume-* agent via the Agent tool. User approval at each phase boundary.",
    "<strong>Failure modes documented</strong>: user rejection at any gate (re-invoke that stage), missing primitive (escalate to tech-director), schema validation errors (hand back to content-designer), cascade failures (loop to systems or content), engine errors during qa (surface to user).",
    "<strong>Out-of-scope handling</strong>: skill reads docs/30 non-goals at Phase 0, refuses prompts that ask for rhythm/precision-platform/soft-body/narrative-heavy games. Surfaces with concrete redirect rather than spending agent calls on doomed pipelines.",
    "<strong>Invariant enforcement integrated</strong>: if user prose asks for forbidden semantic effects (`damage`, `gain_xp`), systems-designer + tech-director cooperate to reject — explained via ADR 0001 + invariant #2.",
    "<strong>2.5h — behavioral test spec</strong> at <code>.claude/skills/yume-design/tests/spec.md</code>. 5 test cases:",
    "<strong>TC-01</strong>: simple farming sim — happy path through all 6 stages. File paths, schema validity, cascade verification.",
    "<strong>TC-02</strong>: rhythm game prompt → rejected at Phase 0 with concrete redirect. No agent calls spent.",
    "<strong>TC-03</strong>: extension to existing demo (demo_ecology + thunderstorm) → modifies in place, no regression of existing cascades.",
    "<strong>TC-04</strong>: ambiguous prose ('a fantasy game') → game-designer outputs clarification questions only, doesn't proceed.",
    "<strong>TC-05</strong>: invariant-violation prompt ('add `damage` effect type') → tech-director rejects with contract citation.",
    "<strong>Manual execution today</strong>; automation deferred. The spec IS the contract for what 'good' looks like — useful for review even before any test runner exists.",
  ],
  files: [
    ".claude/skills/yume-design/SKILL.md",
    ".claude/skills/yume-design/tests/spec.md",
    "task_plan.md (2.5g + 2.5h marked done)",
  ],
  followups: [
    "Try the skill with a real prompt — the proof is invocation",
    "2.5i-l asset generation pipeline (config-driven, plugin-style backends)",
    "Test runner automation (programmatic skill invocation + diff against expected)",
  ],
};
