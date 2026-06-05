# ADR 0021 — Yume as JSON layer over Godot + external capabilities

_Date: 2026-05-06_
_Status: **accepted**_
_Type: foundational architectural commitment_

## Context

Through accumulated discussion (entries 27-28, ADRs 0014-0020), the
project has converged on a clearer architectural framing than the
original "Yume = JSON-driven game engine" pitch. This ADR codifies
the framing as a foundational commitment, sitting alongside ADR 0001
(seven primitives) as durable architecture.

The framing emerged from a specific exchange (2026-05-06) where the
question "can Yume support continuous physics like CALVIN/LIBERO?"
revealed that the answer depends on what "support" means:

- **No**, Yume engine should not REIMPLEMENT continuous physics in
  GDScript / JSON formulas. Performance is hopeless; numerical
  stability is decades of solver tuning; primitive set bloats.
- **Yes**, Yume content can DECLARE physics scenes that delegate to
  Godot's built-in physics engine (or external tools via IPC). The
  JSON declares; Godot computes.

The same pattern applies to many domains: animation, pathfinding,
particles, advanced audio, ML inference, networking. Each is a
specialized capability where:

- A specialized tool already exists (Godot's built-in subsystem, or
  an external library)
- Reimplementing in JSON would be massively worse on performance,
  stability, and ecosystem grounds
- The DECLARATIVE PART (scene config, parameters, references) is
  natural in JSON
- The COMPUTATIONAL PART (numerical methods, solvers, native code)
  belongs in the specialized tool

This generalizes Yume's relationship with the platform. Yume is NOT
a self-contained engine that reimplements every gamedev capability.
Yume is a **JSON-declarative layer that orchestrates Godot + external
tools to produce games**.

## Decision

Adopt the following architectural commitment:

> **Yume is the JSON layer over Godot + external capabilities. The
> engine layer interprets JSON and orchestrates platform / external
> tools to deliver capabilities. Yume content authors (humans or
> LLMs) write only JSON; Yume engine + Godot + external integrations
> deliver the runtime.**

### Layer responsibilities

| Layer | Owns | Yume's discipline |
|---|---|---|
| **Game content** (per-game JSON) | Entities, rules, layouts, physics scenes, behaviors, narrative, economy — everything game-specific | Pure JSON. No per-game GDScript. Authored by humans or LLMs. |
| **Yume engine** (GDScript) | Interpreters: read JSON, dispatch to Godot + external tools, expose state back to rules | Fixed primitive vocabulary; bounded growth; each new capability via ADR. |
| **Godot platform** | Physics, rendering, audio, input, animations, pathfinding, scene graph, GPU/CPU | Yume EXPOSES Godot's existing capabilities; never reimplements. |
| **External tools** (via IPC, ADR 0020) | LLMs, RL agents, specialized solvers, ML models | Yume orchestrates via wire protocol; never bundles. |

### Operational consequences

1. **Adding a capability = an ADR that exposes Godot/external
   subsystem through JSON-declarative primitives.**
   - Godot has a `RigidBody3D` + joints + constraint solver →
     ADR proposes `godot_rigidbody` tag + `physics` config block
     that maps to it. Yume engine instantiates the Godot node;
     reads back state into entity state; rules can drive forces.
   - Same pattern for: animations (`AnimationPlayer`),
     pathfinding (`NavigationServer`), particles, lighting, etc.

2. **Yume engine never reimplements platform capabilities.** If
   Godot does it, Yume exposes it. If Godot doesn't and we need it,
   we either:
   - Add the capability to Godot upstream (rare; Godot is maintained
     by others), OR
   - Implement at minimum complexity in Yume engine (rare; per
     Invariant #8, must be a primitive, not genre-specific)

3. **Yume engine never bundles external tools.** External tools
   (LLM clients, ML runtimes, physics simulators we don't already
   have in Godot) are integrated via IPC (per ADR 0020 pattern) —
   user installs / configures the tool; Yume orchestrates.

4. **The engine roadmap becomes a 'capability exposure' list.**
   Each ADR exposes ONE Godot subsystem or external tool. The set
   grows with games' needs but each addition is bounded.

### How this refines existing invariants

**Invariant #1 (JSON-only content channel)** holds AND becomes more
ambitious. Not just "rules are JSON" — every game-specific decision
is JSON: physics scenes, animation states, audio routing, dialog,
all of it. Engine layer maps JSON to platform/external. Authors
never leave JSON.

**Invariant #8 (engine = primitives + interpreter)** holds with
refinement. Yume's primitives now include "expose Godot capability
X" as a primitive shape. The vocabulary grows via ADR; compositions
stay in JSON. Performance comes from delegating to native Godot or
specialized tools, not from optimizing interpreted JSON dispatch.

**The never-list (ADR 0015)** is REFINED: "Yume engine WILL NEVER
REIMPLEMENT [physics features X]. Yume CONTENT CAN USE [physics
features X] when an ADR exposes Godot's or an external tool's
implementation through JSON." See ADR 0015 § Refinements.

### How existing ADRs fit this framing

- **ADR 0014 (open-world)**: chunked-world streaming. Yume engine
  reads chunk JSON, instantiates Godot scene tree per chunk. Pure
  fit.
- **ADR 0015 (vehicle physics)**: arcade Newtonian collision IS
  Yume engine code (small surface). Coexists with future ADRs
  that expose Godot's full physics for games that need it.
- **ADR 0016 (multi-actor)**: actor management is engine
  orchestration; route input through Godot's InputMap. Fit.
- **ADR 0017 (spatial-LOD)**: rule scheduling optimization in
  Yume engine itself. No platform delegation needed. Fit.
- **ADR 0018 (in-process policies)**: scripted JSON policies are
  Yume's own primitive; godot_resource policies use Godot's
  RefCounted scripts. Fit.
- **ADR 0019 (macros)**: JSON-only authoring abstraction. Pure
  fit; doesn't touch platform.
- **ADR 0020 (external IPC)**: explicitly the "external tools"
  layer. Pure fit.

### Implementation pattern for "expose Godot capability X" ADRs

Each capability-exposure ADR follows a consistent shape:

1. **Identify the Godot subsystem** (physics: PhysicsServer3D +
   RigidBody3D + joints; animation: AnimationPlayer; etc.)
2. **Define JSON declaration shape** (tags, properties, config
   blocks)
3. **Specify engine translation logic** (instantiate Godot nodes
   from JSON; read state back; route effects/inputs through)
4. **Bound the surface** (which Godot APIs we expose; which we
   intentionally don't)
5. **Document author guidance** (skill files explaining when to
   use this capability)

Subsequent ADRs in this lineage:
- **ADR 0022** (future) — Godot rigid-body physics integration
  (replaces the never-list workaround for manipulation games)
- **ADR 0023** (future) — Godot animation system integration
- **ADR 0024** (future) — Godot pathfinding (NavigationServer)
- **ADR 0025** (future) — Godot particles + advanced VFX
- **ADR 0026** (future) — Godot advanced audio (buses, effects)
- **ADR 0027** (future) — Godot character body / kinematic motion
- (build reactively; ADR when the first game needs it)

## Consequences

**Enables:**
- Yume games can have any capability Godot supports (physics,
  animation, advanced rendering, audio mixing, navigation, particles)
- Authors author in JSON; never leave JSON; no GDScript per game
- Performance is native (Godot's C++ physics, not interpreted)
- Ecosystem leverage (Godot's docs, tools, community apply)
- LLMs can generate games using full platform capabilities, not
  just Yume's hand-implemented subset
- Sim2real / robot benchmarks become reachable via physics
  exposure ADR
- The "complete game" ambition (a farming sim quality, open-world-shaped, etc.)
  is technically achievable at gameplay level; performance scales
  via Godot

**Constrains:**
- Yume engine team must DESIGN good JSON declarations for each
  Godot subsystem (not trivial; bad declarations = bad authoring)
- Each capability ADR is real engineering work (~1-3 sessions
  typically)
- The "JSON-over-Godot" coupling means Yume can't trivially port
  to other engines (Unity, Unreal). Acceptable; Godot is the
  platform commitment.

**Doesn't enable:**
- Beating dedicated tools at their own game (Yume + Godot physics
  ≈ Godot games; Yume + PyBullet IPC ≠ PyBullet performance for
  RL research)
- Standalone deployment without Godot (Yume IS a Godot project;
  not a standalone engine)
- LLM-generated content that requires capability X without an
  ADR exposing X first (the capability set is bounded by ADRs;
  growth happens in PRs)

## Alternatives considered

### A. Yume reimplements every capability in GDScript / JSON

This was the implicit position before this ADR. Reject:
performance terrible; primitive set bloats to thousands of items;
loses Yume's "JSON-only" elegance; competes with mature platform
tools.

### B. Yume becomes its own engine (separate from Godot)

Reject: enormous scope expansion; reinvent rendering, physics,
audio, input. Yume's value is the JSON layer, not the engine
underneath.

### C. Yume is platform-agnostic; supports Godot AND Unity AND Unreal

Tempting but premature. Yume currently has ~1 person of effort.
Cross-platform porting would 3-5x the engine surface. Pick one
platform (Godot) and commit. Future: if Yume becomes valuable
enough, port via specifications, not reimplementation.

### D. Yume uses external physics (PyBullet) instead of Godot's

Adds external dependency for a capability Godot already has built
in. Inferior to using Godot's. PyBullet (or MuJoCo) integration
is for cases where Godot's physics is insufficient (sim2real
research with specific solver requirements). That's ADR 0020
territory.

## Performance position (per user direction 2026-05-06)

Performance is explicitly DEFERRED. The architectural commitment is
"correct first; fast eventually." When performance matters:

1. Profile the bottleneck (interpreted JSON dispatch? rule
   matching? observation building?)
2. Identify the hot path
3. Move it to compiled GDScript or native via gdextension
4. Cache, JIT, or precompile JSON-declared structures

These are engineering optimizations, not architectural changes.
The JSON layer's value (LLM-generability, declarative authoring,
content-vs-code split) is preserved through optimization passes.

The "compile games to native code" path is a long-future
optimization — Yume games could eventually export to standalone
Godot projects with all JSON pre-resolved, gaining native
performance for shipping. Not Year 1 work.

## References

- ADR 0001 — Seven primitives + Engine = Primitives + Interpreter
  (foundational; this ADR builds on it)
- ADR 0015 — Vehicle physics primitive (refined never-list per
  this ADR)
- ADR 0020 — External agent IPC (the "external tools" layer
  formalized for one specific case)
- docs/guideline/30_framework_primitives.md — contract doc updated to
  reflect this framing
- docs/timeline/entries/29 — capture of the architectural
  realization moment

## When this ADR's framing applies

This is a CROSS-CUTTING ADR. It applies to:
- Every future ADR proposing engine work — "is this exposing a
  capability or reimplementing one?"
- Every game design that asks "can Yume do X?" — "what platform
  capability would X require, and is there an ADR exposing it?"
- Every skill file — "what JSON does the author write, and what
  does the engine do with it?"

Tech-director uses this ADR as a primary reference when reviewing
future proposals.

## Status

**Accepted** as foundational architectural commitment. Stands
alongside ADR 0001 in shaping all future Yume work.
