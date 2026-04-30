# How Yume Works — Visual Reference

Four mermaid diagrams that together explain Yume from the outside in:
pipeline → engine → tick loop → invariant #8.

---

## 1. Pipeline overview — prose to running game

```mermaid
flowchart TB
    Prose["Natural language description<br/>e.g. 'farming game where<br/>moonlight grows crops faster'"]

    subgraph Tier25["Tier 2.5 — Pipeline (planned)"]
        direction TB
        GD["game-designer<br/>writes GDD"]
        Specs["systems-designer<br/>content-designer<br/>asset-designer<br/>(parallel)"]
        QA["qa-tester<br/>loads + validates"]
        TD["tech-director<br/>guards primitives"]
        GD --> Specs
        Specs --> QA
        TD -.guards.-> Specs
    end

    subgraph Channels["Four JSON channels (decoupled)"]
        direction LR
        WR[("world_rules.json")]
        EN[("entities.json")]
        SH[("shapes.json")]
        AC[("audio_catalog.json")]
    end

    subgraph Tier2["Tier 2 — Runtime (W1 ✅)"]
        direction TB
        World["World orchestrator"]
        Sched["PhaseScheduler<br/>4-phase tick"]
        Render["renderer_2d"]
        World --> Sched
        Sched --> Render
    end

    Game["Running Godot game"]

    Prose --> GD
    QA --> WR
    QA --> EN
    QA --> SH
    QA --> AC
    Channels --> World
    Render --> Game
```

Key idea: **prose flows down, JSON flows across, engine reads from the side**.
Six specialist agents produce four parallel JSON channels; the engine
consumes them. Swap any one channel without touching the others — go silent,
swap art style, replace rules — engine doesn't care.

---

## 2. Engine internals — primitives + interpreter

```mermaid
flowchart LR
    subgraph Data["JSON (content)"]
        WR[world_rules.json]
        EN[entities.json]
        SH[shapes.json]
    end

    subgraph Engine["Engine (GDScript, ~1500 LOC)"]
        direction TB
        World["World<br/>orchestrator"]
        Clock["WorldClock<br/>tick heartbeat"]
        Sched["PhaseScheduler<br/>4-phase + buffer"]

        subgraph Prims["7 primitives"]
            direction LR
            Entity
            Rule
            Query
            Effect
            Relation
            Tag
            Trigger
        end

        World --> Sched
        Clock --> Sched
        Sched --> Prims
    end

    subgraph View["Renderers"]
        R2["renderer_2d<br/>entity_sprite_2d.gd"]
        R3["renderer_3d<br/>(Tier 4)"]
    end

    Godot["Godot 4.6 runtime"]

    Data --> World
    Prims --> R2
    Prims --> R3
    R2 --> Godot
    R3 --> Godot
```

Key idea: **engine is small.** Eight files in `scripts/engine/`. The seven
primitives are typed GDScript classes; PhaseScheduler runs them. Renderer
sits on the side reading entity state per frame. Adding a 3D renderer
doesn't touch any primitive.

---

## 3. Four-phase tick — semantic identity

```mermaid
flowchart LR
    Clock(("WorldClock<br/>fires tick"))
    
    P1["Phase 1: input<br/>drain input_queue<br/>fire input-trigger rules<br/>buffer effects"]
    F1["flush effects"]

    P2["Phase 2: decide<br/>tick + signal rules<br/>read state snapshot<br/>buffer effects"]

    P3["Phase 3: commit<br/>apply effects in JSON order<br/>spawns/removes commit<br/>formulas eval at apply-time"]

    P4["Phase 4: react<br/>contact + relation_changed<br/>fire vs post-commit state<br/>buffer effects"]
    F2["flush effects"]

    Next(("Next tick<br/>input queue"))

    Clock --> P1
    P1 --> F1
    F1 --> P2
    P2 --> P3
    P3 --> P4
    P4 --> F2
    F2 -.signals from react.-> Next
    Next -.-> Clock
```

Key idea: **predictable causality.** Reads in `decide` see snapshot of prior
tick. Writes in `commit` apply in JSON definition order; later effects'
formulas read post-earlier-effect state. `react` runs after motion has
committed (so contact detection sees final positions). Signals emitted in
`react` cross to the *next* tick's input queue — no infinite cascade.

---

## 4. Invariant #8 — engine vs JSON, applied uniformly

```mermaid
flowchart TB
    subgraph Engine["Engine (GDScript) — fixed primitive vocabularies"]
        direction TB
        E1["Effect primitives:<br/>state_set, state_add, state_mul, state_clamp,<br/>spawn, remove, transform,<br/>relate, unrelate, transfer_relation,<br/>velocity_set, emit, tag_add, tag_remove"]
        E2["Draw primitives:<br/>circle, rect, polygon,<br/>line, text, texture"]
        E3["Audio primitives:<br/>play, loop, fade, stop"]
        E4["Query operators:<br/>_eq, _ne, _gt, _lt,<br/>_gte, _lte, _atleast, _atmost,<br/>tags_all/any/none, relations, radius"]
    end

    subgraph JSON["JSON (compositions)"]
        direction TB
        C1[world_rules.json<br/>specific rules]
        C2[shapes.json<br/>specific shapes]
        C3[audio_catalog.json<br/>specific sounds]
        C4[asset_catalog.json<br/>specific bindings]
    end

    E1 -.composes.-> C1
    E2 -.composes.-> C2
    E3 -.composes.-> C3
    E4 -.composes.-> C4
```

Key idea: **engine knows verbs; JSON composes nouns.** Adding `damage` as
an effect type is forbidden — that's a noun, expressible as `state_add` on
`hp`. Adding `draw_tree` as an op is forbidden — that's a noun, expressible
as `circle` + `rect` in `shapes.json`. The same test applies to every
future layer Yume adds.

---

## 5. Bonus — what gets touched when you change one thing

```mermaid
flowchart TB
    Q["What if I want to..."]

    subgraph Q1["Change rules<br/>(e.g. crops grow faster)"]
        E1[edit world_rules.json] -.-> NoTouch1[engine untouched]
    end

    subgraph Q2["Swap art style<br/>(pixel → AI-gen 3D)"]
        E2a[swap entity.visual fields<br/>or asset_catalog.json] -.-> NoTouch2[engine + rules untouched]
    end

    subgraph Q3["Add a new genre<br/>(chess, shooter, ...)"]
        E3[new data folder<br/>entities + rules + assets] -.-> NoTouch3[engine + other games untouched]
    end

    subgraph Q4["Add a draw shape<br/>(bush, lantern)"]
        E4[append to shapes.json] -.-> NoTouch4[renderer code untouched]
    end

    subgraph Q5["Add a new primitive<br/>(animation in Tier 4)"]
        E5[engine GDScript edit<br/>+ new JSON channel] --> Touch5[engine touched once]
    end

    Q --> Q1
    Q --> Q2
    Q --> Q3
    Q --> Q4
    Q --> Q5
```

Key idea: **the engine is touched only when adding new vocabulary**, never
when adding new content. This is the test of correctness — if you're
editing engine code to add a new game, something's wrong.

---

## 6. Asset pipeline — two-phase + three-tier fallback

```mermaid
flowchart TB
    subgraph Phase1["Phase 1 — design pipeline (LLM agents, no I/O)"]
        Prose["prose"] --> AD["asset-designer<br/>writes entity.visual prompts<br/>+ shape/mesh fallback hints"]
    end

    subgraph Output1["After Phase 1: game is PLAYABLE via fallback"]
        Data["data/<br/>entities.json + world_rules.json<br/>+ shapes.json + meshes.json<br/>(prompts written, no asset files yet)"]
    end

    subgraph Phase2["Phase 2 — asset realization (offline tool, when user ready)"]
        direction TB
        Tool["yume assets generate &lt;data_root&gt;<br/>INTERACTIVE one-by-one default"]
        subgraph PerEntity["Per entity"]
            Q1["show prompt + style + cost"]
            Q2["user: g/e/b/s"]
            Q3["call API"]
            Q4["preview file<br/>(viewer or HTML)"]
            Q5["user: y/r/R/b/s"]
            Q6["accept → manifest commit"]
            Q1 --> Q2 --> Q3 --> Q4 --> Q5 --> Q6
        end
        Tool --> PerEntity
    end

    subgraph Backends["Backends (config plugins)"]
        FX["FLUX / DALL-E / SD"]
        ME["Meshy / Tripo / Rodin"]
        EL["ElevenLabs / Stable Audio"]
    end

    subgraph Output2["After Phase 2: real assets in place"]
        Files["assets/generated/*.png|.glb|.ogg<br/>entity.visual.sprite_2d/model_3d filled"]
    end

    subgraph Runtime["Runtime — engine reads paths"]
        direction LR
        T1["1. file exists → load"]
        T2["2. shape/mesh in catalog → compose primitives"]
        T3["3. nothing → bare colored circle/cube"]
        T1 -.fallback.-> T2 -.fallback.-> T3
    end

    Prose --> AD
    AD --> Data
    Data -.iterate gameplay first.-> Runtime
    Data --> Tool
    Q3 --> FX
    Q3 --> ME
    Q3 --> EL
    Q6 --> Files
    Files --> Runtime
```

Key ideas:

- **Two phases, not in-line.** Phase 1 (design) writes JSON only. Phase 2
  (gen) is an explicit user-initiated step. Lets you iterate gameplay on
  fallback visuals before spending API credits.
- **Three-tier fallback** in the runtime renderer. Real asset → composite
  from `shapes.json`/`meshes.json` → bare primitive (colored circle/cube).
  **Always something visible** even with zero generated content.
- **Interactive one-by-one is the default** generation mode. Prompts are
  guesses — user verifies each. Batch mode is opt-in for CI / full
  re-runs after style change.
- **Backends are JSON plugins.** New API = config block + adapter (~50 LOC).
- **Engine never knows about prompts or APIs** — Phase 2 is offline
  tooling that fills paths into `entity.visual`. Engine reads file paths
  identical to human-drawn assets.

---

## How to view these

Mermaid renders in many places. Pick whichever fits:

| Tool | How |
|---|---|
| **GitHub** | Push this file, view on github.com — auto-renders |
| **VSCode** | Install extension *"Markdown Preview Mermaid Support"*, then `Ctrl+Shift+V` to preview |
| **Online** | Copy a single ` ```mermaid ... ``` ` block contents into [mermaid.live](https://mermaid.live) — instant render, exports SVG/PNG |
| **CLI** | `npm install -g @mermaid-js/mermaid-cli` then `mmdc -i this_file.md -o diagrams.png` |
| **Obsidian / Typora / Logseq** | All have built-in mermaid support |

For sharing single diagrams as images: [mermaid.live](https://mermaid.live)
is the fastest — paste, screenshot or export.

---

## How to extend

When adding a new architectural concept (e.g. Tier 3 actors with Plan +
Knowledge primitives), append a section here with a fresh diagram. Keep
each diagram focused on one idea — five focused diagrams beat one giant
one.
