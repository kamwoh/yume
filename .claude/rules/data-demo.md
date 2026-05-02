---
description: Path-scoped rules for Yume demo data folders
globs: archetypes/core/templates/godot/data/**
---

# Demo data — schema discipline

Demos live as JSON folders under `data/`. They are **content**, not code —
no GDScript files belong here.

## DON'T

- ❌ **Reference engine internals.** No `state.entities[N]`,
  `world.scheduler`, or any non-public field. Use the documented context
  bindings: `self`, `target`, `a`, `b`, `world`, plus payload fields.
- ❌ **Use semantic effect type strings.** Forbidden: `damage`,
  `need_decay`, `heal`, `gain_xp`. Express as `state_add` /
  `state_set` with field naming in JSON.
- ❌ **Hardcode coordinates that assume a specific renderer.** Use the
  W5.0 convention: 2D positions live in pixel-scale; 3D scenes scale
  via `position_scale` export. Same JSON works in both.
- ❌ **Reach into engine source paths.** `sprite_2d`, `model_3d`, and
  `mesh` keys reference asset/library paths — `res://data/...` only,
  never `res://scripts/...`.
- ❌ **Mix bare-id and context-binding in the same target.** Pick one:
  `target: "self"` (context) or `target: "specific_id"` (literal).
  Effect resolution does both, but mixing in one rule confuses readers.

## DO

- ✅ **Tag liberally.** Tags are free; queries depend on them. Anti-tag
  with `tags_none` for exclusion (e.g. flammable but not burning yet).
- ✅ **Use `state_init` for both static initial values AND dynamic state
  to be mutated.** The engine doesn't enforce a static/dynamic split;
  it's a content convention.
- ✅ **Comment heavily.** JSON has no real comments, but `_comment` keys
  are ignored by the engine. Use them for design intent.
- ✅ **Whitelist formula syntax.** Formulas are `Expression` strings.
  Allowed: bindings (`self.state.X`, `target.X`, `world.tick`), math
  helpers (`clamp`, `min`, `max`, `abs`, `sin`, `cos`, `sqrt`, `pow`,
  `floor`, `ceil`, `lerp`, `randf`), arithmetic, comparison, bitwise
  (`<<`, `&`, `|`), Vector2/Array subscript (`v[0]`, `a[1]`), and
  **Python-style ternary `a if cond else b`**. **NOT** C-style
  `cond ? a : b` — Godot 4.6.1 Expression doesn't parse it
  (empirically verified during harvestcore QA, 2026-05-02).
  No function calls outside the math helpers — defer to W4.5 AST
  whitelist when it lands.
- ✅ **Keep demos cross-renderer.** If a rule's `radius` only makes sense
  in 2D pixels, document why; same for 3D world units. Default: pick
  values that work both with `position_scale=0.05` for 3D and pixel
  positions for 2D.

## Schema sketch

```jsonc
{
  "definitions": [
    {
      "id": "wheat_seed",                    // unique def id
      "tags": ["plant", "crop", "seed"],     // membership
      "properties": {                         // STATIC
        "material": "wheat",
        "max_growth": 100
      },
      "state_init": {                         // DYNAMIC
        "growth": 0,
        "wet": 0.0,
        "position": [0, 0]                    // optional override
      },
      "visual": {                             // RENDERER input
        "sprite_2d": "res://...",             // tier 1
        "shape": "tree",                      // tier 2
        "color": "#a0c050"                    // tier 3 fallback
      }
    }
  ],
  "initial_instances": [
    { "def": "wheat_seed", "id": "w1", "position": [10, 5] },
    { "def": "wheat_seed", "id": "w2", "position": [20, 5], "state": {"growth": 50} }
  ],
  "initial_relations": [
    { "type": "on_square", "from": "wp1", "to": "sq_a2" }
  ]
}
```

Rules JSON shape (per `docs/30_framework_primitives.md` §3):

```jsonc
{
  "rules": [
    {
      "id": "rule_id_unique",
      "trigger": {"type": "tick", "interval": 1},
      "query": {"tags_all": ["plant"], "state": {"wet_lt": 0.5}},
      "require": {                              // optional
        "context_role": {"tags_all": [...]}
      },
      "chance": 0.3,                            // optional, default 1.0
      "effect": {...} | [{...}, {...}],
      "before": ["other_rule"],                 // optional ordering
      "after": ["another_rule"]
    }
  ]
}
```

## Validation

When adding a demo, verify:
1. `Rule.validate_all()` passes (structural — id/trigger/effect/chance)
2. All entities tagged consistently (no typos in `tags_all`/`tags_none`)
3. Formulas parse (no syntax errors)
4. Demo runs in both 2D and 3D scenes (if applicable)
5. Goal-state cascades reach expected end state in soak test
