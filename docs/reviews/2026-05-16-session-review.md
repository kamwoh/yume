# Code review — 2026-05-16 engine session

_Date: 2026-05-16_
_Reviewer: yume-code-reviewer (self-review by the author — bias caveat)_
_Subject: `fc8ddc0..e2c97b7` on master (10 commits)_

## Verdict

`accept-with-conditions`

The session's substantive direction is right (post-mortem WASD fix
+ TDTE shape-up + tick-rate contract codification + reviewer skill).
Three conditions before this should be considered fully merged:
fix the bundled commit, verify I-toggle in live play, mark the
pre-existing scenario failures explicitly. Smaller items can land
incrementally.

## What the change does

Ten commits over one session: shipped the inventory I-toggle fix
(across 3 engine modules: `world.gd` freeze gate, `screen_flow.gd`
edge-state sync, `camera_director.gd` mouse-delta clear), gave
quadruped animals working motion (`physics` block + `mesh_yaw_offset`),
renamed `physics.json` → `rules.json` + `rules.json` → `goals.json`
framework-wide, codified the tick-rate contract in `CLAUDE.md`, and
added `yume-code-reviewer` skill.

The author claims TDTE is "essentially complete." The diff backs
that partially — engine work is done; live-play verification of
the user-facing I-toggle is unverified.

## Questions

### Q1 — Why is c221633 four unrelated fixes in one commit?

> `TDTE engine fixes: freeze-gated input, global_inputs edge sync, mouse-delta clear, mesh_yaw_offset`

These are four independent bugs across four files. If `mesh_yaw_offset`
later turns out to be wrong-axis for a future mesh, rolling back
requires also losing the I-toggle fix.

The author's commit message says "Four engine bugs surfaced while
playtesting TDTE inventory + animal motion" — that's the SHARED
CONTEXT (one playtest session), not a shared CHANGE. Stepwise
migration (review reflex #7) wants one commit per concern.

**Author's answer needed before:** acceptance. If "ship velocity
> commit hygiene" is the rationale, that's a fair argument but
should be stated, not silent.

### Q2 — Did anyone verify the I-toggle works in live play?

> Three of this session's engine commits (`c221633`, the screen_flow
> edits, the sync hook) target the I-press toggle. The headless
> harness cannot reproduce because `step_runner` doesn't yield Godot
> frames between `Input.action_press` / `release`. The author
> documented this gap honestly ("logical trace says live play
> works"). But the user reported the I-press still broken once
> during this session — that report's relationship to the LATER
> fixes is unverified.

What gate catches "engine fix not actually tested against the
reported user scenario"? Currently: nothing. The reviewer-axis
"every fix references the empirical case + ships a verification"
is in `.claude/rules/post-mortem.md` step 3 but lives at the
documentation level, not enforced.

**Author's answer needed before:** acceptance. At minimum: a
manual playtest before claiming the bug is fixed, OR a recorded
session video showing I open + close, OR a scenario harness that
yields Godot frames.

### Q3 — `current_target_pos` duplicates `current_target` + position lookup. Why?

> `fc8ddc0 ScheduleDirector also writes current_target_pos for pathfind`

The director writes both `current_target` (id) and `current_target_pos`
(`[x, y, z]` array). Rules can read the array directly via
`pathfind_to destination_x=self.state.current_target_pos[0]`.

If the target ENTITY moves between director ticks, the cached
position is stale. For TDTE this is OK (fire pit, market stall, bed
are stationary). For Phase 2+ where villagers follow each other or
chase moving prey, this becomes wrong.

**Author's answer needed before:** acceptance. Document the
"fixed-position targets only" constraint in the director, OR add
a "dynamic target" branch that re-queries each tick.

### Q4 — Three demos have different tick rates without inline reasons. Per the new contract, that's a violation.

> `9756b37 Codify tick-rate contract: 60Hz default, never warp for balance`

`CLAUDE.md` says: *"A per-game override is legal but should be
deliberate — a slow turn-based game (sokoban) might pick 10Hz to
save cycles..."*

`demo_sokoban/scene.json`: `tick_seconds: 0.1` — **no `_comment_tick`
explaining the choice.**

`demo_doomarena3d/scene.json`: `tick_seconds: 0.05` — **no
`_comment_tick`.**

`demo_aldenmere/scene.json`: `tick_seconds: 0.0167` + a long
`_comment_tick` justifying 60Hz.

The contract is written. Two of three demos violate it on day one.
What's the enforcement?

**Author's answer needed before:** acceptance. Two options:
(a) Add `_comment_tick` to sokoban + doomarena3d's scene.json with
the per-genre reasoning. (b) Write a validator that fails when
`tick_seconds != 0.0167` AND `_comment_tick` is missing or empty.
Either, not both.

### Q5 — The yume-code-reviewer skill shipped without a functional test. How do we know its output is the right shape?

> `e2c97b7 Add yume-code-reviewer skill — Socratic second-pair-of-eyes`

Commit message: "Functional test pending — would invoke on a recent
commit and verify the output is the right shape."

This review IS that test. If the format is wrong / the prompts
unclear / the verdict logic broken, you find out by reading what
follows.

Self-review meta: this skill's output is exactly as awkward as
self-review usually is — I authored both the skill and the work,
so my smells and the smells the skill TRIES to surface overlap.
A real test is the user running the skill on someone else's commit.

**Author's answer needed before:** acceptance. Either declare
the current output adequate, or note specific structural changes
needed for the next iteration.

## Smells

- **`godot/data/meshes.json` (villager_3d primitives)** — `pivot:
  [0, 0.275, 0]` is `height/2 = 0.55/2`. Hardcoded magic. If walk
  proportions change, pivot has to update too. Suggest: derive in
  the renderer (`mesh_lib.gd`) — when `pivot` is missing AND the
  primitive has `name` (addressable), default pivot to
  `[0, height/2, 0]` for cylinders.
- **`phase_scheduler.gd::queue_input`** — `O(n²)` linear scan per
  insert. Acceptable for current scale but undocumented. Suggest:
  inline comment noting the cost + an upper-bound assertion (e.g.,
  if queue.size() > 100, push_warning). Cheap insurance.
- **`tools/validate_no_stray_scripts.py`** — fires only via
  `play.sh` pre-launch. If someone runs `cp` directly to the sync
  target and then opens Godot editor, no check. Suggest: a Godot
  `EditorPlugin` hook OR check the validator from `world_boot.gd`
  at engine boot.
- **`yume-code-reviewer/SKILL.md`** — the embedded review template
  (`## Verdict` / `## Questions` / etc. inside the markdown code
  block) gets picked up by structural greps like `grep "^## " *.md`.
  Cosmetic. Maybe indent the template by 2 spaces inside the code
  fence.
- **`scenario_test.tscn` — 4 pre-existing failures** —
  `fp_wasd_w_alone`, `fp_wasd_release_decelerates`,
  `fp_wasd_speed_clamp_no_diagonal_speedup`. Diagnosed by the
  author as "test design errors" (asserting FP behavior against
  world-frame action names). Diagnosis sounds right, but the tests
  still fail every run. Either fix the assertions or mark them
  `expect_fail` / skip with a `_known_broken` flag.
- **`docs/reviews/` is brand new** — this is the first review file.
  No `README.md` indexing the convention; future reviewers won't
  know the directory exists. Suggest: a 5-line `README.md` naming
  the file convention (`YYYY-MM-DD-<topic>-review.md`) and the
  reviewer skill that produced it.

## Gate posture

| Change | Gate updated? | Suggestion |
|---|---|---|
| `c221633` engine fixes (4 bugs) | Partial — `data-demo.md` updated for `.gd` shadow class. No gate for "engine fix unverified in live play." | Add empirical case to `.claude/rules/post-mortem.md` § live-play verification |
| `a0bde76` queue_input dedup | None | Acceptable — defensive, not bug-driven |
| `9756b37` tick-rate contract | `CLAUDE.md` section added | **Missing enforcement** — see Q4 |
| `d4657b4` rename sweep | `validate_no_stray_scripts.py` introduced for related class-cache hazards | OK |
| `f3d6889` face_motion lib | `validate_lib_refs.py` will check the @lib path | OK |
| `e2c97b7` yume-code-reviewer skill | No gate (it IS a gate) | OK |

## Conditions for accept

- [ ] **Manual live-play verification of I-toggle** before TDTE
  ships. Either you press I twice and confirm in-game, or a
  scenario harness with frame yielding is added.
- [ ] **Sokoban + doomarena3d scene.json get `_comment_tick`** with
  the per-genre rationale. (One sentence each is enough.)
- [ ] **Pre-existing scenario failures** (`fp_wasd_*`) marked
  `expected_fail` or fixed. Currently red noise that masks future
  regressions.

## Out of scope (deliberately not reviewed)

- The 28 game-time rule interval scalings in `world/rules.json`
  (data-side, gitignored). Reviewing would require reading the
  user's local working tree.
- Per-game `screens.json` / `hud.json` / entity-def changes for
  TDTE (same gitignored-content reason).
- Pre-existing engine architecture (world.gd at 577 LoC is fine;
  not a smell.)
- The 4 commits' commit-message prose quality — the message
  conventions are author preference, not a review concern.

## Reviewer's note on self-review

Self-review caught:
- The 4-in-1 bundled commit (would have been hard to admit
  prospectively, easy to flag retrospectively as reviewer).
- The unverified I-toggle (the author KNEW this was unverified
  and documented it — but documentation isn't a fix).
- The tick-contract violation by 2 of 3 demos on the same day
  the contract shipped.

Self-review missed (almost certainly):
- Architectural blind spots that I'd need a different mental
  model to see. The user's review on a future session will catch
  things this review can't.
