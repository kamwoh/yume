# Grid System Proposal — Sims-style Tiled World

**Status:** Design proposal. Not implemented.

## Motivation

Current world is continuous: objects have float (x, z) positions, agents walk freely, collision is per-object. This works but:
- **Placement is implicit** — no hard rule that "this tile is occupied"
- **Hard to reason about adjacency** — "is there a tree NEXT TO me?" needs distance math
- **Pathfinding is per-move math** — A* works but on a floating-point grid we improvised
- **Size is ad-hoc** — each collision box is authored separately; no canonical footprint per object

## What a grid gives us

| Before | After |
|---|---|
| `{x: 4.2, z: 1.8}` | `{gx: 4, gz: 2}` — integer tile coords |
| Collision box per object | Tile occupancy (1 object per tile, or multi-tile footprint) |
| Distance-based neighbor check | `world.tile(gx+1, gz)` — O(1) neighbor |
| Overlap possible (authoring error) | Occupancy prevents overlap at spawn time |
| Ad-hoc object sizes | Canonical `size: [w, d]` field per element (in tiles) |

## Hybrid model (what I'd propose)

- **Structures** (houses, campfires, chests, fences, trees, rocks) → grid-placed
- **Agents** → continuous movement, but pathfind ON the grid + respect tile occupancy
- **Ground/terrain** → continuous (heightmap unchanged)
- **Decorations** (flowers, grass) → continuous (visual only, no occupancy)

This matches Sims / Stonehearth / RimWorld / Dwarf Fortress. Structures live on a grid; actors move smoothly between them.

## Schema changes

### elements.json

Add two fields to every non-decoration element:

```json
{
  "id": "house_small",
  "size": [2, 2],           // tile footprint (w, d)
  "occupies_tile": true,    // tile cannot hold another non-stackable
  ...existing...
}
```

For 3D collision box, default to `[size.x, 2.5, size.y]` tiles (auto-derived) with override via existing `collision` field.

### generated_world.json

Object positions become integer tiles:

```json
{
  "element": "campfire",
  "gx": 0, "gz": 0,       // grid coords, not x/z
  "rotation_y": 0
}
```

World-space position = `Vector3(gx * tile_size, 0, gz * tile_size)` where `tile_size=1.0`.

### world_config.json

```json
{
  "world_size": {"tiles_w": 100, "tiles_h": 100},
  "tile_size": 1.0
}
```

## Required engine changes

1. **`world_grid.gd`** (new) — 2D array tracking tile occupancy. Spawn checks + reserves tiles. `get(gx, gz) → element_node`. `neighbors(gx, gz) → Array[element]`.
2. **`world_elements.gd`** — change placement to read `gx, gz` + `size`, reserve tiles, reject overlapping spawns.
3. **Collision helper** — derive BoxShape3D from `size` if no explicit `collision` field.
4. **`brain_needs_driven.gd`** — `_find_nearest_element_in_world` could use grid O(1) neighbor iter instead of tree walk. Optional optimization.
5. **Pathfinding** — `pathfinding_astar.gd` currently operates on `nav_grid.json` for dungeons. For sim, needs grid-occupancy-aware A*.
6. **Generator** — `generate_sim_world.py` emit `gx/gz` not `x/z`. Zones need integer rect bounds. Poisson disk sampler → tile sampler.
7. **Composites** — house parts already use integer-ish offsets (we did this for Kenney 2u grid). Straightforward.

## What breaks immediately

- Every `x/z` field in existing data → becomes `gx/gz`
- `poisson_scatter` in generator → tile-based sampling
- `zones` with float min/max → integer tile rects
- `camp` positions → integer
- `landmarks` → integer
- Composites' `offset` currently in mesh units (2u grid) → interpretation clarified (still float within a tile for sub-tile positioning)

## Cost estimate

| Phase | Work | Effort |
|---|---|---|
| 1 | Add `size` field + derive collision from it (no grid yet) | 30 min |
| 2 | `world_grid.gd` + occupancy tracking | 2 hours |
| 3 | Migrate all element positions to gx/gz in data + generator | 2 hours |
| 4 | Pathfinding + brain updates | 1 hour |
| 5 | Test + fix edge cases | unknown |

**Total: ~1 session dedicated to this.**

## Payoff

Immediate:
- No more overlapping spawns (bugs we've hit)
- Canonical object footprints (reusable across placement/collision/planning)
- Cleaner data format

Long-term:
- Easy neighbor checks enable:
  - Fire spread: "any flammable neighbor?" becomes O(8) tile check
  - Building placement validation
  - Agent reasoning: "what's in my 3x3 area?"
  - Territory / ownership
- Cheaper serialization (integer coords compress well)
- Save/load becomes easier (grid state is a 2D array)

## Open questions

1. **Sub-tile positioning** — flowers sit at float coords within a tile? Or also tile-aligned? (Probably tile-aligned, just rotated.)
2. **Multi-tile objects** — house is 2x2. Anchor at corner or center? (Probably corner, gx/gz is bottom-left.)
3. **Agent tile** — agents occupy a tile during pathing or just pass through? (Pass through. Agents don't reserve.)
4. **Rotation** — tiles are axis-aligned; objects can rotate but footprint stays AABB.

## Recommendation

**Don't build this now.** We've just made huge progress on the simulation foundation. Grid would be a 2-4 hour detour. Validate the current architecture more (run sims, see emergent behavior, find the REAL pain points) before committing.

**Do build this when:**
- Fire spread / territory / neighbor-based rules get cumbersome
- We start hitting overlap bugs at scale
- Agents need more spatial reasoning
- We want save/load
