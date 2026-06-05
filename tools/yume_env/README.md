# `yume_env` — the Python stepping env (ADR 0060)

A **gym-like Python wrapper** that drives a Yume world **one tick at a time** for
RL, agent-evaluation, testing, and trajectory recording. It's the Python
front-end to Yume's world-model interpreter: each call applies one
`f(state, action) → next_state` transition and hands back the new observation.

```python
from tools.yume_env.env import YumeEnv
env = YumeEnv("demo_sokoban")
env.reset()
obs = env.step(["move_north"])     # → {"tick", "hash", "state"}  (+ "frame" if frames=True)
env.close()
```

---

## Is Godot running together, or separately?

**Separately — as a child process.** This is the most important thing to
understand:

- `env.py` is **plain Python**. It does **not** embed Godot, and Godot does
  **not** import Python.
- When you construct `YumeEnv(...)`, Python **spawns a Godot subprocess**
  (`subprocess.Popen`) running the engine with the `--stdio-step` flag.
- The two processes talk over **OS pipes** (the child's stdin/stdout), plus an
  optional **file** for pixels.
- **One Godot process per `YumeEnv`.** Two envs = two independent Godot
  processes (separate worlds, separate pipes). Want parallel rollouts? Make N
  `YumeEnv`s — they don't share state.
- It runs **lockstep**: Python sends one action line, then **blocks** until
  Godot replies with the resulting state. Godot, in turn, **blocks** on stdin
  between steps. Neither runs free — the pipe round-trip is the clock.

```
┌────────────────────┐   stdin: {"actions":[...]}\n      ┌──────────────────────────┐
│  Python (env.py)   │ ───────────────────────────────▶ │  Godot subprocess         │
│  YumeEnv.step()    │                                   │  --stdio-step             │
│  (your RL loop /   │   stdout: @YUMESTEP@{tick,hash,    │  StdioStepDriver autoload │
│   agent / test)    │ ◀──────────────── state}\n ────── │  (World.set_process=false)│
└─────────┬──────────┘                                   └──────────────────────────┘
          │  (frames=True only)        frame file: <tmp>.rgba (raw RGBA8)
          └──────────────────  read after the state line  ◀──────────────────────────
```

Godot is the **interpreter + projection**; Python is the **driver/agent**.
Nothing about the world advances unless Python calls `step()`.

---

## The protocol (one line in → one tick → one line out)

Newline-framed JSON over the pipes:

| Direction | Line |
|---|---|
| Python → Godot (stdin) | `{"actions": ["move_north", ...]}`  (or `""` / `QUIT` to stop) |
| Godot → Python (stdout) | `@YUMESTEP@{"tick":N,"hash":"<sha256>","state":{...}}` |

The `@YUMESTEP@` sentinel lets the reader ignore Godot's boot-log noise on the
shared stdout. The **first** emitted line is the handshake (`"ready":true`),
which `__init__` blocks on.

**One stdin line = exactly one tick = one stdout state line.** Determinism is by
construction: the driver calls `world.set_process(false)`, so the real-time
frame loop can't sneak in extra ticks — `StepRunner` is the sole tick driver.

---

## What one `step()` does (engine side: `stdio_step_driver.gd::_step`)

1. `Input.action_press(a)` for each action — sets the same action state a real
   keypress would (the one input seam).
2. `StepRunner._drive_poll(world)` → `InputRegistrar.poll(...)` →
   `scheduler.queue_input(action, {actor})` — the action becomes a queued input
   bound to the active actor for this tick.
3. **`world.advance_one_tick()`** — the phase scheduler fires the matching rules
   (input → decide → react, with effect flushes); the result *is* `state_{t+1}`.
4. `_tick_character_bodies(world)` — integrate `state.velocity` → `state.position`.
5. `Input.action_release(a)` — clear, so it doesn't latch into the next tick.
6. Serialize + emit: `{tick, hash, state}` (+ `frame` meta if enabled).

---

## `obs` — what you get back

```python
{
  "tick": 42,
  "hash": "<sha256 of canonical state>",     # determinism fingerprint
  "state": {
    "world": { ...world_state singletons... },
    "entities": { "<id>": {"state": {...fields...}, "position": [x, z]} }
  },
  "frame": {"w": W, "h": H, "pixels": <(H,W,4) uint8 ndarray>}   # only if frames=True
}
```
`state` is the readable world snapshot (the evaluator's ground truth); `hash` is
the canonical fingerprint used to verify reproducibility (see `oracle.py`).

---

## The frame (pixel) channel

Pixels can't share the pipe — **Godot's `FileAccess` cannot write pipes/FIFOs**
— so state travels on **stdout** and pixels go to a **regular file**. (That
mechanical split is the ADR 0060 "wall": state = evaluator truth; frame = a
pixel agent's eyes.)

Enable with `YumeEnv(..., frames=True)`:
- Godot launches with `--rendering-driver opengl3` (a real GL viewport, not
  `--headless`) + `--frame-file=<tmp>.rgba`.
- Each step, after the tick, the driver renders, does a synchronous GPU→CPU
  readback, and writes `store_32(w) store_32(h)` + raw `w*h*4` RGBA8 to the file
  (overwritten per step) **before** emitting the state line — so the reader
  never sees a partial frame.
- `env.py::_read_frame` unpacks `w,h` + the bytes into a NumPy `(H,W,4)` array.

---

## Setup + requirements

- **Native Linux Godot binary** — Windows-Godot-via-WSL can't do reliable
  stdin/stdout piping. Set `YUME_GODOT_LINUX_BIN` (default
  `~/godot-linux/Godot_v4.6.1-stable_linux.x86_64`).
- A **dedicated Linux project dir** with its own `.godot` import cache
  (`YUME_GODOT_LINUX_PROJECT`, default `~/godot-linux/yume`). `ensure_project()`
  rsyncs `godot/` → there and imports once; it **excludes** the heavy
  `data/demo_*/assets/` (`.glb`/textures) because the env is **state-only** —
  meshes are renderer-side and don't affect the transition. (For `frames=True`
  you'll want the assets present so the render isn't fallback boxes.)

```python
from tools.yume_env.env import ensure_project, YumeEnv
ensure_project()                       # one-time sync + import (idempotent)
env = YumeEnv("demo_sokoban", frames=False)
```

---

## Files here

| File | Role |
|---|---|
| `env.py` | the `YumeEnv` wrapper + `ensure_project()` |
| `oracle.py` | runs a demo twice and diffs per-tick hashes → proves determinism |
| `test_env.py` | smoke tests for the env |
| `test_lockstep_net.py` | lockstep net transport tests (ADR 0061) |

Engine side: `godot/scripts/engine/io/stdio_step_driver.gd` (the `--stdio-step`
autoload).

---

## Limitations (today)

- **One process = one episode.** `reset()` returns the current obs but does
  **not** re-seed — a true reset means relaunching the process. (A future
  in-process reset would re-init the world without a relaunch.)
- **Frames are slow in WSL** — software GL (llvmpipe) + a synchronous readback
  per step. Fine for correctness; for throughput use state-only, or a native-GPU
  Linux box.
- **No built-in batching / gym.spaces** — it's a thin transport, not a full
  `gym.Env` (no action/observation `Space` objects yet). Wrap N `YumeEnv`s for
  parallel rollouts.

See ADR 0060 (`docs/adr/0060-deterministic-pomdp-pluggable-io.md`) for the full
design + the state/frame channel rationale.
