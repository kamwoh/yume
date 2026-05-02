export const entry26 = {
  id: "26",
  date: "2026-05-02",
  type: "review",
  title: "TinyPond playable — five harness gaps surfaced + folded back into skills",
  summary:
    "Long debug session making TinyPond actually playable. The pipeline produced a sim with no game-feel. " +
    "Adding HUD, win/lose, controls, day/night impact surfaced five separate harness gaps. Each one was a " +
    "lesson the framework didn't yet capture. Captured all five in skill files so the next pipeline run won't " +
    "repeat them.",
  highlights: [
    "<strong>Tier 2.6h shipped (skills updated)</strong>: <code>game_shell.gd</code> runtime reads <code>scene.json</code> + <code>hud.json</code>. Tinypond fully JSON-driven — zero per-game GDScript or .tscn editing. Same shell serves harvestcore.",
    "<strong>Gap 1 — shapes.json location</strong>: per-game <code>data/demo_X/shapes.json</code> was dead weight. Renderer hardcoded to <code>data/shapes.json</code> root. Fix: append per-game shapes to root file. Captured in asset-designer SKILL.md.",
    "<strong>Gap 2 — contact rule format</strong>: tags + radius go in <code>query.a/b</code> + <code>query.radius</code>, NOT inside <code>trigger</code>. Wrong format makes rules silently never fire. Cost a debug cycle. Captured in content-designer SKILL.md.",
    "<strong>Gap 3 — Vector2 != Vector3</strong>: engine bug in world.gd's idle-detection. Fix shipped (type guard). 188/188 tests still pass. Captured in commit history; not a skill issue.",
    "<strong>Gap 4 — visual sizes</strong>: 3-6px shapes are illegible at default zoom. Rule: 12-30px range. Captured in asset-designer SKILL.md.",
    "<strong>Gap 5 — game-feel layer</strong>: sim cascades alone aren't a game. Win/lose conditions, visible feedback for hidden state, HUD config — all required. Captured in game-designer SKILL.md (new 'Goal/Win/Lose' + 'Visible feedback' sections).",
    "<strong>Honest user grade: 1/100 → playable</strong>: at one point user said the game was '1% over 100%'. They were right. Subsequent iterations addressed visuals, eat radius, camera follow, fish flip-on-direction, pond bounds visual, win-freeze, plant population balance, day/night impact (fish slow at night).",
    "<strong>Day/night now meaningful</strong>: 50s cycle (was 10s, too fast to feel). At night, plants don't grow AND fish move at half speed. Player feels real time pressure. Without this, the cycle was conceptually present but mechanically dead.",
    "<strong>Plant balance fix</strong>: seeding chance 0.4/15 → 0.05/60. Plants now a finite resource — pressure to eat efficiently before they run out. Pop stable around starting size; engine no longer lags.",
    "<strong>Frame for the framework</strong>: every gap in this session was a lesson the pipeline COULD have known if its agents knew. Skill files now updated; next <code>/yume-design</code> run should produce a playable game on first try.",
  ],
  files: [
    "archetypes/core/templates/godot/scripts/engine/game_shell.gd (new)",
    "archetypes/core/templates/godot/scripts/engine/world.gd (Vector2/3 fix)",
    "archetypes/core/templates/godot/scripts/renderer_2d/entity_sprite_2d.gd (flip_with_velocity)",
    "archetypes/core/templates/godot/data/shapes.json (tinypond shapes appended to root)",
    "archetypes/core/templates/godot/data/demo_tinypond/{scene,hud,entities,world_rules,world}.json",
    "archetypes/core/templates/godot/data/demo_harvestcore/{scene,hud}.json (HUD via shell)",
    "archetypes/core/templates/godot/scenes/tinypond_2d.tscn (minimal template)",
    "archetypes/core/templates/godot/scenes/harvestcore_2d.tscn (minimal template)",
    ".claude/skills/yume-content-designer/SKILL.md (contact format, balance, position caveat)",
    ".claude/skills/yume-asset-designer/SKILL.md (shapes.json location, sizes, scene.json/hud.json schemas)",
    ".claude/skills/yume-game-designer/SKILL.md (win/lose + visible feedback requirements)",
  ],
  followups: [
    "Update systems-designer SKILL.md with population-balance rule-of-thumb",
    "Make harvestcore actually playable — wire WASD + tool-cycle inputs, test it lands on the same shell",
    "Add a smoke-test that runs each generated game for N ticks and asserts entity count stable",
    "Tier 2.6e VQA integration would have caught the 'grey dots' rendering issue in 30 seconds, not 30 minutes",
  ],
};
