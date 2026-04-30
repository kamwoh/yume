export const entry15 = {
  id: "15",
  date: "2026-04-30",
  type: "decision",
  title: "Asset flow refined — two phases + three-tier fallback + interactive gen",
  summary:
    "User pushed two essential refinements: (a) during dev, use pre-defined primitives " +
    "(rectangles, spheres, cubes, planes) so iteration on rules + balance can happen " +
    "without any real assets; (b) generate one-by-one because prompts are guesses and " +
    "may not reflect intent. Both reshape the asset flow significantly.",
  highlights: [
    "<strong>Two-phase flow:</strong> design pipeline writes <em>prompts</em> in JSON (no I/O); a separate offline tool runs API calls when user is ready. Game is playable after phase 1 via fallback. Phase 2 is on-demand.",
    "<strong>Three-tier fallback in renderer:</strong> (1) real asset file, (2) composite from <code>shapes.json</code>/<code>meshes.json</code>, (3) bare colored circle/cube. Always something visible — every entity renders to something even before any art exists.",
    "<strong>3D primitive vocabulary added:</strong> <code>box</code>, <code>sphere</code>, <code>cylinder</code>, <code>capsule</code>, <code>plane</code>, <code>prism</code>, <code>torus</code>, <code>quad</code> — Godot's <code>PrimitiveMesh</code> types. Compositions in <code>data/meshes.json</code>. Mirrors the 2D <code>shapes.json</code> pattern.",
    "<strong>Interactive one-by-one is default:</strong> <code>yume assets generate</code> shows each prompt + cost, asks <em>g/e/b/s</em> (generate / edit / backend / skip); after generation shows preview + asks <em>y/r/R/b/s</em> (accept / regen / regen+edit / backend / skip). Especially critical for 3D ($0.40 + 60s/model — batch-blasting is wrong default).",
    "<strong>Batch mode opt-in:</strong> <code>--batch --auto-accept</code> for CI / full regen after style change. Selective: <code>--only wheat,tree</code>. Only-changed: <code>--since-prompt-changed</code>.",
    "<strong>Review UX:</strong> MVP dispatches to default OS image viewer (xdg-open / open / start). Nice mode: <code>yume assets review --serve</code> opens localhost HTML grid with click-to-regenerate. Predecessor attempts archived to <code>assets/generated/.history/</code> so iterations never lose a 'good enough' fallback.",
    "<strong>Cost-conscious by design:</strong> manifest tracks per-entity cost, <code>yume assets cost</code> reports totals, optional <code>max_cost_usd</code> guardrail in config.",
  ],
  files: [
    "task_plan.md (W2.7a clarified, 2.5k interactive default, 2.5k.4 review UX added)",
    "docs/32_architecture_diagrams.md (diagram #6 redrawn — two-phase + three-tier fallback)",
  ],
  followups: [
    "Iteration cycle test: type prose → playable game with bare cubes in &lt; 10 minutes",
    "Style change regen test: bare cubes → composite shapes → real assets",
  ],
};
