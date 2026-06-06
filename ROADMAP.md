# Roadmap

Yume is **`0.x` / pre-stable** — the seven primitives + JSON schema aren't
frozen until `1.0`. This roadmap is derived from the README "Known gaps" table;
it's intent, not a promise. Dated 2026-06-06.

## Now (`0.1.x` — polish on what shipped)
- **Convex-hull colliders** for terrain props. Today's axis-aligned box is
  tight + mesh-fit + rotated, but can let the player clip when entering a prop
  airborne on a steep slope. A convex hull from the actual `.glb` geometry is
  tight *and* robust by construction. (See ADR 0067 § colliders.)
- **Scatter-count gate**: `compose_world`'s `scatter_in_mask` should cap at the
  catalog's `expected_count` (a drawn blob is a cluster, not a per-pixel
  tiling) — enforce it in code / a validator, not just prose.
- **CI**: a GitHub Action that runs the engine unit suite on push.

## Next (`0.2` — reuse + RL ergonomics)
- **Play-mode inheritance** (ADR follow-up): lift the walk/jump/sprint/camera
  shell into `data/lib/play_modes/<mode>/` so a same-type game is *just*
  assets + scene + a few rules (`$include` — ADR 0027/0043). Goal: minimal
  per-game JSON.
- **`gym.Env` first-class**: the deterministic stepping env (ADR 0060) as a
  real `gym.Env` — action/observation `Space`s, batching, in-process `reset()`.
- **Animation fidelity**: validate that a declared `animation_clip` exists in
  the mesh; make `anim_phase` speed-proportional (no foot-sliding).

## Later
- **Multiplayer hardening**: client-side prediction, lag compensation,
  NAT/relay/matchmaking, reconnection, persistence; net-test the genre games
  (not just the walk shell).
- **Headless-render fidelity**: port the windowless `--headless-render` path to
  4.6.1 (the current patch targets 4.7-beta → can't load 4.6.1 assets).
- **Audio depth**: music/BGM beyond procedural SFX + cues.

## Someday
- In-engine visual editor (everything is JSON + skills today).
- Touch / mobile input path.
- LLM-driven NPC behavior as a shipped feature (ADR 0020 IPC seam exists).

## `1.0` (the stability promise)
Freeze the 7 primitives + the JSON schema. Until then, expect schema churn
between minor versions — that's why we're honestly `0.x`.
