# Story-to-Gameplay Orchestration — How to Turn a Story into Phases

## The Core Question

Given a story, how do you decide:
- What's a cutscene vs. gameplay?
- How long is each section?
- Where do party members join?
- Where do bosses go?
- When does the player have freedom vs. be on rails?

## The Rhythm

Every JRPG follows this loop:

```
ARRIVE (cutscene) → EXPLORE (gameplay) → DISCOVER (cutscene) → CHALLENGE (boss) → RESOLVE (cutscene)
     2-3 min            5-10 min            1-2 min              3-5 min           1-2 min
```

Repeat per region. A 3-act game has ~4-6 of these loops.

### When to use CUTSCENE (player watches):
- Arriving at a new region for the first time
- Meeting a new party member
- Discovering a key plot point
- Before a boss fight (establishing stakes)
- After a boss fight (consequences)
- Act transitions
- Opening and ending

### When to use GAMEPLAY (player plays):
- Exploring a town (talking to NPCs, shopping, finding items)
- Traversing a dungeon (fighting, solving, collecting)
- Between story beats (player sets their own pace)

**Rule of thumb:** If the scene is about CHARACTER EMOTION or PLOT REVELATION → cutscene. If it's about PLAYER AGENCY or DISCOVERY → gameplay.

## Party Member Joins

**Don't just add them. Make them earn it.**

| Pattern | When to use | Example |
|---------|------------|---------|
| **Rescue join** | Party saves someone who then joins | Vivi trapped → freed → joins |
| **Shared goal** | Character has same objective | Freya: "My homeland is destroyed. I'm coming with you." |
| **Reluctant ally** | Circumstances force alliance | Steiner: "I'm only here to protect the princess!" |
| **Mentor/guide** | Character knows the way | Veil: "I know where the Archives are. I'll take you." |
| **Redemption** | Former enemy switches sides | Rook: "I defected. I couldn't freeze children." |

**Timing:** Party members should join in the FIRST HALF of an act, giving the player time to use them before the act's boss.

**The join scene needs:**
1. WHY they're here (motivation)
2. Personality reveal (how they talk)
3. What they bring (role in party)
4. A moment of connection with the protagonist

## Boss Placement

**Every boss needs buildup and payoff.**

```
Phase N:   "reach:boss_room" → pre-fight cutscene (stakes, dialogue, threat)
Phase N+1: "defeat:boss_id" → post-fight cutscene (consequences, next direction)
```

### Boss Types:

| Type | Pacing Purpose | Example |
|------|---------------|---------|
| **Gate boss** | Blocks progression. Must defeat to advance. | Plant Brain blocking forest exit |
| **Unwinnable boss** | Shows the villain is powerful. Humbles the party. | Beatrix, General Hailstorm |
| **Revelation boss** | Fighting it reveals something about the world. | Soulcage (Mist source) |
| **Final boss** | Climax. Everything builds to this. | Necron, Emperor Glacius |

**Placement rule:** One boss per region. Town → dungeon → boss → next region.

## Pacing Across Acts

### Act 1: Assembly + First Challenge
```
Region 1: Start location (meet protagonist)
  → Inciting incident (village attacked / princess kidnapped)
  → First ally joins
  → First dungeon
  → First boss (gate boss)
Region 2: New area
  → Second ally joins
  → Second dungeon
  → Second boss
  → Revelation that raises the stakes
```

### Act 2: Complications + Escalation
```
Region 3: Mid-game area
  → Third ally joins (if applicable)
  → Major story revelation
  → Harder dungeon
  → Unwinnable boss (humbles party, raises tension)
Region 4: Recovery + preparation
  → Party regroups
  → Key information obtained
  → Final preparation before Act 3
```

### Act 3: Confrontation + Resolution
```
Region 5: Enemy territory
  → Point of no return
  → Penultimate dungeon
  → Penultimate boss
Region 6: Final area
  → Final dungeon
  → Final boss
  → Ending cutscene
```

## Emotional Beat Mapping

**The story isn't just WHAT happens — it's HOW IT FEELS.**

Map each phase to an emotional beat:

| Phase | Emotion | How to achieve |
|-------|---------|---------------|
| Prologue | Wonder + curiosity | Beautiful setting, mystery hint |
| Inciting incident | Urgency + fear | Destruction, loss, time pressure |
| First ally | Relief + humor | Banter, personality clash |
| First boss | Tension + triumph | Buildup, then victory |
| Mid-game revelation | Shock + anger | Truth that reframes everything |
| Unwinnable boss | Despair + determination | Loss that motivates revenge |
| Final approach | Resolve + camaraderie | Party discusses why they fight |
| Final boss | Everything at stake | Callback to themes |
| Ending | Catharsis + hope | Resolution, reunion, new beginning |

## Dialogue Quality Checklist

For each cutscene:

- [ ] Does it SHOW not TELL? (visual description, not summary)
- [ ] Does each character sound DIFFERENT? (Kai: blunt. Pyra: ancient+playful. Rook: dry guilt.)
- [ ] Is there physical action? (kneels, turns away, slams fist)
- [ ] Is there an emotion the player should FEEL? (not just information)
- [ ] Does the scene end with FORWARD MOMENTUM? (player knows where to go next)
- [ ] Is it SHORT ENOUGH? (3-8 dialogue lines per scene. 12+ only for major moments.)

## Converting a Story Beat to a Phase

Given: "Kai discovers the factory where fire spirits are imprisoned."

**Step 1 — Identify the type:** This is a REVELATION scene.

**Step 2 — Choose trigger:** `reach:frost_prison` (player walks into the room)

**Step 3 — Write the emotional arc:**
- Start: curiosity (what is this place?)
- Middle: horror (the spirits are screaming)
- End: determination (we're freeing them)

**Step 4 — Write the cutscene:**
```json
{"action": "dialogue", "speaker": "", "text": "Rows of crystalline prisons line the walls. Inside each one, a fire spirit flickers weakly — dying."},
{"action": "dialogue", "speaker": "Pyra", "text": "My... my family. They're in so much pain."},
{"action": "dialogue", "speaker": "", "text": "Pyra's flame dims. Her voice breaks for the first time."},
{"action": "dialogue", "speaker": "Kai", "text": "We're getting them out. All of them."},
{"action": "dialogue", "speaker": "Rook", "text": "The locks are imperial-grade. We'll need to destroy the Crown itself."},
{"action": "dialogue", "speaker": "Kai", "text": "Then that's exactly what we're going to do."}
```

**Step 5 — Add gameplay context:**
```json
"quest": {"progress": "shatter_the_crown"}
```

## Anti-Patterns

| Don't | Do instead |
|-------|-----------|
| 20-line exposition dump | 3-5 lines with emotion, break with gameplay |
| "Hero, you must go to the tower" | Show WHY through NPC reactions, consequences |
| Party member appears and says "I'll join you" | Scene showing their motivation, personality, connection |
| Boss appears with no buildup | NPCs warn, environment changes, music shifts |
| Cutscene after cutscene | Cutscene → 5+ min gameplay → next cutscene |
| Everyone agrees immediately | Conflict, doubt, then resolution |
| Narration explains feelings | Dialogue and actions show feelings |
