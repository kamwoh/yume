# 00 — What Yume Is

_Last updated: 2026-05-23_

## One sentence

**Yume is a programmable explicit world model.**

JSON is the world specification language. The Yume runtime is an
interpreter that executes the specification, advancing world state
tick by tick. Godot is the projection function that renders the
current state as pixels (or audio, or HUD, or text).

Games are one downstream consumer of this. Reinforcement-learning
testbeds, agent-evaluation harnesses, scene-generation pipelines,
and training-data factories for neural world models are equally
valid uses of the same substrate.

---

## What is a world model?

In the broadest sense, a world model is a function:

```
f(state_t, action_t) → state_{t+1}
```

Given the current state of some world and an action taken in it,
predict the next state. The action can be a player input, an
agent's decision, a scheduled event, or the passage of time.

World models have two flavors:

### Implicit (neural) world models

`f` is represented by neural network weights. The model is trained
on trajectories — sequences of (state, action, next_state) tuples
— until the network learns the transition function in a compressed
distributed form.

Examples: Hafner's Dreamer family (`DreamerV3`), DeepMind's
`MuZero`, Google's `Genie` / `GAIA`. LeCun has argued world models
are the central missing ingredient for general intelligence.

Implicit models are fast at inference and can model worlds whose
rules are unknown or too complex to write down. They're also
opaque, hard to debug, and require massive training data.

### Explicit (programmable) world models

`f` is written down — as code, as a rule system, as a physics
simulator. Game engines, scientific simulations, and rule-based AI
environments all qualify. The transition function is human-
authored and human-readable.

Examples: traditional game engines (Unity, Unreal, Godot), physics
simulators (MuJoCo, PyBullet), agent-based modeling toolkits
(NetLogo, Mesa), Minecraft.

Explicit models are interpretable, debuggable, and require zero
training data. But they're labor-intensive to author per-world and
locked to whatever vocabulary the engine provides.

---

## Where Yume sits

```
                  ┌────────────────────────────────┐
                  │  World model = f(state, action)│
                  │       → next_state             │
                  └──────────────┬─────────────────┘
                                 │
                ┌────────────────┴────────────────┐
                │                                 │
                ▼                                 ▼
        IMPLICIT (neural)               EXPLICIT (programmable)
        DreamerV3, MuZero,              Game engines,
        Genie, GAIA, ...                physics sims, ...
                │                                 │
                ▼                                 ▼
        f lives in weights              f is authored
        Trained from data               Encoded in code/JSON
                ▲                                 │
                │                                 │
                └──── trajectories ◄──────────────┘
```

Yume is **explicit, programmable, and JSON-specified.** It sits
firmly in the right-hand branch. But its specification language
makes it useful for training the left-hand branch too — JSON-
authored worlds can be rolled out in the explicit interpreter,
the trajectories recorded, and the data used to train an implicit
model that approximates the same world cheaper at scale.

This is the bridge between the two halves of the world-modeling
field, and Yume's positioning is to be the **clean, structured,
authorable substrate** that feeds both directions.

---

## Yume's architecture in this frame

| Component | Role in the world-model frame |
|---|---|
| **JSON content** (entities, rules, scenes, screens) | The world specification — the program that *is* `f` |
| **Yume engine** (`godot/scripts/engine/`) | The interpreter that executes the specification, ticking state forward |
| **Yume primitives** (Entity / Tag / Rule / Trigger / Effect / Query / Relation) | The alphabet of the specification language — the minimum vocabulary to describe discrete-time world transitions |
| **Godot rendering / audio / input** | The projection functions — state → pixels, state → audio, input → action |
| **Yume skills + tools** (`.claude/skills/`, `tools/yume_assetgen/`, ...) | Authoring assistants that produce JSON from prose, images, or other JSON |

This is why ADR 0021 says *"expose, don't reimplement."* Godot is
not the world model — it's the projection function. We use it
because rendering, audio, physics integration, and input handling
are *projection* problems and Godot has solved them. The world
model itself — the transition function — is Yume's responsibility,
and it must remain JSON-authorable.

---

## The seven primitives, reframed

The seven primitives in `30_framework_primitives.md` are not
arbitrary engine concepts. They are the minimum vocabulary needed
to describe an arbitrary discrete-time world model:

| Primitive | Frame |
|---|---|
| **Entity** | A discrete element of state |
| **Tag** | A categorical label over entities (membership without hierarchy) |
| **Relation** | A typed directed link between entities (graph structure of state) |
| **Trigger** | A predicate over time + events that drives transitions |
| **Query** | A selector over state — the read side of a transition |
| **Effect** | A state mutation — the write side of a transition |
| **Rule** | A bound triple (Trigger × Query × Effect) — one transition function fragment |

A complete world specification is: a set of entities (initial
state) + a set of rules (transition function). The runtime composes
the rule fragments tick by tick to compute `state_{t+1}` from
`state_t` and the actions buffered in that tick.

This is why we resist adding "semantic effect types" (no `damage`,
no `heal`, no `attack`). Those are *world-specific* labels for
state mutations; the primitive `state_set` / `state_add` /
`spawn` / etc. is *world-agnostic*. The vocabulary must remain
minimal AND universal — anything narrower is content, not engine.

---

## Why this framing matters

Once Yume is understood as a world-model substrate (not a game
engine, not a sim toolkit, not a CMS), several recurring questions
resolve cleanly:

**"Should the engine know about HP / hunger / XP?"**
No. Those are vocabulary in a specific world's specification, not
in the substrate. Yume sees `state.<field>` as opaque scalars or
arrays the rules manipulate.

**"Should we add a `combat` primitive?"**
No. Combat is composable from `contact` triggers + `state_add`
effects + queries. If a world wants combat, its rules express it.
The substrate provides the composition tools, not the verbs.

**"Should the renderer know about 'player' vs 'NPC'?"**
No. The renderer sees entities with visual attributes. `player`
is a tag — a content-level label. The renderer reads `visual.*`
fields the content authored.

**"Should we support 3D / VR / multiplayer / async LLM agents?"**
These are questions about what the *projection function* needs to
support, not about the substrate. The substrate already supports
N agents, N actions per tick, async input — those are vocabulary
features. Whether Godot can render them, stream them, or talk to
an LLM is a separate engineering concern.

**"Is this game or a simulation or a research environment?"**
Yes. The substrate doesn't care. The same JSON spec can render as
a playable game (Godot projection), as a headless rollout for
training data (recording projection), as a visual QA test bed
(capture projection), as a chat-driven debugger (text projection).

---

## Bridging to implicit world models

A practical consequence of being an explicit, programmable world
model is that Yume can serve as a *training-data factory* for
implicit models:

```
JSON spec → Yume interpreter → trajectory(state, action, next_state)
                                          │
                                          ▼
                                    JSONL/Parquet
                                          │
                                          ▼
                            Implicit model trainer
                            (Dreamer / Genie / custom)
                                          │
                                          ▼
                              Neural f̂(state, action)
```

The implicit model approximates Yume's explicit `f` at inference
speed. Training corpus is generated, not collected — every
trajectory is reproducible from the JSON spec + seed. This is
hugely cheaper and cleaner than scraping real-world data.

This is not currently a Yume deliverable (no built-in trainer),
but it's a *natural* downstream use. ADR 0049 (`engine-rules-as-
content`) and ADR 0050 (`frame-tick-trigger`) already structure
the runtime so that recording trajectories is a thin shim on top
of the existing scheduler.

---

## Implications for ADR authors

Every future ADR should ask itself:

1. **Is this a vocabulary change or a content change?**
   - Vocabulary change → modifies the alphabet of world description →
     requires this doc + ADR + primitives doc update
   - Content change → uses existing vocabulary → no ADR needed
2. **Does this preserve the explicit / interpretable property?**
   - Hardcoding game-specific logic in GDScript breaks this.
   - Burying state in opaque Godot nodes breaks this.
3. **Does the projection function expand, or does the world model?**
   - Adding "spawn a particle effect on hit" → projection (Godot
     particles, JSON declares the effect, the engine routes)
   - Adding "compute optimal pathfinding" → could be either; if
     the path becomes world state (cached, queried by other rules)
     it's world model; if it's a one-shot read at decision time
     it's projection. Prefer projection.
4. **Could this same change serve an implicit-model use case?**
   - If yes, it's substrate. Bias toward generality.
   - If it's only useful for "the player sees this," it's
     projection.

The seven primitives are the contract. They have been stable since
W1 (April 2026). Adding to that vocabulary requires this document
and `30_framework_primitives.md` to be updated *first*, then the
code follows.

---

## Inspirations + further reading

- LeCun, *A Path Towards Autonomous Machine Intelligence* — world
  models as the central architecture
- Hafner et al., *Mastering Diverse Domains through World Models*
  (DreamerV3)
- DeepMind, *Genie: Generative Interactive Environments* —
  implicit world model from video
- Sutton & Barto, *Reinforcement Learning: An Introduction*, §8 —
  planning vs learning, dyna architectures
- Schmidhuber, *World Models* (2018) — earliest LSTM-based
  explicit-to-implicit transition model

Yume's positioning is **not** a competitor to these. It's the
piece they're missing: a *clean, structured, authorable* explicit
substrate that can be both interpreted directly *and* used as a
faucet of training data for the implicit half.

---

## See also

- `30_framework_primitives.md` — the seven primitives (contract)
- `31_text_to_game_pipeline.md` — authoring pipeline (Tier 2.5+)
- `32_mda_for_yume.md` — design vocabulary (mechanics → dynamics → aesthetics)
- `adr/0021-yume-is-godot-layer.md` — expose-don't-reimplement
- `adr/0001-seven-primitives.md` — the original primitive set
- `adr/0049-engine-rules-as-content.md` — rules ARE content (closes
  one of the last gaps between vocabulary and content)
