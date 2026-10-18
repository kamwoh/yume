# Conformance cases

_Last updated: 2026-10-18_

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
