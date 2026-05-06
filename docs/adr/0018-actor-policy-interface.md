# ADR 0018 — Actor policy interface (LLM/RL/scripted-agent control)

_Date: 2026-05-06_
_Status: **proposed**_

## Context

ADR 0016 introduces multi-actor architecture. With it, NON-PLAYER
actors can exist — controlled not by keyboard but by some "policy."
This ADR defines the policy INTERFACE: how an external agent (LLM,
RL model, scripted bot, behavior tree) observes the world and emits
actions.

This is the foundation for:

- **LLM-driven NPCs** — Generative Agents / Smallville-style social
  simulations where each NPC has a language-model brain
- **RL agents** — train a model to play Yume games (driving, combat,
  trading)
- **Scripted bots** — testing / playtest automation; sophisticated AI
  beyond what rule-trees can express
- **Hybrid actors** — human player whose actions are augmented or
  shaped by a policy (assist mode, accessibility)
- **Headless agent simulation** — many actors running in parallel in
  a sim (for training data, social-experiment research)

This is core to Yume's Tier 3 vision (Actors). It's also the
foundation for the "simulation input layer" the user has flagged
multiple times.

## Decision

Define a **policy interface** that any actor with `control_mode:
ai_policy` (per ADR 0016) implements. Policies receive observations
+ emit actions; engine routes actions through the same input-effect
pipeline as human inputs.

### Policy interface (conceptual contract)

```
class Policy:
    def observe(env, actor_id, observation_config) -> Observation
    def decide(observation, actor_state) -> List[Action]
```

Where:

- `Observation` = a Dictionary describing what the actor "sees" —
  nearby entities (filtered by tags + radius), recent events
  (signals fired), world state, the actor's own state
- `Action` = a Dictionary matching the existing input event shape —
  `{action: "move_north", actor_id: <self>}` or
  `{action: "fire", actor_id: <self>}`

### Implementation paths

**Path A: Built-in scripted policies (in JSON)**

```jsonc
// policies/guard_basic.json
{
  "type": "scripted",
  "rules": [
    {
      "id": "patrol",
      "if": {"distance_to_player_gt": 200},
      "then": [{"action": "move_to_waypoint"}]
    },
    {
      "id": "alert",
      "if": {"distance_to_player_lt": 100, "world.player_visible": 1},
      "then": [{"action": "fire", "target": "player"}]
    }
  ]
}
```

The engine has a built-in scripted-policy interpreter. No external
dependency. Good for in-game NPC AI.

**Path B: External LLM policy (via process / file IPC)**

```jsonc
// policies/llm_npc.json
{
  "type": "external",
  "transport": "stdio",
  "command": ["python3", "policies/llm_brain.py"],
  "tick_rate_hz": 1.0,        // LLM thinks once per second; faster
                              // = more cost
  "observation_template": "policies/templates/observation.txt"
}
```

The engine forks a process per actor (or pools them). Sends
observation as JSON over stdin; reads action JSON from stdout.

**Path C: External RL agent (via shared memory / ZMQ)**

```jsonc
// policies/rl_driver.json
{
  "type": "external",
  "transport": "zmq",
  "endpoint": "tcp://localhost:5555",
  "tick_rate_hz": 60.0,        // every tick
  "observation_template": "policies/templates/driving_obs.txt"
}
```

For RL training, latency matters. ZMQ or shared-memory IPC.

**Path D: In-process Godot Resource policy**

```jsonc
{
  "type": "godot_resource",
  "script": "policies/behavior_tree_v1.gd"
}
```

Allows GDScript-based policies for performance-critical AI (NPC
crowd) without IPC overhead.

### File layout

```
data/<game>/
├── policies/                   # NEW
│   ├── guard_basic.json
│   ├── llm_npc.json
│   ├── templates/
│   │   ├── observation.txt
│   │   └── driving_obs.txt
│   └── ...
└── ...
```

Per-game policies. Engine ships generic interpreters per type
(scripted, external-stdio, external-zmq, godot-resource).

### Engine work

1. `scripts/engine/actor_policy.gd` — abstract interface + dispatch
   to type-specific implementations
2. `scripts/engine/policies/scripted_policy.gd` — Path A interpreter
3. `scripts/engine/policies/external_stdio_policy.gd` — Path B; spawns
   subprocess, JSON over stdin/stdout
4. `scripts/engine/policies/external_zmq_policy.gd` — Path C; ZMQ
   integration (Godot has a ZMQ binding via gdextension)
5. Per-actor observation builder: takes the actor's perception_config
   (radius, tags-of-interest, recent-event window) and serializes
   relevant env state to JSON

6. Action injection: policy returns JSON action; engine validates
   shape + queues via `scheduler.queue_input(action, params,
   actor_id)` (per ADR 0016)

7. Rate limiting: policies can run at different frequencies than the
   engine tick. Slow policies (LLM, 1Hz) cache their last action and
   the engine reuses it between policy refreshes.

### Backward compat

Existing demos work unchanged. No actor opts into ai_policy without
ADR 0016 + this ADR; policies are opt-in via the per-actor config in
`actors.json`.

### Observation config

The per-policy observation shape needs to be configurable. Yume
should NOT hardcode "every policy gets the same view." Instead:

```jsonc
{
  "perception": {
    "self": ["state.hp", "state.position", "state.inventory"],
    "nearby_radius": 200,
    "nearby_tags": ["npc", "player", "enemy"],
    "nearby_fields": ["state.position", "state.hp", "tags"],
    "recent_signals": 10,    // last N signals across entities
    "world_state": ["day", "weather", "score"]
  }
}
```

Engine builds the observation Dictionary from this config + current
env state, serializes to JSON, sends to policy.

## Consequences

**Enables:**
- LLM-driven NPCs (Smallville / Generative Agents)
- RL training pipelines (agent + Yume sandbox)
- Scripted bots for testing / playtest automation
- Mixed-control actors (player input + AI override)
- Multi-agent simulation experiments (econ, social, combat)
- Foundation for an LLM-first game-design loop
  (game generates itself by querying agents)

**Constrains:**
- IPC adds latency. LLM calls = 100ms-2s. Engine must accept
  asynchrony (policy returns null this tick, engine reuses last
  action).
- Observation serialization costs CPU. At many-actor scale, observation
  building is significant.
- External policies require external dependencies (Python, ZMQ, etc).
  Yume engine doesn't bundle these; ship example policies but require
  user to install runtime.

**Doesn't enable:**
- Frame-perfect physics-aware policies — RL needs sub-tick observations;
  Yume tick is the granularity. Acceptable for arcade/strategy genres,
  not for fighting games.
- Cross-Yume-instance multi-agent (training many sims in parallel) —
  would need separate harness; out of scope for this ADR.

## Alternatives considered

### A. Hardcode behavior trees in engine

Reject: violates Invariant #1 + locks AI shape.

### B. Make policies a JSON-only thing (no external)

Limited expressiveness. LLM drivers fundamentally need external
process; can't simulate language model in pure JSON.

### C. Engine ships its own LLM brain

Out of scope; Yume is engine + content, not AI infrastructure. Let
users plug in their preferred backend.

## References

- ADR 0016 (multi-actor) — prerequisite
- Tier 3 (Actors) — this ADR is the implementation
- yume-actor-policy-designer skill (future) — design discipline for
  policy types + observation configs
- Smallville / Generative Agents paper — reference architecture
- task_plan.md "simulation input layer" — earlier flag, now formal

## Tech-director review

_Date: 2026-05-06_
_Reviewer: yume-tech-director_

### Invariant checks

| Invariant | Status | Notes |
|---|---|---|
| #1 JSON-only content channel | ⚠ | scripted policies are JSON; godot_resource path is GDScript per game (path D); external paths require non-Yume code |
| #2 No semantic effect types | ✓ | actions are existing input events |
| #3 No entity-class hierarchy | ✓ | policies are config + interpreter, not classes |
| #5 Queries first-class | ✓ | observation builder uses existing query mechanisms |
| #8 Engine = primitives + interpreter | ⚠⚠ | external IPC adds significant engine surface — see verdict |

### Major concern: scope conflation

This ADR conflates TWO distinct concerns:

**Concern A: In-process actor policies**
- Path A (scripted JSON) — pure JSON, in-process. Clean.
- Path D (godot_resource) — GDScript per game. Borderline Invariant #1
  but defensible (it's at the actor-AI layer, not game-rule layer).

**Concern B: External agent IPC**
- Path B (stdio subprocess) — spawns external process per actor.
- Path C (ZMQ) — adds ZMQ dependency, networking layer.

Concern A is bounded engine work. Concern B is a NEW DEPENDENCY
SURFACE — Yume currently has zero network/process integration.
Adding both at once is scope creep.

Specific risks of B+C:
- Subprocess management: lifecycle, deadlock, error propagation,
  cleanup on quit. Each is non-trivial.
- ZMQ adds a build-time dependency (gdextension or similar).
- Cross-platform support (Windows/Mac/Linux subprocess differs).
- Security: external policy can do anything its host process can.
- Performance: serialization + IPC + LLM call = 100ms-2s. Engine
  must handle async; current architecture is sync-tick.

### Concerns specific to this ADR

1. **Where does Yume's responsibility end?** ADR doesn't draw the
   line clearly. Recommend explicit:
   - Yume engine MUST: define observation/action protocol, route
     between actor and policy, handle policy unavailability gracefully.
   - Yume engine SHOULD NOT: ship LLM clients, ZMQ broker, RL
     environment wrappers, sample policies.

2. **Action staleness on async policies**. ADR mentions "engine
   reuses last action." But if policy says "move north" 3 ticks ago
   and the world has changed (wall in the way), should engine
   re-validate? Or trust the policy? Spec needed.

3. **Observation serialization cost**. At many-actor scale (100+ AI
   NPCs, each observing 50 nearby entities), observation building
   dominates CPU. ADR doesn't budget this.

4. **Recommendation: split this ADR**. Two ADRs:
   - **0018 (this) — In-process actor policies**: Paths A + D only.
     Scripted JSON + godot_resource. Bounded engine work (interpreter
     + GDScript dispatch). Sufficient for: multi-protagonist games,
     scripted bots, behavior trees. Most use cases.
   - **0020 (future) — External agent IPC**: Paths B + C.
     Subprocess + ZMQ. Land when first LLM/RL game is queued, not
     speculatively. Allows separate scope review.

### Verdict

**revise**.

Recommendation: SPLIT this ADR. The in-process subset (Paths A + D)
is acceptable as ADR 0018. The external subset (Paths B + C) becomes
a future ADR (0020 — External Agent IPC) gated separately.

Reasons:
1. External IPC is a major dependency surface deserving its own
   tech-director gate.
2. Most use cases (multi-protagonist, scripted NPC AI, behavior
   trees) work with in-process policies. External IPC is an
   advanced feature.
3. Scope discipline: don't commit to ZMQ + subprocess management
   speculatively. Wait for the first real game that needs it.
4. The architectural insight (observation/action protocol) is the
   same; only the transport differs. Land transport-specific work
   when needed.

If user wants ALL paths in this ADR, the conditions are:
- Explicit "Yume MUST / SHOULD NOT" responsibility statement
- Action staleness spec
- Observation budget
- Subprocess lifecycle spec (start, error, kill, cleanup)
- ZMQ dependency declared in build docs
- Sample reference impls in tests, not engine

But splitting is the cleaner answer.
