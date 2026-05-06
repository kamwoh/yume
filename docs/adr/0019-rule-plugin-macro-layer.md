# ADR 0019 — Rule plugin / macro layer (composed-effect templates)

_Date: 2026-05-06_
_Status: **proposed**_

## Context

Yume rules are pure JSON declarations. Effect types come from a
fixed engine vocabulary (Invariant #8: engine = primitives +
interpreter). This works well for most game logic but has a
recurring pain point: **boilerplate**.

Examples from existing demos:

- doomarena3d's "deal damage" pattern: `state_add hp -X` +
  `emit damaged signal` + `play_sound` + maybe `tag_add stunned`.
  Repeated across 8+ rules.
- harvestcore's "harvest crop" pattern: `spawn produce_item` +
  `tag_remove ripe` + `state_set growth 0` +
  `emit crop_harvested signal`. Repeated for each crop type.
- merchant game (proposed): "sell item" pattern: `state_add gold +X` +
  `remove item entity` + `emit sale_made` + `state_add reputation +1`
  + maybe `transition_screen`.

Every rule in these patterns repeats 3-5 effects. If the pattern
needs to change (e.g. "all damage now also applies bleeding"),
authors update every rule by hand. Mistakes happen. Patterns drift.

The user's framing: **"specific rule plugin, like lambda function in
Python, dynamically add some rules so the engine able to interpret
this plugin."**

The principled solution: **composed-effect macros**. Per-game JSON
file declares NEW effect types that EXPAND to a sequence of existing
primitives + parameter substitution. The engine reads these at load
time and registers the new effect handlers.

This stays within Invariant #1 (JSON-only content channel) AND
Invariant #8 (engine ships fixed primitives, content composes them) —
the macro IS just a content composition; the engine executes only
existing primitives at runtime.

## Decision

Add a **macro file** per game (`macros.json` or
`game/macros.json`) that defines new effect names that expand to
sequences of existing effects with parameter substitution.

### File layout

```
data/<game>/
├── macros.json                # NEW (or game/macros.json)
└── ...
```

### Macro schema

```jsonc
{
  "_comment": "Per-game effect macros. Each defines a new effect name that expands at load time.",

  "macros": [
    {
      "name": "deal_damage",
      "params": ["target", "amount", "source"],
      "expands_to": [
        {"type": "state_add", "target": "$target", "field": "hp", "amount": "-$amount"},
        {"type": "state_clamp", "target": "$target", "field": "hp", "min": 0, "max": "$target.properties.max_hp"},
        {"type": "emit", "signal": "damaged",
         "payload": {"target": "$target", "amount": "$amount", "source": "$source"}},
        {"type": "emit_shell_event", "event": "play_sound", "name": "@cues.damage_hit"}
      ]
    },

    {
      "name": "harvest_crop",
      "params": ["crop_id", "produce_template"],
      "expands_to": [
        {"type": "spawn", "template": "$produce_template",
         "position": "$crop_id.state.position"},
        {"type": "tag_remove", "target": "$crop_id", "tag": "ripe"},
        {"type": "state_set", "target": "$crop_id", "field": "growth", "value": 0},
        {"type": "emit", "signal": "crop_harvested",
         "payload": {"crop": "$crop_id"}}
      ]
    },

    {
      "name": "sell_item",
      "params": ["item_id", "price"],
      "expands_to": [
        {"type": "state_add", "target": "world", "field": "gold", "amount": "$price"},
        {"type": "remove", "target": "$item_id"},
        {"type": "emit", "signal": "sale_made",
         "payload": {"item": "$item_id", "price": "$price"}},
        {"type": "state_add", "target": "world", "field": "reputation", "amount": 1}
      ]
    }
  ]
}
```

### Usage in rules

After registering macros, rules can use them like any built-in
effect:

```jsonc
{
  "id": "bullet_kills_monster",
  "trigger": {"type": "contact"},
  "query": {"a": {"tags_all": ["bullet"]},
            "b": {"tags_all": ["monster"]}},
  "effect": [
    {"type": "deal_damage", "target": "b", "amount": 10, "source": "a"},
    {"type": "remove", "target": "a"}
  ]
}
```

The engine expands `deal_damage` to its underlying sequence at rule
load time (or rule fire time — see implementation).

### Engine work

1. `scripts/engine/macro_expander.gd` — new module:
   - Loads `macros.json` at world boot
   - Builds a registry: `macro_name → expansion_template + params`
   - On rule registration (or on fire), if an effect's `type`
     matches a macro name, expand it inline:
     - Substitute `$param` references with the rule call's
       arguments
     - Recursively expand if the expansion itself uses macros
       (with recursion limit)

2. Parameter substitution rules:
   - `$param_name` → the value passed in the rule's effect dict
   - `$param.field` → traverse into the param if it's an entity ref
   - Negation (`-$amount`) and arithmetic (`$x * 2`) work via
     existing Formula primitive

3. Validation at load time:
   - Every macro reference's params match macro signature
   - Recursion depth bounded (e.g. 4 levels deep)
   - Tech-director invariant check: macros expand ONLY to
     primitive effect types (no semantic-effect-type aliasing)

4. Two implementation choices:
   - **A: Expand at load time** — each rule's effect list is
     pre-expanded; runtime is unchanged. Memory cost; can't have
     recursive macros. Simpler.
   - **B: Expand at fire time** — macro lookup per effect each tick.
     Allows recursion / parameterization at runtime. Slower; more
     flexible.

   Recommend A for v1; switch to B if needed.

### Macro safety / invariants

Tech-director must verify:

1. **Macros expand to PRIMITIVE effect types only.** A macro can use
   `state_add`, `state_set`, `spawn`, etc. — but cannot reference
   another macro... actually let macro-using-macro work, but
   transitively the leaves must be primitives.

2. **Macros cannot introduce new VOCABULARY** — they're pure
   composition. They cannot make the engine do something it
   couldn't do before.

3. **Macro names cannot shadow built-in primitives.** If a game
   defines `state_add`, error at load.

4. **Macros are per-game, not engine-wide** — each game has its own
   `macros.json`. The macro names don't leak across demos.

5. **Macros preserve the ban on semantic effect types.** A macro
   named `deal_damage` is fine because it expands to state_add (a
   primitive). A macro named `damage` that "feels like" the banned
   effect type — also fine; the rule check is about IMPLEMENTATION
   (does the engine handle it?), not naming.

### Backward compat

Existing demos work unchanged. `macros.json` is OPTIONAL. Demos
gain macros only by adding the file.

## Consequences

**Enables:**
- DRY rule authoring (no more 5-effect repetition)
- Per-game vocabulary (each game can have its own gameplay verbs)
- Easier evolution (change macro definition; all uses update)
- Foundation for genre-specific patterns (combat, crafting, social
  interaction)
- Cleaner GDD-to-rules translation (game-rules-designer can think in
  semantic verbs, knowing the engine will expand them)

**Constrains:**
- New file means new authoring discipline
- Bad macro design = worse than no macro (over-eager generalization
  burns)
- Recursion + complex parameter substitution can introduce bugs
  that are hard to trace (rule fires X but engine actually does Y)
- Tech-director must re-verify Invariant #2 (no semantic effects)
  on every game's macros file

**Doesn't enable:**
- True dynamic logic (loops, conditionals beyond what Formula
  expresses)
- Turing-complete game scripting (would violate Invariant #8)
- Custom collision math, custom AI algorithms (still engine-level
  primitives needed for those)

## Alternatives considered

### A. Per-game GDScript plugin files

Strongest expressiveness; clear violation of Invariant #1.
Rejected.

### B. Embedded scripting language (Lua, Python sandbox)

Adds dependency + interpreter overhead + security questions.
Rejected for v1; macros cover 80% of use cases.

### C. Just expand AST whitelist for Formula language (W4.5 deferred)

Formula language could grow to support functions and conditionals.
This is complementary, not alternative — formula expansion handles
arithmetic; macros handle effect composition. Both valuable.

### D. Engine adds new built-in semantic effect types when patterns
emerge

Conflicts with Invariant #2 (no semantic types). And every game has
its own patterns; a central engine vocabulary doesn't scale.

## References

- Invariant #1 (JSON-only content channel) — preserved
- Invariant #2 (no semantic effect types) — macro check is the gate
- Invariant #8 (engine = primitives + interpreter) — preserved;
  macros are content
- W4.5 (deferred AST whitelist for Formula) — complementary
- ADR 0009 (world/game/flow split) — macros could be per-layer
  (world physics has its own macros vs game rules)

## Tech-director review

_Date: 2026-05-06_
_Reviewer: yume-tech-director_

### Invariant checks

| Invariant | Status | Notes |
|---|---|---|
| #1 JSON-only content channel | ✓ | macros are JSON; expansion produces existing primitives |
| #2 No semantic effect types | ✓ | THE invariant this ADR is designed around — macros expand to primitives only; tech-director-checkable |
| #3 No entity-class hierarchy | ✓ | none |
| #5 Queries first-class | ✓ | none changed |
| #8 Engine = primitives + interpreter | ✓ | macros are CONTENT composition; engine still ships fixed primitives |
| #9 Phase ordering | ✓ | doesn't change phase ordering |

This ADR is the cleanest of the six on invariant grounds. Designed
for invariants from the start. Excellent contract-conscious design.

### Concerns

1. **Recursion bound insufficient as stated**. Depth ≤ 4 prevents
   infinite recursion within a chain, but doesn't prevent EXPANSION
   EXPLOSION: 4 levels × 5 sub-effects each = 625 effects from one
   rule call. Recommend additional bound: max-expanded-effect-count
   per rule (suggest 50). Both bounds enforced; load fails with
   structured error if exceeded.

2. **Mutual recursion not addressed**. Macro A calls B, B calls A.
   The depth bound catches this eventually (at depth 4) but the
   error is opaque. Add explicit cycle detection at load time —
   parse macro graph, detect cycles, error before any expansion.

3. **Expand-at-load vs expand-at-fire-time**. ADR recommends load-
   time. Concur, but be explicit: load-time substitutes ONLY the
   macro's `params`; runtime context bindings (self, target, a, b)
   are unchanged at fire time. This makes macros COMPILE-TIME
   templates, not runtime functions. Cleaner.

4. **Per-game scoping**. Macros are per-game by file location.
   Confirm explicitly that no cross-game macro reference is
   possible. If sokoban defines `deal_damage`, it's not visible to
   doomarena3d.

5. **Tech-director ongoing burden**. ADR says I must verify
   Invariant #2 "on every game's macros file." This is a real cost
   per new game. Mitigation: extend the existing api-manifest CI
   check to scan all `data/<game>/macros.json` and flag any macro
   whose `name` matches a forbidden semantic word (damage, heal,
   attack, etc.). Make the check automated, not human.

6. **Backward compat is genuine**. macros.json absent → empty
   registry → expansion no-op. No risk to existing demos. Confirmed.

7. **Cross-ADR concern (raised by user)**: macros change the
   rule-loading pipeline. Every demo's rules pass through the
   macro expander.
   - In CONTRACT terms (preserves invariants), this IS low risk.
   - In IMPLEMENTATION terms, the rule-loading code path changes
     for every demo. Test plan must include regression tests for
     all 13 demos: each should load + run with identical rule
     behavior to pre-macro-expander baseline.
   - This is NOT as low-risk as ADR claims for implementation,
     even though it's contract-clean.

8. **`$param.field` traversal underspecified**. Example shows
   `"$target.properties.max_hp"`. Is this a Formula, a path lookup,
   or a special macro syntax? Spec the resolution rules:
   - `$param` = direct substitution of the param value
   - `$param.field` = if param is an entity ref, look up the field
     via existing context-binding rules
   - Anything else = parse as Formula at fire time

### Verdict

**accept-with-conditions**.

Conditions before implementation:

1. **Add max-expanded-effect-count bound** (suggest 50) per rule.
   Both depth ≤ 4 AND total expanded effects ≤ 50.
2. **Add explicit cycle detection** at load time. Cycle = error
   with macro_id chain identified.
3. **Spec load-time vs fire-time**: load-time substitutes `$param`;
   fire-time substitutes context bindings. Document with examples.
4. **Confirm per-game scoping**: macros are NOT cross-game. State
   in ADR.
5. **Automate Invariant #2 check** in api-manifest CI: scan all
   macros.json for semantic-effect-name macros; fail build if found.
6. **Test plan**: regression tests confirming all 13 demos load
   + tick identically pre/post macro-expander integration.
7. **Spec `$param.field` traversal** semantics (recommend: same
   as Formula's binding resolution, applied at fire time even for
   load-time-expanded macros).

This ADR can land FIRST in the build order (lowest contract risk;
biggest authoring win). Implementation risk is moderate (rule-loader
change), but tests catch regressions if covered.
