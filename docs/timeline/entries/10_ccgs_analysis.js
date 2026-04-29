export const entry10 = {
  id: "10",
  date: "2026-04-23",
  type: "review",
  title: "CCGS side-quest → three-layer architecture",
  summary:
    "User flagged Claude-Code-Game-Studios (CCGS) as possibly \"better than Yume.\" " +
    "Honest answer: <strong>they solve different problems.</strong> CCGS is a Claude Code " +
    "agent-orchestration template (49 subagents, 72 skills, 0 runtime code). Yume is a " +
    "runtime engine. They're complementary.",
  highlights: [
    "User clarified north star: <em>\"text description → any simulation-shaped game.\"</em>",
    "This forced a three-layer reframe: <strong>Design</strong> (prose → GDD) → <strong>Spec</strong> (GDD → JSON, ADR-tracked) → <strong>Runtime</strong> (Yume today)",
    "CCGS infrastructure fills layers 1-2; Yume is layer 3",
    "<strong>Tier 2.5 Pipeline added</strong> to the roadmap — adopts CCGS patterns: path-scoped rules, ADR + TR-registry, MDA framework, slim 5-specialist agent set, <code>/yume-design</code> skill, behavioral skill tests",
    "<strong>NOT adopting:</strong> 49-agent hierarchy (Yume's 3-agent model matches its scope), 7-phase production workflow, sprint/milestone tracking",
    "Honest scope: <em>any simulation-shaped game</em> — not visual novels, rhythm, continuous physics",
  ],
  files: ["docs/31_text_to_game_pipeline.md"],
  followups: ["Cheap pulls (path rules + engine reference) can land alongside W2"],
};
