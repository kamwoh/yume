# ADR 0036 — Lifecycle / aging primitive

_Date: 2026-05-09_
_Status: proposed_

## Context

Aldenmere's vision asks every entity — NPCs, animals, eventually the
player — to be born, grow, age, and die. Phase 1 (30-day winter
survival) doesn't visibly age much, but the **state schema** (an
`age` field + `life_stage` field on every entity-with-lifecycle)
must land NOW so saves migrate forward cleanly into Phase 2 (where
families form, babies grow into children) and Phase 4 (where the
dynasty primitive — ADR 0034 — depends on player-character aging
out and an heir taking over).

Specifically:

- **Phase 1** — schema only. NPCs have `age` + `life_stage`; aging
  is deliberately slow (one in-game year ≈ many real-time hours)
  so a 30-day campaign rarely crosses thresholds. But a 49-year-
  old elder Morwen turning 50 mid-campaign should swap mesh +
  shift abilities — Discovery aesthetic ("Morwen got slower
  lately" without a UI announcement).
- **Phase 2** — mechanics activate. Family pairs in Phase 1 had
  babies; those infants grow to children across Phase 2's longer
  time scale. Children appear differently in the world (smaller
  meshes), can't hunt (ability gating), need carrying (ability
  tag).
- **Phase 4** — dynasty (ADR 0034) reads `life_stage = dead` to
  trigger inheritance + heir succession. Without the lifecycle
  primitive, dynasty has no aging substrate to hook into.

The Yume engine today has no concept of life stages. NPCs have a
fixed mesh + fixed ability set defined by tags. Hand-coding
"increment age every tick + check thresholds + swap visual.mesh"
per game is technically possible but:

1. Violates Invariant #1 (every game re-deriving the same logic in
   per-game rules)
2. The mesh-swap step requires reaching into renderer state — not
   a JSON-expressible operation today
3. Ability gating per stage requires runtime tag rewriting on
   transitions — not currently a single-rule operation
4. Cross-template reuse demands the @lib pattern (ADR 0027) for
   stage tables shared across humans / deer / wolves

A lifecycle director is a coherent primitive: one per-year tick,
one threshold check, one mesh swap, one tag rewrite, one signal
emission. All driven by JSON-declared stage tables. The director
is interpreter (it READS JSON, dispatches to existing engine
primitives — visual swap, tag mutation, signal emit), not new
verb logic per game.

## Decision

Add a **lifecycle primitive** to the engine with three pieces:

1. **State fields** — `age: float` (in-game years, fractional) and
   `life_stage: string` (current stage id) become recognized state
   conventions on any entity that opts in.
2. **Lifecycle templates** — `@lib.lifecycles.<species>` JSON
   entries declare the stage table (id, age range, mesh, abilities,
   speed multiplier). Stored under `data/lib/lifecycles/<name>.json`,
   resolved via ADR 0027's `$extends` / `$ref` machinery.
3. **Engine module** — `scripts/engine/lifecycle_director.gd`
   increments age per in-game year, evaluates threshold crossings,
   emits `life_stage_changed` and `entity_died` signals, swaps
   `visual.mesh`, and rewrites `tags` to apply the new stage's
   abilities.

Schema lands in Phase 1 (entities can declare a `lifecycle` field
with no behavioral effect if `age_per_in_game_year = 0`); mechanics
activate in Phase 2 by setting `age_per_in_game_year > 0`.

### State schema (per entity)

```jsonc
{
  "id": "villager_marken",
  "tags": ["villager", "human", "adult"],
  "lifecycle": "@lib.lifecycles.human",     // OPT-IN; absent = no aging
  "state_init": {
    "age": 18.0,                            // years, fractional
    "life_stage": "adult"                   // must match a stage in template
  },
  "visual": {"mesh": "merchant_npc_3d"}     // overwritten by stage on transition
}
```

Entities WITHOUT a `lifecycle` field never age. Existing demos are
unaffected — backward-compatible by absence.

### Lifecycle template shape

```jsonc
// data/lib/lifecycles/human.json
{
  "stages": [
    {"id": "infant", "min_age": 0,  "max_age": 2,
     "mesh": "human_infant_3d",
     "abilities": ["needs_caring"],
     "speed_mult": 0.4},
    {"id": "child",  "min_age": 2,  "max_age": 12,
     "mesh": "human_child_3d",
     "abilities": ["gather", "talk"],
     "speed_mult": 0.85},
    {"id": "adult",  "min_age": 12, "max_age": 50,
     "mesh": "merchant_npc_3d",
     "abilities": ["all"],
     "speed_mult": 1.0},
    {"id": "elder",  "min_age": 50, "max_age": 80,
     "mesh": "human_elder_3d",
     "abilities": ["talk", "tend_fire", "teach"],
     "speed_mult": 0.6},
    {"id": "dead",   "min_age": 80,
     "mesh": null,
     "abilities": [],
     "speed_mult": 0.0,
     "terminal": true}
  ],
  "age_per_in_game_year": 1.0,
  "year_seconds": 900
}
```

Field semantics:

- `min_age` (inclusive) / `max_age` (exclusive) — age range, in
  in-game years. Final stage has `min_age` only (no upper bound)
  and is marked `terminal: true`.
- `mesh` — string mesh name (resolves via meshes.json) or `null`
  for invisible / despawn-eligible.
- `abilities` — array of tag-shaped capability strings. The
  director rewrites entity `tags` on transition to remove old
  stage's abilities and add new stage's abilities. Special
  values: `"all"` (don't filter abilities — keep everything).
- `speed_mult` — multiplier applied to `velocity` integration on
  motion rules. Optional; defaults to 1.0. Director writes
  `state.speed_mult` so motion rules can read it via formula.
- `age_per_in_game_year` — how fast aging proceeds. 1.0 = realistic
  pacing; 0 = aging disabled (Phase 1 schema-only mode); 0.1 =
  10x slowed (long-running save). Per-template, not per-entity.
- `year_seconds` — how many real seconds equal one in-game year.
  Couples to ADR 0025 day/night cycle: typically year_seconds =
  day_seconds × 365 / scale.
- `terminal: true` — when reached, emit `entity_died` signal
  instead of continuing to advance.

### Cross-template reuse via @lib + $extends

Per ADR 0027, lifecycle templates are reusable across games:

```jsonc
// per-game override
{
  "id": "long_lived_elf",
  "lifecycle": {
    "$extends": "@lib.lifecycles.human",
    "stages": [...overridden...]      // shape-merge by id, see ADR 0027
  }
}
```

Phase 2 will ship stock templates for human, deer, wolf — each
with different stage counts + thresholds. No engine change needed
to support a new species; just author a new `@lib.lifecycles.X`
JSON file.

### Engine module — `lifecycle_director.gd`

Hooked into the scheduler at the per-second-or-coarser tick (not
per-frame). On each tick:

1. For each entity with `lifecycle` field, increment
   `state.age` by `(tick_seconds / year_seconds) × age_per_in_game_year`
2. Compare `state.age` against the current stage's `max_age`. If
   crossed, find the new stage (linear scan; ≤6 stages typical):
   - Set `state.life_stage = new_stage.id`
   - Update `state.speed_mult`
   - Swap `visual.mesh = new_stage.mesh` (re-render via existing
     mesh-swap path; if mesh is null, mark entity for despawn-
     eligibility — game rules choose corpse vs remove)
   - Rewrite tags: remove old-stage abilities, add new-stage
     abilities. Preserve all non-ability tags (species, faction,
     etc.)
   - Emit `life_stage_changed` signal with `{entity, old_stage,
     new_stage}` payload — game rules listen + react (toast,
     barker line, particle, etc.)
   - If `new_stage.terminal`: emit `entity_died` signal and stop
     further age increments

3. **Save/load**: `state.age` and `state.life_stage` persist via
   normal entity-state serialization (ADR 0010). No special save
   policy needed.

### Signals emitted

- `life_stage_changed` — payload `{entity_id, old_stage, new_stage}`.
  Fires on every threshold crossing including `dead`.
- `entity_died` — payload `{entity_id, lifecycle_id}`. Fires on
  terminal stage. Game rules decide despawn vs corpse-conversion.

Signals plug into the existing signal trigger primitive — game
rules can listen via `{"trigger": {"type": "signal", "name":
"entity_died"}, "effect": [...]}`.

### Tag-rewrite semantics

The director treats `abilities` as a controlled subset of the
entity's tag list. On transition:

```
new_tags = (old_tags - prev_stage.abilities) + new_stage.abilities
```

If `new_stage.abilities = ["all"]`, no removal — all prior tags
preserved. This handles the adult-stage case ("can do anything").
For non-adult stages, the director removes only the abilities
declared by the previous stage (so non-ability tags survive).

Authors must declare `abilities` arrays consistently across stages
for clean tag-rewriting. The validator (`tools/validate_lib_refs.py`
extension) catches inconsistent ability sets at sync time.

## Consequences

### Positive

- Every entity gets a life arc with no per-game engine code.
- Emergent storytelling — NPCs grow up, get old, die; the world
  has temporal depth.
- Foundation for ADR 0034 dynasty (heir succession reads
  `life_stage = dead`).
- Cross-game reuse — `@lib.lifecycles.human` covers any human-NPC
  game; species variants are JSON-only authoring.
- Schema lands in Phase 1 → saves migrate forward cleanly to
  Phase 2 + 4 without state migration code.
- Mesh swap on transition exposes a new mesh-mutation path that
  future primitives (transformation magic, disguise) can reuse.

### Negative

- **Mesh-per-stage authoring load** — humanoid species needs
  ≥4 distinct meshes (infant, child, adult, elder) instead of 1.
  At ~30-50 mesh-piece declarations each, this is real authoring
  cost. Mitigation: Phase 1 ships only adult meshes; child/elder
  meshes land for Phase 2. Phase 1 NPCs are all adults so no
  Phase 1 visual work needed.
- **Tag-rewrite edge cases** — if a game's rules add tags
  dynamically (combat states, status effects), the director must
  not clobber them. Decision: only abilities declared in the
  PREVIOUS stage are removed; everything else passes through. The
  validator audits ability-set consistency.
- **Aging at scale** — at 200+ NPCs (Phase 3 target), per-tick
  age loop is O(N). Mitigation: lifecycle director runs on a
  COARSE tick (1 second or 1 in-game minute, not per frame). 200
  entities × 1 tick/second = 200 ops/sec — trivial. Stage transitions
  are rare events.
- **Mesh swap mid-frame** — visible pop. Mitigation: ADR 0035
  animation can blend between meshes; if not, the swap is rare
  enough (4 transitions per NPC across a multi-hour campaign) that
  pop is acceptable.

### Neutral

- Existing demos: lifecycle field is optional. Entities without
  it stay at fixed visual + abilities. Zero migration needed.
- Phase 1 ships with `age_per_in_game_year` set conservatively
  (e.g. 0.05 — a real-time hour ages an NPC by ~3 days) so the
  30-day campaign rarely sees a transition. The mechanic is
  PRESENT but PASSIVE.
- Save schema gains 2 fields per lifecycle entity (`age`,
  `life_stage`). ADR 0010's policy already handles arbitrary
  state-dict serialization; no save-format change.

## Alternatives considered

### A) Only age the player character (RPG style)

In a classic RPG, the player ages but NPCs are static. We could
ship aging only on the player and skip the simulation cost.

Pros: simple, cheap, works for one-protagonist games.
Cons: fails the Aldenmere simulation goal — NPC longevity, family
formation, dynasty across generations all require NPC aging too.
Also fails Discovery aesthetic ("the world feels temporal" needs
the WORLD to change, not just the camera-character).

Rejected: doesn't serve the target game.

### B) Hard-coded life stages in engine

Hard-code "infant / child / adult / elder / dead" as engine
constants with engine-defined thresholds.

Pros: zero authoring per game.
Cons: violates Invariant #1 (JSON-only content) and Invariant #8
(engine = primitives + interpreter, not embedded game policy).
Also forecloses cross-species variation — wolves don't have
"infant" + "elder" in the same shape as humans.

Rejected: contract violation.

### C) Bake lifecycle into entity def directly (no @lib template)

Each entity def declares its own stage table inline:

```jsonc
{
  "id": "villager_marken",
  "stages": [...inline 4-stage table...]
}
```

Pros: no new resolver work; works with existing entity-def loader.
Cons: every entity duplicates the human stage table. 50 villagers
× ~30 lines of stage config = 1500 lines of duplicated JSON. Fix
to one stage threshold = 50 file edits.

Rejected: combinatorial authoring explosion. The @lib template
pattern (ADR 0027) was built for exactly this case.

### D) Tag-only stages (no engine director)

Express life stages as tags managed by per-game rules. Each game
authors ~5 rules ("if age > 12 and has child tag, remove child,
add adult").

Pros: zero engine work.
Cons: every game re-derives the same logic. The mesh-swap step
is currently not expressible in JSON (visual.mesh isn't a
mutation target on existing effects). Tag-rewrite on threshold
is awkward with current rule shapes (5+ rules per stage × 5
stages = 25 rules per species per game).

Rejected: forces every game to redo identical work. The director
is the right level of abstraction.

### E) Continuous mesh morph (no discrete stages)

Use animation blend-shapes to continuously interpolate from
infant-shape to elder-shape based on a normalized age value.

Pros: no mesh pop on transition.
Cons: requires blend-shape mesh authoring (well beyond meshes.json's
code-drawn primitives). Doesn't naturally express "ability cliffs"
(child can't hunt, adult can — the discrete transition is the
GAMEPLAY mechanic, not a presentation artifact).

Deferred: future ADR could add blend-shape support if a game wants
continuous morphing as a separate concern.

## References

- `docs/games/aldenmere/world.md` — Aldenmere vision (Phase 2
  family formation, Phase 4 dynasty).
- `docs/games/aldenmere/engine_roadmap.md` — ADR 0036 sketch +
  dependency graph.
- ADR 0034 (dynasty / heir succession) — depends on this ADR's
  `entity_died` signal + `life_stage` reads.
- ADR 0027 ($extends + @lib references) — the cross-template reuse
  layer this ADR builds on.
- ADR 0029 (schedule primitive) — interacts: children have
  different schedules than adults; lifecycle changes ability tags
  that schedule director may filter on.
- ADR 0030 (occupation/class primitive) — interacts: class
  progression depends on stage (children can't be warriors).
- ADR 0035 (animation primitive) — interacts: per-stage mesh swaps
  ideally blend rather than pop.
- ADR 0010 (save/load) — `age` + `life_stage` fields persist via
  default state-dict serialization.

## Test plan

10 unit tests in `test_runner.gd` (one section: `test_lifecycle`).

| Test | Verifies |
|---|---|
| `lifecycle.test_age_increments_per_year` | After one in-game year of ticks, `state.age` advances by `age_per_in_game_year`. Sub-year advances are linear. |
| `lifecycle.test_stage_transition_at_threshold` | Crossing `max_age` of a stage advances `life_stage` to the next stage. Boundary (age == max_age) goes to NEXT stage (max_age is exclusive). |
| `lifecycle.test_mesh_swap_on_transition` | After a transition, `entity.visual.mesh` equals the new stage's `mesh` value. Mesh swap fires the renderer's mesh-mutation path. |
| `lifecycle.test_ability_gating` | Child stage's tags include `gather` + `talk` but NOT `hunt`. After transition to adult, tags include all (or whatever the new stage declared). Ability tags are correctly removed + added. |
| `lifecycle.test_speed_mult_applied` | Elder stage's `speed_mult = 0.6` writes to `state.speed_mult`. Motion rules reading `self.state.speed_mult` see 0.6. |
| `lifecycle.test_entity_died_signal_on_terminal_stage` | Reaching a stage with `terminal: true` emits `entity_died` signal. Signal payload includes `entity_id` + `lifecycle_id`. |
| `lifecycle.test_save_load_mid_stage` | Save mid-life (age = 23.5, life_stage = adult), reload, both fields restore. Director resumes ticking from the loaded age. |
| `lifecycle.test_extends_from_lib` | `lifecycle: {"$extends": "@lib.lifecycles.human"}` resolves to the human template's stages. Per-entity overrides win over template. |
| `lifecycle.test_multiple_lifecycle_templates` | Human (5 stages), deer (3 stages: fawn / adult / dead), wolf (4 stages) coexist. Each entity uses its own template's stages without crossover. |
| `lifecycle.test_no_lifecycle_field_no_aging` | Entity without `lifecycle` field has no `age` increments, no `life_stage` field, no signal emissions. Backward-compat preserved. |

Plus 1 scenario test: `aldenmere_phase1_aging` — 8 NPCs in a
village, advance simulation 30 in-game days at 0.05 age-per-year,
verify ≤1 stage transition occurs (slow Phase 1 pacing) and any
transition cleanly swaps mesh + tags + emits signals.

## Implementation sketch

`scripts/engine/lifecycle_director.gd` — pseudocode (~80-100 lines):

```gdscript
class_name LifecycleDirector
extends Node

var _env: Dictionary
var _last_tick_time: float = 0.0
var _tick_interval: float = 1.0    # seconds; coarser than per-frame

func _init(env: Dictionary) -> void:
    _env = env

func tick(now_seconds: float, signals: Array) -> void:
    var dt: float = now_seconds - _last_tick_time
    if dt < _tick_interval:
        return
    _last_tick_time = now_seconds

    var entities: Dictionary = _env.get("entities", {})
    for ent_id in entities:
        var ent: Dictionary = entities[ent_id]
        var lc: Variant = ent.get("lifecycle", null)
        if lc == null:
            continue
        var template: Dictionary = _resolve_template(lc)
        if template.is_empty():
            continue

        # Skip terminal entities (already dead)
        var current_stage_id: String = ent.state.get("life_stage", "")
        var current_stage: Dictionary = _find_stage(template, current_stage_id)
        if current_stage.get("terminal", false):
            continue

        # Increment age
        var rate: float = template.get("age_per_in_game_year", 0.0)
        var year_secs: float = template.get("year_seconds", 900.0)
        var delta_years: float = (dt / year_secs) * rate
        ent.state["age"] = float(ent.state.get("age", 0.0)) + delta_years

        # Check transition
        var new_age: float = ent.state["age"]
        if current_stage.has("max_age") and new_age >= current_stage["max_age"]:
            var new_stage: Dictionary = _find_stage_for_age(template, new_age)
            if new_stage.is_empty() or new_stage["id"] == current_stage_id:
                continue
            _transition(ent, current_stage, new_stage, signals)

func _transition(ent: Dictionary, prev: Dictionary, next: Dictionary, signals: Array) -> void:
    var old_id: String = prev.get("id", "")
    var new_id: String = next.get("id", "")

    # Update state
    ent.state["life_stage"] = new_id
    ent.state["speed_mult"] = next.get("speed_mult", 1.0)

    # Swap mesh (null = despawn-eligible)
    var new_mesh: Variant = next.get("mesh", null)
    if ent.has("visual"):
        ent["visual"]["mesh"] = new_mesh
    _request_renderer_remesh(ent.id)

    # Rewrite tags: remove prev abilities, add new abilities
    var prev_abilities: Array = prev.get("abilities", [])
    var new_abilities: Array = next.get("abilities", [])
    if not (new_abilities.size() == 1 and new_abilities[0] == "all"):
        var tags: Array = ent.get("tags", []).duplicate()
        for ab in prev_abilities:
            tags.erase(ab)
        for ab in new_abilities:
            if not tags.has(ab):
                tags.append(ab)
        ent["tags"] = tags

    # Emit signals
    signals.append({"name": "life_stage_changed",
                    "payload": {"entity_id": ent.id,
                                "old_stage": old_id,
                                "new_stage": new_id}})
    if next.get("terminal", false):
        signals.append({"name": "entity_died",
                        "payload": {"entity_id": ent.id,
                                    "lifecycle_id": _template_id_of(ent)}})

func _find_stage(template: Dictionary, stage_id: String) -> Dictionary:
    for s in template.get("stages", []):
        if s.get("id", "") == stage_id:
            return s
    return {}

func _find_stage_for_age(template: Dictionary, age: float) -> Dictionary:
    for s in template.get("stages", []):
        var lo: float = s.get("min_age", 0.0)
        var hi: Variant = s.get("max_age", null)
        if age >= lo and (hi == null or age < float(hi)):
            return s
    # past final stage's min_age = terminal
    var stages: Array = template.get("stages", [])
    if stages.size() > 0:
        return stages[stages.size() - 1]
    return {}

func _resolve_template(lc: Variant) -> Dictionary:
    # Already resolved at load via lib_resolver (ADR 0027)
    if lc is Dictionary:
        return lc
    return {}

func _request_renderer_remesh(entity_id: String) -> void:
    # Hook into entity_node_3d / entity_node_2d to rebuild mesh from new visual.mesh
    pass  # implementation defers to existing renderer mesh-mutation path
```

LoC estimate: ~170 lines (director + helper methods + signal
plumbing). New EngineError code: `LIFECYCLE_TEMPLATE_INVALID`
(stage table missing or malformed).

Schedule integration (ADR 0029) is light — schedule director already
filters by tags; ability-tag rewrites happen automatically on
lifecycle transition, so schedules naturally adapt (a child's
schedule pulls from `gather`-tagged location bindings; an adult's
from `all`).

## Performance budget

- Per-tick cost: O(N entities with lifecycle). At 200 NPCs and
  1-second ticks, that's 200 dict-lookups + 200 small arithmetic
  ops per second. Trivial — well under 0.1ms / tick on the budget
  laid out in ADR 0017.
- Stage transitions: rare events. A 7-hour Phase 1 campaign sees
  ~0-3 transitions across all NPCs. Mesh swaps happen at user-
  imperceptible frequency.
- ADR 0017 spatial-LOD slows ticks for off-screen NPCs; lifecycle
  inherits that (off-screen NPCs age at the slowed rate, which
  is correct — their stage transitions just happen on a coarser
  schedule).
- Memory: 2 floats + 1 short string per lifecycle entity ≈ 30
  bytes. 500 entities × 30 = 15 KB. Negligible.

## Migration / backwards-compat

- Existing demos (merchant, doomarena3d, sokoban, all 13 demos):
  no `lifecycle` field on any entity → no aging behavior → no
  observable change. Test suite must verify zero regressions.
- Saves from existing demos: unchanged. Loaded into a build with
  ADR 0036 active sees no `lifecycle` field on saved entities,
  director skips them.
- Phase 1 Aldenmere build: ships with `age_per_in_game_year =
  0.05` (or even 0.0 if we want absolute schema-only mode). Saves
  carry `age` + `life_stage` fields that Phase 2 build reads
  cleanly when `age_per_in_game_year` is raised.
- Forward-compat: if a future ADR adds new stage fields (e.g.
  `audio_voice_pitch`), missing fields default to neutral values
  (no behavior change). Stage tables are additive.

No deprecations. No state migration code needed.
