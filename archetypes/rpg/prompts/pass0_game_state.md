Generate the story state machine from the story and structure data. This is the MOST IMPORTANT file — it controls the entire game flow.

You receive: the story text + Pass 1 structure (characters, locations, progression).

**Dialog ownership — game_state.json is the ONLY source of story dialog:**
| System | Owns | Does NOT own |
|--------|------|-------------|
| game_state.json | Cutscenes, party joins, boss intros, plot reveals | Ambient room descriptions |
| location on_enter_events | 1-line ambient description ("A dark cave.") | Character dialog, story events |
| dialogues.json | NPC talk-to only (trigger=interact) | Auto-play, quest-triggered |

If a character speaks → it goes in game_state.json, NOT in location events or dialogues.json.

**Before generating, understand the orchestration rhythm:**
- ARRIVE (cutscene 2-3 min) → EXPLORE (gameplay 5-10 min) → DISCOVER (cutscene 1-2 min) → CHALLENGE (boss 3-5 min) → RESOLVE (cutscene 1-2 min)
- If a scene is about CHARACTER EMOTION or PLOT REVELATION → cutscene phase
- If a scene is about PLAYER AGENCY or DISCOVERY → gameplay (no phase needed, player explores freely)
- Party members join in the FIRST HALF of each act (not right before a boss)
- Every boss needs TWO phases: encounter (reach trigger) + defeated (defeat trigger)
- Cutscene dialogue: 3-8 lines for normal scenes, 10-15 for major moments. SHOW don't TELL.

Output: a single JSON object for `game_state.json`.

## Format

```json
{
  "starting_phase": "prologue",
  "starting_location": "location_id",
  "starting_party": ["character_id"],
  "starting_items": ["potion", "potion", "potion", "phoenix_down"],

  "phases": [
    {
      "id": "phase_id",
      "trigger": "start|reach:location_id|defeat:enemy_id",
      "cutscene": [cutscene steps],
      "adds_party": ["character_id"],
      "sets_flags": ["flag_name"],
      "unlocks_exits": [{"from": "loc_id", "to": "loc_id"}],
      "quest": {"start": "quest_id", "complete": "quest_id"},
      "boss": "enemy_id",
      "next": "next_phase_id"
    }
  ]
}
```

## Scene Prompts — Generate Visuals WITH the Story

Every phase MUST include a `scene_prompt` — a detailed image generation prompt for the cutscene's visual. Write this AS you write the cutscene, not after. You're a film director: describe the shot.

```json
{
  "id": "find_garnet",
  "trigger": "reach:courtyard",
  "scene_prompt": "Castle courtyard at dusk, grand fountain center, theater stage left with red curtains, noble audience in formal dress, warm torchlight, a cloaked princess turning to face camera, watercolor JRPG style, wide establishing shot",
  "cutscene": [...]
}
```

Rules for scene_prompt:
- Describe the KEY VISUAL MOMENT of the scene (the most dramatic frame)
- Include: setting, lighting, characters present, camera angle, mood
- End with art style from meta.json
- For boss encounters: describe the boss's appearance and the arena
- For emotional scenes: describe character expressions and body language

## Phase Types

**Story beat** — reaches a location, cutscene plays, party/quest updates:
```json
{
  "id": "meet_ally",
  "trigger": "reach:forest_camp",
  "adds_party": ["warrior"],
  "cutscene": [
    {"action": "dialogue", "speaker": "", "text": "Narration describing the scene."},
    {"action": "dialogue", "speaker": "Hero", "text": "Character dialogue with personality."},
    {"action": "dialogue", "speaker": "Warrior", "text": "More dialogue."}
  ],
  "next": "next_phase"
}
```

**Boss encounter** — reaches boss room, cutscene plays, then boss fight:
```json
{
  "id": "dragon_fight",
  "trigger": "reach:dragon_lair",
  "boss": "fire_dragon",
  "cutscene": [
    {"action": "dialogue", "speaker": "", "text": "The dragon rises from its slumber."},
    {"action": "dialogue", "speaker": "Hero", "text": "Everyone, ready your weapons!"},
    {"action": "dialogue", "speaker": "", "text": "[Boss Battle] The Fire Dragon is weak to ice!"}
  ],
  "next": "dragon_defeated"
}
```

**Boss defeat** — fires after defeating the boss, unlocks progression:
```json
{
  "id": "dragon_defeated",
  "trigger": "defeat:fire_dragon",
  "sets_flags": ["dragon_slain"],
  "unlocks_exits": [{"from": "dragon_lair", "to": "mountain_peak"}],
  "quest": {"complete": "slay_the_dragon"},
  "cutscene": [
    {"action": "dialogue", "speaker": "Hero", "text": "We did it! The path is clear."}
  ],
  "next": "next_chapter"
}
```

## Cutscene Actions

| Action | Fields | What it does |
|--------|--------|-------------|
| dialogue | speaker, text | Show text (speaker="" for narration) |
| wait | duration | Pause in seconds |
| camera_to | x, y, duration | Pan camera |
| camera_follow_player | duration | Return camera to player |
| screen_shake | intensity, duration | Shake effect |
| fade_out | duration | Fade to black |
| fade_in | duration | Fade from black |

## Rules

1. **First phase trigger MUST be "start"** — fires when the game begins
2. **Phases are sequential** — engine tracks current_phase_index and only watches for the CURRENT phase's trigger
3. **Every boss needs TWO phases**: encounter (trigger: reach) + defeated (trigger: defeat)
4. **Party members join via adds_party**, NOT via cutscene join_party action
5. **Exit gates unlock via unlocks_exits** — the engine finds the requires_flag on that exit and sets it
6. **Quest flow via quest field**: {"start": "quest_id"} and/or {"complete": "quest_id"}
7. **Cutscene dialogue should have PERSONALITY** — not "Hero arrives at town" but "Hero kicks open the tavern door. 'Anyone here know where to find a dragon?'"
8. **Narration (speaker="") describes scenes visually** — what the player SEES, not what they're told
9. **Include [Tip] or [Boss] tags** in dialogue for gameplay hints
10. **Every act should have**: arrival scene, exploration, rising tension, boss, resolution

## Pacing Pattern

For a 3-act story with ~15 locations:
- Act 1: 6-8 phases (prologue, party assembly, first dungeon, first boss)
- Act 2: 6-8 phases (new region, revelations, harder boss)
- Act 3: 6-8 phases (final region, climax, final boss, ending)
- Total: 18-24 phases

## What Makes Good Phase Dialogue

**Good** (shows personality, emotion, visual detail):
```json
{"action": "dialogue", "speaker": "", "text": "The throne room. Rain pours through the shattered roof. A silver-haired man turns with theatrical grace."},
{"action": "dialogue", "speaker": "Villain", "text": "How touching. The rat comes home to die."},
{"action": "dialogue", "speaker": "Freya", "text": "I'd rather die standing in the rain of my homeland than kneel to the woman who destroyed it."}
```

**Bad** (generic, tells instead of shows):
```json
{"action": "dialogue", "speaker": "", "text": "You enter the throne room."},
{"action": "dialogue", "speaker": "Villain", "text": "I am the villain."},
{"action": "dialogue", "speaker": "Hero", "text": "We will defeat you."}
```

## Cutscene Directing Rules

You are a FILM DIRECTOR, not a script reader. Scenes need PACING:

1. **Pause between beats** — `{"action": "wait", "duration": 0.5}` between emotional shifts
2. **Actions before words** — describe what happens visually BEFORE characters react
   ```json
   {"action": "dialogue", "speaker": "", "text": "A match strikes. A candle flickers to life."},
   {"action": "wait", "duration": 0.8},
   {"action": "dialogue", "speaker": "Zidane", "text": "There we go."}
   ```
3. **Characters ENTER** — don't start with everyone present. Describe arrivals:
   ```json
   {"action": "dialogue", "speaker": "", "text": "The door creaks open. Three figures step into the light."},
   {"action": "dialogue", "speaker": "Blank", "text": "You sure are late!"}
   ```
4. **Screen effects punctuate** — `screen_shake` for impacts, `camera_to` for reveals
5. **Comedy needs timing** — setup → wait → punchline
6. **Build the scene** — silence → small action → bigger action → climax → resolution

A 20-step cutscene with pauses feels SHORTER than an 8-step wall of text.

## Immersion — Make the Player BE the Character

You are not writing a summary. You are putting the player INSIDE the scene.

**Sensory details** — smell, touch, sound, not just sight:
```json
{"action": "dialogue", "speaker": "", "text": "Darkness. The smell of sawdust and engine oil. The floor sways beneath your feet."}
```
NOT: `"You are in a dark room on a ship."`

**Internal monologue** — the character THINKS:
```json
{"action": "dialogue", "speaker": "Zidane", "text": "(Damn, who blew out the candle? Can't see a thing...)"}
```

**Delayed reveals** — feel before see:
```json
{"action": "dialogue", "speaker": "", "text": "Your hand finds the table. Fingers brush something waxy. A candle."},
{"action": "wait", "duration": 0.5},
{"action": "dialogue", "speaker": "", "text": "Scratch. A tiny flame catches—"},
{"action": "change_lighting", "type": "dim", "duration": 1.5}
```

**Sound words** — CRASH, CRACK, scratch. Impact through text.

**Forward momentum** — end every scene with desire:
```json
{"action": "dialogue", "speaker": "", "text": "Through the window, Alexandria Castle fills the sky. The adventure begins."}
```
NOT: `"Go to the next area."`

Return ONLY valid JSON.
