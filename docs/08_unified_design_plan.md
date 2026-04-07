# Unified Design Plan — Synthesized from 3 Expert Reviews

## The Verdict

The engine works. The game doesn't. Three experts agree on the core problems:

### Problem 1: No Onboarding (Game Designer)
"You get one chance at a first impression, and right now the first impression is 'I am a rectangle in a rectangle room and I don't know what I'm supposed to do.'"

**Fix:** Forced opening sequence — cutscene, guided first interaction, tutorial battle, one mechanic taught per location for first 4 locations.

### Problem 2: No Spatial Depth (Level Designer)
"Every location is a single flat rectangle. A castle feels the same as a forest feels the same as an alien world."

**Fix:** 52 rooms across 12 regions. No engine changes — just more JSON files. Each region has 3-5 rooms with distinct purposes, props, and flow.

### Problem 3: No Emotional Tissue (Story Designer)
"4 dialogue sequences for 12 locations. Most locations have zero scripted dialogue. The story jumps from crisis to crisis with no downtime for character development."

**Fix:** 26+ dialogues (up from 4), party banter, quiet scenes, NPC reactions to quest state, "You're Not Alone" theme expressed through gameplay.

### Problem 4: No Pacing Rhythm (Game Designer)
"The entire game is one flat pacing line. The destruction of Burmecia has the same mechanical rhythm as walking through Dali Village."

**Fix:** Town (rest) → Dungeon (tension) → Boss (peak) → Town (release) cycle. More enemy variety. Encounter rate escalation per dungeon room.

### Problem 5: No Game Wrapper (All Three)
No title screen. No game over screen. No ending. No credits.

**Fix:** Title scene, game over with retry/title options, ending cutscene, credits scroll.

---

## Priority Execution Order

### Priority 1: Title Screen + Ending (frames the experience)
- Title screen scene with "New Game" / "Continue"
- Game over screen with "Retry" / "Title"
- Ending cutscene after final boss
- Credits

### Priority 2: Opening Sequence (first impression)
- Forced cutscene at Alexandria start
- Tutorial battle (teaches combat)
- Guided first quest step
- HUD hints ("Walk to Garnet", "Press ESC for menu")

### Priority 3: Sub-Areas (spatial depth)
- Split Alexandria into 4 rooms (gate → courtyard → interior → garden)
- Split Evil Forest into 4 rooms (entrance → depths → clearing → exit)
- Continue for remaining 10 regions (52 rooms total)
- Each room: distinct layout, props, purpose

### Priority 4: Rich Dialogue (emotional tissue)
- 26+ dialogue sequences
- Party banter at key moments
- Quiet character scenes between crises
- NPC dialogue that changes with quest state
- The "You're Not Alone" thread (Ice Cavern line → Terra callback → ending payoff)

### Priority 5: Pacing Fixes
- More enemy types (not same Fangs in late dungeons)
- Encounter rate varies per room (entrance=light, depths=heavy, boss room=none)
- Mini-bosses at dungeon midpoints
- Rest points (inn, save crystal) at rhythm breaks

---

## Implementation: What Goes Where

### Engine Changes Needed: MINIMAL
- Title screen → new scene (title.tscn) or data-driven (title screen JSON)
- Game over → already exists in battle_manager, just needs UI
- Credits → simple scrolling text scene
- HUD hints → one new label in HUD
- Everything else is DATA (JSON files)

### Content Generation Needed: LARGE
- 52 room JSONs (replacing 12 location JSONs)
- 26+ dialogue entries in dialogues.json
- Updated quest chain to reference room IDs (not region IDs)
- More enemy types in enemies.json
- Opening tutorial cutscene data
- Ending cutscene data

### This is Yume's Real Test
If the LLM (Claude) can read the design docs + schemas + templates and GENERATE all this content correctly — that proves Yume works as a knowledge framework. The content generation IS the product.

---

## Estimated Effort

| Task | Rooms/files | Time |
|------|-------------|------|
| Title + Game Over + Ending | 3 | 30 min |
| Opening tutorial sequence | 1 cutscene JSON | 20 min |
| Sub-areas for Alexandria (4 rooms) | 4 JSONs | 30 min |
| Sub-areas for remaining 11 regions | ~48 JSONs | 3 hours |
| 26+ dialogues | 1 file update | 1 hour |
| Quest chain update | 1 file update | 30 min |
| More enemies | 1 file update | 20 min |
| Testing full playthrough | - | 1 hour |
| **Total** | **~55 files** | **~7 hours** |

Most of this is CONTENT (JSON), not CODE. The engine is done.
