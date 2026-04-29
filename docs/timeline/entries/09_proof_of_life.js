export const entry09 = {
  id: "09",
  date: "2026-04-22",
  type: "discovery",
  title: "Proof of life — engine ticks in Godot 4.6 headless",
  summary:
    "First end-to-end run of the production engine. One <code>wheat_seed</code> entity, one " +
    "tick rule incrementing <code>growth</code>. Loaded from JSON, scheduler ticked, effects " +
    "committed, state mutated correctly.",
  highlights: [
    "Synced framework to Windows-accessible <code>YumeTemplate/</code> for Godot to launch",
    "First run errored: <code>class_name</code> not registered. Fixed with <code>--editor --quit</code> to force class scan",
    "Second run: <code>[tick 2] seed_1.growth=2.0</code> ... <code>[tick 8] seed_1.growth=8.0</code>",
    "Entity + Rule + QueryLib + EffectApply + PhaseScheduler + World + WorldClock — all integrated and ticking correctly",
    "Tick rate: 0.5s real per tick. Stable for 600 frames (~5s real)",
  ],
  files: [
    "data/entities.json (1 wheat_seed)",
    "data/world_rules.json (1 grow rule)",
  ],
};
