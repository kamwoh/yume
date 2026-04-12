# OpenMW — Detailed NPC AI & World Architecture

## Source: /mnt/c/Users/kamwoh/Documents/Projects/Personal/openmw/

## Stack-Based AI Package System
NPCs have a priority stack. Top package runs each frame, popped when complete.

### AI Package Types
- Wander (default idle), Travel, Escort, Follow, Activate
- Combat, Pursue, Face, Cast, AvoidDoor, Breathe

### Wander State Machine (the default "alive" behavior)
```
ChooseAction → IdleNow (play idle animation with probability)
            → MoveNow (pathfind to destination)
            → Walking (follow path)
```
- Distance parameter: wander radius from spawn
- Duration: game hours to wander
- 8 idle animation slots with configurable probabilities
- Reaction timer: ~250ms between decisions (natural feel)
- Stuck detection: evades obstacles or drops bad nodes

### AI Settings (NPC personality)
```
AIData:
  mHello: greeting distance (0-65535)
  mFight: % chance to fight (0-100)
  mFlee: % chance to flee (0-100)
  mAlarm: % chance to raise alarm (0-100)
  mServices: bitflags (sell weapons, cast spells, train, etc.)
```

## Navigation
- Path Grid nodes pre-placed in editor
- Shortcutting: skip nodes if path is clear
- Door handling: detect closed doors, open or alternate route
- Obstacle avoidance in real-time

## Combat
- AiCombat package pushed on enemy detection
- Target tracking via RefId
- Pursuit if target flees (AiPursue)
- Fleeing logic based on mFlee setting

## Greeting System
```
States: None → InProgress → Done
Timer-based, triggered by proximity (mHello distance)
NPC turns to face player, plays idle dialogue
```

## Dialogue System
Topic-based with conditional responses:
```
DialInfo:
  mSelects: conditions (quest state, faction, race, class)
  mActor: which NPC
  mResponse: text shown
  mResultScript: compiled MWScript, runs on selection
  mQuestStatus: journal update (None, Name, Finished, Restart)
```

## Quest System
- Topic entries with state tracking
- Journal organized by topic
- Quest index determines available dialogue
- Restartable quests

## World Structure
- Cells: containers holding all objects (NPCs, creatures, items, doors)
- Exterior cells: grid-based coordinates
- Interior cells: named locations
- Distance-based streaming: load/unload by proximity

## Day/Night & Time
```
DateTimeManager:
  mGameHour: 0.0 to 24.0
  mGameTimeScale: e.g., 30 = 30 game minutes per real second
  mDaysPassed, mDay, mMonth, mYear
```
NPCs' wander duration decrements in game time.
Note: timeOfDay parameter is NOT functional in vanilla — no true daily schedules.

## Lua Modding API
Mods can:
- Get/set NPC stance, equipment, inventory
- Cast spells, trigger animations
- Create new NPCs with custom properties
- Query all objects in a cell, radius searches
- Get/set game time, weather
- Run global scripts (once per frame) or local scripts (per object)
- Scripts run in separate thread, scene mutations queued

## What Makes NPCs Feel Alive
1. Stack-based priority (combat interrupts wander)
2. Reaction timers (250ms, not instant)
3. Idle animation variety (8 slots with probabilities)
4. Greeting mechanics (turn + acknowledge)
5. Disposition tracking (relationships change)
6. Pathgrid navigation (natural movement)
7. Combat engagement (assess, fight, pursue, flee)

## Key Files
- apps/openmw/mwmechanics/aisequence.hpp — AI stack
- apps/openmw/mwmechanics/aiwander.cpp — wander behavior
- components/esm3/aipackage.hpp — AI data structures
- apps/openmw/mwdialogue/ — dialogue & quest system
- apps/openmw/mwlua/ — Lua API
- apps/openmw/mwworld/cellstore.hpp — cell organization
