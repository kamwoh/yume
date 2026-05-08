# ADR 0028 — Cross-game parameterized lib templates (`$params` substitution)

_Date: 2026-05-08_
_Status: proposed_

## Context

ADR 0027 landed `@lib.X.Y` references + `$extends` shallow merge +
`$include` array splice. Multi-level inheritance via chained
`$extends` already works (tested). What's still missing: the OOP
analog of **constructor parameters** — passing values into a lib
entry at reference-site to customize otherwise-fixed fields.

User asked specifically:

> "can we extend the json? like OOP, we do extend/inherit correct?
> can we extend and have custom parameters?"

Today we have two partial coverages:

| Mechanism | Scope | Parameterization | Cross-game |
|---|---|---|---|
| ADR 0019 macros | Effect names (`deal_damage`) | Yes (`$param` substitution) | NO — per-game |
| ADR 0027 `$extends` | Any JSON dict | NO — pure clone-and-override | YES |

What we'd need:

```jsonc
// data/lib/cameras/fps_with_fov.json — preset with placeholders
{
  "mode": "first_person_3d",
  "eye_height": "$params.eye_height",
  "fov_degrees": "$params.fov",
  "mouse_sensitivity": 0.003
}

// per-game scene.json — supply parameters at reference site
{
  "camera": {
    "$extends": "@lib.cameras.fps_with_fov",
    "$params": {"fov": 90, "eye_height": 1.7},
    "follow_tag": "player"
  }
}
```

The result expansion replaces `"$params.fov"` with `90`,
`"$params.eye_height"` with `1.7`, and produces a complete
camera config. Same lib entry serves any game; each picks its
own field of view + eye height.

This is the **single missing primitive** between "static lib refs"
(ADR 0027) and "true OOP-shaped JSON authoring" the user asked
for. With this in place, Yume's JSON system covers:

- Single inheritance (`$extends` chain) — done in 0027
- Field overrides at instance — done in 0027
- Constructor parameters — this ADR
- Polymorphism via tags — done since W1
- Composition over inheritance — `$include` arrays since 0027

We deliberately exclude:

- Multiple inheritance (`$extends: [A, B]`) — diamond problem,
  rejected
- Late binding / virtual methods — tags + queries already cover
  structurally what virtual dispatch provides
- Turing-complete templating — formula language (W4.5) is the
  bound on expressiveness

## Decision

Extend ADR 0027's resolver with one new operator: **`$params`**.

### Operator semantics

When a `$extends` dict (or a top-level `@lib.X.Y` ref via the
`{$ref: ..., $params: ...}` shorthand) carries a `$params` dict,
the resolver substitutes `"$params.<key>"` strings inside the
expanded base with values from the supplied params.

```jsonc
// data/lib/<category>/<name>.json
{
  "field_a": "$params.value_a",        // string substitution
  "field_b": ["$params.value_b", "x"], // works inside arrays
  "nested": {                          // works deep
    "field_c": "$params.value_c"
  }
}

// usage
{"$extends": "@lib.X.Y", "$params": {"value_a": 1, "value_b": 2, "value_c": "hi"}}
```

After expansion + parameter substitution:

```jsonc
{
  "field_a": 1,
  "field_b": [2, "x"],
  "nested": {"field_c": "hi"},
  "_origin": "$extends:@lib.X.Y",
  "_params": {"value_a": 1, "value_b": 2, "value_c": "hi"}
}
```

### Substitution rules

1. **String token**: `"$params.<key>"` (entire string is the
   placeholder) → replaced with the literal value (any JSON type).
2. **String interpolation**: `"prefix-$params.<key>-suffix"` →
   replaced by string concatenation. Useful for ids:
   `"id": "merchant_$params.kind"` + `$params: {"kind": "garron"}`
   = `"id": "merchant_garron"`.
3. **Missing param**: if the base references `$params.X` but the
   spec doesn't supply X → error. Resolver fails with structured
   `EngineError.LIB_PARAM_MISSING` citing the lib entry + param
   name.
4. **Default values**: `"$params.fov | 90"` → use 90 if `fov`
   not supplied. Pipe-syntax mirrors shells. The default literal
   is parsed as JSON (numbers, strings, bools, nulls).
5. **Type integrity**: the resolver does NOT coerce types. If a
   param holds a string but the substitution site needed a number,
   downstream code raises whatever it would for that type.
6. **Pass-through to nested $extends**: if a base's `$extends`
   target also wants params, params propagate down the chain
   (same scope rules — leaf params win at each level).

### `$ref` shorthand for parameter-only references

When you only want params (no overrides), `$extends` is overkill.
Add a parallel `$ref` shorthand:

```jsonc
// equivalent forms:
{"$extends": "@lib.X.Y", "$params": {"a": 1}}
{"$ref":     "@lib.X.Y", "$params": {"a": 1}}
```

Both produce the same expansion. `$ref` is preferred when there
are no overrides — clearer authoring intent ("this IS that lib
entry, with these params"). Backward-compatible — `$extends`
without params still works as in 0027.

### Origin metadata

Resolver stamps both `_origin` (already) and `_params` on
expanded dicts so post-mortems trace which params were supplied.
Engine ignores both at runtime.

### Validation

`tools/validate_lib_refs.py` (extended):
- For each `@lib.X.Y` reference whose lib entry contains `$params.K`
  placeholders, verify the reference site supplies all required
  params (or the placeholder has a `| default` clause).
- Failure: structured error citing the lib entry's missing params
  + the reference site's path.

### Test coverage (Phase 1 spec)

| Test | Verifies |
|---|---|
| `lib_params.test_string_token_substitution` | `"$params.k"` (entire string) replaced with the param's literal value (any type) |
| `lib_params.test_interpolation` | `"prefix-$params.k-suffix"` produces concatenated string |
| `lib_params.test_missing_required_param` | placeholder with no `\|default` and no spec entry → EngineError fires |
| `lib_params.test_default_value` | `"$params.k \| 42"` → uses 42 when not supplied; uses spec's value when supplied |
| `lib_params.test_propagates_through_chain` | base `$extends` parent which itself reads `$params.k`; leaf-supplied params reach the parent's body |
| `lib_params.test_origin_and_params_metadata` | resolved dict has both `_origin` AND `_params` set |
| `lib_params.test_no_params_pass_through` | `$extends` without `$params` works unchanged (0027 backward compat) |
| `lib_params.test_ref_shorthand` | `$ref` produces same result as `$extends` for params-only case |
| `lib_params.test_nested_substitution` | placeholders inside nested dicts and arrays both expand |

### Implementation plan

Phase 1 (resolver extension):
- `lib_resolver.gd::_substitute_params(value, params)` — recursive
  walk of resolved tree, replace `$params.X` placeholders.
  Insert call between merge and stamp steps in `_resolve_extends`.
- New EngineError code: `LIB_PARAM_MISSING`.
- 9 new unit tests in test_runner.gd per the table above.
- `validate_lib_refs.py` extension: detect placeholder set per
  lib entry, check reference sites supply them.

Phase 2 (catalog):
- Convert `@lib.cameras.fps_default` to `@lib.cameras.fps`
  (parameterized; eye_height + fov as params with defaults).
- Add `@lib.entities.npc_base(speed, max_hp, ...)` parameterized
  template.
- Update `data/lib/manifest.json` to declare each entry's
  `_params` schema (name + type + optional default).

Phase 3 (skill discipline):
- Update yume-asset-designer / yume-content-designer / yume-systems-
  designer SKILLs: "if a lib entry takes params, supply them via
  `$params` rather than authoring a sibling preset."

## Consequences

### Enables
- Single parameterized template covers many use cases
  (one `@lib.cameras.fps` instead of fps_60deg / fps_90deg / fps_120deg)
- LLM authoring picks template + params instead of cloning a
  whole preset to adjust one number
- Fixes propagate to all consumers
- Compositional — combine `$extends` chain + params in one expression

### Constrains
- Params must be supplied at reference site (no late binding;
  no global "default params" registry — that's overkill)
- Substitution is string-replacement, not Turing-complete — no
  conditionals, no loops. (Authors who need that use macros or
  rules.)
- Adds resolver complexity (cycle detection now happens in TWO
  axes: ref chain + param dependency). Existing depth-8 bound
  still applies.

### Doesn't enable
- Inheritance with method overrides — that's macros + rules
- Multiple inheritance — by design, single chain only
- Runtime-dynamic params (params that change as the game runs) —
  resolver is load-time only

## Alternatives considered

### A) Lift macros into cross-game scope (extend ADR 0019)

Macros already do parameterization (`$param` substitution + cycle
detection + expansion limits). We could add a load path for
`data/lib/macros/<name>.json` that any game can reference.

Pros: zero new resolver primitive — reuses macros.
Cons: macros define EFFECT NAMES (rules-side). Camera configs,
screen specs, entity defs aren't effects — macros are
shape-mismatched.

We'd need to broaden ADR 0019's scope from "effect templates"
to "any JSON template," which is a major contract change to that
ADR. Cleaner to add `$params` to ADR 0027's resolver as a parallel
mechanism.

### B) String-only Formula language at JSON load time

Use the existing Formula primitive (W4.5) to evaluate any string
that looks like an expression. This would generalize: not just
params, but arbitrary computed values.

Pros: maximal expressiveness.
Cons: Formula is FIRE-TIME (rule context bindings — `self`,
`target`, `world.X`). Lib refs are LOAD-TIME. Different scope
machinery. Conflating the two opens runtime resolution of lib
refs, which is a much bigger ADR (caching, performance, error
timing). Leave Formula at fire-time; load-time stays static.

### C) Don't add params; just author more presets

If `fps_60`, `fps_90`, `fps_120` are the only fov use cases, just
add three presets and let games pick.

Pros: zero engine work, zero new ADR.
Cons: doesn't scale — every dimension (fov, eye_height,
mouse_sensitivity) explodes the preset count combinatorially.
Real games will need 4-6 dimensions of camera variation. 6 dims
× 3 values each = 729 presets. Untenable.

We picked the present design (B + selective formula-style
substitution at load time, not full Formula) because it covers
the real authoring pain (combinatorial preset explosion) without
opening the runtime-resolution can of worms.

## References

- ADR 0019 (rule-plugin macro layer) — per-game, effect-shape
  templates with `$param` substitution. This ADR extends the
  parameterization idea to ANY lib entry shape, cross-game.
- ADR 0027 (cross-game JSON reuse system) — the reference + merge
  layer this ADR builds on.
- `archetypes/core/templates/godot/scripts/engine/lib_resolver.gd`
  — the resolver that gains `$params` substitution.
- `archetypes/core/templates/godot/scripts/engine/macro_expander.gd`
  — existing per-game `$param` substitution; pattern to mirror.

## Tech-director review

_Date: 2026-05-08_
_Reviewer: yume-tech-director_

### Invariant checks

| Invariant | Status | Notes |
|---|---|---|
| #1 JSON-only content channel | ✓ | substitution is interpreter on JSON; produces JSON; no GDScript game logic introduced |
| #2 No semantic effect types | ✓ | doesn't add effect types |
| #3 No entity-class hierarchy | ✓ | none |
| #5 Queries first-class | ✓ | none |
| #8 Engine = primitives + interpreter | ✓ | substitution is interpreter scope, not new VERB. Resolver now hosts 3 operators (`$extends`, `$include`, `$params`) — surface growing but each is a coherent JSON-template op. See concern #1 below for the cap. |
| #9 Phase ordering | ✓ | load-time only |
| #10 Freeze-policy | ✓ | no new pending pipelines |
| #11 Level-discontinuity | ✓ | no transition_level changes |
| #12 Persistent-clobber | ✓ | no spawn changes |

Greps clean. The proposal is contract-compliant.

### Specific concerns

**1. Three-operator surface — declare the cap.** ADR 0027 added
`$extends` and `$include`. ADR 0028 adds `$params`. That's a coherent
JSON-template vocabulary: merge / splice / parameterize. But future
ADRs will be tempted to add `$select`, `$transform`, `$loop`, etc.

**Decision needed in this ADR**: explicitly declare these three are
the COMPLETE set. Future composition operators require strong
justification (a real combinatorial-explosion problem like `$params`
solves) and another ADR. Loops + conditionals belong in macros + rule
shape, not the load-time resolver.

Add a § "Operator surface boundary" stating: "$extends + $include +
$params are the ONLY load-time JSON-composition operators. Runtime
logic uses rules + Formula + macros."

**2. Pipe-syntax defaults are TOO MUCH new syntax.** `$params.k | 90`
introduces parsing complexity (escaping the literal `|`, JSON-typed
defaults vs string defaults, default values that are themselves
strings containing `|`...). This grows the placeholder grammar.

**Cleaner alternative**: declare defaults at the LIB ENTRY level,
not inline:

```jsonc
// data/lib/cameras/fps.json
{
  "_param_defaults": {"fov": 90, "eye_height": 1.7, "sensitivity": 0.003},
  "mode": "first_person_3d",
  "fov_degrees": "$params.fov",
  "eye_height": "$params.eye_height",
  "mouse_sensitivity": "$params.sensitivity"
}
```

Pros: separates concerns (lib author declares defaults, reference
site supplies overrides). Placeholder grammar stays minimal —
`"$params.<key>"` and string-interpolation only. Defaults can be
arbitrary JSON values without escaping.

**Require this revision** before merge. Pipe-syntax → out;
`_param_defaults` block → in.

**3. ADR 0019 boundary needs concrete syntax mapping.** The
Alternatives section says "macros are effect-shape, this is generic-
shape," which is accurate. But the SUBSTITUTION SYNTAX differs:

- ADR 0019: `$<param_name>` (no prefix; flat namespace)
- ADR 0028: `$params.<key>` (dict-keyed prefix)

This is fine and acceptable distinction (different scope, different
syntax = different mental model — good). But ADR 0028 should call
this out explicitly so authors don't conflate them.

**Add to Alternatives**: a paragraph listing which syntax to use
when. Macros for new effect verbs in your game; lib `$params` for
generic dict templates shared across games.

**4. Missing-param semantics — both layers must fire.** Good ADR
already says: structured `EngineError.LIB_PARAM_MISSING` + validator
catches at sync time. Spell out: validator is the AUTHORATIVE gate
(catches at sync, fails fast); resolver is the RUNTIME SAFETY NET
(catches if validator was bypassed via `SKIP_VALIDATE=1` or
direct-godot launch).

Add to § "Validation": both layers fire; validator is canonical.

**5. `_origin` for nested chains — recommend chain form.** Currently
ADR 0027's resolver stamps `_origin` ONCE at the outermost expansion.
If a 3-level $extends chain triggers, the leaf dict says `_origin:
"@lib.entities.merchant_shopkeeper"` but the user can't see that
merchant_shopkeeper itself extends shopkeeper which extends npc_base.

For ADR 0028, with params now propagating through chains, debug
breadcrumbs become more important. Recommend: change `_origin`
(string) to `_origin_chain` (array of refs from leaf to root).
Stamp on FIRST resolution; append on inner resolutions.

```jsonc
// resolved instance:
{
  "id": "garron",
  "_origin_chain": [
    "@lib.entities.merchant_shopkeeper",
    "@lib.entities.shopkeeper",
    "@lib.entities.npc_base"
  ],
  "_params": {"fov": 90}
}
```

This is a minor revision to ADR 0027 + carries through 0028.
Existing tests would need updating — small cost.

**Optional**, but strongly recommended. If declined, document why
in this ADR.

**6. Land now vs wait — implement Phase 1, defer Phase 2.** Phase 1
is the resolver extension + tests + validator. Cheap (~2-3 hours),
contract-clean, doesn't touch any consumer game.

Phase 2 (catalog conversion — replacing `fps_default` with `fps`-
parameterized) WAITS until first multi-consumer use case. Specifically:

- Merchant currently uses `@lib.cameras.iso_top_down` (no params).
- Future shooter using `@lib.cameras.fps_default` will eventually
  want different fov than merchant's FP toggle. THAT's when Phase 2
  fires — convert `fps_default` to `fps` parameterized, both games
  switch.

Documenting this defer in the ADR avoids speculative data churn.

**7. Test coverage list is good but missing one case.**

Add Test 10: `lib_params.test_string_interpolation_with_special_chars`.
Verify the interpolation handles strings with embedded `$`, `{`, `:`.
For example: `"id": "merchant_$params.kind"` with kind = "$weird"
should produce `"id": "merchant_$weird"` (literal substitution, not
re-evaluated).

### Verdict

**accept-with-conditions**.

Conditions before Phase 1 implementation:

1. **Add operator-surface cap** to Decision: $extends + $include +
   $params are the complete set; future composition needs new ADR.
2. **Replace pipe-syntax defaults with `_param_defaults` block** at
   lib-entry level. Cleaner grammar; arbitrary JSON defaults without
   escaping.
3. **Sharpen ADR 0019 boundary** in Alternatives — call out the
   syntax differences explicitly.
4. **Spell out validator + resolver dual layer** for missing-param
   detection.
5. **Recommend `_origin_chain` array form** (touches ADR 0027 too —
   minor backport).
6. **Defer Phase 2 catalog conversion** until first multi-consumer
   use case. Document this in Implementation plan.
7. **Add Test 10**: string interpolation with special chars.

This ADR is well-shaped overall. The 3-operator vocabulary is
coherent and matches the 3 OOP composition primitives users
intuitively reach for (inherit / mixin / parameterize). The
combinatorial-explosion alternative ("just author more presets")
is a real failure mode worth preventing.

Implementation risk is low (all load-time, no runtime impact, no
new VERBS, no scheduler changes). Test coverage is comprehensive
once concern #7 is added. Defer Phase 2 keeps speculative data
churn off the table.

After conditions land in ADR text → upgrade to **accepted** →
implement Phase 1 → seed catalog conversion to a future session
when first multi-consumer use case fires.
