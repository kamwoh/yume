# Tech-director review — ADR 0085 (delete unused genre verbs)

_Date: 2026-10-16_
_Reviewer: yume-tech-director_
_ADR status: proposed (not changed — the user approves after this review)_

## Verdict

**Approve with conditions.** The deletion is safe. No shipped content,
save file, or kept primitive needs the 16 effects or the 5 directors. The
Invariant #8 argument holds. The ADR misses about 10 touch points (list
C below). The new gate is not yet enforcing, because nothing runs
`run_all.py --strict` (list D below). Fix C and D in the ADR text before
approval, or in the implementation commit.

## Invariant greps (current tree)

| Invariant | Result |
|---|---|
| #1 JSON-only (`entities.get("…")`) | clean |
| #2 no semantic effect types (blocklist) | clean — but the blocklist does not name any of the 16 verbs, which is the ADR's point |
| #3 no entity-class hierarchy | clean |
| #5 queries first-class | clean |
| #8 primitives + interpreter | **violated today** by the 16 verbs and their directors. The ADR deletes the cause. |
| #10 freeze-policy | not affected. The ADR adds or deletes no `_pending_*` pipeline. |
| #11 / #12 level transition, persistent guard | not affected. `transition_player_to` goes, `switch_actor` stays. |

Visual gate: not applicable. No rendering module changes.
Effect-chain gate: not applicable. No screen, scene or save effect changes.
Tests: not run. The ADR has no code yet. The implementation commit must
show `test_main.tscn` and every demo scenario run ending with
`failed: 0`.

## A. Claim 1 — "no content uses them"

**True for shipped content.** Evidence:

- `grep` for the 16 effect names in `godot/data/**` (13 demos, not 12 as
  the ADR says, plus `lib/`, `test_assets/`, `entities.json`): 0 hits.
  This covers `tests.json`, `screens.json`, `hud.json`, `tutorial.json`
  and every rule file.
- No `factions.json`, `tech_trees.json` or `classes/` anywhere. No
  `party_member` tag. No formula root `faction.`.
- The synced template (`YumeTemplate/data`) has the same 13 demos and 0
  hits.
- Godot `app_userdata` save folders: 0 hits for the effects, `faction` or
  `party_member`.

**Two facts the ADR must state:**

1. `demo_aldenmere` carries `lineage_id` (player and villager defs) and
   `dynasty_id: ""`. These are inert "Phase 4 forward-compat" fields. No
   kept engine code reads them. Only the `DynastyDirector` row in
   `validate_scene_directors.py` reads `lineage_id`.
2. Local (gitignored) design docs plan to use the verbs:
   `docs/games/aldenmere/phase2_GDD.md`, `phase3_GDD.md`, `phase4_GDD.md`,
   `engine_roadmap.md` (all 16 between them) and
   `docs/games/thousandgate/GDD.md` §§ 280, 488-489 (`switch_class`,
   `learn_from_master`). `demo_thousandgate` shipped its career and skill
   systems WITHOUT these verbs. That is good evidence for the ADR's
   "generic verbs cover it" claim, and the ADR should cite it.
   Add one line to Consequences: those GDD mappings are stale and the next
   design pass must remap them to the generic recipes.

## B. Hidden engine dependents (claim 2)

**Signals.** The deleted code emits `class_switched`, `tech_discovered`,
`tech_learned`, `tech_inherited`, `dynasty_succeeded`, `dynasty_extinct`
and `faction_{war_declared,treaty_signed,alliance_formed,loyalty_changed}`.
`PartyDirector` consumes `party_revival`. A repo-wide grep finds no other
producer or consumer. The only hits are docs, ADRs and `test_runner.gd`.

**LifecycleDirector.** It does not call into any deleted director. The
only link is a comment (`lifecycle_director.gd:24`).
`DynastyDirector.handle_dynasty_succession` has no engine caller. Only
`test_runner.gd` calls it. Deleting it leaves no death-signal consumer
behind.

**GridSnap.** Safe to keep. After the deletion, `spawn_manager.gd:150-165`
still calls `should_snap`, `snap_position`, `snap_position_2d`,
`snap_position_with_drift_check` and `snap_yaw`.

**Vec3Util.** Six other kept files still use it. Safe.

**formula_context.** The `faction` snapshot lives in
`core/effects/effect_resolution.gd:174, 197-209`. Side effect of the
deletion: today `out["faction"] = {}` is set before the ctx pass-through
loop, so a signal payload field named `faction` is silently shadowed.
After the deletion it passes through. This is a fix, not a regression.

**world_loader / world_boot / world.gd.** Covered by the ADR, but the ADR
names only `world_loader.gd`. `world_boot.gd` also has `_load_factions()`
(lines 75, 335-339) and a `DynastyDirector` verbose-log block (326-332).

**validate_scene_directors.py.** Rules for `PartyDirector`,
`FactionDirector` and `DynastyDirector` exist (lines 62-79). There are no
rules for `ClassManager` or `TechTreeDirector`. The ADR says "the 5
directors". Fix it to 3.

## C. Touch points the ADR does not list

Add these to Decision § 1 or § 3:

| File | What |
|---|---|
| `core/effect_apply.gd:188-206` | the `effect.unknown_type` hint string lists all 66 effects by hand, including the 16. It becomes stale. |
| `core/engine_error.gd:48-50, 74-99` | `EFFECT_BUILD_PLACE_*`, `CLASS_*`, `FACTION_*`, `TECH_*`, `DYNASTY_*` constants |
| `coordinators/world_boot.gd` | `_load_factions()`, the Dynasty log block, the boot-order doc comment (lines 11, 15) |
| `tools/validators/validate_rules.py:75` | `GLOBAL_ROOTS` lists `"faction"`. After deletion, a formula `faction.x` passes the validator and resolves to null at runtime. |
| `godot/scenes/play.tscn:9-10` | the comment lists the 5 directors |
| `README.md:197, 388` | lists party, faction, class, tech-tree, dynasty as directors |
| `docs/adr/0038-grid-based-placement.md` | covers `build_place` + GridSnap. Mark it partly superseded (GridSnap stays). |
| `world.gd:937`, `grid_snap.gd:8`, `vec3_util.gd:13`, `phase_scheduler.gd:418`, `schedule_director.gd:18,194`, `effect_actor.gd:82`, `validate_signal_entry_shape.py:37-38` | comments that name deleted code |
| `docs/engine-reference/api-manifest.md` | regenerate with the `.json` |

**Sync hazard (must go in the implementation steps).** `play.sh:116` syncs
with `cp -r`, which does not delete orphan files. The 7 deleted `.gd`
files stay in `YumeTemplate/scripts/engine/` with their `class_name`
registered. If `engine_error.gd` loses the `FACTION_*` constants, the
orphan `faction_director.gd` fails to parse at every boot. This is the
same bug class as the 2026-05-15 stale `effect_apply.gd`
(`validate_no_stray_scripts.py`). Step: delete the orphans in the
template, then run `--import` to rebuild the global class cache.
Better gate: extend `validate_no_stray_scripts.py` to flag any `.gd` in
`TEMPLATE_DST/scripts/` that has no source in `godot/scripts/`.

## D. Claim 3 — is the allowlist gate enforcing and complete?

**Not enforcing yet.** `play.sh:129` runs `run_all.py "<game>" || true`.
There is no git hook and no CI. The validator only blocks when a person
runs `run_all.py --strict`. Conditions:

1. State in the ADR who runs it with `--strict` and when. Minimum: add it
   to this skill's "How to review" step 2, so every engine review runs it.
2. Put the gate in `validate_engine_wiring.py` as check C instead of a
   new file. That validator already owns "engine vocabulary vs.
   implementation". `tools/gen_api_manifest.py:555 parse_effects()`
   already parses the `match type:` arms. Reuse it, do not write a second
   parser.

**Not complete.** The genre leak came in through 4 routes. The allowlist
covers 1:

| Route | Example in this ADR | Covered? |
|---|---|---|
| effect `match` arm | `declare_war` | yes |
| director mount row | `FactionDirector` in `world_boot.gd`, `_BOOT_DIRECTORS` in `world.gd` | **no** |
| formula root binding | `faction.` in `formula_context` | **no** |
| optional data file loader | `factions.json`, `classes/`, `tech_trees.json` | **no** |

Conditions:

3. Give the allowlist a `directors` section (each `world_boot.gd` mount
   row → ADR) and a `formula_roots` section (each `out["…"]` root in
   `formula_context` → ADR). The same 3 checks apply to each section.
4. "The ADR file exists" is too weak. ADRs 0030, 0032, 0033, 0034 and 0037
   existed and said "proposed" while their code shipped. That is the
   failure this ADR cites. Require that the named ADR has
   `_Status: accepted` and that its text contains the effect name.
5. Also check that the `effect.unknown_type` hint in `effect_apply.gd`
   lists exactly the allowlist, or generate the hint from the allowlist.

## E. Claim 4 — does a kept primitive need anything deleted?

**No.** I examined these kept items: `GridSnap` (spawn_manager),
`switch_actor`, `queue_input_for_actor`, `reset_world`, `LifecycleDirector`,
`ScheduleDirector`, the `zone` binding, `Vec3Util` and the relation store.
The three actor effects share a file with the party effects, but they are
separate functions. `party_member_of` is only a relation type string that
`party_join` writes. Only `build_place` calls `_apply_chain` in
`effect_adr_extensions.gd`.

## Facts verified

- File sizes: 223 + 341 + 640 + 593 + 463 + 724 + 337 = 3,321 lines. The
  ADR says "about 3,300". The figure is right.
- `PartyDirector` moves members from `_process` (line 81, `set_position`
  at 187 and 201). The ADR 0068 claim is right.
- The generic replacements exist as `match` arms: `relation_set`,
  `relation_add`, `relation_clamp`, `transfer_relation`, `array_*`,
  `switch_actor`, `pathfind_to`, `spawn`.

## Top items for the caller

1. Add the missing touch points in C, especially `validate_rules.py`
   `GLOBAL_ROOTS`, `engine_error.gd`, the `unknown_type` hint, and the
   template orphan cleanup + `--import`.
2. Make the gate enforcing and complete (D 1-5): status `accepted` plus
   name match, and director and formula-root sections.
3. Name the aldenmere and thousandgate GDD mappings as stale in
   Consequences, and fix "12 demos" to 13 and "5 directors" in
   `validate_scene_directors.py` to 3.
