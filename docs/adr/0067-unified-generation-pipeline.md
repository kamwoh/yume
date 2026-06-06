# ADR 0067 — unified generation pipeline (game + scene + assets, layered)

_Date: 2026-06-06_
_Status: accepted_

## Context

Three generation pieces existed independently and **clobbered** each other
(README "Known gaps"): `/yume-design` (game mechanics), `/yume-create-scene`
(`compose_world` 3D map + `compose_shell` walk-shell), and `tools/yume_assetgen`
(AI assets). They all assumed they owned `entities/`, `scene.json`,
`game/flow.json`, `world/rules/` — so running more than one on a folder
overwrote files. There was no end-to-end "prose → game with a generated world
and assets."

Grounded audit of the actual writes:
- `compose_world` writes: `scene.json`, `entities/auto_gen.json` (map defs),
  `levels/level_default/entities.json` (map placements), `world/state.json`,
  `world/road_graph.json`, `game/flow.json`, `assets/{layouts,textures}/*.png`.
  It writes **no `world/rules/`** (it is pure environment).
- `compose_shell` writes the walk/jump/sprint **gameplay** + player + camera +
  input + per-game `.tscn` — this is the part that collides with a real game's
  mechanics.
- `/yume-design` (game) writes `entities/*.json`, `world/rules/*.json`,
  `game/goals.json` + `game/flow.json`, `scene.json`, `hud.json`, `audio/`,
  `screens.json`, `ui/`.

So the *only* real overlaps are **`scene.json`** and **`game/flow.json`**.

## Decision

Model a game as **three layers with disjoint file ownership**, composed by one
ordered orchestrator. No merge logic — the engine already globs
`entities/*.json` + `world/rules/*.json` and merges by id, so layers that use
distinct files + ids compose for free.

| Layer | Owns (writes only these) | Produced by |
|---|---|---|
| **World** (the 3D stage) | `scene.json`, `world/state.json`, `world/road_graph.json`, `game/flow.json`, `levels/<level>/entities.json` (map placements), `entities/auto_gen.json` (map defs), `assets/{layouts,textures}/` | `compose_world` |
| **Game** (the play) | `world/rules/*.json` (mechanics), `game/goals.json`, `entities/<slug>.json` (player + dynamic defs + their `initial_instances`), `hud.json`, `audio/cues.json`, `screens.json`, `ui/input.json`, `ui/strings.json` | `/yume-design` skills |
| **Assets** (the look) | `asset_gen.json`, `assets/generated/`, and **in-place patches** of `visual.*` on existing defs | `tools/yume_assetgen` |

**Two ownership rules are the entire fix:**
1. When the World layer ran (`--scene`), the Game layer **must not write
   `scene.json` or `game/flow.json`** — the World owns the environment + the
   single-level flow. The game's player/entities go in `entities/<slug>.json`
   `initial_instances` (spawned into the World's level by the engine's glob).
2. ~~`compose_shell` is **not** run inside `/yume-design`~~ — **REVISED
   2026-06-06, see below.** `/yume-design --scene` DOES reuse `compose_shell`
   as the default walk "play mode."

## Revision 2026-06-06 — `--scene` reuses `compose_shell` (the walk play mode)

The first cut said the game provides its own player/camera/movement and
`compose_shell` stays out of `/yume-design`. Building the first real
`--scene` game (a walkable village explorer) surfaced two problems:

- `compose_world --no-shell` writes `scene.json` with ground/lighting but
  **no `camera` block** (camera was always `compose_shell`'s job) and no
  player/movement — so a `--scene` game had no way to be viewed or controlled
  without re-authoring the entire shell.
- For the common case — explorer / adventure / walk-around 3D games — the
  `compose_shell` third-person walk shell IS exactly the movement the game
  wants. Forbidding it duplicated work for no benefit.

**Decision:** `--scene` runs `compose_world` **+ `compose_shell`** (a
`--no-shell` flag exists on `compose_scene` for the rare game that brings its
own movement). `compose_shell` is the default **walk play mode**: it provides
the player, third-person camera (written into `scene.json`'s `camera` block),
walk/jump/sprint rules (`world/rules/10–13_shell_*.json`), input map, and the
`.tscn`. The game layers mechanics on top via `entities/<slug>.json` +
extra `world/rules/*.json`, and **overrides the shell's movement rules only if
it needs non-walk movement** (a shooter, a top-down RTS). This resolves the
camera-ownership gap (the shell owns the camera key; `compose_world` owns
ground/lighting) and makes explorer games near-free.

**Follow-up (user direction):** generalize play modes into inheritable
`data/lib/play_modes/<mode>/` bundles games `$include` (ADR 0027/0043 lib-ref
machinery), so the walk shell is reusable by NON-`--scene` games too and a
same-type game is just assets + scene + a few rules. Tracked in
`.claude/plan/open-source-v0.1.md`; its own ADR.

## (original) `compose_shell` rule — superseded by the revision above

## Orchestration — one entry point

```
/yume-design "<pitch>"  [--scene]  [--with-assets]   [--style=…] [--name=…] [--autonomous]

  Phase W (only if --scene):  compose_world  → the 3D environment (World layer)
  Phases 0–4 (always):        the game skills → mechanics/goals (Game layer),
                              honoring the ownership rules above
  Phase A (only --with-assets): python -m tools.yume_assetgen <slug>  (Assets layer)
  Phase QA (always):          headless run + capture
```

Each phase writes only its layer's files → **no clobber, by construction.**

## Consequences

- **`/yume-design "..."`** (no flags) is unchanged + key-free: code-drawn
  single-player game. This stays the default + the v0.1 committed-demo path.
- **`/yume-design "..." --scene --with-assets`** = one command, prose → game
  *in a generated 3D world with AI assets*. (`--scene`/`--with-assets` need
  image-gen / Tripo API keys + cost; the default needs neither.)
- `/yume-create-scene` (`compose_world` + `compose_shell`) is unchanged for
  scene-only authoring; it just no longer "fights" `/yume-design` because the
  game pipeline now knows how to *layer onto* a World instead of overwriting it.
- The README "Pipelines clobber each other" gap is closed.

## Alternatives considered

- **Merge files programmatically** (deep-merge `scene.json`, splice rule
  arrays). Rejected — fragile, and unnecessary: disjoint file ownership +
  the engine's glob-by-id gives composition for free.
- **A new top-level orchestrator skill** wrapping all three. Rejected —
  `/yume-design` is already the orchestrator; adding two flags is simpler than
  a fourth entry point.
- **Keep them separate, document the clobber.** Rejected — that's the status
  quo gap; the whole point is end-to-end.
