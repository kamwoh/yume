# ADR 0076 — Query-bound repeated UI (`list` element)

_Date: 2026-08-16_
_Status: proposed_

## Context

`screens.json` (ADR 0011) and `hud.json` describe a Control hierarchy
element-by-element. Every node is authored by hand. There is no
repetition construct anywhere in `control_factory.gd` or
`hud_builder.gd` — no `for_each`, no template, no data source.

That is fine for a shooter's HUD, where the element count is fixed and
small. It fails completely for any menu-driven game, where nearly every
screen is *"one row per thing that matches a condition"*:

- the people currently in this building
- the goods this shop stocks
- the tasks available at this council
- the entries you have collected
- the party members you can swap in

None of these have a compile-time count. Authoring them by hand means
either a fixed number of pre-made rows with `visible_if` on each (which
caps the list and duplicates the template N times), or generating
`screens.json` from a script every time content changes.

Meanwhile the engine already has the exact primitive this needs. Query
(primitive #6) is a declarative "find the entities matching this" that
the rule system uses everywhere. It has simply never been usable as a
UI data source.

Separately, ADR 0075 deferred read access to relation edge state to this
ADR, because rendering "this person, and how well you know them" is the
only place the read is actually needed and the binding shape is only
decidable here.

## Decision

One new element type, `list`, available in both `screens.json` and
`hud.json`. It runs a Query and instantiates its `item` template once
per match.

```jsonc
{
  "type": "list",
  "from": {                          // any Query spec — REQUIRED
    "tags_all": ["npc"],
    "state": {"location_eq": "town_a"},
    "order_by": "state.rank",
    "relations": {"knows": {"_edge": {"trust_gte": 20}}}
  },
  "bind": "row",                     // binding name (default "row")
  "edge_of": {"relation": "knows", "to": "player"},   // optional, ADR 0075
  "limit": 20,                       // default 50, hard cap
  "separation": 4,
  "item": {                          // any element dict — recurses
    "type": "button",
    "text": "row.properties.display_name",
    "on_click": [{"type": "emit", "signal": "talk_to", "target": "row"}]
  },
  "empty": {"type": "label", "text": "No one here."}   // optional
}
```

**Substitution.** Every string inside the `item` template is rewritten
per row, on the principle that *static data becomes a literal, dynamic
data becomes a binding*:

| Template string | Becomes | Why |
|---|---|---|
| `"row"` | the entity's instance id | so `on_click` effects resolve it as a target |
| `"row.id"` | the entity's instance id | explicit form |
| `"row.properties.X"` | the literal value, at build time | `properties` is static by contract (§1) — it cannot change, so a live binding would be waste |
| `"row.state.X"` under a `binds` key | `"<instance_id>.X"` | `state` IS mutated by rules, so it stays live and re-resolves per frame |
| `"row.state.X"` anywhere else | the literal value, at build time | `text` is evaluated once at build; use `binds` for live text |
| `"row_edge.X"` | the literal edge-state value | ADR 0075 read access, resolved through `edge_of` |

**Binding-root fallback.** `game_shell.gd::_resolve_binding` resolves a
path's root by TAG only. A list row needs to bind to one *specific*
entity, so root resolution gains an instance-id fallback: tag first,
then id. This is a generic improvement — any HUD that wants to bind to a
named singleton benefits — not a list-specific hook.

**Re-evaluation cadence.** The query runs when the element is built AND
on every `World.world_loaded` (a new signal, emitted at the end of each
`load_data()`). It does **not** re-run per frame. Live values inside rows
stay live via `binds`; row *membership* refreshes on those two events.
Per-frame re-querying over a large roster, allocating and freeing Control
nodes every frame, is the obvious performance trap, and menu screens are
opened and closed rather than continuously mutated.

The load signal is not optional polish — two cases require it and
neither can be fixed by deferring a frame:

- **Boot.** The directors that build screens and HUD run their `_ready`
  before `World.load_data()`, so the first populate sees an entity count
  of zero. A `call_deferred` retry was tried first and still fired too
  early (instrumented: `world.entities=0` at frame 0, with
  `[World] loaded: 30 entities` printing afterwards).
- **Level transition.** `load_data()` runs again and swaps the entity set
  out from under any already-open list. Without the signal, an open list
  keeps rendering rows for despawned entities.

A list built with an explicitly supplied env (unit tests) has no world to
listen to and does not subscribe. Subscriptions are dropped on the
container's `tree_exiting`, because a lambda has no owning object for
Godot to auto-disconnect and they would otherwise accumulate one per
screen open.

**Truncation is never silent.** When the match count exceeds `limit`,
the list renders `limit` rows and emits a `push_warning` naming the
element and both counts. A list that quietly drops rows reads as "that's
everything" when it isn't.

## Consequences

**Enables.** Menu-driven UI: shop inventories, character rosters, task
boards, collection screens, dialogue-target pickers, save-slot lists —
all authored as one template plus a query, against a world of any size.
This is the single change that makes Yume able to express an RPG's
screens rather than only an action game's overlays.

**Costs.** `ControlFactory` gains a dependency on Query and on world
access. World access uses the `Engine.get_meta("yume_world")` path that
ControlFactory already uses for `MinimapWidget` — an established
pattern, not a new one. When no world is available (unit tests building
raw specs), a `list` renders its `empty` element or nothing, never
errors.

**Precludes.** Live membership. A row that should appear the instant an
entity spawns needs an explicit rebuild. If a genuine need for live
membership appears, it is a follow-on ADR with a dirty-flag design, not
a per-frame re-query.

**Invariant check (#8).** No new primitive — `list` composes Query
(#6) with the existing element vocabulary. The engine never reads a
field name: `properties.display_name` and `state.rank` are content
vocabulary. A shooter's weapon-wheel, a factory sim's recipe browser,
and a chess game's captured-piece tray are the same element with
different queries.

## Alternatives considered

**A. Generate `screens.json` from a script whenever content changes.**
Rejected: it makes screens a build artifact rather than content,
breaks hand-authoring, and cannot react to runtime state at all (the
list of people in a building depends on where they walked to).

**B. N pre-made rows with `visible_if` on each.** Rejected: caps the
list at N, duplicates the template N times in the JSON, and pays layout
cost for hidden rows. This is what content authors do today, and it is
precisely the workaround this ADR removes.

**C. Re-run the query every frame.** Rejected: allocates and frees
Control nodes continuously, and menu content does not change per frame.
The cadence decision is the substantive part of this ADR.

**D. A `repeater` element that takes a literal array instead of a
query.** Rejected: it would need the array to be maintained by rules
(`array_sync_to_field` etc.), duplicating what Query already computes,
and it could not express relation- or radius-based membership.

## References

- Code: `godot/scripts/engine/ui/control_factory.gd` (`build`, `_build_list`,
  `_populate_list`, `_substitute_row`),
  `godot/scripts/engine/ui/widgets/hud_builder.gd`,
  `godot/scripts/engine/ui/game_shell.gd` (`_find_entity_by_tag` id fallback),
  `godot/scripts/engine/core/world.gd` (`world_loaded` signal)
- Tests: `godot/scripts/engine/tests/test_runner.gd` → `test_ui_list_element`
- Gate: `tools/validators/validate_ui_lists.py` — `from`/`item` present,
  `limit` positive, `edge_of` well-formed, every row reference inside the
  template uses the declared `bind`, and no row reference appears outside a
  list. Every one of those is a SILENT runtime failure: the screen still
  builds, it just renders nothing or shows the raw binding string.
  `validate_screens.py` needs no change — its effect walk already recurses
  generically into `list.item`.
- Related: ADR 0011 (declarative screen flow), ADR 0021 (JSON layer over
  the platform), ADR 0075 (relation state — this ADR carries its deferred
  read access), primitive #6 (Query)
