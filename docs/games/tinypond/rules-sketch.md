# TinyPond — rule sketches

_Date: 2026-05-02_
_Designer: yume-systems-designer_
_GDD: docs/games/tinypond/GDD.md_

## Primitive sufficiency check

- [x] Entity — 4 defs (pond_clock, water_plant_seed, water_plant_mature, fish)
- [x] Tag — `clock`, `plant`, `seed`, `mature`, `edible`, `fish`, `hungry`
- [x] Rule — 10 rules across 4 trigger types
- [x] Trigger — `tick`, `contact` (no signals/input/spawn/despawn/relation needed)
- [x] Effect — `state_set`, `state_add`, `state_clamp`, `transform`, `spawn`, `remove`, `velocity_set` (7 of 14)
- [x] Query — `tags_all`, `state` filters with `_eq`/`_gt`/`_gte`/`_lt`, `radius`
- [x] Relation — **NOT USED**. Game is small enough for spatial proximity alone.

**No ADR required.** All mechanics expressible in existing 7 primitives.

## Rule sketches

### 1. clock_advance_time

**Trigger:** `tick` interval 1
**Query:** `tags_all: ["clock"]`
**Effect:** `state_add { field: time_of_day, amount: 0.01 }`, then
  `state_clamp` with wrap (use modulo formula via state_set)

**Why:** Drives day/night cycle. With interval 1 and amount 0.01, full
cycle = 100 ticks. At tick_seconds=0.5, that's ~50s real time per pond-day.

**Note for content-designer:** `state_clamp` doesn't wrap; need a
`state_set { value: "self.state.time_of_day - 1 if self.state.time_of_day >= 1 else self.state.time_of_day" }` pattern, OR
just use `time_of_day = (world.tick * 0.01) % 1` set fresh each tick.
Recommend the latter — simpler.

### 2. clock_update_sunlight

**Trigger:** `tick` interval 1
**Query:** `tags_all: ["clock"]`
**Effect:** `state_set { field: sunlight, value: <sin formula> }`

**Sin formula:** `max(0, sin(self.state.time_of_day * 6.28))` — produces
0 → 1 → 0 → -1→ 0 over a full cycle, but `max(0, ...)` clamps the night
half to 0. Result: smooth ramp up to 1.0 at midday, down to 0 at midnight.

**Why:** Sunlight drives plant growth. Smooth curve gives the meditative
"breathing" feel from GDD aesthetic.

### 3. plant_seed_grows_in_sun

**Trigger:** `tick` interval 1
**Query:** `tags_all: ["plant", "seed"]`
**Effect:** `state_add { field: growth, amount: <formula> }`

**Formula:** `5 if world.sunlight > 0.3 else 0` — binary growth gate.
(Or smoother: `5 * world.sunlight` for continuous.)

**Why:** Plants only advance when there's enough sunlight. Slow at dawn/dusk,
fast at midday, frozen at night. Drives the visible day/night progression.

**Note:** `world.sunlight` reads from world_state dict. Content-designer
must set this in world.json initial OR have rule 2 also write to
world.sunlight (env.world dict) — content-designer to decide.

### 4. plant_seed_to_mature

**Trigger:** `tick` interval 2
**Query:** `tags_all: ["plant", "seed"]`, `state: { growth_gte: 100 }`
**Effect:** `transform { to: water_plant_mature }`

**Why:** Seed → mature transition. Mature plants are eligible for fish
eating (have `edible` tag from def).

### 5. plant_seeding

**Trigger:** `tick` interval 30, `chance: 0.3`
**Query:** `tags_all: ["plant", "mature"]`
**Effect:** `spawn { template: water_plant_seed, position: <near self> }`

**Position:** `[self.state.position.x + (randf() - 0.5) * 60, self.state.position.y + (randf() - 0.5) * 60]` — within ±30 px of parent.

**Why:** Slow plant reproduction. Long interval (30 ticks ≈ 15s) and 0.3
chance → roughly one seed per mature plant per minute. Recovery rate
slower than fish eat rate, creating the GDD's intended "dependency" dynamic.

**Risk:** No spatial overlap check — seeds can stack. For verification
this is fine; if it becomes a problem, add radius query for empty space.

### 6. fish_random_movement

**Trigger:** `tick` interval 4, `chance: 0.4`
**Query:** `tags_all: ["fish"]`
**Effect:** `velocity_set { x: <random>, y: <random> }`

**Random formula:** x = `(randf() - 0.5) * 60`, y = `(randf() - 0.5) * 60`
— random walk in pixel-space. Interval 4 + chance 0.4 = direction change
~once per 10 ticks (5 sec). Between changes, velocity carries them.

**Why:** Fish drift. Not goal-seeking — random walk is enough for the
"watch the pond" aesthetic.

### 7. fish_position_clamp

**Trigger:** `tick` interval 1
**Query:** `tags_all: ["fish"]`
**Effect:** Apply position constraint via state_set or velocity reversal.

**Approach:** Two state_set effects with formulas:
- `state_set { field: position, value: [clamp(self.state.position.x, -200, 200), clamp(self.state.position.y, -200, 200)] }`

**Why:** Keep fish in pond bounds. Without this, fish drift off screen
forever.

**Note for content-designer:** `state_set` on `position` may need to
write a Vector2 literal, not array. Check entity.set_state semantics.
Alternative: skip this rule and trust visual is OK if fish wander a bit.
Recommend: skip for verification, add later if needed.

### 8. fish_eats_mature_plant

**Trigger:** `contact`, `radius: 12`
**Query:** `a: { tags_all: ["fish"] }, b: { tags_all: ["plant", "mature"] }`
**Effect:** [
  `remove { target: b }`,
  `state_add { target: a, field: hunger, amount: -30 }`,
  `state_clamp { target: a, field: hunger, min: 0, max: 100 }`
]

**Why:** Core eating loop. Contact with mature plant → plant gone, fish
hunger drops. Clamp prevents negative hunger.

### 9. fish_hunger_rises

**Trigger:** `tick` interval 5
**Query:** `tags_all: ["fish"]`
**Effect:** `state_add { field: hunger, amount: 1 }`, then
  `state_clamp { field: hunger, min: 0, max: 100 }`

**Why:** Fish slowly get hungry over time. Pace: +1 per 5 ticks = 20
hunger per pond-day if no food. Hits 100 (max hunger) in 5 days if
plants fail entirely.

### 10. fish_hungry_tag

**Trigger:** `tick` interval 10
**Query:** `tags_all: ["fish"]`, `state: { hunger_gt: 70 }`
**Effect:** `tag_add { tag: "hungry" }`

**Why:** Tag-based visual cue — content-designer / asset-designer can
make hungry fish look different (slower visible movement, color shift).
Not strictly needed for sim, but cheap to add.

**Note:** No `tag_remove` rule for when hunger drops. For verification,
this is fine — once hungry, the fish stays tagged until refreshed via
explicit logic. If problematic, add an `else_remove` rule with
`hunger_lt: 50`.

## Cascade design

The pond runs three interleaved loops:

1. **Day/night oscillation** (rules 1, 2): perpetual, drives all else
2. **Plant lifecycle** (rules 3, 4, 5): seed → grows in sun → mature →
   occasionally seeds nearby. Slow positive feedback (more mature →
   more seeds) bounded by space + interval.
3. **Fish loop** (rules 6, 7, 8, 9, 10): wander → eat on contact →
   hunger drops. Hunger always rising; only contact resets it.

**Equilibrium check:** if seed-spawn rate > eat rate, plants overrun
(low fish food shortage but visual gets cluttered). If eat rate > seed
rate, plants vanish, fish hunger climbs to 100, pond becomes empty. The
GDD asks for the latter to be a *visible* but *non-fatal* end state —
fish stay alive (no death rule).

**Sweet spot** (balance work for content-designer): 3 fish at hunger 0
eat at ~1 plant/30s collectively. 8 mature plants seeding at 0.3 chance
per 30 ticks → ~1 new seed every 50s collectively. Eat slightly faster
than regrow → slow decline. Tune to taste.

## Balance values

- `tick_seconds`: 0.5 (default) — pond runs at moderate pace
- `time_of_day` advance: 0.01 per tick → 100 ticks per pond-day = 50s
- Plant grow_rate: 5 per tick → seed→mature in ~20 sunny ticks
- Plant seed chance: 0.3 per 30-tick interval
- Fish hunger: +1 per 5 ticks; -30 per eaten plant; clamped [0, 100]
- Fish movement: ±60 velocity, change every ~10 ticks
- Contact radius (fish-plant): 12 px

## ADRs needed

**None.** All 10 rules expressible in existing primitives. Confirmed
against `docs/engine-reference/api-manifest.json`:
- Triggers used (`tick`, `contact`) — both in manifest's 8 triggers
- Effects used (`state_set`, `state_add`, `state_clamp`, `transform`,
  `spawn`, `remove`, `velocity_set`, `tag_add`) — all in manifest's 14
- Query clauses used (`tags_all`, `state`, `radius`) — all in manifest's 9
- Operators (`_gt`, `_gte`, `_lt`) — all in manifest's 8

## Open questions for content-designer

1. **time_of_day wrap:** GDScript `state_clamp` doesn't wrap. Recommend
   using `state_set` with formula `(world.tick * 0.01) % 1` instead of
   incremental update. Cleaner, no clamp needed.

2. **world.sunlight as world_state OR pond_clock.sunlight:** the
   sin-formula rule writes to one or the other. The plant grow rule
   reads it. Decide which (recommend pond_clock.sunlight for
   single-source-of-truth + add a tick rule that ALSO mirrors to
   world dict if other rules need it).

3. **Position-clamp rule:** drop it for verification. If fish wander
   off-screen during qa, add later.

4. **Visual aesthetics:** simple shapes — fish as ovals, plants as
   small circles (seed) and larger leafy shapes (mature). Asset-designer
   to decide colors.

## Summary (5 lines)

1. **All 10 GDD rules map to existing primitives** — zero ADRs needed; uses 7 effects, 2 triggers, 3 query clauses, 4 operator suffixes.
2. **Cascade design**: 3 interleaved loops (day/night oscillation, plant lifecycle with positive feedback bounded by interval, fish hunger negative feedback bounded by eating contact).
3. **All formulas use Python-style ternary** `a if cond else b` per the harvestcore lesson — example: `5 if world.sunlight > 0.3 else 0`.
4. **Open questions for content-designer**: time_of_day modulo wrap (recommend formula), world.sunlight vs pond_clock.sunlight (recommend pond_clock), drop position-clamp rule for v1, visual choices deferred to asset-designer.
5. **Output written**: `/home/kamwoh/yume/docs/games/tinypond/rules-sketch.md`. Ready for content-designer hand-off.
