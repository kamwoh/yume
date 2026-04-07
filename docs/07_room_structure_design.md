# Room Structure Design: FF9 Multi-Room Locations

## The Problem

Every location is a single 900x700 flat rectangle. The player enters from one side, sees everything at once, and walks to the other side. There is no spatial depth, no discovery, no sense of place. A castle feels the same as a forest feels the same as an alien world.

## The Solution

Split each location into multiple rooms (separate JSON files). Each room is its own screen with its own layout, props, NPCs, and atmosphere. Exits between rooms create flow, pacing, and the feeling of exploring a real place.

## How It Works (No Engine Changes)

The engine already loads locations by ID from `data/locations/<id>.json` and transitions between them via exit targets. Multi-room is just **more JSON files with exits pointing to each other**.

**Naming convention:** `<region>_<room>` (e.g., `alexandria_castle_courtyard`, `evil_forest_clearing`)

**Key rule:** Inter-region exits (going from one region to the next) only exist on specific rooms, not all rooms. This forces the player to traverse the space.

**The `connections` array** in each JSON lists all rooms reachable from that room (both intra-region and inter-region). The `exits` array defines the physical exit markers on screen.

---

## Region 1: Alexandria Castle (Town, Act 1 Start)

**Theme:** Spectacle and secrets. A grand castle buzzing with theater night excitement, hiding royal intrigue.

**Identity:** Warm torchlight, stone walls, red and gold banners, festive crowds.

### Rooms: 4

| # | Room ID | Name | Type | Size |
|---|---------|------|------|------|
| 1 | `alexandria_castle_gate` | Castle Gate | Entry plaza | 900x600 |
| 2 | `alexandria_castle_courtyard` | Courtyard & Theater | Main hub | 1000x700 |
| 3 | `alexandria_castle_interior` | Castle Interior | Corridor/halls | 800x700 |
| 4 | `alexandria_castle_garden` | Royal Garden | Secret area | 700x600 |

### Room Details

**Room 1: Castle Gate** (entry point, `is_starting_location: true`)
- Purpose: First screen the player sees. Establishes scale and mood.
- Entrance: South edge (player walks in from below)
- Props: Grand stone archway, twin banners, torches, guard towers, sign reading "Alexandria Castle"
- NPCs: 2 patrolling guards, 1 excited child, 1 merchant (sells potions)
- Exits:
  - North -> `alexandria_castle_courtyard` (main path, wide archway)
  - East -> `alexandria_harbor` (side path, "To the Harbor")
- Treasures: 1 visible Potion (behind barrel stack near east wall)
- On enter: First-visit narration about arriving at Alexandria

**Room 2: Courtyard & Theater** (story hub)
- Purpose: Central gathering space. The play is happening here. Garnet and Steiner are here.
- Entrance: South edge (from gate)
- Props: Fountain (center landmark), theater stage (west side), audience benches, torches, vendor stalls
- Story NPCs: Garnet (near stage), Steiner (following Garnet), Queen Brahne (on balcony, north)
- Ambient NPCs: Noble Lady, Theater Patron, Festival Goer
- Exits:
  - South -> `alexandria_castle_gate`
  - North -> `alexandria_castle_interior` (guarded door, "To the Castle")
  - East -> `alexandria_castle_garden` (half-hidden path behind fountain)
- Treasures: None (story focus room)
- Events: Quest dialogue triggers for `kidnap_princess`

**Room 3: Castle Interior** (exploration/story)
- Purpose: Deeper castle halls. Feels restricted and important. Leads to Evil Forest escape.
- Entrance: South edge (from courtyard)
- Props: Stone pillars, tapestries, armor stands, candelabras, locked door (flavor), red carpet
- NPCs: 1 guard (blocks west corridor), 1 Old Scholar (lore about Mist and Iifa Tree)
- Exits:
  - South -> `alexandria_castle_courtyard`
  - North -> `evil_forest` (escape route, "Through the Secret Passage")
- Treasures: 1 hidden Phoenix Down (behind armor stand), 1 visible Ether (on table in alcove)
- Events: After talking to Garnet, guard lets you pass north

**Room 4: Royal Garden** (secret/reward)
- Purpose: Optional side area. Peaceful, beautiful, has a good treasure.
- Entrance: West edge (from courtyard)
- Props: Trees, flower beds, bench, small pond, rose trellis, stone path
- NPCs: 1 Garden Moogle (save point, hints)
- Exits:
  - West -> `alexandria_castle_courtyard`
- Treasures: 1 hidden Silk Shirt (behind the rose trellis), 1 visible Potion
- Atmosphere: Quieter music, no crowds. Contrast with the bustling courtyard.

### Player Flow
```
                    [Evil Forest]
                         ^
                         |
  [Harbor] <-- [Gate] --> [Courtyard] --> [Interior]
                              |
                              v
                          [Garden]*
                        (* optional)
```
Natural path: Gate -> Courtyard (talk to NPCs, find Garnet) -> Interior (escape) -> Evil Forest.
Explorer path: Gate -> Courtyard -> Garden (treasure) -> Courtyard -> Interior.

---

## Region 2: Evil Forest (Dungeon, Act 1)

**Theme:** Hostile nature. The forest is alive and doesn't want you here.

**Identity:** Dark greens and blacks, bioluminescent mushrooms, twisted trees, mist, oppressive.

### Rooms: 4

| # | Room ID | Name | Type | Size |
|---|---------|------|------|------|
| 1 | `evil_forest_edge` | Forest Edge | Entry | 900x600 |
| 2 | `evil_forest_path` | Twisted Path | Corridor | 800x700 |
| 3 | `evil_forest_clearing` | Fungal Clearing | Branch/reward | 700x600 |
| 4 | `evil_forest_deep` | Deep Forest | Exit/boss area | 900x700 |

### Room Details

**Room 1: Forest Edge** (entry)
- Purpose: Transition from castle. Still some light filtering in. Danger ramps up.
- Entrance: West edge (from Alexandria)
- Props: Gnarled trees, vines, first mushrooms, fallen log, torn cloth on branch
- NPCs: Lost Traveler ("Turn back!")
- Encounters: Fang x1 (encounter rate 0.10, low -- easing in)
- Exits:
  - West -> `alexandria_castle_interior` (back, but blocked after petrification event)
  - East -> `evil_forest_path`
- Treasures: 1 visible Potion

**Room 2: Twisted Path** (corridor with branch)
- Purpose: Disorientation. Paths wind. Player makes a choice: forward or detour.
- Props: Dense vines, web across path, bones on ground, rocks, mist thickening
- Encounters: Fang + Goblin (rate 0.15)
- Exits:
  - West -> `evil_forest_edge`
  - East -> `evil_forest_deep` (main path continues)
  - South -> `evil_forest_clearing` (side path, less obvious -- narrower gap in trees)
- Treasures: None (the detour has the reward)

**Room 3: Fungal Clearing** (optional, reward)
- Purpose: Dead end with treasure. Eerie beauty. The mushrooms glow brighter here.
- Props: Giant bioluminescent mushrooms (5+), fungal ring on ground, skeleton with pack, still pool reflecting glow
- Encounters: Goblin x2 (rate 0.12)
- Exits:
  - North -> `evil_forest_path` (only way out)
- Treasures: 1 visible Ether (on skeleton), 1 hidden Leather Wrist (inside hollow mushroom)
- Atmosphere: Slightly different music cue -- more ambient, less threatening. The beauty-before-danger effect.

**Room 4: Deep Forest** (climax)
- Purpose: The forest is fully alive here. Exit ahead. This is where Plant Brain lurks in the original -- here, the final push before Ice Cavern.
- Props: Moving vines (flavor), web cocoons, crushed trees, exit visible in distance (light at end)
- Encounters: Fang + Goblin (rate 0.18, highest)
- Exits:
  - West -> `evil_forest_path`
  - East -> `ice_cavern_entrance` (exit to Ice Cavern, light ahead)
- Treasures: 1 hidden Eye Drops (in web cocoon)
- Events: On first enter, narration about the forest closing in behind you

### Player Flow
```
[Alexandria] --> [Edge] --> [Path] --> [Deep Forest] --> [Ice Cavern]
                              |
                              v
                          [Clearing]*
                        (* optional dead-end)
```
Linear with one optional branch. Perfect for first dungeon -- teaches the player that detours have rewards.

---

## Region 3: Ice Cavern (Dungeon, Act 1)

**Theme:** Beauty and danger. Crystalline ice that can kill you.

**Identity:** Blues and whites, prismatic light, icicles, frozen pools, silence broken by cracking ice.

### Rooms: 4

| # | Room ID | Name | Type | Size |
|---|---------|------|------|------|
| 1 | `ice_cavern_entrance` | Cavern Mouth | Entry | 800x600 |
| 2 | `ice_cavern_passage` | Frozen Passage | Corridor | 800x700 |
| 3 | `ice_cavern_crystal` | Crystal Chamber | Puzzle/hub | 900x700 |
| 4 | `ice_cavern_exit` | Deep Freeze | Boss/exit | 800x600 |

### Room Details

**Room 1: Cavern Mouth** (entry)
- Purpose: Cold hits immediately. Transition from green Evil Forest to ice blue.
- Props: Icicles at entrance, snow piles, ice-covered rocks, frozen moss
- NPCs: None
- Encounters: Ice Golem x1 (rate 0.10)
- Exits:
  - West -> `evil_forest_deep`
  - North -> `ice_cavern_passage`
- Treasures: 1 visible Potion (in snow pile)

**Room 2: Frozen Passage** (corridor)
- Purpose: Narrow, claustrophobic. Ice walls close in. Icicles drip.
- Props: Narrow ice walls, frozen waterfall on one side, ice pillars, frozen vine
- Encounters: Ice Golem x1-2 (rate 0.12)
- Exits:
  - South -> `ice_cavern_entrance`
  - North -> `ice_cavern_crystal`
- Treasures: 1 hidden Ether (behind frozen waterfall)

**Room 3: Crystal Chamber** (hub/moment of awe)
- Purpose: The cavern opens up into something stunning. Giant ice crystals. Frozen Moogle is here. Two paths forward -- one obvious, one hidden.
- Props: Massive glowing ice crystals (center), frozen pool, ice arches, prismatic light effect (bright ambient)
- NPCs: Frozen Moogle (save/hint: "The golems guard the exit")
- Encounters: Ice Golem x2 (rate 0.15)
- Exits:
  - South -> `ice_cavern_passage`
  - East -> `ice_cavern_exit` (visible, guarded feel)
  - West -> dead end within the room (ice wall with hidden treasure behind it)
- Treasures: 1 visible Phoenix Down (on ice pedestal), 1 hidden Leather Hat (west ice wall alcove)

**Room 4: Deep Freeze** (climax/exit)
- Purpose: Coldest room. The exit is visible but the encounter rate spikes. Boss-like difficulty.
- Props: Ice throne (flavor), frozen skeleton reaching for exit, massive icicle overhead, exit light
- Encounters: Ice Golem x2 (rate 0.20)
- Exits:
  - West -> `ice_cavern_crystal`
  - North -> `dali_village_road` (exit to Dali, warm light ahead)
- Treasures: 1 hidden Ether (near frozen skeleton)
- Events: First enter narration -- "The cold is overwhelming. You can see daylight ahead."

### Player Flow
```
[Evil Forest] --> [Mouth] --> [Passage] --> [Crystal Chamber] --> [Deep Freeze] --> [Dali]
```
Mostly linear. Crystal Chamber is the "wow" room and serves as the midpoint breather (Moogle save).

---

## Region 4: Dali Village (Town, Act 1)

**Theme:** False peace. Pastoral beauty hiding an underground horror.

**Identity:** Green fields, windmills, warm sunlight, thatched roofs -- but listen for the clanging below.

### Rooms: 4

| # | Room ID | Name | Type | Size |
|---|---------|------|------|------|
| 1 | `dali_village_road` | Village Road | Entry | 900x600 |
| 2 | `dali_village_square` | Village Square | Hub/shop | 900x700 |
| 3 | `dali_village_farm` | Windmill Hill | Side area | 800x600 |
| 4 | `dali_village_underground` | Underground Factory | Story reveal | 800x600 |

### Room Details

**Room 1: Village Road** (entry)
- Purpose: Arrival. Warm after the ice cavern. Idyllic.
- Props: Dirt road, fence posts, trees, flower patches, sign "Welcome to Dali"
- NPCs: Nervous Boy ("Don't go underground!")
- Exits:
  - West -> `ice_cavern_exit`
  - East -> `dali_village_square`
- Treasures: None
- Events: First-visit narration about the peaceful village

**Room 2: Village Square** (hub)
- Purpose: Main interaction space. Inn, item shop, well (leads underground).
- Props: Village well (center landmark, interactable), Inn (cottage), Item Shop (cottage), benches, barrel stack, flower bed
- NPCs: Village Elder (suspicious), Farm Girl (crops wilting), Vivi (story NPC, staring at underground)
- Shop: Potion (50), Broadsword (300), Leather Hat (150)
- Exits:
  - West -> `dali_village_road`
  - North -> `dali_village_farm`
  - Down -> `dali_village_underground` (via the well/trapdoor, requires quest `black_mage_factory` step 1)
  - East -> `lindblum_gate` (road to Lindblum)
- Treasures: 1 visible Potion (inside inn)

**Room 3: Windmill Hill** (optional exploration)
- Purpose: Scenic overlook. Peaceful. Reward for exploring.
- Props: 2 windmills, hay bales, fence, view of surrounding landscape, tree with swing
- NPCs: 1 Farmer ("These windmills power more than grain, if you catch my meaning...")
- Exits:
  - South -> `dali_village_square`
- Treasures: 1 visible Hi-Potion (behind hay bales), 1 hidden Ether (inside windmill)
- Atmosphere: The rhythmic sound of windmills. Highest point in the village -- you can "see" far.

**Room 4: Underground Factory** (story reveal)
- Purpose: Horror contrast. Dirty, dark, mechanical. Black Mage production. Vivi's trauma.
- Props: Conveyor belts, black mage pods, barrels of Mist, chains, pipes, dim lanterns, crates stamped with Alexandria crest
- NPCs: None (abandoned when you arrive, which is creepy)
- Encounters: Black Waltz 3 (boss, triggered by quest)
- Exits:
  - Up -> `dali_village_square` (back through trapdoor)
- Treasures: 1 visible Ether (on crate), 1 hidden Phoenix Down (behind machinery)
- Events: Quest dialogue with Vivi about what the Black Mages are. Atmosphere shift to dark ambient.

### Player Flow
```
[Ice Cavern] --> [Road] --> [Square] --> [Lindblum]
                               |    \
                               v     v
                           [Farm]*  [Underground]**
                         (* optional, ** quest-gated)
```
Hub-and-spoke. Square is the center. Underground is the dramatic reveal that changes the tone of the game.

---

## Region 5: Lindblum (Town, Act 1-2)

**Theme:** Scale and industry. The biggest city -- the player should feel small.

**Identity:** Brass, steam, gears, blue banners, airships overhead, multi-level architecture.

### Rooms: 5

| # | Room ID | Name | Type | Size |
|---|---------|------|------|------|
| 1 | `lindblum_gate` | City Gate | Entry | 900x600 |
| 2 | `lindblum_market` | Business District | Shop/hub | 1000x700 |
| 3 | `lindblum_theater` | Theater District | Side area | 800x600 |
| 4 | `lindblum_docks` | Airship Docks | Story area | 1000x700 |
| 5 | `lindblum_castle` | Grand Castle | Story climax | 900x700 |

### Room Details

**Room 1: City Gate** (entry)
- Purpose: Arrival. Sense of scale. The city rises above you.
- Props: Massive gate, steam pipes, lamp posts, gear motifs on walls, "Lindblum -- City of Industry and Sky" sign
- NPCs: Gate Guard ("Welcome to Lindblum"), Traveler
- Exits:
  - West -> `dali_village_square` (road back)
  - North -> `lindblum_market`
- Treasures: None

**Room 2: Business District** (main hub)
- Purpose: Commerce. The beating heart of the city.
- Props: Market fountain (landmark), vendor stalls, steam pipes, lamp posts, crates, gear decorations
- NPCs: Market Vendor (shop), Festival Goer, Citizen
- Shop: Potion (50), Hi-Potion (200), Mythril Sword (800), Chain Mail (600)
- Exits:
  - South -> `lindblum_gate`
  - West -> `lindblum_theater`
  - East -> `lindblum_docks`
  - North -> `lindblum_castle`
- Treasures: 1 visible Hi-Potion (behind stall)

**Room 3: Theater District** (side area, character)
- Purpose: Where Tantalus hangs out. Cultural flavor. Contrast with the industry.
- Props: Small stage, posters ("Lord Avon's Masterwork!"), benches, balconies, masks on wall
- NPCs: Theater Patron ("Did you see the show in Alexandria?"), Tantalus Member (hint about future)
- Exits:
  - East -> `lindblum_market`
- Treasures: 1 hidden Ether (behind stage curtain)
- Atmosphere: Warmer lighting, less mechanical noise.

**Room 4: Airship Docks** (story/spectacle)
- Purpose: Airships. The visual centerpiece of Lindblum. War preparations visible.
- Props: 2 docked airships, cranes, cargo crates, steam vents, brass railings, telescope
- NPCs: Airship Engineer ("The Hilda Garde is almost ready"), Retired Soldier (war foreshadowing)
- Exits:
  - West -> `lindblum_market`
  - East -> `burmecia_gate` (airship travel to Burmecia, unlocked after Act 1 quests)
- Treasures: 1 hidden Phoenix Down (in cargo crate), 1 visible Ether (on dock platform)

**Room 5: Grand Castle** (story climax)
- Purpose: Meeting Regent Cid. Major story exposition. Top of the city.
- Props: Castle throne, banners (blue), telescope, bookshelves, armor displays, map table
- NPCs: Regent Cid (frog form, story NPC), Castle Advisor
- Exits:
  - South -> `lindblum_market`
- Treasures: 1 hidden Phoenix Down (behind bookshelf)
- Events: Major story dialogue about Brahne's war, Kuja, and the eidolons.

### Player Flow
```
[Dali] --> [Gate] --> [Market] --> [Castle]
                        |    \
                        v     v
                   [Theater]* [Docks] --> [Burmecia]
                 (* optional)
```
Market is the central hub connecting everything. Castle is the story destination. Docks are both spectacle and the path forward. Theater rewards exploration with character moments.

---

## Region 6: Burmecia (Dungeon, Act 2)

**Theme:** War and loss. A city destroyed by rain and conquest.

**Identity:** Perpetual rain, grey stone, collapsed buildings, puddles reflecting, torn banners, corpses.

### Rooms: 5

| # | Room ID | Name | Type | Size |
|---|---------|------|------|------|
| 1 | `burmecia_gate` | Ruined Gate | Entry | 900x600 |
| 2 | `burmecia_avenue` | Fallen Avenue | Corridor | 900x700 |
| 3 | `burmecia_tower` | Collapsed Tower | Side/reward | 700x700 |
| 4 | `burmecia_approach` | Palace Approach | Corridor | 900x700 |
| 5 | `burmecia_palace` | Royal Chamber | Boss/exit | 800x700 |

### Room Details

**Room 1: Ruined Gate** (entry)
- Purpose: Immediate devastation. This was a city. Now it is rubble.
- Props: Shattered gate arch, rubble piles, puddles, broken weapon in ground, torn Burmecia banner
- NPCs: Wounded Burmecian ("The army came with black mages...")
- Encounters: Brahne Guard x1 (rate 0.12)
- Exits:
  - West -> `lindblum_docks` (back to Lindblum)
  - North -> `burmecia_avenue`
- Treasures: 1 visible Potion (near wounded soldier)

**Room 2: Fallen Avenue** (main path, branch point)
- Purpose: The main street of what was once a proud city. Branching to tower.
- Props: Fallen pillars across road, puddles (many), broken statues, extinguished torches, torn banners
- Encounters: Brahne Guard x2 (rate 0.15)
- Exits:
  - South -> `burmecia_gate`
  - West -> `burmecia_tower` (collapsed entrance, partially blocked)
  - North -> `burmecia_approach`
- Treasures: 1 visible Phoenix Down (on fallen soldier)

**Room 3: Collapsed Tower** (optional, side quest)
- Purpose: Freya's personal quest. Fratley's belongings are here. Emotional payoff.
- Props: Cracked bell (top of tower fell), rubble, broken dragon knight statue, water dripping through ceiling, small shrine
- NPCs: None (abandoned)
- Exits:
  - East -> `burmecia_avenue`
- Treasures: 1 visible Hi-Potion, 1 hidden Mythril Spear (Fratley's -- triggers side quest dialogue)
- Events: If `fratleys_memory` quest is active, finding the spear triggers Freya dialogue.

**Room 4: Palace Approach** (escalation)
- Purpose: Getting closer to the heart of the destruction. Encounter rate rises.
- Props: Palace walls (damaged but standing), more rubble, Alexandrian army tents (enemy presence), broken fountain
- NPCs: None (too dangerous)
- Encounters: Brahne Guard x2-3 (rate 0.18)
- Exits:
  - South -> `burmecia_avenue`
  - North -> `burmecia_palace`
- Treasures: 1 hidden Ether (in army tent)

**Room 5: Royal Chamber** (climax)
- Purpose: The throne room. Freya's confrontation. Kuja appears. Story turning point.
- Props: Damaged throne, shattered stained glass (dragon knight motifs), rain pouring through ceiling, Kuja's silver feather on ground
- Story NPCs: Freya (full quest dialogue set)
- Encounters: Boss trigger for Brahne Guard elite (story fight)
- Exits:
  - South -> `burmecia_approach`
  - North -> `cleyra_base` (path to Cleyra, opened after quest)
- Treasures: 1 hidden Dragon Mail (behind throne)
- Events: Major cutscene with Kuja. Quest `fall_of_burmecia` progresses.

### Player Flow
```
[Lindblum] --> [Gate] --> [Avenue] --> [Approach] --> [Palace] --> [Cleyra]
                             |
                             v
                          [Tower]*
                        (* side quest)
```
Mostly linear dungeon with one optional branch. Tension builds room by room. Palace is the emotional climax.

---

## Region 7: Cleyra (Special, Act 2)

**Theme:** Doomed sanctuary. Beauty about to be destroyed.

**Identity:** Warm wood, rope bridges, lantern light, sand swirling outside, vertical ascent through a tree.

### Rooms: 4

| # | Room ID | Name | Type | Size |
|---|---------|------|------|------|
| 1 | `cleyra_base` | Trunk Base | Entry | 800x700 |
| 2 | `cleyra_spiral` | Spiral Path | Vertical climb | 800x800 |
| 3 | `cleyra_village` | Canopy Village | Hub/town | 900x700 |
| 4 | `cleyra_cathedral` | Cathedral | Story climax | 800x700 |

### Room Details

**Room 1: Trunk Base** (entry)
- Purpose: The base of the great tree. Sand swirls around. Looking up into impossible height.
- Props: Massive tree roots, wooden platform, sand vortex on edges, rope ladder going up, first lantern
- NPCs: Burmecian Refugee ("We fled here from Burmecia...")
- Exits:
  - South -> `burmecia_palace` (back down)
  - Up -> `cleyra_spiral`
- Treasures: 1 visible Potion

**Room 2: Spiral Path** (vertical traversal)
- Purpose: The climb. Rope bridges, branches, vertigo. Light encounters with Antlions.
- Props: Winding wooden platforms, rope bridges (2), tree branches as bridges, gaps in bark showing sand outside, lanterns along path
- Encounters: Antlion x1-2 (rate 0.12)
- Exits:
  - Down -> `cleyra_base`
  - Up -> `cleyra_village`
- Treasures: 1 hidden Ether (on branch off the main path)

**Room 3: Canopy Village** (safe hub)
- Purpose: The settlement itself. Peaceful, warm, lived-in. The calm before the storm.
- Props: Wooden houses, rope bridges between platforms, lanterns everywhere, flower garlands, central gathering platform, children's toys
- NPCs: Cleyran Priestess (lore about the sandstorm harp), Cleyran Child ("The sand is dancing!"), Oracle (warns of danger)
- Exits:
  - Down -> `cleyra_spiral`
  - North -> `cleyra_cathedral`
- Treasures: 1 visible Hi-Potion (in house), 1 hidden Phoenix Down (behind flower garland)

**Room 4: Cathedral** (story climax)
- Purpose: The Sacred Harp. The sandstorm barrier. The destruction of Cleyra.
- Props: Sacred Harp (center, glowing), stained-leaf windows, altar, candles, sand beginning to seep in through cracks
- NPCs: High Priestess (guards the harp)
- Exits:
  - South -> `cleyra_village`
  - After destruction event -> `alexandria_harbor_road` (forced transition)
- Treasures: 1 hidden Hi-Potion (behind altar)
- Events: The harp stops playing. The sandstorm dies. Odin is summoned. Cleyra is destroyed. Forced transition to Alexandria Harbor.

### Player Flow
```
[Burmecia] --> [Base] --> [Spiral] --> [Village] --> [Cathedral] --> [Alexandria Harbor]
                                                                  (forced, one-way)
```
Strictly vertical ascent. Each room is higher up the tree. The cathedral is the point of no return -- after the destruction event, you cannot go back.

---

## Region 8: Alexandria Harbor (Field, Act 2)

**Theme:** Aftermath. The war comes home. Brahne's death. Garnet becomes queen.

**Identity:** Coastal amber light, warships, sand, waves, melancholy.

### Rooms: 3

| # | Room ID | Name | Type | Size |
|---|---------|------|------|------|
| 1 | `alexandria_harbor_road` | Harbor Road | Entry | 900x600 |
| 2 | `alexandria_harbor_docks` | The Docks | Hub/story | 1000x700 |
| 3 | `alexandria_harbor_beach` | Sandy Beach | Story climax | 900x600 |

### Room Details

**Room 1: Harbor Road** (entry)
- Purpose: Transition. Coming from the castle district or arriving after Cleyra.
- Props: Cobblestone road, warehouses, lamp posts, cart, direction signs
- NPCs: Harbor Guard ("The fleet returned... battered.")
- Exits:
  - West -> `alexandria_castle_gate`
  - East -> `alexandria_harbor_docks`
- Treasures: None

**Room 2: The Docks** (hub)
- Purpose: War ships, cargo, activity. The machinery of war up close.
- Props: 2 warships (scarred), dock posts, rope coils, crates, barrels, anchor, crane
- NPCs: Dock Worker (patrolling), Sailor ("Kuja turned on the queen...")
- Exits:
  - West -> `alexandria_harbor_road`
  - South -> `alexandria_harbor_beach`
  - East -> `outer_continent_jungle` (by ship, "To the Outer Continent")
- Treasures: 1 visible Hi-Potion (in crate), 1 hidden Phoenix Down (on ship deck)

**Room 3: Sandy Beach** (story climax, dead end)
- Purpose: Where Brahne washes ashore. Garnet's grief. Major story moment.
- Props: Sandy shore, waves, seashells, driftwood, lighthouse in background, sunset lighting
- NPCs: Fisherman ("I found the Queen right here..."), Garnet (story NPC, post-event)
- Exits:
  - North -> `alexandria_harbor_docks`
- Treasures: 1 hidden Elixir (in driftwood -- rare reward for visiting this optional screen)
- Events: Brahne's death scene if `rescue_garnet` quest is active.
- Atmosphere: Different from docks. Quieter, sadder. Waves and wind.

### Player Flow
```
[Alexandria] <-- [Road] --> [Docks] --> [Outer Continent]
                               |
                               v
                           [Beach]*
                         (* story scene, dead-end)
```
Small region. Three rooms. The beach is the emotional payoff. The docks are the transit hub.

---

## Region 9: Outer Continent (Field, Act 2-3)

**Theme:** Unknown frontier. The world beyond the Mist.

**Identity:** Dense jungle, ancient stone, exotic colors, dwarven stonework, waterfalls.

### Rooms: 4

| # | Room ID | Name | Type | Size |
|---|---------|------|------|------|
| 1 | `outer_continent_jungle` | Jungle Path | Entry | 1000x700 |
| 2 | `outer_continent_ruins` | Ancient Ruins | Exploration | 900x700 |
| 3 | `outer_continent_conde` | Conde Petie | Town hub | 900x700 |
| 4 | `outer_continent_cliff` | Cliff Overlook | Branch point | 800x700 |

### Room Details

**Room 1: Jungle Path** (entry)
- Purpose: Immediate sense of wildness. This is not the Mist Continent.
- Props: Dense jungle trees, exotic flowers, hanging vines, colorful birds (prop), muddy path, fallen ancient column (foreshadow ruins)
- NPCs: None (wilderness)
- Encounters: Light encounters with jungle creatures (rate 0.10)
- Exits:
  - West -> `alexandria_harbor_docks` (by ship, back)
  - East -> `outer_continent_ruins`
  - South -> `outer_continent_conde`
- Treasures: 1 visible Hi-Potion (under vine)

**Room 2: Ancient Ruins** (exploration, lore)
- Purpose: Who built these? Older than anything known. Points toward the Iifa Tree.
- Props: Stone pillars (broken), carved walls with inscriptions, ruin archway, moss and vine overgrowth, stone altar
- NPCs: Explorer ("These ruins point toward that giant tree...")
- Exits:
  - West -> `outer_continent_jungle`
  - North -> `iifa_tree_roots` (path leads toward the Iifa Tree)
- Treasures: 1 hidden Diamond Sword (in stone altar, best weapon find so far)
- Atmosphere: Quieter. Ancient. Slightly unsettling.

**Room 3: Conde Petie** (town hub)
- Purpose: Dwarf village. Shop. "Rally-ho!" Culture shock and comedy.
- Props: Dwarf-sized houses (round doors), stone paths, brewery, hot spring, rally-ho banner
- NPCs: Conde Petie Dwarf (shop + "ye must be wed!"), Dwarf Elder, Dwarf Child
- Shop: Hi-Potion (200), Diamond Sword (2400), Platinum Mail (2000), Ether (500)
- Exits:
  - North -> `outer_continent_jungle`
  - East -> `outer_continent_cliff`
- Treasures: 1 visible Ether (behind brewery)

**Room 4: Cliff Overlook** (branch, scenic)
- Purpose: The crossroads. You can see both the Iifa Tree and the path to Terra from here. Decision point.
- Props: Cliff edge, waterfall, panoramic view (described in narration), rocky path, exotic flowers
- NPCs: Hermit ("That tree... it reaches into the earth like it's drinking the world dry.")
- Exits:
  - West -> `outer_continent_conde`
  - North -> `iifa_tree_roots` (alternate route to Iifa Tree)
  - East -> `terra_arrival` (path to Terra, available after Iifa Tree)
- Treasures: 1 hidden Ether (behind waterfall)
- Events: First-enter narration describing the view.

### Player Flow
```
[Harbor] --> [Jungle] --> [Ruins] --> [Iifa Tree]
                |                        ^
                v                        |
           [Conde Petie] --> [Cliff] ----+
                              |
                              v
                           [Terra]**
                        (** after Iifa Tree)
```
Open feel. Multiple ways to reach the Iifa Tree (through ruins or through Conde Petie + cliff). Rewards exploration with the hidden Diamond Sword.

---

## Region 10: Iifa Tree (Dungeon, Act 2-3)

**Theme:** Corruption. A living organism that is sick and wrong.

**Identity:** Sickly green, pulsing veins, Mist pouring upward, organic horror, deep descent.

### Rooms: 5

| # | Room ID | Name | Type | Size |
|---|---------|------|------|------|
| 1 | `iifa_tree_roots` | Root Base | Entry | 900x600 |
| 2 | `iifa_tree_trunk` | Inner Trunk | Descent | 800x800 |
| 3 | `iifa_tree_veins` | Vein Chamber | Branch point | 900x700 |
| 4 | `iifa_tree_network` | Root Network | Side area | 700x700 |
| 5 | `iifa_tree_heart` | Heart of the Tree | Boss | 900x700 |

### Room Details

**Room 1: Root Base** (entry)
- Purpose: The tree is massive. You enter through the roots. Mist pours out.
- Props: Massive exposed roots, mist vents, dead vegetation around base, pulsing green veins visible
- Encounters: Zombie + Dracozombie (rate 0.12)
- Exits:
  - South -> `outer_continent_ruins` or `outer_continent_cliff` (depending on which way player came)
  - Down -> `iifa_tree_trunk`
- Treasures: 1 visible Potion

**Room 2: Inner Trunk** (descent)
- Purpose: Going deeper inside the tree. The walls pulse. It gets darker and wetter.
- Props: Organic walls, pulsing veins (brighter), mist rising from below, fungal growths, dead branches
- Encounters: Zombie + Dracozombie (rate 0.15)
- Exits:
  - Up -> `iifa_tree_roots`
  - Down -> `iifa_tree_veins`
- Treasures: 1 hidden Ether (in dead branch hollow)

**Room 3: Vein Chamber** (hub/branch)
- Purpose: A larger internal cavity. The veins converge here. Two paths diverge.
- Props: Multiple thick pulsing veins meeting at center, mist vents (heavy), pools of green liquid, soul wisps floating
- Encounters: Dracozombie x2 (rate 0.15)
- Exits:
  - Up -> `iifa_tree_trunk`
  - West -> `iifa_tree_network` (side path, reward)
  - Down -> `iifa_tree_heart` (main path, deeper)
- Treasures: 1 visible Hi-Potion

**Room 4: Root Network** (optional, reward)
- Purpose: Dead end with treasure. The roots extend out under the continent. Lore about what the tree does.
- Props: Sprawling root tendrils, trapped souls visible in roots (flavor), ancient inscription on root wall ("The tree drinks memories")
- Encounters: Zombie x3 (rate 0.18)
- Exits:
  - East -> `iifa_tree_veins`
- Treasures: 1 hidden Brigandine (armor, major find), 1 visible Phoenix Down
- Atmosphere: The pulsing slows here. It feels like the tree's unconscious.

**Room 5: Heart of the Tree** (boss)
- Purpose: The core. Soulcage boss. Where the Mist is produced. The reveal of what the tree truly is.
- Props: Massive organic heart (pulsing, green), soul streams flowing into it, mist pouring out of wounds, the ground is root tissue
- Encounters: Boss -- Soulcage (quest triggered), random Dracozombie x2 (rate 0.20)
- Exits:
  - Up -> `iifa_tree_veins`
- Treasures: 1 hidden Elixir (after boss, revealed in heart tissue)
- Events: Boss fight. After victory, the Mist stops. Narration about the world changing.

### Player Flow
```
[Outer Continent] --> [Roots] --> [Trunk] --> [Veins] --> [Heart]
                                                 |         (boss)
                                                 v
                                             [Network]*
                                           (* optional)
```
Vertical descent dungeon. Each room goes deeper. The branch in the Veins rewards exploration before the boss.

---

## Region 11: Terra (Special, Act 3)

**Theme:** Alien beauty. A dying world preserved in blue crystal. Zidane's origin.

**Identity:** Cold blue light, crystal spires, silence, Genome vessels, alien architecture, existential dread.

### Rooms: 5

| # | Room ID | Name | Type | Size |
|---|---------|------|------|------|
| 1 | `terra_arrival` | Arrival Platform | Entry | 800x600 |
| 2 | `terra_street` | Genome Street | Corridor | 900x700 |
| 3 | `terra_atrium` | Crystal Atrium | Hub/awe | 900x700 |
| 4 | `terra_pandemonium` | Pandemonium | Story area | 900x700 |
| 5 | `terra_throne` | Garland's Throne | Boss | 800x700 |

### Room Details

**Room 1: Arrival Platform** (entry)
- Purpose: You are not on Gaia anymore. Everything is wrong. Blue light, crystal, silence.
- Props: Teleport pad (how you arrived), crystal spires, dormant tree, blue lamps, alien architecture
- NPCs: Dormant Genome ("...who...am I...?")
- Exits:
  - West -> `outer_continent_cliff` (teleporter back)
  - East -> `terra_street`
- Treasures: 1 visible Ether
- Events: First-visit narration about arriving on another world.

**Room 2: Genome Street** (atmosphere/lore)
- Purpose: Rows of empty vessels. Soulless bodies waiting to be used. Zidane sees himself in them.
- Props: Genome pods (6+), blue lamps, crystal walkway, soul stream (visible, flowing overhead), alien signs
- NPCs: 2 Dormant Genomes (one twitches, one speaks a fragment)
- Exits:
  - West -> `terra_arrival`
  - East -> `terra_atrium`
- Treasures: 1 hidden Phoenix Down (inside cracked pod)

**Room 3: Crystal Atrium** (hub/spectacle)
- Purpose: The center of Terra. Massive crystal formations. The soul stream is visible flowing upward. Branching paths.
- Props: Enormous crystals (center), soul stream column, alien murals depicting Terra's history, blue light intensifying
- NPCs: Awakened Genome ("Garland created us. We are vessels, waiting for the souls of Terra's dead.")
- Exits:
  - West -> `terra_street`
  - North -> `terra_pandemonium`
  - East -> `terra_throne` (blocked until Pandemonium is visited)
- Treasures: 1 visible Hi-Potion, 1 hidden Platinum Mail (behind crystal formation)

**Room 4: Pandemonium** (story progression)
- Purpose: Garland's fortress within Terra. The truth about Zidane, Kuja, and Terra's plan to assimilate Gaia.
- Props: Alien arch (gate), dark crystal walls, holographic displays (described as glowing panels showing Gaia), chains, throne antechamber
- NPCs: None (Garland awaits in throne room)
- Encounters: Genome Soldier x2 (rate 0.15)
- Exits:
  - South -> `terra_atrium`
  - East -> `terra_throne` (unlocks this path in the atrium too)
- Treasures: 1 hidden Elixir (behind holographic panel)
- Events: Narration revealing Terra's plan.

**Room 5: Garland's Throne** (boss)
- Purpose: The confrontation. Garland reveals everything. Boss fight.
- Props: Throne (center, elevated), crystal pillars flanking, soul stream flowing into throne, Garland's machines
- Story NPCs: Garland (full dialogue tree)
- Encounters: Boss -- Garland (quest triggered)
- Exits:
  - West -> `terra_atrium`
  - North -> `crystal_world_threshold` (after defeating Garland)
- Treasures: 1 hidden Genji Armor (after boss, behind throne)
- Events: Garland boss fight. After defeat, path to Crystal World opens.

### Player Flow
```
[Outer Continent] --> [Arrival] --> [Street] --> [Atrium] --> [Pandemonium]
                                                    |              |
                                                    v              |
                                                 [Throne] <--------+
                                                    |
                                                    v
                                              [Crystal World]
```
The Atrium is the hub. Pandemonium is required to unlock the Throne path. Garland is the gatekeeper to the final dungeon.

---

## Region 12: Crystal World (Final Dungeon, Act 3)

**Theme:** End of everything. The origin of existence. Abstract, cosmic, surreal.

**Identity:** Deep purple/black void, floating crystal platforms, stars, impossible geometry, memory fragments.

### Rooms: 5

| # | Room ID | Name | Type | Size |
|---|---------|------|------|------|
| 1 | `crystal_world_threshold` | Void Threshold | Entry | 800x700 |
| 2 | `crystal_world_memories` | Memory Lane | Atmosphere | 900x700 |
| 3 | `crystal_world_shattered` | Shattered Path | Challenge | 800x700 |
| 4 | `crystal_world_kuja` | Kuja's Platform | Pre-boss | 900x700 |
| 5 | `crystal_world_crystal` | The Crystal | Final boss | 1000x800 |

### Room Details

**Room 1: Void Threshold** (entry)
- Purpose: Reality ends here. The player steps into the void. Everything they knew is gone.
- Props: Floating crystal platform, void below and above, distant stars, crystal shards floating, rift behind (exit back)
- Encounters: Lich (rate 0.15)
- Exits:
  - South -> `terra_throne` (back to Terra)
  - North -> `crystal_world_memories`
- Treasures: 1 visible Elixir (you will need it)
- Events: First-enter narration about the end of reality.

**Room 2: Memory Lane** (atmosphere/emotion)
- Purpose: Fragments of the party's memories float in the void. Each memory fragment is a prop with text -- a moment from the journey. This is the game looking back at itself.
- Props: Memory fragments (6-8, each with a line of text from earlier locations), floating crystals, cosmic dust, star clusters
- Memory fragment texts:
  - "I Want to Be Your Canary..." (Alexandria)
  - "The forest doesn't want us here..." (Evil Forest)
  - "Rally-ho!" (Conde Petie)
  - "Burmecia will rise again." (Burmecia)
  - "...who am I?" (Terra)
- Encounters: Lich + Behemoth (rate 0.15)
- Exits:
  - South -> `crystal_world_threshold`
  - North -> `crystal_world_shattered`
  - West -> hidden path to `crystal_world_kuja` (skip route for sharp-eyed players)
- Treasures: 1 hidden Robe of Lords (behind memory fragment -- the game's best armor, for thorough explorers)

**Room 3: Shattered Path** (challenge gauntlet)
- Purpose: The path is breaking apart. Highest encounter rate in the game. Tests the player's strength.
- Props: Broken crystal platforms, void gaps, crystal shards, shattered remnants of reality
- Encounters: Behemoth + Lich (rate 0.22, highest in the game)
- Exits:
  - South -> `crystal_world_memories`
  - East -> `crystal_world_kuja`
- Treasures: 1 visible Phoenix Down, 1 visible Elixir (you REALLY need these)

**Room 4: Kuja's Platform** (pre-boss, story)
- Purpose: Kuja is here. His final dialogue. The confrontation before the fight.
- Props: Isolated floating platform, Kuja standing at center, void swirling around, crystal throne (his), Ultima energy crackling
- Story NPCs: Kuja (full dialogue tree -- fear, anger, acceptance)
- Encounters: Boss -- Trance Kuja (quest triggered)
- Exits:
  - West -> `crystal_world_shattered`
  - North -> `crystal_world_crystal` (after defeating Kuja)
- Treasures: None (story room)
- Events: Kuja boss fight. Dialogue before and after. He opens the way to the Crystal.

**Room 5: The Crystal** (final boss)
- Purpose: The origin of all life. Necron appears to end existence. The final stand.
- Props: The Crystal itself (massive, pulsing, center of everything), star streams flowing into it, cosmic scale (the room feels infinite), Necron manifesting from the void
- Encounters: Boss -- Necron (final boss, quest triggered)
- Exits:
  - South -> `crystal_world_kuja` (if retreating before Necron -- allowed for preparation)
- Treasures: None (this is the end)
- Events: Necron boss fight. After victory, ending sequence triggers. The game is complete.

### Player Flow
```
[Terra] --> [Threshold] --> [Memories] --> [Shattered] --> [Kuja] --> [Crystal]
                                |                            ^       (final boss)
                                +------- (hidden path) ------+
```
Mostly linear with one hidden shortcut. The final dungeon is five rooms of escalating intensity:
1. Threshold: awe
2. Memories: emotion
3. Shattered: challenge
4. Kuja: confrontation
5. Crystal: climax

---

## Summary Table

| # | Region | Rooms | Type | Key Feature |
|---|--------|-------|------|-------------|
| 1 | Alexandria Castle | 4 | Town | Hub courtyard + hidden garden |
| 2 | Evil Forest | 4 | Dungeon | Linear + one optional branch |
| 3 | Ice Cavern | 4 | Dungeon | Linear, Crystal Chamber midpoint |
| 4 | Dali Village | 4 | Town | Hub square + hidden underground |
| 5 | Lindblum | 5 | Town | Largest city, market hub |
| 6 | Burmecia | 5 | Dungeon | Linear gauntlet + tower side quest |
| 7 | Cleyra | 4 | Special | Vertical ascent, one-way exit |
| 8 | Alexandria Harbor | 3 | Field | Small, beach is emotional payoff |
| 9 | Outer Continent | 4 | Field | Open exploration, multiple paths |
| 10 | Iifa Tree | 5 | Dungeon | Vertical descent, branch before boss |
| 11 | Terra | 5 | Special | Atrium hub, Pandemonium gates boss |
| 12 | Crystal World | 5 | Final | Linear escalation, memory callbacks |

**Total rooms: 52** (up from 12 single-screen locations)

---

## Room ID Quick Reference

This is the complete list of JSON files that need to exist in `data/locations/`:

```
alexandria_castle_gate.json
alexandria_castle_courtyard.json
alexandria_castle_interior.json
alexandria_castle_garden.json
evil_forest_edge.json
evil_forest_path.json
evil_forest_clearing.json
evil_forest_deep.json
ice_cavern_entrance.json
ice_cavern_passage.json
ice_cavern_crystal.json
ice_cavern_exit.json
dali_village_road.json
dali_village_square.json
dali_village_farm.json
dali_village_underground.json
lindblum_gate.json
lindblum_market.json
lindblum_theater.json
lindblum_docks.json
lindblum_castle.json
burmecia_gate.json
burmecia_avenue.json
burmecia_tower.json
burmecia_approach.json
burmecia_palace.json
cleyra_base.json
cleyra_spiral.json
cleyra_village.json
cleyra_cathedral.json
alexandria_harbor_road.json
alexandria_harbor_docks.json
alexandria_harbor_beach.json
outer_continent_jungle.json
outer_continent_ruins.json
outer_continent_conde.json
outer_continent_cliff.json
iifa_tree_roots.json
iifa_tree_trunk.json
iifa_tree_veins.json
iifa_tree_network.json
iifa_tree_heart.json
terra_arrival.json
terra_street.json
terra_atrium.json
terra_pandemonium.json
terra_throne.json
crystal_world_threshold.json
crystal_world_memories.json
crystal_world_shattered.json
crystal_world_kuja.json
crystal_world_crystal.json
```

---

## Connection Graph (Full Game)

```
ACT 1:
  castle_gate ─── castle_courtyard ─── castle_interior ──── evil_forest_edge
       |               |                                          |
   (harbor)       castle_garden*                          evil_forest_path
                                                           |           |
                                                    clearing*    evil_forest_deep
                                                                      |
                                                              ice_cavern_entrance
                                                                      |
                                                              ice_cavern_passage
                                                                      |
                                                              ice_cavern_crystal
                                                                      |
                                                              ice_cavern_exit
                                                                      |
                                                              dali_village_road
                                                                      |
                                                              dali_village_square
                                                               |      |      |
                                                          farm*  underground  lindblum_gate
                                                                              |
ACT 1-2:                                                              lindblum_market
                                                                    /      |       \
                                                            theater*  lindblum_castle  lindblum_docks
                                                                                          |
ACT 2:                                                                            burmecia_gate
                                                                                          |
                                                                                  burmecia_avenue
                                                                                   |           |
                                                                              tower*    burmecia_approach
                                                                                              |
                                                                                      burmecia_palace
                                                                                              |
                                                                                        cleyra_base
                                                                                              |
                                                                                       cleyra_spiral
                                                                                              |
                                                                                      cleyra_village
                                                                                              |
                                                                                    cleyra_cathedral
                                                                                              |
                                                                                  (forced) harbor_road
                                                                                              |
ACT 2-3:                                                                          harbor_docks
                                                                               |              |
                                                                          harbor_beach*  outer_jungle
                                                                                        |         |
                                                                                outer_ruins   outer_conde
                                                                                    |              |
                                                                                    +-- outer_cliff-+
                                                                                    |         |
                                                                              iifa_roots   terra_arrival**
                                                                                    |              |
                                                                              iifa_trunk      terra_street
                                                                                    |              |
                                                                              iifa_veins     terra_atrium
                                                                               |      |       |        |
                                                                          network*  iifa_heart  pandemonium
                                                                                              |        |
ACT 3:                                                                                  terra_throne---+
                                                                                              |
                                                                                  crystal_threshold
                                                                                              |
                                                                                    crystal_memories
                                                                                     |              |
                                                                              (hidden shortcut) crystal_shattered
                                                                                     |              |
                                                                                     +-- crystal_kuja
                                                                                              |
                                                                                     crystal_crystal
                                                                                        (THE END)

  * = optional side area
  ** = unlocked after Iifa Tree
```

---

## Design Principles Applied

1. **Every region has a hub room.** The room with the most exits where the player makes choices. (Courtyard, Square, Market, Atrium, etc.)

2. **Optional rooms are always dead-ends.** You go in, get a reward, come back. This teaches players that detours pay off without punishing them for exploring.

3. **Dungeons escalate linearly.** Each room deeper has harder encounters and better rewards. The player always knows they are making progress.

4. **Towns have 0 encounters.** Safe zones. The contrast matters.

5. **Inter-region transitions happen at specific rooms, not hubs.** You leave Alexandria through the Interior, not the Courtyard. This ensures you traverse the space.

6. **Every room has a distinct purpose.** No room exists just to be a room. It is an entry, a hub, a branch, a climax, or a reward.

7. **The hidden shortcut in Crystal World** rewards players who explored thoroughly and notice a side path in the memory room. This is the final dungeon rewarding the exploration habit the game has been training since Evil Forest's Fungal Clearing.

8. **Each region feels structurally different:**
   - Alexandria: hub-and-spoke (town)
   - Evil Forest: linear with one branch (first dungeon, simple)
   - Ice Cavern: linear tube (claustrophobic)
   - Dali: hub with hidden basement (secret below the surface)
   - Lindblum: hub with four spokes (big city)
   - Burmecia: linear gauntlet (warzone, forward momentum)
   - Cleyra: vertical climb, one-way exit (ascending, doomed)
   - Harbor: tiny, three rooms (intimate, emotional)
   - Outer Continent: open, multiple routes (frontier)
   - Iifa Tree: vertical descent with branch (mirror of Cleyra)
   - Terra: hub with gate-lock (alien logic)
   - Crystal World: linear escalation (final march)

---

## Implementation Notes

### What changes in `progression.json`
- `starting_location` changes from `"alexandria_castle"` to `"alexandria_castle_gate"`

### What changes in `quests.json`
- All `reach:<location>` triggers need updating to specific room IDs (e.g., `reach:evil_forest` becomes `reach:evil_forest_edge`)

### What changes in `connections` arrays
- Each room JSON lists only its direct neighbors in `connections`

### What does NOT change
- The Godot engine code (location_manager.gd) -- it already supports this
- The JSON format -- each room file uses the exact same schema as the current single-room files
- The UI, combat, quest, and dialogue systems -- all unchanged
