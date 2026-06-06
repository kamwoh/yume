# Yume — detailed architecture (Mermaid)

_Last updated: 2026-05-31_

> **Start with §0** — it's the conceptual frame (Yume as an explicit world
> model: instance JSON vs fixed engine laws, and authored vs learned for
> research). §1-8 are the mechanics that implement it.

Visual reference for the Yume engine, grounded in the actual
`godot/scripts/engine/` source tree (verified 2026-05-31). Render with any
Mermaid viewer (GitHub renders these inline; VS Code "Markdown Preview Mermaid
Support"; or `docs/timeline/index.html` patterns).

The contract is `docs/guideline/30_framework_primitives.md`; this doc is illustration,
not invariant-bearing. Where a diagram cites a file, it's a real path.

---

## 0. Yume as an explicit world model (the conceptual frame)

The whole architecture exists to serve one idea: **the JSON IS an explicit,
declarative world model.** But there are TWO layers, and only one is explicit.
The JSON declares *what the world is*; the engine defines *how it evolves* (the
fixed laws every world shares — Invariant #8, primitives + interpreter).

```mermaid
flowchart TB
    subgraph INSTANCE["🟦 WORLD INSTANCE — EXPLICIT, JSON, varies per game"]
        direction LR
        WHAT["WHAT EXISTS<br/>entities/*.json<br/>(id · tags · properties · state · position)"]
        HOW["HOW THINGS INTERACT<br/>world/rules/*.json<br/>(trigger → query → effect)"]
        USER["HOW USER INTERACTS<br/>ui/input.json + input rules"]
        PROPS["WORLD PROPERTIES<br/>scene.json · world/state.json<br/>zones.json · initial_relations"]
    end

    subgraph LAWS["🟧 WORLD ENGINE — FIXED, GDScript, shared by ALL games"]
        direction LR
        CLOCK["the tick clock<br/>+ 4-phase ordering"]
        SEM["effect resolution<br/>query matching · formula eval"]
        PHYS["Godot physics<br/>move_and_slide (opaque C++)"]
    end

    INSTANCE -->|interpreted by| LAWS
    LAWS -->|produces| STATESEQ["STATE SEQUENCE<br/>state(N) = f(initial_state, input_log[0..N])<br/>— deterministic, serializable as JSON"]

    NOTE1["📌 JSON is explicit + inspectable + editable per-game.<br/>Engine laws are fixed + shared — NOT JSON (Invariant #8).<br/>Two games share identical laws; only their JSON differs."]
    INSTANCE -.-> NOTE1

    classDef c fill:#e8f4ff,stroke:#3b82f6,color:#000
    classDef e fill:#fff4e6,stroke:#f59e0b,color:#000
    classDef s fill:#e8ffe8,stroke:#22c55e,color:#000
    classDef n fill:#fffbe6,stroke:#ca8a04,color:#000
    class WHAT,HOW,USER,PROPS c
    class CLOCK,SEM,PHYS e
    class STATESEQ s
    class NOTE1 n
```

### 0b. Programmable EXPLICIT world model → trains an implicit NEURAL one

Yume itself contains **no neural component** — it is a *programmable explicit*
world model: JSON program + deterministic symbolic interpreter (the engine).
Its value for ML is as a **data + ground-truth factory**: it deterministically
emits `(JSON spec, input_log, frames, true_state)` tuples that can train and
evaluate a *separate, implicit neural* world model. The neural model lives
OUTSIDE Yume; it never edits the engine. The agent sees only pixels and must
reconstruct the dynamics from observation (the POMDP wall, ADR 0060).

```mermaid
flowchart LR
    subgraph YUME["🟧 YUME — programmable EXPLICIT world model (deterministic, symbolic, NO neural net)"]
        direction TB
        JSONW["JSON program<br/>(entities · rules · input · props)"]
        ENGINE["symbolic interpreter<br/>(fixed engine laws)"]
        STATE["true state (JSON)<br/>state(N)=f(init, inputs)"]
        REND["render → pixels"]
        JSONW --> ENGINE --> STATE --> REND
    end

    STATE -->|"STATE channel (--state-fd)<br/>GROUND TRUTH — harness only"| DATA
    REND -->|"FRAME channel (--frame-file)<br/>observation"| DATA
    JSONW -.optional conditioning.-> DATA

    DATA["📦 dataset factory<br/>(spec, input_log, frames, true_state)<br/>deterministic · replayable · scalable"]

    subgraph NEURAL["🟥 IMPLICIT NEURAL world model (trained OUTSIDE Yume)"]
        direction TB
        TRAIN["train: learn dynamics<br/>from frames (+ optional spec)"]
        LATENT["internal latent ŝ<br/>(implicit — not JSON)"]
        TRAIN --> LATENT
    end

    DATA -->|frames = inputs| TRAIN
    DATA -->|true_state = supervision / eval| EVAL
    LATENT -->|probe ŝ| EVAL["EVAL — compare ŝ vs true_state<br/>field-by-field → score"]

    WALL["🧱 THE WALL — the agent/model gets PIXELS, never the<br/>STATE channel. State is the answer key, used only to<br/>train/score — leaking it into the model voids results."]
    NEURAL -.-> WALL

    classDef c fill:#e8f4ff,stroke:#3b82f6,color:#000
    classDef e fill:#fff4e6,stroke:#f59e0b,color:#000
    classDef d fill:#fffbe6,stroke:#ca8a04,color:#000
    classDef m fill:#ffe8e8,stroke:#ef4444,color:#000
    class JSONW c
    class ENGINE,STATE,REND e
    class DATA,WALL d
    class TRAIN,LATENT,EVAL m
```

**Key takeaways:**
- **Yume = programmable EXPLICIT model.** JSON is a *program*; the engine is a
  deterministic *symbolic interpreter*. Nothing learns; nothing is approximate.
- **The neural model = IMPLICIT, separate, downstream.** It's trained on Yume's
  emitted data and lives entirely outside the engine. Its "understanding" is a
  learned latent `ŝ`, not JSON. Yume never depends on it.
- The JSON is explicit at the **instance** layer (what exists, what rules, what
  the player can do). The **dynamics** are split: rule *semantics* are explicit
  JSON, but execution semantics (tick order, commit) + physics are fixed engine
  code (Invariant #8) — shared laws, varying instance.
- Yume's rare property: an explicit, *readable* ground-truth state stream — a
  clean answer key for supervising/scoring an implicit model. Most pixel
  environments lock true state in an opaque simulator, so you can only train on
  pixels + reward, never probe against structured truth.

---

## 1. Layered overview — content vs engine vs render

The single most important invariant: **the engine (orange) contains no
game-specific logic.** All game behavior is JSON (blue). Renderers (green)
read engine state and never mutate it.

```mermaid
flowchart TB
    subgraph AUTH["① AUTHORING — offline, LLM-assisted"]
        direction LR
        PITCH["prose pitch"]
        SKILLS["/yume-design (game)<br/>/yume-create-scene (3D world)<br/>— 38 specialist skills"]
        PITCH --> SKILLS
    end

    subgraph CONTENT["② JSON CONTENT — data/demo_&lt;name&gt;/ (gitignored, per-game)"]
        direction LR
        ENT["entities/*.json<br/>defs + initial_instances"]
        RULES["world/rules/*.json<br/>game/goals.json"]
        LEVELS["levels/&lt;n&gt;/<br/>entities + rules"]
        CFG["scene.json · screens.json<br/>hud.json · ui/input.json<br/>audio/cues.json"]
    end

    subgraph SHARED["③ SHARED LIBS — data/ (TRACKED, all games)"]
        direction LR
        LIBS["shapes.json · meshes.json<br/>sounds.json · lib/manifest.json"]
    end

    subgraph ENGINE["④ ENGINE — scripts/engine/*.gd · primitives + interpreter · NO game code"]
        BOOT["coordinators/world_boot<br/>+ world_loader"]
        WORLD["core/world<br/>_process · _physics_process"]
        SCHED["core/phase_scheduler<br/>4-phase tick loop"]
        STORES["stores/ + entities dict<br/>RelationStore · SpatialIndex · ZoneStore"]
    end

    subgraph RENDER["⑤ RENDER + UI — read state, never mutate"]
        direction LR
        R3D["renderer_3d<br/>entity_mesh_3d · ground_renderer<br/>multimesh_director · grass_renderer"]
        UI["ui/game_shell · screen_flow<br/>overlay · hud_builder · minimap"]
    end

    VIEW["🖵 Viewport / player"]
    INPUT["⌨ Input source<br/>OS · scripted · stdio (ADR 0060)"]

    SKILLS --> ENT & RULES & LEVELS & CFG
    ENT & RULES & LEVELS & CFG --> BOOT
    LIBS --> BOOT
    BOOT --> WORLD --> SCHED --> STORES
    STORES --> R3D & UI
    R3D --> VIEW
    UI --> VIEW
    INPUT --> WORLD
    VIEW -. player reacts .-> INPUT

    classDef c fill:#e8f4ff,stroke:#3b82f6,color:#000
    classDef e fill:#fff4e6,stroke:#f59e0b,color:#000
    classDef r fill:#e8ffe8,stroke:#22c55e,color:#000
    classDef a fill:#f3e8ff,stroke:#a855f7,color:#000
    class ENT,RULES,LEVELS,CFG,LIBS c
    class BOOT,WORLD,SCHED,STORES e
    class R3D,UI r
    class PITCH,SKILLS a
```

---

## 2. The seven primitives (ADR 0001)

Everything in a Yume game decomposes into these. No class hierarchy — an
Entity is just a dict; distinctions emerge from Tags + properties + Relations.

```mermaid
flowchart LR
    subgraph DATA["Data primitives"]
        ENTITY["① Entity<br/>id · tags · properties<br/>state · position"]
        TAG["② Tag<br/>string membership label"]
        REL["⑦ Relation<br/>typed directed edge<br/>from → to"]
    end

    subgraph LOGIC["Rule = ③ trigger + query + effect"]
        TRIG["④ Trigger (WHEN)<br/>tick · contact · signal<br/>input · spawn · despawn<br/>relation_changed"]
        QUERY["⑥ Query (WHICH)<br/>tags_all/none + state<br/>+ radius + relations"]
        EFFECT["⑤ Effect (WHAT)<br/>state_set · spawn · remove<br/>velocity_set · relate · emit…"]
    end

    TRIG --> QUERY --> EFFECT
    EFFECT -->|mutates| ENTITY
    EFFECT -->|creates| REL
    QUERY -->|filters by| TAG
    QUERY -->|reads| ENTITY
    ENTITY -.has many.-> TAG

    classDef p fill:#fff4e6,stroke:#f59e0b,color:#000
    class ENTITY,TAG,REL,TRIG,QUERY,EFFECT p
```

---

## 3. Boot sequence — `world_boot.run()`

What happens between launch and the first tick. Most phases no-op when the
relevant ADR's JSON file is absent, so mounting everything is safe.

```mermaid
flowchart TB
    START["scene .tscn loads<br/>World node enters tree"] --> RESOLVE["resolve data_root<br/>from cmdline / export var"]
    RESOLVE --> MOUNT["_mount_default_directors()<br/>auto-create 14 sibling Nodes"]
    MOUNT --> LOAD["world_loader.load()<br/>glob entities/*.json + rules/*.json<br/>merge defs by id (last wins)"]
    LOAD --> SEED["_apply_world_seed_from_scene<br/>(deterministic RNG seed)"]
    SEED --> SPAWN["spawn_manager<br/>instantiate initial_instances<br/>+ apply pattern scatter"]
    SPAWN --> REG["scheduler.register_rules()<br/>+ topo-sort (before/after)"]
    REG --> FLUSH["flush_effects()<br/>initial spawns/relations commit"]
    FLUSH --> READY["World.start()<br/>tick loop begins"]

    MOUNT -.creates.-> DIRS["GameShell · ScreenFlow · OverlayManager<br/>SettingsManager · LightingDirector<br/>PartyDirector · ScheduleDirector<br/>LifecycleDirector · ClassManager<br/>FactionDirector · TechTreeDirector<br/>DynastyDirector · NameplateRenderer<br/>ScreenSmokeRunner"]

    classDef e fill:#fff4e6,stroke:#f59e0b,color:#000
    classDef d fill:#ffe8e8,stroke:#ef4444,color:#000
    class START,RESOLVE,MOUNT,LOAD,SEED,SPAWN,REG,FLUSH,READY e
    class DIRS d
```

---

## 4. The tick loop — the engine's heartbeat (`phase_scheduler.tick()`)

**This is the most important diagram.** The 4-phase order + the flushes
between them explain most of the schema-discipline rules in
`.claude/rules/data-demo.md`. Verified against `core/phase_scheduler.gd:tick()`.

```mermaid
flowchart TB
    subgraph FRAME["FRAME RATE — core/world.gd::_process(delta)"]
        POLL["_poll_input()<br/>InputRegistrar reads Input singleton<br/>→ scheduler.queue_input(action, {actor})"]
        FREEZE{"screen_freeze_world<br/>or overlay_freeze?"}
        ACC["accumulate delta<br/>_tick_due() ?"]
        POLL --> FREEZE
        FREEZE -->|frozen| SKIP["skip poll<br/>(modal open)"]
        FREEZE -->|live| ACC
    end

    ACC -->|tick due| TICK

    subgraph TICK["ONE TICK — scheduler.tick() · rules run in JSON definition order (before/after topo-sorted)"]
        direction TB
        LOD["_compute_lod_anchor()<br/>cache active-actor pos once (ADR 0017)<br/>→ all LOD rules read this value"]

        subgraph PH1["PHASE 1 · input — apply what was done"]
            direction TB
            P1["_phase_input()<br/>drain input_queue (deduped action+actor)<br/>fire trigger:input rules · bind self=actor"]
            FL1["flush_effects() ← commit"]
            DR1["drain signals → visible in decide"]
            P1 --> FL1 --> DR1
        end

        subgraph PH2["PHASE 2 · decide — choose what to do"]
            direction TB
            P2["_phase_decide()<br/>fire trigger:tick rules (interval-gated)<br/>+ trigger:signal rules<br/>read state, QUEUE effects (AI, spawn, sync)"]
            FL2["flush_effects() ← commit"]
            DR2["drain signals → react"]
            FL3["flush_effects() ← extra commit<br/>signal-rule effects land BEFORE react reads"]
            P2 --> FL2 --> DR2 --> FL3
        end

        subgraph PH4["PHASE 4 · react — respond to the new reality"]
            direction TB
            P4A["_phase_react()<br/>fire trigger:contact rules<br/>pair-match a,b within radius (once_per_a)"]
            P4B["+ trigger:relation_changed / spawn / despawn<br/>reaction rules read POST-COMMIT state<br/>(positions + flags already updated)"]
            FL4["flush_effects() ← commit"]
            P4C["signals emitted here are NOT drained now —<br/>persist in env.signal_buffer →<br/>surface in NEXT tick's PHASE 1 input"]
            P4A --> P4B --> FL4 --> P4C
        end

        LOD --> PH1 --> PH2 --> PH4
    end

    subgraph PHYS["FRAME RATE — _physics_process / ground_constraint"]
        MOVE["character_body_runner<br/>CharacterBody3D.move_and_slide()<br/>reads state.velocity (Vector2→Vector3)"]
    end

    PH4 --> MUT["mutated entity state<br/>(in stores · single source of truth)"]
    MUT --> MOVE
    MOVE --> POS["position advances<br/>continuously between ticks"]
    POS --> REND["renderers read state<br/>next frame → screen"]
    P4C -.signal_buffer carries across ticks.-> POLL

    note["NOTE: 'commit' is not a 4th rule-loop —<br/>PHASES const = [input, decide, commit, react];<br/>'commit' = the flush_effects() write-buffer drain.<br/>Within a phase ALL rules read the same snapshot,<br/>queue effects, then commit together → no<br/>read-after-write hazards, fully deterministic."]

    classDef f fill:#e0f2fe,stroke:#0284c7,color:#000
    classDef t fill:#fff4e6,stroke:#f59e0b,color:#000
    classDef p fill:#e8ffe8,stroke:#22c55e,color:#000
    classDef r4 fill:#ffe4f0,stroke:#db2777,color:#000
    class POLL,FREEZE,ACC,SKIP f
    class LOD,P1,FL1,DR1,P2,FL2,DR2,FL3 t
    class P4A,P4B,FL4,P4C r4
    class MOVE,POS,REND p
```

**Phase 4 (react) in detail — why it's its own phase:**
- It runs **after** commit, so it reads the world *as it now is*: positions
  advanced, flags set, spawns/removes already applied. A `contact` rule asking
  "is A touching B?" needs the post-commit positions, not the pre-tick ones.
- It fires the *reactive* trigger types: `contact` (pair-matched `a`/`b` in a
  radius, optional `once_per_a`), `relation_changed`, and post-commit
  `spawn`/`despawn` reactions.
- Its emitted signals **do not** drain this tick — they sit in
  `env.signal_buffer` and become input-phase signals **next** tick. That one
  rule is what makes multi-tick chains possible (react → next input → decide …).

**Why the whole ordering matters (each maps to a real `data-demo.md` rule):**
- input **before** decide → "sync-derived fields used as filters must be
  pre-initialized" (a decide-phase sync rule hasn't run at tick 1's input).
- the extra `flush_effects()` before react → a decide/signal rule's flag is
  visible to a react `contact` rule (the sokoban wall-blocks-push fix, cited in
  `phase_scheduler.gd` — without it boxes pushed through walls).
- react signals → **next** tick's input → multi-tick signal chains.

---

## 5. Effect application — `effect_apply.gd` + `core/effects/`

Effects are the only thing that mutates state. They're queued during a phase,
then committed in a `flush_effects()` in JSON definition order. The verb set is
fixed and split across modules by concern.

```mermaid
flowchart LR
    RULE["Rule fires<br/>(query matched)"] --> RESOLVE["effect_resolution<br/>resolve bindings + formulas<br/>(core/formula.gd)"]
    RESOLVE --> DISPATCH{"effect type"}

    DISPATCH --> CORE["effect_core<br/>state_set · state_add · state_mul<br/>state_clamp · spawn · remove · relate"]
    DISPATCH --> MOTION["effect_motion<br/>velocity_set · velocity_add<br/>velocity_add_relative · teleport"]
    DISPATCH --> ACTOR["effect_actor<br/>switch_actor · switch_class<br/>set_policy"]
    DISPATCH --> SHELL["effect_shell<br/>transition_screen · transition_level<br/>save_state · screen_fade · show_toast"]
    DISPATCH --> ADR["effect_adr_extensions<br/>zone ops · faction · dynasty · tech"]

    CORE & MOTION & ACTOR --> BUF["write buffer<br/>(applied on flush)"]
    SHELL --> DIRS["→ Directors / UI<br/>(GameShell, ScreenFlow)"]
    ADR --> STORES2["→ stores (Zone/Relation)"]
    BUF --> ENT["entities dict<br/>state mutated"]

    classDef e fill:#fff4e6,stroke:#f59e0b,color:#000
    class RULE,RESOLVE,DISPATCH,CORE,MOTION,ACTOR,SHELL,ADR,BUF,ENT,DIRS,STORES2 e
```

---

## 6. Input path + ADR 0060 deterministic I/O (as built)

The pluggable-source contract. Per the ADR 0061 implementation note, ADR 0060
unified input at the **poll/queue seam** (`queue_input`), not at synthesized
`InputEvent`s — so every source converges where `_poll_input` would queue.

```mermaid
flowchart TB
    subgraph SOURCES["Input SOURCES (pluggable)"]
        OS["OS hardware<br/>→ InputEvent → Input singleton"]
        STDIO["stdio_step_driver (--stdio-step)<br/>read JSON {actions:[…]} from stdin"]
        STEP["step_runner / scenario_runner<br/>(scripted tests, capture)"]
    end

    SEAM["⟐ THE MERGE SEAM<br/>scheduler.queue_input(action, {actor})<br/>(dedup per action+actor per tick)"]

    OS -->|_poll_input reads pressed state| SEAM
    STDIO -->|inject batch| SEAM
    STEP -->|inject| SEAM

    SEAM --> TICK["scheduler.tick()<br/>PHASE 1 input fires rules"]
    TICK --> STATE["entity state mutated"]

    subgraph EMIT["OBSERVE — partitioned channels (the wall)"]
        HASH["io/determinism_hash<br/>canonical_state_hash()<br/>id-sorted · keys-sorted · %.6f"]
        STATECH["STATE channel → --state-fd<br/>JSON snapshot + hash<br/>(HARNESS ONLY)"]
        FRAMECH["FRAME channel → --frame-file<br/>raw RGBA get_data()<br/>(AGENT ONLY)"]
    end

    STATE --> HASH --> STATECH
    STATE --> FRAMECH

    STATECH --> HARNESS["Python harness / oracle.py<br/>reward · determinism · eval"]
    FRAMECH --> AGENT["AI agent<br/>policy(pixels) → actions"]
    AGENT -.actions next tick.-> STDIO

    LOCK["io/lockstep_core + lockstep_driver<br/>(ADR 0061 multiplayer — reuses this seam<br/>+ per-tick hash exchange = desync detector)"]
    SEAM -.peer inputs.-> LOCK
    LOCK -.-> SEAM

    classDef s fill:#e0f2fe,stroke:#0284c7,color:#000
    classDef seam fill:#fef08a,stroke:#ca8a04,color:#000
    classDef o fill:#e8ffe8,stroke:#22c55e,color:#000
    classDef m fill:#ffe8e8,stroke:#ef4444,color:#000
    class OS,STDIO,STEP s
    class SEAM seam
    class HASH,STATECH,FRAMECH,HARNESS,AGENT o
    class LOCK m
```

---

## 7. Two generation pipelines (DON'T mix on one folder)

```mermaid
flowchart TB
    subgraph DESIGN["/yume-design — makes a GAME"]
        D1["prose pitch"] --> D2["GDD (game-designer)"]
        D2 --> D3["reviewer · planner · level<br/>systems · rules · content"]
        D3 --> D4["asset-designer"]
        D4 --> D5["qa-tester (headless + VQA)"]
        D5 --> DOUT["data/demo_&lt;name&gt;/<br/>full game: entities, rules,<br/>goals, screens, audio"]
    end

    subgraph SCENE["/yume-create-scene — makes a 3D WORLD"]
        S1["scene pitch + class catalog"] --> S2["hero ref → orthographic"]
        S2 --> S3["semantic map + heightmap"]
        S3 --> S4["extract → compose_world"]
        S4 --> S5["compose_shell (walkable)<br/>+ optional Tripo assets"]
        S5 --> SOUT["data/demo_&lt;name&gt;/<br/>3D scene + presentation shell"]
    end

    WARN["⚠ OVERLAPPING OUTPUT FILES<br/>running both on the same folder<br/>= they clobber each other"]
    DOUT -.-> WARN
    SOUT -.-> WARN

    classDef a fill:#f3e8ff,stroke:#a855f7,color:#000
    classDef w fill:#ffe8e8,stroke:#ef4444,color:#000
    class D1,D2,D3,D4,D5,DOUT,S1,S2,S3,S4,S5,SOUT a
    class WARN w
```

---

## 8. Engine module map (the actual `scripts/engine/` tree)

```mermaid
flowchart TB
    subgraph CORE["core/ — the interpreter"]
        C["world · phase_scheduler · entity<br/>rule · query · formula · effect_apply<br/>engine_error · scripted_policy"]
        CE["core/effects/<br/>core · motion · actor · shell<br/>resolution · adr_extensions"]
    end

    subgraph COORD["coordinators/ — boot + lifecycle"]
        CO["world_boot · world_loader · spawn_manager<br/>actor_manager · character_body_runner<br/>ground_renderer · ground_constraint<br/>grass_renderer · physics_body_builder<br/>level_transition · save_load · world_reset<br/>variant_overlay"]
    end

    subgraph DIR["directors/ — ADR subsystems (auto-mounted)"]
        DD["lighting · schedule · party · faction<br/>dynasty · class_manager · tech_tree<br/>lifecycle · animation (+translator)<br/>multimesh · chunk_streamer"]
    end

    subgraph IO["io/ — input + persistence + ADR 0060/0061"]
        II["input_registrar · capture_runner<br/>save_state · audio_bus<br/>determinism_hash · stdio_step_driver<br/>lockstep_core · lockstep_driver"]
    end

    subgraph UIG["ui/ + ui/widgets/ — Godot Control exposure"]
        UU["game_shell · screen_flow · overlay<br/>control_factory · settings_manager<br/>nameplate · minimap_widget<br/>camera_director · hud_builder<br/>viewmodel · win_lose · bounds"]
    end

    subgraph ST["stores/ + libs/ + util/"]
        SS["stores: relation · spatial_index · zone<br/>libs: lib_resolver · macro_expander<br/>mesh_lib · shape_lib<br/>util: pathfinding · grid_snap · vec3<br/>instance_patterns · build_validators"]
    end

    CORE --> COORD --> DIR
    CORE --> IO
    DIR --> UIG
    CORE --> ST

    classDef e fill:#fff4e6,stroke:#f59e0b,color:#000
    class C,CE,CO,DD,II,UU,SS e
```

---

## Legend

| Color | Meaning |
|---|---|
| 🟦 Blue | JSON content (per-game, gitignored) |
| 🟧 Orange | Engine — primitives + interpreter (no game logic) |
| 🟩 Green | Renderers / observe — read state, never mutate |
| 🟪 Purple | Authoring pipelines (offline) |
| 🟥 Red | Directors / multiplayer / warnings |
| 🟨 Yellow | The input merge seam |

**Source of truth:** `docs/guideline/30_framework_primitives.md` (the contract).
**Verified against:** `godot/scripts/engine/` tree, 2026-05-31.
