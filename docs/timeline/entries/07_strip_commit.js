export const entry07 = {
  id: "07",
  date: "2026-04-22",
  type: "commit",
  title: "Strip + commit — old engine cleared, contract written",
  summary:
    "Spike validated the primitive set; W1.2 strip removed the old agent-flavored engine. " +
    "27 files deleted via <code>git rm</code> (git history preserves them). The new contract " +
    "doc + W0 findings + clean tree committed as one cohesive checkpoint.",
  highlights: [
    "Deleted: 5 brain scripts, 4 UI scripts, world_rules_engine.gd, entire <code>renderer_3d/</code> folder (brain-dependent)",
    "Kept: <code>sim_pos.gd</code>, <code>world_clock.gd</code>, <code>pathfinding_astar.gd</code>, <code>minimap.gd</code> — engine-relevant utilities",
    "Spike code itself: deleted (per throwaway agreement) — learning lives in the contract doc",
  ],
  commit: "3cb878b",
  files: ["docs/30_framework_primitives.md", "task_plan.md"],
  followups: ["Begin W1 production engine"],
};
