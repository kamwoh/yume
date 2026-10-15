# ADR 0085 — Delete the unused genre verbs and their directors

_Date: 2026-10-16_
_Status: accepted 2026-10-16 (revision 2, after the tech-director review)._

_Supersedes: ADR 0026 (party), 0030 (class), 0032 (faction), 0033 (tech tree), 0034 (dynasty), 0037 (build placement)_

## Context

The engine ships 16 effect types that name one genre's mechanics:

| Group | Effects | Engine code | ADR |
|---|---|---|---|
| Party | `party_join`, `party_leave`, `party_ko` | `effect_actor.gd`, `party_director.gd` | 0026 |
| Build | `build_place` | `effect_adr_extensions.gd`, `build_validators.gd` | 0037 |
| Class | `switch_class` | `class_manager.gd` | 0030 |
| Faction | `declare_war`, `sign_treaty`, `propose_alliance`, `swear_loyalty` | `faction_director.gd` | 0032 |
| Tech tree | `try_discover_tech`, `learn_from_master`, `pass_to_apprentice` | `tech_tree.gd` | 0033 |
| Dynasty | `transfer_inventory`, `transfer_reputation`, `transfer_techs`, `transition_player_to` | `dynasty_director.gd` | 0034 |

On 2026-10-16 a search found these facts:

- **No content uses them.** None of the 13 demos, no `data/lib` bundle,
  no `tests.json`, `screens.json`, `hud.json` or `tutorial.json`, and no
  save file names any of the 16 effects. No demo has `factions.json`,
  `tech_trees.json` or a `classes/` folder. No entity has the
  `party_member` tag. No formula reads `faction.`.
- **They break Invariant #8.** The engine is a fixed set of generic verbs.
  `declare_war` and `learn_from_master` are genre semantics. The
  no-genre-leak grep in `engine-scripts.md` did not catch them, because
  it is a blocklist of other names.
- **They cost a lot to keep.** The six files hold about 3,300 lines. Their
  test sections in `test_runner.gd` hold about 2,500 lines. WorldBoot
  mounts 5 directors for them in every game.
- **One has a known bug.** `PartyDirector` writes positions from
  `_process`, which breaks the fixed-rate rule of ADR 0068.
- ADRs 0030, 0032, 0033, 0034 and 0037 still say "proposed", but their
  code shipped.

The generic verbs already cover each mechanic. ADR 0075 relation state
(`relation_set`, `relation_add`, `relation_clamp`) holds faction stance
and tension. `state_set` holds a class. The `array_*` effects hold known
techs. `transfer_relation`, `spawn` and `switch_actor` cover succession.
A `party_member` tag with a relation and `pathfind_to` makes a follower.
`demo_thousandgate` already works this way: it keeps trust per NPC with
`relation_add` and four rank tracks with `state_set` and `state_add`.

## Decision

### 1. Delete

- The 16 effect cases in `effect_apply.gd`.
- `effect_adr_extensions.gd` (all of it), and `party_join`,
  `party_leave` and `party_ko` in `effect_actor.gd`.
- The directors `party_director.gd`, `class_manager.gd`,
  `faction_director.gd`, `tech_tree.gd` and `dynasty_director.gd`, and
  their 5 mount rows in `world_boot.gd`.
- `util/build_validators.gd`. Its only caller is `build_place`.
- The data hooks: `factions.json` loading in `world_loader.gd`, the
  class and tech-tree rows in `world.gd`, and the `faction` snapshot in
  `formula_context`.
- Their test sections in `test_runner.gd`.
- The rest of their wiring, which the tech-director review found:
  - `_load_factions()` and the Dynasty log block in `world_boot.gd`.
  - The `FACTION_*`, `CLASS_*`, `TECH_*`, `DYNASTY_*` and
    `BUILD_PLACE_*` constants in `engine_error.gd`.
  - The `faction` formula root in `validate_rules.py`.
  - The hand list of valid effects in the `effect.unknown_type`
    message. It comes from the dispatcher instead.
  - The comments in `play.tscn` and `README.md`.
- The leftover copies in YumeTemplate. `play.sh` copies with `cp -r`, so
  deleted `.gd` files stay there, and a leftover `faction_director.gd`
  fails to parse once its constants are gone. The change deletes them
  and runs `--import`.

### 2. Keep

`GridSnap` (the spawn manager uses it), `LifecycleDirector`,
`ScheduleDirector`, `switch_actor`, `queue_input_for_actor`,
`reset_world` and the `zone` formula binding.

### 3. Update the docs in the same commit

- ADRs 0026, 0030, 0032, 0033, 0034 and 0037 get
  `_Status: superseded by ADR 0085_`.
- `30_framework_primitives.md`, `33_architecture.md`,
  `00_what_yume_is.md`, `yume-flow.md`, and the regenerated
  `api-manifest`.
- `CLAUDE.md`: WorldBoot mounts 9 directors, not 14.
- `yume-lifesim-designer`: the career, skill and faction rows point to
  the generic recipes above.
- `validate_scene_directors.py`: delete the rules for the 3 directors
  that it checks.
- ADR 0038 and other text that cites the deleted directors.

No deprecation shim. A game file that names a deleted effect gets the
existing `effect.unknown_type` error.

### 4. Gate: a vocabulary allowlist

`tools/validators/engine_vocabulary.json` maps each engine vocabulary
item to the ADR that added it. It covers three kinds, because each one
let a genre system in:

- effect types (the `match type:` arms in `effect_apply.gd`, read with
  `gen_api_manifest.parse_effects`),
- the directors that `world_boot.gd` mounts,
- the formula roots in `formula_context`.

A new check in `validate_engine_wiring.py` fails when:

- the engine has an item that the allowlist does not list,
- the allowlist lists an item that the engine does not have,
- an entry's ADR file is missing, its status is not `accepted`, or its
  text does not name the item.

The status test matters: ADRs 0030 to 0037 stayed `proposed` while their
code shipped. The blocklist grep stays as a second check.

**Make it block.** Today nothing blocks a commit: `play.sh` runs
`run_all` with `|| true`, and there is no CI or hook. This ADR adds a
tracked `.githooks/pre-commit` that runs the repo-wide validators. It
takes effect after `git config core.hooksPath .githooks`, which the user
runs or approves. Batch G CI then runs the same validators.

## Consequences

**Positive:**

- About 5,800 fewer lines (engine and tests), and 5 fewer directors in
  every game.
- The ADR 0068 bug in `PartyDirector` goes with it.
- Each effect in the engine has a named ADR.

**Negative:**

- A future game that wants factions or a tech tree composes them from
  generic verbs, or writes a `@lib` bundle. The old code stays in git
  history (the commit before this ADR lands).
- `test_runner.gd` loses tests that also exercised relations and
  signals. The generic tests for those primitives stay.
- Local, gitignored design docs plan to use these verbs: aldenmere
  phases 2 to 4, `engine_roadmap.md` and the thousandgate design doc.
  The next design pass on those games must use the generic verbs.

## Alternatives considered

**A. Move each verb to a `@lib` bundle** (the first batch D plan).
About 3 days of work, with no demo to test the bundles against. It
builds content that no game asked for. Rejected for now. A game that
needs one can make the bundle then.

**B. Keep them.** The cost and the Invariant #8 break stay. Rejected.
