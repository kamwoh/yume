# ADR 0018 — In-process actor policy interface (scripted + godot_resource)

_Date: 2026-05-06_
_Status: **accepted with conditions addressed (2026-05-06)**_
_Note: ORIGINAL DRAFT INCLUDED EXTERNAL IPC PATHS (B+C); split per
tech-director review. External IPC moved to ADR 0020._

## Context

ADR 0016 introduces multi-actor architecture. With it, NON-PLAYER
actors can exist — controlled not by keyboard but by a **policy**.
This ADR defines the IN-PROCESS policy interface: scripted JSON
policies + GDScript-resource policies. External-process policies
(LLM/RL via subprocess or ZMQ) are deferred to ADR 0020 to keep
this ADR's scope bounded.

This is the foundation for:

- **Multi-protagonist control** — switch between Michael / Trevor /
  Franklin; non-active characters keep doing things via scripted
  policies (continue patrol; idle at cover)
- **Scripted NPC AI** — guards patrol; shopkeepers stand at counter;
  enemies pursue / retreat per behavior tree
- **In-game bots** — testing / playtest automation; advanced AI
  beyond what rule-trees can express but still in-process
- **Behavior trees** — godot_resource path lets games ship
  GDScript-based BT implementations

External-process LLM agents (Smallville-style), RL training pipelines,
and ZMQ-driven external clients ALL move to ADR 0020.

## Decision

Define a **policy interface** that any actor with `control_mode:
ai_policy` (per ADR 0016) implements. Policies receive observations,
emit actions; engine routes actions through the same input-effect
pipeline as human inputs.

### Policy interface (conceptual contract)

```
Policy.observe(env, actor_id, observation_config) -> Observation
Policy.decide(observation, actor_state) -> List[Action]
```

Where:

- `Observation` = a Dictionary describing what the actor "sees" —
  nearby entities (filtered by tags + radius), recent events
  (signals fired), world state, the actor's own state
- `Action` = a Dictionary matching the existing input event shape —
  `{action: "move_north", actor_id: <self>}`

### Two in-process paths

**Path A: Scripted JSON policies**

```jsonc
// policies/guard_basic.json
{
  "type": "scripted",
  "rules": [
    {
      "id": "patrol",
      "if": {"distance_to": {"target": "@waypoint_a", "gt": 50}},
      "then": [{"action": "move_to_waypoint", "waypoint": "@waypoint_a"}]
    },
    {
      "id": "alert",
      "if": {
        "all": [
          {"distance_to": {"target": "active_actor", "lt": 100}},
          {"world_state": {"player_visible": 1}}
        ]
      },
      "then": [{"action": "fire", "target": "active_actor"}]
    }
  ]
}
```

The engine has a built-in scripted-policy interpreter — think of it
as a stripped-down rule engine specifically for actor decision-making.
Pure JSON; no external dependency. Good for in-game NPC AI at the
80% case.

**Path B: Godot Resource policies**

```jsonc
// policies/behavior_tree.json
{
  "type": "godot_resource",
  "script": "res://policies/behavior_tree_v1.gd"
}
```

```gdscript
# policies/behavior_tree_v1.gd
extends RefCounted
class_name BehaviorTreeV1

func decide(observation: Dictionary, actor_state: Dictionary) -> Array:
    # Game-specific behavior tree implementation
    if observation.has("player_visible"):
        return [{"action": "fire", "target": "active_actor"}]
    return [{"action": "patrol"}]
```

For performance-critical AI (crowds with sophisticated behaviors)
where the scripted-JSON interpreter is too slow, OR for behavior-
tree libraries that exist as GDScript code already.

This path uses GDScript per game, which is at the EDGE of Invariant #1
(JSON-only content channel). Justified because:
- It's at the AI/policy layer, not the game-rule layer (rules still
  pure JSON)
- Existing GDScript libraries (e.g. behavior trees) shouldn't be
  reimplemented
- Tech-director explicitly approved this path with the scoping (in-
  process only; doesn't compose with per-game rule-implementation
  GDScript)

### File layout

```
data/<game>/
├── policies/                   # NEW
│   ├── guard_basic.json        # scripted
│   ├── behavior_tree_v1.gd     # godot_resource
│   ├── templates/              # observation templates if shared
│   └── ...
└── ...
```

### Engine work

1. `scripts/engine/actor_policy.gd` — abstract dispatcher
2. `scripts/engine/policies/scripted_policy.gd` — Path A interpreter
3. `scripts/engine/policies/godot_resource_policy.gd` — Path B
   loads GDScript at runtime, calls `decide()`

4. Per-actor observation builder: takes the actor's
   `observation_config` (from actors.json) and serializes relevant
   env state to a Dictionary (not JSON string — in-process; pass by
   reference)

5. Action injection: policy returns Array of Action Dictionaries;
   engine validates + queues via `scheduler.queue_input(action,
   params, actor_id)` (per ADR 0016)

6. Per-policy tick rate: actors.json declares `policy_tick_rate_hz`
   (default = 20Hz, matching engine tick). Slower policies (LLM in
   ADR 0020) cache their last action between policy refreshes.

### Observation config

The per-policy observation shape is configurable on the actor:

```jsonc
// actors.json (per ADR 0016)
{
  "actors": [
    {
      "id": "guard_npc_A",
      "control_mode": "ai_policy",
      "policy_ref": "policies/guard_basic.json",
      "observation_config": {
        "self": ["state.hp", "state.position", "state.weapon"],
        "nearby_radius": 200,
        "nearby_tags": ["player", "enemy", "ally"],
        "nearby_fields": ["state.position", "state.hp", "tags"],
        "recent_signals": 10,
        "world_state": ["day_of_week", "alarm_level"]
      },
      "policy_tick_rate_hz": 5.0
    }
  ]
}
```

Engine builds the observation Dictionary from this config + current
env state, passes to policy. Same shape across both Paths A and B.

### Backward compat

Existing demos work unchanged. Actors with `control_mode: "ai_policy"`
require ADR 0016 (multi-actor) which itself is backward-compatible
via synthesized-default. Without explicit AI actors, no policy code
runs.

## Yume's responsibility — explicit boundary

**Yume engine MUST**:
- Define the observation/action protocol
- Build observations from env state per config
- Route actions through the existing input-effect pipeline
- Handle policy unavailability gracefully (last-action fallback)

**Yume engine SHOULD NOT**:
- Ship reference implementations of complex AI (BT libraries, planners,
  pathfinding) — that's content
- Force policies to follow a particular paradigm (rules, tree, FSM)
  beyond the observe/decide contract
- Require all policies to handle all observation features —
  policies opt into what they consume

## Consequences

**Enables:**
- Multi-protagonist games where non-active actors keep doing things
- In-game NPC AI more flexible than rule-trees (Path B)
- Scripted bots for testing
- Foundation for ADR 0020 (external IPC) — same observe/decide
  protocol, different transport

**Constrains:**
- Path B's GDScript surface is per-game code in the data folder —
  edge of Invariant #1
- Policies are stateless from engine's POV (engine doesn't track
  policy internal state); policies that need persistent state
  (e.g. last-decision memory) must store it in entity state

**Doesn't enable:**
- LLM agents (ADR 0020 — external IPC)
- RL training (ADR 0020)
- Cross-process / networked policies (ADR 0020)

## Alternatives considered

### A. Skip in-process; only do external IPC

External IPC has 100ms-2s latency. Unusable for in-game NPC AI
(crowds, guards). In-process must come first.

### B. Engine ships a built-in BT library as a primitive

Locks games into one BT shape. Better to ship the policy interface
and let games build their own BT (or use scripted JSON, or load a
GDScript BT lib).

### C. Make Path B JSON-only (not GDScript)

Already exists as Path A (scripted). If author needs more power,
GDScript is the escape valve. Forcing all logic into JSON would
push complexity into a new DSL we'd then maintain.

## Revisions per tech-director review (2026-05-06)

This ADR has been REVISED per TD review. Original draft included
external IPC paths (subprocess, ZMQ); those moved to ADR 0020 to
keep this ADR's scope bounded.

### Test plan

1. **Scripted policy fires action**: actor with scripted policy +
   simple "always move north" rule; tick advances; actor entity's
   position changes.
2. **Godot resource policy loads**: actor with godot_resource
   policy; engine loads + invokes; action dispatched.
3. **Observation correctness**: observation Dictionary contains
   correct nearby entities, world_state values, recent signals.
4. **Action staleness**: policy_tick_rate_hz: 1 (1Hz); engine ticks
   at 20Hz; policy decides every 20 ticks; cached action reused
   between.
5. **Existing demos unchanged**: sokoban / harvestcore / etc. don't
   use ai_policy control_mode; their tick + scenario tests pass
   identically post-implementation.

### Final verdict

**Status: accepted (post-split).**

External IPC concerns (subprocess management, ZMQ dependency,
async latency, security) are EXCLUDED from this ADR — see ADR 0020.

## References

- ADR 0016 (multi-actor) — prerequisite
- ADR 0020 (external agent IPC) — companion ADR for LLM/RL/external
- Tier 3 (Actors) — this ADR + ADR 0020 together implement
- yume-actor-policy-designer skill (future) — design discipline
