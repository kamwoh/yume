---
description: Path-scoped rules for Yume demo data folders
globs: godot/data/**
---

# Demo data — schema discipline

## ⚠ CRITICAL: backups belong in `<game>/_snapshots/`, NEVER in engine-globbed dirs

`world_loader.gd` loads entity defs by GLOBBING `<root>/entities/*.json`
(plus `<root>/entities.json`) and MERGING every definition into one
dict. Same trap applies to `world/rules/*.json`. If a def id (or rule
id) appears in two globbed files, the alphabetically-LAST file SILENTLY
WINS — no error, just the wrong mesh/color/behavior.

So a backup snapshot saved next to the live file inside a globbed dir
gets loaded and clobbers the live def. The "always rename, never
delete" principle is right — but the renamed copy must live OUTSIDE
the globbed path. Put it in `<game>/_snapshots/` (the engine never
scans it).

❌ **WRONG**: `entities/auto_gen.preBuckets.json` — globbed, shadows
the live `auto_gen.json`.
✅ **RIGHT**: `_snapshots/auto_gen.preBuckets.json` — preserved, not
loaded.

Note `scene.json` and level `entities.json` are read by EXACT NAME,
so `scene.preHilly.json` / `entities.preRoads.json` siblings aren't
loaded — but keep them in `_snapshots/` too for consistency + to keep
the loaded dir clean.

**Empirical case 2026-05-27**: a manual `entities/auto_gen.preBuckets.json`
backup re-declared `fountain`/`townhall`/`wall_segment`/`bridge` with
the OLD `prim_unit_*` meshes + raw semantic-classification hex
(#e040a0). Sorted after `auto_gen.json`, it won the merge → the
fountain rendered as a bare magenta sphere instead of fountain_kit.
Fix: relocated all snapshots to `_snapshots/`.

**Gate**: `tools/validators/validate_duplicate_defs.py` (wired into the
validator bank) flags any def id declared in 2+ files within a globbed
entities set. Catches this bug class at sync time.

Demos live as JSON folders under `data/`. They are **content**, not code —
no GDScript files belong here.

## ⚠ CRITICAL: top-level `position` clobbers `state.position` in initial_instances

**Resolution order in `entity._apply_overrides` (entity.gd:90):**

1. `state` block — sets fields including `state.position` if listed
2. `properties` block
3. `tags` block
4. `visual` block
5. `position` top-level — **OVERWRITES `state.position` unconditionally**

So writing this:

```json
{
  "def": "free_camera",
  "id": "camera_oblique",
  "position": [0, 0, 0],
  "state": {"position": [0, 28, 32], "yaw": 0.0, "pitch": -0.66}
}
```

...does NOT set state.position to [0, 28, 32]. It sets state.position
to [0, 0, 0] (the top-level value, applied LAST). state.yaw and
state.pitch stick fine; only position gets clobbered.

This is a silent footgun. The author thinks "I'm overriding state
with my state block." The engine resolves "top-level position wins."

### Convention (aldenmere's pattern)

For entities where `state.position` IS the spawn position (logical
entities, free_cameras, anything where the renderer reads state.
position for positioning), set BOTH fields to the SAME value:

```json
{
  "def": "free_camera",
  "id": "camera_oblique",
  "position": [0, 28, 32],
  "state": {"position": [0, 28, 32], "yaw": 0.0, "pitch": -0.66}
}
```

Or omit top-level position if state.position covers it:

```json
{
  "def": "free_camera",
  "id": "camera_oblique",
  "state": {"position": [0, 28, 32], "yaw": 0.0, "pitch": -0.66}
}
```

(But the engine will then fall back to state.position = Vector2.ZERO
during entity creation, then your state override sets [0,28,32]. This
also works.)

### Gates

1. **Engine-side warning** (entity.gd:124+): emits
   `[entity.position_clobber]` push_warning when the two values
   disagree at spawn time. Defense in depth.
2. **Static validator**: `tools/validators/validate_position_consistency.py`
   scans every initial_instances entry, flags conflicts. Wired into
   the validator bank — runs from play.sh / sync.
3. **This doc section**: the convention authors should follow.

### Empirical case (2026-05-26)

`compose_world.py` (auto-gen text-to-world pipeline) emitted
free_camera initial_instances with `position: [0, 0, 0]` (thinking
"the entity has no physical position") AND `state.position: [0, 28,
32]` (the actual camera pose). Result: every free_camera spawned at
world origin. Camera_director's _camera_free_cam read state.position
= [0, 0, 0], moved Camera3D to origin, rendered solid dark brown
(inside-of-building view from inside the densely-packed town).

Symptoms tried before finding root cause (~2 hours of debugging):
- Toggle rules not firing → fixed with rule update (still failed)
- `_neq` operator unsupported → fixed with `_in` (still failed)
- Input routing failed → added player_input_anchor entity (still failed)
- Lighting too minimal → copied aldenmere's rich lighting (STILL failed)
- Compared to aldenmere's working initial_instances → found the
  position-field convention difference.

The user's question "this is just same as aldenmere right?" turned
out to be the right framing every time. The bug was always "I'm not
following aldenmere's exact convention." Lesson: when auto-gen
produces something that should work like a known-good demo,
DIFF the JSON structures field-by-field BEFORE iterating on
engine code or other theories.

## ⚠ INVARIANT: no per-def escape hatches from automated derivation

Anything the engine can derive from the world model, the engine
**must** derive — every time, with no per-def opt-outs. Colliders
come from mesh bbox × state.scale. Mesh offsets come from
visual.y_offset / y_offset_mesh × scale. Material UUIDs come from
the .glb's authored materials. Director mounting comes from the
content's needs. Authors don't override these by hand.

**Why this is non-negotiable**: every escape hatch (a JSON field
that says "ignore the auto-derivation for THIS def") creates a
class of silent drift. Author sets one of the override fields,
forgets to set the others, and the wireframe / collider / sync
drifts away from the mesh — visible only with --debug-colliders
or after a player reports a weird hitbox. Then someone has to
manually fix that one def. Then a similar def hits the same bug.
Then a similar game. The escape hatch becomes a chronic source
of "fix individually" labor that should never exist.

**The principle Yume aims for**: explicit world model, fully
automated. State is JSON. Geometry is derived. Behavior is
declared. Nothing is hand-tuned. Anywhere we author a manual
override on a derivable value, we're admitting the derivation
isn't good enough — fix the derivation, don't add an exception.

**Empirical case 2026-05-24**: `_aabb_intent: "design"` was an
escape hatch in `validate_aabb_extents.py` that let authors opt
defs out of mesh-bbox-derived colliders. 7 aldenmere defs (5
trees + workbench + grave_marker) abused it: set aabb_extents
manually but forgot aabb_offset, so colliders sat half-buried
under the floor. User had to manually flag each one. Fix:
deleted the `_aabb_intent` field entirely from the validator
+ engine + data. Now collider derivation is 100% automatic from
the .glb mesh — no override path exists. Authors who want
different gameplay (e.g., walk between trees) author the MESH
differently, not the collider.

**Gate**: when proposing a new "I'll author this manually because
the auto-behavior isn't right" override, REJECT the override.
Either:
  (a) fix the auto-derivation so the right thing happens for all
      cases of this class, OR
  (b) fix the source data (re-author the mesh, change the bbox,
      etc.) so the existing auto-derivation produces the right
      thing.

Never (c) ship the escape hatch.

This rule applies to every primitive the framework already
derives: aabb (collider sizing), y_offset (mesh-to-ground sync),
material UUIDs, scale propagation, director mounting, position
scaling. New derivations land with NO opt-out. Old opt-outs
get deleted as the post-mortem ritual surfaces their failures.

## ⚠ CRITICAL: NEVER drop a `.gd` file under `godot/data/`

`data/` is content-only. Engine code lives at `godot/scripts/engine/`.
A stray .gd under data/ — especially one declaring `class_name X` where
X collides with an engine class — SHADOWS the engine version via
Godot's global class registry. The dispatch silently routes to whichever
copy registered first; the user-visible symptom is "feature stopped
working" with no error.

**Empirical case 2026-05-15**: a stale `data/demo_aldenmere/effect_apply.gd`
(May 10 leftover, never deleted because `cp -r src/. dst/` doesn't
remove orphans) declared `class_name EffectApply` and won the registry
race over the real engine file. The stale copy's `match type:` predated
`velocity_add_relative` dispatch. Result: Aldenmere's WASD input fired
correctly through query + flush, then `EffectApply.apply` hit the
stale match-arm with no `velocity_add_relative` case → silent no-op.
Player never moved; NPC `velocity_set` motion kept working (stale copy
had that arm). User reported it as "drift / pulls sideways."

**Gate**: `tools/validators/validate_no_stray_scripts.py` (wired into `play.sh`)
scans both `godot/data/` and the sync target's `data/` for any `*.gd`
file and fails the pre-launch check. After deleting a stray .gd, rebuild
Godot's class cache: `godot --path <template> --headless --import`
(otherwise the cache still maps `class_name X` to the deleted path and
load-time class lookup explodes everywhere).

## ⚠ CRITICAL: formula context bindings depend on the trigger type

Formulas (`"value": "X.state.Y"`, `"index": "X.state.Y"`) get their
context bindings from how the rule fires. Using the wrong binding name
crashes at runtime with `self can't be used because instance is null
(not passed)` — the Godot Expression engine has no way to soft-fail.

| Trigger | Context bindings available in formulas |
|---|---|
| `tick` (with `query.tags_all` or flat query) | `self`, `self_entity` |
| `tick` (with `query: {a: {...}, b: {...}}`) | named sub-bindings (`a`, `b`, ...) |
| `contact` | `a`, `b` (pair-matched entities) |
| `signal` (with `require: {actor: ..., target: ...}`) | the require-named bindings (`actor`, `target`, ...) — **no `self`** |
| `signal` (with `query`) | `self` from the query match |
| `input` (with `query.tags_all`) | `self` from the matched actor |
| `spawn` / `despawn` | `self` (the spawning/despawning entity) |

❌ **WRONG** — signal rule with `require` bindings, formula uses `self`:
```jsonc
{
  "id": "gather_pickup",
  "trigger": {"type": "signal", "name": "gather_request"},
  "require": {
    "actor": {"tags_all": ["player"]},
    "target": {"tags_all": ["forageable"]}
  },
  "effect": [
    {"type": "array_set_at",
     "target": "actor",
     "field": "inventory_cooked",
     "index": "self.state._last_slot",   // ← CRASH: self not bound
     "value": "target.state.cooked"}
  ]
}
```

Runtime error: `formula.exec_failed: 'self.state._last_slot'` →
`self can't be used because instance is null`.

✅ **RIGHT** — use the binding name from `require`:
```jsonc
"index": "actor.state._last_slot"
```

**Empirical case 2026-05-16**: TDTE multi-slot inventory shipped with
`gather_pickup` referencing `self.state._last_slot` for its parallel
array_set_at index. Unit tests passed (because the test bound `self`
directly). Scenario tests passed (don't exercise gather — needs
crosshair aim). User hit it on the first live pickup.

**Second incident, same session**: switched to `actor.state._last_slot`
to match the require-binding name. Still crashed. Root cause: even when
the trigger/require has a binding called `actor`, the formula evaluator
only sees it as an Entity object if `EffectResolution.formula_context`'s
entity-id auto-promotion includes it. The original `entity_roles`
allowlist (`self, target, a, b, source, from, to, piece, from_sq,
to_sq`) didn't include `actor`. Fix: removed the allowlist as a
correctness gate — any ctx value that's a string AND a known entity id
is now auto-promoted to its Entity. Custom payload binding names like
`actor`, `pursuer`, `prey`, etc. now drill into `.state.X` without
needing engine code changes. The allowlist remains as an ORDERING hint
(those names are resolved first to guarantee shadowing precedence) but
unknown names fall through to auto-promotion.

**Gate** — when authoring a rule, identify the trigger type and the
shape of `query` vs `require`, then audit every formula in `effect`
to confirm the binding it references is in the active context:

```bash
# Find effects in signal rules using `self.X` formulas that may be
# unbound (require-driven binding instead):
grep -B 8 '"self\.' godot/data/demo_*/world/rules.json | grep -A 8 '"signal"'
```

If you can't immediately confirm the binding from re-reading the rule,
the safest move is to test the rule live (capture-input scripted
playtest, not just unit + scenario). Unit tests that synthesize their
own context easily mask binding-resolution bugs.

## ⚠ CRITICAL: sync-derived fields used as filters must be pre-initialized

When a tick rule derives a state field (e.g. `array_sync_to_field` writing
`held_item` from `inventory[active_slot]`, or any `state_set` whose
target field other rules later filter on), authors MUST also initialize
that field in the source entity's `state_init`. Otherwise the field is
MISSING at tick 1, and Yume's strict-missing query semantics will fail
the filter — the first input-driven rule that gates on it silently
refuses.

❌ **WRONG** — derived `held_item` referenced by a tick-1 input rule but
never initialized:
```jsonc
// player.json
"state_init": {
  "inventory": ["", "", "", ""],
  "active_slot": 0
  // held_item is derived by inventory_derive_view tick rule, but its
  // initial absence means filter `held_item_eq: ""` fails at tick 1 input.
}

// world/rules.json
{
  "id": "eat_input_empty",
  "trigger": {"type": "input", "action": "eat"},
  "query": {"tags_all": ["player"], "state": {"held_item_eq": ""}}
  // → first E press at tick 1 never fires. User reports "eat does
  //   nothing on the first try."
}
```

✅ **RIGHT** — pre-init derived fields in state_init too:
```jsonc
"state_init": {
  "inventory": ["", "", "", ""],
  "active_slot": 0,
  "held_item": "",                  // pre-init derived (mirrors inventory[0])
  "held_cooked": 0,
  "held_wet": 0,
  "inventory_empty_count": 4        // pre-init derived (count of '' slots)
}
```

**Why this matters**: phase ordering. Tick scheduler runs input → flush
→ signal-drain → decide-tick → flush. Sync tick rules fire in
decide-tick — AFTER the input phase. So tick 1 input rules read the
state from BEFORE any sync ever ran. Missing field = strict filter
fails (per QueryLib strict-missing convention).

**Empirical case 2026-05-16**: Three Days to Eat multi-slot inventory
(#95). `gather_pickup`'s `require: {actor: {state: {inventory_empty_count_gt: 0}}}`
silently refused the first E press because `inventory_empty_count`
was only ever written by the tick rule `inventory_derive_view`, never
in `state_init`. Caught during pre-commit verification by tracing the
phase ordering manually, not by user playtest.

**Gate**: when authoring a tick rule that writes a state field via
`array_sync_to_field`, `array_count_matching`, or any `state_set` whose
target field OTHER rules use as a filter, also add that field to the
entity's `state_init` with a matching sentinel default. yume-game-rules-
designer + yume-content-designer should check this jointly during the
"final pass before declaring done" step. A future static validator
(`tools/validators/validate_derived_fields.py`) can grep for sync-rule outputs
and verify each appears in the corresponding entity def's state_init.

## ⚠ CRITICAL: never ship a rule with `effect: []`

The engine's `_load_rules_file` reports `[rule.effect_empty]` as a
hard error when a rule's effect list is empty. Empty-effect rules
are a code-smell pattern — typically the result of removing the
last effect during cleanup ("audio not shipped → remove play_music")
without removing the now-no-op rule itself.

❌ **WRONG**:
```jsonc
{"id": "bgm_proto_village",
 "trigger": {"type": "tick", "interval": 60},
 "query": {"tags_all": ["world_clock"]},
 "effect": []}      // CRASH at load: rule.effect_empty
```

✅ **RIGHT** — delete the entire rule if it's no-op. If a rule MUST
exist as a placeholder (e.g. for future audio wiring), use a
trivial state-touch:
```jsonc
"effect": {"type": "state_set", "target": "world_clock",
           "field": "_bgm_tick_count", "value": "world_clock.state._bgm_tick_count + 1"}
```

**Empirical case 2026-05-10**: Aldenmere `bgm_proto_village` shipped
with `effect: []` after `play_music` was stripped (no audio assets
yet). World load reported `rule.effect_empty` error. Fix: deleted
the placeholder rule until audio-designer ships BGM.

**Gate**: yume-content-designer + yume-game-rules-designer skills
must NEVER ship a rule with `"effect": []`. If the cleanup pass
removes the last effect, also remove the rule. Add to those skills'
"final pass before declaring done" checklists.

## ⚠ CRITICAL: engine-injected input actions need `engine_injected: true`

Some input actions are not bound to keys — the engine queues them
directly from internal state. Examples: `stop_x` / `stop_y` queued
by `world.gd::_poll_input` on per-axis idle (when neither E nor W
is held → queue stop_x).

❌ **WRONG** — InputRegistrar warns + skips (action never reaches
InputMap; scenario_runner can't fire it):
```jsonc
{"name": "stop_x", "edge": "press"}        // no key, no marker → warning
```

✅ **RIGHT** — explicit opt-in marker tells InputRegistrar to
register a keyless action silently:
```jsonc
{"name": "stop_x", "edge": "press", "engine_injected": true}
```

The marker preserves typo detection for ordinary actions (`{"name":
"jjjump"}` still warns) while supporting the legitimate
engine-injected case.

**Empirical case 2026-05-10**: Aldenmere shipped stop_x / stop_y /
stop without the marker; three warnings per world load. Fix:
added `engine_injected: true` to all three; updated InputRegistrar
to handle the field.

## ⚠ CRITICAL: schema field-name landmines (memorize, then verify)

These are exact field names the engine reads. Wrong name = silent failure
(rule registers but never fires; no error). Empirically caught all of these
during the merchant game build (2026-05-06) — each had ~30-50 occurrences
across the data files before being fixed.

| Effect | Engine reads | Common wrong name | Where verified |
|---|---|---|---|
| `state_add` | `amount` | ❌ `delta` | `effect_apply.gd:120` `e.get("amount")` |
| `state_mul` | `amount` | ❌ `factor` / `delta` | `effect_apply.gd:126` |
| `spawn` | `template` | ❌ `def` | `effect_apply.gd:148` `e.get("template")` |
| `state_clamp` | `min` / `max` | (correct) | `effect_apply.gd:133-134` |

**Verify before writing**: `grep -A 4 '"type": "<effect>"' godot/data/demo_doomarena3d/world/rules.json` — if a working demo uses different names, follow the demo, not your intuition.

## ⚠ CRITICAL: `self.nearest({...})` is NOT IMPLEMENTED — use contact-pair

`formula.gd`'s top docstring declares `self.nearest({...})` as **deferred
to Tier 3** — the formula evaluator does NOT actually resolve it.
Writing it in any formula context (effect `value`, `destination_x`,
`payload.X`, etc.) makes evaluate() see `self.nearest(...)` as a
bare path lookup, returns null, and the downstream `.state.position`
or `.id` access crashes with `"self can't be used because instance
is null"`.

❌ **WRONG**:
```jsonc
{"type": "pathfind_to",
 "destination_x": "self.nearest({tags_all: [villager]}).state.position[0]",
 "destination_z": "self.nearest({tags_all: [villager]}).state.position[2]"}
```

✅ **RIGHT** — use a CONTACT-pair query with `a` (the pursuer) +
`b` (the target). The engine pre-binds both, formulas reference `b.X`
directly:
```jsonc
{"trigger": {"type": "contact"},
 "query": {
   "a": {"tags_all": ["wolf"]},
   "b": {"tags_all": ["villager"], "tags_none": ["in_shelter"]},
   "radius": 40,
   "once_per_a": true
 },
 "effect": {
   "type": "pathfind_to",
   "target": "a",
   "destination_x": "b.state.position[0]",
   "destination_z": "b.state.position[2]"
 }}
```

Drawback: contact-pair fires per-tick (no `interval` field), and the
binding picks "any matching b within radius" rather than `order_by`-
sorted (e.g. lowest health). For most pursuer AI nearest-in-cone is
acceptable; if priority sorting is essential, gate on additional
state filters in `b`'s query (e.g. `state: {health_lt: 30}` → only
chases wounded).

**Empirical case 2026-05-11**: Aldenmere `wolf_pursue_villager` used
the broken `self.nearest(...).state.position[0]` formula. Loaded
fine (no parse error), then crashed at runtime the first tick a
wolf existed — `formula.exec_failed` → "self can't be used because
instance is null". Stack trace from world.gd::_on_tick. Fixed by
collapsing to contact-pair + `once_per_a`.

**The gate**: yume-systems-designer skill must NEVER author
`self.nearest({...})` in any formula context. The three "find me a
related entity" patterns the engine supports today:

1. **Contact-pair** (`trigger: contact`, `query: {a, b, radius}`) —
   the most common.
2. **Single-binding tick** + a separate signal/contact rule that
   sets `state.X_target_id` for later rules to bind via.
3. **Spatial query inside a single-binding query** (`tags_all` +
   `radius`) — but only ONE entity is bound (`self`), not "find
   related to self."

Until Tier-3 spatial helpers land, those three cover every real use.
A new ADR is required before adding `nearest()` to the formula
evaluator (it would need spatial-index integration + scoring/order
semantics).

## ⚠ CRITICAL: 2-binding `{a, b, radius}` queries are CONTACT-only

Pair-matching (find pairs of entities (a, b) within radius) is ONLY
supported on `trigger: {type: "contact"}`. The engine's
`_fire_contact_rule` walks pairs; `_fire_scan_rule` (used by tick /
input / signal triggers) does NOT.

If you write a tick / signal / input rule with a 2-binding query:

```jsonc
// ❌ WRONG — engine treats this as single-entity scan; b never binds
{
  "trigger": {"type": "tick", "interval": 5},
  "query": {
    "a": {"tags_all": ["mud_hut", "under_construction"]},
    "b": {"tags_all": ["fire_pit", "burning"]},
    "radius": 10.0
  },
  "effect": [
    {"type": "tag_add", "target": "a", "tags": ["built"]},
    {"type": "emit", "payload": {"id": "a.id"}}  // CRASH: a not bound
  ]
}
```

The engine fires this as a single-entity scan: matches the FIRST sub-
binding (`a`'s tags) and binds `self` to each match. **`a` and `b`
are never bound** — `target: "a"` resolves to literal id "a" (no
entity), and formulas `a.id` / `b.id` evaluate against null Entity →
"self can't be used because instance is null" runtime error.

✅ **Three correct patterns**:

1. **Use `contact` trigger** if pair-matching is the intent (rare for
   "complete construction"-style rules; common for combat / pickup):
   ```jsonc
   {"trigger": {"type": "contact"},  // engine pair-matches per tick
    "query": {"a": {...}, "b": {...}, "radius": 5.0}, ...}
   ```

2. **Single-binding tick** + use `self.nearest({...})` formula to
   resolve the partner inline:
   ```jsonc
   {"trigger": {"type": "tick", "interval": 5},
    "query": {"tags_all": ["mud_hut", "under_construction"]},
    "effect": [
      {"type": "tag_add", "target": "self", "tags": ["built"]},
      {"type": "state_set", "target": "world",
       "field": "nearby_fire_id",
       "value": "self.nearest({tags_all: [fire_pit]}).id"}
    ]}
   ```

3. **Drop the partner condition** if it's a soft proximity hint and
   exact pair semantics aren't required (acceptable when the radius
   was vibes, not a hard constraint).

**Empirical case 2026-05-10**: Aldenmere Phase 1 shipped with 15
tick rules using broken `{a, b, radius}` queries — `wolf_despawn_dawn`,
`mudhut_construction_complete`, `warmth_decay_*`, etc. All crashed at
tick 1 with formula-exec errors. yume-systems-designer skill
generated them; the gate below didn't exist. Bulk-fixed by
collapsing each rule to single-binding `self` query.

**The gate**: `yume-systems-designer` skill must NEVER write a 2-
binding query under a non-contact trigger. Both:
- The skill's role spec calls this out under "Common rule shapes"
- A static validator check in `tools/validators/validate_rules.py` (future)
  can grep for `(tick|signal|input).*"a":\s*{.*"b":\s*{` shape and
  fail at sync time

## ⚠ CRITICAL: query vs require — they are NOT interchangeable

Wrong assumption (the merchant build cost ~40 broken rules to this):

❌ **WRONG** — `require` is NOT a state-search filter:
```jsonc
{
  "trigger": {"type": "tick", "interval": 10},
  "require": {"clock": {"tags_all": ["world_clock"], "state": {"phase_eq": "shop"}}}
  // expectation: rule fires when world_clock entity has phase=shop
  // reality: require validates that ctx["clock"] (a binding from elsewhere)
  // matches; ctx["clock"] is NEVER set, so require always fails, rule never fires
}
```

✅ **RIGHT** — to gate on a singleton's state, put it in `query`:
```jsonc
{
  "trigger": {"type": "tick", "interval": 10},
  "query": {"tags_all": ["world_clock"], "state": {"phase_eq": "shop"}}
  // engine searches for entities matching this filter; rule fires per match
}
```

**`require` semantics**: validates that bindings ALREADY set in context match
the filter. Used when query has named sub-bindings (chess `piece`, `from_sq`,
`to_sq`) and require enforces extra constraints on those existing bindings.
The engine code is `phase_scheduler.gd::_require_ok` — it reads
`ctx.get(binding_name, null)`; if null → require FAILS regardless of
your filter.

**`query` with named sub-bindings**: `query: {clock: {...}, a: {...}}` sets
multiple context bindings via search. Rule fires per (clock × a) combination.
For pure tick rules wanting state-gating, use FLAT pattern:
`query: {tags_all: ["world_clock"], state: {field_op: value}}`.

## ⚠ CRITICAL: state_set / show_toast values are HUMAN TEXT vs FORMULAS

`_value()` routes string values through `Formula.looks_like_formula()`
→ `Formula.evaluate()` if it looks formula-shaped. As of 2026-05-08
the heuristic requires a formula-START char (lowercase / digit /
`(` / `-` / `+` / `_` / `@`), so capital-letter-starting English
text bypasses parsing safely.

When authoring `state_set value: "..."` or `show_toast text: "..."`:

**Safe — passes through as literal text**:
- `"Find your shop in Pendrel."`     (starts capital)
- `"Day 6 — bailiff returns soon."`  (starts capital)
- `"→ Open the shop"`                (starts arrow / non-letter)
- `"Eugene joins your party."`       (starts capital)

**Treated as formula — must evaluate cleanly or it crashes**:
- `"world.gold"`                     (starts lowercase, has `.`)
- `"signal.sale_price"`              (lowercase + `.`)
- `"a.state.hp + 10"`                (lowercase + math)
- `"(a.state.hp - 5) * 2"`           (paren start, math)

If you want literal text that LOOKS formula-like, prefix with a
capital letter or `→` to opt out:

- `"→ world.gold"`         ← treated as text
- `"World.gold"`           ← treated as text (capital W)

Empirical: 2026-05-08 the `current_objective` field set to
`"Find your shop in Pendrel. Walk to the shop door (south-west of
the fountain)."` crashed `Expression.parse` because the old
`looks_like_formula` only checked for any-of `[space + - * / ( ) .]`
without a start-character filter. Fixed in formula.gd; this gate
documents the convention so future authors don't have to discover it.

## ⚠ CRITICAL: bindings in payload values are BARE, not `{...}`

❌ **WRONG**: `"new_tier": "{world.reputation_tier}"` — engine sends the
literal string through the formula evaluator, fails to parse `{world.X}` as
a Godot Expression.

✅ **RIGHT**: `"new_tier": "world.reputation_tier"` (bare binding) OR
`"new_tier": {"binds": "world.reputation_tier"}` if your effect supports
binding objects. Check the specific effect's spec.

The merchant build had ~57 of these brace-wrapped bindings causing 31,000+
formula.parse_failed errors per session.

## ⚠ CRITICAL: `velocity_add_relative` requires deceleration mechanism

Camera-relative WASD rules use `velocity_add_relative` (lib bundle's
FP + iso variants). The effect ADDS to existing velocity each tick;
speed-clamp normalizes magnitude to `state.max_speed`. When the actor's
`state.facing` changes between ticks (e.g., player mouse-turning
mid-walk), the previous tick's velocity points in the OLD facing
direction; this tick adds in the NEW facing direction; sum-then-clamp
lands BETWEEN old and new facing. Velocity LAGS the camera — player
feels "something pulling" them back from where they're looking.

❌ **WRONG** — `velocity_add_relative` actor with no decay:
```jsonc
"state_init": {
  "facing": 0,
  "max_speed": 3,
  // missing: BOTH drag AND zero_velocity_pretick → facing-lag bug
}
```

✅ **RIGHT** — pick ONE (or both) deceleration mechanism:
```jsonc
"state_init": {
  "facing": 0,
  "max_speed": 3,
  "zero_velocity_pretick": true  // engine zeros vel each tick →
                                  // tight FPS feel, instant direction match
}
// OR
"state_init": {
  "facing": 0,
  "max_speed": 3,
  "drag": 5.0  // motion integrator decays vel each frame →
                // momentum-glide feel, converges over a few ticks
}
```

**The rule**: any actor whose movement comes from `velocity_add_relative`
rules MUST declare ONE of:
- `state.zero_velocity_pretick: true` (engine zeros at start of each tick)
- `state.drag > 0` (motion integrator decays each frame)

Without either, velocity accumulates in stale-facing direction and produces
the "pulling" feel when the mouse turns.

**Camera mode → required check:**

| Camera mode | Movement rules | Deceleration check |
|---|---|---|
| `top_down_3d`, `third_person_3d` | world-frame `velocity_set` per-axis | n/a (last-writer-wins handles direction) |
| `isometric_3d` | iso variant `velocity_add_relative` (facing=π/4) | **MANDATORY**: zero_velocity_pretick=true OR drag>0 |
| `first_person_3d` | FP variant `velocity_add_relative` (state.facing) | **MANDATORY**: zero_velocity_pretick=true OR drag>0 |

**Empirical case 2026-05-10**: Aldenmere FP rollout shipped with player
`drag: 0` + no `zero_velocity_pretick`. User reported "movement laggy as
if something pulling it" on mouse-turn-mid-walk. Fix: re-enabled
`zero_velocity_pretick: true`.

**Gate**: skills authoring `entities/<actor>.json` (yume-content-designer)
AND skills writing world/rules.json with WASD lib bundle splice
(yume-systems-designer) MUST verify the actor's state_init satisfies
this rule. The yume-asset-designer skill's camera-mode-pick must
FLAG the requirement to the content-designer downstream.

## ⚠ CRITICAL: logical/singleton entities need `visual: {hidden: true}`

Entities without a `visual.mesh` / `visual.model_3d` / `visual.shape`
block fall through to entity_mesh_3d.gd's tier-3 fallback: **a bare
colored box at entity.state.position**. The renderer doesn't know
"this is a logical entity with no representation" vs "the author
forgot to set a visual" — it picks the safe default (visible box).

For logical-only entities (clocks, score trackers, camera anchors,
zone markers, event spawners, world state holders), the def MUST
declare `visual: {hidden: true}` so spawn_manager.gd's renderer-
attach skips the entity entirely.

❌ **WRONG** — logical entity with no visual block:
```jsonc
{
  "id": "world_clock",
  "tags": ["world_clock", "persistent"],
  "properties": {},
  "state_init": {"current_day": 1, ...}
  // No visual → renderer spawns a colored box at position [0,0,0].
  // Player sees a mystery cube floating at origin.
}
```

✅ **RIGHT** — explicit hidden flag:
```jsonc
{
  "id": "world_clock",
  "tags": ["world_clock", "persistent"],
  "properties": {},
  "state_init": {"current_day": 1, ...},
  "visual": {"hidden": true}
}
```

**Empirical cases**:
- 2026-05-03 towerdef3d: singleton tracker entity showed as pink
  square. spawn_manager.gd line 187 was added to honor
  `visual.hidden=true` after this.
- 2026-05-21 aldenmere `free_camera` def: cameras were spawned as
  bare cubes at the 3 authored positions. Player saw the cube when
  entering free_cam and the cinematic camera flew near it. User
  asked "why do i see a cube spawn when i switch to freecam?"
  Cube was always there; just first visible when the user-controlled
  camera moved into a frame containing one.

**The gate**: when authoring an entity def under
`data/<game>/entities/`, decide upfront: does this entity have a
visual representation?

| Entity purpose | visual block required |
|---|---|
| Player, NPC, animal, prop | `visual.mesh` / `visual.model_3d` / `visual.shape` REQUIRED |
| Code-drawn primitive (cube, sphere, custom mesh) | `visual.mesh` referencing meshes.json |
| AI-gen mesh (.glb from tripo3d) | `visual.model_3d` + path |
| Library shape (tree, rock, hut) | `visual.shape` referencing shapes.json |
| Singleton / logical state holder | `visual: {hidden: true}` REQUIRED |
| Zone marker / trigger volume | `visual: {hidden: true}` REQUIRED |
| Camera anchor (`free_camera` etc.) | `visual: {hidden: true}` REQUIRED |
| Spawner / event source | `visual: {hidden: true}` REQUIRED |

A future static validator (`tools/validators/validate_visual_presence.py`)
can grep entity defs and fail any def where `visual` is missing OR
empty AND no `visual.hidden: true` opt-out exists. Treats forgotten
visual as a hard error rather than a silent colored-box.

## ⚠ CRITICAL: mode-transition rules must reset state mutated by the OLD mode

When a rule transitions an entity from mode A to mode B by writing
`state_set` on a field that **gates downstream rules' queries** (e.g.
`camera_mode`, `input_active`, `game_phase`), the transition rule
MUST also reset any state field that:

1. Was being written by input/tick rules under mode A's filter, AND
2. Won't be reached by mode B's rules (because the filter excludes B), AND
3. Doesn't have an automatic decay path (drag=0, no zero_velocity_pretick,
   no `stop` action firing while the input is still held).

The canonical case: `velocity` written by `velocity_add_relative` WASD
rules. ADR 0048's per-tick auto-reset only triggers on the FIRST add
per tick — it doesn't fire if the rule's filter excludes the new mode.
Drag=0 (FPS-snappy feel) doesn't decay it. The `stop` action only
queues when no keys are held; if the player is still holding W during
the mode transition, `stop` never fires and velocity persists.

❌ **WRONG** — freecam_enter only sets camera_mode:
```jsonc
{
  "id": "freecam_enter_from_fp",
  "trigger": {"type": "input", "action": "toggle_freecam"},
  "query": {"tags_all": ["world_clock"], "state": {"camera_mode_eq": "first_person_3d"}},
  "effect": [
    {"type": "state_set", "target": "self", "field": "camera_mode", "value": "free_cam"}
    // Missing: actor velocity reset. Player drifts while W held until release.
  ]
}
```

✅ **RIGHT** — also zero velocity on the player (input-triggered rules
bind `actor` to the input source):
```jsonc
"effect": [
  {"type": "state_set", "target": "self", "field": "camera_mode", "value": "free_cam"},
  {"type": "velocity_set", "target": "actor", "x": 0, "y": 0}
]
```

**Empirical case 2026-05-21**: aldenmere `freecam_enter_from_fp` /
`freecam_enter_from_tp` shipped without the velocity reset. User held
W (player moving north in first-person), pressed C to enter free_cam.
Camera + player both moved north until W release because the WASD rule
filter (`camera_mode_in: [first_person_3d, third_person_3d]`) no longer
matched, the velocity_add_relative auto-reset never fired, and drag=0
held the previous velocity. User feedback: "now 'w' control both cam &
player until i release."

**The gate**: when authoring ANY rule that flips a state field gating
downstream input/tick rules, audit what state those downstream rules
WRITE. Each written field needs a reset effect in the transition rule
unless one of these is true:
- The field has automatic decay (drag>0, or zero_velocity_pretick=true)
- A queryable `stop_*` rule fires unconditionally on mode B (no camera_mode filter)
- The new mode's rules will overwrite the field on their first tick

Common state fields that need reset on input-driven mode transitions:
`velocity`, `facing`, `aim_target`, `charge_progress`, `pending_action`.

This applies to: camera_mode transitions (free_cam, pause), level_phase
transitions, character_class transitions (rare), any state-machine
flag that gates an input rule's query.

A future static validator (`tools/validators/validate_mode_transitions.py`)
can grep for rules that `state_set` a field that appears in any other
rule's `query.state.<field>_eq|_in|_neq` filter, then verify the
transition rule's effects include resets for the gated rules' targets.

## ⚠ CRITICAL: state.velocity dimensionality — Vector2 NOT Vector3 for floor-walkers

The WASD lib bundle (`@lib.input_bundles.wasd_with_fp_variant.rules`)
uses `velocity_set` with field name `y` to mean **"the second component
of velocity"**. The renderer (entity_mesh_3d.gd:127) lifts a Vector2
velocity into world Vector3 via:

```gdscript
position = Vector3(p.x, 0, p.y) * position_scale
```

So when velocity is Vector2 `(x, y)`, `y` becomes world-Z (north/south
on the floor). When velocity is Vector3 `(x, y, z)`, `y` is the
world-UP axis — pressing W literally launches the player upward.

❌ **WRONG** for floor-walking actors (player, NPCs):
```jsonc
"velocity": [0, 0, 0]    // Vector3 — y is world-up, W makes player jump
```

✅ **RIGHT** for floor-walking actors:
```jsonc
"velocity": [0, 0]       // Vector2 — y is renderer-Z = north, W walks
```

✅ **Vector3 IS appropriate** for entities that legitimately move
in 3D space (projectiles with arc trajectories, flying mobs, vertical
elevators). Those entities' rules use `velocity_set z:` for horizontal
+ `y:` for vertical separately.

**Empirical case 2026-05-10**: Aldenmere player + 8 villagers + 3
animals shipped with Vector3 `[0,0,0]` velocity (11 entities total).
Pressing W made the player float upward instead of walking north.
User feedback: "why my 'w' is not on the floor, but is up and down?"

**ADR 0045 follow-up (2026-05-13)**: actors with `physics.body_type:
"character"` ALSO use Vector2 for floor-walkers — the runner script
mirrors state.velocity to its `CharacterBody3D.velocity` via
`sync_body_velocity`, which lifts Vector2(x, y) → Vector3(x, 0, y)
exactly like the renderer. Same convention; same rule.

**The check**: any entity tagged `actor`, `villager`, `ambient_walker`,
`prey`, `wolf` (or any other ground-mover) MUST have 2-component
velocity. Verify with grep before declaring content done:

```bash
# Find all 3-component zero-velocity inits on ground-walker entities:
grep -B 6 '"velocity": \[\s*0,\s*0,\s*0\s*\]' entities/*.json
```

Each match needs to be either (a) collapsed to `[0, 0]` if the entity
walks on the floor, or (b) explicitly justified as a 3D-mover (with
a `_comment` so future readers know it's intentional).

## ⚠ CRITICAL: world-state singleton pattern (no env.world_state queries)

The engine does NOT support querying `env.world_state` directly:
- ❌ `query: {world_state: {phase_eq: "shop"}}` — engine doesn't recognize
  `world_state` as a query target
- ✅ Create a singleton entity tagged `world_clock` (or `level_clock`,
  `game_state`) with all your global state fields in `state_init`. Rules
  query it via `tags_all: ["world_clock"]`; effects mutate via
  `target: "<world_clock_entity_id>"`.

**HUD bindings work BOTH ways** but for different stores:
- `world.X` → reads `env.world_state` dict (set by `state_set target=world`)
- `<entity_tag>.X` → finds first entity with that tag, reads its state

**Don't duplicate**: pick ONE source-of-truth. Either use env.world_state
(`target=world`, HUD binds `world.X`) OR singleton entity
(`target=<entity_id>`, HUD binds `<tag>.X`). Mixing both means mutations on
one don't affect reads from the other.

Working demos:
- chess: `game_state` singleton entity, queries via `tags_all: ["game_state"]`
- sokoban: `level_clock` singleton, same pattern
- harvestcore: hybrid (some env.world_state, some singletons) — the messier path

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
- ⚠️ **`blocks_motion` is engine-recognized** (ADR 0004). Entities with
  this tag must also declare `properties.aabb_extents: [hx, hy, hz]`
  (half-extents on each axis). Motion integrator slides moving entities
  around their AABB on the XZ plane. Example: `tags: ["wall",
  "blocks_motion"], properties: {"aabb_extents": [22, 1.5, 0.25]}`.
  Don't reuse the name for other meanings.
- ✅ **Use `state_init` for both static initial values AND dynamic state
  to be mutated.** The engine doesn't enforce a static/dynamic split;
  it's a content convention.
- ✅ **Comment heavily.** JSON has no real comments, but `_comment` keys
  are ignored by the engine. Use them for design intent.
- ✅ **Whitelist formula syntax.** Formulas are `Expression` strings.
  Allowed: bindings (`self.state.X`, `target.X`, `world.tick`), math
  helpers (`clamp`, `min`, `max`, `abs`, `sin`, `cos`, `sqrt`, `pow`,
  `floor`, `ceil`, `lerp`, `randf`), arithmetic, comparison, bitwise
  (`<<`, `&`, `|`), Vector2/Array subscript (`v[0]`, `a[1]`).
  No function calls outside the math helpers — defer to W4.5 AST
  whitelist when it lands.
- ⚠️ **Ternary `a if cond else b` is BROKEN.** Godot 4.6.1's
  `Expression` parses it without error but **always returns the IF
  branch**, ignoring the condition. C-style `cond ? a : b` doesn't
  parse at all. Empirically verified during doomarena3d v2 QA
  (2026-05-03) — `5.0 if false else 0.0` returns 5.0; `5.0 if true
  else 0.0` also returns 5.0. **Workaround**: use a clamp-based
  step function:
  ```
  // step = 1 if (x > threshold) else 0
  clamp((x - threshold) * 1e6, 0, 1)
  // result = move if (cond) else 0
  move * clamp((cond_lhs - cond_rhs) * 1e6, 0, 1)
  ```
  The `* 1e6` makes the boundary sharp (<1 µunit transition zone).
  Older demos (harvestcore, tinypond) that use ternary may have
  silently been taking the IF branch always — audit on next pass.
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
