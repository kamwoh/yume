# yume_codegen — Python composable builders for Yume JSON

JSON is the canonical authoring format (per ADR 0021 + Invariant #1).
This package is an **optional** Python emitter — it produces the same
JSON dicts you'd hand-author, but with named keyword arguments,
type-checked schemas, and helpers that prevent recurring authoring
bugs.

## Why use it

Recurring bug classes in hand-authored rule JSON:

1. **Brace-wrapped bindings** (`"{world.X}"` instead of `world.X`)
   — engine sends the literal string through the formula evaluator,
   fails to parse, generates thousands of `formula.parse_failed`
   errors.
2. **Wrong context-binding names** (`self.foo` in a signal rule
   whose binding is `actor.foo`) — engine returns null, downstream
   `.state.X` access crashes with `self can't be used because
   instance is null`.
3. **Field-name landmines** (`state_add` with `delta` instead of
   `amount`, `spawn` with `def` instead of `template`) — engine
   silently no-ops.
4. **Empty effect lists** — engine load-time error.
5. **Pair queries on non-contact triggers** — second binding never
   resolves; rule fails at runtime.

These slip through hand-authored JSON because there's no schema
check until the validator (or runtime) catches them. With codegen,
the typed parameter list catches the obvious cases at author time;
omitting required fields raises `TypeError` immediately.

## When to use vs hand-author

**Use codegen** when:
- Generating many similar rules (e.g. 50 variations of "X-tier
  customer pays N-gold for class-Y item")
- The rule's effect chain is long and order-sensitive (codegen
  makes the destructive-last-in-chain pattern obvious)
- You want to validate inputs before emitting (`array_set_at`
  with no `result_field` raises `TypeError` if you try)

**Hand-author** when:
- One-off rules, short effect chains, low risk of typos
- Quick edits to existing JSON files
- The rule shape is idiomatic ("if X then Y") and Python adds
  no clarity

Both paths coexist — codegen emits to JSON files that the engine
reads exactly like hand-written ones. You can mix:

```python
from tools.yume_codegen import rule, tick, query, state_add, save_rules, load_json

# Load existing hand-written rules
existing = load_json("godot/data/demo_X/world/rules/00_combat.json")

# Append codegen-built rules
existing["rules"].extend([
    rule(id=f"poison_tier_{tier}",
         trigger=tick(interval=60),
         query=query(tags_all=["poisoned"], state={"tier_eq": tier}),
         effect=state_add(target="self", field="hp", amount=-tier))
    for tier in range(1, 6)
])

# Write back
import json
with open("godot/data/demo_X/world/rules/00_combat.json", "w") as f:
    json.dump(existing, f, indent=2)
```

## Top-level imports

```python
from tools.yume_codegen import (
    # Rules
    rule, tick, contact, signal_trigger, input_trigger,
    spawn_trigger, despawn_trigger,
    query, require, pair_query,

    # Effects
    state_set, state_add, state_mul, state_clamp,
    spawn, remove, tag_add, tag_remove,
    emit, emit_shell_event,
    transition_screen, transition_level, screen_fade, show_toast,
    save_state, load_state, reset_world,
    relate, unrelate,
    array_set_at, array_insert_first_empty,
    array_sync_to_field, array_count_matching,

    # Entities
    entity, instance, state_init, visual, physics,

    # Screens / HUD
    screen, label, panel, progress_bar, slot_grid, item_icon,
    button, image, image_3d, control, minimap, global_input,

    # Lib refs
    lib_ref, include_lib, cue_ref, string_ref,

    # IO
    save, save_rules, save_entities, save_screens, load_json,
)
```

## Example — building a TDTE rules file

```python
from tools.yume_codegen import (
    rule, tick, signal_trigger, query, require,
    state_add, state_clamp, array_insert_first_empty, array_set_at,
    show_toast, remove, save_rules,
)

rules = [
    # vital decay every second
    rule(
        id="hunger_decay",
        comment="Hunger drops 1/sec while awake",
        trigger=tick(interval=60),
        query=query(tags_all=["player"], state={"sleeping_eq": 0}),
        effect=[
            state_add(target="self", field="hunger", amount=1),
            state_clamp(target="self", field="hunger", min=0, max=100),
        ],
    ),
    # pickup chain (the bug-prone one — actor.state._last_slot is
    # carried through a sequence of effects; codegen makes the
    # binding name obvious at author time)
    rule(
        id="gather_pickup",
        trigger=signal_trigger("gather_request"),
        require=require(
            actor={"tags_all": ["player"], "state": {"inventory_empty_count_gt": 0}},
            target={"tags_all": ["forageable"]},
        ),
        effect=[
            array_insert_first_empty(
                target="actor", field="inventory",
                value="target.def_id", sentinel="",
                result_field="_last_slot",
            ),
            array_set_at(
                target="actor", field="inventory_cooked",
                index="actor.state._last_slot",  # ← validator + codegen confirm 'actor' binding exists
                value="target.state.cooked",
            ),
            show_toast("Picked up."),
            remove(target="target"),
        ],
    ),
]

save_rules(
    "godot/data/demo_aldenmere/world/rules/02_inventory.json",
    rules,
    comment="Aldenmere inventory rules — generated 2026-05-17",
)
```

## Running the smoke test

```bash
python3 -m tools.yume_codegen
# or
python3 -m tools.yume_codegen.tests.test_smoke
```

Exit code 0 on success; prints each assertion's pass/fail.

## Layout

```
tools/yume_codegen/
├── __init__.py     # exports everything (no submodule imports needed)
├── __main__.py     # `python3 -m tools.yume_codegen` runs smoke
├── rules.py        # rule(), tick(), contact(), signal_trigger(), query(), require(), pair_query()
├── effects.py      # state_set, state_add, spawn, remove, transition_screen, ...
├── entities.py     # entity, instance, state_init, visual, physics
├── screens.py      # screen, label, panel, progress_bar, slot_grid, ...
├── lib_refs.py     # lib_ref, include_lib, cue_ref, string_ref
├── io.py           # save, save_rules, save_entities, save_screens, load_json
├── tests/test_smoke.py  # 30+ smoke assertions across all modules
└── README.md       # this file
```

## Authority hierarchy

1. JSON is canonical — the engine reads it authoritatively.
2. `tools/validate_rules.py` + sibling validators are the contract gate.
3. codegen emits JSON that **passes** the validators.
4. Hand-authored JSON remains fully supported alongside codegen.

If codegen ever emits something that fails a validator, the codegen
is wrong — file a fix.

## Empirical motivation

Task #101, 2026-05-17. Two incidents in one session
(`gather_pickup` referencing `self.state._last_slot` then
`actor.state._last_slot` after a partial fix) showed that
hand-authored signal-rule effects routinely use the wrong binding
name. `require(actor=..., target=...)` in codegen makes the
binding names visible upfront, and the formula strings sit next to
them in code review.
