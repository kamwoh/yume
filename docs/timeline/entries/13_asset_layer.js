export const entry13 = {
  id: "13",
  date: "2026-04-30",
  type: "decision",
  title: "Assets are config, not code — invariant #8 added",
  summary:
    "Initial asset proposal lapsed into hardcoded thinking — \"enrich " +
    "<code>entity_sprite_2d.gd</code> with primitive shapes\" baked tree/rock/person " +
    "into engine code. User pushed back: <em>\"config config config, like the Environment " +
    "Map thingy too.\"</em> Sharp architectural correction. The deeper principle was " +
    "implicit; now it's an explicit invariant.",
  highlights: [
    "<strong>Invariant #8:</strong> <em>Engine = primitives + interpreter.</em> Engine ships fixed verb sets (effect types, draw ops, audio ops, query operators); all compositions (specific shapes, specific assets, specific bindings) live in JSON. Adding a verb requires engine code; adding a composition requires only JSON.",
    "<strong>Same shape across domains:</strong> rules / shapes / audio / asset-binding / formulas — all follow the primitives-vs-compositions split.",
    "<strong>W2.7a revised:</strong> instead of hardcoding tree/rock/person, build <code>shape_lib.gd</code> + <code>data/shapes.json</code>. Engine learns 6 draw primitives; shapes compose them. Adding \"bush\" or \"lantern\" = JSON edit, not engine code.",
    "<strong>Asset catalog format generalized:</strong> <code>data/asset_catalog.json</code> uses QueryLib matchers (existing engine primitive!) — Kenney catalog, custom catalog, AI-gen output all interchangeable JSON files.",
    "<strong>AI-gen backend is a plugin:</strong> tool reads <code>sprite_prompt</code> fields, dispatches to configured backend (SD/DALL-E/etc.). Engine knows nothing about which.",
    "<strong>Connection to Environment Maps:</strong> Feng et al.'s structured-graph claim is the same insight applied to agent memory. Structured representations beat hardcoded behavior — queryable, editable, incrementally refinable. Yume now applies this principle <em>uniformly</em> across runtime, content, and assets.",
    "<strong>Test of correctness:</strong> swapping pixel-art to AI-gen 3D = swap JSON files. Going silent = delete one JSON file. Adding a shape = edit one JSON file. Engine is ignorant of every specific asset/shape/sound/prompt by design.",
  ],
  files: [
    "docs/30_framework_primitives.md (invariant #8 added)",
    "task_plan.md (W2.7a revised, 2.5i-l tightened)",
  ],
  followups: ["Apply this consistency check whenever new layer is proposed"],
};
