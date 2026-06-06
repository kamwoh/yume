# Changelog

All notable changes to Yume are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[SemVer](https://semver.org/) — `0.x` is pre-stable (the 7 primitives + JSON
schema are not frozen until `1.0`).

## [Unreleased]

## [0.1.0] — 2026-06-06

First public, open-source release. Yume is a **programmable, explicit world
model** on Godot 4.6.1: worlds are pure JSON (entities + rules), advanced tick
by tick by a fixed primitives + interpreter engine; games are one use of it.

### Added
- **Seven primitives + interpreter** (ADR 0001/0021): Entity, Tag, Rule,
  Trigger, Effect, Query, Relation; 8 trigger types, ~60 effect verbs, a
  whitelisted formula evaluator, a deterministic fixed-rate phase-flush tick.
- **2D + 3D rendering**: 8 camera modes, GLB meshes + kit-of-parts composites +
  MultiMesh decoration + trimesh static world, shaders-as-JSON, multi-biome
  ground from a semantic map, water, day/night, fog + procedural sky.
- **Opt-in gameplay directors**: party, schedule, class, zones, faction,
  tech-tree, dynasty, lifecycle, vehicles, multi-actor AI, pathfinding,
  procedural placement, animation.
- **"Complete game" layer**: declarative screens/modals, save/load, tutorials,
  settings, HUD-from-JSON, event→SFX audio, juice.
- **Generation pipeline** (ADR 0067): `/yume-design` orchestrates **three
  disjoint-ownership layers** — World (`--scene`), Game, Assets
  (`--with-assets`) — so they compose without clobbering. `compose_world` is
  scene-only + flat; `compose_scene --no-shell` is the World-layer entry point;
  no flags = a key-free code-drawn game. 38 specialist skills + standalone
  authors (`/yume-create-scene`, `/yume-hud/screen/map-author`).
- **Mesh-fit colliders**: solid props get a static box shrink-wrapped to the
  visual `.glb` (proportions × per-instance scale + yaw, base on the ground),
  enforced by a unit-test gate (`test_collider_matches_mesh`).
- **Networking & I/O** (ADR 0060–0066): deterministic gym-like Python stepping
  env + determinism oracle; lockstep; server-authoritative client-server with
  data-driven `net.json`; record-then-replay smooth headless N-player video.
- **Tooling & QA**: 25 static validators (sync gate), scenario tests, visual QA
  (Gemini + Claude vision), tech-director invariant gate.
- **Three committed example games** (run on a fresh clone, no API keys):
  `demo_sokoban` (2D puzzle), `demo_doomarena3d` (first-person arena shooter),
  `demo_lanterns` (third-person collect-’em-up with generated low-poly meshes).
- Project docs: README (world-model framing, feature/gap tables, roadmap,
  pipeline + skill graph), `LICENSE` (MIT), `CONTRIBUTING`, `INSTALLATION`.

### Known gaps
See the README "Known gaps / what's lacking" and "Roadmap" sections — most
notably: no client-side prediction in multiplayer; tight box colliders can clip
on steep slopes (convex-hull follow-up); thin music/BGM; no in-engine editor.

[Unreleased]: https://github.com/kamwoh/yume/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/kamwoh/yume/releases/tag/v0.1.0
