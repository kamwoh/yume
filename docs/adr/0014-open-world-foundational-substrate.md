# ADR 0014 — Open world as foundational substrate

_Date: 2026-05-06_
_Status: **proposed**_

## Context

Most games are open-world in their fundamental shape:

- Harvest Moon = farm + town + mountain — open world with daily rhythm
- Final Fantasy = overworld + dungeons + cities — open world with
  loading transitions
- GTA = LA-sized open world
- Stardew Valley = village + caves + ocean — open world
- The proposed merchant game = shop + town + markets — also open world

What differs between these is NOT the spatial structure — it's:
- World physics (gravity, fire spread, water)
- Game rules (combat, win conditions)
- NPCs (who, when, what they do)
- Economy
- Narrative arcs
- Game-specific logic (the plugin layer — ADR 0019)

Yume currently treats levels as the base unit (ADR 0006). Each level
loads all its content at once. This works at the prototype scale
(~100 entities) but does NOT generalize to:

- Towns with 50+ NPCs going about their day
- Multi-district cities the player traverses
- Connected sub-areas without artificial loading screens
- Persistent world state that survives "going somewhere else"

This ADR promotes **open-world** from a "future genre extension" to a
**foundational substrate** every Yume game can rest on. Specifically:

1. Spatial streaming — load/unload regions as the player (or active
   actor — see ADR 0016) moves
2. Persistent vs transient distinction at the chunk level (not just
   entity level)
3. Sub-world transitions (existing multi-level + new chunk-streaming
   coexist; both compose on the same primitive)
4. World-state that survives chunk eviction (NPCs you met still exist
   when you return)

The shipped open-world capability becomes the BASE; "single-level
prototype" becomes a degenerate case (one chunk, no streaming).

## Decision

Add a **chunked-world architecture**: each game ships a `world.json`
declaring chunk dimensions, streaming radius, and persistent-tag
policy. The engine loads/unloads chunks based on active-actor
position. Per-chunk content lives in `chunks/<x>_<y>/entities.json`
(extending ADR 0006's per-level pattern).

Existing multi-level games (sokoban, doomarena3d, multilevel) become
"single-chunk-per-level games." The level transition mechanism
(ADR 0006) is RETAINED for game-flow events; chunk streaming handles
spatial traversal within a level/world.

### File layout

```
data/<game>/
├── world.json                  # NEW — open-world meta
├── world/state.json            # global state
├── world/physics.json          # rules
├── chunks/                     # NEW — per-chunk content
│   ├── 0_0/entities.json       # chunk at origin
│   ├── 0_1/entities.json
│   ├── 1_0/entities.json
│   ├── ...
│   └── _persistent/entities.json  # entities that survive chunk eviction
└── ... (existing files)
```

`world.json` schema:

```jsonc
{
  "_comment": "Open-world meta. Chunks are 320x320 world-units (~10x10 grid cells in pixel coords). Player-radius streaming loads chunks within 1 chunk; unloads beyond 2 chunks.",

  "chunk_size": [320, 320],
  "stream_radius": 1,           // load chunks within N of active actor
  "unload_radius": 2,           // unload beyond N (hysteresis)

  "starting_chunk": [0, 0],
  "starting_position": [160, 160],

  "persistent_tags": ["named_npc", "shop", "story_relevant"],
  // entities with these tags load from chunks/_persistent/ once and
  // survive chunk eviction. Their positions can be ANYWHERE, not
  // constrained to a chunk.

  "boundary_mode": "clamp"      // or "wrap" or "infinite"
  // clamp: player stops at world edge; wrap: torus topology;
  // infinite: chunks generate procedurally (separate ADR if needed)
}
```

### Engine work

1. `scripts/engine/chunk_streamer.gd` — new module:
   - Tracks active actor position (per ADR 0016)
   - Computes which chunks should be loaded
   - Loads `chunks/<x>_<y>/entities.json` for new chunks
   - Despawns entities in chunks leaving stream radius (except
     persistent-tagged)

2. `world.gd` integration:
   - On `load_data()`, if `world.json` declares chunked-world mode:
     load `chunks/_persistent/` + `chunks/<starting_chunk>/`
   - On player movement, invoke chunk_streamer.update()
   - Chunk-loaded entities tagged internally so streamer knows what's
     transient

3. World-state persistence across chunks:
   - `world.world_state` is global (survives chunks)
   - Per-NPC state: if tagged persistent, position + state survive
     when player leaves the chunk; entity is just despawned visually

4. Spatial index already supports unbounded coords (W3.1) — verify at
   scale.

5. Coordinates: chunk (x, y) maps to world position
   `(x * chunk_size.x, y * chunk_size.y)`. Entities within a chunk
   use chunk-local OR world-absolute coords (config flag in
   `world.json`).

### Backward compat

Existing demos work unchanged. `world.json` is OPTIONAL — if absent,
engine treats game as "single-chunk world" (current behavior). Demos
opt into chunked-world by adding the file.

### Composition with existing ADRs

- **ADR 0006 (multi-level)** — coexists. A "level" is a logical unit
  (sokoban level 1); a "chunk" is a spatial unit. Both can be used
  together: a multi-level RPG has levels (overworld, dungeon-A,
  dungeon-B), each level is its own chunked world.
- **ADR 0009 (world/game/flow split)** — chunks belong to the world;
  per-chunk rules can land in `world/physics.json` or per-chunk
  `chunks/<x>_<y>/rules.json` (game-specific rule overrides).
- **ADR 0010 (save/load)** — save_policy can specify per-chunk
  persistence vs world_state vs persistent_tag entities. Saves
  serialize whatever the policy says, regardless of which chunks are
  loaded at save time.

## Consequences

**Enables:**
- Open-world games (towns, cities, overworlds) at any scale
- Persistent NPC schedules across regions
- Faster initial load times (only the starting chunk + persistent
  entities)
- Larger total world content without memory bloat
- Foundation for "explore the world" gameplay (Stardew, Harvest Moon,
  Zelda, GTA-shaped)

**Constrains:**
- Per-game authoring requires thinking in chunks. Larger upfront
  effort but avoids rewriting later.
- Streaming has cost (every move check; load/unload is JSON parse +
  entity instantiation). Chunk size is the tuning knob: larger
  chunks = fewer loads, more memory; smaller = opposite.
- Persistent-tag entities may have stale spatial-index entries when
  their chunk is unloaded. Need a "ghost" representation in spatial
  index so they're still queryable.

**Doesn't enable:**
- Procedurally generated infinite worlds (separate ADR — boundary_mode
  "infinite" is a placeholder)
- LOD-based detail scaling beyond load/unload (visual fidelity per
  distance — out of scope; 2D)
- Multi-actor stream-radii — only ONE active actor's chunks load.
  When ADR 0016 lands, may need per-actor streaming.

## Alternatives considered

### A. Stay single-chunk (status quo)

Reject: blocks all open-world games. Limits Yume to puzzle / arena
genres.

### B. Load entire world at startup

Works for small worlds (~1000 entities). Breaks at GTA scale. Picking
chunked-world from the start is cleaner than retrofitting.

### C. Make every "level" a chunk (subsume ADR 0006)

Tempting unification. Rejected: levels are FLOW units (you complete a
level to advance the story); chunks are SPATIAL units (you traverse
to look around). Different lifecycles. Sokoban is naturally
multi-level; an open-world RPG is naturally chunked. Keep both.

## References

- ADR 0006 (multi-level architecture) — coexists
- ADR 0009 (world/game/flow split) — chunks fit into "world/" layer
- ADR 0010 (save/load) — composes
- ADR 0016 (multi-actor) — informs which actor's position drives
  streaming
- ADR 0017 (spatial-LOD rule scheduling) — perf-critical for chunked
  worlds with many active rules
