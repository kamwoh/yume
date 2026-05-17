---
name: yume-save-policy-designer
description: Designer for save_policy.json — declares what persists across sessions, autosave triggers, slot count, schema versioning. Per ADR 0010, the engine has one save/load implementation; per-game variation lives in this JSON. The skill answers: which world_state keys persist, which entity tags survive (persistent NPCs vs transient mobs), what causes an autosave, how many manual save slots, what version is the save schema. Distinct from save-state-designer (which is this skill renamed) — this is the policy author.
---

# /yume-save-policy-designer

You are the **save policy designer** for Yume. Your job: decide what
persists across sessions for each game.

This skill loads into the orchestrator's main context (Tier 2.6 — no
subagent spawn).

## Why this skill exists

Save/load is universal in shipping games but underspecified per-game.
Without a policy specialist, common failure modes:
- Saves miss critical state (player progress restarts after reload)
- Saves include too much (every projectile, every tile — saves balloon)
- No autosave triggers (player rage-quits after losing 30 minutes)
- Save schema changes silently break old saves
- Persistent entities don't actually persist across chunks (per ADR 0014)

This skill produces `save_policy.json` per ADR 0010's schema.

## Inputs

- A GDD at `docs/games/<game>/GDD.md` (mentions save / progress /
  achievements / persistence)
- Optional: world-plan (named NPCs that should persist), level-design
  (level-transition triggers), economy-design (currencies that should
  persist)

## Outputs

A save policy at `data/<game>/save_policy.json` (per ADR 0010 schema).

## Core questions to answer

### 1. What world_state keys persist?

Walk through the game's world_state usage. For each key, decide:
**persist** vs **reset on new game** vs **purely runtime**.

Examples:
- `current_level` — persist (player resumes at correct level)
- `score` — persist (long-term progress)
- `tutorial_step` — persist (don't re-do tutorial after reload)
- `achievements_unlocked` — persist (cross-save persistence)
- `tick` — runtime only (reset; engine recomputes)
- `_pending_level_transition` — runtime only (engine internal)
- `last_input_action` — runtime only

Rule of thumb: persist if the player would feel cheated by losing it.

### 2. Which entity tags survive?

Per ADR 0014, persistent-tagged entities survive chunk eviction. The
save policy further filters which TAGS the engine SERIALIZES.

Typical patterns:
- `named_npc` — persist (each NPC has identity + state)
- `shop` / `landmark` / `chest` — persist (positional + state)
- `pickup` / `monster` / `projectile` — DON'T persist (transient)
- `terrain` / `wall` — DON'T persist (reload from chunk JSON)

Authoring note: the persistent tag is decided by content-designer
when authoring entity defs; this policy file just LISTS which tags
serialize.

### 3. What causes an autosave?

Three trigger types:

- **on_signal** — autosave when a named signal fires (e.g.
  `level_won`, `boss_defeated`, `day_ended`)
- **on_level_transition** — autosave whenever level changes
- **interval_ticks** — periodic autosave every N ticks (rarely a
  good idea; tick-based is uneven)

Recommend at minimum: `on_level_transition: true`. Anything more
depends on game pacing.

### 4. How many manual save slots?

- **1 slot**: simplest; "Continue" button. Most arcade games. Player
  expects auto-overwrite.
- **3 slots**: a farming sim/JRPG standard. Lets player branch playthroughs.
- **>3 slots**: only for games where save-scumming or branching is
  core (Souls, branching narrative).

### 5. Schema version

Set `version: 1` initially. Bump when:
- Adding required new fields to save format (rare)
- Removing fields that older saves may include (engine refuses old
  saves)

Per ADR 0010, refuse-on-mismatch is the policy. No silent migration
in v1. Future ADR if migrations needed.

## Sample policies per game type

### Sokoban / puzzle game

```jsonc
{
  "world_state_keys": [
    "current_level", "tutorial_step", "moves_total",
    "levels_completed", "achievements_unlocked"
  ],
  "entity_tags_persistent": [],
  "relations_persistent": [],
  "slots": 1,
  "autosave": {
    "on_level_transition": true,
    "on_signal": [],
    "interval_ticks": 0
  },
  "version": 1
}
```

Rationale: levels reload from disk; only progress (current_level +
counters) needs to persist. No persistent entities (each level is
fresh).

### farming-sim-style farming sim

```jsonc
{
  "world_state_keys": [
    "current_level", "day", "season", "year", "gold",
    "tutorial_step", "married_to", "achievements_unlocked",
    "discovered_recipes"
  ],
  "entity_tags_persistent": [
    "named_npc", "shop", "house", "field", "crop_planted",
    "animal_owned"
  ],
  "relations_persistent": [
    "married_to", "befriended", "owns"
  ],
  "slots": 3,
  "autosave": {
    "on_level_transition": false,
    "on_signal": ["day_ended", "wedding_completed"],
    "interval_ticks": 0
  },
  "version": 1
}
```

Rationale: many persistent NPCs + crops; 3 slots for branching
playthroughs; autosave at day end (a farming sim convention).

### Action game / shooter

```jsonc
{
  "world_state_keys": [
    "current_level", "score", "highscore", "lives",
    "achievements_unlocked"
  ],
  "entity_tags_persistent": [],
  "relations_persistent": [],
  "slots": 1,
  "autosave": {
    "on_level_transition": true,
    "on_signal": [],
    "interval_ticks": 0
  },
  "version": 1
}
```

Rationale: no persistent entities (each level is fresh); score and
unlocks persist; single slot since action games don't branch.

### Open-world RPG

```jsonc
{
  "world_state_keys": [
    "current_chunk", "tutorial_step", "story_beats_fired",
    "quests_active", "quests_completed", "inventory",
    "gold", "xp", "level"
  ],
  "entity_tags_persistent": [
    "named_npc", "shop", "key_item", "story_relevant"
  ],
  "relations_persistent": [
    "owns", "befriended", "knows_about"
  ],
  "slots": 3,
  "autosave": {
    "on_level_transition": true,
    "on_signal": ["story_beat_fired", "boss_defeated"],
    "interval_ticks": 0
  },
  "version": 1
}
```

## Common mistakes

❌ **Persisting everything by default** — bloats saves; new entity
   defs in updates break loads. Be selective.

❌ **No autosave** — players will lose progress; rage. At minimum
   on_level_transition.

❌ **Too many save slots** — most games don't need >3. Decision
   paralysis.

❌ **Forgetting tutorial_step** — reload re-runs tutorial. Always
   persist tutorial state.

❌ **Persisting `tick` or other runtime fields** — engine internals
   leak into save format.

## What you DON'T do

- ❌ Implement the save/load engine — that's ADR 0010 implementation
- ❌ Decide which entity defs ARE persistent-tagged — content-designer
  picks tags; this skill just lists which tags persist
- ❌ Author the save UI (slot picker, save buttons) —
  yume-screen-flow-designer
- ❌ Author the save_state effect rules — yume-systems-designer (post
  ADR 0009 revision 2026-05-16, rule authoring including save_state
  effects lives in world/rules/*.json feature modules, not in the now-
  removed game/goals.json)

## When invoked by orchestrator

After yume-game-planner + yume-content-designer establish the
entity vocabulary + world_state keys. Skill produces:
1. save-policy-design.md (rationale per key/tag/trigger)
2. save_policy.json (the data file)

Returns summary: persisted key count, persistent tag count, autosave
triggers, slot count.

## Reference files

- docs/adr/0010-save-load-persistence.md — the schema + engine semantics
- docs/adr/0014-open-world-foundational-substrate.md — persistent-tag
  interaction with chunked worlds
