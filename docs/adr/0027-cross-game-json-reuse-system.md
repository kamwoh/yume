# ADR 0027 — Cross-game JSON reuse system (`@lib.X` references + `$extends` merge)

_Date: 2026-05-08_
_Status: **accepted (conditions addressed 2026-05-08)**_

## Context

Yume games are pure JSON. The framework already provides three
shared libraries at `data/`-level:

- `data/meshes.json` — 3D mesh primitives
- `data/shapes.json` — 2D shape primitives
- `data/sounds.json` — procedural SFX library

Every game references entries in these libraries by name (e.g.
`visual.mesh: "merchant_shop_3d"`). The pattern works because
the engine has hand-coded resolvers (`MeshLib.get_mesh()`,
`AudioBus.play(name)`) that perform the lookup at use time.

But many other authoring artifacts are **NOT** reusable:

| Artifact | Status today | Cost to author per game |
|---|---|---|
| Camera presets (iso / FP / top-down) | Hand-author in scene.json | 8-15 lines |
| Input bundles (WASD + sprint + attack) | Hand-author 8+ rules in physics.json + actions in ui/input.json | ~80 lines |
| First-person camera + WASD-relative bundle | Hand-author 8 split rules + camera config + state init | ~120 lines |
| Title / pause / settings screens | Hand-author per game | ~60-200 lines |
| Common entity defs (townie, house, prop_lamp) | Redefined per game | ~30-80 lines each |
| Common rule snippets (modal-pop-with-fade, wave-spawn) | Re-author per chain | ~20-60 lines each |

LLM authoring (Claude / Gemini / Codex via the `/yume-design`
pipeline) re-derives all of these for every new game. The pipeline
is slow and error-prone (we just shipped 3+ regressions in the
WASD-with-FP-variant work alone). A reuse layer would let the
author write `"$ref": "@lib.input_bundles.wasd_with_fp_variant"`
and inherit a tested bundle.

The user framed it directly:

> "what i imagine is that, we are building something like 'json
> language system' like although we use only json, but we can
> build the whole game, and because these can be done by you/
> claude/codex/gemini, so we make sure this is friendly to you"

This ADR specifies the foundational reuse mechanism so all
subsequent authoring work (including the merchant city redesign
in task #5, FP camera setup we just shipped, future minimap
widget) can build on it.

## Decision

Introduce a **JSON include / preset system** with two operators:

### 1. `@lib.<category>.<name>` — value-replacement reference

Anywhere a value appears in a JSON file, a string starting with
`@lib.` is resolved at world-load time to the matching library
entry's value.

```jsonc
// In demo_merchant/scene.json
"camera": "@lib.cameras.iso_top_down"
// Engine expands at load:
"camera": {"mode": "isometric_3d", "distance": 24, "ortho_size": 24, "lerp": 0.18}
```

### 2. `{"$extends": "@lib.X.Y", ...overrides}` — merge with overrides

When the per-game spec needs to override one or two fields of a
preset, use `$extends`. The engine merges the preset under the
spec dict, with spec values winning.

```jsonc
// In demo_merchant/scene.json
"camera": {
  "$extends": "@lib.cameras.iso_top_down",
  "follow_tag": "player",
  "ortho_size": 30
}
// Engine expands at load:
"camera": {
  "mode": "isometric_3d",
  "distance": 24,
  "ortho_size": 30,            // override won
  "lerp": 0.18,
  "follow_tag": "player"        // added
}
```

Merge is **shallow** (top-level keys only) — predictable for
authors. Deep merge is opt-in via repeated `$extends` (an
overriding value can itself be a `$extends` dict).

### 3. `{"$include": ["@lib.X.Y", "@lib.X.Z"]}` — array splice

For files where the top-level is an array (e.g. `world/physics.json
::rules` is an array), include lib entries to splice multiple
items in. The engine flattens the include into the parent array.

```jsonc
// In demo_merchant/world/physics.json
{
  "rules": [
    {"$include": "@lib.input_bundles.wasd_with_fp_variant.rules"},
    {"id": "merchant_specific_rule", ...}
  ]
}
// Engine expands at load:
{
  "rules": [
    {"id": "player_move_north", ...},
    {"id": "player_move_south", ...},
    {"id": "player_move_east", ...},
    {"id": "player_move_west", ...},
    {"id": "player_move_forward_fp", ...},
    {"id": "player_move_back_fp", ...},
    {"id": "player_strafe_right_fp", ...},
    {"id": "player_strafe_left_fp", ...},
    {"id": "merchant_specific_rule", ...}
  ]
}
```

### Library tree

```
data/
├── meshes.json              ← existing
├── shapes.json              ← existing
├── sounds.json              ← existing
├── lib/
│   ├── manifest.json        ← discoverability index (REQUIRED — see schema below)
│   ├── cameras.json         ← presets: iso_top_down, fps_default, top_down_3d, ...
│   ├── input_bundles/
│   │   ├── wasd_world.json              ← WASD bound to world-frame velocity_set
│   │   ├── wasd_with_fp_variant.json    ← 8 rules: world-frame + FP camera-relative
│   │   └── arena_shooter.json           ← WASD + mouse-look + attack/reload
│   ├── entities/
│   │   ├── npcs/
│   │   │   ├── townie.json
│   │   │   ├── shopkeeper.json
│   │   │   └── guard.json
│   │   ├── props/
│   │   │   ├── house_small.json
│   │   │   ├── lamppost.json
│   │   │   └── fountain.json
│   │   └── ui/
│   │       └── world_clock.json         ← persistent singleton template
│   ├── screens/
│   │   ├── title_default.json           ← title with New/Continue/Settings/Quit
│   │   ├── pause_default.json
│   │   └── settings_default.json
│   └── rules/
│       ├── modal_pop_with_fade.json     ← screen_fade alpha=1, transition_screen, ...
│       ├── tutorial_overlay_step.json
│       └── wave_spawn_tick.json
└── <game>/  ← existing per-game data
    └── ...
```

### Manifest — discoverability index (load-bearing)

`data/lib/manifest.json` is the SINGLE entry point LLM authors
(and humans) read to discover what's in the lib. Without this,
agents cannot author lib references reliably. Every category gets
a `_shape` declaration + per-entry one-line description.

```jsonc
{
  "_comment": "Authoritative index of lib entries. ALL @lib.X.Y refs must resolve through here. Updated whenever a lib file is added/renamed.",

  "categories": {
    "cameras": {
      "_shape": "camera_config",
      "_path": "data/lib/cameras.json",
      "entries": {
        "iso_top_down":       "Isometric 3D follow with 24m ortho extent, 0.18 lerp.",
        "top_down_3d":        "Camera directly above target, ortho 16m extent.",
        "third_person_default": "Behind-shoulder follow with mouse-look yaw, perspective.",
        "fps_default":        "First-person eye-height, mouse pitch+yaw, perspective."
      }
    },
    "input_bundles": {
      "_shape": "input_bundle",
      "_path": "data/lib/input_bundles/*.json",
      "entries": {
        "wasd_world":            "4 rules: WASD → world-frame velocity_set (3 m/s).",
        "wasd_with_fp_variant":  "8 rules: 4 world-frame + 4 camera-relative (gates on world_clock.camera_mode).",
        "arena_shooter":         "WASD + mouse-look + attack/reload bindings."
      }
    },
    "entities": {
      "_shape": "entity_def",
      "_path": "data/lib/entities/<subcat>/*.json",
      "entries": { /* per subcategory: npcs, props, ui */ }
    },
    "screens": {
      "_shape": "screen_spec",
      "_path": "data/lib/screens/*.json",
      "entries": {
        "title_default":     "Title with New/Continue/Settings/Quit buttons.",
        "pause_default":     "Resume/Settings/Quit overlay with translucent background.",
        "settings_default":  "Audio + display settings with sliders + back button."
      }
    },
    "rules": {
      "_shape": "rule_array",
      "_path": "data/lib/rules/*.json",
      "entries": {
        "modal_pop_with_fade":   "screen_fade alpha=1 → transition_screen @previous → screen_fade alpha=0 (paired-fade pattern).",
        "tutorial_overlay_step": "show_overlay → wait → emit advance signal → dismiss_overlay.",
        "wave_spawn_tick":       "tick rule that spawns N enemies on a tag-anchored ring."
      }
    }
  },

  "shape_defs": {
    "camera_config":  "dict with mode + follow_tag + mode-specific fields (distance/ortho_size/eye_height/etc.)",
    "input_bundle":   "dict {actions: [<inputs.json action>...], rules: [<rule>...]}",
    "entity_def":     "dict {id, tags, properties, state_init, visual} matching entities.json schema",
    "screen_spec":    "dict {id, modal, freeze_world, background_color, elements} matching screens.json schema",
    "rule_array":     "array of rule dicts; spliced via $include into a parent rules array"
  }
}
```

**Authoring discipline**: when a content-designer skill adds a new
lib entry, it MUST also add a manifest row + `_shape` declaration.
The validator (Phase 1) checks every `@lib.X.Y` reference resolves
through the manifest's `entries` table.

### Resolution semantics

1. **Resolution timing**: at world-load (and each level-load).
   Lib files are loaded once at startup, cached. Per-game files
   are walked tree-style; `@lib.X` strings are replaced inline,
   `$extends` and `$include` dicts are expanded inline.

2. **Recursion**: a lib entry may reference another lib entry.
   Resolution is recursive with **depth limit 8** + **cycle
   detection** (mirrors `macro_expander.gd`'s discipline).

3. **Identity stability**: rule `id` fields inside an included
   bundle stay the same. If two games include the same bundle,
   each gets its own copy of the rules (not shared at runtime).

4. **Override clarity**: when `$extends` merges, only top-level
   keys merge. Author must duplicate the full inner dict if they
   want to override a sub-field. This is intentional — predictable
   beats clever.

5. **Validation**: a static validator (extend
   `tools/validate_screens.py` pattern) walks every game's data,
   verifies `@lib.X` references resolve through the manifest's
   `entries` table. Wired into `play.sh`.

6. **Id-collision in `$include`**: when an `$include` splices a
   lib's rule array into a game's `rules` array, the engine
   compares included rule `id` fields against existing game rule
   ids. **A collision is an ERROR** (structured `EngineError` with
   both source paths). Author resolves by either renaming the
   game-side rule OR forking the lib bundle. No silent override.

7. **Cache policy — startup-only**: `lib_resolver.gd` loads every
   `data/lib/**.json` file once at engine boot, caches in memory.
   Live-editing a lib file while the game is running does NOT
   reflect — a restart is required. Documented in
   `yume-asset-designer` SKILL so authors know iteration cycle.
   Rationale: per-frame file reads would be unnecessary I/O;
   restart is fast (<2s) for a non-shipped dev workflow.

8. **`_origin` metadata on every expanded dict**: when the resolver
   replaces a `@lib.X.Y` ref or expands a `$extends` block, it
   stamps the resulting dict with `_origin: "@lib.X.Y"`. Engine
   error messages cite this so post-mortems trace bugs back to
   the source bundle. The engine ignores `_origin` at runtime
   (treated like `_comment`). Visible in any state dump or log.

9. **Effect-chain validation runs on EXPANDED rule list**, not the
   pre-expansion authored list. Per `engine-scripts.md` §
   effect-chain validation gate, destructive effects must be LAST
   in their chain. Lib bundles must obey this rule INTERNALLY —
   a `$include`'d rule whose effect chain has `transition_level`
   followed by a `state_set` is a lib-level error caught by the
   gate even though no game-side author wrote it. Lib authors
   carry the discipline.

### Migration path

This ADR doesn't break existing games. The resolver runs as a
preprocessor — JSON without `@lib.X` / `$extends` / `$include`
passes through unchanged. Existing games continue to work.

Migration is **opt-in**: a game author can adopt lib references
when they choose. Initial migration:

- merchant: convert FP camera + WASD bundle to `@lib.input_bundles
  .wasd_with_fp_variant`.
- All future games shipped via `/yume-design` use lib refs by
  default.

## Consequences

### What this enables

- LLM authoring becomes **bundle composition** instead of
  re-derivation. New game = pick camera preset + input bundle +
  screen templates + per-game entity defs. ~80% of boilerplate
  vanishes.
- Bug fixes propagate. Fix a bug in `@lib.input_bundles.wasd_with
  _fp_variant` → every game using it picks up the fix at next
  data sync.
- Skill discipline: `yume-asset-designer` declares "use camera
  preset X" instead of authoring the full block. Auditable.
- Shared regression coverage: scenario tests for lib bundles
  (e.g. "FP movement rotates with mouse-look") cover EVERY
  consuming game.

### What this precludes

- Per-instance lib-entry mutation. A game can `$extends` a preset,
  but cannot mutate the lib entry itself. (Lib is read-only at
  runtime; mutation = author a sibling preset.)
- Deep-merge ambiguity. Authors who expect "merge sub-dicts
  recursively" must use repeated `$extends`. Documented; not
  hidden.

### What changes elsewhere

- `world.gd::_read_entities_json` (and similar JSON loaders) call
  the resolver before parsing. New module: `lib_resolver.gd`.
- `tools/validate_lib_refs.py` (new) — sync-time check.
- `yume-asset-designer`, `yume-content-designer`, `yume-screen-flow
  -designer`, `yume-systems-designer` SKILLs gain a "prefer lib
  reference" instruction.
- `docs/30_framework_primitives.md` adds a § "JSON reuse layer"
  documenting `@lib.X` / `$extends` / `$include` semantics.

### Risks

- **Discovery**: agents need to know what's in the lib. Mitigation:
  add `data/lib/manifest.json` listing all entries with one-line
  descriptions. SKILLs reference this.
- **Versioning**: changing a lib entry breaks consuming games.
  Mitigation: version sub-keys (`@lib.cameras.iso_top_down_v2`)
  and document deprecation.
- **Performance**: load-time resolution adds overhead.
  Mitigation: cache lib files at startup; resolution is O(N) over
  game JSON tree, runs once per level load.
- **Debug ambiguity**: errors in expanded JSON reference lib
  entries. Mitigation: resolver records `_origin: "@lib.X.Y"` on
  expanded dicts so error messages cite the source.

## Alternatives considered

### A) Macros (existing system, ADR 0019 / `macro_expander.gd`)

Macros and lib-references solve **different problems with different
shapes**. Both are content-side composition mechanisms; they
coexist without overlap:

| Aspect | ADR 0019 macros | ADR 0027 lib refs |
|---|---|---|
| What it adds | NEW EFFECT NAMES (`deal_damage`, `harvest_crop`) that expand to existing primitives | Pure REFERENCES to existing JSON blobs (camera config, rule bundle) |
| Scope | Per-game (each game's own `macros.json`) | Cross-game (`data/lib/` shared) |
| Parameterization | Yes — `$param` substitution at load | No — clones the dict verbatim, override via `$extends` |
| Adds vocabulary | Yes (per game) | No (pure splice) |
| Use case | Author wants `deal_damage(target=b, amount=10)` instead of 4 effects | Author wants the same FP camera setup as merchant + future shooters |

A game can use BOTH. The ADRs are orthogonal:
- `macros.json` defines per-game effect verbs
- `@lib.X` references shared building blocks across games
- Lib bundles can themselves invoke macros (the macro is per-game,
  resolved after lib expansion)

Pros of NOT using macros for cross-game reuse:
- Macros are PER-GAME by ADR 0019's design — extending to cross-game
  would change that ADR's contract and reopen its tech-director
  review.
- Macros parameterize; lib doesn't need to (most reuse is config-
  shape, not function-shape).
- Different syntax (`{macro: name, params: {}}` vs `@lib.X` /
  `$extends`) communicates different intent.

### B) GDScript-side imports

Build per-category loaders (CamerasLib, InputLib, ScreensLib) like
the existing MeshLib pattern.

Pros: no new resolver primitive, follows existing pattern.
Cons: each new category needs hand-coded engine support. Doesn't
generalize. We'd write 6 loaders instead of 1 resolver.

### C) JSON Schema $ref

Use the standard JSON-Schema `$ref` convention.

Pros: familiar to web devs.
Cons: $ref is a URL-form pointer, more general than we need;
implementations vary; doesn't match Yume's `@cues.X` / lib lookup
convention. New syntax for authors to learn.

We picked the present design because:
- `@lib.X` mirrors `@cues.X` and `@audio.X` already in the
  codebase (continuity of convention).
- `$extends` / `$include` are intuitive merge/splice ops.
- Single resolver handles all categories — generic primitive,
  not category-specific code.

## Implementation plan

Phase 1 (engine foundation) — **scope of this ADR**:
- New: `archetypes/core/templates/godot/scripts/engine/lib_resolver.gd`
- Hook: world.gd JSON loaders call resolver pre-parse
- Validator: `tools/validate_lib_refs.py` + wire into play.sh
- Tests: 9 unit tests in `tests/test_runner.gd`:

| Test | Verifies |
|---|---|
| `lib_resolver.test_string_ref` | `"camera": "@lib.cameras.fps_default"` resolves to the matching dict |
| `lib_resolver.test_extends_shallow_merge` | `$extends` overlays top-level keys; spec values override preset values |
| `lib_resolver.test_include_array_splice` | `$include` flattens lib's rule-array into parent array at the splice site |
| `lib_resolver.test_recursion_depth` | lib A → lib B → lib C resolves at depth 3, all leaves expanded |
| `lib_resolver.test_cycle_detection` | lib A references lib B, B references A → load fails with structured error citing chain |
| `lib_resolver.test_depth_limit` | 9-deep chain fails at depth 8 with structured error |
| `lib_resolver.test_id_collision_detected` | game rule id `X` + `$include`d rule id `X` → load fails with both source paths |
| `lib_resolver.test_origin_metadata` | resolved dict contains `_origin: "@lib.X.Y"` |
| `lib_resolver.test_pass_through_unchanged` | JSON without any `@lib.X` / `$extends` / `$include` round-trips byte-identical |

Phase 2 (initial library content):
- `data/lib/cameras.json` — iso_top_down, top_down_3d,
  third_person_default, fps_default
- `data/lib/input_bundles/wasd_world.json`,
  `wasd_with_fp_variant.json`
- `data/lib/manifest.json` (the discoverability index)

Phase 3 (migrate merchant):
- Convert merchant's scene.json camera → `$extends @lib.cameras.iso
  _top_down`
- Convert physics.json WASD rules → `$include @lib.input_bundles
  .wasd_with_fp_variant`
- Verify 12/12 scenarios still pass

Phase 4 (skill discipline):
- yume-asset-designer / yume-systems-designer / yume-screen-flow-
  designer SKILLs: "Phase X — check lib for reusable preset
  before authoring custom"

Phase 5 (broader migration — separate ADRs/sessions):
- Town building / NPC / prop libs
- Screen templates lib
- Used by /yume-design pipeline going forward

## References

- `docs/30_framework_primitives.md` — invariants this fits under
- `docs/adr/0019-rule-plugin-macro-layer.md` — existing macro
  system (per-game, doesn't solve cross-game reuse)
- `docs/adr/0021-yume-as-json-layer-over-platform.md` — Yume's
  expose-don't-reimplement principle (this ADR exposes JSON-level
  composition primitives)
- `archetypes/core/templates/godot/scripts/engine/macro_expander
  .gd` — depth limit + cycle detection patterns to mirror
- `archetypes/core/templates/godot/scripts/engine/mesh_lib.gd` —
  existing per-category loader pattern (this ADR generalizes)

## Tech-director review

_Date: 2026-05-08_
_Reviewer: yume-tech-director_

### Invariant checks

| Invariant | Status | Notes |
|---|---|---|
| #1 JSON-only content channel | ✓ | resolver is engine code; lib entries are JSON; expanded output is JSON consumed by existing handlers |
| #2 No semantic effect types | ✓ | resolver doesn't introduce effect types — bundles only package existing primitives |
| #3 No entity-class hierarchy | ✓ | none |
| #5 Queries first-class | ✓ | none changed |
| #8 Engine = primitives + interpreter | ✓ | resolver is INTERPRETER scope (JSON pre-parse transform), not new VERB scope. Mirrors existing `mesh_lib.gd` / `audio_bus.gd` per-category loaders, generalized into one resolver |
| #9 Phase ordering | ✓ | load-time only; doesn't touch tick/scheduler |
| #10 Freeze-policy audit | ✓ | no new pending pipelines |
| #11 Level-discontinuity | ✓ | no transition_level changes |
| #12 Persistent-clobber | ✓ | no entity-spawn changes (lib resolves PRE-spawn into game JSON; same spawn loop runs) |

The design fits Yume's principles cleanly. `@lib.X` continues the
existing `@strings.X` / `@cues.X` namespace pattern (see
`screen_flow.gd::_resolve_at_ref`), generalizing per-category
loaders (`mesh_lib.gd`, `audio_bus.gd`) into one composable
resolver. Migration is opt-in. Cycle detection + depth limit
mirror `macro_expander.gd` discipline.

### Specific concerns

**1. Discoverability for LLM authors — manifest must be load-bearing,
not a "Risk."** The ADR mentions `data/lib/manifest.json` once under
"Risks." For LLM authoring this is the entry point — agents need
to know what's in the lib before they can reference it. Move to
**Decision** § "Library tree" with a defined schema:

```jsonc
// data/lib/manifest.json
{
  "categories": {
    "cameras": {
      "iso_top_down": "Isometric 3D follow with 24m ortho.",
      "fps_default": "First-person with mouse-look + WASD-relative."
    },
    "input_bundles": {
      "wasd_with_fp_variant": "8 rules: 4 world-frame (non-FP modes) + 4 camera-relative (FP mode)."
    }
  }
}
```

Update the yume-design skills (asset-designer, systems-designer)
to load `data/lib/manifest.json` and prefer lib references.

**2. Relationship to ADR 0019 (macros) — explicit boundary needed.**
The ADR mentions macros under "Alternatives" and dismisses with
"per-game only." But the boundary needs to be sharper:

- **ADR 0019 macros**: per-game JSON declares NEW EFFECT NAMES that
  expand to existing primitives. `deal_damage` is content vocabulary
  the game adds.
- **ADR 0027 lib**: cross-game JSON references an existing JSON
  blob (camera config, rule bundle) by name. No new vocabulary;
  pure composition.

These solve **different problems** with **different shapes**.
Macros parameterize effects; lib clones config. Both can coexist
without merging. State this in § "Alternatives considered" so
future readers don't try to consolidate.

**3. `$include` array splice — id-collision semantics.** Critical
gap. If a game's `physics.json::rules` has rule id `player_move_north`
AND `$include @lib.input_bundles.wasd_with_fp_variant.rules` brings
its own `player_move_north`, what happens? The current `world.gd`
doesn't dedupe rule ids. Need to declare:

- **Reject**: lib included rule ids must NOT collide with game
  rule ids. Validator catches at load. Error: structured EngineError
  with both source paths.
- This forces the author to either rename a game-side rule OR fork
  the lib bundle. Predictable.

Add to Decision § "Resolution semantics" as point 6.

**4. Test plan — be explicit per test case.** ADR mentions "unit
tests" but doesn't enumerate. For my review to track regression
coverage, I need:

| Test | What it verifies |
|---|---|
| `lib_resolver.test_string_ref` | `"camera": "@lib.cameras.fps_default"` expands to dict |
| `lib_resolver.test_extends_shallow_merge` | `$extends` overlays top-level keys, doesn't deep-merge |
| `lib_resolver.test_include_array_splice` | `$include` flattens lib array into parent array |
| `lib_resolver.test_recursion_depth` | lib A → lib B → lib C resolves at depth 3 |
| `lib_resolver.test_cycle_detection` | lib A → lib B → lib A errors with chain identified |
| `lib_resolver.test_depth_limit` | 9-deep chain errors at depth 8 |
| `lib_resolver.test_id_collision_detected` | `$include`'d rule id matching game rule id errors |
| `lib_resolver.test_origin_metadata` | resolved dict carries `_origin: "@lib.X.Y"` for debug |
| `lib_resolver.test_pass_through_unchanged` | JSON without `@lib.X` / `$extends` / `$include` round-trips identically |

Add this table to Phase 1.

**5. Cache invalidation policy — explicit.** ADR says "lib files
are loaded once at startup, cached." For dev iteration:
- Live-edit `data/lib/cameras.json` while game runs → does NOT
  reflect (cache stale until restart).
- This is acceptable but must be DOCUMENTED in the ADR + in
  yume-asset-designer skill ("editing lib requires restart").

Add to Decision § "Resolution semantics" as point 7.

**6. Lib entry shape is per-category — schema discipline.** Each
category has its own shape:

- `cameras.X` → camera config dict (mode, distance, lerp, ...)
- `input_bundles.X` → `{actions: [...], rules: [...]}` dict
- `entities.<cat>.X` → entity def dict (id, tags, properties,
  state_init, visual)
- `screens.X` → screen spec dict (id, modal, elements, ...)
- `rules.X` → effect-list array

The validator (`tools/validate_lib_refs.py`) must know the expected
shape per category so it can fail loudly when a game references
a lib entry of the wrong shape into the wrong field. Add a
per-category schema to manifest.json:

```jsonc
{
  "categories": {
    "cameras": {"_shape": "camera_config", "entries": {...}},
    "input_bundles": {"_shape": "input_bundle", "entries": {...}}
  }
}
```

Define `_shape` enum in this ADR (5-6 named shapes).

**7. Effect-chain integrity — does $include preserve destructive
ordering?** When `$include @lib.rules.wave_spawn` splices rules
into a chain, do those rules' effect ordering still respect
"destructive effects last"? Per ADR 0010/0011 effect-chain
gate, this is invariant-bearing. Need a NOTE in the ADR:

> Effect-chain validation runs on the EXPANDED rule list, not the
> pre-expansion authored list. Lib bundles must obey the
> destructive-last rule internally.

Add to § "Resolution semantics".

**8. `_origin` metadata — debug breadcrumb.** ADR mentions in Risks.
Promote to Decision: "Resolver records `_origin: '@lib.X.Y'` on
every expanded dict so error messages cite source." This makes
post-mortems tractable when a rule fired from a lib bundle
misbehaves — author sees `[origin: @lib.input_bundles.wasd_with_fp_
variant]` in stderr.

### Minor

- Phase 1 + Phase 2 can land in same PR; Phase 3 (merchant migration)
  in separate PR so the resolver lands without coupling to merchant
  regression risk.
- `data/lib/manifest.json` is itself a tracked-in-git file; commit
  it with the resolver.

### Verdict

**accept-with-conditions**.

Conditions before merge (incorporate into ADR before implementation):

1. Move `manifest.json` from Risks to Decision § "Library tree"
   with defined schema (concern #1).
2. Sharpen ADR 0019 boundary in Alternatives (concern #2).
3. Add point 6 to Resolution semantics: id-collision = error
   (concern #3).
4. Add explicit test list table to Phase 1 (concern #4).
5. Add point 7 to Resolution semantics: cache is startup-only,
   restart to reload (concern #5).
6. Add `_shape` enum + per-category schema to manifest.json
   (concern #6).
7. Add note: effect-chain validation runs on expanded list
   (concern #7).
8. Promote `_origin` metadata from Risks to Decision (concern #8).

This ADR has **the lowest contract risk of any structural ADR
since 0019** — generic, doesn't add primitives, mirrors existing
patterns. Implementation risk is moderate (touches every JSON
loader path) but the test plan + opt-in migration limit blast
radius. The reuse payoff for LLM authoring is large enough to
prioritize this before any further game-content work.

After conditions land in the ADR text → upgrade to **accepted**
→ implement Phase 1 + Phase 2 → run regression suite →
implement Phase 3 (merchant migration).

## Revisions per tech-director review (2026-05-08)

Each condition mapped to where it was addressed in the ADR text
above. Status: **all 8 conditions addressed → ADR upgraded to
accepted**.

| # | Condition | Where addressed |
|---|---|---|
| 1 | Manifest moves to Decision § Library tree with schema | New § "Manifest — discoverability index" under Decision |
| 2 | Sharpen ADR 0019 boundary in Alternatives | § "Alternatives considered" / A) — added comparison table + coexistence rules |
| 3 | `$include` id-collision = error | § "Resolution semantics" point 6 |
| 4 | Explicit test table | § "Implementation plan" Phase 1 — 9-row table with test name + verifies |
| 5 | Cache startup-only policy | § "Resolution semantics" point 7 |
| 6 | Per-category `_shape` enum + schema | § "Manifest" — `shape_defs` block enumerates 5 shapes |
| 7 | Effect-chain validates on EXPANDED list | § "Resolution semantics" point 9 |
| 8 | `_origin` metadata promoted to Decision | § "Resolution semantics" point 8 |

Status: **accepted**. Lands per build order — Phase 1+2 in single
PR, Phase 3 (merchant migration) in separate PR for blast-radius
isolation.

