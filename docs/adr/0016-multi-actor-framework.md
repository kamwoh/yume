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

## Tech-director review

_Date: 2026-05-06_
_Reviewer: yume-tech-director_

### Invariant checks

| Invariant | Status | Notes |
|---|---|---|
| #1 JSON-only content channel | ✓ | actors.json is content |
| #2 No semantic effect types | ✓ | switch_actor / queue_input_for_actor are mechanical, not semantic |
| #3 No entity-class hierarchy | ✓ | actors are config records, not classes |
| #5 Queries first-class | ✓ | actor entity lookup via existing tag/id mechanisms |
| #8 Engine = primitives + interpreter | ✓ | adds dispatch layer; doesn't add new effect vocabulary beyond switch_actor + queue_input_for_actor |
| #9 Phase ordering | ⚠ | switch_actor mid-tick semantics underspecified |

### Concerns

1. **Backward compat creates dual code paths**. ADR proposes "if
   actors.json absent, fall back to legacy actor_tag." Two paths =
   maintenance debt. Every change to input handling must consider
   both. Better path: at world load, if actors.json absent, the
   engine SYNTHESIZES a default actors.json with one actor pointing
   to the actor_tag-tagged entity. Then there's only ONE code path.

2. **`input_actions_press` location underspecified**. Currently lives
   on the World scene as @export. ADR says "each actor has its own
   input_actions_press config" but doesn't say where. Either:
   (a) per-actor in actors.json, or (b) global with actor-routing
   based on input device. Pick one explicitly.

3. **switch_actor mid-tick semantics**. If a rule fires
   `switch_actor` during a tick, do subsequent input rules in the
   SAME tick route to the new actor or the old? Need spec. Recommend:
   take effect at next tick boundary (consistent with other state
   changes that flush at phase boundaries).

4. **Camera follow on switch**. ADR mentions camera follows
   active_actor. But camera config lives in scene.json (asset-designer
   owns it per ADR 0009 reorg). When active actor changes,
   does the camera config change? Or is "follow active_actor" a
   camera mode that adapts automatically? Likely the latter —
   add `camera.mode: follow_active_actor` as the new mode.

5. **Per-actor state location**. GTA-style multi-protag has separate
   inventories. ADR doesn't show how. Two options:
   (a) per-entity state with naming convention (player_main.hp,
   player_alt.hp); (b) per-actor state slot in world_state
   (world.actors.player_main.hp). Recommend (a) — entity-tied state
   is the natural place. Document this.

6. **Migration path for existing demos**. Sokoban / harvestcore use
   actor_tag = "player". After this ADR lands, what migration is
   required? Per concern #1: synthesized default actors.json means
   ZERO migration. Confirm + document.

### Verdict

**accept-with-conditions**.

Conditions before implementation:

1. **Replace dual-code-path with synthesized-default**. If
   actors.json absent, engine constructs one in memory at load:
   single actor pointing to actor_tag entity. Single code path.
2. **Spec input_actions_press location**: per-actor in actors.json
   (recommended; allows per-character control schemes).
3. **Spec switch_actor timing**: takes effect at next tick boundary,
   not mid-tick.
4. **Add `camera.mode: follow_active_actor`** as part of this ADR
   or coordinate with asset-designer skill update.
5. **Spec per-actor state**: lives on the entity that the actor
   controls; multi-actor games use distinct entities per character.
   No new "per-actor state slot" needed.
6. **Migration confirmation**: explicit "zero migration required for
   existing demos" statement.
7. **Test plan**: scenario tests for (a) switch_actor at tick N
   takes effect at tick N+1; (b) input route change after switch;
   (c) camera reframe after switch.

Foundational ADR; depends on nothing; gates ADRs 0014, 0017, 0018.
Should land first if user approves all six.
