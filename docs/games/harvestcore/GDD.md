# HarvestCore

_Date: 2026-05-02_
_Designer: yume-game-designer_

---

## One-line pitch

Run a silent farm through four seasons — till, plant, tend animals, watch
weather and time reshape your harvest — no words, just the rhythm of the land.

---

## Aesthetics target

Primary (MDA §A, from `docs/32_mda_for_yume.md`):

| Category | Why this game |
|---|---|
| **Submission** | The dominant register. Player falls into a daily routine — morning rounds, watering, animal feeding — that feels productive without demanding vigilance. "Stardew without the words" is explicitly a calm, meditative loop. |
| **Discovery** | Seasonal crop rotation means the valid move-set changes every ~28 in-game days. Rainy-day farming feels different from drought management. Each year the player re-discovers what to plant when. |
| **Sensation** | The visual payoff of crops cycling seed → sprout → mature, animals producing outputs, the chest slowly filling — satisfying state progressions made visible. Weather overlays (overcast filter, storm vignette) amplify this. |

Expressly NOT: Challenge (no enemies, no time penalty for sub-optimal play),
Fellowship (single-player), Narrative (no cutscenes, no dialogue).

---

## Dynamics

### Core loop rhythm

A day cycle (~10–15 real minutes if desired, tunable via `world.ticks_per_day`)
drives the micro-loop: wake at dawn → water crops / feed animals → watch
growth → harvest mature crops → deposit in sell-chest → end of day.

The macro-loop: 28-day seasons cycle through Spring → Summer → Autumn →
Winter. Seasonal crop availability forces the player to plan ahead (plant
radishes in Spring, pumpkins in Autumn). Winter is deliberately sparse — few
crops, focus on animals and gold-saving.

### Key feedback loops

**Rain shortcut (positive, bounded).** On rainy days, all watered_flag resets
are skipped — rain counts as watering. The crop growth rate ticks normally
but the player's manual labor cost is zero. On stormy days, there is a small
chance a mature crop is destroyed (negative pressure). Net: rain is a gift
with a tail risk.

**Animal care loop (negative, convergent).** Animals have `hunger` that
decays each in-game day. Fed animals produce outputs on cycle (egg, milk,
wool). Unfed animals stop producing but do not die (no punishing cascade).
Output rate is the reward signal; neglect simply pauses it.

**Sell-chest accumulation (convergent growth).** Dropping produce in the chest
increments a `gold` counter on a `farm_ledger` entity. Gold has no spend
mechanic in this GDD scope (no shop, no upgrades). It is the visible score
— a satisfaction gauge, not a resource gate.

**Seasonal crop turnover (phase transition).** At season boundary (world.day
mod 28 == 0), in-season crops remain valid; out-of-season planted seeds stop
growing entirely (growth rate = 0). This creates a hard "deadline" dynamic:
harvest before the season turns or lose the investment.

### Randomness entry points

- Weather draw each day: probability table weighted by season
  (Spring = 40% rainy, 10% stormy; Winter = 20% snowy-equivalent, rare storm)
- Animal output: fixed cycle with `randf()` jitter (±1 day variance)
- Storm crop damage: chance ~0.15 per mature crop per stormy tick

### Typical play arc

- Day 1–3: hoe ground tiles, plant first seeds, feel the day length
- Day 5–8: first harvest of fast crop (radish ~7 days), first gold
- Day 14–20: animal output cycle produces eggs/milk/wool — second income stream
- Day 27–28: seasonal panic-harvest before turnover
- Year 2+: player has a mental model, begins optimising planting density

---

## Mechanics

All behavior expressed via Yume's 7 primitives. No new primitive required
(confirmed against `docs/30_framework_primitives.md` invariant #8).

### Player verbs

| Verb | Trigger type | What it does |
|---|---|---|
| Move | `input` (WASD) | velocity_set on player entity |
| Hoe | `input` (tool action) + contact with `dirt_tile` | transform `dirt_tile` → `tilled_soil` |
| Water | `input` (tool action) + contact with `tilled_soil` or `planted_crop` | state_set `watered = 1` |
| Plant seed | `input` (plant action) + contact with `tilled_soil` | spawn `crop_<type>_seed` at tile, relate `on_tile` |
| Harvest | `input` (scythe action) + contact with `crop_mature` | remove crop, spawn `produce_<type>` in player inventory (`held_by`) |
| Feed animal | `input` (feed action) + contact with animal | state_set `hunger = 0` |
| Deposit | `input` (deposit action) + contact with `sell_chest` | unrelate all `held_by player`, state_add `gold + produce_value` on `farm_ledger` |

Player carries a `held_tool` state (watering_can / hoe / scythe) that gates
which input rules fire. Tool switching is an `input` trigger that state_sets
`held_tool`.

### World clock

A `world_clock` entity carries:
- `world.tick` — global tick counter
- `world.time_of_day` — 0.0 (dawn) to 1.0 (dusk), derived from tick mod ticks_per_day
- `world.day` — integer day counter
- `world.season` — 0=Spring, 1=Summer, 2=Autumn, 3=Winter (day / 28 mod 4)
- `world.weather` — 0=sunny, 1=rainy, 2=stormy (drawn each morning)

Weather draw: a tick rule fires once per day (when time_of_day crosses dawn
threshold), state_sets `world.weather` using a formula with `randf()` weighted
by season.

### Tile system

Ground is a grid of `ground_tile` entities. States: `tilled` (0/1). Tilled
tiles accept seeds. Hoe tool transforms `dirt_tile` → `tilled_soil` entity
(or state_set `tilled = 1` on ground_tile — content-designer to decide).
`watered` flag (0/1) resets each dawn via tick rule; rain skips the reset
(or sets all planted crops' `watered` directly).

### Crop lifecycle

Each crop type has three stage entities: `<crop>_seed`, `<crop>_young`,
`<crop>_mature`. Growth uses `transform` effect at thresholds. Growth tick
rate is conditional on:
- `watered_eq: 1` (or weather == rainy)
- `world.season` matches crop's valid season(s) — expressed as
  `self.properties.season_mask` vs `world.season` in formula

### Animal production

Each animal entity has a `hunger` state (decays per day) and a `produce_timer`
state (counts down; when 0, emits produce + resets timer). Production only
fires when `hunger < hunger_threshold` (i.e., animal was fed today).

### NPC schedules

4 NPC entities carry `schedule_phase` state (0=home, 1=work, 2=social).
A tick rule fires on time_of_day thresholds and velocity_sets NPCs toward
their current phase's waypoint position. NPCs have no dialogue interaction
with player — they are ambient. Relation `located_at` can be used to track
which zone an NPC is in (optional, content-designer decides).

---

## Entity inventory

_Rough types and tag taxonomy. Do not write JSON yet — that is content-designer's job._

### World / meta entities

| Entity type | Tags | Key state fields | Notes |
|---|---|---|---|
| `world_clock` | `meta`, `world_state` | `time_of_day`, `day`, `season`, `weather`, `ticks_per_day` | Singleton. All other rules read `world.*` bindings off this. |
| `farm_ledger` | `meta`, `economy` | `gold` | Singleton. Gold counter. |

### Ground / terrain entities

| Entity type | Tags | Key state fields | Notes |
|---|---|---|---|
| `dirt_tile` | `ground`, `tillable` | `tilled` (0/1) | Grid tile. Hoe converts to tilled. |
| `tilled_soil` | `ground`, `tilled`, `plantable` | `watered` (0/1), `occupied` (0/1) | Post-hoe state. Could be same entity w/ transform or state_set. |

### Crop entities (5 types × 3 stages = 15 entity defs, but share tag structure)

| Crop | Season(s) | Stage entities | Tags |
|---|---|---|---|
| Radish | Spring | `radish_seed`, `radish_young`, `radish_mature` | `crop`, `plant`, `<stage>`, `season_spring` |
| Corn | Summer | `corn_seed`, `corn_young`, `corn_mature` | `crop`, `plant`, `<stage>`, `season_summer` |
| Pumpkin | Autumn | `pumpkin_seed`, `pumpkin_young`, `pumpkin_mature` | `crop`, `plant`, `<stage>`, `season_autumn` |
| Turnip | Autumn | `turnip_seed`, `turnip_young`, `turnip_mature` | `crop`, `plant`, `<stage>`, `season_autumn` |
| Potato | Spring + Autumn | `potato_seed`, `potato_young`, `potato_mature` | `crop`, `plant`, `<stage>`, `season_spring`, `season_autumn` |

All mature crop entities add tag `harvestable`. Produce items (`radish_produce`,
`corn_produce`, etc.) carry tags `produce`, `item`, `carryable` and a
`sell_value` property.

Stage-entities share key state fields:
- `growth` — 0→100 (seed→young), 100→200 (young→mature)
- `watered` — 0/1 (reset each dawn)

Properties (static):
- `grow_rate` — base growth per watered tick
- `season_mask` — integer bitmask (1=Spring, 2=Summer, 4=Autumn, 8=Winter)

### Animal entities

| Entity type | Tags | Key state fields | Properties |
|---|---|---|---|
| `chicken` | `animal`, `livestock` | `hunger` (0–100), `produce_timer`, `fed_today` (0/1) | `produce_type: "egg"`, `produce_interval: 3` (days) |
| `cow` | `animal`, `livestock` | `hunger` (0–100), `produce_timer`, `fed_today` (0/1) | `produce_type: "milk"`, `produce_interval: 2` |
| `sheep` | `animal`, `livestock` | `hunger` (0–100), `produce_timer`, `fed_today` (0/1) | `produce_type: "wool"`, `produce_interval: 5` |

Produce items: `egg`, `milk_bucket`, `wool_bundle` — tags `produce`, `item`, `carryable`, property `sell_value`.

### NPC entities (4 types)

| Entity type | Tags | Key state fields | Notes |
|---|---|---|---|
| `npc_farmer`, `npc_merchant`, `npc_fisherman`, `npc_elder` | `npc`, `actor` | `schedule_phase` (0/1/2), `velocity` | No dialogue. Waypoints baked as properties. |

### Player entity

| Entity type | Tags | Key state fields |
|---|---|---|
| `player` | `player`, `actor` | `velocity`, `held_tool` (0=watering_can, 1=hoe, 2=scythe) |

### Structure entities

| Entity type | Tags | Key state fields |
|---|---|---|
| `sell_chest` | `structure`, `container`, `sell_point` | (none mutable) |
| `barn` | `structure`, `building` | (none mutable) |
| `farmhouse` | `structure`, `building` | (none mutable) |

### Total entity def count

- World meta: 2
- Terrain: 2
- Crops (5 crops × 3 stages): 15
- Produce items (5 crops + 3 animals): 8
- Animals: 3
- NPCs: 4
- Player: 1
- Structures: 3

**Total: 38 entity defs.**

This exceeds the 12–18 def budget. Recommendation: content-designer collapses
crop stages via `transform` from a single `crop_base` template + season-specific
properties, reducing to ~18–20 defs. See Open Questions #1.

---

## Rule inventory

_Rule id + one-line description. Effect JSON is content-designer's job._

### World / clock rules

| Rule id | Trigger | One-line description |
|---|---|---|
| `dawn_advance_day` | tick, once per ticks_per_day | Increments `world.day`, advances `world.season` every 28 days |
| `dawn_draw_weather` | signal `day_start` | Draws new `world.weather` using `randf()` weighted by season |
| `dawn_reset_watered` | signal `day_start` | Resets `watered = 0` on all `planted_crop` where weather != rainy |
| `dawn_reset_fed` | signal `day_start` | Resets `fed_today = 0` on all `animal` |

### Crop growth rules

| Rule id | Trigger | One-line description |
|---|---|---|
| `crop_grow_watered` | tick, interval N | Adds `grow_rate` to `growth` for every `planted_crop` that is watered and in-season |
| `crop_rain_watered` | tick | Sets `watered = 1` on all `planted_crop` when `world.weather == rainy` |
| `crop_seed_to_young` | tick | Transforms `<crop>_seed` → `<crop>_young` when `growth >= 100` |
| `crop_young_to_mature` | tick | Transforms `<crop>_young` → `<crop>_mature` when `growth >= 200` |
| `crop_out_of_season_halt` | tick | Sets `grow_rate = 0` (or skips growth rule) for crops whose `season_mask` does not include `world.season` |
| `storm_damages_crop` | tick, interval N, chance 0.15 | Removes a random `harvestable` crop when `world.weather == stormy` |

### Player tool rules

| Rule id | Trigger | One-line description |
|---|---|---|
| `tool_switch` | input `tool_cycle` | Increments `held_tool` mod 3 on player |
| `hoe_till` | input `use_tool`, contact | Transforms contacted `dirt_tile` → `tilled_soil` when `held_tool == hoe` |
| `watering_can_water` | input `use_tool`, contact | Sets `watered = 1` on contacted `tilled_soil` or `planted_crop` when `held_tool == watering_can` |
| `scythe_harvest` | input `use_tool`, contact | Removes contacted `harvestable` crop, spawns corresponding `produce` item `held_by` player |
| `plant_seed` | input `plant` | Spawns selected `seed` entity `on_tile` of nearest `tilled_soil`, `occupied = 0` |
| `feed_animal` | input `use_tool`, contact | Sets `hunger = 0`, `fed_today = 1` on contacted `animal` |
| `deposit_produce` | input `deposit`, contact with `sell_chest` | Removes all `produce` `held_by` player, adds `sum of sell_value` to `farm_ledger.gold` |

### Animal production rules

| Rule id | Trigger | One-line description |
|---|---|---|
| `animal_hunger_decay` | tick (dawn signal) | Increments `hunger` on all `animal` by 1 per day |
| `animal_produce_tick` | tick | Decrements `produce_timer` on `fed_today == 1` animals |
| `animal_produce_output` | tick | Spawns produce item near animal and resets `produce_timer` when timer reaches 0 |

### NPC schedule rules

| Rule id | Trigger | One-line description |
|---|---|---|
| `npc_go_to_work` | signal `time_work` (emitted by clock at day 0.3) | velocity_sets all `npc` toward their `work_position` property |
| `npc_go_social` | signal `time_social` (emitted at day 0.6) | velocity_sets all `npc` toward their `social_position` property |
| `npc_go_home` | signal `time_home` (emitted at day 0.9) | velocity_sets all `npc` toward their `home_position` property |
| `npc_arrive_stop` | contact (npc near waypoint) | Sets `velocity = [0,0]` when npc is within arrive_radius of current waypoint |

### Relation rules (inventory management)

| Rule id | Trigger | One-line description |
|---|---|---|
| `produce_pickup` | contact, player near produce item on ground | Relates `held_by player` on `produce` item |
| `produce_drop_on_deposit` | signal `deposit` | Unrelates all `held_by player` produce, positions them in chest or removes them |

**Total rule count: ~26 rules.** Within the 20–30 budget.

---

## Relations used

| Relation type | From → To | Used for |
|---|---|---|
| `held_by` | produce/item → player | Player inventory |
| `on_tile` | crop_seed/young/mature → tilled_soil | Crop is planted on this tile (tile marks `occupied = 1`) |
| `located_at` | npc → zone entity | Optional NPC zone tracking (content-designer decides) |

---

## Honest scope

This game **is** in Yume's simulation-shaped game domain. Analogous to the
`demo_farming` and `demo_ecology_deep` reference demos. No new primitives
required.

### Explicitly out of scope (per user request + Yume non-goals)

- No dialogue trees (user-excluded; also requires a dialogue UI archetype
  not in Yume's current engine scope)
- No festivals or cutscenes (user-excluded)
- No combat or enemies (user-excluded)
- No shop or upgrade mechanic (not in the prose; can be added as a future GDD
  extension without engine changes)
- No continuous physics — NPCs pathfind via velocity toward waypoints, not
  A\* (A\* is flagged as a future engine service in `docs/30_framework_primitives.md`)
- No save/load in this GDD scope (engine supports serialization but content-
  designer would need to wire it for harvestcore specifically)

### Features that approach Yume's limits

- **Day/night visual filtering** — `world.time_of_day` drives a visual overlay
  (dark filter at night). This is renderer-layer, not engine. Content-designer
  should flag if the current `renderer_2d` supports a global color modulate
  driven by entity state.
- **Weather visual effects** (rain particles, storm vignette) — same concern.
  Asset-designer's scope.
- **NPC waypoint pathfinding** — velocity-toward-target works on open maps
  but NPCs will clip through buildings. If the map has tight corridors,
  this becomes a problem. Simple workaround: arrange building layout so
  NPC routes are unobstructed. A\* is not in scope.

---

## Open questions

_For content-designer and systems-designer to resolve before writing JSON._

**Q1. Entity def count reduction.**
38 entity defs exceed the 12–18 budget. Two options:
a) Collapse crop stages: one `crop` def per type with `grow_stage` state
   (0/1/2) and visual changing via `visual_stage` lookup — fewer defs, more
   complex transform logic.
b) Keep 3-stage model but treat `crop_seed/young/mature` as shared base defs
   with `crop_type` property, reducing to 3 crop-stage defs + 5 produce item
   defs = ~8 crop defs total.
Content-designer should pick before writing entities.json.

**Q2. Ground tile representation.**
Two models:
a) Explicit `dirt_tile` entities in a grid (one entity per tile) — works for
   small farms, may be expensive at 20×20 = 400 entities.
b) Player carries a "tilled_positions" list as state (no tile entities) and
   crops spawn at arbitrary position — simpler, less visually grid-locked.
Recommend (a) for visual clarity, but content-designer must choose farm size
that keeps entity count within engine perf range (~200–400 total entities).

**Q3. Sell mechanic detail.**
Does depositing produce immediately award gold (current GDD), or does a
"next day" delay simulate a merchant pickup? Current design says immediate.
If delayed is wanted, a `pending_gold` state + dawn rule is needed.

**Q4. Player seed selection.**
How does the player select which seed to plant? Options:
a) Player has a `selected_seed` state, and a `seed_select` input cycles through
   available seed types in inventory.
b) Proximity-based: nearest `seed` item `held_by player` is used.
Content-designer needs this resolved before writing the `plant_seed` rule.

**Q5. NPC arrival detection.**
NPC "arrive at waypoint" uses contact trigger between NPC and an invisible
`waypoint` entity, or a state-based distance check in a tick rule? Contact
is cleaner but requires invisible waypoint entities in the world. Tick-based
distance check avoids the extra entities. Content-designer to decide.

**Q6. Out-of-season crop handling.**
Three options:
a) Out-of-season seeds simply don't grow (growth rate formula returns 0) —
   they persist as wasted ground space.
b) Out-of-season seeds auto-transform to a `dead_crop` entity (visual feedback
   that you missed the season).
c) Out-of-season seeds are auto-removed at season change.
Option (b) gives the clearest player feedback.

**Q7. Animal hunger death.**
User prose implies animals don't die (no punishing cascades). Confirm: if
hunger reaches 100, animal simply stops producing until fed. No despawn rule.
If the user wants any consequence, flag before implementing.

**Q8. Visual renderer capability check.**
Before asset-designer finalises sprites: confirm whether the current
`renderer_2d` supports `world.time_of_day`-driven ambient color modulation
(day/night tint). If not, this is an engine extension request that needs
tech-director approval and an ADR.

---

## Hand-off checklist

- [ ] Open questions Q1 and Q2 resolved (entity budget, tile model)
- [ ] Open questions Q4 and Q5 resolved (seed select, NPC arrive)
- [ ] This GDD approved by user
- [ ] Passed to `yume-systems-designer` with path
      `/home/kamwoh/yume/docs/games/harvestcore/GDD.md`
- [ ] Content-designer reference: `godot/data/demo_farming/`
  as entity JSON shape reference

_Respects framework invariants #1–#8 from `docs/30_framework_primitives.md`:_
_all behavior is JSON-expressed; no semantic effect types; no entity-class_
_hierarchy; rules compose; queries are first-class; formulas throughout;_
_relations carry inventory and crop-placement; engine = primitives + interpreter._
