export const entry19 = {
  id: "19",
  date: "2026-05-01",
  type: "build",
  title: "Tier 2.5f — six specialist agents written",
  summary:
    "Wrote the 6 specialist agents that compose the text-to-game pipeline: game-designer, " +
    "systems-designer, content-designer, asset-designer, qa-tester, tech-director. " +
    "Each is a Claude Code subagent under <code>.claude/agents/yume/</code> with role, " +
    "inputs, outputs, references, and explicit DO/DON'T lists.",
  highlights: [
    "<strong>game-designer</strong>: prose → GDD via MDA decomposition. Output is structured Markdown with aesthetics target (LeBlanc's 8), dynamics intent, mechanics sketch, honest scope (Yume non-goals), open questions.",
    "<strong>systems-designer</strong>: GDD → rule sketches in pseudo-JSON. Mandatory primitive sufficiency check — if existing 7 don't suffice, propose ADR before sketching anything else. References primitive contract.",
    "<strong>content-designer</strong>: sketches → actual <code>entities.json</code> + <code>world_rules.json</code>. Picks specific tag names, balance values, positions. Reads <code>.claude/rules/data-demo.md</code> for schema discipline. Has balance priors (tick interval ranges, contact radius ranges, chance ranges).",
    "<strong>asset-designer</strong>: GDD aesthetics → entity.visual.* fields. Picks ONE strategy per project (library lookup / AI-gen / code-draw) for style consistency. Uses $param overrides for cheap variation.",
    "<strong>qa-tester</strong>: empirical verification. Loads JSON in Godot headless, runs N ticks, reads <code>verbose</code> tick output, checks cascades against GDD intent. Includes diagnosis patterns for common bugs (no rule firing, runaway feedback, dead rules, etc.).",
    "<strong>tech-director</strong>: cross-cutting guardian. Runs invariant grep checks, runs full test suite + 5 acid-test demos as regression sweep, gates engine changes. Mandatory ADR for primitive additions. Explicit authority: invariants are not negotiable mid-merge.",
    "<strong>Pipeline structure</strong>: prose → game-designer → systems-designer → content-designer → asset-designer → qa-tester. tech-director is cross-cutting (any engine change passes through). Collaboration protocol (Q → Options → Decision → Draft → Approval) applies at each handoff.",
    "<strong>Each agent</strong> has tool whitelist (typically Read/Write/Edit/Glob/Grep + Bash for qa-tester and tech-director), references its read-first docs, and links to existing demos as pattern library.",
  ],
  files: [
    ".claude/agents/yume/{README, game-designer, systems-designer, content-designer, asset-designer, qa-tester, tech-director}.md",
    "task_plan.md (2.5f marked done)",
  ],
  followups: [
    "2.5g — /yume-design skill that orchestrates the agents in sequence",
    "2.5h — skill behavioral tests (prompt X → expected output Y)",
    "Optional: agent integration test (programmatic invoke of game-designer with a fixture prompt)",
  ],
};
