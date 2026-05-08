export const entry28 = {
  id: "28",
  date: "2026-05-06",
  type: "decision",
  title: "Content layer gaps — Yume passes correctness, fails attractiveness",
  summary:
    "Strategic redirect: instead of building more infrastructure (save/load, screens, tutorials, settings — " +
    "all 4 ADRs drafted but proposed), prioritize the CONTENT QUALITY layer. Yume's 13 specialist skills enforce " +
    "that games are correct (engine expresses them, no broken cascades). They do NOT enforce that games are " +
    "good. Identified 6 specific content-layer gaps and 3 priority candidate skills (playtester, " +
    "reference-design discipline, mechanic-progression-designer). Open question: is merchant game built AS the " +
    "test bed for these new skills, or do we mature content layer first then build?",
  highlights: [
    "<strong>Redirect framing</strong>: 'not just the game pause thing — most important is game content, attractiveness, story line, gameplay.' The 4 shell-layer ADRs (0010-0013) are necessary but secondary; primary problem is game quality, not infrastructure.",
    "<strong>Honest pipeline assessment</strong>: 13 specialist skills cover the design space. They produce games that PASS review. They do not produce games that are MEMORABLE. Sokoban v0.4 = 8 levels of 'push box onto goal' with no mechanic evolution; harvestcore NPCs are functionally distinct but personality-flat; tinypond runs the same dynamics from t=0 to t=2400. Symptoms.",
    "<strong>Gap 1 — No 'drafting on X' discipline</strong>: every shipped game stands on shoulders (a farming sim = a farming sim + AC + Terraria; an item-shop merchant game = 'play the shopkeeper'). Yume games design in a vacuum. game-designer writes 'merchant game' without 'we're drafting an item-shop merchant game, keep these 3, change these 2'. Fix: reference-design discipline added to game-designer + GDD section requiring 2-3 named games drafted on, with concrete what-we-keep/change.",
    "<strong>Gap 2 — No mechanic-progression / verb-expansion designer</strong>: level-designer thinks per-level; story-planner thinks per-beat; nobody thinks 'what's the player's verb library at hour 1, 2, 5, 10?'. Real Sokoban introduces ice/switches/holes; Mario gains running/jumping/swimming/vehicles. The variety IS the game. Yume games scale horizontally (more of same) not vertically. Fix: new skill OR strict GDD section.",
    "<strong>Gap 3 — No charm / voice / character-density discipline</strong>: a farming sim has 30+ NPCs with names + voices + schedules + heart events + arcs. game-planner produces 'named cast' but they're skeletons. Nobody puts FLESH on them. Fix: character-voice-designer skill OR more demanding game-planner.",
    "<strong>Gap 4 — No playtester skill</strong>: qa-tester verifies cascades fire (correctness). It does NOT say 'middle 10 minutes were boring.' Real games iterate dozens of times on playtester feedback; Yume builds once. Fix: playtester skill that simulates player experience — boring/confusing/great moments. Different from qa-tester and visual-designer; owns FUN.",
    "<strong>Gap 5 — No content scale enforcement</strong>: game-reviewer Axis 8 catches 'demo not game' but the fix is often 'add more levels' without thinking through whether the content is meaningful. 30 trivial levels ≠ more complete than 8 crafted ones. Fix: tighter game-designer + game-reviewer standards for 'intentional content per hour'.",
    "<strong>Gap 6 — No theme-cohesion-through-execution check</strong>: GDD says 'warm parchment archive'; asset-designer picks colors; visual-designer reviews — but nobody checks audio/enemy-names/dialog-tone alignment. Theme drift is #1 reason indie games feel 'off'. Fix: extend visual-designer's theme axis OR new theme-coherence pass.",
    "<strong>Deeper pattern</strong>: Yume's pipeline is optimized for 'the engine can express this'. It is NOT optimized for 'this game is GOOD'. Skills enforce correctness; almost none demand quality. Reasonable place to be (correctness first), but 'complete game' upgrade requires adding the quality layer.",
    "<strong>Priority candidates (3, ranked by impact)</strong>: (1) playtester skill — feedback loop that catches everything else; hardest to design but biggest impact. (2) reference-design discipline added to game-designer — every GDD must name 'drafting on: X, Y, Z'; 5 minutes per GDD; lifts all downstream decisions. (3) mechanic-progression-designer — forces verb-library expansion across play arc; without it, content scales horizontally.",
    "<strong>Relationship to ADRs 0010-0013</strong>: shell-layer ADRs become MORE valuable once content is good (polish on top of fun). Fun isn't there yet. Don't accelerate save/screen/tutorial/settings work until content layer matures.",
    "<strong>Open discussion questions logged</strong>: do gaps land? which of 3 candidate skills first? merchant game as test bed or content-mature-first? specific shipped games to learn from?",
  ],
  files: [
    "docs/adr/0010-save-load-persistence.md (proposed; awaits review)",
    "docs/adr/0011-declarative-screen-flow.md (proposed; awaits review)",
    "docs/adr/0012-tutorial-overlay-primitive.md (proposed; awaits review)",
    "docs/adr/0013-settings-schema-and-config.md (proposed; awaits review)",
    "docs/timeline/entries/28_content_layer_gaps_2026-05-06.js (this entry)",
    "task_plan.md (will append summary)",
  ],
};
