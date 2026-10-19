# Conformance cases

_Last updated: 2026-10-19_

Each folder is a small game with a `tests.json`. Every interpreter of
the spec must pass every case (ADR 0086, ADR 0095). The cases use only
code-drawn content, so they hold no generated assets.

| Case | Checks |
|---|---|
| `rules_and_effects` | rule order, `interval`, effect order, `before`/`after`, `once`, `once_per`, when a value formula resolves |
| `formulas` | the formula language (ADR 0088), with its edge cases |
| `queries_relations` | query clauses, relations, edge state, `relation_changed` |
| `spawn_lifecycle` | spawn ids, `spawn` and `despawn` triggers, `transform`, `remove`, the engine lifetime rule |
| `contact_order` | contact pairs in world order |
| `random_seeded` | the spec generator, and when a roll happens |
| `input_edges` | press-edge and hold-edge actions under `press` and `hold` |
| `calendar` | `advance_time` and `scheduled` rules (ADR 0078) |
| `levels_variants` | level swaps, `persistent_tags`, the kept `_engine` entity, a variant overlay |
| `instance_patterns` | ring, grid, line, scatter, cluster and mirror patterns. Scatter and cluster draw from the spec generator, so their positions are exact |
| `motion_effects` | `velocity_set_relative`, `velocity_add_relative`, `velocity_lerp`, `raycast_hit` |
| `reset_world` | `reset_world`: state, the starting level, and one copy of the global and level rules |
| `save_load` | `save_state` and `load_state`: world state, persistent entities, the state blacklist, a swap to the saved level |
| `physics_robot` | an articulated body (ADR 0091) with sensors (ADR 0092): readback fields, motors, masks, contact from a physics position. Checks with margins |

`random_vectors.json` holds reference values of the spec generator.

## Run

```bash
./scripts/conformance.sh            # the TypeScript host, then Godot
./scripts/conformance.sh --ts-only
```

Godot reads a case as `data/conf_<case>`, next to `data/lib`.

## Add a case

1. Write the game folder and its `tests.json`.
2. Check only exact behaviors. A host-defined value (a physics position,
   a pathfinding route) needs a margin, never an exact value.
3. Run both hosts. If they disagree, read
   `hosts/web/README.md` § When the two hosts disagree.
