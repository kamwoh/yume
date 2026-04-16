# Game Goal Discussion — 2026-04-16

## The question (user)

> "I feel now still kind of empty, I am thinking what am I simulating,
> we should have a game goal right?"

## Diagnosis

Tier 1 complete = agents self-sustain. But homeostasis alone is empty.
No arc, no stakes, no progress. The sim ticks forever but nothing changes.

## What's missing

Every compelling living sim has ONE of:
- **Stakes** — things can go wrong (Dwarf Fortress, RimWorld)
- **Accumulation** — things you can point to ("that wasn't there before")
- **Individuality** — agents feel like characters, not cogs (The Sims)
- **Progression** — world changes over time (Civilization)

We have homeostasis. We need a driver.

## Four candidate goals

### (a) Survive the night ⭐ recommended start
- Day safe, night dangerous
- Agents must reach shelter (house/campfire) before dark or take damage
- Optional: hostile NPCs spawn at night (brain_state_machine reuse)
- **Why first:** 80% of mechanics already in place (day/night cycle exists,
  shelter groups exist, hostile brains exist). ~1-2 hours to wire.
- **Drama level:** HIGH — every sunset = real stakes

### (b) Build a village
- Agents accumulate materials → construct new composites (house_small etc.)
- More houses → population grows (new agents spawn)
- Progress metric: village size, agent count
- Recipe already exists in recipes.json (`build_shelter`: 8 wood + 4 stone)
- **Effort:** medium. Brain needs a `build` action + placement logic on open ground
- **Drama level:** slow but visible — "village grew"

### (c) Tech tree progression
- Stone age → bronze → iron → modern
- Each age unlocks new recipes + better tools
- **Effort:** high. Need research/discovery mechanic, tech gate system
- **Drama level:** stat progression, not visceral

### (d) Agent individuality + relationships
- Traits: greedy / lazy / social / ambitious → affect decisions
- Relationships: friend / rival / family → drive behavior
- **Effort:** medium-high. New brain logic layer
- **Drama level:** surprising, story-driven like Sims

## Recommended path

1. **(a) Night danger** first — low effort, high impact
2. **(b) Village building** second — gives long-term progression
3. **(d) Individuality** third — adds emotional hook to (a) + (b)
4. **(c) Tech tree** later — needs (b) as foundation

## What the user picked

Paused for sleep. Decision on the next direction comes next session.

## Hints for the next session

- User is tired of "empty" feeling — needs direction, not just mechanics
- Tier 1 is done; foundation is solid
- Options (a) and (b) are the low-hanging fruit
- Don't over-engineer — pick one, ship the feeling, then add depth

## Quick reference — what's already in place that a game goal can use

| Asset | Can support |
|---|---|
| Day/night cycle (world_environment.gd) | (a) night danger trigger |
| `shelter_energy_regen` rule | (a) — agents naturally prefer shelter |
| `brain_state_machine.gd` | (a) — hostile NPCs (orcs, used in dungeon) |
| `build_shelter` recipe | (b) — house construction |
| Composite spawn helper `sim_world.spawn_element_at()` | (b) — place new buildings |
| `population_manager.gd` | (a)(b) — respawn dynamics |
| HUD shows agent names + status | (a)(d) — character identity |
| Brain abstraction | (d) — swap in personality-tinted brains |
