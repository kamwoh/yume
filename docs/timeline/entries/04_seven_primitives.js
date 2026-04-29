export const entry04 = {
  id: "04",
  date: "2026-04-22",
  type: "build",
  title: "Contract finalized — seven primitives + four-phase tick",
  summary:
    "All review feedback applied. <code>docs/30_framework_primitives.md</code> becomes the " +
    "design contract — every engine choice traces back to it.",
  highlights: [
    "<strong>7 primitives:</strong> Entity, Tag, Rule, Trigger, Effect, Query, <strong>Relation</strong>",
    "<strong>4-phase tick:</strong> <code>input</code> → <code>decide</code> (snapshot read, buffer effects) → <code>commit</code> (apply in JSON definition order, formulas eval at apply-time) → <code>react</code> (contact + signals from commit; signals from react queue to next tick)",
    "Operator renames: <code>_min</code>/<code>_max</code> → <code>_atleast</code>/<code>_atmost</code>; <code>tags_none</code> added",
    "<code>priority: int</code> deleted — replaced with named phases + <code>before</code>/<code>after</code> hints",
    "Six-layer test plan baked in: unit, schema validator, integration, determinism/replay, acid-test, no-genre-leak",
    "Reserved triggers: <code>scheduled</code> (rhythm), <code>relation_changed</code> (equip-on-pickup)",
  ],
  files: ["docs/30_framework_primitives.md"],
  followups: ["W0 throwaway spike before W1 production work"],
};
