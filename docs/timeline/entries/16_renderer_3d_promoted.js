export const entry16 = {
  id: "16",
  date: "2026-05-01",
  type: "decision",
  title: "Renderer_3d promoted from Tier 4.3 → W5.0 (acid-test prerequisite)",
  summary:
    "User ran the old Yume3D test instance and asked: <em>can the new plan ever produce that?</em> " +
    "Honest answer: yes, eventually — but originally scheduled at Tier 4.3, ~3-4 months away. " +
    "After review I revised: <strong>3D renderer belongs in W5</strong>, not Tier 4.3. The acid " +
    "test claims universality; if it only tests 2D, that claim is unverified.",
  highlights: [
    "<strong>Decision:</strong> renderer_3d moves from Tier 4.3 (deferred) → W5.0 (acid-test prerequisite). +~2 weeks to Tier 2; 3D back at end of Tier 2 instead of Tier 4. Saves ~6-8 weeks of \"colored circles only\" period.",
    "<strong>Reasoning:</strong> Invariant #8 says engine is renderer-agnostic. Testing this claim across only 2D demos is testing a weaker claim than the contract makes. Promoting 3D to W5 makes the acid test honest — universality across genres AND renderers.",
    "<strong>W5.0 scope:</strong> entity_3d.gd (Node3D), renderer_3d/ folder (mesh loader, primitive composer, camera/light/env), meshes.json equivalent of shapes.json, world_3d.tscn. Patterns harvested (not copied) from Yume3D's working code: model_helpers, terrain, camera_controller. None of the brain/agent code carries over.",
    "<strong>W5.0e hot-swap test:</strong> load the same ecology demo with world_3d.tscn instead of world_2d.tscn. If it doesn't run identically (modulo visuals), invariant #8 is broken — fix the engine, not the demo.",
    "<strong>W5.2 farming demo is the 3D one:</strong> visual continuity with Yume3D, terrain + named agents + composite buildings via part_of relations. The demo that says \"yes the new framework can do what Yume3D did, on clean primitives.\"",
    "<strong>Tier 4.3 reframed</strong> as 3D polish/expansion: animation state machines, LODs, biomes, particles, post-processing — engine extensions beyond primitives.",
    "<strong>Yume3D stays as the interim 3D reference</strong> — runs today at <code>/mnt/c/Users/kamwoh/Documents/Projects/Godot/Yume3D/</code>. Not merged back; explicitly preserved as a viewing target.",
    "<strong>Why I changed my mind:</strong> initially recommended \"stay course\" for plan-purity. User pushed back. On reconsideration, plan-purity weighs less than (a) honest acid test, (b) sustained motivation across long projects, and (c) catching 2D-implicit assumptions early instead of months late.",
  ],
  files: [
    "task_plan.md (W5 expanded with W5.0 prerequisite + farming demo as 3D; Tier 4.3 reframed; conceptual ladder + reframe note updated)",
  ],
  followups: [
    "Build W5.0 renderer_3d when W4 (formula layer) completes",
    "Spawn clean reviewer to critique this revision",
  ],
};
