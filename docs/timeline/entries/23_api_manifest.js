export const entry23 = {
  id: "23",
  date: "2026-05-01",
  type: "build",
  title: "Tier 2.6c — auto-generated API manifest",
  summary:
    "Replaced hand-edited engine-vocabulary lists in agent prompts with an auto-generated " +
    "manifest derived from GDScript source. <code>tools/gen_api_manifest.py</code> regex-scrapes " +
    "<code>Rule.VALID_TRIGGERS</code>, <code>EffectApply.apply</code> match arms, query operators, " +
    "and <code>engine_error.gd</code> constants. Adding a primitive now updates agent docs " +
    "automatically. Tool discoverability: C- → B.",
  highlights: [
    "<strong>Generator</strong>: <code>tools/gen_api_manifest.py</code> (Python, no Godot dep). Sanity check fails loudly if expected vocabulary is missing — catches source-format drift before agents read a half-empty manifest.",
    "<strong>Outputs</strong>: <code>docs/engine-reference/api-manifest.json</code> (machine-readable, agent input) + <code>api-manifest.md</code> (human companion, auto-rendered).",
    "<strong>What's in the manifest</strong>: 7 primitives, 2 deferred, 8 triggers, 14 effect types, 9 query clauses, 8 operator suffixes, 6 formula entity roles, 14 math helpers, 26 error codes, 3 reserved state fields, 8 invariants count.",
    "<strong>Agent integration</strong>: pointers added to <code>content-designer.md</code> (schema validation table), <code>systems-designer.md</code> (effect-list reference), <code>tech-director.md</code> (invariant #2 enforcement). Agents now read the manifest, not the prompt's frozen text.",
    "<strong>Why Python over Godot introspection</strong>: runs anywhere (CI, agent invocation), no Godot install needed. The grep patterns are stable; engine source format is consistent. Fallback option (Godot-side live introspection) reserved for if regex becomes brittle.",
    "<strong>Compounds with 2.6a</strong>: the 26 structured error codes from 2.6a are now in the manifest under <code>error_codes</code>, indexed by both stable string (<code>rule.duplicate_id</code>) and Godot constant (<code>RULE_DUPLICATE_ID</code>). LLM agents matching on error codes get the canonical list.",
    "<strong>Honest grade movement</strong>: tool discoverability C- → B. Was: hand-edited agent prompts that drift from engine source. Now: source-of-truth pipeline. Still B not A because manifest doesn't include effect-parameter schemas yet (just type names). That's a future enhancement, not blocker.",
  ],
  files: [
    "tools/gen_api_manifest.py (new — Python regex generator)",
    "docs/engine-reference/api-manifest.json (new — auto-generated)",
    "docs/engine-reference/api-manifest.md (new — auto-generated)",
    ".claude/agents/yume/{content-designer,systems-designer,tech-director}.md (manifest pointers)",
    "task_plan.md (2.6c marked done)",
  ],
  followups: [
    "Effect parameter schemas — manifest currently has type names only; could parse static func _state_set(e, env, ctx) signatures for params",
    "CI hook: regenerate manifest on engine source changes, fail PR if not committed",
    "2.6d: persistent workflow state (production/session-state/)",
    "2.6b: programmatic test runner — now unblocked since the manifest gives the diff target a vocabulary",
  ],
};
