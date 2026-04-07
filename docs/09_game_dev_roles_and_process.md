# Game Development Roles & Process

## Complete Team Roles

### Real Game Studio Roles

| Role | What they do | Yume equivalent |
|------|-------------|----------------|
| **Creative Director** | Overall vision, tone, identity | The user's story + GDD |
| **Game Designer** | Mechanics, systems, balance, fun | docs/02 (RPG systems), balance pass |
| **Level Designer** | Room layouts, flow, pacing, exploration | docs/07 (room structure), location JSONs |
| **Narrative Designer** | Story, dialogue, emotional arc, character development | docs/07 (narrative design), dialogues.json |
| **Dialogue Writer** | Actual dialogue lines, NPC conversations, personality | dialogues.json, quest-state dialogues |
| **Systems Programmer** | Core engine, combat, save/load, AI | templates/godot/scripts/ |
| **Gameplay Programmer** | Player controller, interactions, UI | player_controller.gd, UI scripts |
| **UI/UX Designer** | Menus, HUD, dialogue boxes, shop interface | ui_theme.gd, UI scripts |
| **Concept Artist** | Visual style, character designs, environment mood | ART_BIBLE.md prompts |
| **Environment Artist** | Backgrounds, tilesets, props | Location props, atmosphere |
| **Character Artist** | Sprites, portraits, animations | Character sprite prompts |
| **Animator** | Walk cycles, attack animations, effects | (Future: sprite animation) |
| **Audio Designer** | SFX, ambient sounds | audio_manager.gd, sfx/ |
| **Composer** | BGM, battle music, victory fanfare | audio_manager.gd, bgm/ |
| **QA Tester** | Find bugs, test everything | validator.py, playtesting |
| **Producer** | Schedule, scope, priorities | task_plan.md |

### Game Dev Tycoon's 9 Development Areas

The game "Game Dev Tycoon" breaks development into 9 sliders across 3 phases:

**Phase 1: Foundation**
| Area | Design% | Tech% | What it covers |
|------|---------|-------|---------------|
| Engine | 20% | 80% | Core systems, performance, save/load |
| Gameplay | 80% | 20% | Controls, combat, interactions, "the fun" |
| Story/Quests | 80% | 20% | Plot, quest chains, narrative structure |

**Phase 2: Content**
| Area | Design% | Tech% | What it covers |
|------|---------|-------|---------------|
| Dialogues | 90% | 10% | NPC conversations, cutscene text, personality |
| Level Design | 40% | 60% | Room layouts, enemy placement, flow, secrets |
| AI | 20% | 80% | Enemy behavior, NPC pathing, boss patterns |

**Phase 3: Polish**
| Area | Design% | Tech% | What it covers |
|------|---------|-------|---------------|
| World Design | 60% | 40% | Location variety, atmosphere, props, connections |
| Graphics | 50% | 50% | Art assets, animations, visual effects, particles |
| Sound | 60% | 40% | BGM, SFX, ambient audio, voice |

### RPG Genre Focus (from Game Dev Tycoon)
For RPGs specifically, the most important areas are:
**Gameplay, Story/Quests, Dialogues, AI, Graphics, Sound**

Engine and Level Design matter less for RPGs than for action games. This maps to Yume's priorities:
1. ✅ Gameplay (combat, interactions) — done
2. ✅ Story/Quests (quest chain, progression) — done
3. ⚠️ Dialogues (need 26+, have 11) — partially done
4. ✅ AI (enemy combat behavior) — done
5. ❌ Graphics (still colored rectangles) — future
6. ⚠️ Sound (system built, no audio files) — partially done

---

## How This Maps to Yume's Framework

Each "role" in a real studio maps to a **component** in Yume:

```
Creative Director  →  User provides story/vision
Game Designer      →  core/docs/ + archetypes/rpg/docs/
Level Designer     →  location JSONs (the 52-room blueprint)
Narrative Designer →  dialogues.json + cutscene data
Dialogue Writer    →  LLM generates from prompts/
Systems Programmer →  templates/godot/scripts/ (pre-built)
UI/UX Designer     →  ui_theme.gd (pre-built)
Artist             →  ART_BIBLE.md → image gen API (future)
Composer           →  audio_manager.gd → audio files (future)
QA Tester          →  validator.py + playtesting
Producer           →  task_plan.md + progress.md
```

**Yume replaces the entire team except the Creative Director.** The user provides the vision. Yume (through its knowledge framework + LLM) handles everything else.

---

## The Development Process (How a Game Gets Made)

### Phase 1: Pre-Production (what we've done)
```
Story idea → GDD → Architecture → Tech choices → Prototype
```

### Phase 2: Production (where we are)
```
Engine systems ✅ → Content creation ⚠️ → Art creation ❌ → Audio ⚠️
```

### Phase 3: Polish (next)
```
Bug fixing → Balance → Visual effects → UI juice → Playtesting
```

### Phase 4: Release
```
README → Demo video → GitHub → Marketing → Community
```

### What "Done" Looks Like for Each Area

| Area | Current state | "Done" state |
|------|--------------|-------------|
| Engine | ✅ Complete | All systems work |
| Gameplay | ✅ Complete | Combat, shops, save/load feel good |
| Story/Quests | ⚠️ Basic chain | 52 rooms, 26+ dialogues, cutscenes at key moments |
| Dialogues | ⚠️ 11 dialogues | 26+, party banter, quest-state NPCs |
| Level Design | ⚠️ 12 flat rooms | 52 rooms with distinct layouts, flow, secrets |
| AI | ✅ Basic | Boss patterns, varied enemy behavior |
| World Design | ⚠️ Props + particles | Each room feels unique, atmospheric |
| Graphics | ❌ Colored rectangles | Sprites or procedural visuals |
| Sound | ⚠️ System built | BGM + SFX files present |

Sources:
- [Game Dev Tycoon Specialists Guide](https://steamcommunity.com/sharedfiles/filedetails/?id=1842635307)
- [Game Development Team Roles](https://indiedevgames.com/decoding-game-development-team-roles-and-structures-a-deep-dive-into-aaa-teams-and-their-influence-on-the-gaming-industry/)
- [Key Roles in Game Development](https://www.indeed.com/career-advice/finding-a-job/game-development-roles)
- [Video Game Development - Wikipedia](https://en.wikipedia.org/wiki/Video_game_development)
