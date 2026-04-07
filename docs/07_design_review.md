# Design Review: FF9 RPG Prototype

**Reviewer:** Senior JRPG Design Consultant
**Date:** 2026-03-30
**Build State:** Functional prototype -- all systems operational, no title screen, no ending, 12 flat locations, 4 dialogues, 8 enemies, 12 items, 1 side quest

---

## Executive Summary

This prototype proves the engine works. It does not prove the game works. The distance between those two things is the distance between a SNES ROM hack and Final Fantasy VI.

What you have built is a **corridor with encounters bolted on**. A player walks from rectangle A to rectangle B, reads some text, fights some colored shapes, and eventually reaches a big colored shape. The skeleton of FF9's story is here, but a skeleton is not a body. There is no muscle, no skin, no breath.

I am going to be specific about every problem, and I am going to be specific about what to do about each one.

---

## 1. The First Five Minutes (Player Onboarding)

### What happens now

The player starts in Alexandria Castle. A narration box says the castle is grand and there are banners. The player is immediately free to walk anywhere. There are colored rectangles. One is labeled "Garnet." If the player happens to walk to Garnet, the game's first (and only) real dialogue plays -- four lines where Zidane quips about kidnapping and Garnet asks for help.

Then the player is left alone in a flat room with no direction.

### What a player feels

Confusion. Then boredom. There is no tutorial. No one tells them to talk to Garnet. No one tells them attacks exist. No one tells them they can open a menu. The first time they encounter a random battle in Evil Forest, they will be thrown into an ATB system they have never seen, with commands they have never been told about, against enemies whose weaknesses they have no way of knowing.

This is the **single biggest problem** in the prototype. You get one chance at a first impression, and right now the first impression is "I am a rectangle in a rectangle room and I don't know what I'm supposed to do."

### What needs to change

**A. Forced opening sequence (before player has control):**

Add a cutscene sequence triggered on `first_visit` to Alexandria Castle that does not just narrate -- it SHOWS. The cutscene manager exists. Use it:

1. Camera starts zoomed on the Theater Stage prop (the play is about to start)
2. Narration: "The kingdom of Alexandria. Tonight, the Tantalus theater troupe performs 'I Want to Be Your Canary' for Queen Brahne and Princess Garnet."
3. Camera pans to Zidane's position. Zidane speaks: "Alright, boys. We're here to put on a show... and steal a princess."
4. Player gains control. A HUD prompt appears: "Use arrow keys to move. Walk to Garnet."
5. When player reaches Garnet, the existing `garnet_intro` dialogue plays -- but extend it to 8-10 lines. This is the player's first character interaction. It needs to breathe. Garnet needs to express fear, resolve, and vulnerability. Zidane needs to be charming and cocky but also show a flicker of genuine care.
6. After dialogue, Steiner attacks. This is the **tutorial battle**: Steiner is an ally who fights as an enemy. The game freezes on each command menu option and explains it. "ATTACK deals physical damage. MAGIC uses MP for special abilities. ITEM uses consumables. DEFEND halves incoming damage."
7. After defeating Steiner (who has 50 HP in this tutorial fight), he begrudgingly joins. The game tells the player: "Steiner joined the party! Open the MENU to see your party."
8. Quest marker appears: "Escape to the Evil Forest."

This is 3-5 minutes of guided content. It costs nothing in engine terms -- it is data. But it transforms the opening from "I am lost in a rectangle" to "I am a thief who just stole a princess and I need to run."

**B. Teach one mechanic per location for the first four locations:**

| Location | Mechanic taught | How |
|---|---|---|
| Alexandria Castle | Movement, talking, menu | Opening sequence above |
| Evil Forest | Random encounters, basic combat | First random encounter has a popup: "Enemies appear randomly in dangerous areas! Defeat them to earn XP and Gil." |
| Ice Cavern | Elemental weakness | Frozen Moogle tells you: "Ice Golems are weak to fire! Try Vivi's Fire spell!" |
| Dali Village | Shops and equipment | An NPC says: "You look beaten up! Visit the shop and buy a Broadsword -- equip it from the MENU to boost Steiner's attack!" |

---

## 2. Pacing (The Rhythm is Broken)

### What happens now

The entire game is one flat pacing line: walk to location, maybe see 4 lines of dialogue, fight some identical encounters, reach next location, repeat. There is no crescendo. There is no rest. The destruction of Burmecia -- one of FF9's most devastating moments -- has the same mechanical rhythm as walking through Dali Village.

### The problem in specific terms

Look at the encounter design:

| Location | Enemies | Encounter rate |
|---|---|---|
| Evil Forest | Fang, Goblin | 15% |
| Ice Cavern | Ice Golem | 12% |
| Burmecia | Brahne Guard | 15% |
| Iifa Tree | Fang, Ice Golem | 18% |

The Iifa Tree -- a late-game dungeon that should feel like descending into hell -- has the same Fangs from the first dungeon. This is telling the player "we ran out of enemies." That breaks immersion completely.

There are **zero encounters** in 7 of 12 locations (Alexandria Castle, Lindblum, Dali Village, Cleyra, Alexandria Harbor, Outer Continent, Terra). This means large portions of the game have no gameplay tension at all. The player is just walking between text boxes.

### What needs to change

**A. Every act needs the rhythm: Town (rest) -> Field/Dungeon (tension) -> Boss (peak) -> Town (release)**

Currently the game goes:
```
Castle -> Forest -> Cavern -> Village -> City -> Ruins -> Tree -> Harbor -> Jungle -> Tree -> Planet -> Void
```

That is 12 locations with no rhythm. Here is what pacing should look like:

```
ACT 1 -- Escape and Discovery
  Alexandria Castle  [CALM - establish world, characters, stakes]
  Evil Forest        [TENSION - first real encounters, learning combat]
  Evil Forest Boss   [PEAK - Plant Brain miniboss, test the player]
  Ice Cavern         [TENSION - harder encounters, elemental puzzle]
  Ice Cavern Boss    [PEAK - Black Waltz 1, first real boss fight]
  Dali Village       [REST - shop, heal, story reveal about Vivi]
  Dali Outskirts     [TENSION - ambush by Black Waltz 3]
  Lindblum           [MAJOR REST - biggest town, shops, side content, Festival of the Hunt]

ACT 2 -- War and Loss
  Burmecia           [HEAVY TENSION - rain, destruction, constant encounters]
  Burmecia Palace    [PEAK - encounter Kuja, helplessness]
  Cleyra             [BRIEF REST then DREAD - the calm before destruction]
  Cleyra Destruction [PEAK - Odin destroys Cleyra, escape sequence]
  Alexandria Harbor  [EMOTIONAL REST - Brahne dies, Garnet mourns]

ACT 3 -- Truth and Confrontation
  Outer Continent    [EXPLORATION - new world, new encounters, shop]
  Iifa Tree          [HEAVY TENSION - dungeon with unique enemies]
  Terra              [EERIE REST - alien world, revelations, Zidane's crisis]
  Crystal World      [FINAL TENSION - hardest encounters, point of no return]
  Kuja Boss          [CLIMAX PEAK - Trance Kuja]
  Necron Boss        [ULTIMATE PEAK - final boss]
  Ending             [RELEASE - resolution, catharsis]
```

**B. Add location-appropriate enemies:**

| Location | Current enemies | What's needed |
|---|---|---|
| Evil Forest | Fang, Goblin | Add: Plant Spider (poison attack), Dendroid (plant type) |
| Ice Cavern | Ice Golem | Add: Wyerd (ice bat), Fang (reskinned as Ice Fang, ice element) |
| Burmecia | Brahne Guard | Add: Black Mage (Type A) -- this is thematic, the very weapons being used against Burmecia |
| Cleyra | None | Add: Alexandrian Soldier, Sand Scorpion (during invasion) |
| Outer Continent | None | Add: Gnoll, Cactuar, Basilisk -- this is a wild continent, it should have wild things |
| Iifa Tree | Fang, Ice Golem (wrong!) | Replace entirely: Zombie, Dracozombie, Mistodon -- undead creatures corrupted by the soul flow |
| Terra | None (boss only) | Add: Genome Drone, Iron Man -- Terra's automated defenses |
| Crystal World | None (bosses only) | Add: Lich, Kraken, Malaris -- the four fiends guarding the path to the Crystal |

This is 14 new enemies. Each needs: id, name, stats, 0-2 abilities, weakness, resist, drops, XP, gil. That is approximately 2 hours of data authoring. It transforms the late game from "same Fangs again" to "what the hell is that thing."

**C. Add at least one mini-boss per act break:**

The game has bosses only at quest trigger points. But FF9 (and every good JRPG) uses mini-bosses to punctuate dungeon exploration and create "oh no" moments.

| Location | Mini-boss | Why it matters |
|---|---|---|
| Evil Forest | Plant Brain (HP 200) | First real test. Can the player use Vivi's Fire? |
| Ice Cavern exit | Black Waltz 1 (HP 180) | First boss with abilities. Teaches "this enemy can heal, focus fire" |
| Dali outskirts | Black Waltz 3 (exists, HP 280) | Great -- but currently has no location to trigger in. Give it a proper encounter event when leaving Dali |
| Cleyra Cathedral | Alexandrian General (HP 350) | The invasion has a face. Someone who orders the destruction |
| Iifa Tree Heart | Soulcage (HP 500) | The corrupted tree spirit. Stopping the Mist means fighting its source |

---

## 3. Emotional Beats (The Story Has No Weight)

### What happens now

There are 4 dialogue sequences in the game data:
1. `garnet_intro` -- 4 lines. Zidane meets Garnet.
2. `vivi_factory` -- 4 lines. Vivi discovers he's manufactured.
3. `freya_burmecia` -- 3 lines. Freya sees her destroyed home.
4. `terra_revelation` -- 4 lines. Garland reveals Zidane's origin.

That is 15 lines of dialogue for the entire emotional arc of the game.

FF9's script has approximately 3,000 lines of dialogue. I am not asking for 3,000. But 15 is a catastrophe. The most devastating moments in the game -- Vivi's existential crisis, Burmecia's fall, Garnet cutting her hair, Zidane's "You're Not Alone" breakdown, Kuja's final act of grace -- each of these requires 15+ lines MINIMUM to land.

### What a player feels

Nothing. You cannot feel sadness from 3 lines. You cannot feel triumph from 4 lines. Emotional investment requires **time** -- the player needs to sit with a character's pain, hear them struggle to articulate it, watch other characters react. Right now, Vivi discovers he's a weapon and the game immediately moves on. That is not a story beat. That is a Wikipedia summary.

### What needs to change

**A. Every story beat needs a full dialogue sequence (8-20 lines minimum):**

Here are the 11 scenes that MUST exist with full dialogue:

| Scene | Location | Lines needed | Emotional target |
|---|---|---|---|
| Zidane meets Garnet | Alexandria Castle | 10-12 | Charm, intrigue, hint of danger |
| Steiner confrontation | Alexandria Castle | 8-10 | Comedy, tension, establishes Steiner's arc |
| Vivi's identity crisis | Dali Village | 15-20 | Sadness, compassion, Zidane's warmth |
| Lindblum war council | Lindblum | 10-12 | Dread, stakes, world is bigger than you thought |
| Freya's homecoming | Burmecia | 12-15 | Grief, rage, helplessness |
| Cleyra destruction | Cleyra | 10-12 | Horror, loss, determination |
| Brahne's death | Alexandria Harbor | 12-15 | Complex grief -- she was a villain but also Garnet's mother |
| Garnet cuts her hair | Alexandria Harbor | 8-10 | Transformation, resolve, player feels proud of her |
| Zidane's breakdown (You're Not Alone) | Terra | 20-25 | Despair, then hope. Each party member speaks. The most important scene in the game |
| Kuja's last stand | Crystal World | 12-15 | Pity for the villain, understanding his fear |
| Ending | Post-Crystal World | 15-20 | Reunion, joy, tears, "I want to come home to you" |

That is approximately 140-170 lines of dialogue. Each line is one JSON object with a speaker, text, and expression field. This is the single highest-ROI investment possible -- it turns colored rectangles reading text into characters you care about.

**B. Add party banter dialogues (triggered by exploration, not quests):**

Right now, ambient NPCs speak. Party members are silent outside of 4 cutscenes. In every good JRPG, your party talks to each other as you explore. This is how you build the bonds that make the climax hit.

Add 2-3 "party_banter" dialogues per location, triggered when the player walks near certain props:

- Evil Forest, near bones prop: Steiner says "What manner of creature could do this?" Vivi says "I-I don't want to end up like that..." Zidane says "Stick close, Vivi. I've got your back."
- Ice Cavern, near frozen pool: Garnet says "It's beautiful..." Zidane says "Yeah? Wait till I show you the view from Lindblum's airship docks." Steiner says "Stop flirting with the princess, you scoundrel!"
- Lindblum, near airship: Vivi says "Wow... it's so big!" Zidane says "This is where I grew up. Well, sort of. Tantalus moved around a lot." Garnet says "You must have seen so many places." Zidane says "Yeah. But none of them ever felt like home."
- Burmecia, near broken weapon: Freya picks up the spear silently. No one speaks for a beat. Then Zidane says "...We'll make this right, Freya." Freya says "...Thank you."

These are 3-5 lines each. 30-40 extra lines across the game. The emotional ROI is enormous because they happen during GAMEPLAY, not in cutscenes. The player feels like their party is alive.

---

## 4. World Building (The NPCs Are Wallpaper)

### What happens now

Each location has 1-5 ambient NPCs. Each says exactly one line. That line never changes regardless of what is happening in the story.

The Dock Worker in Alexandria Harbor says "The fleet's been coming and going nonstop" whether you visit during Act 1 (before the war) or Act 3 (after the war is over and the fleet is destroyed). The Excited Child in Alexandria says "I wanna see the play!" whether you're there for the play or returning after the entire kingdom has been through a war.

### What a player feels

The world is fake. NPCs are furniture that speaks. This is one of the most common failures in indie JRPGs and the fix is straightforward.

### What needs to change

**A. Ambient NPCs need quest-state dialogue, just like story NPCs already have:**

The data schema already supports `dialogues_by_quest` on story NPCs. Ambient NPCs currently only have a single `dialogue` string. The engine needs a small modification: ambient NPCs should support the same `dialogues_by_quest` format as story NPCs.

Then update NPC dialogue for at least 3 quest states per NPC:

**Example -- Alexandria Castle NPCs:**

| NPC | Default (Act 1) | After Burmecia falls (Act 2) | After Brahne dies (Act 3) |
|---|---|---|---|
| Castle Guard | "Welcome to Alexandria Castle. The play begins at sunset." | "The kingdom mourns. Queen Brahne's armies have fallen." | "Long live Queen Garnet. May she bring peace." |
| Noble Lady | "Have you heard? Tantalus is performing tonight!" | "I can't believe it... Burmecia, Cleyra... destroyed by our own queen." | "The young queen carries a heavy burden. I pray for her." |
| Excited Child | "I wanna see the play!" | "Mama says I can't go outside anymore. She says there's a war." | "The new queen is pretty! Is she nice?" |
| Merchant | "Finest potions in Alexandria!" | "Business is bad. Nobody's buying when there's war." | "Maybe now that the war's over, trade will pick up..." |

This is the most tedious content to write and the most transformative. 3 dialogue states across ~25 ambient NPCs = 75 extra lines. The player starts to feel like the world reacts to what they're doing.

**B. Add 2-3 more ambient NPCs per town:**

Towns feel empty with 3-5 NPCs. Target 6-8 per town. Focus on:
- A child (shows innocence, makes stakes feel real)
- A merchant/worker (grounds the economy)
- A gossip/storyteller (delivers lore naturally)
- A sad/worried NPC (foreshadows coming danger)
- A couple or family (makes the world feel lived-in)

---

## 5. Progression Satisfaction (Leveling Up Feels Like Nothing)

### What happens now

Characters level from 1 to ~30. They gain stats on level up. The player sees a "Victory" screen with XP and Gil earned. There is no fanfare. There is no notification of what changed. The player has no idea whether their Vivi at level 12 is stronger than at level 11 or by how much.

Equipment exists: 3 weapons, 3 armor pieces. That is a total of 6 gear items for the entire game. In a game that spans 12 locations and 3 acts.

### What a player feels

No sense of growth. Progression is the core reward loop of JRPGs -- you fight battles to get stronger so you can fight harder battles. If getting stronger doesn't FEEL like anything, the player has no reason to fight.

### What needs to change

**A. Level-up notification:**

When a character levels up, the victory screen should show:

```
Zidane reached Level 6!
  HP: 105 -> 118 (+13)
  MP: 35 -> 39 (+4)
  STR: 12 -> 13 (+1)
  *** New ability: Tidal Flame! ***
```

The `*** New ability ***` line is critical. In the current data, abilities are gated by `learn_level`. But the player is never told this. They have no idea Vivi learns Firaga at level 20. This means they have no aspiration -- nothing to grind toward.

Display a list of upcoming abilities on the character status screen: "Next ability: Firaga (Lv.20)". Now the player has a goal.

**B. Triple the equipment catalog:**

Current: 3 weapons, 3 armor, 4 consumables = 10 items total.

Target: 8-10 weapons (2-3 per act), 6-8 armor (2 per act), 3-4 accessories, 6 consumables.

| Act | Weapon examples | Armor examples |
|---|---|---|
| Act 1 | Dagger (start), Broadsword (Dali), Iron Sword (Lindblum) | Leather Hat (Ice Cavern), Leather Armor (start), Chain Mail (Lindblum) |
| Act 2 | Mythril Sword (Burmecia), Flame Saber (Cleyra), Coral Sword (Harbor) | Mythril Helm (Burmecia), Mythril Mail (Cleyra), Gold Armor (Harbor) |
| Act 3 | Diamond Sword (Outer Continent), Rune Blade (Terra), Ultima Weapon (Crystal World, hidden) | Platinum Helm (Outer Continent), Platinum Mail (Terra), Genji Armor (Crystal World, hidden) |

Add **accessories** as a new equipment slot: Power Belt (+STR), Magic Ring (+MAG), Speed Boots (+SPD), Rebirth Ring (auto-revive). These are the items that create build diversity and make players excited to explore.

**C. Make treasures worthwhile:**

Currently, hidden treasures contain Potions, Ethers, and Phoenix Downs. These are consumables the player can buy. There is no reason to explore.

Hidden treasures should contain things you CANNOT buy:
- Unique accessories (see above)
- Character-specific weapons
- Key items that unlock side content
- Items that reference FF9 lore ("Garnet's Pendant -- a keepsake from her true mother")

---

## 6. Moment-to-Moment Gameplay (Walking is Dead Time)

### What happens now

The player holds a direction key. Their colored rectangle moves across a flat colored room. They may bump into props (also colored rectangles). If they are in a dungeon, they may get a random encounter. If they are in a town, they walk to an NPC, press interact, read one line, and walk to the next NPC.

### What a player feels

Boredom. There is nothing to do between point A and point B. In a finished JRPG, walking around is when the player is:
- Searching for hidden items
- Reading environmental storytelling (signs, books, carvings)
- Triggering optional dialogue
- Noticing details that foreshadow the plot
- Deciding where to go next based on visual cues

Currently none of this happens. The locations are flat planes. There is no reason to explore because everything is visible at once.

### What needs to change

**A. Sub-areas (the doc at `06_what_makes_a_complete_game.md` already identifies this):**

Every major location should be 3-5 rooms instead of 1. This is the single biggest change to exploration feel:

| Current location | Minimum rooms needed |
|---|---|
| Alexandria Castle | Gate, Courtyard, Theater, Castle Interior, Garden |
| Evil Forest | Entrance, Twisted Path, Clearing (save point), Deep Forest, Plant Brain's Lair |
| Ice Cavern | Entrance, Frozen Passage, Crystal Chamber, Exit |
| Dali Village | Village Road, Village Square, Underground Factory |
| Lindblum | City Gates, Market, Theater District, Airship Docks, Castle |
| Burmecia | Ruined Gate, Fallen Avenue, Palace Approach, Royal Chamber |
| Crystal World | Void Threshold, Memory Lane, Kuja's Platform, The Crystal |

That takes the game from 12 rooms to ~40 rooms. Each room transition is a moment of anticipation. Each new room is a tiny discovery. The player stops feeling like they are in a tech demo and starts feeling like they are in a place.

**B. Interactable props:**

Props exist but are purely visual. Add `interactable: true` and `interact_text` fields to select props:

- Alexandria fountain: "Crystal clear water. Garnet says it was her favorite place as a child."
- Evil Forest bones: "The remains of an adventurer. A torn note reads: 'Fire works against the plants. If you're reading this, I didn't make it. Good luck.'" (teaches fire weakness AND tells an environmental story)
- Dali trapdoor: "A suspicious hatch. You can hear mechanical clanking below." (foreshadows the factory quest)
- Burmecia broken weapon: "A Burmecian soldier's spear, planted in the ground like a grave marker."
- Terra genome pod: "An empty vessel shaped like a person. The face looks... like Zidane's."

10-15 interactable props across the game. 10 minutes of writing. Transforms exploration from passive walking to active discovery.

**C. Hidden paths and optional rooms:**

Every dungeon should have at least one hidden path that leads to a reward:

- Evil Forest: a vine-covered passage that leads to a dead-end with a unique accessory
- Ice Cavern: a cracked ice wall (interact to break) revealing a hidden chamber with an Ether and a frozen treasure
- Iifa Tree: a side root that leads to the Soulcage mini-boss and a rare item
- Crystal World: a memory fragment interaction that shows a flashback of Zidane's childhood on Terra

---

## 7. Combat Depth (Attack, Attack, Attack, Win)

### What happens now

ATB system with Attack, Magic, Item, Defend, Flee. The player has access to:

| Character | Useful abilities | Strategic role |
|---|---|---|
| Zidane | Steal (0 power), Tidal Flame (fire) | Steal is useless (enemies have 0-1 drops). Tidal Flame is just "fire attack" |
| Garnet | Cure, Shiva (ice), Bahamut | Healer and AoE. The only real strategic role |
| Vivi | Fire, Blizzard, Thunder, Firaga, Flare | Hit weakness. This is the only strategic decision in combat |
| Steiner | Power Break, Sword Art, Shock | Just big damage. No strategy |
| Freya | Jump, Reis's Wind (regen), Dragon Breath | Jump is slow single-target. Reis's Wind is the one interesting ability |

The dominant strategy is: Vivi hits weakness, Garnet heals, everyone else presses Attack. This is correct for 100% of encounters.

There are no status effects. No buffs or debuffs (Power Break claims to lower strength but this is not implemented in the damage formula). No multi-phase boss fights. No "the enemy is about to use a big attack, defend NOW" telegraphing.

### What a player feels

Combat starts exciting (the ATB system is novel) and becomes tedious by location 3. By the time the player reaches Burmecia, they are mashing Attack and wishing encounters would end faster. This is the death of a JRPG.

### What needs to change

**A. Give enemies abilities that force the player to react:**

| Enemy | Current abilities | Needed abilities |
|---|---|---|
| Fang | None | Howl (raises own ATK for 3 turns) -- teaches player to use Power Break |
| Goblin | None | Steal Gil (takes 10-30 gil from party) -- motivates killing goblins fast |
| Ice Golem | Ice Punch (just damage) | Ice Armor (defense up, weak to fire removes it) -- teaches targeting weaknesses |
| Brahne Guard | None | Shield Wall (Defend + counter next attack) -- teaches player when NOT to attack |
| Garland | Wave Cannon, Stop | Add: Judgment (charges for 1 turn, hits all for massive damage) -- teaches Defend timing |
| Trance Kuja | Flare Star, Ultima | Add: phase 2 at 50% HP where he casts Shell (halves magic damage) -- forces physical attackers to step up |
| Necron | Grand Cross, Neutron Ring | Add: Countdown (places 5-turn death timer on one character, must be Cured) -- creates urgency |

**B. Make Steal valuable:**

Currently, enemy drop tables have 0-1 items with 10-30% chance. Steal has 0 power, meaning it does nothing except occasionally get a Potion. Zidane's signature ability is worthless.

Fix: Every boss should have a rare steal (20% chance) that is a unique item unavailable anywhere else:

| Boss | Rare steal |
|---|---|
| Black Waltz 3 | Lightning Staff (Vivi weapon, +MAG, Thunder boost) |
| Brahne Guard captain | Mythril Gloves (accessory, +DEF) |
| Garland | Dark Matter (key item, unlocks optional dialogue in Crystal World) |
| Trance Kuja | Ether x3 |
| Necron | Rebirth Ring (accessory, auto-revive once) |

Now Zidane's Steal creates a strategic dilemma every boss fight: do I spend turns stealing for a unique reward, or do I deal damage and end the fight faster?

**C. Add Trance (limit break system):**

FF9's signature combat mechanic. Each character has a Trance gauge that fills as they take damage. When full, they transform temporarily with enhanced abilities. This is the "hype moment" of combat -- the turn where the player feels powerful.

| Character | Trance ability | Effect |
|---|---|---|
| Zidane | Dyne | All single-target skills become AoE |
| Vivi | Double Black | Cast two spells per turn |
| Steiner | Trance Sword Art | Physical attack that hits all enemies |
| Garnet | Eidolon Full Power | Summon deals 1.5x damage |
| Freya | Dragon's Crest | Fixed 999 damage ignoring defense |

This is a significant engine addition. But without it, combat has no crescendo. Every fight feels the same from turn 1 to the last turn.

---

## 8. Story Delivery (Reading vs. Experiencing)

### What happens now

The story is delivered through:
- 4 dialogue sequences (15 total lines)
- 12 `on_enter` narration texts (one per location)
- Quest-state NPC dialogue changes

The cutscene system exists (`cutscene_manager.gd`) but I see no cutscene data in the JSON files. Cutscenes are referenced in the feature list ("7 cutscenes") but the data files contain zero cutscene definitions.

### The core problem

Text narration tells. Cutscenes show. Dialogue makes you feel. The game is currently 95% telling and 5% feeling.

The `on_enter` narration texts are actually well-written. "Rain falls without end on the ruins of Burmecia..." -- that is good prose. But it is a paragraph the player reads once and then never sees again. It does not make them FEEL the rain.

### What needs to change

**A. Convert key story moments from dialogue to cutscenes:**

The cutscene manager supports camera movement and dialogue sequences. Use it for the 5 most important moments:

1. **The Kidnapping** (Alexandria): Camera follows Zidane sneaking through the castle. Quick cuts between Zidane/Garnet and Brahne in the audience. The escape has urgency.

2. **Vivi's Discovery** (Dali): Camera slowly pans down through the trapdoor, into the factory. Rows of Black Mage bodies. Camera holds on Vivi's face. Long pause. Then his line: "Am I... am I just a weapon too?"

3. **Burmecia Falls** (Burmecia): Camera pans across the destroyed city. Rain. Fallen soldiers. Camera finds Freya standing alone in the rain. She doesn't speak for 3 seconds. Then: "My home..."

4. **You're Not Alone** (Terra): Zidane pushes everyone away. Camera follows him walking alone through Terra's empty streets. One by one, party members find him. Each says one line. "I'm coming with you." "You don't have to do this alone." The camera pulls out to show all of them standing together.

5. **The Ending**: Zidane returns to Alexandria. Garnet runs through the crowd. The camera holds on their reunion. No dialogue needed -- just the moment.

**B. Add "reaction" dialogues after every boss fight:**

After every boss, before the victory screen fades, there should be 3-5 lines of party reaction:

- After Black Waltz 3: Vivi says "He was... like me. But so angry." Zidane says "You're nothing like him, Vivi."
- After Garland: Zidane says "I know who I am now. I'm not his puppet." Freya says "None of us are what we were made to be."
- After Trance Kuja: Kuja says "Why... why do you fight so hard?" Zidane says "Because I have people to go home to."

---

## 9. Missing Systems (What the Engine Needs)

### Currently missing, HIGH priority:

| System | Why it matters | Effort estimate |
|---|---|---|
| Title screen | First thing the player sees. Sets tone. No title = looks unfinished | Low (static UI scene) |
| Game Over screen | Dying currently does... nothing? Goes back to exploration? | Low (UI + retry/load option) |
| Ending sequence | Beating the final boss needs a payoff | Medium (cutscene + credits) |
| Inn/rest mechanic | Players need to heal without burning consumable items | Low (dialogue trigger -> full heal for gil) |
| Story gating | Player can walk to Crystal World at level 1 right now | Medium (exit requires quest flag) |

### Currently missing, MEDIUM priority:

| System | Why it matters |
|---|---|
| Party join events | All 5 party members are available from the start. They should join at story beats (Garnet in Alexandria, Vivi in Evil Forest, Steiner in Alexandria, Freya in Burmecia) |
| Damage numbers | Floating damage text in battle gives immediate feedback on whether an attack was effective |
| Status effects | Poison, Blind, Haste, Protect -- these create combat variety |
| Equipment comparison | When buying gear, show stat delta ("STR 12 -> 15") |
| Battle backgrounds | Currently one background. Different biomes should have different backgrounds |

---

## 10. The Side Quest Problem

### What exists

One side quest: "Fratley's Memory." Talk to Freya in Burmecia, search the ruins, get Dragon Mail.

### What's missing

Side quests are how players feel ownership of the world. Main quests say "go here." Side quests say "you chose to care about this." One side quest for a 5-8 hour game is criminal.

### Minimum side quests needed:

| Quest | Location | Reward | Emotional purpose |
|---|---|---|---|
| Fratley's Memory | Burmecia | Dragon Mail | Freya's personal story, hope in ruin |
| Vivi's Letter | Dali Village | Black Mage Robe (+MAG, +spirit) | Vivi writes a letter to the Black Mages, comes to terms with being manufactured |
| Steiner's Honor | Alexandria Castle | Excalibur (weapon) | Steiner confronts a corrupt Knight of Pluto, chooses loyalty to Garnet over blind duty |
| Garnet's Pendant | Alexandria Harbor | Healing Light (ability, full party heal) | Garnet finds her true mother's pendant, accepts both her identities |
| Zidane's Tantalus Roots | Lindblum | Thief Gloves (accessory, Steal always succeeds) | Zidane returns to the Tantalus hideout, remembers where he came from |
| The Chocobo Forest | Outer Continent | Gold Chocobo (fast travel) | Pure exploration reward, the classic FF optional content |
| Mognet Letters | Everywhere | Ribbon (accessory, protects all status) | Deliver letters between Moogles. Light, funny, spans the whole game |

Seven side quests. Each requires: quest JSON entry, 1-2 dialogue sequences, 1 unique reward item. The game goes from "linear corridor" to "I wonder what I missed."

---

## 11. The Numbers

Here is a cold count of what exists versus what a minimum viable JRPG needs:

| Content | Current | Minimum target | Gap |
|---|---|---|---|
| Locations (rooms) | 12 | 35-40 | 23-28 rooms |
| Dialogue sequences | 4 | 25-30 | 21-26 sequences |
| Total dialogue lines | 15 | 200-250 | 185-235 lines |
| Enemies (normal) | 5 | 15-20 | 10-15 enemies |
| Bosses | 4 | 8-10 | 4-6 bosses |
| Items (equipment) | 6 | 20-25 | 14-19 items |
| Items (consumable) | 4 | 8-10 | 4-6 items |
| Quests (main) | 7 | 7 | OK |
| Quests (side) | 1 | 5-7 | 4-6 quests |
| Cutscenes | 0 data | 5-7 | 5-7 cutscenes |
| Party banter dialogues | 0 | 15-20 | 15-20 |
| NPC dialogue states | 1 per NPC | 3 per NPC | ~50 extra lines |

---

## 12. Priority Order (What to Do First)

If I had to ship this game in its current engine with no engine changes, here is what I would do, in order:

### Week 1: Frame the experience
1. Add title screen data (game title, "New Game" / "Continue")
2. Add game over screen
3. Add ending cutscene and credits
4. Add story gating (lock exits behind quest completion)
5. Add party join events (characters join at story-appropriate moments)

### Week 2: Make the player care
6. Expand `garnet_intro` to 10-12 lines
7. Write the full "You're Not Alone" scene (20+ lines)
8. Write Brahne's death scene (12-15 lines)
9. Write post-boss reaction dialogues (3-5 lines each, 5 bosses)
10. Write 15-20 party banter dialogues (3-5 lines each)

### Week 3: Make the world feel real
11. Add quest-state dialogue to all ambient NPCs (3 states each)
12. Add 10-15 interactable props with environmental text
13. Add 2-3 ambient NPCs per town to reach 6-8 per town
14. Write the opening tutorial sequence for Alexandria Castle

### Week 4: Make combat interesting
15. Add 10-15 new enemies with location-appropriate designs
16. Add abilities to existing enemies (at least 1 per enemy)
17. Add 4-6 mini-bosses
18. Add 14-19 new equipment items
19. Add 5-7 side quests with unique rewards

### Week 5: Make exploration worthwhile
20. Split Alexandria Castle into 4-5 sub-rooms
21. Split Evil Forest into 4 sub-rooms
22. Split remaining locations into 2-3 sub-rooms each
23. Add hidden treasures with unique, non-purchasable items
24. Add hidden paths in dungeons

---

## Final Verdict

The engine is solid. The data architecture is clean. The location JSON schema is rich enough to support a real game. The atmospheric descriptions are genuinely evocative. The art bible is production-ready.

But the game data is a sketch, not a painting. You have built a canvas and squeezed out the paint. Now you need to actually paint.

The core issue is not technical. It is a content volume problem and a pacing design problem. Both are solvable with data authoring alone -- no engine rewrites needed. The JSON schema supports everything I have described. The engine scripts handle combat, dialogue, quests, cutscenes, and location rendering.

What is missing is 200+ lines of dialogue, 15+ enemies, 20+ items, 30+ rooms, and the connective tissue that turns a tech demo into an experience that makes a player feel something when Vivi asks "Am I just a weapon?" and feel something different when Zidane says "You're not alone."

That is what separates a game from a game engine. Build the data. Write the words. The bones are good. Now give them a soul.
