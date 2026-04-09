# Task Plan: Yume Complete — Framework + FF9 + Game State

## Vision
Yume (夢) = React for game dev. User writes story → Claude + Yume → playable RPG.
Same data → 2D code blocks → 2D sprites → 3D models. Engine-agnostic.

## Yume Design Principles
1. **Data drives everything** — JSON → engine reads → game runs
2. **Asset abstraction** — visual_helpers.gd auto-detects sprites/blocks/3D; audio_manager auto-detects audio files
3. **Story state machine** — game_state.json = single source of truth for story flow
4. **Test-driven** — yume test verifies entire game automatically
5. **Nothing hardcoded** — everything controllable from JSON data

## End-to-End Flow
```
User: "Here's my story..."
  → Claude reads pass0-5 prompts
  → Generates: game_state.json + locations/*.json + characters/items/enemies/quests.json
  → yume init my-game → yume test my-game → fix loop
  → "Open in Godot → F5"

Asset pipeline (parallel):
  → sprite_prompts → Image Gen AI → sprites/*.png (auto-detected)
  → bgm_prompt/sfx_prompt → Audio Gen AI → audio/*.ogg (auto-detected)
  → sprite_prompts → 3D Gen AI → models/*.glb (future)
```

---

## TRACK A: Game State Machine — DONE
- [x] A1: game_state.json (27 phases, 5 bosses, 3 party joins)
- [x] A2: story_manager.gd (reads phases, fires triggers, save/load)
- [x] A3: Playthrough simulator (follows phases, 20 pass / 0 fail)
- [x] A4: Location JSONs cleaned (story events removed, visual-only)

## TRACK B: FF9 Content — DONE
- [x] B1: Disc 1 (26 rooms at 3.8 items/room)
- [x] B2: Disc 2-4 (26 rooms upgraded, 184 total treasures, 7 bosses)
- [ ] B3: Human playtest — IN PROGRESS (dialog bugs being fixed)

## TRACK C: Framework Polish — MOSTLY DONE
- [x] C1: Prompts updated (pass0-5, 6 total)
- [x] C2: Tested on new story (Ember Chronicle — 16 pass, 0 fail)
- [ ] C3: 3D templates (future)
- [ ] C4: Publish (future)

## TRACK D: Active Bugs + Polish ← CURRENT
- [x] D1: debug_mode missing from game_manager.gd
- [x] D2: Nil-to-String crash in story_manager.gd (JSON null pitfall)
- [x] D3: Nil-to-String crash in quest_manager.gd (prerequisite: null)
- [x] D4: := inference fail in static func (visual_helpers.gd)
- [ ] D5: Prologue dialog repeats after prologue screen — split into 2 phases (narration + gameplay)
- [ ] D6: visual_helpers.gd NPC shapes hardcoded — should be JSON data-driven
- [ ] D7: Prologue screen visuals need polish
- [ ] D8: Character portraits in dialogue box
- [ ] D9: Audio abstraction layer (bgm, sfx, ambience, voice)

## Current State

| Component | Status |
|-----------|--------|
| Engine (12 autoloads) | Done |
| game_state.json | Done (27 phases) |
| story_manager.gd | Done |
| 52 room JSONs | Done (3.5 items/room) |
| 23 enemies, 21 items | Done |
| 6 prompts (pass0-5) | Done |
| 4-layer test suite | Done (20 pass, 0 fail) |
| Prologue screen | Working, needs polish |
| Visual abstraction | Done (auto-detect sprites) |
| Audio abstraction | Prompt written (pass5), engine TODO |
| Data-driven NPC visuals | TODO (currently hardcoded) |
| FF9 novel reference | Scraped (54K words) |
| FF9 walkthrough | Scraped (45 chapters) |
| Lessons | 55+ saved |

## 5-Question Reboot Check
| Question | Answer |
|----------|--------|
| Where am I? | Playtesting. Engine fully data-driven. 31 phases, 57 rooms, 8 ability types. |
| Where am I going? | Battle config + player physics to JSON → 3D → README → publish |
| What's the goal? | ZERO hardcoded game data. Same JSON → any renderer. |
| What have I learned? | Zero fake rule, director mindset, single controller, ability types, hardcoded audit process |
| What have I done? | 57 rooms, 31 phases, 24 enemies, 8 ability types, 6 prompts, 4 tests, 75+ lessons, GitHub |
