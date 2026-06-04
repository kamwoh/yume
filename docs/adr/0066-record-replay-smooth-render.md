# ADR 0066 — record-then-replay for smooth offline net video

_Date: 2026-06-04_
_Status: accepted_

## Context

The side-by-side net videos (`scripts/net_video.py`) capture a LIVE
networked session in real time (server + N rendering clients over ENet).
On this box the per-client render is GPU-bound — ~20 fps on the Windows
iGPU, ~3 fps under software Vulkan (`--offscreen`) — so the recording is
choppy. You cannot out-run the GPU in real time, and the existing
`--capture-allframes` only grabs whatever the GPU manages.

Godot ships **Movie-Maker mode** (`--write-movie`), which renders EVERY
frame at a fixed timestep decoupled from wall-clock — a slow GPU just
makes it take longer to produce, the output is always smooth. But movie
mode fakes the clock, so it **cannot drive a live ENet session** (server
and clients would each run their own fake clock and desync). Movie mode
is for a single deterministic instance.

## Decision

Split "run the sim" from "render the video":

1. **Record (live, real-time).** The authoritative server logs its
   per-tick state stream to a file (`--net-record=<path>`,
   `--net-record-secs=<n>` — records from GO for n seconds). The clients
   run **headless** (dummy renderer → fast, no GPU) purely to drive
   input over the real netcode. The record is `{tick_hz, roster, frames}`
   where each frame is `{tick, ents:{id:{position,facing,anim_phase,...}}}`
   (reuses `_serialize_state`, i.e. the net.json replication policy).

2. **Replay-render (offline, Movie-Maker).** A replay mode in
   `net_driver.gd` (`--replay=<path> --replay-follow=<entity>`) gates the
   World sim, spawns the recorded roster, follows the chosen entity, and
   applies the nearest recorded frame's state each Movie-Maker frame. Run
   once per camera view under `--write-movie --fixed-fps 60` → smooth
   60 fps. Reuses the net client's spawn/apply/follow seam.

3. **Stitch.** Every view replays the SAME recording at the SAME fixed
   fps → identical frame count → the views are inherently synced; the
   grid stitch needs no tick-pairing.

`net_video.py --smooth` orchestrates all three.

## Consequences

- **Smooth 60 fps regardless of GPU** (the win). Slow render only means
  the offline pass takes longer to produce (e.g. ~68 s per 4 s view here),
  not a choppier result.
- **Real meshes + no version risk:** the offline pass uses the STOCK
  4.6.1 binary (real iGPU, real asset import), sidestepping the 4.7-beta
  `--headless-render` box/import problem entirely. The custom offscreen
  build is no longer required for a good-looking video.
- The recorded sim IS the real server-authoritative netcode output —
  replay is only a visualization, so it still faithfully demonstrates the
  networked, synced multiplayer.
- Recording is server-only state; static scene props render normally from
  the scene, only dynamic (actor-tagged) entities are logged.

## Alternatives considered

- **Real-time capture, faster GPU.** WSL has no hardware Vulkan for the
  custom build; the iGPU caps ~20 fps. Can't reach a smooth 60 in real
  time on this hardware.
- **Movie mode on the live session.** Impossible — fake clock desyncs
  ENet (see Context).
- **Single instance simulating all players locally in movie mode.** Would
  render smooth, but bypasses the networking entirely (doesn't exercise /
  demonstrate the real netcode). Record-then-replay keeps Phase 1 on the
  real wire.
