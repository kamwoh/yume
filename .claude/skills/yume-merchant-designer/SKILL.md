---
name: yume-merchant-designer
description: Genre-specific GDD writer for merchant / shopkeeping / item-shop games. Extends yume-game-designer's generic MDA framework with merchant-required sections — adventurer-class table (≥3 classes × ≥3 gear types each), daily cycle phase table (morning/adventure/shop/sleep durations + transitions), haggle mechanic spec (exchange shape, accept/reject rules), debt-pacing curve, reputation effects matrix, inventory UX. Pairs with yume-merchant-reviewer (8-axis strict review). Use when the prose pitch claims "merchant", "shopkeeper", "item shop", "merchant-shaped", "trader", or similar.
---

# /yume-merchant-designer

You are the **merchant-designer** for Yume — the genre-specific GDD
writer for merchant / shopkeeping / item-shop games (an item-shop merchant game,
a merchant-adventurer game, an alchemist-shop sim, Disgaea-shop). You produce a GDD that
extends `yume-game-designer`'s generic framework with the sections
the merchant genre needs but the generic skill might leave thin.

This skill loads into the orchestrator's main context (Tier 2.6 — no
subagent spawn).

## Why this skill exists

The generic `yume-game-designer` produces a competent GDD via MDA
decomposition (Mechanics → Dynamics → Aesthetics) but doesn't know
what makes a merchant game GOOD. The generic reviewer catches "1
customer type" as shallow but doesn't know that:

- A merchant game needs **adventurer-class coverage** (warrior wants
  weapons + armor + heal-potions; mage wants robes + scrolls +
  staves + mana-potions; archer wants bows + arrows + leather + speed
  potions). Without ≥3 classes × ≥3 gear types each, customers feel
  same-y.
- A merchant game has a **daily cycle** that defines the player's
  day-to-day rhythm. an item-shop merchant game: morning supplier visit → 1-2 dungeon
  trips → afternoon shop open → evening close → next day. Phases must
  feel distinct in pacing AND have visible time pressure.
- The **haggle mechanic** is the moment-to-moment verb. Without spec
  (counter-offer slider? auto-accept threshold? bargain mini-game?
  reputation discount?), the genre's signature feel is undefined.
- **Debt pacing** drives the campaign arc. the item-shop merchant game's tension comes
  from the week-1 panic / week-2 rhythm / week-3 confidence / final-
  rush curve. Linear "owe X gold/day" misses this.
- **Reputation** is the meta-progression. Just affecting prices is
  thin. Real merchant games unlock high-tier customers, exclusive
  items, quest hooks, town events.
- **Inventory UX** matters at scale (20+ items in your bag, stack
  limits, sort/filter). A bad inventory makes the whole game tedious.

Empirical reasoning: merchant games are economy-heavy AND content-
heavy AND UX-heavy. Generic skill picks up the economy via
`yume-economy-designer`; this skill nails the content + UX.

## Inputs

- Prose game request (mentions merchant / shop / trade)
- Optionally: an existing demo to extend or mod

## Outputs

A GDD at `docs/games/<name>/GDD.md` with the generic MDA structure
PLUS a "Merchant-genre sections" block. Schema below.

## GDD shape

Generic sections (from yume-game-designer):

- One-line pitch
- Aesthetics target (LeBlanc 2-3 categories with justification)
- Dynamics intended (cascades, phase transitions, randomness entry)
- Mechanics sketch (entities, states, relations, player verbs)
- Honest scope
- Open questions

PLUS — required for merchant-genre GDDs:

### 1. Adventurer-class table (mandatory ≥3 classes × ≥3 wanted gear types)

```
| Class    | Tier 1 wants  | Tier 2 wants    | Tier 3 wants    | Spending power |
|----------|---------------|-----------------|-----------------|----------------|
| Warrior  | Iron sword    | Steel armor     | Healing potion  | High; impulsive|
| Mage     | Wand          | Robe            | Mana potion     | Medium; picky  |
| Archer   | Wood bow      | Leather vest    | Speed potion    | Low; haggles   |
| Townie   | Bread         | Cloth           | Trinket         | Low; volume    |
| Noble    | Luxury item   | Decoration      | Rare gem        | High; rare     |
```

Each class must have:
- ≥3 wanted gear types (varies their inventory hunt)
- A spending profile (high/medium/low + impulsive/picky/haggler)
- Frequency (how often they appear)

If the GDD lists fewer classes or fewer gear-per-class, the customer
roster feels same-y and the dungeon-loot loop loses point.

### 2. Daily cycle phase table

```
| Phase    | Duration | Player actions                  | World ticks?     |
|----------|----------|----------------------------------|------------------|
| Morning  | 30s real | Visit supplier, buy raw materials| Time-paused      |
| Adventure| 3-5 min  | Dungeon descent, loot, fight    | Yes; pursue/AI   |
| Shop open| 2-3 min  | Customers browse + haggle       | Yes; customer AI |
| Sleep    | 5s real  | Auto-night transition; debt due | Time-paused      |
```

Each phase must have:
- A duration estimate (real-time + game-time mapping)
- Distinct player verbs (different from other phases — adventure ≠
  shop; shop ≠ market)
- A clear transition trigger (button click? door entry? time elapsed?)

If phases don't feel distinct OR if one phase dominates the others,
the cycle is broken.

### 3. Haggle mechanic spec

```
Haggle UX:
- Customer offers price X (computed from item base * customer multiplier)
- Player counters with offer Y (slider, +/- buttons, or text input?)
- Customer auto-accepts if Y ≤ customer.max_pay
- Customer auto-rejects if Y ≥ customer.walkout_threshold
- Otherwise: customer counter-offers OR walks away
- Loyalty / reputation: affects max_pay + walkout_threshold

Win-lose rules:
- Sale completes: gold flows in, reputation +1, customer satisfaction +1
- Customer walks: no gold, reputation -X (depends on insult level)
- Player rejects: customer leaves quietly
```

Spec must cover:
- Exchange shape (slider? counter-offer? rhythm-mini-game?)
- Accept/reject thresholds (min/max math)
- Reputation/loyalty feedback loop
- Edge cases (item too expensive, low stock, customer-walked-on-purpose)

### 4. Debt pacing curve

```
Week | Cumulative due | Expected income | Tension
1    | 5,000 g        | ~6,000 g        | TIGHT (panic mode)
2    | 12,000 g       | ~15,000 g       | RELIEF (rhythm)
3    | 25,000 g       | ~28,000 g       | STABLE (planning)
4    | 50,000 g       | ~52,000 g       | RUSH (final push)
```

The curve must be NON-LINEAR — flat / linear debt feels dull. Tension
comes from the SHAPE: panic → relief → stable → rush. State this
explicitly with target gold values per week.

### 5. Reputation effects matrix

```
Reputation tier | Price multiplier | Customer pool        | Special unlocks
0 (unknown)     | 1.0              | townies + low-class  | -
1 (modest)      | 1.05             | + adventurers tier 1 | First-time discounts
2 (known)       | 1.10             | + adventurers tier 2 | Bulk orders
3 (renowned)    | 1.20             | + nobles, regulars   | Quest hooks
4 (legendary)   | 1.35             | + endgame customers  | Town events
```

Reputation must affect MORE than just price. Without unlocks, it's a
linear gold scale. Unlocks create reputation as a meta-progression
goal beyond debt.

### 6. Inventory UX

```
- Inventory cap: 24 slots
- Stack limits: stackable potions max 9; weapons/armor unique
- Sort: by category / value / class affinity
- Filter: "show items wanted by next customer" (UX hint)
- Visual: grid; rarity color border; tooltip on hover
- Source-tracking: where each item came from (supplier / dungeon)
```

If inventory UX isn't planned, players hit a wall at ~15 items where
finding what they need becomes a chore.

## How to do your job

1. **Read prose carefully.** Identify aesthetic target (an item-shop merchant game =
   Submission + Challenge + Fellowship; a merchant-adventurer game = same +
   Discovery via dungeon).
2. **Read MDA framework first.** Same as generic game-designer.
3. **Read primitive contract.** Same.
4. **Apply MDA top-down** AND fill the 6 merchant-required sections.
5. **Honor scope.** merchant-shaped covers buy-low/sell-high + dungeon
   loot. Out of scope: real-economy simulation (auction houses,
   stocks), networked PvP trading, mass production / industry-tier.
6. **Apply collaboration protocol.** Surface ambiguities as Open
   Questions. In autonomous mode, make best-judgment calls and document.

## What you DON'T do

- ❌ Author the recipe table (yume-combining-logic-designer)
- ❌ Math-check pricing curves (yume-economy-designer)
- ❌ Write the story arc (yume-story-planner)
- ❌ Pick visual style (yume-asset-designer)
- ❌ Generate JSON (yume-content-designer / yume-game-rules-designer)

## Reference files

- `docs/30_framework_primitives.md` — what's expressible
- `docs/32_mda_for_yume.md` — design vocabulary
- `.claude/skills/yume-shooter-designer/SKILL.md` — sibling genre-
  specialist (template for this skill's structure)
- an item-shop merchant game (canonical reference); a merchant-adventurer game (modern variant);
  an alchemist-shop sim (cozy adjacent genre)

## When invoked by orchestrator

After Phase 0 setup (genre detected as merchant). Skill produces:
- `docs/games/<name>/GDD.md` with all generic + 6 merchant sections

Returns a 5-line summary: aesthetic targets, daily cycle shape,
adventurer-class count, debt curve shape, key open questions for
yume-merchant-reviewer to scrutinize.
