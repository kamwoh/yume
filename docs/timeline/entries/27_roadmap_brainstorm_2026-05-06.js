export const entry27 = {
  id: "27",
  date: "2026-05-06",
  type: "decision",
  title: "Post-ADR-0009 roadmap brainstorm — next games + new skills",
  summary:
    "Strategic conversation about what to build after ADR 0009 closed. Captured engine-surface findings, " +
    "ranked candidate skills (combining-logic, economy-designer, story-planner), ranked candidate games " +
    "(merchant-POV, SAO-Alicization-style, Sims-like, combining-magic, Civilization), reframed " +
    "combining-logic as universal compositional pattern (not magic-specific), recognized that SAO " +
    "Alicization is essentially a life-sim setup. Decided next move: merchant-POV game as pipeline " +
    "freshness test + combining-logic skill shakedown, then Alicization-style as second target after " +
    "time-compression engine question is answered.",
  highlights: [
    "<strong>Engine surface — ui/input.json scope</strong>: keys + mouse left/right/middle buttons work via Godot InputMap. NOT yet wired: mouse position (continuous), mouse wheel, modifier combos (shift+click), touch, gamepad. doomarena3d reads mouse position via Input.get_last_mouse_velocity directly in game_shell rather than as an input action. Press/hold edge classification covers most needs; mouse-as-state worth adding before any pointer-driven game (RTS, point-and-click).",
    "<strong>Engine surface — simulation input layer</strong>: scenario_runner.gd already provides programmatic input via scheduler.queue_input(action, params) — same code path as live keyboard. What's missing for runtime AI driving the game: (1) non-headless variant (queue_input not exposed via running World node) and (2) policy interface — observer/action loop per tick. Both are Tier 3 (Actors) work.",
    "<strong>Skill candidate — combining-logic designer (REFRAMED)</strong>: not magic-specific; a universal compositional pattern (input set + combination rule → output). Applies to crafting (Minecraft a+b=c), alchemy/cooking, plant breeding (Stardew), key combos, chemical reactions. Skill owns: recipe table shape (explicit map vs emergent rules), discovery design (recipe book vs free experimentation), combinatorial blow-up control, yield rules (destroy inputs vs copy), failure modes (invalid combos → trash / nothing / junk output). Yume primitives cover all of this — no new engine work. Cleanest of the new skills to ship.",
    "<strong>Skill candidate — economy-designer</strong>: high value but broad scope. Numeric balance (resource flows, conversion ratios, pricing curves) currently ad-hoc per game and a frequent source of QA findings. TD, RPG, Civ-likes, merchant games all need it. Best built alongside a real game so the surface is grounded.",
    "<strong>Skill candidate — story-planner</strong>: distinct from level-designer (spatial). Tracks named events, character arcs, plot progression. Defer until a narrative game actually needs it — speculative authoring risks over-engineering.",
    "<strong>Game idea — merchant-POV (Recettear-like)</strong>: BEST next pipeline test. NPC-side simulation, async news events, quest-issuing-not-receiving. Yume's relation/signal primitives handle this naturally. Honest scope: 1 shop, ~5 traveler types, ~10 item types, news as world.signal. Simultaneously tests pipeline freshness + the new combining-logic skill (merchant crafts items by combining materials).",
    "<strong>Game idea — SAO Alicization-style life-sim</strong>: the Alicization arc (LN vols 9-18, 2018-2020 anime) is the Underworld project — researchers raise artificial souls (Fluctlights) from infancy through full life arcs in a medieval-village simulation. Two POV options: (a) play the Fluctlight (life sim from inside) or (b) play the researcher (god-game observer). Two unique design levers: time-compression (Fluctlights live decades, observers see days) and the dual-POV framing. Yume substrate suits this — harvestcore already has NPCs with schedules + needs + relationships.",
    "<strong>Game idea — Sims-like</strong>: harvestcore + needs systems + select-and-direct UI. Substrate mostly there.",
    "<strong>Game idea — Civilization</strong>: too big without Tier 3 actors (faction AI). Premature.",
    "<strong>Game idea — pure-combining-magic</strong>: small-scope test for combining-logic skill in isolation. Could ship as ~1 hour of progression with ~15 base elements. Useful if we want to validate the skill without coupling to a larger game.",
    "<strong>SAO mainline (Aincrad/ALO/GGO arcs)</strong>: noted but unbuildable without picking the GAME mechanic — combat? floor-clearing? guild management? 'Build SAO' is too underspecified. Alicization is the buildable arc because life-sim IS the mechanic.",
    "<strong>Decision — next move</strong>: build merchant-POV game via /yume-design as pipeline-freshness test, with combining-logic baked in (merchant crafts potions/items). One session. Validates pipeline + new skill simultaneously.",
    "<strong>Decision — second move</strong>: SAO-Alicization-style life-sim AFTER answering the time-compression engine question (do we add a year_counter world_state binding? variable tick_seconds? compress via tick interval?). Needs design conversation, not a clean /yume-design drop-in.",
    "<strong>Outstanding planning questions</strong>: time-compression mechanism for long-arc games; mouse-position-as-state for pointer-driven games (when needed); story-planner skill design (defer until narrative game starts).",
  ],
  files: [
    "task_plan.md (will update with brainstorm outcomes if/when committed)",
    "docs/timeline/entries/27_roadmap_brainstorm_2026-05-06.js (this entry)",
  ],
};
