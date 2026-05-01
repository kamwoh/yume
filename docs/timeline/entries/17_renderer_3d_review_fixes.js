export const entry17 = {
  id: "17",
  date: "2026-05-01",
  type: "review",
  title: "W5.0 review caught three load-bearing holes — corrections applied",
  summary:
    "After promoting renderer_3d to W5.0, ran a clean reviewer over the revision. Found " +
    "three significant holes plus several smaller ones. The biggest catch: <em>invariant #8 " +
    "was never tested in W1.</em> Adding entity_3d.gd as a Node3D variant of Entity " +
    "violates invariant #3 (no entity-class hierarchy) — a real architectural debt incurred " +
    "at W1 that I was about to carry as hidden cost into W5.0. Pay it now in W1.14, ~3 days.",
  highlights: [
    "<strong>Hit #1 — timing was optimistic.</strong> +2 weeks was wrong; honest is +2-4 weeks. Plan now says \"~3-4 weeks\" consistently. Tier 2.5 timing slips by the same delta — flagged explicitly so we're not surprised.",
    "<strong>Hit #2 — coordinate ambiguity in W5.0e hot-swap.</strong> Ecology rules use radius-1.5 in 2D top-down; in 3D with terrain altitude differences, what does 1.5 mean? Resolved: <strong>sim-space coords are XZ-planar.</strong> 2D Vector2(x,y) maps to 3D Vector3(x,0,y). Y is decorative (terrain height). Demos with Y-axis distances are explicitly 3D-only. Documented.",
    "<strong>Hit #3 — invariant #8 was untested in W1.</strong> Entity is Node2D today. The casual \"entity_3d.gd as Node3D variant\" violates invariant #3. Real fix: <strong>W1.14 — Entity refactor</strong>. Entity becomes <code>extends Node</code>; position lives in <code>state.position</code> as Vector2 or Vector3 (pure data); renderer attaches a positioned child node and syncs each frame. One Entity class. Reviewer was right: pay the architectural debt where it was incurred (W1), not at acid-test time.",
    "<strong>W5.0e renamed and clarified</strong> — explicitly the renderer-agnosticism test. Run proof-of-life under both 2D + 3D scene; same JSON; assert state ticks identically (modulo visuals).",
    "<strong>W5.0f added</strong> — explicit tests for renderer_3d (mesh composer unit, composite render integration, parity assertion, input system smoke).",
    "<strong>Path naming fixed:</strong> renderer_2d/ and renderer_3d/ are siblings of <code>scripts/engine/</code>, not under it. The renderer is not engine — it reads engine data and projects it to a view.",
    "<strong>Motivation reframed:</strong> the acid test makes <em>two independent</em> claims (rule-genre-agnostic + renderer-agnostic). They're tested separately. Conflating them was a draft mistake.",
    "<strong>Reimplementation, not harvest.</strong> Dropped \"harvest patterns from Yume3D\" framing. Yume3D's terrain/camera/model_helpers are tangled with brain/agent code; clean reimplementation guided by their structure ≈ 1 week of W5.0d, not free.",
    "<strong>Yume3D reference termination:</strong> the \"Yume3D as interim 3D reference\" note now has an explicit termination condition — drop it the moment W5.0c lands. Two reference points = drift.",
    "<strong>Why the reviewer matters:</strong> I had defended \"+2 weeks\" and \"harvest patterns\" with confidence. Both were wrong. Independent critique catches what proximity to the work obscures.",
  ],
  files: [
    "task_plan.md (W1.14 added; W5.0/W5 rewritten with honest timing, coordinate convention, parity tests, paths, framing)",
  ],
  followups: [
    "W1.14 is the next concrete work — pay the Entity refactor before W2",
    "After W5.0c lands, drop Yume3D reference note from plan",
  ],
};
