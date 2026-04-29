export const entry02 = {
  id: "02",
  date: "2026-04-22",
  type: "build",
  title: "Initial six primitives drafted",
  summary:
    "First sketch of the universal vocabulary: <strong>Entity, Tag, Rule, Trigger, " +
    "Effect, Query</strong>. Composition examples written for hunger (RPG), bullet damage " +
    "(shooter), crop growth (farming), level-up (RPG). All four expressible from the same " +
    "primitive set with different JSON.",
  highlights: [
    "Effects reduced to primitives: <code>state_set</code>/<code>add</code>/<code>mul</code>/<code>clamp</code>, <code>spawn</code>, <code>remove</code>, <code>transform</code>, <code>velocity_set</code>, <code>emit</code>, <code>tag_add</code>/<code>remove</code>",
    "Triggers: <code>tick</code>, <code>contact</code>, <code>signal</code>, <code>input</code>, <code>spawn</code>/<code>despawn</code>, <code>scheduled</code>",
    'Genre acid-test framing: 4 demos must run on identical engine code — <em>"if any needs engine code, the engine leaks"</em>',
  ],
  followups: ["Independent review caught critical gap"],
};
