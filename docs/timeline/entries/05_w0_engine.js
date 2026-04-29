export const entry05 = {
  id: "05",
  date: "2026-04-22",
  type: "build",
  title: "W0 spike — single-file GDScript engine",
  summary:
    "Throwaway prototype to validate the primitive set <em>before</em> committing 5-7 weeks " +
    "to production code. Single file, all 7 primitives, 4-phase tick, formula eval via Godot " +
    "<code>Expression</code>. Lives in <code>YumeSpike/</code>; gets deleted at W0 exit.",
  highlights: [
    "~700 lines of GDScript total — entire engine in one file",
    "Entity dict / rule list / relation store / phase scheduler / formula eval / contact pair matcher",
    "Goal: discover primitive gaps in days, not weeks",
    "If a primitive is missing or wrong, found here for the cost of throwaway code",
  ],
  files: ["spike/engine.gd (deleted)", "spike/run.gd (deleted)"],
  followups: ["Run 9 demos against it"],
};
