export const entry22 = {
  id: "22",
  date: "2026-05-01",
  type: "build",
  title: "Tier 2.6a — structured engine errors landed",
  summary:
    "First Tier 2.6 deliverable. Replaced 17 ad-hoc <code>push_error(\"...\")</code> calls with " +
    "structured records <code>{code, what, where, hint, severity}</code> that accumulate in " +
    "<code>env.error_buffer</code>. LLM agents and qa-tester now read engine failures " +
    "programmatically instead of parsing console strings. Error→retry signal: D → B-.",
  highlights: [
    "<strong>New module</strong>: <code>scripts/engine/engine_error.gd</code> with <code>make()</code> / <code>report()</code> / <code>raise()</code> / <code>drain()</code> helpers and 27 stable error code constants (<code>rule.duplicate_id</code>, <code>effect.unknown_type</code>, <code>formula.parse_failed</code>, ...). Codes are documented as load-bearing — renames need an ADR.",
    "<strong>Record shape</strong>: <code>{code, what, where, hint, severity}</code>. <code>code</code> is a stable enum string for matching in retry loops; <code>what</code> is human-readable; <code>where</code> is structured (file/rule_id/field); <code>hint</code> is the suggested fix written for an LLM reader; <code>severity</code> is error/warning. Plain Dictionaries — JSON-serializable end-to-end.",
    "<strong>Rule attribution flows automatically</strong>: <code>phase_scheduler._enqueue</code> stamps <code>_rule_id</code> into context. <code>EffectApply</code>, <code>Formula</code>, and any downstream module read it from context — so an unknown-effect-type error knows which rule queued it.",
    "<strong>Backward compatible</strong>: <code>EngineError.report()</code> still calls <code>push_error</code> / <code>push_warning</code> so the Godot dev console keeps working. Records are <em>added</em>, not <em>replaced</em>.",
    "<strong>17 sites migrated</strong>: <code>rule.gd</code> (3 load + 6 validate), <code>effect_apply.gd</code> (4: unknown type, spawn no-def, transform no-def, emit no-buffer), <code>formula.gd</code> (2: parse + exec), <code>world.gd</code> (3: rules forward, entities load, unknown def), <code>shape_lib.gd</code> + <code>mesh_lib.gd</code> (2 each), <code>phase_scheduler.gd</code> (1: topo cycle).",
    "<strong>Contract change</strong>: <code>Rule.validate_all</code> now returns <code>Array[Dictionary]</code> (was <code>Array[String]</code>). Existing in-tree callers only checked <code>.size()</code> so no breakage; future readers get structured records.",
    "<strong>Tests: 169 → 188</strong>. New <code>test_engine_error</code> section verifies record shape, buffer accumulation, drain, and integration cases (unknown effect type → buffer record with rule_id; broken formula → parse_failed record with rule_id).",
    "<strong>Honest grade movement</strong>: error→retry signal D → B-. Was: stack traces requiring human interpretation. Now: machine-readable codes the LLM can match against (<code>if record.code == 'effect.unknown_type'</code>) and react to.",
  ],
  files: [
    "archetypes/core/templates/godot/scripts/engine/engine_error.gd (new)",
    "archetypes/core/templates/godot/scripts/engine/{rule,effect_apply,formula,world,shape_lib,mesh_lib,phase_scheduler}.gd",
    "archetypes/core/templates/godot/scripts/engine/tests/test_runner.gd (+19 assertions)",
    "task_plan.md (2.6a marked done)",
  ],
  followups: [
    "2.6b: programmatic test runner for /yume-design — invoke skill with fixture prompt, diff output",
    "2.6c: tool registry auto-generation — derive from rule.gd / effect_apply.gd source, not hand-edited markdown",
    "Once 2.6c lands, the 27 error codes here can join the auto-generated reference",
  ],
};
