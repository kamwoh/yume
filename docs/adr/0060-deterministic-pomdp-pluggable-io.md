# ADR 0060 — Deterministic I/O contract: pluggable input source + partitioned observe channels

_Date: 2026-05-30_
_Status: accepted — SHIPPED (2026-05-30). See ADR 0061 for documented deviations._

> **Implementation reality (post-ship correction).** The shipped API differs
> from this ADR's original prose: the canonical hash is
> `DeterminismHash.canonical(world)` (not `canonical_state_hash`); the stdio
> driver autoload is `io/stdio_step_driver.gd` (not `stdio_driver.gd`); and
> input is unified at the **poll/queue seam** (`InputRegistrar.poll` →
> `scheduler.queue_input`), NOT at synthesized Godot `InputEvent`s /
> `parse_input_event` (see ADR 0061's deviation note — don't go looking for
> `parse_input_event`).

> **Scope guard.** This ADR is ONLY the I/O contract — input injection, a
> determinism hash, and external observe channels — serving **automated tests**
> and **AI-plays-the-game (world-model research)**. **Networked multiplayer is
> NOT in this ADR** (it is a downstream consumer; see ADR 0061). Do not
> implement networking, peers, ENet, or lockstep transport from this document.

## Context

Yume's engine is already tick-deterministic by construction: `world._advance()`
is the single canonical tick body that live play, scenario tests, and capture
all route through (tech-director Condition C4, `step_runner.gd` header). World
state at tick N is a pure function of `(initial_state, input_log[0..N])`. State
is already JSON (`entity.snapshot()` at `entity.gd:267`, save/load per ADR
0010). Frames are already capturable (`capture_runner.gd:84`). Input is already
injectable (`step_runner.gd:114`).

Two wants converge on the SAME missing primitive (a third, multiplayer, is a
downstream consumer handled in ADR 0061):

1. **Faithful automated testing.** Scenario tests run *inside* Godot (GDScript
   drives GDScript via `StepRunner`), and `StepRunner` injects input via
   `Input.action_press` — which skips Godot's real event pipeline. This created
   the `_scripted_action_consumed` carve-out (`input_registrar.gd:265-287`) to
   paper over a phantom `is_action_just_pressed` that only exists *because* the
   event pipeline is skipped. `click` calls `button.pressed.emit()` directly,
   never exercising hit-testing / modal-blocking / z-order — the exact bug class
   `validate_screens.py` was bolted on to compensate for.

2. **AI-plays-the-game for world-model research.** An external agent that
   observes the SCREEN (pixels), never the privileged state, and must learn to
   model the hidden state. Yume's explicit JSON state is an unusually clean
   ground-truth answer key for evaluating a learned world model — most pixel-RL
   environments (Atari, Procgen) lock true state inside an opaque simulator.

Both are the same architecture: **the input SOURCE is pluggable; the input
SHAPE is fixed.** Whatever produces input (OS hardware, a Python orchestrator
over stdio, a recorded session) emits a Godot `InputEvent`, merges at ONE point,
and flows through the unchanged engine. The observe side splits into two
channels with different audiences: pixels for the agent, state for the harness
— and for world-model research that split must be a hard wall, not a convention.

This ADR pins the CONTRACT. It does not implement it. Implementation is phased
(see Decision §Phasing) and will be carried out separately.

### Why these two together, and what's deliberately excluded

The agent/harness channel partition is only *load-bearing* under the world-model
framing — for plain testing you could leak state to the harness harmlessly.
Framing the contract as "deterministic POMDP" is what forces the partition to be
a wall. Testing then falls out as a restricted case (a test = scripted input +
state assertions, no pixel channel needed).

**Excluded by design:** networked multiplayer (ENet, peers, authority,
input-replication-over-the-wire) and any rollback/lockstep *transport*. Those
are a separate decision built ON TOP of this contract — ADR 0061. This ADR's
deliverables (one input path, state hash, stdio driver) are what 0061 will
reuse; keeping them here keeps 0060 implementable without touching networking.

## Decision

Adopt the **deterministic I/O contract** with three parts.

### Part 1 — Determinism contract: `canonical_state_hash`

A function `canonical_state_hash(world) -> String`:
- Iterate entities in **id-sorted** order.
- For each entity, serialize `snapshot()` with **state keys sorted** and
  **floats at fixed precision** (precision is part of the contract; pick once,
  document it — `%.6f` is the proposed default).
- Include `world_state` (sorted keys) and `relation_store.snapshot()`.
- CRC/hash the canonical serialization.

This hash IS the determinism contract: same `(initial_state, input_log)` →
identical per-tick hash sequence, run-to-run, machine-to-machine (same arch).
It is independently valuable today as a save/load determinism check, and it is
the proof that Part 2's input rewrite changed nothing observable.

Exposed via `--hash-log=<path>` on the existing `capture_runner.gd`: after each
`_advance()`, append `{"tick": N, "hash": "..."}`.

### Part 2 — One input path: source-pluggable, shape-fixed

All input sources converge at `Input.parse_input_event(ev)`. Below that merge
point there is exactly ONE code path (`_input` → action state →
`world._poll_input` → `scheduler.queue_input` → rule input-phase).

- **Bound actions** (have an `InputMap` binding from `ui/input.json`): build a
  real `InputEvent` by duplicating the action's first bound event and setting
  `pressed`; inject via `Input.parse_input_event`.
- **Engine-injected actions** (`engine_injected: true`, no binding — e.g.
  `stop_x`/`stop_y`): keep a clearly-labeled synthetic `Input.action_press`
  fallback. "Always use InputEvent" is WRONG; these have no event to construct.

`StepRunner._do_press/_do_hold/_do_click` are rewritten onto this path. The
injection logic is extracted into a shared `_inject(input_dict)` reused by
`capture_runner` (file source), `scenario_runner` (test source), and a new
`stdio_driver` (stdin source). `_scripted_action_consumed` is **deleted** (the
bug it papers over ceases to exist once the event pipeline is used).
Tech-director Condition C4 is unchanged — only the injection layer beneath
`_advance` shifts.

### Part 3 — Partitioned observe channels + stdio driver

A new autoload `stdio_driver.gd` (NOT named "lockstep" — that is multiplayer
vocabulary; this driver is general single-env stepping over stdio), active on
`--stdio-step`. Per tick:
1. BLOCK on `OS.read_string_from_stdin()` (the blocking read IS the step
   barrier) — read one JSON input batch.
2. `_inject(...)` each action.
3. `world._advance()` — exactly one tick.
4. Emit, on dedicated file descriptors:
   - **State** (`--state-fd=<n>`): `JSON.stringify(world_snapshot)` +
     `canonical_state_hash`, newline-framed. **Harness-only.**
   - **Frame** (`--frame-fd=<n>`): `store_32(len)` + `store_buffer(img.get_data())`
     where `img = get_viewport().get_texture().get_image()`, length-prefixed
     raw RGBA8 (NO PNG encode). **Agent-only.**

**The wall is load-bearing**: state and frame go to *separate fds*. The agent
process must be physically incapable of reading the state fd (it is handed only
the frame fd). A state leak into the policy contaminates every world-model
result from that run. Enforced by fd partition + process separation, not by
convention.

`--headless` alone has no GPU render → state-only, very fast (determinism
oracle, state-prediction research). Pixel emission requires a rendering context
(`--rendering-driver opengl3`, as `play.sh --capture` already uses) and pays
the synchronous GPU→CPU readback cost of `get_image()`.

### Python harness (reference, `tools/lockstep_sim/` → propose `tools/yume_env/`)

- **`oracle.py`** — run one demo twice with one input log; diff per-tick hashes;
  report first divergent tick + entity. The determinism gate.
- **single-env stepping wrapper** — one Godot process, the observe/act loop
  (`stdin.write(actions)` → read frame + state). A gym-like `Env` for tests and
  AI training. (N-peer / desync-detecting brokers are ADR 0061's concern, not
  this one.)
- Wire framing rule: text fd = newline-framed (`readline` + `json.loads`);
  binary fd = length-prefixed (`read(4)` → uint32 → loop until full — a single
  `read` may return fewer bytes). Never mix binary + text on one fd. Channels
  given to the child via `os.pipe()` + `subprocess.Popen(pass_fds=...)`.

### Phasing (implementation order; each ships CI-testable)

- **Phase 0 — Determinism oracle.** `canonical_state_hash` + `--hash-log` +
  `oracle.py`. Audit existing demos (chess → sokoban → an action demo). Diverging
  demos = the determinism-bug backlog (RNG seeds, Dictionary iteration order,
  float ordering, spatial-index tiebreakers, signal-drain order). Each bug found
  follows the post-mortem ritual; the likely gate is a new validator. **Do this
  FIRST** — it is how Phase 1 proves it changed nothing.
- **Phase 1 — One input path (UNCONDITIONAL).** Rewrite StepRunner onto
  `parse_input_event`; extract `_inject`; delete `_scripted_action_consumed`.
  Ship behind a one-release parity run (scenario suite + per-tick hash through
  both old and new injection, assert identical hash sequences) before removing
  the old path. Valuable independent of everything downstream — it is a
  correctness fix.
- **Phase 2 — `stdio_driver.gd`** + `--stdio-step` + `--state-fd`/`--frame-fd`.
- **Phase 3 — Python harness** (`oracle.py` + single-env `Env` wrapper).
- **Phase 4 (deferred)** — test-runner migration to stdio (only after the stdio
  path is proven on several demos — do NOT rip out `scenario_test.tscn` on spec).

## Phase 0 — implementation notes (2026-05-30, for tech-director review)

Phase 0 landed: `DeterminismHash.canonical(world)`
(`godot/scripts/engine/io/determinism_hash.gd`, new `class_name` — new engine
vocabulary, surfaced here not buried), `--hash-log` on `World`, and
`tools/yume_env/oracle.py`. **No `step_runner`/`input_registrar` changes** (that
is Phase 1). Decisions made that this ADR should ratify or correct:

- **Hash algorithm**: SHA-256 of a recursive canonical string (sorted dict keys,
  preserved array order, `%.6f` floats with ±0.0 collapsed, Vector2/3 as
  component arrays). ADR said "CRC/hash" — SHA-256 chosen for collision-safety.
- **What is "state"**: hashed the FULL `entity.snapshot()` (def/properties/tags/
  visual/state/position) per the literal "serialize snapshot()". This includes
  static fields (constant, harmless but extra cost) and `_`-prefixed transient
  keys. The trajectory recorder instead uses dynamic-only + excludes `_` keys.
  **Open question**: pin the hash to dynamic state (state+position+world_state+
  relations) only? (Cheaper; would also avoid a future false-divergence from a
  legitimately-transient `_` key.)
- **Driver**: `--hash-log` is parsed at `World` and the row is written in
  `write_hash_log_row()` called from BOTH tick paths (`advance_one_tick` AND the
  legacy `scenario_runner` `scheduler.tick()` loop — same manual-trigger pattern
  the trajectory recorder uses). So the hash logs under scenario_runner
  (tick-locked, the oracle's driver) and capture_runner alike — broader than
  "on capture_runner.gd". Multiple Worlds in one process append (scenario suite).
- **New query operator `id` / `ids`** (`query.gd::matches`): match a specific
  instance id, or any id in a set. Added for by-id `expect` assertions (the
  scenario de-legacy) and id-addressed effect targets. This is new game-facing
  query vocabulary (Invariant #8) — documented in `30_framework_primitives.md`
  §6 and unit-tested in `test_runner.gd::test_query`. Rules should still prefer
  tags over hardcoded ids (`data-demo.md`); the primitive is generic.

**Audit result (Phase 0 deliverable — found, NOT fixed):**
- `demo_sokoban` ✓ deterministic (133 ticks, identical).
- `demo_doomarena3d` ✓ deterministic (651 ticks) — the "action demo".
- `demo_aldenmere` ✗ DIVERGENT at tick 1 on `camp_berry_1..10` — scattered
  foragables via the shared global PRNG; `level_seed` is set but PRNG
  consumption order isn't pinned (see backlog). The determinism-bug backlog's
  first entry; fix later via the post-mortem ritual.
- `chess` UNAVAILABLE locally (gitignored demo, not generated) — could not audit.

## Phase 1 — implementation notes (2026-05-30, for tech-director review)

Phase 1 landed: scripted input is now ONE path. `step_runner.gd` no longer
calls `scheduler.queue_input` directly — `_do_press`/`_do_hold` set Godot's
Input state (`Input.action_press`) and drive the SAME `InputRegistrar.poll()`
the live `_process` loop uses (via a new `StepRunner._drive_poll`). The
`_scripted_action_consumed` carve-out is DELETED.

Decisions this ADR should ratify or correct:

- **Seam, not literal `parse_input_event`.** The ADR said "rewrite onto
  `parse_input_event`." The implementation unifies at `InputRegistrar.poll`
  instead: `Input.action_press(action)` + `poll()` reading
  `is_action_just_pressed`/`is_action_pressed`. Net effect is identical (one
  path; scripted == live edge classification + per-tick dedup + per-axis stop),
  with less ceremony than synthesizing `InputEventAction` objects. `poll` IS the
  single seam both live and scripted now share.
- **The carve-out replacement is a real frame boundary.** Godot's
  `is_action_just_pressed` does NOT clear in a synchronous headless run — every
  action pressed earlier in a scenario stays "just pressed," so a naive poll
  re-queues all of them (the `slot_1/slot_2/slot_4` bug found during parity).
  `_do_press`/`_do_hold` now `await get_tree().process_frame` after release to
  clear the edge. This structurally removes the double-fire the carve-out
  masked — no consume-map needed.
- **StepRunner is the sole tick driver in headless mode.** Because StepRunner
  now awaits real frames, `scenario_runner` calls `world.set_process(false)`
  (and `test_step_runner` likewise) so `_process._tick_due` can't inject
  uncontrolled ticks during those frames — preserving deterministic tick counts
  and the Phase 0 hash oracle.
- **scenario_runner now populates `input_actions_press/hold`** from
  `ui/input.json` (mirroring `world_boot`; `auto_start=false` skips world_boot)
  so `poll` classifies each action's edge exactly as live play does.
- **Two latent `await` bugs fixed (masked by StepRunner being synchronous):**
  `scenario_runner`'s scenario loop called `_run_one` un-awaited, and
  `test_runner` called `test_step_runner` un-awaited. Both are coroutines that
  only *appeared* synchronous because `StepRunner.run` never suspended before.
  Once it awaits a frame, the un-awaited callers fire-and-forget → assertions
  resume after RESULTS is tallied (total under-counts). Canary: the RESULTS
  `total` dropping. Generalization (post-mortem 3a): audited all three
  `StepRunner.run` consumers (capture_runner, scenario_runner, test_runner) —
  all now `await`.

**Parity result (the gate before deleting the carve-out):** unit 950/0,
aldenmere 19/0, sokoban 14/0, doomarena3d 25/16 (the 16 are pre-existing
steps[]-vs-live movement/AI gaps, unchanged — out of input scope). Determinism
oracle re-run AFTER the change: `demo_sokoban` ✓ (133 ticks), `demo_aldenmere`
✓ (652 ticks) — the input-path rewrite did not perturb the hash sequence.

**Not live-verified:** the original I-toggle double-open empirical case
(2026-05-17, merchant) couldn't be reproduced in a live capture — no current
demo ships an inventory/map screen-toggle. The invariant is covered by the
rewritten unit gate (`test_step_runner` §13: press queues once; release + one
frame clears the edge → no re-fire). Flagged for re-check when a screen-toggle
demo next exists.

## Phase 2 — implementation notes (2026-05-31, transport contract amended)

Phase 2 landed the **state channel** of the single-env stepping driver:
`stdio_step_driver.gd` (new autoload, active only on `--stdio-step`) +
`tools/yume_env/env.py` (gym-like `YumeEnv.step/reset/close`). Two material
deviations from the original spec — both forced by verified runtime facts, so
this section AMENDS the Part 3 transport contract:

- **Transport: stdout, not inherited fds.** Godot's `FileAccess` WRITE mode
  (`O_CREAT|O_TRUNC`) **cannot open a pipe / FIFO / `/dev/fd/N`** —
  `ERR_FILE_CANT_OPEN` (err 12) on Linux, `ERR_FILE_NOT_FOUND` (err 7) on the
  Windows build (no `/dev/fd`). Verified directly. So the ADR's
  `--state-fd`/`--frame-fd` + `os.pipe`/`pass_fds` design is infeasible: Godot
  can only `FileAccess`-write regular files. The **state** channel therefore
  uses plain **stdout** (newline-framed, `@YUMESTEP@`-sentinel-prefixed JSON so
  the harness ignores Godot's boot-log noise) and **stdin** for the action
  batch. This is pure stdio — no networking (scope guard intact). The blocking
  `OS.read_string_from_stdin()` IS the step barrier (verified to block + read
  per line). `--state-fd` is dropped from the contract.
- **Runtime: native LINUX Godot binary.** The project's Windows-Godot-via-WSL
  build can't do reliable stdin/stdout piping (CLAUDE.md) nor open `/dev/fd`.
  The env runs `/home/kamwoh/godot-linux/Godot_v4.6.1-stable_linux.x86_64`
  (same build hash `14d19694e` as the Windows binary). The Windows binary stays
  for interactive play/capture. `YUME_GODOT_LINUX_BIN` overrides.
- **Frame (pixel) channel — BUILT (2026-05-31), regular-file transport.** It is
  the only part needing a non-stdout transport (binary RGBA can't go through
  `print`). Decision: a **regular file** (`--frame-file=<path>`), not localhost
  TCP — `FileAccess`-compatible, no networking (scope guard intact). Each step
  writes `store_32(w) store_32(h)` + raw RGBA8 to the file (overwritten per
  tick), and the stdout state line carries a `frame` block; the file is closed
  BEFORE the state line is emitted, so a reader that waits for the state line
  never sees a partial frame. `env.py frames=True` launches with
  `--rendering-driver opengl3` (NOT `--headless` — the viewport needs a GL
  context; Mesa **llvmpipe** software GL works in WSL, no display required) and
  returns the frame as a `(h,w,4)` numpy array. Pays a synchronous GPU→CPU
  readback per step, so it's opt-in; state-only (`--headless`) stays the fast
  default. The state/frame **wall** (Part 3): mechanism-separated (state→stdout,
  frame→file) and ready to enforce by handing an agent only the frame path — but
  with no agent consumer yet there is a single reader, so the hard process/fd
  partition is not exercised. Enforce it when a pixel-agent lands.
- **Sole-tick-driver discipline (Phase 1 carryover):** the driver calls
  `world.set_process(false)` so wall-clock frames can't `_tick_due` an extra
  tick; one stdin line = exactly one `advance_one_tick`. Input is injected
  through the Phase 1 `InputRegistrar.poll` seam (one path). Actions are treated
  as a per-tick held set (the gym/RL model).
- **Env project excludes render assets.** `env.py::ensure_project` rsyncs the
  source `godot/` to a dedicated Linux project (`/home/kamwoh/godot-linux/yume`,
  separate `.godot` cache, keeps source clean) **excluding `data/*/assets/`** —
  importing ~1.7GB of Tripo `.glb` took >5min and is pointless for state-only
  (meshes are renderer-side; sim state is mesh-independent). 1.7GB → 19MB,
  near-instant import.

**CI gate (`tools/yume_env/test_env.py`):** sokoban deterministic across two
separate env processes (6 ticks, identical hashes) + hashes change across steps
(env truly advances the sim) + aldenmere (3D, meshes excluded) steps via the
state channel + frame channel emits a non-black 960×540 RGBA frame per step
(GL-tolerant: SKIPs rather than fails if no rasterizer). All pass.

## Consequences

**Positive.**
- One input path → tests exercise the real event pipeline (hit-testing,
  modal-blocking, z-order); the `validate_screens.py` bug class is caught by
  tests, not a bolt-on validator. `_scripted_action_consumed` carve-out gone.
- "Scripted input" and "AI input" become the same code as real input — the
  engine cannot distinguish source. (This is also the property ADR 0061's
  multiplayer needs; it inherits one clean path instead of two.)
- `canonical_state_hash` is a determinism gate usable today (save/load) AND the
  parity proof for Phase 1 AND the eval anchor for world-model research.
- Yume becomes a clean deterministic POMDP: hidden state is explicit JSON, so
  world-model latents can be linearly probed against ground-truth fields — a
  supervision/eval target most pixel-RL environments can't offer.
- Recorded sessions replay bit-identically without re-running the AI (the ACTION
  is logged, not the reasoning); pixels regenerate from state, so the research
  corpus is just input logs (tiny).

**Negative / cost.**
- Phase 0 will surface latent nondeterminism that single-player tolerated. That
  is work, not a side effect — it is the point, but it is unbounded until the
  audit runs.
- Pixel emission is GPU-readback-bound; serious training throughput needs a later
  shared-memory upgrade (only the frame reader changes; the handshake stays).
- One env per process stepped serially; RL parallelism = N processes (asyncio /
  gym.vector), more infra.
- `canonical_state_hash` float precision is a cross-platform hazard (float math
  differs across archs/compilers); the contract bounds it to same-arch, with
  fixed-precision serialization as mitigation — not a guarantee of bit-identical
  cross-platform floats.

**Neutral.**
- Mouse-look (`InputEventMouseMotion`) is a known StepRunner gap; pixel-based AI
  for an FPS needs a `{"look":[dx,dy]}` action or raw-event support.
  Canonical-actions-only (ADR 0043 universal input) is cleaner for wire/hash/
  replay; mouse-look is the awkward exception to resolve when an FPS needs it.

## Alternatives considered

- **Keep `Input.action_press` (status quo).** Rejected: leaves two input paths
  and the carve-out; any downstream consumer (AI, and later multiplayer)
  inherits the divergence and the bug class. Phase 1 is cheaper than debugging
  drift caused by scripted-vs-real input divergence.
- **Single combined observe channel (state + pixels together).** Rejected:
  defeats the POMDP wall (agent could read state), and mixes binary + text
  framing on one fd. Two fds is simpler AND safer.
- **In-engine AI only (extend `ai_policy`, ADR 0018) for the agent.** Rejected
  for the *research* agent: a learning agent is a "player," lives outside the
  deterministic core, must observe pixels not state. `ai_policy` remains correct
  for NPCs / shipped opponents that must be in the deterministic replay. The
  line: in the replay → in-engine; a player → outside.
- **Fold multiplayer into this ADR.** Rejected (2026-05-30, user direction):
  multiplayer is a downstream consumer with its own decisions (lockstep vs
  rollback, authority, transport). Bundling it risks an implementer of the I/O
  contract drifting into networking. Split to ADR 0061, which depends on this.

## References

- Code: `godot/scripts/engine/qa/step_runner.gd` (`_do_press/_do_hold/_do_click`,
  `_inject` to extract), `godot/scripts/engine/io/capture_runner.gd`
  (`--hash-log`, `get_image()` at :84), `godot/scripts/engine/io/input_registrar.gd:265-287`
  (`_scripted_action_consumed` to delete), `godot/scripts/engine/core/entity.gd:267`
  (`snapshot()`), `godot/scripts/engine/io/save_state.gd` (world snapshot shape),
  `godot/scripts/engine/core/world.gd` (`_advance`, `_poll_input`).
- New: `godot/scripts/engine/io/stdio_driver.gd`, `tools/yume_env/{oracle.py, env.py}`.
- Godot APIs: `OS.read_string_from_stdin` / `OS.get_stdin_type`,
  `Input.parse_input_event`, `Viewport.get_texture().get_image().get_data()`.
- Related ADRs: 0010 (save/load — state serialization), 0018 (actor-policy —
  in-engine AI), 0039 (StepRunner step verbs), 0043 (universal input library).
  **ADR 0061 (multiplayer) depends on this contract.**
- Design + phased plan: `.claude/plan/world-model-multiplayer.md`.
- Rules: determinism-audit bugs follow `.claude/rules/post-mortem.md`; new
  vocabulary is documented per `.claude/rules/engine-scripts.md`.
