export const entry01 = {
  id: "01",
  date: "2026-04-22",
  type: "decision",
  title: "The reframe — universal simulation framework",
  summary:
    "User's clarifying question: <em>\"shouldn't this engine handle every game, not just RPG? " +
    "Farming, shooter, RPG — all on one substrate, differing only in JSON?\"</em> " +
    "This inverts the previous framing. World engine becomes the primary deliverable; " +
    "agents become Tier 3 work, not Tier 2.",
  highlights: [
    "Decision: <em>compositionality first.</em> Cost doesn't matter — get it right.",
    "Add (B): properties + reactions emerge from rules, not enumerated recipes",
    "All semantic effects (<code>damage</code>, <code>need_decay</code>, <code>advance_stage</code>) get deleted — they violate the universality invariant",
    "Player, AI, LLM brain — all emit the same <code>input</code> trigger stream",
  ],
  followups: ["Sketch the primitive set"],
};
