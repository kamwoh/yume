# TinyPond

_Date: 2026-05-02_
_Designer: yume-game-designer_

## One-line pitch

A tiny pond breathing in day-night rhythm — fish drift between sunlit
plants and starving stillness, in 5 entities and 10 rules.

## Aesthetics target

| Category | Why this game |
|---|---|
| **Sensation** | The point is the *visible* rhythm: plants growing, fish nibbling, day fading. No goals, no score — just watch the pond. |
| **Submission** | Meditative, no input needed. The pond runs itself; the player witnesses. |

Expressly NOT: Challenge, Narrative, Discovery (the system is small
enough to read in one viewing — no surprise after t=200), Fellowship.

## Dynamics intended

A single negative-feedback loop with a slow positive-feedback recovery:

- **Day**: sunlight high → plants gain growth → fish eat mature plants → fish hunger drops
- **Night**: sunlight zero → plants stop growing → fish keep eating from remaining mature → eventually only seeds remain → fish hunger rises slowly
- **Recovery**: existing plants occasionally seed nearby empty spots, regrowing the pond's biomass (slow, days-scale)

If fish eat too efficiently and plants seed too slowly, the pond
collapses to "all fish hungry, no plants" → tedious. If plants seed too
fast, plants overrun → also tedious. Balance values matter.

Typical first-interesting-event: ~30 ticks (one fish eats one mature plant).

Randomness enters via:
- Fish movement direction (random walk with brief pauses)
- Plant seeding chance (~5% per tick when mature)

## Mechanics sketch

### Entities (rough types)

- `pond_clock` — singleton meta entity tracking world.time_of_day, world.tick. Drives day/night.
- `water_plant_seed` — small, growing. Doesn't get eaten.
- `water_plant_mature` — full-size, can be eaten by fish, can seed nearby empty spots.
- `fish` — moves randomly, has hunger state. Eats plants on contact.

5 entity defs total (including a non-mutable `pond_water` background tile if needed for visual; otherwise 4).

### Key states

- `pond_clock.time_of_day` — 0.0 (dawn) → 1.0 (dusk) → 0.0 (next dawn)
- `pond_clock.sunlight` — derived from time_of_day (sin curve clamped to [0, 1])
- `water_plant_seed.growth` — 0 → 100, advances when sunlight > 0.3
- `fish.hunger` — 0 → 100, increases each tick, decreases on eating

### Key relations

None. This game is small enough to use spatial proximity (contact triggers)
+ tags. No relations needed.

### Player verbs

None. Pure simulation, watch-only. The "player" entity is omitted entirely
to keep entity count low.

## Honest scope

- No player input, no held-tools, no inventory — keeps within Yume's
  simulation-shaped sweet spot
- No dialogue, no NPCs — just fish + plants
- No tile grid — fish + plants live in a continuous 2D space
  (positions drawn from random distribution at init)
- No save/load (out of scope for this verification)
- No fish death (per prose — they just stop being interesting at high hunger)

Flag for future:
- Fish reproduction is intentionally absent. If we add it, bumps entity
  count up. Skip for verification.

## Open questions

(In autonomous mode — content-designer to resolve based on best-judgment.)

**Q1. Single plant def or two?** Splitting `water_plant_seed` and
`water_plant_mature` makes the visual progression clear. Could collapse
to one def with a `stage` state field. Recommend: keep as 2 defs
(simpler rules, same total count).

**Q2. Day/night via single sin formula or stepped phases?** Sin curve
gives smooth fade; stepped (day=1, night=0) is cheaper. Recommend: sin
curve in formula, stored to `sunlight` state for query simplicity.

**Q3. Fish eating mechanic — remove plant entirely or transform?**
Transform mature → seed (regrowable from 0) creates a richer cycle
than just remove. Recommend: remove (simpler, plant seeding handles
recovery).

**Q4. Initial entity counts?** Recommend: 1 pond_clock, 8 mature plants,
4 seed plants, 3 fish = 16 instances. Within engine perf budget.

## Hand-off checklist

- [x] Open questions Q1-Q4 documented with autonomous-mode recommendations
- [ ] Pass to `yume-systems-designer` with path
      `/home/kamwoh/yume/docs/games/tinypond/GDD.md`
- [ ] Reference: `archetypes/core/templates/godot/data/demo_ecology/` for
      smallest-similar simulation pattern

## Rule count target

Per autonomous-mode budget directive: ~10-12 rules total.
- 2 clock rules (advance time, update sunlight)
- 2 plant growth rules (grow when sunlit, seed→mature transform at threshold)
- 1 plant seeding rule (mature plant occasionally spawns new seed nearby)
- 2 fish movement rules (random walk, position clamp)
- 2 fish eating rules (contact-based: detect mature plant + remove it, hunger decrease)
- 1 fish hunger rule (per-tick hunger increase)

Total: 10 rules. Within budget.

_Respects framework invariants #1-8 from `docs/30_framework_primitives.md`._
