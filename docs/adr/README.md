# Architecture Decision Records (ADRs)

ADRs document **load-bearing decisions** for Yume: choices that shape
the engine, primitive set, or pipeline in ways that downstream code +
content depend on.

Format: `NNNN-short-title.md` — zero-padded sequence, kebab-case title.
Sequence is by chronology of acceptance.

Status: `proposed` / `accepted` / `superseded by ADR-MMMM`.

> **Note on file paths in older ADRs.** The engine was later reorganized from a
> flat `scripts/engine/*.gd` layout into subdirectories (`core/ · coordinators/
> · directors/ · io/ · ui/ · stores/ · libs/ · util/ · qa/`). ADRs written
> before that move (roughly 0001–0043) reference flat `scripts/engine/X.gd`
> paths — the **filenames are still correct**, but the directory is now one of
> those subdirs. For the authoritative current tree see
> [`../guideline/33_architecture.md`](../guideline/33_architecture.md) §8 and
> the README "Engine file map".

## When to write an ADR

- **Adding a primitive** to the contract (e.g., `Plan` or `Knowledge`
  in Tier 3) → ADR.
- **Changing tick semantics** (e.g., adding a 5th phase) → ADR.
- **Renaming or removing a vocabulary item** (effect type, query
  operator) → ADR.
- **Strategic pivots** (e.g., the W5.0 review's "promote renderer_3d"
  decision) → ADR.
- **Schema changes** to data files (entities/rules/shapes) that break
  existing demos → ADR.

## When to NOT write an ADR

- Bug fixes that restore documented behavior — just fix it.
- Adding a new demo (`data/demo_<name>/`) — it's content, not architecture.
- Adding new content (entities, rules, shapes) within existing schema.
- Test additions.
- Doc clarifications that don't change semantics.

## Index

| ID | Title | Status | Date |
|---|---|---|---|
| [0001](./0001-seven-primitives.md) | Seven primitives + Engine = Primitives + Interpreter | accepted | 2026-04-22 |
| [0002](./0002-renderer-agnostic-entity.md) | Entity extends Node (renderer-agnostic) | accepted | 2026-05-01 |
| [0003](./0003-harness-engineering-tier-26.md) | Harness engineering as Tier 2.6 | accepted (in-flight) | 2026-05-01 |
| [0004](./0004-blocks-motion-tag.md) | blocks_motion tag | accepted | 2026-05-03 |
| [0005](./0005-raycast-hit-effect.md) | raycast_hit effect | accepted | 2026-05-03 |
| 0006 | Multi-level architecture | accepted | 2026-05-04 |
| 0007 | Complex collision + GLB assets | accepted | 2026-05-04 |
| 0008 | _(unused — slot reserved during sequencing; no decision needed)_ | — | — |
| 0009 | World/game/flow separation | accepted | 2026-05-05 |
| [0010](./0010-save-load-persistence.md) | Save/load persistence | accepted (TD review) | 2026-05-06 |
| [0011](./0011-declarative-screen-flow.md) | Declarative screen flow → Godot Control exposure | accepted (refactored under ADR 0021) | 2026-05-06 |
| [0012](./0012-tutorial-overlay-primitive.md) | Tutorial overlay primitive | accepted | 2026-05-06 |
| [0013](./0013-settings-schema-and-config.md) | Settings schema + config | accepted | 2026-05-06 |
| [0014](./0014-open-world-foundational-substrate.md) | Open-world foundational substrate | accepted (conditions resolved) | 2026-05-06 |
| [0015](./0015-vehicle-physics-primitive.md) | Vehicle physics primitive (+ never-list anchor) | accepted (conditions resolved) | 2026-05-06 |
| [0016](./0016-multi-actor-framework.md) | Multi-actor framework | accepted (conditions resolved) | 2026-05-06 |
| [0017](./0017-spatial-lod-rule-scheduling.md) | Spatial-LOD rule scheduling | accepted (conditions resolved) | 2026-05-06 |
| [0018](./0018-actor-policy-interface.md) | In-process actor policy interface | accepted (conditions resolved) | 2026-05-06 |
| [0019](./0019-rule-plugin-macro-layer.md) | Rule plugin / macro layer | accepted (conditions resolved) | 2026-05-06 |
| [0020](./0020-external-agent-ipc.md) | External agent IPC (split from 0018) | proposed — deferred until first dependent game | 2026-05-06 |
| [0021](./0021-yume-as-json-layer-over-platform.md) | **Yume = JSON layer over Godot + external** (foundational) | accepted | 2026-05-06 |
| 0022 | _(unused — slot reserved for "physics through Godot collision" refactor; not yet drafted. ADRs 0004 + 0005 carry the legacy hand-rolled approach in the meantime.)_ | — | — |
| 0023 | _(unused — slot reserved during sequencing; no decision needed)_ | — | — |
| [0024](./0024-npc-pathfinding.md) | NPC pathfinding via NavigationServer3D | accepted (shipped) | 2026-05-07 |
| [0025](./0025-day-night-cycle.md) | Day/night cycle exposed via scene.json lighting block | accepted (shipped) | 2026-05-07 |
| [0026](./0026-party-member-primitive.md) | Party-member primitive (leashed NPCs) | accepted (shipped) | 2026-05-07 |
| [0027](./0027-cross-game-json-reuse-system.md) | Cross-game JSON reuse (`@lib.X` + `$extends`) | accepted (conditions addressed) | 2026-05-08 |
| [0028](./0028-cross-game-parameterized-templates.md) | Cross-game parameterized templates (`$params`) | proposed — deferred until first dependent game | 2026-05-08 |
| [0029](./0029-schedule-primitive.md) | Schedule primitive (NPC daily routines at scale) | proposed — Aldenmere Phase 1 BLOCKING | 2026-05-09 |
| [0030](./0030-class-primitive.md) | Occupation/class primitive (switchable, per-class HUD/verbs) | proposed — Aldenmere Phase 2 unlocks | 2026-05-09 |
| [0031](./0031-zone-state-primitive.md) | Aggregated zone-state primitive (macro-economy substrate) | proposed — Aldenmere Phase 3 unlocks | 2026-05-09 |
| [0032](./0032-faction-primitive.md) | Faction primitive (politics, alliances, war) | proposed — Aldenmere Phase 3 unlocks | 2026-05-09 |
| [0033](./0033-tech-tree-primitive.md) | Technology-tree primitive (knowledge accumulation across NPCs + generations) | proposed — Aldenmere Phase 4 unlocks | 2026-05-09 |
| [0034](./0034-dynasty-primitive.md) | Dynasty / heir succession (player ages, dies, heir takes over) | proposed — Aldenmere Phase 4 unlocks | 2026-05-09 |
| [0035](./0035-animation-primitive.md) | Animation primitive (declarative skeletal/piece-level mesh animation) | accepted — implementation realigned by ADR 0046 (2026-05-17) | 2026-05-09 |
| [0036](./0036-lifecycle-aging.md) | Lifecycle / aging primitive (every entity born → grows → ages → dies) | proposed — Aldenmere schema in Phase 1, mechanics Phase 2 | 2026-05-09 |
| [0037](./0037-dynamic-structure-placement.md) | Dynamic structure placement (player/NPC builds shelter; collision-validated) | proposed — Aldenmere Phase 1 BLOCKING | 2026-05-09 |
| [0038](./0038-grid-based-placement.md) | Grid-based structure placement | accepted | 2026-05-09 |
| [0039](./0039-step-runner-scenario-tests.md) | StepRunner-based scenario tests | accepted | 2026-05-10 |
| [0040](./0040-camera-relative-wasd.md) | Camera-relative WASD movement | accepted | 2026-05-10 |
| [0041](./0041-multimesh-static-decoration.md) | MultiMeshInstance3D for static decoration batching | accepted | 2026-05-11 |
| [0042](./0042-procedural-generation-primitives.md) | Procedural-generation primitives (umbrella ADR) | proposed — deferred until first dependent game | 2026-05-11 |
| [0043](./0043-universal-input-via-lib.md) | Universal input lib via @lib refs | accepted | 2026-05-13 |
| [0044](./0044-physics-via-godot-physicsserver.md) | Physics via Godot PhysicsServer3D (deletes legacy AABB) | accepted | 2026-05-13 |
| [0045](./0045-motion-via-godot-characterbody.md) | Motion via Godot CharacterBody3D | accepted | 2026-05-14 |
| [0046](./0046-animation-via-godot-animation-player.md) | Animation via Godot AnimationPlayer (Phase A code-drawn + Phase B .glb) | accepted (shipped) | 2026-05-17 |
| [0047](./0047-world-state-as-engine-entity.md) | world_state as `_engine` singleton entity's state | accepted | 2026-05-15 |
| [0048](./0048-velocity-add-relative-auto-reset.md) | velocity_add_relative auto-resets per sim-tick | accepted | 2026-05-16 |
| [0049](./0049-engine-rules-as-content.md) | engine_rules — express always-on engine behaviors as JSON rules | accepted | 2026-05-16 |
| [0050](./0050-frame-tick-trigger.md) | frame_tick trigger — content-authored per-frame behaviors | accepted | 2026-05-16 |
| [0051](./0051-authoring-time-python-emitters.md) | Authoring-time Python emitters (yume_codegen + yume_assetgen) | accepted | 2026-05-17 |
| [0052](./0052-shader-as-visual-primitive.md) | visual.shader — entity-level shader as visual primitive | accepted | 2026-05-17 |
| [0053](./0053-tripo3d-animation-pipeline.md) | Tripo3D animation pipeline (rig + retarget, all 8 rig types) | accepted | 2026-05-18 |
| [0054](./0054-visual-layout-compiler.md) | Visual layout compiler — image gen → CV extraction → JSON | accepted | 2026-05-19 |
| [0055](./0055-multi-biome-ground-from-semantic-map.md) | Multi-biome ground from the semantic map | accepted | 2026-05-20 |
| [0056](./0056-visual-assertion-library.md) | Visual assertion library + capture-per-test runner | accepted | 2026-05-22 |
| [0057](./0057-yume-visual-tester-skill.md) | yume-visual-tester skill (auto-generated visual test plans) | proposed | 2026-05-22 |
| [0058](./0058-shader-as-json.md) | Shader as JSON (templates + composable primitives) | proposed | 2026-05-23 |
| [0059](./0059-water-surface-from-scene-json.md) | Water surface from scene.json | accepted | 2026-05-26 |
| [0060](./0060-deterministic-pomdp-pluggable-io.md) | Deterministic I/O contract — pluggable input + partitioned observe channels | accepted | 2026-05-30 |
| [0061](./0061-networked-multiplayer-lockstep.md) | Networked multiplayer — input-replicated lockstep | accepted | 2026-05-30 |
| [0062](./0062-trimesh-static-world-mesh.md) | Trimesh collision for static world meshes | accepted | 2026-05-30 |
| [0063](./0063-client-server-multiplayer.md) | Client-server multiplayer (server-authoritative + state replication) | accepted | 2026-06-01 |
| [0064](./0064-data-driven-replication-config.md) | Data-driven replication config (net.json) | accepted | 2026-06-01 |
| [0065](./0065-synced-animation-phase.md) | Synced animation — phase as deterministic sim state | accepted | 2026-06-01 |
| [0066](./0066-record-replay-smooth-render.md) | Record-then-replay for smooth offline net video | accepted | 2026-06-04 |
| [0067](./0067-unified-generation-pipeline.md) | Unified generation pipeline (World / Game / Assets — disjoint-ownership layers) | accepted | 2026-06-06 |

## Cross-ADR review (2026-05-06, batch 0014-0019)

Tech-director cross-cutting analysis of the six ADRs proposed in
the open-world + multi-actor + agents + macros batch:

### Cumulative invariant pressure

Each ADR individually preserves invariants. Cumulatively, they add:

- 6 new engine modules (chunk_streamer, physics_response,
  actor_manager, lod_scheduler-extension, policy_interface,
  macro_expander)
- 5 new content file types (world.json, actors.json, policies/,
  macros.json, plus chunk layout)
- 5 new effect types (apply_impulse, switch_actor,
  queue_input_for_actor, plus 0019 and 0014 derivatives)

Concern: "death by a thousand cuts" on Invariant #8 (engine =
primitives + interpreter). Each new module is interpreter-shaped
(reads JSON, produces effects on existing primitives), so no
individual violation. But the engine's contract surface grows
significantly.

Verdict: not a violation. Tracked.

### Build-order critique

ADR text suggests order:
1. ADR 0019 (macros) — "small, low-risk, immediate benefit"
2. ADR 0016 (multi-actor) — foundational
3. ADR 0017 (spatial-LOD) — perf foundation
4. ADR 0015 (vehicle physics) — independent, parallel
5. ADR 0014 (open-world) — depends on 0016
6. ADR 0018 (actor policy) — depends on 0016

Tech-director recommendation:
1. **ADR 0017 (spatial-LOD) FIRST** — pure optimization, no
   contract change, lowest implementation risk. Provides immediate
   perf benefit to existing demos at scale.
2. **ADR 0019 (macros) SECOND** — clean contract design but rule-
   loader change requires regression tests across all 13 demos.
3. **ADR 0016 (multi-actor) THIRD** — foundational for 0014/0018;
   needs synthesized-default-actors mechanism to avoid dual code paths.
4. **ADR 0015 (vehicle physics) FOURTH** — independent; needs
   "never list" anchor before landing.
5. **ADR 0014 (open-world) FIFTH** — depends on 0016 + 0017; biggest
   surface change; ship after the foundations are validated.
6. **ADR 0018 (actor policy) — SPLIT and DEFER**:
   - In-process subset (Paths A + D) ships as 0018; gated behind
     0016 multi-actor.
   - External IPC subset (Paths B + C) becomes future ADR 0020 when
     first LLM/RL game is queued. Don't speculatively commit to
     subprocess + ZMQ infrastructure.

### Authoring surface explosion

Combined with shell-layer (ADRs 0010-0013, also proposed), authors
gain ~10 new file types to learn:
- save_policy.json, screens.json, tutorial.json, settings_schema.json
  (shell layer)
- world.json, actors.json, policies/, macros.json, chunks/<x>_<y>/
  (this batch)

Plus 5+ new skills to author them. Real cognitive load. Mitigation:
yume-design orchestrator + skills handle most of this for LLM-driven
content; human authors will have a learning curve.

This is not a violation; it's a feature ambition tradeoff. Logged.

### Backward compat patterns

All six ADRs follow the "if file absent, fall back to legacy" pattern.
Acceptable migration discipline. Concern: legacy paths get crufty if
not actively retired. Recommend per-ADR sunset timelines (~2-3 ADR
cycles ≈ 3 months).

### Recommended verdict for the batch

| ADR | Verdict |
|---|---|
| 0014 | accept-with-conditions |
| 0015 | accept-with-conditions (must add "never list") |
| 0016 | accept-with-conditions (synthesize default; single code path) |
| 0017 | accept-with-conditions (hysteresis required) |
| 0018 | revise — SPLIT into in-process (this) + external IPC (future 0020) |
| 0019 | accept-with-conditions (cycle detection + max-expanded-count) |

None blocked outright. Five accept-with-conditions; one needs
splitting before re-review.

If user accepts these conditions, recommended build order above
applies. Tech-director will re-verify on each ADR's implementation
PR.

### Conditions resolution (2026-05-06 update)

User reviewed the TD verdicts and chose to **address all conditions
in-place**. Each ADR now has a "Revisions per tech-director review"
section concretely resolving every condition:

- **0014**: persistent-entity-in-spatial-index spec'd; chunk-size
  unit semantics inherit from renderer; cross-chunk query semantics
  defined; save/load interaction explicit; test plan added.
- **0015**: physics never-list anchored as contract addendum (no
  continuous integration, no constraints, no soft body, no sub-tick
  CCD, no tire grip, no aerodynamics); impulse-based semantics;
  performance budget; phase ordering; reflection spec; mass>0
  contract.
- **0016**: synthesized-default-actors at load (single code path);
  per-actor input lists in actors.json; switch_actor at flush
  boundary; follow_active_actor camera mode; per-actor state on
  entity; zero migration confirmed; test plan added.
- **0017**: hysteresis (enter_radius < leave_radius); tick_slowed
  state in scheduler; determinism guidance bake into crowd-designer
  skill; lod_anchor_position cached; LOD vs stream-radius
  validation; test plan added.
- **0018**: SPLIT — in-process subset (Paths A+D) accepted as
  ADR 0018; external IPC (Paths B+C) extracted to ADR 0020 as
  deferred-until-needed.
- **0019**: depth ≤ 4 + max-expanded-effects ≤ 50; cycle detection
  at load; load-time-only expansion semantics; per-game scoping;
  automated CI Invariant #2 check; test plan + $param.field
  traversal spec.

All six ADRs now status: **accepted**. ADR 0020 is **proposed
(deferred)** — activates when a game requires external IPC.

Build order remains as recommended:
1. ADR 0017 (spatial-LOD)
2. ADR 0019 (macros)
3. ADR 0016 (multi-actor)
4. ADR 0015 (vehicle physics)
5. ADR 0014 (open-world)
6. ADR 0018 (in-process policies)
7. ADR 0020 (external IPC) — when needed

Implementation start gated on user's go-ahead.

ADRs land alongside the contract change they justify. PR review is the
gate. If a PR's diff materially changes engine vocabulary or pipeline
shape, the reviewer should ask "where's the ADR?"

## Format

```markdown
# ADR NNNN — short title

_Date: YYYY-MM-DD_
_Status: proposed / accepted / superseded by ADR-MMMM_

## Context

Why this decision is being made. What problem, what constraints.
Be specific — capture the situation that forced the choice.

## Decision

What we're doing. One paragraph max.

## Consequences

Positive, negative, neutral. What this enables, what it precludes,
what other things change.

## Alternatives considered

Options A, B, C — and why they weren't chosen.

## References

- Code locations affected
- Related ADRs
- Discussions / reviews
```
