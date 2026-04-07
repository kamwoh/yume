# FF9 Walkthrough Analysis — Ground Truth Statistics

## Source: jegged.com walkthrough, 45 chapters, 492KB

## Game Scale
| Metric | Real FF9 | Our Game | Gap |
|--------|----------|----------|-----|
| Chapters/sections | 45 | 12 regions | 3.75x |
| Rooms/sub-areas | 215 | 52 | 4.1x |
| Boss battles | 78 | 8 | 9.75x |
| Treasure finds | 54+ (undercounted) | ~30 | 2x+ |
| Party members | 8 playable | 5 (Zidane, Garnet, Vivi, Steiner, Freya) | missing 3 |
| Discs/acts | 4 | 3 | close enough |

## Density Per Chapter (what our rooms should match)
| Location Type | Avg Rooms | Avg Bosses | Avg Items |
|--------------|-----------|------------|-----------|
| Town | 5-7 | 0-1 | 3-6 |
| Dungeon | 4-8 | 2-4 | 2-4 |
| Field/travel | 2-4 | 0-1 | 0-1 |
| Story event | 2-3 | 1-3 | 0-1 |
| Final dungeon | 12 | 7 | 1+ |

## Key Insight for Yume
Our 52 rooms are roughly 1/4 of the real game. For a DEMO (Act 1 only), 52 rooms is actually reasonable — Act 1 has ~60 rooms in the real game.

**For v1 release:** Focus on making Act 1 (chapters 1-10) PERFECT with our 52 rooms, rather than trying to match the full 215-room game.

## Chapter-by-Chapter Density
(See analysis script output for full table)

Largest chapters: Lindblum (12 rooms), Gizamaluke's Grotto (17 rooms), Memoria (12 rooms)
Smallest chapters: Cargo Ship (2 rooms), Crystal World (1 room)

## What This Means for Prompt Engineering
The walkthrough shows that each room in a JRPG has:
- 2-5 hidden items/treasures
- 1-3 NPCs with unique dialogue
- A specific purpose (story beat, puzzle, shop, transition)
- Environmental details described in 2-3 sentences
- Boss encounters with steal lists and drop tables

Our prompts need to instruct: "For each room, generate 3+ hidden treasures, 2+ NPCs with personality dialogue, specific props that match the location theme, and a purpose statement."
