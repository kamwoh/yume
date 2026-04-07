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

Return ONLY valid JSON.
