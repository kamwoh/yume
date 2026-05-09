# ADR 0029 — Schedule primitive

_Date: 2026-05-09_
_Status: proposed_

## Context

Aldenmere Phase 1 ships 8-12 named NPCs whose **daily rhythm IS the
game** (Submission aesthetic per phase1_GDD.md §"Voice & texture"). Each
NPC must wake at dawn, work mornings, eat midday, work afternoons,
gather at the central fire each evening, and sleep through the night —
authentically and visibly, every in-game day for 30 days.

There is no current way to author this in Yume's primitives without
hand-coding a wall of tick-rules per NPC. With 8 NPCs × ~6 schedule
slots × ~3 supporting tick rules each (entry conditions, target
selection, transition stings), Phase 1 alone would cost ~150 hand-
authored rules just for daily routine — half the rule budget for the
whole campaign.

More importantly, **this scheme does not generalize forward**:

| Phase | NPC count | Hand-coded rules required |
|---|---|---|
| 1 (Survival) | 8-12 | ~150 |
| 2 (Settlement) | 15-50 | ~600 |
| 3 (Society) | 50-200 | ~3000 |
| 4 (Civilization) | 200-500 | ~9000 |

The Aldenmere world bible explicitly commits to **emergent over
pre-defined** (world.md §"The pillar: emergent over pre-defined") —
NPCs are simulated, not scripted. Per-NPC scheduling rules are
the WORST case for that thesis: they bloat content, make every
NPC a hand-authored unit, and forfeit the framework's reuse
discipline.

What Phase 1's GDD §"Cascade 1 — The Daily Rhythm" actually
declares is a **schedule with five fixed slots** mapping wall-clock
hours to a `current_verb` + `location_tag`. Phase 1's open
question (§"For systems-designer", item 5) explicitly asks for
this primitive: *"Schedule definition: list of `{start_hour,
end_hour, verb, location_tag, fallback_verb}` slots. Tendency
drift integrated into 'fallback verb when ambiguous'."*

A declarative schedule primitive encodes that intent once in the
engine and exposes it as JSON to all 200-500 NPCs across all four
phases. Per Invariant #8 (engine = primitives + interpreter), this
is the canonical shape: a fixed verb (the `schedule` block) +
interpreter (a new `ScheduleDirector`) consumes the JSON and
produces existing-primitive effects (`state_set` for
`current_verb`/`current_target`; `emit` for the
`schedule_phase_changed` signal).

Per ADR 0021 (Yume = JSON layer over Godot), the director is an
interpreter — not a new behavior tree, not a planner, not a utility-
AI scoring system. It reads JSON; resolves which slot is active for
the current in-game hour; sets two state fields and optionally emits
a signal. AI rules — the same `tick`-triggered, `query`-bound,
`effect`-firing rules content authors already write — consume those
fields to do real work (move toward target, perform verb, restore
need).

Constraints:
- Cannot break Invariant #2 (no semantic effect types). A schedule
  is data; the director resolves data into existing-primitive effects.
- Cannot break Invariant #8 (engine = primitives + interpreter). The
  schedule block is the new primitive; ScheduleDirector is the
  interpreter; nothing about WHAT NPCs do moves into engine code.
- Must compose with ADR 0017 (spatial-LOD): off-camera NPCs at Phase
  3-4 scale must resolve schedules at lower frequency without behavior
  visibly desyncing.
- Must integrate with ADR 0027 (`@lib.X.Y` + `$extends`): authors
  declare schedules once (`@lib.schedules.standard_villager`,
  `@lib.schedules.farmer`, `@lib.schedules.smith`) and reference
  per-NPC.
- Must compose with ADR 0036 (lifecycle / aging) when Phase 2 lands:
  children have different schedules than adults; elders run a slower
  variant. Schedule selection per life-stage is emergent from
  `$extends` + tag-based selection at content layer — no engine
  change needed.

## Decision

Add a `schedule` block to entity definitions, plus a new engine
module `schedule_director.gd` that reads it each tick, resolves the
current slot from a bound time-of-day source, and writes
`current_verb` + `current_target` onto the entity's state.

### Schema

```jsonc
// In an entity def (or via @lib.schedules.standard_villager + $extends)
{
  "id": "villager_marken",
  "tags": ["villager", "named_npc"],
  "state_init": {
    "current_verb": "idle",
    "current_target": "",
    "tendency": {"gather": 0, "hunt": 0, "tend": 0, "craft": 0, "fish": 0}
  },
  "schedule": {
    "binds_to": "world_clock.current_hour",   // optional; default same
    "wraps_at": 24.0,                         // optional; default 24.0
    "slots": [
      {"start": 6.0,  "end": 7.0,  "verb": "wake",      "location_tag": "home"},
      {"start": 7.0,  "end": 12.0, "verb": "work",      "location_tag": "field",
       "fallback_verb_by_tendency": ["gather", "hunt", "tend"]},
      {"start": 12.0, "end": 13.0, "verb": "eat",       "location_tag": "home"},
      {"start": 13.0, "end": 18.0, "verb": "work",      "location_tag": "field",
       "fallback_verb_by_tendency": ["gather", "hunt", "craft"]},
      {"start": 18.0, "end": 21.0, "verb": "socialize", "location_tag": "fire_pit"},
      {"start": 21.0, "end": 6.0,  "verb": "sleep",     "location_tag": "home"}
    ],
    "default_verb": "idle",                   // when no slot matches
    "emit_on_transition": true                // emit schedule_phase_changed signal
  }
}
```

### Slot resolution semantics

1. **Bound time source.** `binds_to` reads
   `<entity_tag>.<field>` (entity-tag form per data-demo.md
   convention) or `world.<field>` (env.world_state form). Default
   `world_clock.current_hour`. Director caches the parse once at
   load.
2. **Active-slot pick.** Each tick, ScheduleDirector reads the bound
   time value, then walks `slots` in order. The first slot whose
   `[start, end)` interval contains the time WINS. **Wrap-around**
   slots (`start > end`, e.g. 21.0 → 6.0) match if `time >= start`
   OR `time < end`.
3. **Overlap handling.** If two slots' intervals overlap, the
   FIRST in JSON order wins. Validator (see §Validation) flags
   overlap and warns at sync time; runtime accepts and uses
   first-match.
4. **No matching slot.** Director writes `current_verb =
   default_verb` (default `"idle"`) and `current_target = ""`.
5. **Verb selection (with tendency drift).** If the matched slot
   has `fallback_verb_by_tendency` (an array of verb names), the
   director picks the verb whose tendency stat on this entity is
   HIGHEST. Ties broken by JSON order. Falls back to slot's
   `verb` if entity has no `tendency` dict OR all listed tendencies
   are zero. This is how the Phase 1 GDD's "tendency drift" cascade
   becomes visible behavior — a villager who's gathered 30 times in
   the morning slot now picks "gather" first as their work verb;
   one who's hunted 30 times picks "hunt." Identical schedule
   shape, divergent observed routine.
6. **Target resolution.** When `location_tag` is set, the director
   resolves it ONCE per slot transition (not every tick) by:
   - Querying for entities with `tags_all: [<location_tag>]` near
     the entity (radius from properties.aabb_extents fallback to
     unbounded); if a `home_at` / `works_at` / `tends` relation
     exists pointing at a same-tag target, prefer that.
   - Picking the nearest match.
   - Writing the matched entity's `id` to `current_target`.
   If no entity matches, `current_target = ""` and the director
   leaves `current_verb` set anyway (AI rules can fail open).
7. **Phase-transition signal.** When the active slot changes for an
   entity (compared to last tick's active slot), the director emits
   `schedule_phase_changed` with payload `{entity, old_verb,
   new_verb, slot_index}` IF `emit_on_transition: true` (default).
   Content rules subscribe via `signal` trigger to drive juice
   (toast "Marken heads home for the night") or audio cues
   (ambient lull at the dawn-rise transition).

### Effect-side surface

ScheduleDirector composes existing primitives — no new effect types:

- `state_set target=<entity> field=current_verb value=<resolved>`
- `state_set target=<entity> field=current_target value=<id|"">`
- `emit signal=schedule_phase_changed payload={...}` (when
  emit_on_transition true and slot changed)

These three form a single batch per entity per tick. They go
through `effect_apply.gd` like any other effect, respecting phase
ordering (queued in `decide`, applied in `commit`).

### Phase-scheduler integration

ScheduleDirector ticks at the START of `decide` phase (before
tick-rules fire). Reasoning: AI rules must read the
just-resolved `current_verb` / `current_target` in the SAME tick
they were written. With the director executing first in `decide`,
the writes land in the commit buffer; AI rules later in `decide`
read from `env.entities[*].state` (snapshot of pre-commit) — so
they see the PREVIOUS tick's verb. Acceptable: with tick_seconds
≈ 0.1-0.5, a 1-tick latency is invisible. **Confirmed direction
via test_w2_integration semantics** — this is the same
input → decide → commit cadence chess + sokoban already use.

Alternative considered: write directly to entity.state
(bypassing the commit buffer) so same-tick AI sees the new verb.
Rejected — bypassing commit breaks the "rules see a stable
snapshot" invariant. 1-tick lag is the right tradeoff.

### Spatial-LOD interaction (ADR 0017)

ScheduleDirector accepts the same `lod` config as rules:

```jsonc
"schedule": {
  "lod": {
    "anchor": "active_actor",
    "enter_radius": 60,
    "leave_radius": 80,
    "outside_mode": "tick_slowed:0.5"
  },
  "slots": [...]
}
```

Off-camera NPCs at Phase 3-4 scale resolve schedules at 0.5 Hz (or
whatever rate). The slot-active-set is a step function of time, so
even a 2-second resolution latency produces correct slot pick
99.99% of the time (boundaries miss-by-2-seconds is acceptable). LOD
defaults to None → resolve every tick if the schedule has no `lod`
block (Phase 1 keeps simple behavior; Phase 3+ skills add `lod`).

### Lib catalog

```
data/lib/schedules/
├── standard_villager.json     // wake/work/eat/work/socialize/sleep
├── farmer.json                // longer field work, dawn start
├── smith.json                 // forge daytime, evening guildhall
├── hunter.json                // pre-dawn hunt, midday rest, dusk hunt
├── child.json                 // play, gather, follow parent
├── elder.json                 // shorter work, longer fire-tend
└── manifest.json
```

Per-game NPCs `$extends` a lib schedule and override slots / tags
where needed. Per Phase 1 GDD §"For content-designer item 1", the
campaign opens with `@lib.schedules.standard_villager` for all 8 NPCs
+ a couple manual variations (Elder Morwen uses `elder` schedule).

### Authorship pattern (for skill guidance)

yume-content-designer + yume-systems-designer + future
yume-schedule-designer (Phase 2 occupation roll-out) author per-NPC
schedules. yume-game-rules-designer authors AI rules that consume
`current_verb` + `current_target`:

```jsonc
// Example consumer rule (lives in game/rules.json, not engine):
{
  "id": "npc_walks_to_target_during_work",
  "trigger": {"type": "tick", "interval": 1},
  "query": {
    "tags_all": ["villager"],
    "state": {"current_verb_eq": "work"}
  },
  "effect": {
    "type": "pathfind_to",
    "target": "self",
    "destination_x": "self.current_target.state.position[0]",
    "destination_y": "self.current_target.state.position[1]",
    "destination_z": "self.current_target.state.position[2]",
    "speed": 2.5
  }
}
```

The schedule is the WHEN/WHAT; AI rules are the HOW.

## Consequences

### Enables

- Phase 1's "daily rhythm" cascade authorable as data, scaling
  cleanly to Phase 4's 200-500 NPCs.
- **Tendency drift** (Phase 1 GDD §"Cascade 3") becomes visible
  emergent behavior with no extra rules — every verb performed
  bumps the entity's tendency stat (one tick rule); the schedule
  director picks the highest-tendency verb at next slot. By Day 30,
  NPCs visibly differentiate.
- Cross-game reuse via `@lib.schedules.X`. Future merchant-style
  game with shopkeeper NPCs uses `@lib.schedules.shopkeeper` (open
  shop dawn-dusk, close at dusk) trivially.
- Composes with ADR 0030 (occupation/class) cleanly: a class def
  declares its schedule (`@lib.schedules.smith`); switching class
  swaps which schedule the player's entity points at.
- Composes with ADR 0036 (lifecycle / aging) cleanly: per-life-stage
  schedule swap is a JSON pattern (`$extends` + life_stage tag),
  not engine logic.
- Phase-transition signal (`schedule_phase_changed`) gives juice +
  audio designers a hook for ambient cues at meaningful moments
  (dawn rise, dinner gathering, night-fall).

### Constrains

- Schedule is data, not behavior tree. Authors who want truly
  context-dependent decisions ("if hungry AND scheduled to work,
  override and eat") write that as a separate `tick`-rule that
  overwrites `current_verb`. Schedule sets the BASELINE; rules
  override on conditions. This is fine — keeps the schedule
  primitive minimal and the override path explicit.
- Schedule slots are STEP functions of time, not continuous. No
  smooth blending between "work" and "eat." This is a feature for
  the Phase 1 contemplative tone; if Phase 4 needs continuous
  schedules, that's a future ADR.
- One schedule per entity. NPCs cannot follow two schedules
  simultaneously. Workaround: nested verbs (`current_verb=work`,
  another rule sets `current_subverb=chop` based on tendency).
  Acceptable.

### Changes elsewhere

- `world.gd`: add `schedule_director` member; instantiate +
  add as child of self in `_ready()` after `actor_manager` (mirrors
  LightingDirector / PartyDirector wiring).
- `phase_scheduler.gd`: minor — accept director's batched effect
  list at start of `decide` phase. Same surface PartyDirector uses
  for its leashing writes (no schema change, just a documented
  ordering invariant).
- Entity defs gain optional `schedule` field. Backward-compatible:
  existing demos (which don't ship one) see no change.
- New EngineError code: `SCHEDULE_BIND_INVALID` for malformed
  `binds_to` paths; `SCHEDULE_NO_SLOTS` for empty slots arrays.

### Doesn't enable

- Goal-oriented action planning — that's GOAP territory; not in scope.
- Multi-step plans — that's the deferred Plan primitive (§Tier 3
  Deferred primitives in 30_framework_primitives.md).
- Utility-based AI scoring — every-verb-scored-each-tick. Schedules
  are step functions; utility AI is continuous. Future ADR if
  Phase 4 emergent civilians need it.

## Alternatives considered

### A) Hand-coded tick rules per NPC (status quo)

Each NPC author writes 6+ tick rules: "if hour ≥ 6 and < 7, set
verb=wake"; "if hour ≥ 7 and < 12, set verb=work"; etc. Plus
target-resolution rules: "if verb=work, target nearest field."

Pros: zero engine work; pure JSON; familiar pattern.
Cons: bloats content (~150 rules for Phase 1, ~9000 for Phase 4);
every new NPC duplicates the pattern; no reuse; tendency-drift
fallback would need its own bespoke rule per slot per NPC. Does
NOT scale.

Rejected because Aldenmere's whole thesis (emergent civilization
sim) requires content authoring scale that hand-coded scheduling
fundamentally cannot support.

### B) Behavior trees (BTs)

Add a `behavior_tree` block to entity defs; engine includes a BT
runner with selectors / sequences / decorators / conditions.

Pros: industry-standard for NPC AI; expressive; well-understood.
Cons: BTs are a deep new primitive (~500 LoC engine, weeks of
testing). Yume's tag-based queries already give us 80% of BT
expressiveness — selectors are tag-filtered queries; conditions are
state-field comparisons; sequences are rule-ordering hints. The
remaining 20% (multi-tick state machines) is what ADR 0036 (Plan
primitive, deferred to Tier 3) is for. Schedule + tendency drift
covers the daily-routine case at <200 LoC. Cheaper, more focused,
ships now.

Rejected as premature complexity. Revisit at Phase 4 if civilian AI
requires it; if it does, that's a focused ADR with concrete
motivation.

### C) Utility AI

Every tick, every NPC scores all available verbs by a formula
(`score(work) = hunger_lt_50 * 0.3 + at_field_proximity * 0.5 + ...`)
and picks the highest. No schedules; behavior emerges from the
utility weights.

Pros: powerful, fully emergent, robust to interruptions.
Cons: harder to debug + author than schedules. Hard to predict
"what will Marken do at noon?" without simulating. Phase 1's
contemplative aesthetic specifically wants PREDICTABLE rhythm —
players SHOULD know that everyone gathers at the fire at 18:00.
That is the Submission aesthetic. Utility AI undermines it by making
NPC behavior reactive instead of cyclical.

Rejected for Phase 1. May come later as a SEPARATE ADR for emergent
civilian AI (Phase 4 city-state dwellers); does NOT replace the
schedule primitive — they layer.

### D) GOAP / planner

Full goal-oriented action planning: NPC has a goal stack; planner
chains preconditions → actions → effects to reach goals.

Pros: maximally expressive; emergent at all time horizons.
Cons: way too heavy for daily-routine NPCs. Planning costs scale
poorly (NP-hard in worst case). Reserve for Phase 4 famous-figure
storyline NPCs IF needed.

Rejected for Phase 1-3. Phase 4 may revisit via the deferred Plan
primitive (30_framework_primitives.md §"Plan (deferred)") with
concrete motivation.

## Test plan

Land in `godot/scripts/engine/tests/test_runner.gd` as `test_schedule()`.
At minimum, the assertions below — concrete enough that the
implementer (next session) knows what to build:

1. **`test_schedule.simple_slot_match`** — entity with schedule
   `[{6,12,work,field}, {12,18,rest,home}]`, world_clock.current_hour
   = 9.0, after one director.tick(): entity.state.current_verb ==
   "work" AND entity.state.current_target points at the nearest
   `field`-tagged entity.

2. **`test_schedule.slot_transition_signal`** — same entity. Set
   current_hour = 11.5, tick. Set current_hour = 12.5, tick. Assert
   exactly one `schedule_phase_changed` signal queued with payload
   `{entity, old_verb: "work", new_verb: "rest", slot_index: 1}`.

3. **`test_schedule.wraparound_slot`** — schedule
   `[{21,6,sleep,home}]`. current_hour = 23.0 → verb=sleep.
   current_hour = 3.0 → verb=sleep. current_hour = 12.0 → verb =
   default_verb (no match).

4. **`test_schedule.fallback_verb_by_tendency`** — slot
   `{7,12,work,field, fallback_verb_by_tendency: ["gather", "hunt"]}`.
   Entity tendency `{gather: 5, hunt: 2}` → resolved verb = "gather".
   Set tendency `{gather: 1, hunt: 8}` → resolved verb = "hunt".
   Set tendency `{gather: 0, hunt: 0}` → resolved verb = slot's
   declared `"work"`.

5. **`test_schedule.no_slot_match_uses_default`** — schedule
   `[{6,12,work,field}]` with `default_verb: "idle"`. current_hour
   = 14.0 → verb = "idle", current_target = "".

6. **`test_schedule.boundary_inclusive_start_exclusive_end`** —
   slot `{6,12,work,field}` at current_hour = 6.0 → matches
   (verb=work). At current_hour = 12.0 → does NOT match. (Tests
   `[start, end)` half-open intervals.)

7. **`test_schedule.mid_day_spawn`** — spawn an entity at
   current_hour = 14.0 (middle of "rest" slot). After one director
   tick, the entity's verb is correctly resolved (no requirement
   that the entity has been alive since slot start). Verifies no
   "first transition" gap.

8. **`test_schedule.location_tag_resolution_uses_relation_when_present`**
   — entity has `home_at` relation to specific shelter A; multiple
   `home`-tagged shelters in the level. After tick during sleep
   slot, current_target points at A (relation hint wins over
   nearest). Without the relation, the nearest-tagged is picked.

9. **`test_schedule.lod_outside_radius_skips_resolution`** —
   schedule with `lod: {anchor: active_actor, enter_radius: 10,
   leave_radius: 12, outside_mode: tick_slowed:0.1}`. Entity at
   distance 50 from active_actor. Run 10 director ticks. Assert
   resolution fired ≤2 times (slow rate), not 10.

10. **`test_schedule.entity_without_schedule_unaffected`** —
    entity def has no schedule block. Run director.tick(). Entity
    state unchanged; no current_verb / current_target written.
    Director's per-entity loop skips it cleanly.

11. **`test_schedule.malformed_binds_to_raises_error`** —
    `binds_to: "garbage_path.no_field"` → at load, EngineError
    raised with code SCHEDULE_BIND_INVALID. Director continues
    operating on other entities; no crash.

Plus one scenario test in `data/demo_<aldenmere_phase1>/tests.json`:

12. **`scenario_phase1_daily_cycle`** — boot the Phase 1 demo, run
    until current_day == 2 (≈3500 ticks at 0.5s tick + 1-min day).
    Assert: every named villager visited each of their schedule's
    location_tags at least once; `schedule_phase_changed` signal
    fired ≥ 6 times per villager (one per slot transition); no
    villager stuck on `current_verb = "idle"` for > 1 hour.

Total: **11 unit + 1 scenario = 12 test assertions**.

## Implementation sketch

Pseudo-Godot for `scripts/engine/schedule_director.gd`. Target
~150-180 LoC.

```gdscript
extends Node
class_name ScheduleDirector

# Same base pattern as LightingDirector + PartyDirector — sibling
# of GameShell + ScreenFlow + ActorManager under World.

var _world: Node = null
# Per-entity cached state: entity_id → {
#   bind_tag, bind_field, slots, default_verb, emit_on_transition,
#   wraps_at, lod_cfg, last_slot_index, last_resolved_target_for_slot
# }
var _cache: Dictionary = {}
# LOD hysteresis (mirror phase_scheduler.gd._lod_state pattern):
# _lod_state[entity_id] = {inside: bool, last_fired_tick: int}
var _lod_state: Dictionary = {}

func _ready() -> void:
    _world = get_parent()  # World
    if _world == null or not _world.has_method("_build_env"):
        push_error("ScheduleDirector must be a child of a World node")

func _on_entity_spawned(entity_id: String) -> void:
    # Walk the entity's def, cache schedule block if present.
    # Parse binds_to into bind_tag + bind_field once.
    # No-op for entities without schedule.
    pass

func _on_entity_despawned(entity_id: String) -> void:
    _cache.erase(entity_id)
    _lod_state.erase(entity_id)

# Called from PhaseScheduler at start of decide phase, OR on a
# fixed sub-tick interval if outside_mode == tick_slowed.
func tick(env: Dictionary) -> void:
    var current_tick: int = env.get("tick_count", 0)
    for entity_id in _cache.keys():
        var schedule_cache: Dictionary = _cache[entity_id]
        # LOD gate (per ADR 0017 hysteresis pattern)
        if not _lod_should_fire(entity_id, schedule_cache, env, current_tick):
            continue
        # 1. Read time source
        var time_value := _resolve_bound_time(schedule_cache, env)
        if time_value == null:
            continue   # bind broken; reported once at load
        # 2. Find active slot (first match wins)
        var slot_index := _pick_active_slot(time_value, schedule_cache)
        # 3. Pick verb (with tendency-drift fallback)
        var slot: Dictionary = schedule_cache.slots[slot_index] if slot_index >= 0 else {}
        var verb := _pick_verb(slot, schedule_cache, entity_id, env)
        var location_tag := str(slot.get("location_tag", ""))
        # 4. Resolve target if slot transitioned (cache target per slot)
        var target_id := schedule_cache.last_resolved_target_for_slot.get(slot_index, "")
        if slot_index != schedule_cache.last_slot_index:
            target_id = _resolve_target(entity_id, location_tag, env)
            schedule_cache.last_resolved_target_for_slot[slot_index] = target_id
        # 5. Queue effects via env (same pattern as PartyDirector)
        # state_set current_verb
        env.scheduler.queue_effect({
            "type": "state_set", "target": entity_id,
            "field": "current_verb", "value": verb
        })
        # state_set current_target
        env.scheduler.queue_effect({
            "type": "state_set", "target": entity_id,
            "field": "current_target", "value": target_id
        })
        # 6. Emit phase-change signal on transition
        if slot_index != schedule_cache.last_slot_index and \
           bool(schedule_cache.get("emit_on_transition", true)):
            env.scheduler.queue_effect({
                "type": "emit",
                "signal": "schedule_phase_changed",
                "payload": {
                    "entity": entity_id,
                    "old_verb": _verb_at_slot(schedule_cache, schedule_cache.last_slot_index),
                    "new_verb": verb,
                    "slot_index": slot_index
                }
            })
        schedule_cache.last_slot_index = slot_index

func _pick_active_slot(time: float, schedule_cache: Dictionary) -> int:
    var wraps_at: float = float(schedule_cache.get("wraps_at", 24.0))
    for i in range(schedule_cache.slots.size()):
        var s: Dictionary = schedule_cache.slots[i]
        var start: float = float(s.get("start", 0.0))
        var end: float = float(s.get("end", wraps_at))
        # Wrap-around case
        if start > end:
            if time >= start or time < end:
                return i
        else:
            if time >= start and time < end:
                return i
    return -1   # no match → default_verb

func _pick_verb(slot: Dictionary, cache: Dictionary, eid: String, env: Dictionary) -> String:
    var fallback_array = slot.get("fallback_verb_by_tendency", null)
    if fallback_array is Array and not fallback_array.is_empty():
        var ent: Entity = env.entities[eid]
        var tendency: Dictionary = ent.state.get("tendency", {})
        if not tendency.is_empty():
            var best_verb := ""
            var best_score: float = -INF
            for verb in fallback_array:
                var score: float = float(tendency.get(verb, 0))
                if score > best_score:
                    best_score = score
                    best_verb = verb
            if best_score > 0:
                return best_verb
    return str(slot.get("verb", cache.get("default_verb", "idle")))

func _resolve_target(eid: String, location_tag: String, env: Dictionary) -> String:
    if location_tag == "": return ""
    # 1. Prefer a relation hint (home_at, works_at, tends) IF present
    #    and target has the location_tag.
    # 2. Otherwise, query for nearest entity tagged location_tag.
    # See query.gd; reuse existing helpers.
    return ""  # detail in implementation pass
```

Wiring at `world.gd::_ready()`:

```gdscript
schedule_director = ScheduleDirector.new()
schedule_director.name = "ScheduleDirector"
add_child(schedule_director)
# After actor_manager, before flush_effects().
```

`phase_scheduler.gd` changes: at the START of decide phase (before
tick-rule iteration), call:

```gdscript
if env.world.schedule_director != null:
    env.world.schedule_director.tick(env)
```

Effects queued by the director go through the same commit-buffer
+ `effect_apply.gd` paths as ordinary rule effects. No new effect
types.

## Performance budget

Director resolution cost per entity per tick:
- Read bound time (1 dict lookup): ~0.0001 ms
- Walk slots until match (≤ ~10 slots): ~0.001 ms
- Verb pick (≤ ~5 fallback verbs): ~0.0005 ms
- Target resolve on slot transition (one nearest-tag query): ~0.05 ms
  (rare — once per slot change, ~6 times/day per entity)
- Queue 2-3 effects: ~0.001 ms

**Phase 1 (8-12 NPCs × every tick × ~2 Hz)**: ~0.05 ms/tick total.
Trivial.

**Phase 4 (200-500 NPCs)**:
- Without LOD: 500 × 0.001 ms ≈ 0.5 ms/tick steady-state. ~5% of a
  10ms frame budget. Acceptable but tight.
- With LOD (off-camera at 0.5 Hz; assume 80% off-camera): 100 × 0.001
  ms + 400 × 0.0001 ms ≈ 0.14 ms/tick. <2% frame budget. Comfortable.

Slot-transition target-resolution (the ~0.05 ms case) fires at
~6 times/NPC/day. At 200 NPCs over a day = 1200 query calls
across ~3500 ticks ≈ 0.34 query/tick on average. Negligible.

Memory: per-entity cache ~200 bytes × 500 NPCs = 100 KB.
Negligible.

**Verdict**: schedule resolution is not a perf concern at any planned
phase. Spatial-LOD interaction (ADR 0017) is the primary defense for
Phase 4 throughput; even without it the steady-state cost is <1 ms.

## Migration / backwards-compat

Schedule is **OPTIONAL** on entity defs. Existing demos (sokoban,
chess, doomarena3d, merchant, etc.) ship no schedule blocks. The
director sees no schedules → its tick is a no-op.

No engine-level migration. No data-format change to existing demos.
No breaking changes to the rule schema.

When ADR 0030 (occupation/class) lands, switching class CAN swap an
entity's effective schedule (e.g. via `state_set` writing a
`current_class` field that an `$extends`-aware lib pattern resolves
to a different schedule). Schedule primitive doesn't need to change
for that — composition handles it.

## Validation

`tools/validate_schedule.py` (new, ~80 LoC). Runs at sync time and
in CI. Checks:

- Every entity def with a `schedule` block has at least one slot.
- Every slot has `start` (number), `end` (number), `verb` (string).
- `fallback_verb_by_tendency` (if present) is a string array.
- `binds_to` (if present) parses as `<tag>.<field>` or
  `world.<field>`.
- Slot intervals don't overlap (warning, not error — runtime uses
  first-match).
- Slot intervals collectively cover [0, wraps_at) OR `default_verb`
  is set (warning if neither).
- `location_tag`s referenced by slots match at least one entity's
  `tags` in the same level (warning — flags typos).

Missing-schedule is fine (the director skips). Invalid schedule
fails sync (CI gate) per `.claude/rules/data-demo.md` § static
validators.

## References

- `docs/games/aldenmere/engine_roadmap.md` — sketch of ADR 0029
  this proposal lifts and concretizes.
- `docs/games/aldenmere/phase1_GDD.md` — uses this primitive for
  8-12 NPCs' daily routines (§"Cascade 1 — Daily Rhythm",
  §"Cascade 3 — Tendency Drift", §"For systems-designer", §"Risks
  honestly named" item 6 names this ADR as the BLOCKING
  dependency).
- `docs/games/aldenmere/world.md` §"Engine work needed" — names
  ADR 0029 as the second of eight Phase 1+ ADRs (after ADR 0035
  animation).
- ADR 0017 (spatial-LOD scheduling) — schedule director composes
  with LOD: off-camera NPCs resolve at lower rate.
- ADR 0027 (cross-game JSON reuse) — `@lib.schedules.X` +
  `$extends` pattern for shared schedule templates.
- ADR 0019 (rule-plugin macros) — macro vocabulary may grow to
  include schedule-emit-juice macros (e.g. `dawn_rise_juice`)
  per game.
- ADR 0030 (occupation/class, future) — class-tagged schedules
  per occupation; no engine change needed (composition).
- ADR 0036 (lifecycle / aging, future) — life-stage-tagged
  schedules (children, adults, elders); composition only.
- ADR 0021 (Yume = JSON layer over Godot) — schedule_director is
  an interpreter that reads JSON and produces existing-primitive
  effects.
- New engine module: `godot/scripts/engine/schedule_director.gd`
  (~150-180 LoC).
- Tests: `godot/scripts/engine/tests/test_runner.gd` adds
  `test_schedule()` with 11 assertions; Aldenmere Phase 1 demo
  adds `scenario_phase1_daily_cycle` (1 scenario).
- Validator: `tools/validate_schedule.py` (~80 LoC, runs at
  sync per existing pattern).
- Format: follows ADR README's standard format; precedent
  includes ADR 0024 (NPC pathfinding director), ADR 0025
  (lighting director), ADR 0026 (party director) — all
  director-pattern ADRs.

## Risks honestly named

1. **1-tick lag between schedule resolution and AI consumption**.
   Schedule writes via commit buffer; AI rules in same tick read
   pre-commit snapshot. Symptom: at slot transition, AI rules
   continue old verb for ONE tick. At tick_seconds=0.5, that's
   500ms. Mitigated by tight tick rate; if visible at user
   playtest, ScheduleDirector can be promoted to write directly
   to entity.state pre-decide (engineering tradeoff documented).

2. **Tendency-drift dominance**. If `fallback_verb_by_tendency` is
   set, the slot's primary `verb` is sometimes overridden. Risk:
   over 30 days, every NPC drifts toward extreme specialization,
   robbing schedules of their function. Mitigated by capping
   tendency stat at 10.0 (per Phase 1 GDD §"For systems-designer"
   item 4) + content discipline (most slots don't use the
   fallback feature).

3. **Schedule + manual override conflict**. Content rule sets
   `current_verb = "flee"` (wolf attack); next tick, schedule
   overwrites back to scheduled verb. Two solutions, both
   content-side: (a) make override rules write a different
   field (`emergency_verb`) and have AI consumer rules check
   it first; (b) add a `schedule_paused` boolean state field
   that gates ScheduleDirector. Engine-side: NOT solved by ADR
   0029 — that's Phase 2 priority-management work, possibly
   another ADR.

4. **LOD-off-camera schedule drift**. NPC at LOD-slowed rate
   may resolve a stale slot for ~2 seconds at slot-boundary
   crossings. Visible if player walks AT a slot boundary
   moment. Mitigation: LOD enter triggers an immediate
   resolve (one extra fire on enter — already in
   PhaseScheduler's hysteresis pattern; ScheduleDirector
   mirrors it).

5. **Schedule + multi-actor**. ADR 0016 supports multiple
   active actors. A schedule on an entity that's the active
   actor still resolves; player sees their controlled NPC
   "do" the scheduled verb. Not a bug per se — the schedule is
   a baseline, not a constraint. But may surprise. Mitigation:
   document in skill SKILL.md; recommend clearing schedule
   for player-class entities.
