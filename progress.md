# Progress Log — Yume 3D / World Modeling

## Previous work: see progress_ff9_2d.md

## Session: 2026-04-08 to 2026-04-09

### Completed
- Strategic pivot: game framework → world modeling data generation
- 3D engine: world_builder.gd, player_3d.gd (reads JSON, loads GLBs)
- 876 free GLB models organized (KayKit + Kenney)
- Auto-capture: 10-angle screenshots, no human needed
- Auto-agent: walks around automatically, records actions
- Visual QA loop: capture → Claude reads → fix JSON → re-capture
- Grid-based room building (modular tiles)
- Animation system: load from separate GLBs, crossfade blending
- All config from JSON (zero hardcoded in engine)
- Git: 3 commits pushed

## Session: 2026-04-10

### Harness Engineering (COMPLETE)
- 5 hooks in .claude/settings.json (pre-commit test, JSON validate, hardcode check, error-learn, session log)
- 3 agent definitions (.claude/agents/designer.md, builder.md, tester.md)
- Structured state file (.claude/yume_state.json)
- Visual regression testing tool (tools/visual_regression.py + CLI command)
- Bootstrapped 116 lessons in ~/.yume/lessons/
- Updated docs/17_harness_engineering_plan.md — all items complete

### Game Design Study (COMPLETE)
- Deep research: Level Design Book, MIT courses, MDA framework, procedural gen algorithms
- docs/18_game_design_knowledge.md — comprehensive rules document
- 33 concrete design rules + metrics + algorithms
- Key insight: hybrid approach (handcrafted templates + procedural arrangement)
- 6 design lessons saved to knowledge base

### First Good Room — "Guard Post" (COMPLETE)
Applied ALL design rules to create dungeon_guard_post.json:
- L-shaped 16x14 room (asymmetric, not symmetric box)
- Dark background (bg_color near black, sun_energy 0)
- 4 point lights: warm entrance, golden focal, cool blue alcove, mid-room fill
- Zebra lighting: bright pools + dark gaps + two distinct moods
- Three-layer composition: dark foreground → lit center → dark background
- Focal point: red banner + lit chest on far wall
- Props with story logic: barrels (storage), weapons (security), rocks (battle damage)
- Spawn point on grid (not pixel coords — fixed stuck-in-wall bug)
- Auto-agent walks around, camera follows, 47 captures showing different views

### Engine Improvements
- point_lights support in world_builder.gd (OmniLight3D from JSON)
- Per-location sun_energy override via atmosphere section
- spawn_on_grid for grid rooms (vs pixel-based entrance)
- Auto-agent attachable via meta.json capture.auto_agent flag
- Auto-capture reads grid room dimensions correctly
- _build_environment() only runs after location data loads (fixes blue sky bug)

### Visual QA Loop (PROVEN)
Command: `timeout 20 "$GODOT" --path "$WIN_PROJECT" --rendering-method gl_compatibility`
- Works from WSL with Intel GPU
- Auto-agent moves character around room
- frame_capture.gd saves screenshots every 0.5s
- Claude reads captures, evaluates, iterates
- STANDING RULE: never ask user to visually test

## Current State
| What | Status |
|------|--------|
| 2D engine | Complete, pushed to GitHub |
| 3D engine | Working — reads JSON, loads GLBs, point lights, auto-agent |
| Harness engineering | Complete — 5 hooks, 3 agents, visual regression, 116 lessons |
| Game design knowledge | Complete — docs/18, 33 rules, metrics, algorithms |
| First good room | Complete — guard post looks like a real dungeon |
| Room templates | Next — handcraft 5-10 templates per story_role |
| Procedural generator | Next — BSP layout → story roles → templates → content variation |

## Next: Room template library → Procedural generation → Agent recording → Export
