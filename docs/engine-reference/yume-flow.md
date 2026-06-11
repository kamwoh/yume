# Yume — the complete flow

_Last updated: 2026-06-11_

Five diagrams, one per altitude: (1) the big picture, (2) the
`/yume-design` generation pipeline, (3) per-game JSON anatomy + ownership,
(4) boot sequence, (5) the runtime loop. Companion doc:
[input-flow.md](input-flow.md) for the player-vs-AI input pipeline.

---

## 1. Big picture — prose to playable

```mermaid
flowchart LR
    PITCH(["prose pitch<br/>'a roguelike where vampires<br/>steal HP from light sources'"])

    PITCH --> DESIGN["/yume-design<br/>(orchestrator, ADR 0067)"]

    DESIGN --> JSON[("per-game JSON<br/>godot/data/demo_&lt;slug&gt;/<br/>entities · rules · scene ·<br/>hud · screens · audio · levels")]

    JSON --> ENGINE["engine = primitives + interpreter<br/>godot/scripts/engine/<br/>(fixed verb set, zero<br/>game-specific GDScript)"]

    ENGINE --> GAME(["playable game<br/>./scripts/play.sh &lt;slug&gt;"])

    GAME --> QA["QA loop<br/>validators · unit tests ·<br/>scenario tests · visual QA"]
    QA -- "bug found → post-mortem ritual:<br/>fix + harden the owning gate" --> DESIGN

    GODOT["Godot 4.6.1<br/>physics · rendering · UI ·<br/>audio · animation"] -.->|"exposed, never<br/>reimplemented (ADR 0021)"| ENGINE

    style JSON fill:#1d3557,color:#fff
    style ENGINE fill:#2d6a4f,color:#fff
```

**The contract (Invariant #1 + #8):** all game-specific behavior is JSON;
the engine ships seven primitives (Entity, Tag, Rule, Trigger, Effect,
Query, Relation) plus an interpreter. New behavior = compose existing
verbs in JSON, or propose a new primitive via ADR — never bake game logic
into engine code.

---

## 2. Generation pipeline — `/yume-design` and the three layers

```mermaid
flowchart TD
    CMD(["/yume-design '&lt;pitch&gt;'<br/>[--scene] [--with-assets]<br/>[--style] [--name] [--autonomous]"])

    CMD --> P0{"Phase 0: env precheck<br/>API keys present?"}
    P0 -- "key missing → DROP flag,<br/>degrade to code-draw (warn, never crash)" --> GAMELAYER
    P0 -- "--scene + OPENAI_API_KEY" --> WORLD

    subgraph WORLD["WORLD layer (the 3D stage) — compose_world"]
        W1["hero reference image"] --> W2["semantic map + heightmap"]
        W2 --> W3["extract → placements"]
        W3 --> W4["scene.json · flow.json ·<br/>world/state.json ·<br/>levels/level_default/entities.json ·<br/>entities/auto_gen.json ·<br/>assets/{layouts,textures}/"]
    end

    WORLD --> GAMELAYER

    subgraph GAMELAYER["GAME layer (the play) — specialist skills, in order"]
        S1["1 yume-game-designer<br/>→ GDD.md (MDA decomposition)"]
        S2["2 yume-game-reviewer<br/>→ 15-axis depth review<br/>(accept / revise / reject)"]
        S3["3 yume-game-planner<br/>→ world bible (named NPCs,<br/>items, events, schedules)"]
        S4["4 yume-level-designer<br/>→ level-design.md (coordinates)"]
        S5["5 yume-systems-designer<br/>→ world/rules/*.json sketches"]
        S6["6 yume-game-rules-designer<br/>→ hud.json win/lose · game/flow.json"]
        S7["7 yume-content-designer<br/>→ entities/*.json · levels/ · state"]
        S8["8 yume-asset-designer<br/>→ visual.* fields · audio/cues.json ·<br/>ui/strings.json · scene/hud config"]
        S9["9 yume-qa-tester<br/>→ headless cascade run + capture"]
        S1 --> S2 -->|accept| S3 --> S4 --> S5 --> S6 --> S7 --> S8 --> S9
        S2 -.->|revise| S1
    end

    GAMELAYER -->|"--with-assets +<br/>image key + TRIPO_API_KEY"| ASSETS

    subgraph ASSETS["ASSETS layer (the look) — tools.yume_assetgen"]
        A1["scan *_prompt fields in<br/>asset_gen.json"] --> A2["dispatch backends<br/>(openai_images / tripo3d / ...)"]
        A2 --> A3["patch defs in-place with<br/>res:// texture + .glb paths<br/>→ assets/generated/"]
    end

    subgraph SOUL["soul pass (if GDD targets Fellowship / Narrative /<br/>Submission / Discovery / Sensation)"]
        L1["flavor-writer (writing)"]
        L2["asset-designer (visual identity)"]
        L3["audio-designer (BGM/ambience/stings)"]
        L4["juice-designer (kinetic feedback)"]
        L5["rules-designer (reactive density)"]
        L1 ~~~ L2 ~~~ L3 ~~~ L4 ~~~ L5
    end

    GAMELAYER -.->|"5 layers must reinforce<br/>the SAME emotional direction"| SOUL
    ASSETS -->|">5 entities replaced →<br/>composition pass (10 axes)"| DONE
    GAMELAYER --> DONE(["godot/data/demo_&lt;slug&gt;/"])

    style WORLD fill:#264653,color:#fff
    style GAMELAYER fill:#2d6a4f,color:#fff
    style ASSETS fill:#7b2d26,color:#fff
    style SOUL fill:#5a4a7a,color:#fff
```

**Disjoint file ownership** is what lets the three layers compose without
clobbering: each layer writes ONLY its own files (see diagram 3). The one
known clobber: never run `/yume-create-scene` on a `/yume-design` game —
its `compose_shell` overwrites the game's player/movement/camera.

---

## 3. Per-game JSON anatomy — who owns what, who reads what

```mermaid
flowchart LR
    subgraph DATA["godot/data/demo_&lt;name&gt;/"]
        direction TB
        ENT["entities/*.json<br/>defs + initial_instances<br/>(GLOBBED, merged by id)"]
        RULES["world/rules/*.json<br/>feature modules<br/>(GLOBBED)"]
        LEVELS["levels/&lt;n&gt;/entities.json<br/>per-level instances + patterns"]
        SCENE["scene.json<br/>camera · lighting · ground ·<br/>tick_seconds · world_seed"]
        FLOW["game/flow.json<br/>multi-level progression (ADR 0006)"]
        STATE["world/state.json<br/>initial _engine state (ADR 0047)"]
        HUD["hud.json<br/>panels · bindings · win:/lose:"]
        SCREENS["screens.json<br/>title/pause/modals (ADR 0011)"]
        AUDIO["audio/cues.json<br/>signal → SFX/BGM"]
        INPUT["ui/input.json<br/>actions (+ universal include)"]
        SAVE["save_policy.json (ADR 0010)"]
        TUT["tutorial.json (ADR 0012)"]
        SET["settings_schema.json (ADR 0013)"]
        SNAP["_snapshots/<br/>backups — engine NEVER scans"]
    end

    subgraph LIB["godot/data/ (shared, TRACKED)"]
        SHAPES["shapes.json · meshes.json ·<br/>sounds.json"]
        LIBREF["lib/ — @lib.X.Y $include<br/>bundles (WASD, universal input)"]
    end

    LIBREF -- "$include resolves via<br/>lib/manifest.json" --> RULES
    LIBREF --> INPUT

    ENT --> WL["WorldLoader"]
    RULES --> WL
    LEVELS --> WL
    SCENE --> WL
    STATE --> WL
    FLOW --> WL
    HUD --> GS["GameShell"]
    SCREENS --> SF["ScreenFlow"]
    AUDIO --> AB["audio_bus / cue router"]
    INPUT --> IR["InputRegistrar"]
    SAVE --> SS["save_state (ADR 0010)"]
    TUT --> OM["OverlayManager (ADR 0012)"]
    SET --> SM["SettingsManager (ADR 0013)"]

    style DATA fill:#1d3557,color:#fff
    style LIB fill:#264653,color:#fff
```

**Layer ownership (ADR 0067):** World layer owns `scene.json`,
`game/flow.json`, `world/state.json`, `levels/level_default/`,
`entities/auto_gen.json`, `assets/{layouts,textures}/`. Game layer owns
`world/rules/*.json`, `entities/<slug>.json`, `hud.json`, `screens.json`,
`audio/`, `ui/`. Assets layer owns `asset_gen.json`, `assets/generated/`,
and in-place `visual.*` patches. Duplicate def ids across globbed files →
alphabetically-last silently wins (gate: `validate_duplicate_defs.py`).

---

## 4. Boot — `play.sh` to first frame

```mermaid
flowchart TD
    PLAY(["./scripts/play.sh &lt;name&gt; [--capture]"])

    PLAY --> VAL{"validator bank<br/>tools/validators/run_all.py<br/>(~16 validators: stray .gd, lib refs,<br/>rules bindings, screens targets,<br/>spawn templates, position clobber,<br/>mesh y_offset, shader params, ...)"}
    VAL -- "fail (strict mode)" --> STOP(["abort — fix content first"])
    VAL -- pass --> SYNC["sync: cp -r godot/. → $TEMPLATE_DST<br/>(single source of truth for<br/>GODOT_BIN + TEMPLATE_DST)"]

    SYNC --> LAUNCH["$GODOT_BIN --path . scenes/&lt;name&gt;_&lt;dim&gt;.tscn<br/>(thin ~12-line stub: World node +<br/>Camera + data_root + renderer_script)"]

    LAUNCH --> BOOT["WorldBoot (world_boot.gd)"]

    BOOT --> DIR["auto-mount 14 Director nodes:<br/>GameShell · ScreenFlow · OverlayManager ·<br/>SettingsManager · LightingDirector ·<br/>PartyDirector · ScheduleDirector ·<br/>LifecycleDirector · ClassManager ·<br/>FactionDirector · TechTreeDirector ·<br/>DynastyDirector · NameplateRenderer ·<br/>ScreenSmokeRunner"]

    BOOT --> AM["ActorManager.load_or_synthesize<br/>(actors.json or default_player)<br/>→ active_actor_id"]

    BOOT --> WL2["WorldLoader.load_data:<br/>glob entities/*.json + world/rules/*.json,<br/>merge defs by id, spawn initial_instances,<br/>load level (flow.json), seed RNG<br/>(scene.json world_seed)"]

    WL2 --> SPAWN["spawn_manager: per entity —<br/>visual block → mesh/sprite/multimesh<br/>(hidden: true → skip renderer attach);<br/>physics_body_builder: aabb_extents →<br/>auto CharacterBody3D / colliders"]

    DIR --> ENV2["LightingDirector: scene.json lighting →<br/>Sky · Sun · WorldEnvironment<br/>GroundRenderer: ground.mesh → floor<br/>(+ optional biome shader, ADR 0055)<br/>GrassRenderer (opt-in)"]

    BOOT --> SCHED["PhaseScheduler.new(env)<br/>register_rules(all loaded rules)"]

    SPAWN --> READY(["title screen (screens.json)<br/>or straight into sim"])
    ENV2 --> READY
    SCHED --> READY
    AM --> READY

    style VAL fill:#7b2d26,color:#fff
    style BOOT fill:#2d6a4f,color:#fff
```

---

## 5. Runtime — the heartbeat (ADR 0068: sim tick on the physics clock)

```mermaid
flowchart TD
    subgraph FRAME["_process(delta) — display rate"]
        POLL["InputRegistrar polls keys<br/>(hold: every frame · press: edge)<br/>→ scheduler.queue_input<br/>{actor: active_actor_id}"]
        CAM["camera smoothing · HUD refresh ·<br/>nameplates · visual interpolation"]
    end

    subgraph PHYS["_physics_process(delta) — fixed 60Hz"]
        FREEZE{"freeze gate:<br/>modal screen / overlay open?<br/>(ADR 0011/0012)"}
        FREEZE -- frozen --> SKIP["sim paused; Godot anim/<br/>tween/audio continue"]
        FREEZE -- live --> ACC["accumulator += delta<br/>each crossing of tick_seconds<br/>(default 0.0167 = 60Hz) →"]
        ACC --> TICK
        BODIES["character_body_runner:<br/>CharacterBody3D.move_and_slide<br/>per body (ADR 0044/0045) —<br/>velocity from state, position back to state"]
    end

    subgraph TICK["PhaseScheduler.tick() — one sim tick"]
        LOD["cache LOD anchor (ADR 0017)"]
        P1["PHASE 1 — input:<br/>drain input_queue, fire input rules<br/>(match by action name)<br/>→ flush_effects<br/>→ drain signals into decide"]
        P2["PHASE 2 — decide:<br/>ScheduleDirector.tick →<br/>tick rules (interval in TICKS) →<br/>flush_effects →<br/>drain signals into react →<br/>flush_effects (signal effects apply<br/>BEFORE react reads state)"]
        P4["PHASE 4 — react:<br/>contact rules (spatial pair-match) ·<br/>spawn/despawn/relation_changed<br/>→ flush_effects<br/>(react signals → NEXT tick's input)"]
        LOD --> P1 --> P2 --> P4
    end

    subgraph EFX["effect interpreter (effect_apply.gd)"]
        FX1["state_set / state_add / state_clamp ·<br/>spawn / remove / transform / relate ·<br/>velocity_set / velocity_add_relative ·<br/>emit (signal) · show_toast / show_overlay ·<br/>transition_screen / transition_level ·<br/>switch_actor / queue_input_for_actor ·<br/>save_state / load_state · camera_shake ·<br/>particle_emit · set_audio_bus_volume · ...<br/>(full list: api-manifest.json)"]
        FORM["Formula.evaluate — bindings per<br/>trigger type (self · actor · a/b · world)<br/>+ math whitelist"]
        FX1 --- FORM
    end

    subgraph RENDER["renderers (read state, never own it)"]
        R3D["entity_mesh_3d · multimesh_director<br/>(yaw → rotation.y; forward = (-sin, -cos)) ·<br/>animation_director (ADR 0046) ·<br/>chunk_streamer · grass/ground"]
        UI2["GameShell HUD bindings<br/>(world.X / &lt;tag&gt;.X) ·<br/>ScreenFlow · OverlayManager ·<br/>NameplateRenderer · minimap"]
    end

    subgraph NET["net / replay (optional)"]
        ND["net_driver: snapshots @ 20Hz,<br/>interp 0.10s; remote presses →<br/>queue_input {actor: peer entity};<br/>recorded fields WIN over derivation"]
    end

    POLL --> P1
    TICK --> EFX
    EFX -->|"state mutations"| STATE2[("entity state ·<br/>world_state ·<br/>relations · zones")]
    STATE2 --> BODIES
    STATE2 --> RENDER
    NET <--> P1
    NET -.-> STATE2
    AIRULES["AI = tick rules pressing<br/>virtual buttons<br/>(queue_input_for_actor —<br/>see input-flow.md)"] --> P1

    style TICK fill:#2d6a4f,color:#fff
    style EFX fill:#1d3557,color:#fff
    style STATE2 fill:#7b2d26,color:#fff
```

**Clock discipline:** rules + body integration share the physics clock so
they can never skew under load (ADR 0068). The tick is never a balance
knob — scale a rule's `interval` instead. Display-rate work stays in
`_process`; fixed-rate work (move_and_slide, the accumulator) in
`_physics_process`.

---

## 6. QA + hardening loop — how bugs become gates

```mermaid
flowchart LR
    BUILD["content / engine change"] --> GATES

    subgraph GATES["gates, cheapest first"]
        direction TB
        G1["static validators (sync-time,<br/>tools/validators/ — fail play.sh)"]
        G2["unit tests — test_runner.gd<br/>(passed: NN failed: 0)"]
        G3["scenario tests — per-game<br/>tests.json, headless cascade"]
        G4["visual QA — frame the feature →<br/>capture → context-specific Read<br/>(baseline env checks + 3-5<br/>falsifiable criteria)"]
        G5["effect-chain trace — destructive<br/>effects LAST in every on_click chain"]
        G6["yume-visual-designer — 7-axis<br/>art-direction review"]
        G1 --> G2 --> G3 --> G4 --> G5 --> G6
    end

    GATES -- all pass --> SHIP(["ship / commit"])
    GATES -- "user finds a bug anyway" --> PM

    subgraph PM["post-mortem ritual (ALWAYS-ON)"]
        direction TB
        M1["1 fix the bug"] --> M2["2 identify the OWNER —<br/>which skill/rule/validator/test<br/>should have caught it"]
        M2 --> M3["3 harden the gate —<br/>enforceable check, not 'be careful'<br/>(3a: fix the PRIMITIVE,<br/>not the symptom site)"]
        M3 --> M4["4 commit fix + gate together,<br/>citing the empirical case"]
    end

    PM -- "gate added → bug class<br/>blocked forever" --> GATES

    style PM fill:#7b2d26,color:#fff
    style GATES fill:#2d6a4f,color:#fff
```

The ratchet only goes one way: every user-found bug must leave behind a
machine-enforceable gate (validator > test > reviewer axis > prose rule),
so the same bug class can't recur in a future session, game, or pipeline.
