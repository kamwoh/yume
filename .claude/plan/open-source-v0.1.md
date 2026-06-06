# Open-source v0.1 — plan (parked; resume after the pipeline unification)

_Status: notes — captured 2026-06 during the v0.1 discussion. Resume after the
unified pipeline lands._

## v0.1 scope (decided)
- **Unify the pipelines** ✅ LANDED at code+skill level (ADR 0067, 2026-06-06):
  `/yume-design` gains `--scene` (World layer via `compose_world`) + auto-run
  `--with-assets` (Assets layer via `yume_assetgen`). Three layers, disjoint
  file ownership, no clobber. `compose_world` made **scene-only + flat** (no
  `levels/`/`flow.json`/`world/state.json`); `compose_shell` writes flat
  `entities/shell_singletons.json`. Verified: flat scene boots (78 entities,
  no flow needed). `/yume-create-scene` documents its World half is reused by
  `/yume-design --scene`. **Still TODO:** a real end-to-end `--scene
  --with-assets` run once API keys are wired (needs image-gen + Tripo).
- text → playable **single-player** game, end-to-end.
- no multiplayer, no video-recording in the v0.1 story.

## scatter-count gate gap (found 2026-06-06 during the lanterns run)
- `compose_world`'s `scatter_in_mask` strategy IGNORED the catalog's
  `expected_count` → 1220 rocks + 239 trees (1510 total) from a catalog asking
  for ~30. The `/yume-create-scene` SKILL *documents* "scatter counts come from
  expected_count, never mask-fill" but `lib_extract_dispatch.scatter` doesn't
  ENFORCE it (prose rule, no code gate). Worked around by post-trim for the run.
- **Gate to add** (post-mortem step 3): make `scatter_in_mask` cap at
  `expected_count` (× a spread factor), OR a validator that fails when a class's
  emitted instance count exceeds `expected_count` by a large factor. Owner:
  `lib_extract_dispatch` scatter method.

## tools/* audit (2026-06-06) — follow-ups
- **No dead code** — every `tools/visual_layout/` module has a live consumer.
- `compare_semantic.py` is documented in `/yume-create-scene` (placement-
  fidelity comparator) but **untracked in git** — decide: `git add` it (it's
  real tooling) or leave as a local helper.
- `yume-extract-author` skill (the per-scene-LLM-**script** flow) is
  **superseded** by (a) `lib_extract_dispatch` strategy library and (b) the
  documented per-scene `data/<game>/extract.py` path. Decide: retire the skill
  or keep as a labelled fallback.
- `compose_map` (level-instance authoring) vs `compose_world` (3D scene) —
  disambiguated in `pipeline-stability.md`; names still invert the expected
  map⊂world relationship (cosmetic; rename deferred, would churn skill refs).

## OSS release checklist (do after unification)
- [ ] **LICENSE** — pick MIT (max adoption) or Apache-2.0 (patent grant). Godot
      is MIT → compatible. *Legally required — without it nobody may use it.*
- [ ] **Ship ≥1 runnable demo committed to the repo** — demos are gitignored, so
      a fresh `git clone` currently has NOTHING to run. Un-ignore one polished
      no-API-key game so `clone → play.sh demo_X` works out of the box.
- [ ] **CHANGELOG.md** (keepachangelog format) + tag `v0.1.0` + GitHub Release.
- [ ] **ROADMAP.md** — 3–5 bullets derived from the README Known-gaps table
      (next / later / someday). Each gap closed = a roadmap item.
- [ ] **CONTRIBUTING.md** — note the "built by/for Claude" workflow; issues +
      discussions welcome.
- [ ] **README** — add a status badge (experimental / pre-1.0) + a demo GIF.
- [ ] **Secrets/PII scan** — machine-specific paths swept 2026-06-06:
      - ✅ `scripts/play.sh` — 3 fully-hardcoded `app_userdata` paths consolidated
        into `USERDATA_DST` (derives Windows user from `YUME_TEMPLATE_DST`,
        overridable via `YUME_USERDATA`); 2 remaining defaults documented +
        overridable.
      - OK (overridable `os.environ.get("YUME_*", default)` defaults — same
        pattern): `scripts/net_video.py`, `tools/yume_env/oracle.py`,
        `tools/yume_env/env.py`, `tools/validators/validate_no_stray_scripts.py`.
      - ❌ STILL fully-hardcoded (no override) — normalize to `YUME_*` env or
        delete: `scripts/vqa/merchant_walkthrough.sh` (4× + a "merchant"
        commercial-name concern — candidate for deletion), `scripts/run_linux.sh`
        (2×), `tools/visual_qa/run_plan.py` (3×), `tools/yume_codegen/tests/test_smoke.py` (1×, likely a comment).
      - Confirm no API keys are committed (keys are env vars — verified none in
        tracked files during this session).
- [ ] (optional) a simple CI GitHub Action that runs the unit tests.

## Versioning convention (decided)
- `0.MINOR.0` = a coherent new capability/theme, tested. `0.x.PATCH` = fixes.
  `1.0.0` later = the 7 primitives + JSON schema are frozen (a stability
  promise) — far off, stay 0.x, that's honest.
- Tag at meaningful tested states, not per-commit.

## Marketing notes (for the launch post)
- Hooks: "a game framework written entirely by an AI, designed to be operated by
  an AI" + "a programmable explicit world model that bridges to neural world
  models." Lead with the hook + a 30s demo GIF.
- Be honest about scope (the Known-gaps table = trust). Post to Show HN,
  r/gamedev, r/proceduralgeneration, Godot community, AI/RL circles.

## Play-mode inheritance (user direction 2026-06-06) — follow-up ADR
- Generalize **"play modes" as inheritable lib bundles** so a same-type game is
  just assets + scene + a few rules (OOP-inheritance feel; minimal per-game
  JSON). Primitive already exists: `data/lib/` + `@lib.X.Y` / `$include`
  (ADR 0027/0043).
- Concrete: lift `compose_shell`'s third-person explorer shell (player +
  walk/jump/sprint/camera rules + input) into
  `data/lib/play_modes/third_person_explorer/`; games `$include` it + override
  assets/scene/rules. Same for top-down-shooter, platformer, top-down-rts.
- Lands AFTER ADR 0067 (which made `--scene` reuse `compose_shell` as the walk
  play mode). The library makes that bundle reusable by NON-`--scene` games too.
- Memory: `project-play-mode-inheritance`.

## Roadmap themes beyond v0.1 (the pipeline fragmentation = the roadmap)
- v0.x: `--with-assets` truly end-to-end (auto-run generate) — folded into the
  v0.1 unification.
- v0.x: multiplayer hardening (client prediction, real-internet, persistence).
- v0.x: the RL/stepping env as a first-class `gym.Env` (batching, reset).
