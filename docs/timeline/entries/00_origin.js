export const entry00 = {
  id: "00",
  date: "2026-04-22",
  type: "decision",
  title: "Starting point — Tier 1 self-sustaining sim, no driver",
  summary:
    "Read task_plan.md. Yume's 3D agent-farming sim runs continuously: 5 brains, " +
    "farming loop closes (90s soak, 0 deaths), population respawns. Foundation ~80% " +
    "but the world has no <em>arc</em> — homeostasis without stakes.",
  highlights: [
    "Existing primitives: composites, terrain ground sampling, target-claim system, ATB battle",
    "Open question: what's the <em>driver</em> — the reason the world has narrative arc?",
    "Leading candidate at this point: <em>survive-the-night</em> — cold damages exposed agents",
    "2D pivot landed earlier (commit <code>63c59c7</code>) — Vector2 contract, dimension-agnostic refactor",
  ],
  followups: ["Reframe to genre-agnostic framework"],
};
