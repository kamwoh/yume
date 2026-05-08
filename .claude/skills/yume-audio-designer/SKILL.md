---
name: yume-audio-designer
description: Designer for music + soundtrack architecture across a Yume game — distinct from yume-asset-designer (which writes audio/cues.json mapping signals to one-shot SFX). This skill owns: BGM selection per screen/level/state, dynamic intensity layers (calm/explore/combat/boss), bus design (composes ADR 0013's set_audio_bus_volume), looping + crossfade transitions, ambient layers, and stinger/jingle moments. Outputs audio-design.md + extends data/<game>/audio/cues.json with music-bed entries.
---

# /yume-audio-designer

You are the **audio designer** for Yume. You don't pick the
"door_creak.ogg" filename for a single signal — that's
yume-asset-designer's per-cue mapping. You design the **musical
architecture** of a game: when does music shift, what bus mixes
go where, how do calm/combat layers crossfade, what jingles fire
on victory.

This skill loads into the orchestrator's main context (Tier 2.6 — no
subagent spawn).

## Soul workflow membership — Layer 3 (Audio)

You are **Layer 3 of 5** in the soul workflow (per
`.claude/rules/soul.md`). Your job: BGM + ambience + stings tied
to signals so the world sounds like it feels.

Cross-reinforce with adjacent layers:
- Match BGM mood to **Layer 1 voice tone**: gruff dialogue → low
  brass; lyrical voice → harp/strings.
- Match BGM transitions to **Layer 5 reactive rules**: when a
  reactive rule fires (tier-up, bailiff arrival, boss phase), there
  must be an audio sting.
- Coordinate with **Layer 4 juice**: kinetic events (sale clinch,
  hit-pause) need a one-shot to land the kinesthetic feel.

**Soul minimum**: ≥1 BGM per distinct location/mood, ≥1 ambient
loop per level type (shop/wilderness/dungeon/town), ≥3 signature
stings per major event class (debt, combat, narrative).

## Why this skill exists

Without an audio-architecture specialist, games either:
- Ship with one looping track for the whole game (sokoban v0.1
  shipped this — flat, no emotional arc)
- Have BGM but no intensity shifts (combat feels the same as exploration)
- Hand-author audio bus volumes per-game with no consistency
- Forget transition stingers (level-clear, boss-spawn) — moments feel
  flat
- Have ambient sound but never layer it dynamically (cave should sound
  different from forest)

This skill produces an audio-design.md with rationale + a music-bed
section in audio/cues.json.

## Engine-capability gate (MANDATORY before declaring complete)

Before signing off, verify the cues you authored can ACTUALLY play.
Empirical case (2026-05-08): merchant authored 12 BGM cues + 7 ambient
loops + 9 stings in `audio/cues.json::music_beds`. User played:
"where is the background music you said early?" Reason: `audio_bus.gd`
was sfxr-only (one-shot procedural). The music_beds metadata was
forward-compat but NO ENGINE CODE READ IT. BGM degraded to silence.

Checklist before complete:
1. Run `grep -E "play_music|loop_mode|_music_player" archetypes/core/templates/godot/scripts/engine/audio_bus.gd` — does the engine
   have a play_music API? If NOT, your BGM cues will be silent.
2. If absent, EITHER:
   - Author short procedural melodies (`notes: [{freq, dur}, ...]` in
     sounds.json) and document the rule wiring + the limitation.
   - OR propose an ADR for ogg/loop playback. Don't claim BGM is
     authored if the engine can't play it.
3. Verify each BGM track has a corresponding rule in game/rules.json
   that fires `emit_shell_event {event: "play_music", name: "..."}`
   on level entry. Without the rule, the cue is dead JSON.
4. Document in audio-design.md exactly which cues are PLAYABLE today
   vs forward-compat metadata.

## Inputs

- A GDD at `docs/games/<game>/GDD.md` (theme, aesthetic, emotional
  beats)
- A world plan + level design (knows # of levels, named areas)
- A story plan (if exists) — for narrative beats that need stingers
- The cues.json that yume-asset-designer wrote (don't conflict — extend)

## Outputs

- `docs/games/<game>/audio-design.md` — design doc
- Extension/update to `data/<game>/audio/cues.json` adding a `music`
  section + ambient layers
- (optional) `data/<game>/audio/buses.json` if game needs custom bus
  layout beyond the default master/music/sfx/voice

## Core questions

### 1. What's the BGM strategy?

Three patterns:

**Single-track loop** — one piece for the whole game. Simplest. Good
for short games (<30 min) or strongly contemplative aesthetics
(sokoban "warm parchment archive" → could ship with one warm piano
loop).

**Per-screen tracks** — title has its own theme; each level has its
own BGM; pause keeps current playing or mutes. Standard for most
games. a farming sim, FF1-6.

**Layered intensity** — base layer always plays; combat/danger layer
fades in on triggers. Used in a metroidvania, a soulslike, modern
JRPGs. Most ambitious; requires separate stems.

Default: per-screen, with one ambient layer that varies per level.

### 2. What audio buses?

Per ADR 0013, `set_audio_bus_volume` effect adjusts a named bus.
Standard buses Yume games should have:

- **Master** — global volume
- **Music** — all BGM
- **SFX** — one-shot effects (footsteps, hits, UI clicks)
- **Voice** — character voiceover (if any)
- **Ambient** — looping environmental beds (wind, water, rain)

Most games use exactly these 5. Add custom buses only if there's a
real reason (e.g., separate "boss music" bus that ducks SFX).

### 3. What stingers/jingles?

Stingers = short non-looping pieces fired by signals. Common ones:
- **level_complete** — 2-4s flourish before next level loads
- **boss_spawn** — 1-2s warning fanfare
- **player_died** — 1-2s descending tone
- **item_acquired** — 0.5-1s ding (an action-adventure treasure jingle)
- **achievement_unlocked** — 1-2s chime

Each stinger should have:
- A signal it listens for
- Optional bus override (often duck music while playing)
- Length budget so it doesn't overlap next loop

### 4. Ambient layers

For games with named areas/biomes, each area can have an ambient
loop on the Ambient bus, separate from BGM:

- **Forest area**: birds + wind layer
- **Cave area**: drips + low rumble
- **Town area**: chatter + footsteps
- **Boss arena**: heartbeat / industrial drone

Ambient layers play on level enter and crossfade out on exit. Music
stays as its own track.

### 5. Crossfade timing

When music changes (level transition, screen change, layer toggle),
how long does it crossfade?

- **Hard cut** (0s) — cheap; jarring; good for game-over screens or
  state changes that should feel abrupt
- **Quick crossfade** (0.5-1s) — smooth; default for screen transitions
- **Slow crossfade** (3-5s) — atmospheric; good for layered intensity
  fade-in (combat layer over explore layer)

Default: 1s crossfade for screen transitions; 3s for intensity layer
changes.

## Output schema

### Music section in audio/cues.json

```jsonc
{
  "music": {
    "default_bus": "Music",
    "tracks": {
      "title_theme": {
        "asset": "@audio.title_theme",
        "loop": true,
        "volume_db": -6.0
      },
      "level_1_bgm": {
        "asset": "@audio.level_1_bgm",
        "loop": true,
        "volume_db": -8.0
      },
      "boss_bgm": {
        "asset": "@audio.boss_bgm",
        "loop": true,
        "volume_db": -4.0
      }
    },
    "stingers": {
      "level_complete": {
        "asset": "@audio.stinger_complete",
        "loop": false,
        "volume_db": 0.0,
        "duck_bus": "Music",
        "duck_amount_db": -12.0,
        "duck_duration_s": 3.0
      },
      "boss_spawn": {
        "asset": "@audio.stinger_boss",
        "loop": false,
        "volume_db": 0.0
      }
    },
    "ambient_layers": {
      "forest": {
        "asset": "@audio.amb_forest",
        "loop": true,
        "volume_db": -18.0,
        "bus": "Ambient"
      },
      "cave": {
        "asset": "@audio.amb_cave",
        "loop": true,
        "volume_db": -16.0,
        "bus": "Ambient"
      }
    },
    "transitions": {
      "default_crossfade_s": 1.0,
      "intensity_crossfade_s": 3.0
    }
  }
}
```

### Mapping music to game state

Music plays based on signals + screen state. Rules in
game/rules.json (yume-game-rules-designer's domain) fire effects
like:

```jsonc
{"type": "play_music", "track": "level_1_bgm", "crossfade_s": 1.0},
{"type": "play_stinger", "id": "level_complete"},
{"type": "set_audio_bus_volume", "bus": "Music", "volume_db": -20}
```

**This skill specifies WHAT exists; game-rules-designer wires it
into state transitions.**

## Sample architectures per game type

### Puzzle / contemplative (sokoban)

- 1 main loop track — warm piano, slow tempo
- 1 stinger: level_complete (warm flourish)
- 1 stinger: all_levels_complete (bigger warm flourish)
- Ambient: book-shelf creaks (very subtle)
- No combat layer (no danger)
- No boss music
- 5 bus standard

### Action shooter (doomarena3d)

- 3 BGM tracks: title theme, arena combat, boss
- Stingers: enemy_killed (small punch), player_died, boss_spawn,
  victory
- Ambient: industrial drone in arena, heartbeat near low-HP
- Combat layer: distorted guitar over base drone (intensity layer
  fades in when ≥3 enemies alive)
- 5 bus standard

### Open-world RPG

- BGM per zone (5-10 tracks)
- Stingers: level_up, item_pickup, save_complete, save_failed,
  death, victory
- Ambient: 1 per biome (forest/cave/town/dungeon/coast)
- Combat layer: tense strings fade in when in_combat=true
- 5 buses + Voice for dialogue

### farming-sim-style farming

- BGM per season + per area (12+ tracks: spring/summer/fall/winter ×
  farm/town/mine/beach)
- Stingers: day_end, harvest, festival_start
- Ambient: weather (rain layer over BGM)
- 5 bus standard

## Design discipline

### Don't over-author

7 tracks is plenty for most games. Once you hit 12+ tracks, you're
over-scoping. Combine: "town BGM" can serve "shop interior" too.

### Listen for emotional beats

GDD aesthetics → music tone:
- "Submission" / contemplation → slow tempo, sparse instruments,
  major key
- "Challenge" / tension → driving rhythm, dissonance, minor key
- "Sensation" / impact → percussive, heavy bass
- "Discovery" / wonder → ambient, evolving, modal

### Volume hierarchy

Loud-to-quiet ordering:
- Stingers: -3 to 0 dB (peaks)
- BGM: -8 to -6 dB (steady)
- SFX: -6 to -3 dB (transient)
- Ambient: -18 to -16 dB (always background)
- Voice: -3 to 0 dB (must be intelligible)

If a stinger is at -10dB nobody will hear it; if BGM is at 0dB it
crushes everything else.

### Loop points

If you specify `loop: true` for a track, the asset must loop
seamlessly. Note this in the asset_gen prompt for the asset designer
to honor.

## Anti-patterns

❌ **One track per screen** — exhausting; track count balloons.
   Reuse where it makes thematic sense.
❌ **No stingers** — moments feel flat. At minimum: level_complete,
   game_over.
❌ **Music + ambient on same bus** — can't independently control.
   Always separate buses.
❌ **No volume specified** — playback uses 0dB default which is
   often too loud. Always specify volume_db.
❌ **Stinger longer than 3s** — overlaps/awkward. Keep brief.
❌ **Combat layer with no out-condition** — never fades back to
   calm; player is "always in combat." Must specify both fade-in
   and fade-out triggers.

## What you DON'T do

- ❌ Pick filenames for one-shot SFX cues (yume-asset-designer's
  cues.json domain)
- ❌ Author the music files themselves (asset-gen pipeline)
- ❌ Decide audio engine internals (ADR 0013 + Godot AudioServer
  exposure)
- ❌ Wire signals → music effects in rules (yume-game-rules-designer)
- ❌ Translate voice lines (asset-designer + ui/strings.json)

## When invoked by orchestrator

After yume-asset-designer (so cues.json already has one-shot SFX
mapped). This skill EXTENDS cues.json with the music section, plus
writes the design doc. Skill needs:
- GDD aesthetic for tone
- Level/screen list
- Signal vocabulary for stingers

Returns summary: track count, stinger count, ambient layer count,
bus layout choice, intensity-layering strategy.

## Reference files

- docs/adr/0013-settings-schema-and-config.md — set_audio_bus_volume
  effect + bus layout integration
- (future) docs/adr/0026-audio-server-exposure.md — full AudioServer
  capability map
- existing demos: sokoban (single-track), doomarena3d (combat layer
  example when built)
