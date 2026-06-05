export const entry18 = {
  id: "18",
  date: "2026-05-01",
  type: "build",
  title: "Tier 2.5 begins — cheap pulls + ADR scaffolding + MDA framework",
  summary:
    "After Tier 2 runtime engine completed (W6 closed), pivoted into Tier 2.5 — the " +
    "text-to-game pipeline. Started with the cheap pulls (path-scoped rules, engine reference, " +
    "collaboration protocol) plus two foundational pipeline-core docs (ADR scaffolding, MDA " +
    "framework). Total: 9 new files, zero engine code changes.",
  highlights: [
    "<strong>2.5a — path-scoped rules</strong> (4 files): <code>.claude/rules/{engine-scripts, data-demo, docs, tests}.md</code>. Each scopes to a glob + lists DON'Ts and DOs. Encodes invariants like 'no semantic effect types in engine,' 'JSON formulas use only whitelisted bindings,' 'primitive changes require ADRs.'",
    "<strong>2.5b — engine reference</strong>: <code>docs/engine-reference/godot/{VERSION, current-best-practices, deprecated-apis}.md</code>. Pinned to Godot 4.6.1. Documents observed working idioms (class_name, Expression, RegEx, signal Callable). Lists Godot 3 → 4 trip-wires that LLMs reach for from training cutoffs (<code>Reference</code> → <code>RefCounted</code>, <code>connect-by-name</code> → typed Callable, <code>OS.get_ticks_msec</code> → <code>Time.*</code>).",
    "<strong>2.5c — collaboration protocol</strong> baked into project <code>CLAUDE.md</code>: Question → Options → Decision → Draft → Approval. Selectively applied (trivial edits skip 1-3; primitive changes / deletions require all 5).",
    "<strong>2.5d — ADR scaffolding</strong>: <code>docs/adr/</code> with format + when-to-write guide + 2 retroactive ADRs. ADR 0001 captures the seven-primitives + invariant #8 decision. ADR 0002 captures the W5.0-review-driven Entity-extends-Node refactor. TR-registry deferred until content scales demand it.",
    "<strong>2.5e — MDA framework</strong>: <code>docs/guideline/32_mda_for_yume.md</code>. Translates the classic Hunicke/LeBlanc/Zubek paper into Yume vocabulary. Mechanics = JSON. Dynamics = emergent cascades. Aesthetics = LeBlanc's 8 categories. Foundational doc for the design agent — gives it structured vocabulary to decompose prose game requests.",
    "<strong>What this unlocks</strong>: future agents (Claude included) editing under each glob now have explicit guardrails. Engine-code edits get the no-semantic-effects rule auto-attached. JSON edits get the formula whitelist + tag-convention rule. Doc edits get the ADR-gating rule. Together they're the structural enforcement layer that makes the universality invariant durable across many sessions.",
    "<strong>Doesn't change runtime.</strong> All 9 files are pipeline / process / docs. Engine still 2200 LOC, 13 modules, 169 tests passing. Tier 2.5 grows the framework's discipline layer; Tier 2 stays frozen.",
  ],
  files: [
    ".claude/rules/{README, engine-scripts, data-demo, docs, tests}.md",
    "docs/engine-reference/godot/{VERSION, current-best-practices, deprecated-apis}.md",
    "docs/guideline/32_mda_for_yume.md",
    "docs/adr/{README, 0001-seven-primitives, 0002-renderer-agnostic-entity}.md",
    "CLAUDE.md (collaboration protocol section added)",
    "task_plan.md (Tier 2.5 cheap pulls + 2.5d/e marked done)",
  ],
  followups: [
    "2.5f — slim specialist agents (game-designer, systems-designer, content-designer, qa-tester, tech-director, asset-designer)",
    "2.5g — /yume-design skill (the actual prose → game pipeline)",
    "2.5h — skill behavioral tests",
  ],
};
