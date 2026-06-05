# ADR 0010 — Save / load persistence

_Date: 2026-05-06_
_Status: **accepted (TD review 2026-05-06)**_

## Context

No Yume demo persists state across sessions. Players close the game,
reopen, and start over. This is fine for prototypes but blocks
shipping a "complete" game in two ways:

1. **Real games take longer than one session.** Sokoban with 8 levels
   ≈ 30-60 minutes. Merchant game across 30 in-game days ≈ 2-4 hours.
   Players can't be expected to finish in one sitting.
2. **No cross-session progression** means achievements, unlocked
   content, and meta-progression all become impossible. Many "complete
   game" features depend on save/load existing.

The framework has the data primitives needed to serialize state —
entity dictionaries, world_state, relations — but no architecture for
deciding **what** gets serialized. A naive "save everything" would
balloon save files (every projectile, every tile) and break across
content updates (a save from v1 fails to load in v2 because new
entity defs exist).

## Decision

Add a **declarative save policy layer**: each game ships a
`save_policy.json` that tells the engine which world_state keys,
which entity tags, and which relation types persist. The engine has
exactly one save/load implementation; per-game variation lives in
JSON.

### File layout

```
data/<game>/
├── save_policy.json       # what gets saved (per-game)
└── ... (existing files)

user://saves/<game>/
├── slot_0.json            # save data, written by engine at runtime
├── slot_1.json
└── slot_2.json
```

Save files live under Godot's `user://` (cross-session, per-OS user
data). Path resolves to `~/.local/share/godot/...` on Linux,
`%APPDATA%\Godot\...` on Windows.

### `save_policy.json` schema

```jsonc
{
  "_comment": "Sokoban save policy. Slots = 3, persists progression + tutorial state across sessions. Per-level entity state (player position, box positions) does NOT persist — level reload is fresh.",

  "world_state_keys": [
    "current_level",
    "tutorial_step",
    "score",
    "achievements_unlocked"
  ],

  "entity_tags_persistent": [
    "named_npc"
    // entities with these tags: their full state + position serialize
  ],

  "entity_state_blacklist": [
    "_temp_*",
    "diag_*"
    // glob patterns; matching state fields are EXCLUDED from save
  ],

  "relations_persistent": ["owns", "knows"],

  "slots": 3,

  "autosave": {
    "on_signal": ["level_won", "story_beat_fired"],
    "on_level_transition": true,
    "interval_ticks": 0
  },

  "version": 1
  // schema version; engine refuses to load saves with mismatched
  // version + emits a structured error
}
```

### New effect types

Two new effects on the existing effect_apply.gd:

```jsonc
{"type": "save_state", "slot": 0}
// Serializes per save_policy.json into user://saves/<game>/slot_0.json.
// Slot 0 = autosave by convention; named slots also fine.

{"type": "load_state", "slot": 0}
// Deserializes; replaces world_state + persistent entities.
// Triggers a level reload of world_state.current_level.
```

Both are buffered (apply between ticks) like other effects. Tech-
director invariant check: these are GENERIC verbs (no game-specific
fields hardcoded) — they read the policy file. Composable with any
trigger (input rule, tick rule, signal rule).

### Engine work

1. New `scripts/engine/save_state.gd` module:
   - `save(env, policy, slot)` — serialize per policy
   - `load(env, policy, slot)` — deserialize, mutate env in place
   - Format: top-level JSON with `version`, `world_state`,
     `persistent_entities` (id → {def, position, state, relations}),
     `relations` (filtered list), `_meta` (timestamp, game_name)

2. `effect_apply.gd` gains `save_state` + `load_state` effect handlers.

3. `world.gd` gains `save_data_path()` helper resolving the
   `user://saves/<game_name>/slot_N.json` path.

4. Save validation: on load, if `policy.version` mismatches save's
   `version`, emit structured engine error (Tier 2.6a) and refuse to
   load. No silent migration in v1.

5. `world.world_state["has_save"]` exposed as a binding so menus can
   show/hide "Continue" buttons based on save existence.

### Backward compat

Existing demos work unchanged — `save_policy.json` is OPTIONAL. If
absent, the engine doesn't expose save/load effects (or they no-op
with a warning). Demos remain prototypes; "complete game" flag is
implicit in the existence of `save_policy.json`.

## Consequences

**Enables:**
- Complete games with multi-session progression
- Multiple save slots
- Autosave on meaningful events
- Achievement persistence (achievements_unlocked is just a
  world_state key)
- Variants persisted (which mode the player chose)

**Constrains:**
- Per-game save policy is an authoring step (5-10 min). Worth it for
  the engine simplicity gain.
- Save format is JSON, not binary. Trade-off: human-debuggable + diff-
  able vs slow for huge worlds. Yume's content scale is small enough
  this is fine; if a game ships with 10000+ entities, revisit.
- Schema version bumps require either save invalidation (v1 saves
  unloadable in v2) or a migration story. v1 = invalidation; future
  ADR could add migrations if needed.

**Doesn't enable** (out of scope):
- Cloud sync / Steam Cloud — that's an integration layer
- Shared saves across games — each game has its own save folder
- Cross-platform save format incompatibility (Vector2 vs Vector3
  serialization handles this; verify in tests)

## Alternatives considered

### A. Save EVERYTHING by default

Reject: save files balloon; new entity defs in updates break loads;
ephemeral state (current_velocity, tick_count) shouldn't persist.

### B. Per-entity opt-in via `persistent: true` field

Tag-based opt-in (this ADR's path) is simpler — content-designer
already adds tags; "persistent" is just another tag. Per-entity
booleans are redundant.

### C. Hardcode the save shape in engine

Reject: violates Invariant #1 (JSON-only content channel). Different
games need different policies; engine shouldn't bake any specific
game's needs.

### D. Use Godot's built-in `ConfigFile` / `ResourceSaver`

ConfigFile is fine for settings (flat key-value); not appropriate for
nested entity state. ResourceSaver is for Godot Resources, not our
JSON-driven entities. JSON gives the cross-renderer + diff-able
property we want.

## References

- Invariant #1 (JSON-only content channel) — `docs/guideline/30_framework_primitives.md`
- ADR 0009 Phase 2d (variants) — variants persist via this same
  `world_state_keys` mechanism
- Tier 2.6a — structured engine errors for save version mismatch

## Tech-director review (2026-05-06, post-ADR-0021 framing)

### Invariant checks

| Invariant | Status | Notes |
|---|---|---|
| #1 JSON-only content channel | ✓ | save_policy.json is content; engine reads |
| #2 No semantic effect types | ✓ | save_state / load_state are mechanical |
| #3 No entity-class hierarchy | ✓ | none |
| #5 Queries first-class | ✓ | save uses tag-based filtering |
| #8 Engine = primitives + interpreter | ✓ | bounded primitive surface |
| #9 Phase ordering | ✓ | save/load runs between ticks (deferred-effect pattern) |

### Re-evaluation under ADR 0021

The save/load case is genuinely Yume-specific in a way that JUSTIFIES
engine code:

- The DATA being saved is Yume's entity dictionary + world_state +
  relations — this is Yume's data model, not Godot's.
- The POLICY (which world_state keys, which entity tags) is Yume-
  shaped; Godot has no equivalent concept.
- Godot's `ResourceSaver` saves Resource subclasses; Yume's Entity
  is a Node, not a Resource. Wrapping every entity in a Resource
  for the sole purpose of saving would be reimplementation of the
  wrong shape.
- Godot's `ConfigFile` is for flat key-value (settings); not
  appropriate for nested entity state with positions, tags,
  relations.

What Yume's save/load USES from Godot:
- `FileAccess` for I/O (already in plan)
- `JSON.stringify` / `JSON.parse_string` (already in plan)
- `user://` path resolution (Godot's cross-platform user data dir)

So Yume's save logic IS legitimate engine code, but it COMPOSES
Godot primitives (FileAccess, JSON, user://) rather than reimplementing
them. This is consistent with ADR 0021's "expose-Godot-where-it-fits"
principle.

### Concerns

1. **Future binary save format**. JSON saves are debuggable but
   slow and large for big worlds. If future games need binary saves
   (open-world with thousands of persistent entities), consider
   Godot's `Resource` system as an alternative serialization layer.
   Not required now; flag as future option.

2. **Save policy validation**. ADR mentions schema version + refuse-
   on-mismatch. Good. Add explicit check that `world_state_keys` +
   `entity_tags_persistent` actually exist in the loaded game (warn
   on unknowns; don't silently drop).

3. **Atomic save**. A crash during save would corrupt the slot file.
   Recommend write-to-temp-then-rename pattern (Godot's FileAccess
   supports this). Standard atomicity pattern; trivial to add.

### Verdict

**Status: accepted (conditions resolved at implementation time).**

Conditions:
- Composes Godot's FileAccess + JSON (per existing ADR text)
- Atomic write-then-rename for save robustness
- Schema validation: warn on unknown keys/tags
- Future binary format via Godot `Resource` flagged as future option

Tier classification: this is **infrastructure** (T5 "shell layer" /
"gameplay experience" — making the game a complete product). Cleanly
fits the user's tier framing.
