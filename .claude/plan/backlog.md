# Yume — live backlog

_Last updated: 2026-06-08_

The **actionable** backlog only. Full session history + decision log lives in
[`archive.md`](archive.md) (the former 5k-line `task_plan.md`). Add new work
here; when an item ships, delete it (the archive keeps the record). Keep this
file short enough to read in one screen.

---

## Active — text-to-3D scene pipeline (`/yume-create-scene`)

- [ ] **Camera intrinsics.** Per-scene projection-mode override
      (perspective ↔ orthographic) + `clip_near`/`clip_far`/`focal_length_mm`
      in `_apply_ortho`. Goal: match the hero-reference framing. (You flagged
      this to revisit after tiny_village.)
- [ ] **Fence gaps (minor).** Ellipse-tiled fence ring leaves small gaps
      between sections; overlap at `section_len × 0.9` if a flush look is wanted.
- [ ] **Water system** — DEFERRED. Box-mesh + FRONT_FACING underwater works but
      is off by default for new scenes. Revisit when a scene needs water.
- [ ] **MultiMesh for repeated `.glb`** — perf path for scenes with many
      instances of one mesh (trees/rocks). Deferred until a scene needs it.

## Active — 3rd-person shell

_Done: walk/idle/run/jump animation, sprint, mouse-wheel zoom, instant follow.
Jump works in live play + is config-driven (`scene_config.json` `shell`
block: jump_impulse/gravity)._

- [ ] **Step-up for stairs (CharacterBody3D has none).** Floor params now keep
      detection correct + ride shallow steps (ADR 0062), but tall stair risers
      still block the player. Add detect-step-ahead-within-max-height + lift.
- [ ] **Camera collision.** Raycast player→desired-camera-pos; pull in when a
      wall/tree is between. (Partial raycast exists in camera_director; verify.)
- [ ] **3rd-person HUD framing.** Vitals/minimap/crosshair positions tuned for
      top-down were never re-framed for behind-shoulder.

## Active — UI harness (HUD / screen authors)

- [ ] **yume-visual-designer pass** on aldenmere HUD + inventory.
- [ ] **Inventory detail panel** — richer than `Held: <id>`.
- [ ] **More screen presets** (dialog, save-slot, level-select).
- [ ] **Screen-author regression test** in the harness test suite.

## Active — engine / ADR

- [ ] **ADR 0057 Phase B** — `yume-visual-tester` skill (objective per-game
      visual assertions).
- [ ] **ADR 0058 Phase A/B** — shader templates → composable shader primitives.

## Design — deterministic I/O contract (tests + AI-play + world-model)

ADR **0060** (proposed) — pure I/O contract. Design + phased plan:
[`world-model-multiplayer.md`](world-model-multiplayer.md). Handed to a SEPARATE
Claude instance to implement; do NOT write engine code for this from the design
session. Multiplayer is SPLIT OUT to ADR 0061 (decision-only, depends on 0060).

_Phase 0 + determinism audit DONE (2026-06-08): hash + `--hash-log` +
`oracle.py` shipped; sokoban / doomarena3d / aldenmere all verified
DETERMINISTIC (the aldenmere scatter divergence was fixed by per-pattern
seeded RNG, gated at test_runner.gd:2026). See archive.md._

- [ ] **Phase 0 contract ambiguities to confirm (ADR 0060 amendment / tech-
      director):** (a) hash algorithm — used SHA-256 of a canonical string (ADR
      said "CRC/hash"). (b) what counts as "state" — hashed the FULL `snapshot()`
      incl. static def/properties/tags/visual (literal ADR reading); dynamic-only
      (state+position+world_state+relations) would be cheaper + is what the
      trajectory recorder uses. (c) `_`-prefixed transient keys included (full
      snapshot); trajectory excludes them. (d) driver — `--hash-log` wired at the
      World tick level (works under scenario_runner AND capture_runner), oracle
      uses scenario_runner (tick-locked) not capture_runner; ADR said "on
      capture_runner.gd". All defensible; flagged not buried.
- [ ] **Phase 1 (unconditional)**: rewrite StepRunner press/hold/click onto
      `Input.parse_input_event`; delete `_scripted_action_consumed`. Parity run
      (both paths, identical hash sequences) BEFORE deleting the old path.
- [ ] **Phase 2/3**: `stdio_driver.gd` (`--stdio-step` + dedicated state/frame
      fds, the hard wall) + Python `oracle.py` + single-env `Env` wrapper.
- [ ] **Phase 4 (deferred)**: migrate `scenario_test.tscn` to stdio (only after
      stdio path proven on several demos).

## Design — networked multiplayer (DECISION-ONLY, behind 0060)

ADR **0061** (proposed, decision-only) — input-replicated strict lockstep over
0060's contract; rollback = per-game opt-in, deferred. NO implementation
scheduled — 0060 must land + determinism audit must pass first. This is the
"Tier 4 / future" hold turned into a decided path, not a build order.

## Housekeeping

- [ ] (Optional) `docs/33_yume_full_architecture.md` — mark superseded sections.
- [ ] (Optional) move one-off tools (`gen_primitive_cylinder`, `inspect_glb`,
      `synth_test_glb`) under `tools/oneoff/`.
