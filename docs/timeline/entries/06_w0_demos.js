export const entry06 = {
  id: "06",
  date: "2026-04-22",
  type: "discovery",
  title: "W0 — 9 demos pass; <code>require</code> clause discovered",
  summary:
    "Six original demos plus three stress tests. All pass on the same engine — different JSON. " +
    "Critically: <strong>chess</strong> (non-spatial, turn-based) exposed a primitive gap that " +
    "the original 7 couldn't fill alone.",
  highlights: [
    "<strong>trivial:</strong> tick + <code>state_add</code> ✅",
    "<strong>ecology:</strong> contact trigger + <code>wet_lt 0.3</code> property match ✅",
    "<strong>rpg:</strong> state thresholds + signal chain (level-up) ✅",
    "<strong>farming:</strong> input trigger + emit + relate (<code>held_by</code>) ✅",
    "<strong>shooter:</strong> velocity_set + engine motion + contact + remove both ✅",
    "<strong>chess:</strong> Relation + turn flow + illegal-move rejection ✅ <em>after fix</em>",
    "<strong>stress_physics:</strong> formula via Expression — <code>(a.T - b.T) * 0.5</code> ✅",
    "<strong>stress_ordering:</strong> definition order + apply-time formula eval ✅",
    "<strong>stress_lifecycle:</strong> spawn / despawn / relation_changed triggers ✅",
    "<em>The big find:</em> chess rules carrying entity refs in payload need <code>require: {ctx_name: query_spec}</code> to validate context-bound entities. Generalizes to all input/signal/relation_changed rules.",
  ],
  followups: [
    "Add <code>require</code> to contract",
    "Document formula-at-apply-time semantics",
    "Document target resolution: context first, literal id fallback",
    "Document lifecycle flush at load",
  ],
};
