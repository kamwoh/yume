# ADR 0016 — Multi-actor framework (actor as configurable, not singleton)

_Date: 2026-05-06_
_Status: **proposed**_

## Context

Yume's input system currently assumes ONE actor. The world has an
`actor_tag` (default `"player"`); input rules find the entity with
that tag and dispatch the input to it. This works for single-player
games but fails for:

- Multi-protagonist games (GTA's 3 characters; Trails of Cold Steel
  party switching)
- Couch co-op (two players, two entities)
- Multi-agent sandboxes where each NPC has its own perception+action
  loop (LLM-driven NPCs, RL agents — Tier 3 dream)
- Games where the player can possess different units (RTS, certain
  puzzle games)

The current `actor_tag` mechanism is hardcoded singleton; refactoring
it to a multi-actor architecture is the foundation for all of the
above.

## Decision

Promote the actor concept to a first-class binding: `world.active_actor_id`
identifies the currently-controlled entity. Multiple "actor profiles"
can exist; the active one receives keyboard/gamepad input. Other
actors can be controlled by:

- Other input devices (gamepad 2 in couch co-op)
- AI policies (behavior rules + perception)
- LLM agents (ADR 0018 — actor policy interface)

### Schema additions

`world/state.json`:
```jsonc
{
  "state": {
    "active_actor_id": "player_main",
    "actor_profiles": ["player_main", "player_alt", "guard_npc_A"]
  }
}
```

Or a per-game `actors.json` (cleaner separation):
```jsonc
{
  "actors": [
    {
      "id": "player_main",
      "input_device": "keyboard",
      "control_mode": "human",
      "starting_entity_tag": "michael"
    },
    {
      "id": "player_alt",
      "input_device": "gamepad_2",
      "control_mode": "human",
      "starting_entity_tag": "trevor"
    },
    {
      "id": "guard_npc_A",
      "input_device": null,
      "control_mode": "ai_policy",
      "policy_ref": "policies/guard_basic.json"
    }
  ],
  "active_actor_id": "player_main"
}
```

### Engine work

1. `scripts/engine/actor_manager.gd` — new module:
   - Loads `actors.json` (or falls back to legacy single-actor mode
     if absent)
   - Maintains active_actor_id
   - Routes input from each device to its bound actor
   - Maintains per-actor perception state (what entities are nearby,
     what just happened) — used by ADR 0018 policies

2. Input rule resolution change:
   - Currently: `input_actions_press` polled; if action fires, find
     entity with `actor_tag` and dispatch
   - New: each actor has its own `input_actions_press` config; the
     one with `control_mode: human` reads physical input; others
     receive synthesized input from policies
   - Action rule: `query.actor_id` field optional; default = active
     actor

3. Camera follow:
   - Camera follows `active_actor_id`'s entity by default
   - "Switch character" = state_set on `world.active_actor_id`
   - Camera mode (ADR 0011 screens layer / scene config) can opt
     into `follow_active_actor` instead of fixed entity

4. Per-actor input queue:
   - Each actor has its own queue of actions
   - Existing `scheduler.queue_input(action, params)` extended to
     `queue_input(action, params, actor_id)`

5. Input rule trigger schema:
   ```jsonc
   {"type": "input", "action": "fire", "actor": "player_main"}
   // optional "actor" field; default = active actor
   ```

### Backward compat

Existing demos work unchanged. If `actors.json` is absent, the engine
falls back to the legacy `actor_tag` mechanism (singleton player).
Demos opt into multi-actor by adding the file.

### New effect types

```jsonc
{"type": "switch_actor", "target_id": "player_alt"}
// Sets active_actor_id; camera + input route to new actor

{"type": "queue_input_for_actor", "actor_id": "guard_npc_A",
 "action": "move_north"}
// Sends synthesized input to a non-human actor
// (foundation for AI policies in ADR 0018)
```

## Consequences

**Enables:**
- Multi-protagonist games (GTA / Trails / Live A Live)
- Couch co-op (split-screen renderer is a separate concern)
- AI-driven NPCs that "play" their own entity via policies
- Foundation for ADR 0018 (LLM/RL actor policies)
- Mode switching (player can possess different units)

**Constrains:**
- Per-actor state must be authored carefully — easy to forget
  "this rule reads active_actor's HP, not all players' HP"
- Input device bindings are config; gamepad detection is Godot's
  problem (engine integration)
- Camera = singleton (one rendered viewport per screen). Split-screen
  is a future concern.

**Doesn't enable:**
- Networked multiplayer (out of scope; no networking layer)
- True simultaneous control of multiple actors by one human (could
  be done via ai_policy synthesizing input, but feels artificial)

## Alternatives considered

### A. Stay singleton; multi-protagonist via "swap entity tags"

Could implement protagonist switching as "rename the player tag from
michael to trevor" each switch. Hacky; breaks if multiple protagonists
need to coexist (e.g. one is in a cutscene while another is gameplay).

### B. Multiple "input bus" abstraction without actor_id concept

Could let games have multiple input buses without explicit actors.
But every multi-input use case needs to know "who's the actor" for
camera + perception + AI. Actor abstraction is the right layer.

### C. Make actor management entirely content-driven

`actors.json` IS content-driven; engine just interprets. ✓

## References

- ADR 0011 (screens) — pause menu can show actor switcher UI
- ADR 0014 (open-world) — chunk streaming follows active actor's
  position
- ADR 0017 (spatial-LOD scheduling) — uses active actor for "near
  player" criteria
- ADR 0018 (actor policy interface) — depends on this; can't have
  AI-driven actors without multi-actor framework
- Tier 3 (Actors) — this ADR is the foundation
