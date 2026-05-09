# ADR 0030 — Occupation/Class primitive

_Date: 2026-05-09_
_Status: proposed_

## Context

Aldenmere (the long-arc successor world to the merchant demo) builds
toward 15+ playable occupations across its four phases: farmer,
hunter, warrior, healer, merchant, scholar, smith, fisher, builder,
herbalist, scribe, captain, priest, mage, leader, plus more emergent
specializations introduced in Phase 3-4 (e.g. court physician,
faction strategist, dynasty heir). The world.md "Class system & UI/UX
discipline" section makes the design contract explicit: each
occupation is a complete UI/UX surface, not a stat bundle.

A class is therefore a coherent BUNDLE of data:

| Channel | Per-class variation |
|---|---|
| Verb-set | farmer has plant/water/harvest; warrior has attack/block/charge; healer has diagnose/treat/brew |
| HUD panel | farmer sees crop yields + weather; warrior sees combat stats; merchant sees gold + queue |
| Ambient barker pool | farmers talk weather, smiths talk iron, scholars talk parchment |
| Camera preference | farmer iso-top-down, warrior third-person, scholar overhead |
| Audio bed | smith anvil-rings, healer mortar-grinding, scholar parchment-rustling |
| Progression curve | linear / exponential / capped — class designer chooses |
| Stat keys | per-class skill fields (`farming_skill`, `combat_skill`, `healing_skill`) |
| Level unlocks | new verbs unlocked at level thresholds |

Phase 2 onwards lets the player switch classes mid-game. **Inventory
and faction reputation persist across switches** (they're properties
of the player-actor, not the class). **Class-specific stats live in a
per-class `class_progress[<class_id>]` record** so a level-3 farmer
returning to farming after a hunter detour finds wheat-specialty
intact, not reset. **Switching must be fluid** — no level reload, no
respawn, no save-quit-reload dance. The HUD swap and verb-binding
swap happen in-place at a single tick boundary.

The merchant demo's existing pattern (one set of verbs hard-bound at
load via `ui/input.json`; one HUD authored in `hud.json`; barkers
authored as flat ambient rules) collapses under this requirement.
Per-class authoring needs first-class engine support so games declare
classes in JSON and the engine swaps the bundle on a single
`switch_class` effect.

This is also reusable beyond Aldenmere. A tower-defense game's
"tower-builder" mode vs "wave-commander" mode is the same shape. A
party-based RPG's class swap-out at a town shrine is the same shape.
A factory game's "engineer" vs "logistics-manager" view is the same
shape. The pattern is: **a player-controlled actor has a bundled
role-state that swaps as a unit**.

Without a class primitive, every game that wants this composes it
ad-hoc through 8-12 boilerplate rules per class — and ends up
authoring N copies of "swap the HUD" wiring, with all the screen-flow
+ effect-chain footguns this codebase has spent multiple sessions
hardening (pause-fade pairing, destructive-effect ordering, modal
revealing world). The primitive abstracts that into one effect.

## Decision

Add a **declarative class primitive** with three parts:

1. **Class definitions in JSON** — `data/<game>/classes/<name>.json`
   files (or `@lib.classes.<name>` for cross-game reuse via ADR 0027).
   Each declares verbs, hud_panel ref, barker_pool ref, audio_bed ref,
   camera_mode, progression_curve, stat_keys, level_unlocks.

2. **Player-actor state schema extension** — `current_class` (string)
   + `class_progress` (dict keyed by class_id) added to the player
   entity's `state_init`. `inventory` and `reputation` remain
   class-agnostic (they're already on the actor, untouched by this
   ADR).

3. **`switch_class` effect** — atomic swap: validates the cooldown,
   updates `current_class`, fires the HUD-panel swap via screen_flow,
   re-binds the active verb-set via input_registrar, swaps the audio
   bed + barker pool registration, emits a `class_switched` signal
   for game-rules subscribers.

A new `class_manager.gd` module loads class defs at world boot and
hosts the swap logic. The implementation is interpreter-shaped — it
composes existing primitives (state_set, screen_flow operations,
audio_bus changes) under one declarative effect; no new VERBS beyond
`switch_class`.

### Class definition schema

```jsonc
// data/aldenmere/classes/farmer.json
//   OR @lib.classes.farmer (for cross-game reuse)
{
  "id": "farmer",
  "display_name": "Farmer",

  "verbs": ["plant", "water", "harvest", "tend_livestock"],
  // Each verb name is an action that's expected to exist in
  // ui/input.json. switch_class enables/disables these actions
  // (input poll + InputMap action_erase_events for the OFF set;
  // re-add for the ON set). Other classes' verbs become inactive.

  "hud_panel": "@lib.hud.farmer_panel",
  // Reference to a hud.json panel definition. screen_flow swaps
  // the per-class HUD region in-place; cross-class HUD elements
  // (gold, time-of-day, location label) stay put.

  "barker_pool": "@lib.barkers.farmer",
  // Reference to a barker pool — list of strings with mood tags.
  // ambient_barker.gd reads from the active class's pool when
  // selecting next ambient line.

  "audio_bed": "@lib.audio_beds.farmer",
  // Reference to an audio cue map. Gets registered into the
  // ambient bus on class switch; previous class's bed
  // unregistered.

  "camera_mode": "iso_top_down",
  // game_shell.gd already knows the camera-mode strings
  // (top_down_3d / iso_top_down / third_person_3d /
  // first_person_3d / fixed). switch_class triggers a
  // _set_camera_mode call.

  "progression_curve": "linear",
  // "linear" | "exponential" | "capped" — drives xp_to_level
  // formula. Authored via existing Formula language.

  "stat_keys": ["farming_skill", "harvest_speed"],
  // Class-specific stat fields. Their values live in
  // class_progress[farmer].<stat>. Rules query them via the
  // standard `self.class_progress.farmer.farming_skill` binding.

  "level_unlocks": [
    {"level": 3, "unlock_verb": "graft"},
    {"level": 5, "unlock_verb": "irrigate"},
    {"level": 7, "unlock_verb": "fallow_rotation"}
  ],
  // When class_progress[farmer].level reaches threshold, the
  // listed verb is appended to the active verbs[]. Persisted in
  // class_progress[farmer].unlocked_verbs.

  "switch_cooldown_days": 1
  // Minimum in-game days between switches. Default 0
  // (no cooldown). class_manager checks
  // world_state.day - last_switch_day >= cooldown.
}
```

### Player-actor state schema

```jsonc
// On the player entity (e.g. data/<game>/entities/player.json)
{
  "id": "player",
  "tags": ["player", "actor"],
  "state_init": {
    "current_class": "farmer",        // optional; if absent → no class system
    "class_progress": {
      "farmer": {
        "level": 3,
        "xp": 240,
        "unlocked_verbs": ["graft"],
        "specialty": "wheat"
      },
      "hunter": {"level": 1, "xp": 30, "unlocked_verbs": []}
    },
    "inventory": [...],               // shared across switches
    "reputation": {...},              // shared across switches
    "last_switch_day": 0              // bookkeeping for cooldown
  }
}
```

Class-specific stats live in `class_progress[<class_id>]`. The
`stat_keys` list in the class def is content's contract — when
class-specific rules read `self.class_progress.farmer.farming_skill`,
the field exists because `state_init.class_progress.farmer` was
populated.

### `switch_class` effect

```jsonc
{
  "type": "switch_class",
  "target": "self",                  // resolves to the player actor
  "to_class": "warrior",             // string class_id
  "skip_cooldown": false,            // optional; tutorial / debug bypass
  "skip_audio_swap": false,          // optional; for stealth/silent swap
  "on_failure_signal": "switch_class_blocked"
  // emit signal if cooldown blocks switch; lets game-rules surface
  // a toast or HUD note. No signal = silent reject.
}
```

Effect resolution sequence (atomic — runs as one effect-apply call,
either fully completes or fully no-ops on validation failure):

1. **Validate** — class_id exists; cooldown satisfied unless
   `skip_cooldown: true`; target entity has `current_class` field.
2. **Snapshot** — record old class_id for the signal payload.
3. **Update state** — `target.state.current_class = to_class`;
   `target.state.last_switch_day = world.day`.
4. **HUD swap** — call ScreenFlow/GameShell hook to rebuild the
   per-class HUD region using the new class's `hud_panel` reference.
5. **Verb rebind** — call InputRegistrar/ClassManager hook to set
   InputMap action availability for the new class's `verbs[]`.
6. **Camera swap** — call GameShell hook to set camera mode if
   class declares one.
7. **Audio swap** — call AudioBusManager hook to switch ambient bed
   (no-op if `skip_audio_swap`).
8. **Barker pool swap** — class_manager updates the active pool
   reference; ambient_barker.gd reads from it on next selection.
9. **Emit signal** — `class_switched` with payload
   `{from: old_class, to: new_class, day: world.day}` for game-rules
   that need to react (e.g. unlock dialogue, toast, achievement).

If validation fails (cooldown not met, class_id unknown), step 9
emits `on_failure_signal` instead and steps 3-8 are skipped. No
state mutation.

### `class_manager.gd` module

`godot/scripts/engine/class_manager.gd` — a `Node`, sibling of
`LightingDirector` / `OverlayManager` / `ScreenFlow` / `PartyDirector`
under `play.tscn`. ~80-100 LoC.

```gdscript
extends Node
class_name ClassManager

## ADR 0030 — Occupation/class primitive.
##
## Loads class defs from data/<game>/classes/*.json at world boot
## (resolved through LibResolver so @lib.classes.X refs work).
## Hosts switch_class semantics: validates cooldown, updates state,
## triggers HUD/verb/camera/audio swap, emits signals.

var _class_defs: Dictionary = {}      # class_id -> resolved def dict
var _current_class: String = ""       # cache of player.state.current_class

# References injected by world.gd at load
var _env: Dictionary = {}
var _game_shell: Node = null          # for HUD + camera swaps
var _screen_flow: Node = null         # for per-class HUD panel push

func load_from_data_root(root: String, env: Dictionary) -> void:
    _env = env
    var classes_dir := root + "/classes"
    if not DirAccess.dir_exists_absolute(classes_dir):
        # Optional — games without classes load no defs (no-op).
        return
    var dir := DirAccess.open(classes_dir)
    if dir == null: return
    dir.list_dir_begin()
    while true:
        var fname := dir.get_next()
        if fname == "": break
        if not fname.ends_with(".json"): continue
        var path := classes_dir + "/" + fname
        var raw := _read_json(path)
        if raw.is_empty(): continue
        # Resolve any $extends / @lib refs through LibResolver
        var resolved: Dictionary = LibResolver.resolve(raw, _env)
        var cid := str(resolved.get("id", ""))
        if cid == "":
            push_warning("[ClassManager] class def missing 'id': %s" % path)
            continue
        _class_defs[cid] = resolved
    dir.list_dir_end()

func get_class_def(class_id: String) -> Dictionary:
    return _class_defs.get(class_id, {})

func switch_class(target_id: String, to_class: String,
                  opts: Dictionary = {}) -> Dictionary:
    # Returns {"ok": bool, "reason": String, "from": String, "to": String}
    var def: Dictionary = _class_defs.get(to_class, {})
    if def.is_empty():
        return {"ok": false, "reason": "unknown_class",
                "from": _current_class, "to": to_class}
    var ent_state: Dictionary = _env["entities"][target_id].state
    var from_class := str(ent_state.get("current_class", ""))
    # Cooldown check
    if not opts.get("skip_cooldown", false):
        var last := int(ent_state.get("last_switch_day", 0))
        var cd := int(def.get("switch_cooldown_days", 0))
        var day := int(_env.get("world", {}).get("day", 0))
        if day - last < cd:
            return {"ok": false, "reason": "cooldown",
                    "from": from_class, "to": to_class}
    # Atomic apply
    ent_state["current_class"] = to_class
    ent_state["last_switch_day"] = int(_env.get("world", {}).get("day", 0))
    _swap_hud(def)
    _swap_verbs(def)
    _swap_camera(def)
    if not opts.get("skip_audio_swap", false):
        _swap_audio(def)
    _current_class = to_class
    # Emit signal (drained by phase scheduler)
    _env.get("signal_buffer", []).append({
        "name": "class_switched",
        "payload": {"from": from_class, "to": to_class,
                    "day": _env.get("world", {}).get("day", 0)}
    })
    return {"ok": true, "from": from_class, "to": to_class}

func _swap_hud(def: Dictionary) -> void:
    if _game_shell == null: return
    var panel_ref = def.get("hud_panel", null)
    if panel_ref == null: return
    _game_shell.rebuild_class_hud(panel_ref)

func _swap_verbs(def: Dictionary) -> void:
    var active_verbs: Array = def.get("verbs", [])
    # Disable all class-owned verbs first (any verb listed in any class def)
    for cid in _class_defs.keys():
        for v in _class_defs[cid].get("verbs", []):
            if InputMap.has_action(str(v)):
                InputMap.action_erase_events(str(v))
    # Re-bind the new class's verbs from inputs registry snapshot
    InputRegistrar.rebind_actions(active_verbs)

func _swap_camera(def: Dictionary) -> void:
    if _game_shell == null: return
    var mode := str(def.get("camera_mode", ""))
    if mode == "": return
    _game_shell.set_camera_mode(mode)

func _swap_audio(def: Dictionary) -> void:
    var bed_ref = def.get("audio_bed", null)
    if bed_ref == null: return
    AudioBusManager.set_ambient_bed(bed_ref)

func _read_json(path: String) -> Dictionary:
    var f := FileAccess.open(path, FileAccess.READ)
    if f == null: return {}
    var raw := f.get_as_text()
    f.close()
    var json := JSON.new()
    if json.parse(raw) != OK: return {}
    return json.data if json.data is Dictionary else {}
```

### Engine wiring

- `world.gd::load_data` — after `actor_manager` load + before
  `_load_entities_path`: instantiate ClassManager, call
  `class_manager.load_from_data_root(root, _build_env())`. Inject
  `_game_shell` + `_screen_flow` references after scene tree is up.
- `effect_apply.gd` — add a `switch_class` match arm dispatching to
  `class_manager.switch_class(target_id, to_class, opts)`. Returns
  the `{ok, reason, from, to}` dict; on failure, emit
  `on_failure_signal` if specified.
- `game_shell.gd` — add `rebuild_class_hud(panel_ref)` that resolves
  the panel ref through LibResolver, removes the existing per-class
  panel children (tagged with `_class_panel = true` metadata), and
  rebuilds via the existing `_build_panel` machinery. Add
  `set_camera_mode(mode_string)` that re-runs the camera setup arm.
- `input_registrar.gd` — add `rebind_actions(active_set: Array)`
  static method. Uses pre-saved key bindings from `ui/input.json`'s
  initial registration (cached on `register_from_data_root`).
- `audio_bus_manager.gd` (or extension to existing audio pipeline) —
  add `set_ambient_bed(ref)` that resolves and registers the
  ambient cue layer.
- `phase_scheduler.gd` — no changes. The level_unlocks logic is
  rule-shaped (a tick rule queries `class_progress[<class>].xp`
  vs threshold and fires `state_set` to push the unlock_verb into
  `class_progress[<class>].unlocked_verbs`). Standard primitives.

### Reading class state from rules

Class state is just entity state. Existing bindings work:

```jsonc
// Query that fires only for the active farmer
{
  "trigger": {"type": "tick", "interval": 60},
  "query": {
    "tags_all": ["player"],
    "state": {"current_class_eq": "farmer"}
  },
  "effect": {...}
}

// Effect that increments class-specific xp
{
  "type": "state_add",
  "target": "self",
  "field": "class_progress.farmer.xp",
  "amount": 10
}
```

Nested-key field path support already exists in
`effect_apply.gd::_apply_state_add` (per the existing harvestcore
pattern). No new query operator needed.

### Operator surface boundary

`switch_class` is the only new effect type added. No new query
operator, no new trigger type, no new relation type. The class
schema is content; the swap mechanism is interpreter scope (mirrors
how ADR 0011 added `transition_screen` as a single effect that
internally orchestrates Control rebuilds).

If a future game wants per-class STARTING POSITIONS or per-class
CONTACT RULES that auto-attach on switch, that's a content
composition (rule that triggers on `class_switched` signal +
existing `teleport` / `relate` effects). NOT a new primitive.

## Consequences

### Enables

- **15+ classes scale via JSON** — adding a new class is one file in
  `data/aldenmere/classes/<name>.json`, no engine work.
- **Per-class UI/UX surface is data-driven** — HUD, verbs, camera,
  audio bed, barkers all swap as a coherent bundle.
- **Cross-game class reuse** — `@lib.classes.merchant` can be shared
  across any game wanting a shopkeeper occupation. Per ADR 0027, lib
  catalog grows organically.
- **Atomic switch** — no level reload, no respawn; inventory and
  reputation persist; class progress preserved per-class.
- **Class-tagged queries** — rules can `query: {tags_all: ["player"],
  state: {current_class_eq: "warrior"}}` to scope class-specific
  behavior without adding a new tag per class.
- **Backward compat with non-class games** — if `current_class`
  field absent on player, ClassManager's defs are empty, no swaps
  happen, all input verbs from `ui/input.json` stay active. Merchant,
  doomarena3d, sokoban etc. unchanged.

### Constrains

- **HUD swap is a new operation** — `game_shell.gd::rebuild_class_hud`
  needs careful scoping (only the class panel rebuilds, not the
  full HUD). Visual gate per `.claude/rules/visual-qa.md` MANDATORY
  on first implementation: capture before/after switch, verify
  cross-class elements (gold, time-of-day) survive intact and only
  the class panel changed.
- **Verb binding swap requires InputRegistrar extension** — must
  cache the original key bindings from `ui/input.json` so
  `rebind_actions` can re-issue them. Idempotency is the existing
  registrar's invariant; this just splits the active set.
- **Cooldown is days-based** — assumes `world.day` exists. Games
  without a day clock either set `switch_cooldown_days: 0` or
  declare `world_state.day` themselves.
- **Effect-chain ordering** — `switch_class` is non-destructive
  (doesn't reload scene, doesn't pop modals), so it composes safely
  in any chain position. Per `.claude/rules/engine-scripts.md` §
  effect-chain gate, this is documented in
  `docs/engine-reference/api-manifest.json`.
- **Resolver depth** — class defs may chain through `$extends` to a
  base class def in `@lib.classes.npc_class_base`. Existing depth-8
  bound (ADR 0028) applies; no new bound.

### Doesn't enable

- **Multi-class stacking** — one current_class at a time. A
  merchant-warrior hybrid is a SEPARATE class (`merchant_warrior`)
  whose def declares the merged verb set, not a runtime composition.
- **Per-class entities other than the player** — class is conceived
  as a player-actor role-bundle. NPC role differentiation stays
  with tags + properties. (A future ADR could extend if needed —
  e.g., a multiplayer game with class-typed NPCs — but Aldenmere
  doesn't need it.)
- **Mid-tick swap** — switch_class fires at effect-apply boundary,
  not mid-rule. A rule that triggers `switch_class` then queries
  the new class's verb set in the SAME tick gets the post-switch
  state on the NEXT tick. Standard Yume tick semantics.
- **Conditional unlocks based on quests/items** — the level_unlocks
  list is level-based only. Item-gated or quest-gated unlocks
  compose via game-rules listening on `class_switched` or item
  signals; they push the unlock_verb into `unlocked_verbs` via
  `state_set`. Not engine surface.

### Neutral

- **Existing demos work unchanged** — `current_class` is OPTIONAL;
  if absent, no class system runs. ClassManager loads zero defs
  if no `classes/` directory.
- **Save/load** — class state lives in entity state, which already
  persists per ADR 0010. No schema change to save_policy.json
  required (per-game policies that already declare the player
  entity persistent get class state for free).
- **Tests** — engine ships with 7 unit tests (see Test plan); per-
  game scenario tests opt-in.

## Alternatives considered

### A) Hard-coded class enums in engine

Add a `Class` enum in GDScript with verb-set / hud-panel hardcoded.

Pros: simplest implementation; type-checked at compile time.
Cons: violates Invariant #1 (data drives everything) and Invariant
#8 (engine = primitives + interpreter). Adding a class would require
engine code edit + recompile. Aldenmere needs 15+ classes, half
emergent — engine can't enumerate them. **Rejected**.

### B) Classes as full entity defs (one entity per class)

Make each class a separate entity. Switching = despawn old, spawn
new. State carries via `transfer_state` effect.

Pros: zero new primitive; uses existing spawn/despawn vocabulary.
Cons: confusing semantics — a "class" is a PROPERTY of an actor, not
an actor itself. Despawn breaks party-membership relations,
spatial-index entries, navmesh anchors. State transfer becomes a
manual chore (inventory, reputation, position, party membership,
relations all need explicit copy). **Rejected**.

### C) Classes as tag bundles

Use existing tags. A "farmer" entity has tags `["player", "farmer",
"can_plant", "can_water", "can_harvest"]`. Switching = remove old
class-tags, add new. Verbs gated by tag presence in rule queries.

Pros: zero new primitive.
Cons: tags don't capture HUD layout, camera mode, audio bed,
progression curve, level unlocks — those are STRUCTURED data, not
membership labels. Authoring 15 classes via tag bundles balloons the
content surface (15 classes × 4-8 verbs each = 60-120 tags, plus
parallel hud.json conditional regions, parallel barker rules per
tag). **Rejected — works for queries, fails for the bundled
UX surface.**

### D) Switch via reload_scene

Treat class switch as a scene transition. `[save_state, load_data,
spawn_player_with_new_class]`.

Pros: uses existing save/load primitives.
Cons: per the post-mortem 2026-05-08 lesson, destructive effects
must be LAST in their chain — and reload_scene mid-game means a
black-screen + load delay every switch. Aldenmere wants
**fluid** switching (the player turns to face the smithy, presses
"become smith," and is the smith) — not a 2-second reload. Also
re-runs all level-init logic (re-spawning NPCs, re-binding
relations) for what should be a five-field swap. **Rejected.**

### E) Add a runtime "role" sub-system separate from this primitive

Introduce a "role" concept that's narrower (just verb-set + HUD).
Audio + camera + barkers stay manual.

Pros: smaller surface; less engine code.
Cons: every class would still need 4-5 hand-wired rules to swap
audio/camera/barkers on `class_switched` signal. The boilerplate
multiplies across 15 classes (60-75 rules to maintain). The whole
point of a primitive is to bundle the entire role-state into one
declarative knob. **Rejected — half-measure.**

## References

- `docs/games/aldenmere/world.md` — "Class system & UI/UX
  discipline" section (the design contract this ADR satisfies)
- `docs/games/aldenmere/engine_roadmap.md` — ADR 0030 sketch
  (this document expands the sketch)
- `docs/games/aldenmere/phase2_GDD.md` — Phase 2 specifications
  for occupation gameplay
- ADR 0011 (declarative-screen-flow) — `transition_screen` pattern
  this ADR mirrors for HUD swap
- ADR 0013 (settings-schema-and-config) — InputMap dynamic registration
  pattern via InputRegistrar
- ADR 0026 (party-member-primitive) — `PartyDirector` peer-Node
  pattern this ADR mirrors for ClassManager
- ADR 0027 (cross-game-json-reuse-system) — `@lib.classes.X` /
  `$extends` enables cross-game class reuse
- ADR 0028 (cross-game-parameterized-templates) — `$params` lets
  a parameterized class template specialize per game (e.g. base
  `merchant_class` + per-game progression curve)
- `godot/scripts/engine/world.gd` — class-manager load hook
  (`load_data` after actor_manager init)
- `godot/scripts/engine/input_registrar.gd` — gains
  `rebind_actions(active_set)` static method
- `godot/scripts/engine/game_shell.gd` — gains
  `rebuild_class_hud(panel_ref)` + `set_camera_mode(mode)` hooks
- `godot/scripts/engine/effect_apply.gd` — gains `switch_class`
  match arm

## Test plan

7 unit tests in `godot/scripts/engine/tests/test_runner.gd`,
section `test_class_primitive`:

| Test | Verifies |
|---|---|
| `test_class_def_loads` | classes/*.json files load into ClassManager._class_defs; @lib.classes.X refs resolve through LibResolver |
| `test_switch_class_basic` | switch_class effect updates `current_class` field; emits `class_switched` signal with from/to/day payload |
| `test_inventory_persists_across_switch` | switch_class farmer→warrior; player.state.inventory unchanged |
| `test_reputation_persists_across_switch` | switch_class farmer→merchant; player.state.reputation unchanged |
| `test_class_progress_preserved_per_class` | level-3 farmer switches to hunter, gains hunter xp, switches back; class_progress.farmer.level still 3, class_progress.hunter.xp persists |
| `test_cooldown_blocks_switch` | switch_class with cooldown=1 day on day 0; second switch on day 0 emits `on_failure_signal` (reason=cooldown), state unchanged |
| `test_unknown_class_fails_atomic` | switch_class with unknown class_id; emits failure signal, no state mutation, HUD/camera/audio unchanged |

Two scenario tests (`tests.json` per Aldenmere demo) cover the
integrated path: full HUD swap + verb rebind + camera mode change
visible in capture.

Visual-QA gate (per `.claude/rules/visual-qa.md`) on first
implementation:
- Capture frame N (active class = farmer, HUD shows crop yields).
- Trigger switch_class to warrior.
- Capture frame N+1 (HUD must show combat stats panel; cross-class
  elements like gold + time intact; camera mode shifted to
  third_person_3d).
- Failure modes: cross-class HUD elements lost; old class panel still
  visible; verbs not actually disabled (player still has plant
  action); camera mode unchanged.

Effect-chain gate (per `.claude/rules/engine-scripts.md`) — none
required; switch_class is non-destructive, composes in any chain
position.

## Implementation sketch

Phases of work, sequenced:

**Phase 1 — Engine module + effect (~2-3 hours)**
- Write `class_manager.gd` (~80-100 LoC per pseudocode above).
- Add `switch_class` arm to `effect_apply.gd` (~20 LoC).
- Add `rebind_actions(active_set)` to `input_registrar.gd` (~25
  LoC) + cache initial bindings on `register_from_data_root`.
- Add `rebuild_class_hud(panel_ref)` + `set_camera_mode(mode)`
  to `game_shell.gd` (~30-40 LoC).
- Wire `world.gd::load_data` to instantiate ClassManager and
  inject scene-tree refs (~10 LoC).
- Add ClassManager node to `play.tscn` (~3 lines of TSCN).
- 7 unit tests in test_runner.gd (~150 LoC).

**Phase 2 — Aldenmere class catalog (post-Phase 1, content-side)**
- Author `data/aldenmere/classes/farmer.json`,
  `hunter.json`, `warrior.json`, `merchant.json`, `healer.json`,
  `scholar.json`, ... (per Phase 2 GDD).
- Author corresponding `@lib.hud.<class>_panel`,
  `@lib.barkers.<class>`, `@lib.audio_beds.<class>` entries.
- Wire game-rules listening for `class_switched` to surface a toast
  + tutorial-overlay update.
- Visual-QA pass per gate above.

**Phase 3 — Cross-game catalog promotion (deferred)**
- Promote first stable class def (likely `merchant`) to
  `@lib.classes.merchant` once a second game wants it.
- Per ADR 0027 norms, defer until first multi-consumer use case.

Total engine LoC: ~350-400 (module + effect + tests + game_shell
hooks + registrar extension + world load).

## Performance budget

- **Class def loading**: O(N) at world boot, where N = class def
  files. ~5-15ms for 15 class defs (FileAccess + JSON.parse +
  LibResolver). Negligible — once-per-world-load.
- **switch_class effect**: O(1) — swap ~5 entity-state fields,
  rebuild one HUD panel (~10-20 Control nodes), rebind ~5
  InputMap actions, change camera mode (~5 Camera3D properties).
  Estimated ~5-10ms total. Acceptable for a deliberate player
  action; not invoked per-tick.
- **Per-tick cost**: ZERO. ClassManager doesn't run a `_process`
  hook. `current_class` is just a state field; rules read it via
  the standard query pipeline.
- **Memory**: ~2-5KB per class def in `_class_defs` cache.
  15 defs ≈ 75KB. Negligible.

## Migration / backwards-compat

- **Existing demos**: zero migration. `classes/` directory absent
  → ClassManager loads no defs. `current_class` field absent on
  player → no class-gated queries fire. All current input verbs
  from `ui/input.json` remain active (no class swap → no
  rebind). Verified by running merchant + sokoban + doomarena3d
  test suites unchanged.
- **Aldenmere Phase 1** (no occupations yet): can ship without
  class defs OR ship with a single `villager` class that's the
  "default occupation" with all Phase 1 verbs (gather, plant,
  hunt, fish, build, sleep). The latter primes for Phase 2's
  first switch.
- **Aldenmere Phase 2 and later**: full class system live; player
  starts in `villager`, transitions to a phase-2 class via
  in-world action (e.g. visit smithy + apprentice for 3 days =
  emits `apprentice_complete` signal → game-rules fires
  `switch_class` to `smith`).
- **Save schema versioning**: per ADR 0010, save policy declares
  `current_class` + `class_progress` as persistent fields. No
  schema-version bump needed since these are additive optional
  fields; missing-field on legacy save = empty class state =
  no-op. Per ADR 0010 § migration norms.

## Risks

- **HUD region scoping** — `rebuild_class_hud` MUST swap only the
  class panel, not the full HUD. If implementation accidentally
  rebuilds gold / time-of-day / objective-banner elements, those
  flicker on every switch. Visual-QA gate catches at first
  implementation; reviewer checklist captures going forward.
  Mitigation: tag class-panel Control children with metadata
  `set_meta("_class_panel", true)` on creation; rebuild only
  walks children with that flag.
- **InputMap action collision** — if two classes declare the same
  verb name (e.g. both farmer and hunter list "harvest"), swap
  re-uses the same InputMap action. This is INTENDED (one verb
  = one action), but content authoring needs the discipline.
  Mitigation: `tools/validate_classes.py` lint that flags duplicate
  verb names across classes for review (warn, not error — sometimes
  intentional).
- **Cooldown clock dependency** — if a game without a day clock
  declares classes with `switch_cooldown_days > 0`, the cooldown
  check reads `world.day = 0` always and blocks ALL switches after
  the first. Mitigation: ClassManager logs a warning at load if
  cooldown > 0 but `world_state.day` field never appears in
  state.json + flow.json. Author guidance: set cooldown to 0 if
  no day clock.
- **Audio bed swap latency** — switching ambient bed on
  AudioBusManager fires a stream change; depending on Godot's
  AudioStreamPlayer crossfade, may take 0.1-0.5s to settle. For
  game-feel, this is acceptable (a "before you become a smith"
  vs "you ARE a smith" transition feels right with a small
  crossfade). Mitigation: AudioBusManager uses tween-fade rather
  than hard cut (existing pattern).
- **Class def schema drift** — adding a new field to the class def
  schema (e.g. Phase 4's `dynasty_inheritance: true`) without
  versioning could leave older class defs missing the field.
  Mitigation: ClassManager treats missing fields as default values
  at load; new fields are additive. Document in
  `docs/engine-reference/api-manifest.json` when added.
- **Aging/lifecycle interaction (ADR 0036)** — player aging crosses
  life stages (child → adult → elder). Some classes may be
  age-gated (no toddler smiths). This is content-side: a tick rule
  on `age_state_changed` signal can fire `switch_class` back to a
  default class if current class isn't age-allowed. ADR 0036 doesn't
  modify the class primitive surface; it adds rules-content on top.
- **Dynasty inheritance (ADR 0034)** — heir takes over with
  fresh class progression per the world.md spec. ADR 0034 will
  declare an effect chain `[transfer_inventory, transfer_reputation,
  reset_class_progress, switch_class to default, transition_player_to
  heir]`. The class primitive supports this via `class_progress`
  being just entity state (overwritable via `state_set`).
