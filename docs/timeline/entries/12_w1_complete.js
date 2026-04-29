export const entry12 = {
  id: "12",
  date: "2026-04-29",
  type: "build",
  title: "W1 complete — 77/77 unit tests pass",
  summary:
    "W1.13 ships engine-unit tests for all primitives in a single consolidated runner. " +
    "Run via <code>godot --headless --path . scenes/test_main.tscn</code>. Demo (<code>world_2d.tscn</code>) " +
    "still green post-test addition. <strong>Tier 2 W1 is closed cleanly.</strong>",
  highlights: [
    "<code>scripts/engine/tests/test_runner.gd</code> — 6 sections, 77 assertions",
    "<strong>Entity:</strong> create / tags (add/remove/dedup) / state / velocity / snapshot / override merges (18)",
    "<strong>Rule:</strong> from_dict / effect-list normalization / before-after / validate_all (12)",
    "<strong>RelationStore:</strong> relate / unrelate / transfer / dedup / clear_entity / has_edge / snapshot+restore (13)",
    "<strong>QueryLib:</strong> tags all/any/none / property + state operators / strict missing-field / radius / limit / order_by / matches (14)",
    "<strong>EffectApply:</strong> all 13 effect types / target as literal id / spawn with forced id / transform with state preservation (16)",
    "<strong>Schema validator smoke:</strong> rejects empty id, missing effect type, bad chance (4)",
    'Tier 2 status: W0 ✅, W1 ✅, W2-W6 📋 next. <em>Engine has primitives + tests; needs trigger expansion (W2), spatial index (W3), formula layer (W4), acid test (W5), content depth (W6).</em>',
  ],
  files: [
    "scripts/engine/tests/test_runner.gd",
    "scenes/test_main.tscn",
  ],
  followups: ["W2: signal/input/spawn/contact triggers + motion integrator"],
};
