# ADR 0026 — Party-member primitive (leashed NPCs that fight + KO)

_Date: 2026-05-07_
_Status: accepted (shipped — `scripts/engine/party_director.gd`, 2026-05-09)_

## Context

The kingdom-sim merchant game (`docs/games/merchant/GDD.md`) graduates
from a solo-shopkeeper loop in Acts 1-2 into a small-party adventure
in Acts 3-4: the player recruits 2-3 hireable companions who follow
them into dungeons, fight alongside them, and revive at the next town
when knocked out (NOT permanently killed — companions are story
characters, not respawnable mobs).

The existing engine vocabulary covers most pieces:

- **NPC schedules + pathfinding** — ADR 0024 (`pathfind_to` + the
  `walkable_floor` / `pathfinding_obstacle` tags).
- **Per-NPC AI policies** — ADR 0018 (scripted JSON or godot_resource
  policies with observation/decide loop).
- **Combat contact rules** — already work via `contact` triggers +
  tag matching + state mutation.

What's missing is the **leash-and-coordination layer**: a party member
must stay within ~1.5m of the player whether the player walks, runs,
or pathfinds across a dungeon. ADR 0018 actor policies are sufficient
for autonomous NPCs (a guard standing post; a villager going to
market) but introduce surface area we don't need for "follow the
leader" — every party member would need its own observation_config,
its own scripted policy file, its own pathfind-to-player rule. And
critically, ADR 0018 doesn't address **death recovery**: a policy can
set state.hp = 0 just as easily as a contact rule can, and once the
entity is removed, it's gone — there's no "wake up at the next town"
pathway in the current vocabulary.

Per ADR 0021 (Yume = JSON layer over Godot), the question is: are
party members a NEW primitive, or a composition of existing ones?

The answer: mostly a composition (relations + tags + signals already
exist), with two narrow additions:

1. A small **director module** that handles the per-frame leash
   geometry — analogous to `LightingDirector` (ADR 0025) and
   `Pathfinding` (ADR 0024). It reads existing entity state, computes
   target positions, writes them back via `state.position`. Authors
   never write per-frame leash math in JSON.
2. Three **convenience effects** (`party_join`, `party_leave`,
   `party_ko`) that wrap the relation-create + tag-add + state-mutate
   triplets that every party game would otherwise spell out
   manually. Pure sugar over existing primitives — they decompose
   into `relate` + `tag_add` + `state_set` calls, but bundling
   them produces a single declarative verb that content can reach
   for without reinventing the same 6-line effect chain per game.

Combat coordination is intentionally **not** added: existing
`contact` triggers + `attack_pending` state pattern (used by the
player's combat in DoomArena3D) work fine for a party member, given
its `party_member` tag and the same enemy-tag matching the player
uses. The director only handles leashing and KO recovery.

## Decision

### 1. New relation type — `party_member_of`

Standard relation, no engine code (relations are user-defined
strings — see §7 of `docs/guideline/30_framework_primitives.md`). Convention:
`{type: "party_member_of", from: <npc_id>, to: <player_id>}`. The
director scans for entities tagged `party_member` and reads their
single outgoing `party_member_of` edge to find the leash anchor.

### 2. New tag — `party_member`

Engine-recognized in the same sense `walkable_floor` is engine-
recognized: the PartyDirector module scans for it each frame. Adding
or removing the tag toggles leash behavior. Authors never edit
director code; they tag entities.

### 3. Three new effects — `party_join`, `party_leave`, `party_ko`

| Effect | Semantics |
|---|---|
| `party_join` | `{target: <npc>, leader: <player_id>}` — adds tag `party_member`, creates `party_member_of` relation `npc → leader`, sets `state.party_index` to the next free slot (0/1/2…), increments leader's `state.party_count`. |
| `party_leave` | `{target: <npc>}` — removes tag, breaks relation, clears KO flag, sets `state.party_index = -1`. Decrements leader's `party_count` if a relation existed. |
| `party_ko` | `{target: <npc>}` — sets `state.ko = 1`, `state.hp = 1` (so future damage doesn't fire KO again), snaps `state.position` to leader's current position, sets `state.velocity = 0`. The entity remains in `env.entities` so revival can wake it. |

All three are pure compositions of `relate` / `unrelate` / `tag_add`
/ `tag_remove` / `state_set` / `state_add` — they could be hand-
spelled in JSON. Bundling them gives content authors a single verb
per intent and lets the engine document the contract.

### 4. PartyDirector module

`godot/scripts/engine/party_director.gd` — a `Node`, sibling of
`LightingDirector` / `OverlayManager` / `ScreenFlow` under the
universal `play.tscn`.

Per-frame tick (`_process`):

1. For each entity with tag `party_member`:
   - Find its leader via `relations.targets("party_member_of",
     <npc_id>)`. If no leader (0 or >1 results) → skip.
   - Read `state.party_index` (0..N-1). If unset, skip.
   - Compute target position = leader.position + offset(party_index).
     Default offset pattern: index 0 → (-1.0, 0, +1.5), index 1 →
     (+1.0, 0, +1.5), index 2 → (0, 0, +2.5) — fan out behind the
     leader on the XZ plane (Y matches leader for grounded
     gameplay). Pure-3D; 2D demos can override via author convention.
   - Write `state.position = target` (smoothed via lerp toward
     target so movement feels natural, not snap-teleport).
   - If `state.ko == 1`, force position to leader.position
     directly (KO'd companions lie next to leader, no offset).

2. Drain `env.signal_buffer` for any signal named `party_revival`.
   For every emit:
   - For each `party_member`-tagged entity: clear `state.ko`, set
     `state.hp = state.hp_max` (or `properties.hp_max`, fallback
     to current hp).

KO interception is content's job — game/goals.json adds a tick rule:

```jsonc
{
  "id": "party_member_ko_intercept",
  "trigger": {"type": "tick", "interval": 1},
  "query": {"tags_all": ["party_member"], "state": {"hp_lte": 0, "ko_eq": 0}},
  "effect": {"type": "party_ko", "target": "self"}
}
```

The `party_revival` emit is also content's call — typically on
level-enter signals into a `town`-tagged location:

```jsonc
{
  "id": "town_revives_party",
  "trigger": {"type": "signal", "name": "level_enter"},
  "query": {"tags_all": ["world_clock"], "state": {"current_level_eq": "level_town_pendrel"}},
  "effect": {"type": "emit", "signal": "party_revival"}
}
```

This keeps revival policy **in JSON** — different games can revive
at shrines, on time-of-day, on NPC dialogue, etc., by emitting the
same signal. The director just listens.

### 5. Combat coordination — explicitly not in the engine

Per ADR 0021, combat already works through existing `contact`-rule +
tag-matching. A party member uses the same `attack_pending` state
field the player uses; same enemy tags (`hostile`, `enemy`); same
`raycast_hit` or melee-radius rule. The director does not add an
"attack the same target as the player" coordination signal —
that's a content choice (the GDD's adventurer-class table dictates
who attacks who). If a future game needs explicit party-targeting
coordination, it can compose `relate` + signals on top.

### Engine wiring

- `world.gd` does NOT import PartyDirector — the director is a peer
  Node in the scene tree (same as LightingDirector). Adding a
  `[node name="PartyDirector"]` to `play.tscn` is the only scene-
  side change.
- `effect_apply.gd` adds three match-arm dispatches:
  `party_join`/`party_leave`/`party_ko`. Each is a small static
  function that sequences the underlying primitive operations.
- `tests/test_runner.gd` adds three test sections covering the
  three behaviors (join creates relation; leashing offset matches
  expected per-index pattern; KO preserves entity).

## Consequences

### Enables

- 2-3 companions following the player through Acts 3-4 dungeons
  with one tag + one effect per join, no per-game per-frame
  leash code.
- Party members fighting via existing combat rules (no new
  vocabulary) — they share the same contact-rule + state mutation
  pattern as the player.
- KO'd companions visually sitting next to the player (snap-to-
  position) until revival, instead of vanishing — preserves the
  "save them at the next town" narrative beat.
- Revival as a content choice: emit `party_revival` from any rule
  context (level transition, NPC dialogue, item use, time of day).

### Constrains

- Single-leader topology — `party_member_of` points to one anchor.
  Multi-leader RTS-style squads need a different relation pattern
  (deferred to a future ADR if a game wants it).
- The director's offset pattern is hardcoded for 2-3 followers
  on the XZ plane. Larger parties or 2D-only games would override
  via subclassing or extending the director (deferred — kingdom-
  sim's GDD caps party at 3).
- KO recovery is "all party members at once" on `party_revival`
  emit. Selective revival (only one companion wakes) needs content-
  side gating (emit a different signal type) or a future
  `party_revive_one` effect.

### Tests ship with the change

Per `.claude/rules/tests.md`, new primitives land with unit tests:

1. `test_party_join_creates_relation` — `party_join` effect on an
   NPC adds the `party_member` tag, creates the
   `party_member_of` relation, assigns `state.party_index`, and
   increments leader's `state.party_count`.

2. `test_party_leashing_position_follows_player` — director's
   offset helper produces the expected XZ delta for indices
   0/1/2 given a leader position.

3. `test_party_ko_preserves_entity` — `party_ko` effect on an
   entity sets `state.ko=1`, `state.hp=1`, snaps position to the
   leader, and the entity STAYS in env.entities (NOT removed).

## Alternatives considered

**A. Implement party as ADR 0018 actor policies.** Each companion
gets a `policy_ref` pointing to a "follow leader" scripted policy.
Rejected — ADR 0018's strength is per-actor autonomous behavior
(guards on patrols, shopkeepers at counters), and "follow leader"
through that lens needs an observation_config per actor + a scripted
policy with distance-to-leader rules + per-actor tick budget. For
2-3 companions this is more surface area than the leashing problem
warrants. Composing existing primitives (relations + tag + tiny
director) is cheaper.

**B. Add a generic `leash_to` effect** that runs each tick, with
`distance` and `offset` parameters. Rejected — would duplicate the
director's per-frame work as content rules (tick rate is at most
20Hz in our tickrate, which makes leash motion feel laggy at higher
framerates; per-frame `_process` is smoother). The director is the
right scope for per-frame interpolation.

**C. Make party-member a distinct entity class** (subclassing
Entity). Rejected — violates Invariant #3 (no entity-class
hierarchy). The party-membership status is fully expressible as
`tag` + `relation` + `state` — same as every other entity role.

**D. Combat-coordination effects (`party_attack_target`, etc.)**
in the engine. Rejected — per Invariant #2 (no semantic effects)
+ Invariant #8 (engine = primitives + interpreter). Combat is
already a contact-rule + tag-match pattern; party AI shooting at
the same target as the player is a JSON rule choice ("if leader
state.attack_target_id is set, party member's attack rule binds
to that id"). Engine doesn't need to add a verb for it.

## References

- ADR 0018 — actor policies (the "smart NPC" path; party leashing
  is intentionally cheaper).
- ADR 0021 — Yume as JSON layer over Godot (the policy that says
  compose, don't reinvent).
- ADR 0024 — pathfinding (companions can pathfind to leader if the
  leash radius exceeds pathfinding_obstacle thickness; same
  primitive composes).
- ADR 0025 — day/night cycle (precedent for a small per-frame
  director module that JSON content drives).
- `docs/games/merchant/GDD.md` Acts 3-4 — the consumer.
