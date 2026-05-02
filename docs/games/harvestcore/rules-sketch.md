# HarvestCore — Rule Sketches

_Date: 2026-05-02_
_Designer: yume-systems-designer_
_GDD: docs/games/harvestcore/GDD.md_

---

## Primitive sufficiency check

Can the seven existing primitives express HarvestCore's mechanics?

- [x] **Entity** — covers world_clock, farm_ledger, terrain tiles, crop stage defs,
      animal defs, NPC defs, player, structures, produce items. Collapsed crop
      model (8 defs: crop_seed / crop_young / crop_mature + 5 produce item defs)
      fits within entity budget using `crop_type` property + `season_mask`.
- [x] **Tag** — `planted_crop`, `harvestable`, `animal`, `livestock`, `npc`, `actor`,
      `ground`, `tillable`, `plantable`, `produce`, `item`, `carryable`,
      `sell_point`, `meta`, `world_state`, `economy` — all pure membership.
- [x] **Rule** — each of the 26 GDD rules maps cleanly to a single Rule struct.
- [x] **Trigger** — tick (clock/growth/decay), signal (day_start, time_work, etc.),
      input (tool verbs), contact (harvest contact, pickup, animal feed). All
      trigger types in the manifest are exercised.
- [x] **Effect** — state_set, state_add, state_clamp, transform, spawn, remove,
      relate, unrelate, velocity_set, emit — all present in api-manifest.json.
      No semantic gaps.
- [x] **Query** — tags_all/tags_none/state operators cover every filter needed.
      `relations` clause covers `held_by player` inventory queries. `radius`
      covers contact zones.
- [x] **Relation** — `held_by` (produce → player), `on_tile` (crop → soil tile).
      Optional `located_at` (NPC → zone) deferred to content-designer.

**Verdict: all seven primitives are sufficient. No ADR required.**

One design note flagged below (deposit_produce multi-entity aggregate) — it
uses a known formula pattern (`self.held_by.sum(sell_value)`) from
§7 of `docs/30_framework_primitives.md`, so it is not a new primitive.

---

## Entity model (resolved from open questions)

Per the resolved open questions passed with this task:

- **Q1 (entity budget):** Collapsed to 3 shared crop-stage defs
  (`crop_seed`, `crop_young`, `crop_mature`) + `crop_type` property +
  `season_mask` bitmask property. 5 produce item defs. Total crop-related
  defs: 8.
- **Q2 (tile model):** 64 explicit `dirt_tile` / `tilled_soil` entities (8×8
  grid). Total entity instance target: ~150.
- **Q3 (sell):** immediate `state_add` on `farm_ledger.gold` on deposit.
- **Q4 (seed select):** `selected_seed` state on player + `seed_cycle` input
  action increments it.
- **Q5 (NPC arrive):** tick rule + distance check formula — no waypoint
  entities.
- **Q6 (out-of-season):** auto-transform to `dead_crop` entity on season
  change.
- **Q7 (animal hunger):** no death, just stops producing.
- **Q8 (day/night tint):** renderer layer, not modelled in rules.

---

## Rule sketches

### WORLD / CLOCK RULES

---

### Mechanic: dawn_advance_day

**Rule id:** `dawn_advance_day`
**Trigger:** tick, interval = `ticks_per_day` (read from world_clock properties)
**Query:** tags_all `["world_state"]`
**Effect (list):**
1. state_add `world.day += 1`
2. state_set `world.season = "floor(self.state.day / 28) mod 4"` (formula)
3. state_set `world.time_of_day = 0.0` (reset to dawn)
4. emit signal `"day_start"` (triggers the dawn chain rules)

**Why:** Single rule governs the macro cycle. Emitting `day_start` as a
signal lets all dawn-reset rules listen on one event, decoupling them from
the tick interval value. Changing the day length in content requires only
one property edit on `world_clock`.

**Ordering:** must fire `before: dawn_draw_weather`, `before: dawn_reset_watered`,
`before: dawn_reset_fed`. All three are signal-triggered so they naturally
follow in the decide phase of the next tick — but if same-tick ordering
matters, `emit` in react plus signal in next tick's decide phase handles it.

---

### Mechanic: dawn_draw_weather

**Rule id:** `dawn_draw_weather`
**Trigger:** signal `"day_start"`
**Query:** tags_all `["world_state"]`
**Effect:** state_set `world.weather` to formula:

```
// Pseudo-formula. season 0=Spring: 40% rainy (1), 10% stormy (2), else sunny (0)
// season 3=Winter: 20% rainy, rare stormy.
// Content-designer writes the full randf() branching expression.
randf()-weighted ternary chain over self.state.season
```

Concrete shape (content-designer to fill exact thresholds):
```
(randf() < stormy_threshold[season]) ? 2 :
  (randf() < rainy_threshold[season]) ? 1 : 0
```
Because per-season thresholds are static values baked as formula literals,
no new primitive is needed.

**Why:** Isolates weather randomness to a single rule fired once per dawn.
All downstream rules read `world.weather` as a committed state value.

---

### Mechanic: dawn_reset_watered

**Rule id:** `dawn_reset_watered`
**Trigger:** signal `"day_start"`
**Query:** tags_all `["planted_crop"]`, tags_none `[]`
  — with state filter: only fire on entities where `world.weather != 1`
  (i.e., not rainy). This is expressed as a query-level formula or as a
  require clause checking the world_clock entity's weather state.

**Preferred approach:** two-rule split to stay within query expressiveness:
- `dawn_reset_watered_dry` — fires when weather != rainy → state_set `watered = 0`
- `dawn_keep_watered_rain` — fires when weather == rainy → state_set `watered = 1`
  (rain auto-waters all planted crops)

**Effect for `dawn_reset_watered_dry`:** state_set target `self` field `watered` value `0`
**Effect for `dawn_keep_watered_rain`:** state_set target `self` field `watered` value `1`

**Query for both:** tags_all `["planted_crop"]`
**Require (for the dry variant):** `world_clock` entity with `state.weather_ne 1`
**Require (for the rain variant):** `world_clock` entity with `state.weather_eq 1`

**Why:** Splitting avoids a conditional inside the effect body. Both rules
share the same trigger; engine runs both; only one will match its require
clause each dawn.

---

### Mechanic: dawn_reset_fed

**Rule id:** `dawn_reset_fed`
**Trigger:** signal `"day_start"`
**Query:** tags_all `["animal", "livestock"]`
**Effect:** state_set target `self` field `fed_today` value `0`

**Why:** Clears the daily fed flag so each new day requires explicit feeding.
Pairs with `animal_produce_tick` which gates on `fed_today == 1`.

---

### CROP GROWTH RULES

---

### Mechanic: crop_rain_watered

**Rule id:** `crop_rain_watered`
**Trigger:** tick, interval = 1
**Query:** tags_all `["planted_crop"]`
**Require:** world_clock entity with `state.weather_eq 1` (rainy)
**Effect:** state_set target `self` field `watered` value `1`

**Why:** Provides continuous rainy-day watering without requiring dawn
signal timing. Fires every tick while it is raining. Combined with
`dawn_keep_watered_rain`, this is belt-and-suspenders — content-designer
may consolidate to one.

**Ordering:** before `crop_grow_watered`

---

### Mechanic: crop_grow_watered

**Rule id:** `crop_grow_watered`
**Trigger:** tick, interval = N (content-designer sets; roughly 1 tick per
  in-game hour — see Balance Values section)
**Query:** tags_all `["planted_crop"]`, state `watered_eq 1`
**Require:** world_clock entity (for season formula evaluation)
**Effect:** state_add target `self` field `growth`
  amount formula: `(((1 << world.season) & self.properties.season_mask) > 0) ? self.properties.grow_rate : 0`

The season bitmask check: `(1 << world.season)` produces 1/2/4/8 for
seasons 0–3. Bitwise AND with `season_mask` is non-zero only if the current
season is valid. If out-of-season, growth amount is 0 (effectively a no-op
growth tick). This keeps the rule count low; content-designer may prefer
the explicit `crop_out_of_season_halt` transform approach (see below).

**Why:** Core growth engine. Only fires on watered crops. Season gating is
formula-level so a single rule handles all crop types via `crop_type` and
`season_mask` properties.

---

### Mechanic: crop_out_of_season_halt (season-turn transform)

**Rule id:** `crop_out_of_season_halt`
**Trigger:** signal `"day_start"` (fires at season boundary; content-designer
  may use a separate `season_changed` signal emitted by `dawn_advance_day`
  when `world.day mod 28 == 0`)
**Query:** tags_all `["planted_crop"]`
  state formula filter: season_mask does NOT include current season
  — expressed as query `state.season_valid_eq 0` where `season_valid`
  is a derived state updated by a companion rule, OR handled inline via
  require clause against world_clock.

**Preferred shape:** require clause on world_clock + formula in query.
Because query `state` clauses support formulas as values in the engine,
the filter can be:
```
"state": {"season_valid_eq": 0}
```
where `season_valid` is set by a cheap companion tick rule each dawn. See
`crop_update_season_valid` below.

**Effect:** transform target `self` to `"dead_crop"`

**Why:** Provides the hard seasonal deadline. Resolves open question Q6.
`dead_crop` is a visual entity with no grow rules attached — dead crops
simply persist as wasted tile space until the player hoes them away.

---

### Mechanic: crop_update_season_valid (helper)

**Rule id:** `crop_update_season_valid`
**Trigger:** signal `"day_start"`
**Query:** tags_all `["planted_crop"]`
**Effect:** state_set target `self` field `season_valid`
  value formula: `((1 << world.season) & self.properties.season_mask) > 0 ? 1 : 0`

**Why:** Caches the season-validity check as a plain state field so other
rules can query `season_valid_eq 1` or `season_valid_eq 0` without
re-evaluating the bitmask formula in query operators. Cheap; runs once per
dawn.

**Ordering:** `before: crop_out_of_season_halt`, `before: crop_grow_watered`

---

### Mechanic: crop_seed_to_young

**Rule id:** `crop_seed_to_young`
**Trigger:** tick, interval = N (same interval as `crop_grow_watered`)
**Query:** tags_all `["planted_crop", "crop_stage_seed"]`, state `growth_gte 100`
**Effect:** transform target `self` to `"crop_young"`, preserving state
  (growth carries over, `crop_type` property carries over via the shared def)

**Why:** Stage transitions are threshold-triggered transforms. The `transform`
effect preserves position and merges state so `growth` and `crop_type`
survive the entity replacement. Content-designer must ensure `crop_young`
def has matching state field names.

---

### Mechanic: crop_young_to_mature

**Rule id:** `crop_young_to_mature`
**Trigger:** tick, interval = N
**Query:** tags_all `["planted_crop", "crop_stage_young"]`, state `growth_gte 200`
**Effect:** transform target `self` to `"crop_mature"`
  — `crop_mature` gains tag `harvestable` in its def

**Why:** Completes the growth chain. The `harvestable` tag appearing on
transform is what gates the scythe harvest rule.

---

### Mechanic: storm_damages_crop

**Rule id:** `storm_damages_crop`
**Trigger:** tick, interval = N (roughly once every few in-game minutes;
  see Balance Values)
**Query:** tags_all `["harvestable"]`, limit = 1, order_by = `"random"`
  — only storms: require world_clock `state.weather_eq 2`
**Chance:** 0.15
**Effect:** remove target `self`

**Why:** Introduces tail-risk to the rain gift. Chance 0.15 means roughly
1 mature crop lost per storm per interval. `limit = 1` ensures at most one
crop dies per tick, making storms stressful but not catastrophic.

**Note:** `order_by: "random"` is not in the current `api-manifest.json`
query clauses (which lists `order_by` as a clause but does not enumerate
valid values). Content-designer should verify whether the engine supports
`"random"` as an `order_by` value, or work around it by using `chance`
alone and dropping the limit (so multiple crops could die per tick). See
Open Questions.

---

### PLAYER TOOL RULES

---

### Mechanic: tool_switch

**Rule id:** `tool_switch`
**Trigger:** input `"seed_cycle"` (resolved Q4 — same action cycles both
  seeds and optionally tool; content-designer may split into `tool_cycle`
  and `seed_cycle`)
**Query:** tags_all `["player"]`
**Effect:** state_add target `self` field `held_tool` amount `1`
  + state_set clamped via formula: `self.state.held_tool mod 3`
  — or two effects: state_add +1 then state_clamp to ensure wrap-around.

**Preferred (two effects):**
1. state_add field `held_tool` amount `1`
2. state_set field `held_tool` value `"self.state.held_tool mod 3"`

**Why:** Cycles the tool index 0→1→2→0. Modular arithmetic via formula
formula on state_set achieves wrap-around without a new primitive.

---

### Mechanic: seed_cycle (separate from tool_switch)

**Rule id:** `seed_cycle`
**Trigger:** input `"seed_cycle"`
**Query:** tags_all `["player"]`
**Effect:** state_add field `selected_seed` amount `1`
  + state_set field `selected_seed` value `"self.state.selected_seed mod NUM_SEED_TYPES"`

Where `NUM_SEED_TYPES` is a property on the player entity (content-designer
sets it to match actual seed count).

**Why:** Resolves Q4. Player cycles through available seed types. Content-
designer should confirm whether tool_cycle and seed_cycle are the same
input action or separate.

---

### Mechanic: hoe_till

**Rule id:** `hoe_till`
**Trigger:** input `"use_tool"` (contact with nearby tillable ground)
**Query:** tags_all `["ground", "tillable"]`, radius = contact radius (e.g. 20px)
**Require:** player entity with `state.held_tool_eq 1` (hoe index)
**Effect:** transform target `self` to `"tilled_soil"`
  — tilled_soil def has `plantable` tag, `watered` and `occupied` state
    fields initialized to 0.

**Why:** Input trigger fires on use_tool; require clause gates on the
player's tool state. Only tillable (unhoed) ground is in the query.
Tile entity identity is preserved via `transform` rather than spawn+remove,
so relations to the tile position survive.

---

### Mechanic: watering_can_water

**Rule id:** `watering_can_water`
**Trigger:** input `"use_tool"`
**Query:** tags_any `["plantable", "planted_crop"]`, radius = contact radius
**Require:** player entity with `state.held_tool_eq 0` (watering_can index)
**Effect:** state_set target `self` field `watered` value `1`

**Why:** Waters either an empty tilled tile or an already-planted crop.
`tags_any` allows both tile types in one rule.

---

### Mechanic: scythe_harvest

**Rule id:** `scythe_harvest`
**Trigger:** input `"use_tool"`
**Query:** tags_all `["harvestable"]`, radius = contact radius
**Require:** player entity with `state.held_tool_eq 2` (scythe index)
**Effect (list):**
1. spawn `"produce_item"` (def id driven by `self.properties.crop_type`)
   at player position, with `state: {produce_type: self.properties.crop_type}`
   and immediate relate `held_by` → player
2. remove target `self` (the harvested crop)
3. unrelate `on_tile` from `self` → its tile; state_set tile `occupied = 0`

**Design note:** The spawn effect's template must be parameterizable by
`crop_type`. Two options:
- a) Spawn a generic `produce_item` def with `crop_type` as a state field —
  visual varies via `crop_type` lookup. This is the cleaner approach.
- b) Five separate harvest rules, one per crop type, each spawning the
  type-specific produce def.

Option (a) is preferred; content-designer decides. If the engine's `spawn`
effect supports `"template": "self.properties.crop_type"` as a formula
resolving to a def id, it works cleanly. If `template` must be a literal
string, option (b) is needed. **Flag for content-designer to verify.**

**Why:** Completes the harvest chain. Removing the crop + clearing occupied
frees the tile for replanting.

---

### Mechanic: plant_seed

**Rule id:** `plant_seed`
**Trigger:** input `"plant"`
**Query:** tags_all `["ground", "plantable"]`, state `occupied_eq 0`,
  radius = contact radius, limit = 1, order_by = `"distance_asc"`
**Require:** player entity (carries `selected_seed` state)
**Effect (list):**
1. spawn `"crop_seed"` (shared base def) at tile position,
   with properties `{crop_type: player.state.selected_seed}`,
   state `{growth: 0, watered: 0, season_valid: 0}`
2. relate `on_tile`: new crop entity → matched soil tile
3. state_set on the tile: `occupied = 1`

**Design note:** Same formula-template question as `scythe_harvest`. If
spawn template cannot be formula-driven, content-designer spawns a generic
`crop_seed` def with `crop_type` property baked at spawn time. Crop growth
rules read `self.properties.crop_type` to select visuals and produce type.

**Why:** `order_by: distance_asc` + `limit: 1` ensures the nearest unoccupied
tile is targeted. `occupied_eq 0` prevents double-planting.

---

### Mechanic: feed_animal

**Rule id:** `feed_animal`
**Trigger:** input `"use_tool"` (or a separate `"feed"` action — content-designer decides)
**Query:** tags_all `["animal", "livestock"]`, radius = contact radius
**Require:** player entity with `state.held_tool_eq 0` (watering_can can
  share the feed action, OR content-designer adds a dedicated `held_tool`
  index 3 for feed bucket; simplest: a separate input action `"feed"`)
**Effect (list):**
1. state_set target `self` field `hunger` value `0`
2. state_set target `self` field `fed_today` value `1`

**Note:** GDD says "feed action + contact". Simplest rule does not require
a specific tool — any press of the feed action near an animal triggers it.
Content-designer to decide if a separate feed tool index is needed.

**Why:** Feeding resets hunger and stamps the daily flag. Animal produce
rules gate on `fed_today == 1`.

---

### Mechanic: deposit_produce

**Rule id:** `deposit_produce`
**Trigger:** input `"deposit"`
**Query:** tags_all `["sell_point"]`, radius = contact radius
**Require:** (implicit — player is the actor context)
**Effect (list):**
1. state_add on `farm_ledger` entity: field `gold`
   amount formula: `self.held_by.sum(sell_value)`
   — where `self` resolves to the player entity (context role), and
     `held_by.sum(sell_value)` traverses all produce currently in player's inventory
     (via the `held_by` relation) and sums their `sell_value` properties.
2. unrelate all `held_by` from player (removes all produce from inventory)
3. remove each unrelated produce entity (or leave as visual chest fill —
   content-designer decides)

**Design note on the aggregate:** `self.held_by.sum(sell_value)` uses the
relation traversal aggregate documented in `docs/30_framework_primitives.md`
§7. This is a known formula pattern, not a new primitive.

**Design note on targeting farm_ledger:** The `state_add` effect needs
to target the `farm_ledger` singleton by its well-known instance id (e.g.
`"farm_ledger_1"`). Using a literal target id in the effect is valid per
the primitives doc §"Effect target resolution".

**Why:** Immediate gold award on deposit (Q3). Single rule handles all
produce types simultaneously via the aggregate traversal.

---

### ANIMAL PRODUCTION RULES

---

### Mechanic: animal_hunger_decay

**Rule id:** `animal_hunger_decay`
**Trigger:** signal `"day_start"`
**Query:** tags_all `["animal", "livestock"]`
**Effect (list):**
1. state_add target `self` field `hunger` amount `1`
2. state_clamp target `self` field `hunger` min `0` max `100`

**Why:** Hunger decays once per in-game day. Clamped at 100 (Q7 — no death,
just stops producing). The `state_clamp` effect keeps hunger within bounds
without formula complexity.

---

### Mechanic: animal_produce_tick

**Rule id:** `animal_produce_tick`
**Trigger:** tick, interval = 1
**Query:** tags_all `["animal", "livestock"]`, state `fed_today_eq 1`
**Effect:** state_add target `self` field `produce_timer` amount `-1`

**Why:** Timer counts down only on fed animals. Unfed animals (Q7) stall —
produce_timer stops decrementing, production pauses without punishment.

---

### Mechanic: animal_produce_output

**Rule id:** `animal_produce_output`
**Trigger:** tick, interval = 1
**Query:** tags_all `["animal", "livestock"]`, state `produce_timer_lte 0`
**Effect (list):**
1. spawn produce item def = `self.properties.produce_type` at position near
   `self` (formula: `self.state.position + [offset_x, offset_y]`)
2. state_set target `self` field `produce_timer`
   value formula: `self.properties.produce_interval * ticks_per_day + floor(randf() * ticks_per_day)`
   (base interval ± 1 day jitter, resolves Q GDD "±1 day variance")

**Design note:** Same spawn-template formula question as `scythe_harvest`.
If `spawn.template` cannot be formula-driven, content-designer writes three
rules (one per animal type), each spawning the specific produce def.

**Why:** Timer hits zero → spawn output → reset timer with jitter. Animal
output rate is the reward signal for consistent feeding.

---

### NPC SCHEDULE RULES

---

### Mechanic: npc_schedule_emit (clock emits schedule signals)

**Rule id:** `npc_schedule_emit`
**Trigger:** tick, interval = 1
**Query:** tags_all `["world_state"]`
**Effect:** three conditional emits based on time_of_day thresholds:
- if `time_of_day` crosses 0.3 → emit `"time_work"`
- if `time_of_day` crosses 0.6 → emit `"time_social"`
- if `time_of_day` crosses 0.9 → emit `"time_home"`

**Implementation note:** Three separate tick rules with require clauses
checking `time_of_day` ranges are cleaner than one rule with conditional
effects (which would need formula-branching inside an emit). Recommended
split:

- `npc_schedule_emit_work`: trigger tick, require `time_of_day_gte 0.3` AND
  `time_of_day_lt 0.35` (narrow window to fire once per day-period)
- `npc_schedule_emit_social`: trigger tick, require `time_of_day_gte 0.6`
  AND `time_of_day_lt 0.65`
- `npc_schedule_emit_home`: trigger tick, require `time_of_day_gte 0.9`
  AND `time_of_day_lt 0.95`

The narrow window (0.05 of the day cycle) ensures these fire at most once
per phase transition per day. Content-designer must tune window width to
match `ticks_per_day` so exactly one tick falls in each window.

**Why:** Decouples NPC movement rules from the clock implementation.
Schedule-signal rules are clean signal-triggered rules with no clock logic
inside.

---

### Mechanic: npc_go_to_work

**Rule id:** `npc_go_to_work`
**Trigger:** signal `"time_work"`
**Query:** tags_all `["npc", "actor"]`
**Effect:** velocity_set target `self` toward formula:
  `direction from self.state.position to self.properties.work_position`

**Velocity formula:** content-designer writes a vector normalization formula
using `self.properties.work_position - self.state.position`, normalized,
times `npc_speed` property. Full formula:
```
// direction vector component (content-designer writes both x and y):
x: "(self.properties.work_position[0] - self.state.position[0]) / distance * npc_speed"
y: "(self.properties.work_position[1] - self.state.position[1]) / distance * npc_speed"
```
where `distance` = `sqrt(pow(...x..., 2) + pow(...y..., 2))`. Verify
formula syntax with content-designer — vector math in the formula language
may need per-component rules.

---

### Mechanic: npc_go_social

**Rule id:** `npc_go_social`
**Trigger:** signal `"time_social"`
**Query:** tags_all `["npc", "actor"]`
**Effect:** velocity_set toward `self.properties.social_position`
  (same velocity formula shape as `npc_go_to_work`)

---

### Mechanic: npc_go_home

**Rule id:** `npc_go_home`
**Trigger:** signal `"time_home"`
**Query:** tags_all `["npc", "actor"]`
**Effect:** velocity_set toward `self.properties.home_position`

---

### Mechanic: npc_arrive_stop (Q5 resolved: tick-based distance check)

**Rule id:** `npc_arrive_stop`
**Trigger:** tick, interval = 1
**Query:** tags_all `["npc", "actor"]`
**Effect:** state_set / velocity_set using conditional formula.
  Two options:

Option A (single effect, formula gate):
- state_set `velocity` to `[0, 0]` IF distance to current waypoint < arrive_radius.
- Requires the formula to select the current waypoint from `schedule_phase`.
  Formula would be:
  ```
  target_pos = (self.state.schedule_phase == 0) ? self.properties.home_position :
               (self.state.schedule_phase == 1) ? self.properties.work_position :
               self.properties.social_position
  distance = sqrt(pow(target_pos[0]-self.state.position[0], 2) +
                  pow(target_pos[1]-self.state.position[1], 2))
  ```
  Then `velocity_set x: 0, y: 0` with a `chance` formula equivalent. This
  pushes complex logic into the formula layer.

Option B (three rules, one per phase):
- `npc_arrive_work`: query `schedule_phase_eq 1` + radius check formula,
  velocity_set [0,0]
- `npc_arrive_social`: query `schedule_phase_eq 2` + radius check
- `npc_arrive_home`: query `schedule_phase_eq 0` + radius check

**Recommendation: Option B (three rules).** Keeps individual rules simple
and query-driven. Content-designer picks arrive radius per waypoint type.
Distance is expressed as the tick rule's query `radius` clause centered on
the waypoint position — but waypoints are not entities (Q5 resolved: no
waypoint entities). Therefore the distance check must be formula-based in
the require clause or as a conditional effect.

**Final recommendation:** Use a single `npc_arrive_stop` tick rule with a
require clause binding world_clock, and a formula-conditional `velocity_set`
that only fires when the NPC is within `arrive_radius` of its current phase
destination. Content-designer implements by setting velocity to
`lerp(current_vel, 0, large_factor)` or checking distance in the query's
state clause. **Flag for content-designer to verify formula vector
support.**

---

### RELATION / INVENTORY RULES

---

### Mechanic: produce_pickup

**Rule id:** `produce_pickup`
**Trigger:** contact
**Query:**
  a: tags_all `["player"]`
  b: tags_all `["produce", "item", "carryable"]`, tags_none `[]`
  radius = pickup radius (e.g. 20px)
**Effect:** relate `held_by` from `b` to `a`

**Why:** Standard pickup pattern. Once related, the produce item's position
follows the player (renderer reads `held_by` relation to offset position).
Query `tags_none` can exclude already-held items if the engine indexes
relations in queries — use `tags_none: ["in_inventory"]` if content-designer
adds that tag on relate, or use a relation filter `tags_none` equivalent.

**Ordering:** `after: deposit_produce` (so freshly deposited produce is not
immediately re-picked-up; in practice these fire in different tick phases).

---

### Mechanic: produce_drop_on_deposit

This mechanic is handled inside `deposit_produce` (see above) as effect
steps 2–3. No separate rule needed. The `unrelate` effect removes all
`held_by player` produce in one rule.

---

## Cascade design

### Cascade 1: daily crop growth loop

```
tick (interval=ticks_per_day)
  → dawn_advance_day fires
    → state: world.day++, world.season updated
    → emit "day_start"

signal "day_start"
  → dawn_draw_weather: world.weather = random(season)
  → dawn_reset_watered_dry (if !rainy): crop.watered = 0
  → dawn_keep_watered_rain (if rainy): crop.watered = 1
  → dawn_reset_fed: animal.fed_today = 0
  → crop_update_season_valid: crop.season_valid = (season in mask ? 1 : 0)
  → crop_out_of_season_halt: out-of-season crops → dead_crop

tick (interval=N, every growth tick)
  → crop_rain_watered (if rainy): watered = 1 on all planted_crop
  → crop_grow_watered (if watered): growth += grow_rate
    → crop_seed_to_young (growth >= 100): transform to crop_young
    → crop_young_to_mature (growth >= 200): transform to crop_mature
      → crop now has tag "harvestable"
```

**Equilibrium:** Mature crops accumulate until player harvests. After
harvest, tile becomes unoccupied → available for replanting. No auto-
removal of mature crops (except storms).

**Feedback:** Negative regulation via watering requirement (player must
tend daily or rain covers it). Positive reward: successful watering →
growth → harvestable crop → gold on deposit.

---

### Cascade 2: sell loop (convergent growth)

```
player presses "deposit" near sell_chest
  → deposit_produce fires
    → gold += sum of held_by produce's sell_value
    → unrelate + remove all held produce
    → farm_ledger.gold++ (visible score)
```

**Equilibrium:** Gold is unbounded (no spend mechanic in scope). Growth
is the dominant loop — gold is the visible score. No equilibrium point;
design intent is accumulation satisfaction.

---

### Cascade 3: animal care loop (negative, convergent)

```
signal "day_start"
  → animal_hunger_decay: hunger++ (clamped 0–100)
  → dawn_reset_fed: fed_today = 0

player presses "feed" near animal
  → feed_animal: hunger = 0, fed_today = 1

tick (interval=1)
  → animal_produce_tick (fed_today==1): produce_timer--
    → animal_produce_output (timer <= 0): spawn produce + reset timer with jitter

Consequence if unfed:
  → fed_today stays 0 → produce_timer stalls → no produce spawns
  → hunger accumulates each dawn but no punishing cascade (Q7)
```

**Feedback:** Negative regulation (hunger builds if player neglects →
production pauses). Converges to stable production when player feeds
consistently.

---

### Cascade 4: NPC ambient schedule

```
tick (narrow window near time_of_day=0.3)
  → npc_schedule_emit_work: emit "time_work"
signal "time_work"
  → npc_go_to_work: velocity_set toward work_position

tick (interval=1)
  → npc_arrive_stop (near waypoint): velocity_set [0,0]

tick (narrow window near time_of_day=0.6)
  → emit "time_social" → npc_go_social → npc_arrive_stop

tick (narrow window near time_of_day=0.9)
  → emit "time_home" → npc_go_home → npc_arrive_stop
```

**Equilibrium:** NPCs oscillate between three positions per day. No
simulation consequence — purely ambient sensation (GDD aesthetics: Sensation).

---

### Cascade 5: storm damage tail-risk

```
tick (interval=N, while weather==stormy)
  → storm_damages_crop (chance 0.15, limit 1): remove one harvestable crop
```

**Feedback:** Positive pressure (storm → crop loss → less gold). Bounded
by limit=1 per tick interval. Terminates when weather changes or all
mature crops are removed.

---

## Balance values

Initial guesses for content-designer to tune; qa-tester validates.

| Parameter | Initial guess | Rationale |
|---|---|---|
| `ticks_per_day` | 3600 | 60fps × 60s = 1 real minute per in-game day; 10-min day = 36000. Start slow for feel. |
| Crop seed-to-young threshold | 100 growth units | Arbitrary; `grow_rate` × ticks determines real time. |
| Crop young-to-mature threshold | 200 growth units | Double the seed threshold. |
| `grow_rate` for fast crops (radish) | 5 per growth tick | ~7 in-game days to mature at 1 tick/growth-tick |
| `grow_rate` for slow crops (pumpkin) | 2 per growth tick | ~14–20 in-game days |
| `crop_grow_watered` tick interval | ticks_per_day / 28 | Roughly once per in-game "hour" |
| `produce_interval` chicken | 3 (days) | Egg every 3 days |
| `produce_interval` cow | 2 (days) | Milk every 2 days |
| `produce_interval` sheep | 5 (days) | Wool every 5 days |
| Animal `produce_timer` jitter | ± 1 day in ticks | `floor(randf() * ticks_per_day)` |
| Contact / pickup radius | 20–30 px (2D) | Adjacent-tile feel at 64px tile size |
| Storm damage tick interval | ticks_per_day / 4 | ~4 storm checks per in-game day |
| Storm damage chance | 0.15 per check | ~1 crop lost per stormy day if 4 mature crops |
| NPC schedule window width | 0.05 × ticks_per_day | ~3 min at 10-min day; ensures single-fire |
| NPC arrive radius | 24–32 px | Roughly half a tile |
| Spring rainy probability | 0.40 | GDD spec |
| Spring stormy probability | 0.10 | GDD spec |
| Winter rainy probability | 0.20 | GDD spec |

---

## ADRs needed

**None.** All 26 GDD rules map to the existing 7 primitives without
engine changes. The two design notes below are content-designer decisions,
not engine gaps.

### Design note 1 (not an ADR): spawn template formula

Several rules need to spawn an entity whose def id is determined by a state
value (`crop_type`, `produce_type`). Whether `spawn.template` accepts a
formula string is a content-designer question about current engine behavior,
not a primitive gap. If it does not, the content-designer writes N parallel
rules (one per type) rather than one generic rule. This is a verbosity
tradeoff, not a missing primitive.

### Design note 2 (not an ADR): order_by random in query

`storm_damages_crop` ideally selects a random mature crop. The manifest
lists `order_by` as a valid query clause but does not enumerate valid
values. Content-designer should test whether `"order_by": "random"` is
supported. If not, using `chance: 0.15` without `limit` achieves similar
behavior (each mature crop independently has 15% chance per tick of being
removed during a storm).

---

## Open questions for content-designer

1. **NPC velocity formula (vector math).** The formula language supports
   per-component arithmetic. Confirm whether `velocity_set` accepts `x` and
   `y` as separate formula strings (current RPG demo shape) or as a vector
   formula. If per-component, the direction normalization needs two rules
   (one for x, one for y) or a combined `velocity_set` with both `x` and
   `y` formula fields. Reference: demo_rpg `move_north` rule uses literal
   integers — needs verification for formula-driven values.

2. **spawn.template as formula.** If `spawn.template` must be a literal
   string (not a formula), write 3 animal-produce rules and 5 crop-type
   harvest rules instead of the single generic rules sketched here. The
   engine behavior here determines whether 8 rules or ~18 rules are needed
   in this section.

3. **deposit_produce multi-produce.** The `unrelate` effect pattern for
   removing ALL `held_by player` produce at once — confirm whether `unrelate`
   supports a wildcard `from: "all matching query"` or whether a separate
   `remove` pass is needed per produce item. If the engine unrelates one
   edge at a time, the rule may need to fire N times (once per produce item)
   or the content-designer batches it as a `remove` on all
   `{tags_all: ["produce"], relations: {held_by: "player"}}` matches.

4. **NPC schedule window tuning.** The "narrow window" approach for schedule
   signal emission requires `ticks_per_day` to be large enough that 0.05 of
   a day contains at least one tick. At `ticks_per_day = 3600`, a 0.05
   window = 180 ticks. Fine. At `ticks_per_day = 100`, window = 5 ticks —
   still fine. Content-designer should document the chosen `ticks_per_day`
   and derive window widths from it.

5. **dead_crop entity.** The `dead_crop` def needs to exist in entities.json
   with no growth rules and a distinct visual (greyed-out/withered). The
   player should be able to hoe it away — add a `hoe_remove_dead` rule
   (input `"use_tool"` + `held_tool_eq 1` + contact with `dead_crop` →
   transform back to `dirt_tile`). This rule was not in the GDD's rule
   inventory; flag for game-designer to confirm.

6. **soil occupied flag on harvest.** When `scythe_harvest` removes a crop,
   it must also unrelate `on_tile` and set the tile's `occupied = 0`. Confirm
   that the `unrelate` effect can target the crop's `on_tile` relation (i.e.,
   source is the crop entity about to be removed). If remove fires before
   unrelate in the effect list, the tile reference may be lost. Ordering of
   effects within the list matters — unrelate and state_set on tile must come
   BEFORE the remove effect.

7. **world.weather binding.** Rules checking `world.weather` assume the
   `world_clock` entity's state fields are exposed via the `world.*` binding.
   Confirm this is the engine convention (it appears to be, given `world.tick`,
   `world.time_of_day`, etc. in the GDD). If `world.*` bindings are read from
   a specific entity tagged `world_state`, document the convention explicitly
   in entities.json comments.

8. **Hoe on tilled_soil.** The GDD describes `dirt_tile` → `tilled_soil` via
   hoe. Should hoeing an already-tilled empty tile do nothing (no rule fires
   because `tilled_soil` lacks the `tillable` tag), or should it revert to
   `dirt_tile`? Current sketch: silent no-op. Flag for game-designer.
