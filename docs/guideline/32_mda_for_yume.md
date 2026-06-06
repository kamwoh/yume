# MDA framework for Yume

_Last updated: 2026-05-01_

## Source

**Hunicke, LeBlanc, Zubek (2004).** *"MDA: A Formal Approach to Game Design
and Game Research."* Workshop on Challenges in Game AI, AAAI.

The classic three-layer model:

| Layer | Designer's view | Player's view |
|---|---|---|
| **Mechanics** | Rules, algorithms, data | (invisible — the rules) |
| **Dynamics** | Runtime behavior from rules + player action | The world reacting |
| **Aesthetics** | Emotional responses we want to evoke | What the game *feels* like |

Designer thinks **M → D → A**: build mechanics, dynamics emerge, hope
aesthetics land.
Player experiences **A → D → M**: feels something, sees the world react,
infers (or doesn't) the rules underneath.

This doc translates MDA into **Yume vocabulary** so the design agent
(`game-designer`) can decompose prose game requests into structured GDDs.

---

## M — Mechanics

In Yume terms: **the JSON.**

| MDA term | Yume term | File |
|---|---|---|
| Entities (objects, units) | `Entity` defs | `entities/*.json` |
| Rules (triggers + conditions + outcomes) | `Rule` defs | `world/rules*.json` |
| Relations (ownership, adjacency, membership) | `Relation` typed edges | `entities/*.json` `initial_relations` |
| State (HP, XP, ammo, growth) | `state_init` fields | `entities/*.json` |
| Properties (mass, hardness, color) | `properties` fields | `entities.json` |
| Tags (membership groups) | `tags` arrays | `entities.json` |

Mechanics are **declarative**. They specify what *is* (entities, properties)
and what *can happen* (rules with triggers and effects). They do NOT specify
runtime sequences — that's dynamics.

**Mechanic design questions** (the agent should ask these):
- What entities exist?
- What states does each entity carry?
- What triggers fire what effects?
- What relations matter (inventory? on_square? part_of?)
- What's the verb set the player can invoke?

---

## D — Dynamics

In Yume terms: **what happens when the engine runs the JSON over time.**

Dynamics are **emergent**: never written explicitly, always derived from
how mechanics + player input + chance compose.

| Yume primitive | Produces these dynamics |
|---|---|
| Tick rule with `interval` | Periodic decay/growth (hunger, fuel, age) |
| Contact rule with radius | Spatial reactions (fire spread, predation, hits) |
| Signal cascade | Event chains (kill → xp → level up) |
| Relation transfer | Resource flow (item pickup, building ownership) |
| Formula with state path | State-dependent behavior (faster growth near water) |
| Random (`randf()`, `chance`) | Variability across runs (same JSON, different stories) |

**Dynamic design questions:**
- What cascades do mechanics produce?
- Are they convergent (stable equilibrium) or divergent (runaway)?
- Where does randomness enter? (chance per-rule, formula `randf()`,
  initial position scatter)
- What feedback loops exist? (positive: fire spread; negative: water
  extinguishing; equilibrium: rabbit-fox)
- What's the typical play length until first interesting state change?

In Yume, observable dynamics include:
- **Cascades**: forest fire → ash → grass → forest regen
- **Equilibria**: predator-prey (rabbits/foxes population stabilization)
- **Phase transitions**: ore + heat over time → smelt → ingot
- **Chains**: input → emit signal → spawn entity → contact → damage → death → xp

---

## A — Aesthetics

In Yume terms: **what the player feels.** Yume can't directly produce
aesthetics — they emerge from D, which emerges from M.

LeBlanc's eight aesthetic categories (from the original MDA paper):

| Category | What it means | Yume mechanism examples |
|---|---|---|
| **Sensation** | Sense pleasure | Visual chains (`tree → ash → grass`), satisfying cascades |
| **Fantasy** | Make-believe | Tagged entities (wizard, dragon) + thematic shapes/meshes |
| **Narrative** | Story progression | Signal-driven phase changes, world.tick gating |
| **Challenge** | Obstacle course | Enemy AI (contact-pair pursue), HP scarcity, time pressure |
| **Fellowship** | Social framework | Relations (`member_of`, `allied_with`); multi-actor coord (Tier 3) |
| **Discovery** | Uncharted territory | Procedural variation via `randf()`, large entity-space exploration |
| **Expression** | Self-discovery | Player choice via input rules with multiple effects |
| **Submission** | Pastime | Long-running self-sustaining sims (deep ecology) |

**Aesthetic design questions:**
- What's the *intended* feel? (challenge, calm, surprise, mastery, ...)
- What dynamics produce that feel?
- What mechanics produce those dynamics?
- Which aesthetic categories does this game emphasize? (Usually 2-3, not all 8.)

---

## How the design agent should use this

When given prose like *"a farming game where moonlight grows crops faster
and rot turns into fertilizer"*, the **game-designer** agent decomposes:

### 1. Identify aesthetics target

> "This sounds like **Submission** (long sim) + **Sensation** (visual
> growth/decay cycles) + lightly **Discovery** (different crops behave
> differently)."

### 2. Sketch dynamics

> "Cascades: seed → young → mature → rot. Moonlight (world.time_of_day)
> modulates growth rate. Rot accumulates → fertilizer → boosts nearby
> growth. Need feedback loop so player can see the moonlight effect
> (timing matters). Low/no challenge dynamics — this is a calm sim."

### 3. Specify mechanics

> Entities: crop_seed, crop_young, crop_mature, rotting, fertilizer,
> player.
> States: growth, rot_age, position.
> Rules: tick growth rate scales with `world.is_night ? 2 : 1`. Contact
> fertilizer + crop_seed → state_add growth +5. Tick rot_age++ → at
> threshold transform to fertilizer.
> Relations: held_by (player carries seeds).

### 4. Hand off to systems-designer

The **systems-designer** agent takes these mechanics, writes the actual
rules + entity defs, picks balance values, surfaces ADRs for any new
primitive needs.

---

## What MDA does NOT cover

The original MDA paper is genre-agnostic but assumes a **playable game**.
For pure simulations (Yume's deep ecology demo, no player), the
"player's view" of A is replaced by an **observer's view**: what does
watching this world feel like? Yume supports both — the same primitive
set runs sim-only and player-driven games.

For text-to-game pipelines (Yume's north star), MDA gives the design
agent vocabulary to **structure prose decomposition**. Without MDA, the
agent might dive straight into "what entities should exist" — losing
the aesthetic intent that should drive everything else.

---

## Reference reading

- Hunicke et al. 2004 — original paper (4 pages, free PDF)
- Schell, *The Art of Game Design: A Book of Lenses* — MDA expanded
- *A Theory of Fun* (Koster) — aesthetics-first take

For Yume content authors, the **mechanics → dynamics → aesthetics**
direction (MDA) is the design path. The **aesthetics → dynamics →
mechanics** direction (player experience) is the testing path —
playtesting reveals whether the intended aesthetic landed.
