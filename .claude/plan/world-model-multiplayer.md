# Plan — Yume as a deterministic POMDP (multiplayer + AI-play + world-model research)

_Created: 2026-05-30_
_Status: ADRs WRITTEN, SPLIT IN TWO (user direction 2026-05-30 — keep
multiplayer OUT of the I/O contract so its implementer can't drift into
networking):_
- _`docs/adr/0060-deterministic-pomdp-pluggable-io.md` (proposed) — the I/O
  contract ONLY (input path + state hash + observe channels; tests + AI-play).
  Implementation handed to a SEPARATE Claude instance; this design session does
  NOT write engine code._
- _`docs/adr/0061-networked-multiplayer-lockstep.md` (proposed, DECISION-ONLY) —
  multiplayer model (input-replicated lockstep); depends on 0060; NO impl
  scheduled until 0060 lands + determinism audit passes._

_NOTE: this doc predates the split and still uses the unified framing + the name
`lockstep_driver.gd`. The ADRs are authoritative: the driver is renamed
`stdio_driver.gd` in 0060 (general single-env stepping; "lockstep" is 0061's
multiplayer vocabulary), and §4 (multiplayer) + the Python `broker.py` N-peer
desync detector belong to 0061, not 0060's Phases 0-4._

This is a forward-looking design + phased plan, not committed work. It
captures a multi-turn design discussion (2026-05-30). Nothing here is built
yet. The first concrete deliverable is an **ADR**, not code.

---

## 1. Goal

Make Yume's "explicit world model" (JSON-declarative state) the foundation
for three things that turn out to be **the same architecture**:

1. **Cleaner automated testing** — scenario tests driven from outside the
   engine instead of GDScript-drives-GDScript.
2. **Multiplayer** — currently single-instance only (deferred to "Tier 4",
   `docs/30_framework_primitives.md:853`). No networking layer exists.
3. **AI-plays-the-game for world-model research** — an external agent that
   observes the SCREEN (pixels), never the privileged state, and must learn
   to model the hidden state. Yume's explicit JSON state becomes the
   ground-truth answer key for evaluating the learned model.

The unifying idea: **the input SOURCE is pluggable; the input SHAPE is
fixed.** Everything (human, test, AI, remote peer) produces a Godot
`InputEvent`, merges at ONE point, and flows through the existing engine
unchanged. Tests + multiplayer + AI + replay all fall out of one contract.

---

## 2. Why Yume fits this unusually well

- **Tick-deterministic rule engine.** `world._advance()` is the single
  canonical tick body; live play, scenario tests, and capture all route
  through it (tech-director Condition C4). State at tick N = pure function of
  (initial_state, input_log[0..N]).
- **State is already JSON.** `entity.snapshot()` (`entity.gd:267`) +
  save/load (ADR 0010) already serialize the whole world to a Dictionary →
  `JSON.stringify`. "Emit state" is a redirect, not new code.
- **Frames are already capturable.** `capture_runner.gd:84` does
  `get_viewport().get_texture().get_image()`. "Emit pixels" = same call,
  minus PNG encode (`img.get_data()` → raw bytes).
- **Input is already injectable.** `step_runner.gd:114` synthesizes input
  via `Input.action_press`. The plumbing exists; it just isn't the *clean*
  path yet (see §4 Move 1).

This is **deterministic simulation testing** (FoundationDB / TigerBeetle
pattern) + a **POMDP research environment** in one.

---

## 3. The architecture (one input path, partitioned observe channels)

```
SOURCE (pluggable)              SHAPE (fixed)            DOWNSTREAM (unchanged)
─────────────────               ─────────────            ──────────────────────
OS hardware ──────────┐
Python orchestrator ──┤──► InputEvent ──► parse_input_event ──► world._poll_input
ENet peer (future) ───┘         ▲                                ──► rule engine → tick
                                │                                       │
                          THE MERGE POINT                               ▼
                     (below here: ONE code path)                  state + frame
```

### Observe side — TWO channels, strictly partitioned by audience

```
              GODOT (rule engine → state → renderer)
                        │                    │
              STATE (JSON + hash)      PIXELS (raw frame buffer)
                        │                    │
                        ▼                    ▼
              ┌──────────────────┐   ┌──────────────────┐
              │ HARNESS / EVAL    │   │   AI AGENT        │
              │ reward, scoring,  │   │ policy(pixels)    │
              │ determinism hash, │   │ → actions         │
              │ GROUND-TRUTH      │   │ NEVER sees state  │
              └──────────────────┘   └──────────────────┘
```

**The wall is load-bearing, not cosmetic.** For world-model research the
agent process must be *physically incapable* of reading the state channel
(separate fd / socket, not "we politely don't pass it"). A state leak into
the policy contaminates every result from that run. POMDP: pixels are the
observation; JSON state is the hidden variable the model must predict.

### Every consumer is the same observe/act loop

| Consumer       | Observe            | Decide             | Act          |
|----------------|--------------------|--------------------|--------------|
| Human          | screen render      | brain              | OS event     |
| Test           | reads state/assert | scripted schedule  | JSON steps   |
| AI bot         | reads PIXELS only  | `policy(obs)`      | JSON actions |
| Multiplayer    | reads merged state | remote human       | JSON actions |

Rows 2-4 go through Python/stdio. Below `parse_input_event`, identical.

### In-engine vs out-of-engine AI (don't confuse)

- **In-engine `ai_policy`** (ADR 0018) — NPCs / enemy behavior. GDScript,
  deterministic, runs INSIDE the sim, must be reproducible from the input
  log. A wandering villager can't be a Python subprocess.
- **Out-of-engine orchestrator** — the "player" (human, test, RL agent,
  LLM). Lives in a separate process, feeds input like a player does.
- **Line**: in the deterministic replay → in-engine. A "player" → outside.
  An RL agent *training* is outside; once a trained policy ships as a
  built-in opponent it gets ported to in-engine `ai_policy`.

### Determinism bonus for AI/replay

What gets LOGGED is the ACTION, not the agent's reasoning. So you can record
an AI (or human) session and replay it bit-identically WITHOUT re-running the
AI. Pixels are a deterministic function of state (fixed renderer), so the
corpus is just input logs; observations regenerate on demand. Tiny storage.

---

## 4. Multiplayer system decision

**Strict lockstep first; rollback per-game later only if needed.**

- Lockstep = the literal explicit-world-model contract: replicate INPUTS,
  every peer reproduces state from (initial_state, input_log). Same contract
  as save/load + deterministic replay.
- Most Yume genres don't need rollback (chess, sokoban, merchant, farming,
  civ-sim — turn-based or paced enough for a 2-4 tick input buffer to be
  invisible).
- Rollback = lockstep + speculation, so lockstep is a prerequisite, not
  wasted work. Twitch-action games (future arena shooter) opt into rollback
  on top of the SAME transport.
- **Server-authoritative state replication is the WRONG fit** — it abandons
  the explicit-world-model contract (server state becomes truth, input log
  stops being authoritative, can't replay from inputs alone).

Tradeoff: at 60Hz a 16ms tick is tighter than typical RTT (30-80ms) → buffer
2-4 ticks (~32-64ms input delay). Fine except twitch games.

**Transport is a swap, not a rewrite.** Dev-loop uses Python-over-stdio
(simplest, deterministic, scriptable, faster-than-realtime). Real
multiplayer swaps stdin for `ENetMultiplayerPeer` — only `lockstep_driver.gd`
changes; merge point + engine + rendering unchanged.

---

## 5. The Moves (phased plan)

Build in this order. Each ships as a CI-testable artifact. **Move 1 is
unconditional** (a correctness fix valuable regardless of multiplayer);
the rest are the research/multiplayer build.

### Move 0 — Determinism oracle (foundation, no networking)
- **`canonical_state_hash(world)`** — sort entities by id, sort each state's
  keys, fixed float precision, CRC the serialized result. THIS hash IS the
  determinism contract. Standalone value: catches save/load determinism bugs
  today.
- **`--hash-log=<path>`** flag extending `capture_runner.gd`: after every
  `_advance()`, append `{tick, hash}` to a log.
- **`oracle.py`** — run one demo twice with the same input log; diff per-tick
  hashes; report first divergent tick + entity.
- **Audit**: run oracle against every existing demo. The ones that diverge =
  the determinism-bug backlog (RNG seeds, Dictionary iteration order, float
  ordering, spatial-index tiebreakers, signal-drain order). Start with chess
  (smallest deterministic demo), then sokoban, then an action demo.
- **Gate**: a demo that can't oracle-green twice is not multiplayer-ready.

### Move 1 — Collapse StepRunner onto the REAL input path (UNCONDITIONAL)
- Rewrite `_do_press` / `_do_hold` / `_do_click` in `step_runner.gd` to build
  a real `InputEvent` from the action's `InputMap` binding and call
  `Input.parse_input_event(ev)` — instead of `Input.action_press`.
- Engine-injected actions (no binding, e.g. `stop_x`/`stop_y` with
  `engine_injected:true`) keep a clearly-labeled synthetic fallback.
- **Deletes** the `_scripted_action_consumed` carve-out
  (`input_registrar.gd:265-287`) — the phantom-`is_action_just_pressed` bug
  it papers over only exists because StepRunner skips the event pipeline.
- `click` goes through Godot's real mouse routing (hit-test, modal-block,
  z-order) → catches the bug class `validate_screens.py` was bolted on for.
- **Why first**: makes tests faithful, and makes "scripted input" and "remote
  peer input" THE SAME PATH — the property determinism needs. The bugs that
  surface during the parity run are the ones `action_press` was masking.
- Tech-director Condition C4 (`_advance` is canonical) unchanged — only the
  injection layer underneath shifts.
- **Process**: ADR + one-release parity run (scenario tests through both
  paths, confirm identical results) before deleting the old path.

### Move 2 — `lockstep_driver.gd` + bidirectional stdio
- Extract Move 1's injector into a shared `_inject(input_dict)` used by
  capture_runner (file), scenario_runner (test), AND a new lockstep_driver
  (stdin).
- `--lockstep-stdio` activates it: per tick, BLOCK on `OS.read_string_from_stdin()`
  (the blocking read IS the tick barrier), inject, `_advance()`, emit
  frame + state + hash, loop.
- `--state-fd=<n>` / `--frame-fd=<n>`: emit on dedicated fds (the hard wall).
  State = `JSON.stringify(snapshot)` newline-framed; frame =
  `store_32(len)` + `store_buffer(img.get_data())` length-prefixed.
- **Headless caveat**: pure `--headless` has NO GPU render → state only, very
  fast. Pixel emission needs a rendering context (`--rendering-driver
  opengl3`, same as `play.sh --capture`) and pays the GPU→CPU readback cost.
  Splits research into two regimes: state-prediction (cheap, headless) vs
  pixel-observation (GPU-bound).

### Move 3 — Python orchestrator (3 entry points, same machine)
- **`oracle.py`** (from Move 0) — determinism gate.
- **`broker.py`** — N Godot peers, merge inputs per tick, fail-fast on hash
  mismatch (= desync detector pointing at exact divergent tick/entity).
  `asyncio`, one pipe-trio per peer.
- **`scenario.py`** (optional, later) — 1 peer + scripted steps + assertions.
  A test IS a 1-peer broker. DON'T migrate the existing `scenario_test.tscn`
  on spec — keep it until the stdio path is proven on a few demos.
- Agent loop: `policy(frame)` receives ONLY pixels; `compute_reward(state)`
  receives ground-truth; world-model eval = linear-probe(latent) vs JSON
  state fields.

---

## 6. Godot ↔ Python wire mechanics (verified APIs)

**Godot reads input** (verified via godot-api skill):
- `OS.read_string_from_stdin(buf=1024)` — blocking; pipe-mode blocks until
  buffer/EOF; strips trailing newline. `OS.read_buffer_from_stdin()` for raw.
- `OS.get_stdin_type()` → STD_HANDLE_{INVALID,CONSOLE,FILE,PIPE,UNKNOWN};
  check before reading to avoid console hang. Linux/macOS/Windows.
- Blocking is DESIRED for lockstep — it's the barrier.

**Godot emits state**: `entity.snapshot()` → `JSON.stringify` → `store_line`
on a dedicated fd (redirect of the existing save serializer).

**Godot emits frames**: `get_viewport().get_texture().get_image()` →
`img.get_data()` (raw RGBA8 bytes, NO PNG encode) → `store_32(size)` +
`store_buffer(raw)`. The `get_image()` call is a synchronous GPU→CPU
readback (the perf cliff; fine at capture rate, bottleneck at training rate).

**Input injection fidelity (3 levels)**:
1. `Input.action_press(name)` — flips action state; pollers see it; `_input`
   callbacks DON'T. (what StepRunner uses today)
2. `Input.parse_input_event(ev)` — full event through `_input`/`_unhandled_
   input`/`_gui_input`; closest to hardware. (what Move 1 switches to)
3. `get_viewport().push_input(ev)` — viewport-scoped variant (SubViewports).
- Not everything IS an event: engine_injected actions have no binding → must
  keep the synthetic fallback. "Always use InputEvent" is wrong; need both,
  honestly labeled.

**Python side (verified shape)**:
- `os.pipe()` × 2 (state, frame) + `subprocess.Popen(..., pass_fds=(...))` to
  give the child extra fds beyond stdin/stdout/stderr. (POSIX; Windows uses
  named pipes/sockets.)
- **Framing rule**: text fd = newline-framed (`readline` + `json.loads`);
  binary fd = length-prefixed (`read(4)` → uint32 → loop `read(n-len(buf))`
  until full — a single `read` may return fewer bytes). NEVER mix binary +
  text on one fd.
- Blocking reads = synchronization: `stdin.write(actions)` → Godot ticks →
  `read_frame`/`read_state` unblock. No timers/polling; Python and Godot take
  turns.
- Frame reshape: `np.frombuffer(buf, np.uint8).reshape(H, W, C)`.
- The policy signature literally doesn't take `state`; to make the wall
  un-bypassable, run the agent in its own subprocess handed only `frame_pipe`.
- Scaling: one env per process stepped serially. For RL, N processes each
  with its own pipe-trio, stepped concurrently (asyncio / gym.vector). Per-
  process code unchanged. Shared-memory frame buffer is the later perf
  upgrade — only `read_frame` changes (pipe → mmap), handshake stays.

---

## 7. Open questions / decisions still to make

1. **ADR scope**: frame as "Yume as deterministic POMDP for world-model
   research" covering (a) one input path, (b) two-channel observe split with
   the hard wall, (c) determinism contract (state hash) tying replay + eval +
   lockstep. NOT narrowly "multiplayer". RECOMMENDED.
2. **Blast-radius audit BEFORE the ADR**: grep every engine site that
   special-cases scripted-vs-real input (every analogue of
   `_scripted_action_consumed`) so the ADR's migration scope is concrete.
   Do this FIRST (item picked by user next).
3. **Lockstep vs rollback default**: lockstep recommended; rollback deferred
   to a per-game opt-in for twitch genres.
4. **Test-runner migration**: keep `scenario_test.tscn`, build stdio path for
   multiplayer/AI first, migrate tests only after the stdio path is proven.
5. **State channel JSON shape**: confirm exactly what `save_state.gd`
   assembles for the full world snapshot (the precise shape the harness +
   probe will consume) — not yet inspected in detail.
6. **Mouse-look**: `InputEventMouseMotion` for FPS camera look is a known
   StepRunner gap; multiplayer/AI for FPS needs a `{"look":[dx,dy]}` action
   or raw-event support. Canonical-actions-only (ADR 0043 universal input)
   is cleaner for wire/hash/replay; mouse-look is the awkward special case.

---

## 8. Recommended next step

**Move 2 from the open-questions list: blast-radius audit** — find every
scripted-vs-real input special-case in the engine — THEN draft the ADR
against known scope (per `.claude/rules/docs.md`: pin the contract before
code). Do NOT write engine code before the ADR.

---

## 9. Constraints from project rules (apply when this proceeds)

- **`docs/30_framework_primitives.md` is ADR-gated** — adding the
  state-hash / lockstep / observe-channel primitives needs ADR(s).
- **`engine-scripts.md`**: no genre-specific code; new vocabulary = primitive
  expansion documented in the contract. Camera-stability + visual gates apply
  to any rendering-adjacent change.
- **`post-mortem.md`**: every bug surfaced during the determinism audit gets
  the fix + gate ritual (the audit WILL surface determinism bugs — each is a
  gate candidate, likely a new validator).
- **`data-demo.md`**: no per-def escape hatches; anything derivable is
  derived. The state hash must be derived identically everywhere.
- Networked multiplayer is currently "Tier 4 / future" in the contract — this
  plan is the bridge from that hold to a concrete path.
