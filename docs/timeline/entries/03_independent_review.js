export const entry03 = {
  id: "03",
  date: "2026-04-22",
  type: "review",
  title: "Independent review — three holes found",
  summary:
    "Asked a clean reviewer to critique the design with no conversation context. Verdict: " +
    "<em>\"promising-with-holes.\"</em> Three concerns ranked by severity. The biggest one " +
    "killed the 6-primitive design.",
  highlights: [
    "<strong>Missing 7th primitive — Relation.</strong> No way to express inventory, parent/child, board state, party. <code>carrying: {item: count}</code> as a state field breaks the queries-are-first-class invariant.",
    "<strong>Ordering/atomicity undefined.</strong> Within a tick, do effects see snapshot or mutate sequentially? Spawn visibility? Signal timing? — Semantic identity of the engine.",
    '<strong>Formula-by-Expression has three traps:</strong> perf (~30k evals/s), security (full GDScript syntax via JSON), fixed binding namespace can\'t express <code>nearest</code>, <code>last_hit_by</code>, <code>equipped_weapon</code>.',
    "Plus: <em>4-demo acid test isn't acid</em> — ecology/farming/shooter/RPG are real-time spatial siblings. Add <strong>chess</strong> as 5th demo for non-spatial proof.",
    "Plus: <em>do a spike before W1.</em> Acid test shouldn't sit at end of 5-7 weeks of work.",
  ],
  followups: ["Revise contract: 7 primitives, ordering model, chess demo, W0 spike"],
};
