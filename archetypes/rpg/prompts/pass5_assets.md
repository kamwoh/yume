Add asset generation prompts to the existing game data files. These prompts describe what images, audio, and 3D models should look like — for use with image gen AI, audio gen AI, or human artists.

You receive: all existing JSON files (characters, items, enemies, locations, game_state, meta).

**You do NOT create new files. You ADD fields to existing files.**

## meta.json — Add global style guides

```json
{
  "art_style": "existing field — visual style for all images",
  "audio_style": "Orchestral JRPG soundtrack with emotional piano motifs. Battle music uses driving strings and brass. Towns use acoustic guitar and flute. Dungeons use ambient synth with percussion.",
  "voice_style": "Japanese RPG English dub style. Expressive, theatrical, clear enunciation."
}
```

## characters.json — Add per-character audio prompts

Each party member and boss already has `portrait_prompt` and `sprite_prompts`. Add:

```json
{
  "id": "zidane",
  "voice_prompt": "Young male, 17-19, confident and playful. Quick delivery, occasional sarcasm. Warm when serious. Think: charming rogue who cares more than he lets on.",
  "battle_sfx_prompts": {
    "attack": "Quick double slash sound, light metallic ring of twin daggers",
    "hurt": "Short surprised grunt, male",
    "ability_steal": "Quick sneaky grab sound, cloth rustling",
    "ability_tidal_flame": "Whooshing fire slash, burning blade impact"
  }
}
```

For NPCs/bosses:
```json
{
  "id": "beatrix",
  "voice_prompt": "Adult female, 30s, cold and professional. Military precision. Every word deliberate. Slight accent of authority.",
  "battle_sfx_prompts": {
    "attack": "Heavy single sword strike, steel on steel, authoritative",
    "ability_stock_break": "Devastating multi-slash, rising in intensity, final heavy impact"
  }
}
```

## locations/*.json — Add per-room audio prompts

Each location already has `atmosphere.music_mood`. Add audio detail:

```json
{
  "atmosphere": {
    "music_mood": "noble_peaceful",
    "bgm_prompt": "Gentle orchestral waltz, strings and harp. Warm and festive but with underlying melancholy. 120 BPM.",
    "ambience_prompt": "Crowd murmur, distant fountain splashing, occasional laughter, torch crackling",
    "ambience_layers": ["crowd_murmur", "fountain", "torch_crackle"]
  }
}
```

For dungeons:
```json
{
  "atmosphere": {
    "music_mood": "dark_forest",
    "bgm_prompt": "Low strings tremolo, sparse woodwind, unsettling. Quiet with sudden crescendos. 80 BPM.",
    "ambience_prompt": "Wind through branches, distant animal calls, creaking wood, dripping water",
    "ambience_layers": ["wind", "animal_calls", "creaking", "water_drip"]
  }
}
```

## game_state.json — Add per-phase audio cues

Each phase can specify what audio plays during its cutscene:

```json
{
  "id": "find_garnet",
  "bgm_override": "emotional_piano",
  "bgm_prompt": "Solo piano, minor key, slow and searching. Builds to hopeful major key as Garnet speaks. 70 BPM.",
  "sfx_cues": [
    {"at_step": 0, "sfx": "dramatic_reveal", "sfx_prompt": "Soft orchestral sting, single held violin note"},
    {"at_step": 5, "sfx": "party_join", "sfx_prompt": "Warm ascending harp arpeggio, hopeful jingle 2 seconds"}
  ]
}
```

## items.json — Add item SFX prompts

```json
{
  "id": "potion",
  "sfx_prompt": "Gentle glass clink, liquid pouring, soft magical sparkle"
}
```

## enemies.json — Add enemy audio prompts

```json
{
  "id": "plant_brain",
  "sfx_prompts": {
    "appear": "Deep rumbling, vines tearing from earth, wet organic growth",
    "attack": "Vine whip crack, heavy thud",
    "hurt": "Organic squelch, plant fiber tearing",
    "death": "Slow wilting collapse, sap draining, final heavy thud"
  }
}
```

## Rules

1. **Add to existing files** — do NOT create new audio-specific files
2. **Prompts describe the SOUND** — what a human or AI audio tool should produce
3. **ambience_layers list specific loops** — each is a separate audio file that plays together
4. **bgm_prompt includes BPM and instruments** — specific enough for generation
5. **voice_prompt describes personality** not just pitch — how the character SPEAKS
6. **battle_sfx_prompts match ability names** from the character's abilities array
7. **Keep consistent style** — reference meta.audio_style for overall tone
8. **SFX prompts are short** (1 line) — BGM prompts can be longer (2-3 sentences)

## What This Enables

```
JSON data with prompts
  → Image gen AI reads sprite_prompts → produces PNG sprites
  → Audio gen AI reads bgm_prompt → produces OGG music
  → Audio gen AI reads sfx_prompt → produces OGG effects
  → Voice gen AI reads voice_prompt + dialogue text → produces voice lines
  → 3D gen AI reads sprite_prompts → produces GLB models

All go into:
  sprites/characters/{id}.png
  audio/bgm/{mood}.ogg
  audio/sfx/{name}.ogg
  audio/voice/{character}/{line_id}.ogg
  models/characters/{id}.glb
```

The game engine auto-detects all of them. No code changes needed.

Return ONLY the modified JSON fields (not entire files).
