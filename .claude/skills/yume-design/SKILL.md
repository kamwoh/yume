---
name: yume-design
description: Run the Yume text-to-game pipeline. Orchestrates 7 specialist skills (yume-game-designer → game-planner → systems-designer → content-designer → asset-designer → qa-tester, plus tech-director on demand) with optional user-approval gates. Skills load into orchestrator context (no subagent spawn — Tier 2.6 architecture). Flags - `--autonomous` skips approval gates and runs end-to-end. `--plan-only` stops after the planning phases (GDD + world-plan) so the user can review before any JSON is committed. `--with-assets` invokes AI-gen pipeline. `--style=pixel-art|low-poly-3d|ascii` art-style hint. `--name=<slug>` game folder name.
---

# /yume-design — text-to-game pipeline

Turn a prose game description into a runnable Yume game.

> **REVISION BANNER 2026-05-16 (ADR 0009 revision, tasks #109 + #110).**
> The file layout in this skill below still mentions the legacy
> `world/rules.json` + `game/goals.json` split in several places.
> Treat these as the CURRENT shape:
>
> - `world/rules/*.json` (directory of feature modules) — all rule
>   authoring goes here. Filename prefix (`01_`, `02_`, ...) sets load
>   order. Engine globs + concatenates alpha-sorted.
> - Single-file `world/rules.json` still works for small games
>   (chess, sokoban). Pick whichever fits the game's size.
> - `game/goals.json` is GONE. Its content moves to
>   `world/rules/13_transitions.json` (boot/day-boundary/win/lose
>   signal-rules) + `world/rules/14_objectives.json` (HUD-text
>   updates + tutorial overlays).
> - Declarative win:/lose: blocks live in `hud.json` (HUD-driven
>   overlay; the engine evaluates them per-frame and shows the
>   win/lose panel automatically).
> - `game/flow.json` (multi-level progression) is unchanged.
> - Skill ownership: yume-systems-designer writes all rule files.
>   yume-game-rules-designer's scope shrinks to declarative HUD
>   win/lose blocks + game/flow.json. See each skill's own header.

## Usage

```
/yume-design <prose description of the game>
/yume-design "a farming sim where moonlight grows crops faster" --style=pixel-art --name=<your-game>
/yume-design "a roguelike where vampires steal HP from light sources" --with-assets
/yume-design "explore a fortified river town and collect 5 lost relics" --scene --with-assets
```

Args (parsed from the user's prompt after `/yume-design`):

- `<prose>` — the game description (free-form). Required.
- `--style=<value>` — `pixel-art` / `low-poly-3d` / `ascii` / `realistic`.
  Defaults to user-stated preference in prose, else `pixel-art`.
- `--name=<slug>` — game folder name. Defaults to a slug derived from
  the prose (auto-suggest: ask user to confirm).
- `--scene` — generate a 3D **world** for the game first (the World
  layer, via `compose_world`): a semantic-map + heightmap-driven map
  with biome ground, water, and placed environment props. The game's
  mechanics then layer ONTO that world. Default: no generated world
  (the game owns its own flat scene). **Needs `OPENAI_API_KEY`** — if
  absent, the flag is DROPPED (graceful degrade to a flat code-draw
  scene + a warning), never a crash. See Phase 0 step 2a.
- `--with-assets` — after the game is built, auto-run the AI asset
  pipeline (`tools.yume_assetgen`) to replace code-draw visuals with
  generated textures + meshes. Default: skip (code-draw fallback).
  **Needs an image key + `TRIPO_API_KEY`** — if absent, the flag is
  DROPPED (graceful degrade to code-draw visuals + a warning).

> **No API keys? You still get a game.** The no-flag path is fully
> key-free (code-drawn shapes). `--scene`/`--with-assets` are
> best-effort: present keys → used; absent → dropped with a warning,
> and you fall back to the code-draw game. Nothing hard-fails for lack
> of a key (Phase 0 step 2a).

> **The three layers (ADR 0067).** A game is **World** (the 3D stage,
> `--scene`) + **Game** (mechanics, always) + **Assets** (the look,
> `--with-assets`). Each layer writes only its own files, so they
> compose without clobbering. Default (no flags) = a key-free
> code-drawn single-player game. See the per-layer file-ownership
> table in Phase W below.

## What I do when invoked

I am the orchestrator. I do **NOT** write game content directly — I
load the 6 specialist skills in `.claude/skills/yume-<role>/` one at a
time and execute their role instructions in my own (the orchestrator's)
context.

**Skills, not subagents (Tier 2.6 architecture).** Earlier versions
of this pipeline spawned subagents via `Agent(subagent_type=...)`.
Some org auth policies disable subscription-backed subagent spawns
(`organization has disabled Claude subscription access`), which
breaks the pipeline. Skills load into the orchestrator's main
context — same role prompts, no auth boundary, lower latency, fewer
moving parts.

**Autonomous mode.** If the user passes `--autonomous` in the prompt,
skip the per-phase user-approval gates and walk all phases in one
shot, surfacing only on hard failure or at the final wrap. Default
(no flag) is interactive: pause after each phase for user approval.

### Phase 0 — Setup (no skill load)

1. Parse the prose + flags. Detect `--autonomous`, `--name=<slug>`,
   `--style=<value>`, `--scene`, `--with-assets`.
2. Auto-suggest a `<name>` slug from the prose (a 1-2 syllable
   shorthand of the genre + theme) if `--name=` not given.
2a. **API-key precheck (graceful degrade — NO crash without keys).**
   The gen flags need keys; the DEFAULT path needs none. Before
   running, check env and drop any flag whose key is missing, with a
   clear one-line warning — never hard-fail into a mid-pipeline crash:

   | Flag | Needs | If missing |
   |---|---|---|
   | `--scene` | `OPENAI_API_KEY` (gpt-image-2 for the semantic map + heightmap) | DROP `--scene` → the game uses a flat code-draw scene. Warn: "no OPENAI_API_KEY → skipping --scene (flat code-draw scene). Set the key for a generated 3D world." (Exception: a scene already on disk → keep `--scene` and run `compose_scene --skip-gen` to reuse the maps key-free.) |
   | `--with-assets` | an image key (`OPENAI_API_KEY` or `GEMINI_API_KEY`) **and** `TRIPO_API_KEY` (meshes) | DROP `--with-assets` → keep code-draw visuals. Warn: "no image/Tripo keys → skipping --with-assets (code-draw visuals). Set OPENAI_API_KEY + TRIPO_API_KEY for generated textures + meshes." |

   The no-flag path is **always key-free** (code-drawn shapes via
   `data/shapes.json`) — that is the fallback. Degrading to it must be
   loud (the warning) but non-fatal. In interactive mode, surface the
   degrade in the plan and let the user re-run with keys; autonomous
   proceeds degraded.
3. State the plan: paths, phases (Phase W only if `--scene` SURVIVED
   the precheck; Phase A only if `--with-assets` survived),
   autonomous-or-interactive mode.
4. Interactive mode: wait for explicit go-ahead. Autonomous: proceed.

### Phase W — World (only if `--scene`) — the 3D stage

Run BEFORE the game phases so the mechanics can layer onto a real
world. This is the **World layer** of ADR 0067 — the 3D scene PLUS the
default walk "play mode" (player + camera + movement). It reuses the
`/yume-create-scene` pipeline's `compose_world` (scene) **and**
`compose_shell` (the walkable explorer shell). See
`.claude/skills/yume-create-scene/SKILL.md` § "Used as the World layer."

1. Author the class catalog (the one LLM-in-the-loop step): invoke
   `yume-scene-class-catalog` on the prose → `/tmp/_class_catalog.json`.
   The catalog's scene brief is derived from the game's SETTING in the
   prose (the town, the dungeon, the forest), NOT its mechanics. The
   game's collectibles / NPCs / interactables are GAME-layer entities —
   keep them OUT of the catalog.
2. Run the scene pipeline (image gen → semantic map → heightmap →
   extract → scene + walk shell):
   ```bash
   python3 -m tools.visual_layout.compose_scene <name> \
       --catalog /tmp/_class_catalog.json
   ```
   This runs `compose_world` (scene: `scene.json` ground/water,
   `entities/auto_gen.json` defs + flat placements) **+ `compose_shell`**
   (the walk play mode: player `player_input_anchor` tagged `player`,
   third-person camera written into `scene.json`, `world/rules/10–13_shell_*`
   walk/jump/sprint, `ui/input.json`, the `.tscn`). Add `--skip-gen` to
   reuse existing maps; do NOT pass `--assets` (Phase A runs
   `yume_assetgen` once, after the game's asset-designer).
   **Non-walk game** (shooter, top-down RTS): pass `--no-shell` instead,
   and the game's systems-designer authors its own movement+camera.
3. The World layer now owns these files — **the Game phases below must
   NOT overwrite them** (this is the entire anti-clobber contract):

   | File | Owner | Game phases must… |
   |---|---|---|
   | `scene.json` | **World** (compose_world ground/lighting + compose_shell camera) | NOT write it |
   | `entities/auto_gen.json` | **World** (map prop defs + placements) | NOT touch; game writes a separate `entities/<slug>.json` |
   | `entities/player.json`, `world_clock.json`, `cameras.json`, `shell_singletons.json` | **World** (shell) | NOT overwrite; REUSE the `player`-tagged player |
   | `world/rules/10–13_shell_*.json` | **World** (shell walk/camera) | leave for walk games; REPLACE only for non-walk movement |
   | `screens.json` | **World** (shell H-help overlay: controls + `world.objective`, toggled by `toggle_help`/H via `global_inputs`) | a game with its OWN screens APPENDS to `screens` + keeps `global_inputs` — don't overwrite. Set `world_state.objective` (via `world/state.json` `{"state":{...}}` or `state_set target=world`) so it shows in help. |
   | `world/road_graph.json` | **World** | read-only |
   | `assets/{layouts,textures}/` | **World** | read-only |
   | `ui/input.json` | **World** (shell) | EXTEND (add game actions), don't clobber the shell's |

   No `levels/`, `game/flow.json`, or `world/state.json` — `compose_world`
   is scene-only + flat (ADR 0067). The engine globs `entities/*.json` +
   `world/rules/*.json` and merges by id, so the game's
   `entities/<slug>.json` (collectibles/NPCs/game-state singleton) and
   extra `world/rules/*.json` (mechanics) spawn INTO the flat scene for
   free — provided ids are disjoint from the map's `<class>_NNN` ids and
   the shell's singleton ids.

4. **No `--scene`?** Skip this phase entirely; the game owns a flat
   scene as before (the content/asset phases write `scene.json` normally;
   `game/flow.json` only if multi-level).

### Phase 0a — Multi-level detection

Read the GDD's "Level progression" or "Levels" section if present.
If the prose describes ≥2 levels (sokoban with N puzzles, TD with
multi-map campaign, RPG town→dungeon, roguelike floors), this is a
**multi-level game** and the file layout uses the `levels/` directory
pattern (ADR 0006):

```
data/<name>/
├── scene.json                              # camera, tick, renderer
├── world/state.json                        # initial world_state
├── world/rules/*.json                    # how the world works + scoring + transitions + objectives (chain modules)
├── hud.json                              # declarative win:/lose: blocks live here (per ADR 0009 revision)
├── game/flow.json                          # level order + start
├── ui/hud.json + ui/input.json + ui/strings.json
├── audio/cues.json                         # @cues.X mappings
├── variants/<mode>.json                    # OPTIONAL difficulty/mode
├── entities/                               # PERSISTENT defs (multi-level)
└── levels/
    ├── level_1/entities.json   # level-scoped instances
    ├── level_1/rules.json      # OPTIONAL per-level rules
    ├── level_2/...
    └── ...
```

State the multi-level decision to the user (interactive) or proceed
(autonomous):

```
LEVELS DETECTED: 8 (sokoban-style puzzles)
- Pattern: levels/ directory + game/flow.json
- Persistent entities: player (carries cleared/score across levels)
- Per-level: walls, boxes, goals (cleared on transition)
- Transition rule: contact(player, goal) → transition_level "next"
```

Single-level games (most arena shooters, single-zone sims) use the
flat layout — no game/flow.json, no levels/ directory; entities and
rules live at the root.

### Phase 0b — Layout planning (cross-cutting decision)

Before invoking any specialist skill, decide the file layout. All
downstream skills follow this plan; no skill-by-skill drift. Decisions
based on prose-estimated scope:

**Entity layout**:
- Small (estimated ≤ 8 entity defs): single `entities.json`
- Medium (8-20 defs): `entities/` directory, one file per def, plus
  `entities/zz_instances.json` for placements
- Large (20+ defs): `entities/` directory grouped by category subfolder
  (e.g. `entities/world/`, `entities/creatures/`, `entities/plants/`),
  with one `entities/zz_instances.json` at the root

**Rules layout** (ADR 0009 + revision 2026-05-16 — feature-module split):
- `world/rules/*.json` — feature-module directory holding ALL rule
  chains (motion, AI, contact, decay, lifecycle, scoring, transitions,
  objectives, tutorials). yume-systems-designer owns all of these.
  Engine globs the dir alpha-sorted at load. Per-feature splitting
  (`01_movement.json`, `02_inventory.json`, `13_transitions.json`,
  `14_objectives.json`, etc.) keeps each file scannable.
- Smaller games (chess, sokoban) can still use single-file
  `world/rules.json` — the engine accepts both layouts.
- Declarative `win:` / `lose:` blocks live in `hud.json` — engine
  evaluates per-frame and auto-shows the win/lose overlay.
- `game/flow.json` — multi-level progression (level order + start).
  yume-game-rules-designer owns this in its narrowed scope.
- Per-level rules: `levels/<name>/rules.json` (or `levels/<name>/rules/*.json`
  directory form).

**Always**:
- `scene.json` is single-file at root (camera/tick/renderer config)
- `world/state.json` holds initial world_state values
- `ui/hud.json` + `ui/input.json` + `ui/strings.json` for UI layer
- `audio/cues.json` maps semantic events → sound names (@-prefix
  refs in rules)
- New shapes append to **`data/shapes.json` root**, NOT per-game
- Per-game scene `.tscn` is a 12-line template stub (auto-written
  by orchestrator at Phase 5; see template body in this doc)
- Universal `scenes/play.tscn` works for any game via `--game=` arg

State the chosen layout to the user (interactive) or proceed with it
(autonomous). Pass layout to each skill in its arg payload so it
writes files in the right structure:

```
LAYOUT CHOSEN:
- entity_layout: medium → entities/ directory
- rules: world/rules/*.json feature modules (systems-designer)
- flow: game/flow.json (game-rules-designer, multi-level only)
- assets: code-draw shapes appended to data/shapes.json root
```

This step prevents per-skill drift — content-designer and asset-designer
both follow the orchestrator's chosen plan instead of inventing their own.

### Phase 0c — Genre detection + dispatch

After layout planning, classify the prose's genre. Genre dispatch
unlocks **strictest-layer** specialist skills (genre-specific
designer + reviewer) that catch concerns the generic skills can't
see (FPS movement feel, TD path geometry, sim resource cycles, etc.).

Match keywords from the one-line pitch:

| Genre | Triggers | Designer | Reviewer |
|---|---|---|---|
| **shooter** | "shooter", "fps", "doom", "arena shooter", "twin-stick", "first-person" | `yume-shooter-designer` | `yume-shooter-reviewer` |
| **merchant** | "merchant", "shopkeeper", "item shop", "an item-shop merchant game", "trader", "a merchant-adventurer game" | `yume-merchant-designer` | `yume-merchant-reviewer` |
| **racing** | "racing", "kart", "a high-speed futuristic racer", "a high-speed futuristic racer", "a time-attack racer", "an arcade combat racer" | `yume-racing-designer` | (future: yume-racing-reviewer) |
| **td** | "tower defense", "td", "bloons", "kingdom rush", "pvz" | (future: yume-td-designer) | (future: yume-td-reviewer) |
| **sim** | "sim", "ecology", "farming", "stardew", "harvest moon", "life sim" | (future) | (future) |
| **puzzle** | "puzzle", "sokoban", "match", "block-push", "tile" | (future) | (future) |
| **roguelike** | "roguelike", "dungeon crawler", "rogue-lite" | (future) | (future) |
| _(no match)_ | fallback | `yume-game-designer` only | `yume-game-reviewer` only |

State the detected genre to the user (interactive) or proceed
(autonomous):

```
GENRE DETECTED: shooter
- Specialist designer: yume-shooter-designer (FPS-specific GDD sections)
- Specialist reviewer: yume-shooter-reviewer (10 FPS axes, strictest)
- Generic floor: yume-game-designer + yume-game-reviewer (13 axes) still apply
```

If no genre matches, only generic skills run.

### Phase 1 — game-designer (prose → GDD)

5. Invoke the specialist designer if genre detected, else generic:
   - Shooter: `Skill(skill="yume-shooter-designer", args=<prose + name>)`
   - Merchant: `Skill(skill="yume-merchant-designer", args=<prose + name>)`
   - Racing: `Skill(skill="yume-racing-designer", args=<prose + name>)`
   - TD/sim/puzzle/roguelike (when those skills land): same shape
   - No genre: `Skill(skill="yume-game-designer", args=<prose + name>)`
6. Specialist designers PRODUCE the full GDD (generic MDA scaffolding
   + genre-specific sections). They internalize the generic
   game-designer's framework so they don't drop generic concerns.
7. Output: `docs/games/<name>/GDD.md`.
8. Interactive: show GDD summary, ask "Approve? (y / edit / reject)".
   Autonomous: proceed to Phase 1b.

### Phase 1b — Generic game-reviewer (13-axis floor)

7a. Invoke `yume-game-reviewer` skill (always — the generic floor).
    `Skill(skill="yume-game-reviewer", args=<GDD path>)`.
7b. Skill produces `docs/games/<name>/review.md` with verdict.
7c. **Verdict handling**:
    - `accept` → proceed to Phase 1b.5 (genre-strict reviewer if any).
    - `revise` → re-invoke designer with revision requests. Loop
      max 3 cycles. After 3, surface to user.
    - `reject` → surface to user; pipeline halts.
7d. Why: generic 13-axis catches shallow GDDs at cheapest iteration
    point. Genre-strict review runs after this passes.

### Phase 1b.5 — Genre-strict reviewer (strictest gate)

7e. If a genre was detected in Phase 0c AND a specialist reviewer
    exists, invoke it:
    - Shooter: `Skill(skill="yume-shooter-reviewer", args=<GDD path>)`
7f. Specialist reviewer APPENDS a genre-review section to
    `review.md` (doesn't replace the generic findings).
7g. **Verdict handling — same as Phase 1b** but stricter:
    - `accept` → proceed to Phase 1c.
    - `revise` → re-invoke specialist designer with genre-specific
      revision requests. Loop max 3 cycles.
    - `reject` → surface to user. Genre-claim mismatch is the most
      common reject reason ("you said FPS but the GDD lacks N FPS
      requirements").
7h. Why: generic floor + genre ceiling = both must accept. Genre
    reviewer is the strictest layer: empirically, doomarena3d v2 +
    v2.5 needed reactive fixes (walk speed, diagonal, blocks_motion,
    weapons) that an FPS-aware reviewer would have caught at GDD
    review.

### Phase 1c — game-planner (GDD → world plan)

8a. Invoke `yume-game-planner` skill. Tool:
    `Skill(skill="yume-game-planner", args=<GDD path>)`.
8b. Skill produces `docs/games/<name>/world-plan.md` — named NPCs,
    items, plants, events, day-1 onboarding flow.
8c. Interactive: show plan summary (cast count, item categories, key
    events) — ask user to approve.
    Autonomous: proceed.

### Phase 1d — level-designer (spatial layout)

9a. Invoke `yume-level-designer` skill. Tool:
    `Skill(skill="yume-level-designer", args=<GDD + world-plan paths>)`.
9b. Skill produces `docs/games/<name>/level-design.md` — concrete
    coordinates + rationale per placement (path, choke points, tower
    slots, spawn zones, decoration).
9c. Interactive: show layout summary (dimensions, key placements) —
    ask user to approve.
    Autonomous: proceed.
9d. **If `--plan-only` flag was set**: stop here. Final summary lists
    GDD path + review path + world-plan path + level-design path.
    Tell user to re-invoke with `--resume`.

The plan + level-design are the single sources of truth for downstream:
- systems-designer references named entities + path lengths when
  sketching rules (radius / cooldown / speed numbers).
- content-designer wires named entities into JSON at the EXACT
  coordinates from level-design.md (no ad-hoc placement decisions).
- asset-designer reads visual hints + applies consistent style.

### Phase 1e — domain-specialist designers (CONDITIONAL)

Three optional design specialists run BEFORE systems/content/game-rules
authors any JSON. Each is gated on whether the GDD signals its domain.
Order matters: combining-logic first (recipe table feeds economy),
then economy (pricing curves feed content placement), then story
(beats reference both).

#### Phase 1e.1 — combining-logic-designer (CONDITIONAL)

Trigger: GDD mentions any of crafting / alchemy / breeding / cooking /
chemistry / spell-combinations / key-combos / recipe / merge.

10a. Invoke `yume-combining-logic-designer` skill.
10b. Produces `docs/games/<name>/combining-design.md` — recipe table,
     discovery model, yield rules, failure modes, primitive mapping.
10c. Interactive: show summary (recipe count, discovery model, key
     risks). Autonomous: proceed.

If trigger absent: skip this phase entirely.

#### Phase 1e.2 — economy-designer (CONDITIONAL)

Trigger: GDD mentions any of currency / score / shop / trade /
progression / unlock / cost / level-up / XP / income / merchant.
Most non-trivial games trigger this.

11a. Invoke `yume-economy-designer` skill (read combining-design.md
     too if Phase 1e.1 ran — recipe yields feed economy).
11b. Produces `docs/games/<name>/economy-design.md` — sources/sinks,
     conversion ratios, currency design, pricing curves, pacing math,
     adversarial-poke checklist.
11c. Interactive: show summary (resource count, currency layers, key
     adversarial findings). Autonomous: proceed.

If trigger absent (pure simulation, no progression): skip.

#### Phase 1e.3 — story-planner (CONDITIONAL)

Trigger: GDD mentions any of campaign / acts / arc / story / NPC
evolution / scripted events / branches / endings / chronicle. Pure
sandboxes / arcades skip.

12a. Invoke `yume-story-planner` skill (reads level-design + economy
     if present — beats often gate on level transitions or resource
     thresholds).
12b. Produces `docs/games/<name>/story-design.md` — beats, character
     arcs, act structure, branches, primitive mapping.
12c. Interactive: show summary (story shape, beat count, key risks).
     Autonomous: proceed.

If trigger absent: skip.

### Phase 2 — systems-designer (GDD → all rules)

Per ADR 0009 revision 2026-05-16, this skill now writes ALL rule
chains under `world/rules/*.json` (feature modules): motion, AI,
contact, decay, lifecycle, scoring, transitions, objectives, tutorial
overlays. Previously split with yume-game-rules-designer — scope
absorbed here.

8. Invoke `yume-systems-designer` skill. Tool:
   `Skill(skill="yume-systems-designer", args=<GDD path + resolved questions>)`.
9. Skill produces `docs/games/<name>/rules-sketch.md` + `world/rules/*.json`
   feature modules under the data folder. May propose ADRs if new
   primitives needed.
10. **If ADR proposed → escalate to tech-director:**
    `Skill(skill="yume-tech-director", args=<ADR path + diff>)`.
    On rejection → re-invoke systems-designer without the new primitive.
    On accept → ADR status set to `accepted`, proceed.
11. Interactive: show sketch + ADRs, ask approval. Autonomous: proceed.

### Phase 3 — content-designer (entities + initial state)

Per ADR 0009 narrowed scope: this skill ONLY writes entity defs + initial
placements + world state. Rules are NOT written here.

12. Invoke `yume-content-designer` skill. Tool:
    `Skill(skill="yume-content-designer", args=<GDD + world-plan + level-design + sketch>)`.
13. Skill writes `entities/*.json` (defs + placements), `world/state.json`
    (initial world state), `levels/<name>/entities.json` (multi-level
    games), under `data/demo_<name>/`.
14. Interactive: show file summary, ask approval. Autonomous: proceed.

> **`--scene` ownership guard (ADR 0067).** When Phase W ran (walk
> shell), the **player + camera + movement already exist** from the
> shell (`player_input_anchor`, tagged `player`) — do NOT author a
> player; the game's contact/interaction rules query the `player` tag.
> Write the game's OWN entities (collectibles, NPCs, interactables, a
> `game_state` singleton) with their `initial_instances` to
> **`entities/<slug>.json`** — NOT to `entities/auto_gen.json` or the
> shell's `entities/{player,world_clock,cameras,shell_singletons}.json`.
> Put game-global state in the `game_state` singleton (not
> `world/state.json`). Entity ids must not collide with the map's
> `<class>_NNN` ids or the shell singleton ids.

### Phase 3.5 — game-rules-designer (HUD win/lose + flow) — NARROWED scope

Post-ADR-0009-revision (2026-05-16), this phase covers only the
declarative win/lose surface + multi-level progression. Rule
authoring (scoring/transitions/objectives) moved to Phase 2's
yume-systems-designer scope.

15. Invoke `yume-game-rules-designer` skill. Tool:
    `Skill(skill="yume-game-rules-designer", args=<GDD + world/rules/*.json>)`.
16. Skill writes:
    - Declarative `win:` / `lose:` blocks in `hud.json` (engine
      evaluates per-frame, auto-shows the overlay).
    - `game/flow.json` (level sequence + on-all-complete) for
      multi-level games.
    For sandbox sims (no goals, single-level), this phase is SKIPPED.
17. Interactive: show decisions, ask approval. Autonomous: proceed.

> **`--scene` ownership guard (ADR 0067).** When Phase W ran, do NOT
> write `game/flow.json` — the World owns it (a single `level_default`).
> Win/lose blocks in `hud.json` are fine (game-owned); just reference
> `level_default` as the level id. A `--scene` game is single-level by
> construction (the generated world is one map).

### Phase 4 — asset-designer (visuals + audio + UI strings)

Per ADR 0009 expanded scope: also writes audio/cues.json + ui/strings.json.

18. Invoke `yume-asset-designer` skill. Tool:
    `Skill(skill="yume-asset-designer", args=<GDD + entities path + style flag>)`.
19. Skill updates `entity.visual.*` + `audio.*` fields, writes `scene.json`,
    `hud.json`, `audio/cues.json` (semantic event → sound mapping),
    `ui/strings.json` (localizable HUD text), and `asset_gen.json` if
    `--with-assets`.
20. Interactive: show visual + audio + string choices, ask approval. Autonomous: proceed.

> **`--scene` ownership guard (ADR 0067).** When Phase W ran, do NOT
> write `scene.json` — the World owns the camera/lighting/ground/tick.
> Set `entity.visual.*` on the game's own defs only; the map props keep
> their World-authored visuals. (If the game needs a specific camera
> mode the world didn't set, surface it — don't silently overwrite the
> world's `scene.json`.)

### Phase A — Assets (only if `--with-assets`) — generate the look

Run AFTER the asset-designer wrote `asset_gen.json` (which scans the
defs' `*_prompt` fields) and BEFORE QA, so the visual gate captures the
generated look, not the code-draw placeholders. This is the **Assets
layer** of ADR 0067 — it patches `visual.*` on existing defs in place;
it writes no new content files.

```bash
python3 -m tools.yume_assetgen <name>          # reads data/demo_<name>/asset_gen.json
```

- Generates textures (gpt-image-2 / nanobanana) + meshes (tripo3d) per
  the manifest, writes them under `assets/generated/`, and patches each
  def's `visual.albedo_texture` / `visual.model_3d` to the new
  `res://…` paths. (`--dry-run` to preview the plan; `--init` to scaffold
  a manifest.) See `tools/yume_assetgen/README.md`.
- Generated assets use **versioned filenames** and are **never deleted
  or committed** (gitignored, paid artifacts — memory:
  never-delete / never-commit). Iterate by adding a variant suffix.
- After patching, the NEXT phase must `--headless --import` before
  capture (Godot errors "No loader found" otherwise — memory:
  always-import-after-new-assets).
- **No `--with-assets`?** Skip; the code-draw visuals from Phase 4 ship
  as-is (the key-free default path).

### Phase 5 — qa-tester (verify)

18. Write the scene file `scenes/<name>_2d.tscn` (or `<name>_3d.tscn`)
    from the standard 12-line template. WorldBoot auto-mounts every
    Director Node (GameShell, ScreenFlow, LightingDirector, …) — the
    .tscn just pins data_root, picks the renderer, and places a Camera.

    **2D template** (replace only `<name>`):

    ```
    [gd_scene load_steps=2 format=3]
    [ext_resource type="Script" path="res://scripts/engine/core/world.gd" id="1"]
    [node name="World" type="Node"]
    script = ExtResource("1")
    data_root = "res://data/demo_<name>"
    auto_start = true
    verbose = true
    renderer_script = "res://scripts/renderer_2d/entity_sprite_2d.gd"
    [node name="Camera2D" type="Camera2D" parent="."]
    position = Vector2(0, 0)
    ```

    **3D template** (replace `<name>` + tune Camera3D position/projection):

    ```
    [gd_scene load_steps=2 format=3]
    [ext_resource type="Script" path="res://scripts/engine/core/world.gd" id="1"]
    [node name="World" type="Node"]
    script = ExtResource("1")
    data_root = "res://data/demo_<name>"
    auto_start = true
    verbose = true
    renderer_script = "res://scripts/renderer_3d/entity_mesh_3d.gd"
    [node name="Camera3D" type="Camera3D" parent="."]
    position = Vector3(0, 12, 0)
    rotation = Vector3(-1.5708, 0, 0)
    ```

    No GameShell / ScreenFlow / LightingDirector mounts in the .tscn —
    WorldBoot creates them at boot. Sky/Sun/WorldEnvironment driven by
    `scene.json`'s lighting block via LightingDirector. Ground plane
    driven by `scene.json`'s ground.mesh block via GroundRenderer.

    The universal `scenes/play.tscn --game=<name>` works for any 2D
    game without writing a per-game .tscn; generating a per-game stub
    is a UX shortcut (`godot --path . scenes/<name>_2d.tscn` directly).
19. Invoke `yume-qa-tester` skill. Tool:
    `Skill(skill="yume-qa-tester", args=<data folder + scene path + GDD path>)`.
20. Skill runs Godot headless, drains `env.error_buffer`, produces
    `docs/games/<name>/qa-report.md`.
20b. **Tier 2.6s — Game-specific scenario tests**: content-designer should
    have authored `data/demo_<name>/tests.json` covering 3-5 core verbs
    (input → state change → expected cascade). qa-tester runs:
    `godot --headless scenes/scenario_test.tscn -- --game=demo_<name>`.
    These JSON tests catch behavior bugs the smoke test misses (e.g.,
    "bullet doesn't move after fire"). Schema in
    `scripts/engine/scenario_runner.gd` header.
21. **Tier 2.6r — Visual QA**: after headless smoke test, qa-tester
    runs the game windowed with auto-capture (`scripts/play.sh <name>
    --capture`), reads the captured PNG, and verifies:
    - Entities visible at expected scale (not collapsed at origin)
    - Layout matches design intent (rings/scatters render correctly)
    - HUD renders + lighting applied
    - No obvious clipping / camera-in-wall / wrong-mode-for-content
    Findings appended to qa-report.md alongside cascade verification.
21b. **Tier 2.6r ext — Stage-driven Visual QA** (2026-05-06): the
    spawn-frame capture only catches static rendering bugs. For
    GAMEPLAY-state bugs (HUD bindings only populate after sales,
    haggle screen renders mid-customer-arrival, dungeon layout only
    after East Gate transition), drive scripted input first then
    capture. Use `--capture-input='action,seconds;...'` flag on
    capture_runner; the engine holds each action for the given
    duration via `Input.action_press`/`release` then captures. Per-
    system VQA examples in yume-qa-tester SKILL § "Stage-driven
    visual QA". qa-tester captures both spawn-frame AND at least
    one stage-frame for each major game system (movement, sale,
    haggle UI, phase transition, debt-due splash, tier-up
    celebration).
22. **Autonomous fix-and-retry**: if qa-tester reports a small mechanical
    bug (ternary syntax, typo, missing field, position_scale mismatch),
    the orchestrator may apply the fix inline and re-run. Tier 2.6a
    structured engine errors + Tier 2.6r visual bug recognition make
    this safe. Never invent new logic; only fix what the report
    directly identifies. Limit: max 3 retry cycles before surfacing.
23. Interactive: show QA report + capture path, ask approval.
    Autonomous: proceed.

### Phase 5b — gdd-coverage-tracker (audit)

23a. **MANDATORY** in autonomous mode. After qa-tester reports
     `complete` (correctness verified), run gdd-coverage-tracker:
     `Skill(skill="yume-gdd-coverage-tracker", args=<game-name>)`.

23b. Read its `coverage.md` output. Severity-weighted thresholds:
     - **REQUIRED = 100% AND IMPORTANT ≥ 90% AND NICE gaps all
       documented** → proceed to Phase 7 wrap-up.
     - **Any required ✗ OR important < 90%** → LOOP: parse the gap
       list as a checklist, hand items back to the right designer
       (content / game-rules / asset / etc. per gap type), re-run
       their phases, then re-run qa-tester + gdd-coverage-tracker.
       Cap at 3 loop iterations.
     - **After 2 loops, any same required ✗ persists** → STOP. The
       gap is a structural / engine block, not a content gap. Read
       the tracker's "GDD-revision proposal" section and surface
       it to the user verbatim. User picks: (1) build engine
       extension, (2) edit GDD to remove the promise, (3) accept
       a substitute design. DO NOT pick on the user's behalf.

23c. NEVER declare `accept` to user before reading coverage.md.
     If the user accepts a "with explicit GDD revisions" verdict,
     reflect that in the final summary verbatim — never collapse
     to "accept" alone. Future sessions need the audit trail.

23d. The principle: a GDD is a CONTRACT. Anything written in it
     either lands in the build OR gets cut from the GDD with the
     user's explicit acknowledgment. There is no silent-drop path.
     Empirical case: merchant 2026-05-07 shipped at 32% coverage
     with qa-tester verdict `complete` — that loophole is closed
     by this gate.

### Phase 6 — Optional: asset generation (only if --with-assets)

24. Invoke the offline `yume assets generate <data_root>` tool (Tier
    2.5k — defer to its own workflow; not part of this skill).
25. Re-run qa-tester + gdd-coverage-tracker to verify assets load
    AND that coverage hasn't regressed.

### Phase 7 — Wrap up

26. Summarize what was built:
    - Game name + folder
    - Number of entities, rules
    - Cascades verified
    - Files added (data, scenes, docs, ADRs)
27. Tell user how to run it:
    ```
    godot --path . scenes/<name>_2d.tscn
    godot --path . scenes/<name>_3d.tscn
    ```
28. Suggest next steps (iteration: "want to add X?", "want to refine
    Y?")

## Parallel execution discipline (mid-session, deliverable-level)

The phase pipeline above is mostly sequential by design — each
phase's output is the next phase's input. But within a single
session (especially Tier A/B/C content sessions per a kingdom-sim
GDD), there are typically 3-7 deliverables that can be worked in
parallel because their file boundaries don't overlap.

Empirical case: kingdom-sim merchant Session 2 needs to ship 5
items. Sequential (single-thread) ~3-5 hours; pure parallel
(N agents) ~1.5-2 hours but high coordination cost; **hybrid
~2-3 hours with each item handled by its best-fit thread.**

### When to use parallel builders vs foreground (me)

Classify each deliverable BEFORE starting:

| Profile | Example | Best handler |
|---|---|---|
| **Cross-cutting**: touches ≥3 files, depends on full state-machine context | "4 distinct daily phases" (touches physics + game/rules + hud + scene + screen flow + state) | **Foreground (me/orchestrator)** |
| **Coupled-to-cross-cutting**: requires another in-flight cross-cutting item to land first | "Customer wants matrix" depends on "phases distinct" landing | **Foreground sequential after cross-cutting item** |
| **Self-contained UI**: writes one screen + signal-chain rules with clean file boundary | "Real haggle gauge screen" | **Builder agent (parallel)** |
| **Self-contained pattern demo**: writes new entity defs + new rules, doesn't modify existing rules | "Hire-NPC template" | **Builder agent (parallel)** |
| **Self-contained ai_policy**: writes new actor policy script + new entity, doesn't change existing actors | "Multi-shop NPC competitor" | **Builder agent (parallel)** |
| **New ADR / engine work**: ADR doc + engine module + tests | "ADR 0026 party primitive" | **Builder agent (parallel)** — file boundary is engine/ |

Litmus test for "parallel-safe":
1. Does this deliverable need to read state/files that another
   deliverable also writes? (yes → sequential)
2. Does it modify shared files (test_runner.gd, primitives doc)
   that another agent will also modify? (yes → coordinate)
3. Can I describe the deliverable's file-list in 1 sentence with
   no overlaps? (yes → parallel-safe)

### Sync race — parallel agents must NOT sync to YumeTemplate

CRITICAL constraint discovered Session 2 (2026-05-07): multiple
parallel agents each running `cp -r /home/kamwoh/yume/godot/. /mnt/c/
.../YumeTemplate/` race to overwrite the SAME shared template
directory. If two agents run godot binaries against this shared
template at overlapping times, godot processes see mixed source
state — non-deterministic tests, corrupt captures, file-not-found
errors mid-load.

**Rule: parallel agents WRITE source files only. They do NOT sync
to YumeTemplate. They do NOT run godot. The orchestrator (me) owns
the single integration sync + unit tests + visual QA across the
integrated state.**

This is also why parallel agents stage their rules into files like
`rules_haggle_staged.json` — the orchestrator splices them into the
appropriate `world/rules/<feature>.json` chain module AFTER all agents
land, BEFORE the single sync.

### Spawning parallel builder agents

When launching a `builder` subagent for parallel work, use this
prompt skeleton:

```
Build <deliverable name> for <game-name>.

WHY: <1-2 lines linking to GDD section>

YOUR FILES (own these, don't touch others):
- <path 1>
- <path 2>
...

DO NOT TOUCH (these are owned by me/other agents):
- <path A>
- <path B>
...

SHARED FILES — coordinate by appending only:
- <path X> — append your test sections at end, don't modify others'
- <path Y> — same, append-only

WHAT TO BUILD:
1. <step 1>
2. <step 2>
...

VERIFY:
- DO NOT sync to YumeTemplate. DO NOT run godot binary.
- DO NOT run unit tests or visual QA — orchestrator owns these
  across the integrated state.
- After writing your files, verify they parse as valid JSON / GDScript
  via Read/grep. That's your verification scope.

CONSTRAINTS:
- Per ADR 0021: expose Godot capabilities, don't reimplement
- Path-scoped rules in .claude/rules/ apply
- Visual QA gate per .claude/rules/visual-qa.md mandatory for
  visual-touching changes — construct context-specific prompt

REPORT BACK:
- Files modified + lines changed
- Test count delta (baseline → new)
- Visual QA result (PASS/FAIL with specific evidence)
- If commit: commit hash. If not (shared-file conflict expected):
  files staged for orchestrator to integrate.

Time budget: <estimate>. If blocker, surface — don't push through.
```

### Integration after parallel agents complete

When agents finish:

1. Read each agent's task-notification result
2. For each agent that committed cleanly: pull the commit message
   into your session understanding
3. For each agent that staged files (didn't commit due to shared-
   file conflicts): use `git add -p` to take their hunks cleanly,
   then commit yourself with attribution
4. Run unit tests + visual QA on the integrated state
5. Run gdd-coverage-tracker on the post-integration build
6. If any [R] still ✗: loop back per Phase 5b discipline

### When NOT to spawn parallel builders

- **Designer phases** (game-designer, planner, story-planner,
  economy-designer, level-designer): these write design docs that
  are coordination inputs to everything else. Run sequentially.
- **Reviewer phases**: read-only, but lock-stepped to design output
  they're reviewing. Sequential.
- **qa-tester + gdd-coverage-tracker**: these run AFTER all build
  work to evaluate the integrated state. Always last.
- **Single-deliverable sessions**: if the session has only 1-2
  items, spawning agents adds overhead without payoff.

### Pre-Session checklist

Before starting any content/build session:
1. List the session's deliverables from the GDD's Tier plan
2. Classify each: cross-cutting / coupled / self-contained / engine
3. Identify file boundaries per item
4. Pre-allocate ownership: foreground items + agent items
5. Write each agent's prompt with explicit DO TOUCH / DO NOT TOUCH
   file list
6. Identify shared-file coordination items (test_runner.gd,
   primitives doc, etc.) — pick a strategy (append-only, last-merge,
   or me-as-integrator)
7. Launch parallel agents in same message (multi-tool block)
8. Begin foreground work in parallel
9. Integrate when agents complete

This discipline replaces "vibes-based whether to spawn" with a
defensible decision framework. The merchant 2026-05-07 session
shipped ADR 0024 + 0025 by accidentally getting agents to step on
test_runner.gd; the integration recovery cost ~30 min. Pre-allocated
ownership prevents the recovery cost.

## Failure modes + handling

| Failure | What I do |
|---|---|
| User rejects at any approval gate | Stop, ask what to change, re-invoke that stage |
| systems-designer needs new primitive | Escalate to tech-director. If rejected, ask user to descope |
| content-designer's JSON fails Rule.validate_all | Surface errors, hand back to content-designer with specifics |
| qa-tester reports broken cascades | Identify failure pattern (dead rule, missing query match, runaway), loop back to fix |
| Engine error during qa load | Surface error to user, often indicates content-designer schema bug |
| Tests broken after content add | Reject the content (regression) — should be impossible if rules are valid, but guard anyway |

## Collaboration protocol enforcement

Apply Question → Options → Decision → Draft → Approval at each phase
boundary. Don't apply destructive operations (file writes, agent
invocations that modify state) without user go-ahead.

The user can **abort** at any approval gate; the partial output (GDD
without sketches, sketches without content, etc.) is still valid as
intermediate artifacts.

## Reference docs (read FIRST when invoked)

I read these before invoking any agent, to ground myself in current
state:

- `docs/guideline/30_framework_primitives.md` — primitive contract
- `docs/guideline/32_mda_for_yume.md` — design vocabulary
- `docs/guideline/31_text_to_game_pipeline.md` — full pipeline architecture
- `.claude/skills/yume-*/SKILL.md` — specialist skills (loaded via Skill tool)
- `.claude/rules/` — path-scoped rule files
- `task_plan.md` — current state of the framework

If reading any of these reveals the framework is in a broken state
(failing tests, half-landed primitive change, etc.) → surface to user
before starting. Don't generate against a broken baseline.

## What I do NOT do

- ❌ Write GDDs, sketches, JSON, or QA reports myself. Always delegate
  to the appropriate specialist agent.
- ❌ Skip approval gates to "save time."
- ❌ Modify engine code (only tech-director gates engine changes).
- ❌ Generate assets (Tier 2.5k tool, separate workflow).
- ❌ Promise specific genre support not validated by the W5 acid test
  (visual novels, rhythm games, soft-body physics — out of scope).

## Honest scope reminder

Yume covers **simulation-shaped games**: ecology, farming, RPG, shooter,
chess, survival, strategy, tower defense, roguelike, puzzle-with-state.

Out of scope: rhythm games, precision platformers, narrative-heavy
adventures, continuous physics simulation, networked multiplayer.

If the prose asks for one of these, I tell the user upfront before
spending agent calls.

## Example invocation transcript

```
> /yume-design "a farming sim where moonlight grows crops faster"

I'll run the Yume text-to-game pipeline. Plan:
- Game name: '<auto-suggested-slug>' (from prose). OK?
- 6 stages: GDD → sketches → content → assets → QA → wrap
- Code-draw visuals (no --with-assets flag)

Approval to start?

> yes

[Phase 1: invoking yume-game-designer...]
[GDD written: docs/games/<game>/GDD.md]

GDD summary:
- Aesthetics: Submission + Sensation
- Dynamics: day/night cycle modulates crop growth; rot → fertilizer cycle
- Mechanics: ~6 entity types, ~10 rule sketches
- Open question: should night be a global state or distance from a
  "moon" entity?

Approve GDD?

> yes, global state is fine

[Phase 2: invoking yume-systems-designer...]
...
```

## Status

This skill is the orchestrator (Tier 2.5g, expanded for Tier 2.7
design-quality phases). The 8 specialist skills it invokes are at
`.claude/skills/yume-<role>/`:

- `yume-game-designer` — Phase 1 (prose → GDD)
- `yume-game-reviewer` — Phase 1b (adversarial GDD critique)
- `yume-game-planner` — Phase 1c (GDD → world plan, named cast)
- `yume-level-designer` — Phase 1d (spatial layout + rationale)
- `yume-combining-logic-designer` — Phase 1e.1 (recipe systems — CONDITIONAL)
- `yume-economy-designer` — Phase 1e.2 (numeric balance + flows — CONDITIONAL)
- `yume-story-planner` — Phase 1e.3 (narrative beats + arcs — CONDITIONAL)
- `yume-systems-designer` — Phase 2 (ALL rules — `world/rules/*.json` feature modules, scope expanded per ADR 0009 revision 2026-05-16)
- `yume-content-designer` — Phase 3 (entities + initial state)
- `yume-game-rules-designer` — Phase 3.5 (declarative win/lose in `hud.json` + `game/flow.json` multi-level progression — NARROWED scope post-revision)
- `yume-asset-designer` — Phase 4 (visuals + audio cues + UI strings)
- `yume-qa-tester` — Phase 5 (headless + visual + scenario QA)
- `yume-tech-director` — invariant guardian, on-demand

Behavioral tests are Tier 2.5h — see `tests/spec.md`.
