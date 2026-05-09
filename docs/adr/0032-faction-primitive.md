# ADR 0032 — Faction primitive

_Date: 2026-05-09_
_Status: proposed (Phase 3 prerequisite for Aldenmere)_

## Context

Aldenmere Phase 3 (Society) introduces emergent politics: NPCs belong
to factions (traditionalists, innovators, militarists, mercantile
guild, religious sect, wild-keepers); factions hold stances toward
each other (allied, hostile, neutral, at-war, rivals); wars + treaties
+ marriage alliances are signal-driven faction-state changes; the
player can lead a faction.

The merchant game's "reputation tier" mechanic is a faction-shaped
problem solved with ad-hoc state (`world.reputation_tier` int, no
inter-faction relationships, no leadership, no warfare). For
Aldenmere's 50-200 NPCs across ~10 villages and 1-2 cities, the
ad-hoc shape collapses:

- NPCs need MULTI-faction loyalty (a smith who is 80%
  traditionalist + 20% innovator votes both ways depending on the
  decision)
- Factions need typed RELATIONSHIPS (who is allied with whom; who
  is at war; tension that drifts before erupting)
- Wars + treaties need to be FIRST-CLASS state transitions
  (declarative effects, not bespoke rules per faction pair)
- Zone control (per ADR 0031) MUST cross-reference faction
  ownership ("who controls Brookhaven this season?")
- The player's class (per ADR 0030) NATURALLY aligns with certain
  factions (warrior → militarist; scholar → innovator); switching
  class should nudge faction loyalty
- Party members (per ADR 0026) share faction-loyalty boosts when
  the leader gains reputation with a faction

These are all faction-shaped — repeating "if-then-else" per faction
pair in `game/rules.json` would be hundreds of bespoke rules and
won't generalize across kingdoms.

The roadmap (`docs/games/aldenmere/engine_roadmap.md` § ADR 0032)
sketched the shape; this ADR pins it down.

### Adjacent primitives

- **ADR 0031 (zone-state)**: a faction can "control" a zone; war
  changes which faction controls a zone. Faction primitive READS
  zone state and WRITES zone-control via `zone_state_set`. No new
  zone-side machinery needed.
- **ADR 0030 (class/occupation)**: classes have natural faction
  alignment. Class primitive does NOT read faction state directly;
  faction primitive reads class as one of several inputs to loyalty
  drift.
- **ADR 0026 (party member)**: party members share faction-loyalty
  boosts when leader gains reputation. Faction primitive emits
  loyalty deltas; party_director cascades them per existing leashed-
  follower rules.
- **ADR 0027 ($extends)**: faction defs reusable across kingdoms
  via `@lib.factions.<name>` references.
- **ADR 0010 (save/load)**: faction state + relationship state
  persists; save_policy declares the keys.

## Decision

Add a **faction primitive** as a new engine module
(`scripts/engine/faction_director.gd`, ~250 LoC) plus three new
effect types and a small binding namespace. Faction definitions
+ initial relationships live in `data/<game>/factions.json` (a new
content file). NPC loyalty is a per-entity state field
(`faction_loyalty`, a dict `{faction_id: int}`).

This is a **capability-exposure ADR** in the ADR 0021 sense: the
primitive doesn't reimplement Godot or invent new substrate; it
formalizes a JSON shape + a director module + three effect verbs
so games declare politics rather than hand-author per-pair rules.

### Schema

#### `data/<game>/factions.json` (new file)

```jsonc
{
  "factions": [
    {
      "id": "traditionalists",
      "leader": "elder_morwen",        // entity id; optional
      "ideology": "preserve_old_ways", // free-form string tag
      "color": "#8a6840",              // ui hint; renderer reads
      "home_zone": "village_riverside" // zone id from ADR 0031; optional
    },
    {
      "id": "innovators",
      "leader": "scholar_lerian",
      "ideology": "embrace_change",
      "color": "#4080c0"
    },
    {
      "id": "militarists",
      "leader": "captain_brennar",
      "ideology": "strength_first",
      "color": "#a04040"
    }
  ],
  "relationships": [
    {
      "from": "traditionalists",
      "to":   "innovators",
      "stance": "rivals",      // one of: allied | neutral | rivals | hostile | at_war
      "tension": 40            // 0-100; rises with provocations, drops with treaties
    },
    {
      "from": "traditionalists",
      "to":   "militarists",
      "stance": "allied",
      "tension": 10
    }
  ]
}
```

Stances form a fixed vocabulary (5 values, ordered by escalation):
`allied < neutral < rivals < hostile < at_war`. Tension is a numeric
0-100 scalar that decays toward the stance's neutral baseline each
in-game day; effects nudge it on provocations.

Relationships are stored as **directed edges** (from, to) but most
content authors will write them symmetrically. The director enforces
no symmetry; asymmetric stances are valid (faction A views B as
hostile, B views A as neutral) and content can exploit that for
emergent narrative.

#### NPC entity state field

```jsonc
{
  "id": "smith_haldor",
  "tags": ["npc", "smith"],
  "state_init": {
    "faction_loyalty": {"traditionalists": 80, "innovators": 20}
  }
}
```

Loyalty values are 0-100 ints; they need not sum to a fixed total
(an NPC can be 90% traditionalist AND 70% mercantile-guild — those
are independent loyalty channels). A loyalty entry below a
threshold (default 5) is treated as "not a member" and may be
pruned to keep state compact.

### Effects (three new verbs)

| Effect | Payload | Semantics |
|---|---|---|
| `declare_war` | `from`, `to` | Sets relationship stance to `at_war`, tension to 100. Emits `war_declared` signal with from + to. |
| `sign_treaty` | `from`, `to`, `new_stance` (default `neutral`) | Sets stance to `new_stance` (from the fixed 5), tension to that stance's baseline. Emits `treaty_signed` signal. |
| `propose_alliance` | `from`, `to` | Sets stance to `allied`, tension to 0. Emits `alliance_formed` signal. |

A fourth effect, `swear_loyalty`, mutates an NPC's `faction_loyalty`
field. It's expressible via existing `state_set` / `state_add` on
the NPC's loyalty dict, but a dedicated verb makes intent explicit
and emits the `loyalty_changed` signal for downstream rules:

| Effect | Payload | Semantics |
|---|---|---|
| `swear_loyalty` | `target` (entity id), `faction` (id), `delta` (int) OR `value` (int) | Adds delta (clamped 0-100) or sets value on target's `faction_loyalty[faction]`. Emits `loyalty_changed` signal with target + faction + new value. |

These four effects are the **complete vocabulary** for faction
state mutation — adding more (e.g., `marriage_alliance`,
`betray_faction`, `fund_faction`) is content layered on top via
rules that compose these four primitives plus existing
`state_set` / `spawn` / `relate` verbs. We deliberately resist a
genre-specific vocabulary expansion (per Invariant #8 — no
semantic effect types beyond what generalizes).

### Bindings

The faction director registers a `faction.<id>.<field>` binding
namespace, readable in formulas + HUD:

| Binding | Returns |
|---|---|
| `faction.<id>.leader` | Leader entity id (string) |
| `faction.<id>.member_count` | Count of entities whose `faction_loyalty[<id>] >= 50` (default threshold) |
| `faction.<id>.tension_with.<other_id>` | Tension scalar 0-100 (defaults to 0 if no relationship row exists) |
| `faction.<id>.stance_with.<other_id>` | Stance string (one of the 5; defaults to `neutral`) |
| `faction.<id>.controls_zone` | True if any zone's `controlling_faction` (zone-state from ADR 0031) is `<id>` |

Per Invariant #5 (queries first-class), faction membership is
also queryable via the existing query system, NOT a bespoke
faction_query primitive:

```jsonc
{
  "trigger": {"type": "tick", "interval": 60},
  "query": {
    "tags_all": ["npc"],
    "state": {"faction_loyalty.traditionalists_gte": 50}
  },
  "effect": [...]
}
```

This means we extend the existing query state-filter operators to
support **dotted state paths** (`faction_loyalty.traditionalists_gte`).
Today's filter assumes flat field names; the change to allow `.` in
filter keys is a small interpreter extension (~10 LoC in
query.gd). Tracked as part of this ADR's scope.

### Engine module sketch (~250 LoC)

`scripts/engine/faction_director.gd`:

```gdscript
class_name FactionDirector
extends RefCounted

# Loaded from data/<game>/factions.json at world boot
var _factions: Dictionary = {}        # faction_id -> def dict
var _relationships: Dictionary = {}   # "<from>:<to>" -> {stance, tension}

const STANCE_BASELINE := {
    "allied":  0,
    "neutral": 10,
    "rivals":  40,
    "hostile": 70,
    "at_war":  100
}

func load_from_json(data: Dictionary) -> void:
    # Populate _factions + _relationships, validate stance vocab.
    pass

func get_stance(from_id: String, to_id: String) -> String: ...
func get_tension(from_id: String, to_id: String) -> int: ...
func set_stance(from_id: String, to_id: String, stance: String) -> void: ...

# Effects (called from EffectApply._apply_declare_war etc.)
func apply_declare_war(env: Dictionary, payload: Dictionary) -> void: ...
func apply_sign_treaty(env: Dictionary, payload: Dictionary) -> void: ...
func apply_propose_alliance(env: Dictionary, payload: Dictionary) -> void: ...
func apply_swear_loyalty(env: Dictionary, payload: Dictionary) -> void: ...

# Tick — daily tension-drift toward stance baseline
func on_daily_tick(env: Dictionary) -> void: ...

# Bindings (called from BindingResolver for faction.<id>.<field>)
func resolve_binding(path: Array) -> Variant: ...

# Save/load
func to_save() -> Dictionary: ...
func load_from_save(data: Dictionary) -> void: ...
```

Wired into `world.gd::_ready` after entity load (so member_count
binding resolves). Effect dispatch table in `effect_apply.gd`
registers the four new types pointing at the director's `apply_*`
methods.

### Save/load

Per ADR 0010, faction state persists by default:

- `factions.json` content is read-only at boot (definitions); not
  saved.
- `_relationships` (current stance + tension per pair) IS saved —
  these mutate during play.
- Per-NPC `faction_loyalty` is saved as part of the existing entity
  state save path; no new save plumbing.

Game-level `save_policy.json` may opt out via:

```jsonc
{ "exclude_faction_state": true }
```

(Default: included.)

### Validation

`tools/validate_factions.py` (new, ~80 LoC):

- Every relationship's `from` + `to` must reference a defined faction.
- Every relationship's `stance` must be one of the 5.
- Tension must be 0-100.
- Every NPC's `faction_loyalty` keys must reference a defined faction.
- Every faction's `leader` (if set) must reference an entity id that
  exists in initial_instances.
- Every faction's `home_zone` (if set) must reference a zone defined
  in `world/zones.json` (per ADR 0031).

Wired into `scripts/play.sh` as a non-blocking check (mirrors
`validate_screens.py` per ADR 0011 / `.claude/rules/visual-qa.md`).
Skills running design pipelines call it with `--strict`.

### Test plan (~10 unit tests in `test_runner.gd`)

| Test | Verifies |
|---|---|
| `faction.test_creation_and_state_roundtrip` | Loading factions.json populates director; getter reads back identical state |
| `faction.test_alliance_formation` | `propose_alliance` effect sets stance=`allied`, tension=0, emits signal |
| `faction.test_war_declaration` | `declare_war` sets stance=`at_war`, tension=100, emits `war_declared` |
| `faction.test_treaty_signing` | `sign_treaty` resets tension to stance baseline, emits `treaty_signed` |
| `faction.test_npc_loyalty_mutation` | `swear_loyalty` adds + clamps loyalty, emits `loyalty_changed` |
| `faction.test_multi_faction_npc` | NPC with `{traditionalists: 60, innovators: 40}` is queryable by either filter; both bindings resolve |
| `faction.test_query_npcs_by_faction` | `query.state.faction_loyalty.X_gte: 50` matches expected entity set |
| `faction.test_query_factions_by_stance` | binding `faction.A.stance_with.B` returns current value; ticks-then-rechecks reflect mid-game change |
| `faction.test_save_load_preserves_state` | Save mid-war, reload, stance + tension + per-NPC loyalty all match |
| `faction.test_emergent_ally_loyalty_drift` | Party-member follower's loyalty drifts toward leader's faction across days (ADR 0026 wiring) |

Per `.claude/rules/tests.md` discipline: each test builds its own env
dict, exercises the director directly + via effect dispatch, asserts
both state and emitted signals, frees created entities at end.

### Implementation plan

**Phase 1 (engine + tests)** — single session, ~2-3 hours:

1. `faction_director.gd` (~250 LoC) — load + state + effects +
   bindings + save/load.
2. `effect_apply.gd` — register 4 new effect types.
3. `query.gd` — extend state-filter to allow dotted paths
   (`faction_loyalty.traditionalists_gte`).
4. `binding_resolver.gd` — register `faction.*` namespace.
5. `world.gd` — load factions.json after entities; wire daily
   tension-drift tick.
6. `test_runner.gd` — 10 new tests per the table.
7. `save_state.gd` — include `_relationships` + `faction_loyalty`
   per save_policy.

**Phase 2 (validator + lib seeds)** — same session or follow-up,
~1 hour:

8. `tools/validate_factions.py` — 5 checks above.
9. `scripts/play.sh` — non-blocking validate hook.
10. `data/lib/factions/<name>.json` seeds for Aldenmere's six core
    factions (traditionalists, innovators, militarists, mercantile_guild,
    religious_sect, wild_keepers). Reusable across kingdoms via
    `@lib.factions.<name>`.

**Phase 3 (skill discipline)** — when Aldenmere Phase 3 is queued:

11. Update yume-systems-designer SKILL: "if a game has politics
    (factions, war, treaties), declare them in factions.json; never
    hand-author per-pair rules."
12. Update yume-story-planner SKILL: faction-driven event templates
    (war_breaks_out, marriage_alliance_proposed, treaty_signed_ceremony).

Phases 1 + 2 land BEFORE Aldenmere Phase 3 build starts. Phase 3
defers until first dependent game queues content.

## Consequences

### Enables

- **Aldenmere Phase 3 politics** — factions are first-class, war
  + treaty + alliance are declarative, content authors write 5-10
  faction relationships instead of hundreds of per-pair rules.
- **Reputation systems generalize** — the merchant game's
  ad-hoc reputation_tier becomes "merchant_player has loyalty toward
  mercantile_guild faction"; the existing tier formula drives off
  `faction.mercantile_guild.member_count` or per-NPC loyalty.
- **Cross-game library** — `@lib.factions.merchant_guild`,
  `@lib.factions.thieves_guild`, `@lib.factions.scholars_circle` reusable
  across any game with social structure.
- **Emergent narrative** — NPCs with split loyalty produce
  organic conflict; rules can fire on `loyalty_changed` to spawn
  faction-betrayal beats.
- **Zone-control loop** — combined with ADR 0031, war between
  factions changes zone control; downstream effects (taxation,
  garrison spawn) chain via existing zone state.

### Constrains

- **Stance vocabulary is fixed** at 5 values. A game wanting
  finer granularity (e.g., "vassal", "tributary", "client-state")
  must encode them via tension-band-on-allied or extend the
  vocabulary via a future ADR.
- **Loyalty is per-faction-keyed**, NOT per-NPC-pair (an NPC's
  loyalty is "to a faction," not "to another NPC"). Personal
  relationships (rivalry, friendship between two NPCs) are a
  separate concern — handled via existing `Relation` primitive
  (typed directed edges) or a future personal-relationship
  primitive. This ADR scopes to faction-level only.
- **Daily tension-drift is fixed** in director code (tension drifts
  toward stance baseline at 1 unit per in-game day). Per-game
  override via `factions.json` `_drift_rate` field; the FORMULA
  stays in code (per Invariant #8 — drift is interpreter, rate is
  composition).

### Doesn't enable

- **No multi-tier faction hierarchy** (sub-factions inside
  factions). All factions are flat. A future ADR could add
  sub-faction support if Phase 4 needs it.
- **No faction AI policy** (factions don't autonomously decide to
  declare war). Wars + treaties fire via tick rules + signal rules
  using the four effect verbs. AI policy is an ADR 0018 concern, not
  this one.
- **No procedural faction generation**. Factions are hand-authored
  in JSON; the engine doesn't synthesize new factions from emergent
  state. (Future ADR could explore.)

### Cumulative invariant pressure

This ADR adds:
- 1 new engine module (faction_director.gd, ~250 LoC)
- 1 new content file type (factions.json)
- 4 new effect types (declare_war, sign_treaty, propose_alliance,
  swear_loyalty)
- 1 new binding namespace (faction.*)
- 1 query operator extension (dotted state paths)

Each addition is interpreter-shaped (reads JSON, dispatches to
existing primitives). The four effect verbs are GENERIC (any game
with factions uses them; not merchant/aldenmere-specific) so
Invariant #2 (no semantic effect types) is preserved — these are
PRIMITIVES, not genre logic. The dotted-state-path extension is a
small generalization of Invariant #5 (queries first-class), not a
new feature.

Tech-director should run the standard invariant suite on the
implementation PR.

## Alternatives considered

### A) Encode factions as plain entities + relations

Treat each faction as an entity tagged `faction`; encode
relationships as typed `relation` edges between faction entities
(e.g., `at_war`, `allied`). Use existing `relate` / `unrelate`
effects.

**Pros**: zero new primitives. Pure use of existing seven primitives.
Maximally orthogonal.

**Cons**:
1. Tension scalar has no natural home in the relation primitive
   (relations are typed edges, no payload state).
2. Stance vocabulary becomes implicit (relation type strings) with
   no validation; typos silently break content.
3. Faction state (member_count, controlling_zone) requires bespoke
   query rules per game; no shared director.
4. Daily tension-drift becomes per-game tick rules instead of one
   engine-side mechanism.

The cleaner path is to recognize that "faction" is a coherent
JSON-template concept (like ADR 0026 party-member or ADR 0031
zone-state) deserving a director module. Same precedent as those
ADRs.

### B) Bake faction logic into class primitive (ADR 0030)

Since classes have natural faction alignment, fold faction state
into class progression — e.g., warrior class IS the militarist
faction membership.

**Pros**: one fewer primitive.

**Cons**:
1. Conflates two concepts. A warrior CHARACTER can be loyal to
   any faction (a militarist warrior, a mercantile-guild warrior,
   a traditionalist warrior). Their class is what they DO; their
   faction is who they SERVE.
2. NPCs (non-player) need factions but may not have classes
   (a generic villager has no class but votes traditionalist).
3. Players switching class shouldn't auto-shift faction loyalty
   (your warrior becoming a scholar doesn't betray the militarists
   overnight).

Class and faction are orthogonal axes of identity. Conflate them
and the design space collapses.

### C) Defer to per-game faction implementations

Don't build a faction primitive; let each game (Aldenmere, future
politics-heavy games) hand-roll its own faction system in JSON
rules + state.

**Pros**: zero engine work right now; defers complexity.

**Cons**:
1. Aldenmere Phase 3 alone needs ~6 factions × ~5 stances × ~4
   transition events = ~120 bespoke rules. Authoring + maintaining
   that without a director is the same trap merchants escaped
   with the party-member primitive (ADR 0026).
2. Cross-game lib reuse becomes impossible — every politics-heavy
   game reinvents the wheel.
3. The "faction-shaped" pattern is universal across RPGs, sims,
   strategy games, civilization-style games — building it once
   benefits everything downstream.

The reference is ADR 0026 (party-member primitive). Same logic:
party-shaped problems exist across many games; one director with
clean JSON shape beats per-game ad-hoc.

### D) Borrow CK3-style "casus belli" rich relationship model

Encode richer relationship state — claims, grievances, justifications
for war, marriage ties, trade pacts — as a complex relationship
record per pair.

**Pros**: deepest emergent narrative.

**Cons**:
1. Massive scope creep. Aldenmere Phase 3 doesn't need claim-
   resolution; it needs "are these two factions at war?" + "is
   this NPC loyal to faction X?".
2. Adds 200-500 LoC + 30+ tests; pushes ADR scope from focused to
   sprawling.
3. Most of the richness can be ADDED LATER as additional fields on
   the relationship record (the existing schema is open). Don't
   speculatively over-build.

Picked: minimal director with 5-stance vocabulary + tension scalar.
Rich relationships are a future ADR if a game demands them.

## References

- ADR 0026 (party-member primitive) — pattern reference: director
  module + new effect verbs + binding namespace + cross-game lib
  reuse via `@lib.party.*`.
- ADR 0031 (zone-state primitive) — faction "controls zone"
  semantics; faction director writes zone-control via existing
  `zone_state_set`.
- ADR 0030 (class/occupation primitive) — natural class-faction
  alignment; class switch may emit `swear_loyalty` via game rules.
- ADR 0027 (cross-game JSON reuse) — `@lib.factions.<name>` reuse
  across Aldenmere kingdoms + future games.
- ADR 0010 (save/load persistence) — faction state persists by
  default; save_policy can opt out.
- ADR 0021 (Yume = JSON layer) — this ADR is a capability-exposure
  ADR; faction-shaped JSON over a thin GDScript director.
- ADR 0029 (schedule primitive) — NPC schedules can branch on
  faction stance ("if at_war with raider faction, schedule guard
  duty at night").
- `docs/games/aldenmere/world.md` — Phase 3 scope motivating this ADR.
- `docs/games/aldenmere/engine_roadmap.md` § ADR 0032 — sketch this
  ADR formalizes.
- `godot/scripts/engine/faction_director.gd` (to be created) — the
  module this ADR specifies.
- `godot/data/<game>/factions.json` (new content file type) — schema
  defined here.
- `godot/data/lib/factions/` (future seeds, Phase 2) — cross-game
  faction templates.
- `tools/validate_factions.py` (to be created) — sync-time validator
  per `.claude/rules/visual-qa.md` static-validator pattern.
