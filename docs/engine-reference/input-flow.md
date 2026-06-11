# Input flow — player vs AI (input-parity architecture)

_Last updated: 2026-06-11_

Every input source — keyboard, JSON-rule AI, scripted policy, remote net
peer — converges on the same scheduler queue and is consumed identically.
The ONLY data-level difference is the `synthesized: true` flag the AI
paths attach, and **nothing in the engine reads it** (verified 2026-06-11).
This is why possession (human taking over an AI actor) is a pure-JSON
change: the consumer can't tell who pressed the button.

```mermaid
flowchart TD
    subgraph Producers["Producers — the ONLY place sources differ"]
        KB["Human keyboard<br/>input_registrar.gd:290/314<br/>polls Input.is_action_pressed /<br/>is_action_just_pressed per frame"]
        AI["AI via JSON rules<br/>queue_input_for_actor effect<br/>effect_actor.gd:50"]
        SP["AI via scripted policy (ADR 0018)<br/>actor_manager.gd:315<br/>_queue_actions_for_actor"]
        NET["Remote net peers<br/>net_driver.gd:713"]
    end

    KB -- "{actor: active_actor_id}" --> Q
    AI -- "{actor: rule's actor_id,<br/>synthesized: true}" --> Q
    SP -- "{actor: policy's actor_id,<br/>synthesized: true}" --> Q
    NET -- "{actor: peer's entity}" --> Q

    Q["PhaseScheduler.queue_input()<br/>phase_scheduler.gd:187<br/>input_queue: Array (drained per tick)"]

    Q --> DRAIN

    DRAIN["_phase_input()<br/>phase_scheduler.gd:292<br/>matches input rules by ACTION NAME only —<br/>never inspects synthesized"]

    DRAIN --> RULES["input-trigger rules (JSON)<br/>context binds 'actor' to the<br/>event's actor param"]

    RULES --> FX["effects mutate state<br/>(e.g. autorace input_accel:<br/>state_set actor.speed)"]

    FX --> TICK["downstream tick rules read state<br/>(e.g. car_drive: velocity from<br/>speed + yaw — doesn't know or care<br/>who pressed accel)"]

    style Q fill:#2d6a4f,color:#fff
    style DRAIN fill:#2d6a4f,color:#fff
    style Producers fill:none,stroke:#888,stroke-dasharray: 5 5
```

## Reading the diagram

- **Differentiation lives at the producer call sites, not the consumer.**
  Four producers, one queue, one drain. An AI press and a human press are
  the same event shape by construction.
- **`synthesized: true`** is written by the two AI paths and consumed
  nowhere. Params are flattened into the rule context, so a rule *could*
  filter on it (anti-bot gate, input-source telemetry) — today unused.
- **The `actor` param is what routes control.** Keyboard events carry
  ActorManager's `active_actor_id` (switch via the `switch_actor` effect,
  ADR 0016); AI events carry whatever `actor_id` the rule passed (autorace
  uses `self.state.me`). Four cars can all "press accel" in one tick —
  same action, different actor binding.
- **Possession is pure JSON**: mute the AI's press rules for one entity
  (per-entity state flag in their queries) + `switch_actor` at it. See
  `demo_autorace/world/rules/01_drive.json` for the canonical
  discrete-controller layout (`ai_sense` → `ai_press_*` →
  shared `input_*` handlers → `car_drive` transmission).
