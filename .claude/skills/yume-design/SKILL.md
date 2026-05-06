---
name: yume-design
description: Run the Yume text-to-game pipeline. Orchestrates 7 specialist skills (yume-game-designer → game-planner → systems-designer → content-designer → asset-designer → qa-tester, plus tech-director on demand) with optional user-approval gates. Skills load into orchestrator context (no subagent spawn — Tier 2.6 architecture). Flags - `--autonomous` skips approval gates and runs end-to-end. `--plan-only` stops after the planning phases (GDD + world-plan) so the user can review before any JSON is committed. `--with-assets` invokes AI-gen pipeline. `--style=pixel-art|low-poly-3d|ascii` art-style hint. `--name=<slug>` game folder name.
---

# /yume-design — text-to-game pipeline

Turn a prose game description into a runnable Yume game.

## Usage

```
/yume-design <prose description of the game>
/yume-design "a farming sim where moonlight grows crops faster" --style=pixel-art --name=<your-game>
/yume-design "a roguelike where vampires steal HP from light sources" --with-assets
```

Args (parsed from the user's prompt after `/yume-design`):

- `<prose>` — the game description (free-form). Required.
- `--style=<value>` — `pixel-art` / `low-poly-3d` / `ascii` / `realistic`.
  Defaults to user-stated preference in prose, else `pixel-art`.
- `--name=<slug>` — game folder name. Defaults to a slug derived from
  the prose (auto-suggest: ask user to confirm).
- `--with-assets` — invoke AI-gen pipeline at the end. Default: skip.
  Without this flag, code-draw fallback is used.

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
   `--style=<value>`, `--with-assets`.
2. Auto-suggest a `<name>` slug from the prose (a 1-2 syllable
   shorthand of the genre + theme) if `--name=` not given.
3. State the plan: paths, phases, autonomous-or-interactive mode.
4. Interactive mode: wait for explicit go-ahead. Autonomous: proceed.

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
├── world/physics.json                      # how the world works
├── game/rules.json                         # scoring + win/lose
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

**Rules layout** (ADR 0009 — always split by axis):
- `world/physics.json` — motion, AI, contact resolution, decay,
  lifecycle (yume-systems-designer)
- `game/rules.json` — scoring, win/lose, transitions, level-up
  (yume-game-rules-designer)
- For pure simulations with no game layer (chess, ecology), omit
  `game/rules.json` entirely — physics-only is fine.
- Per-level rules go to `levels/<name>/rules.json`.

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
- rules: world/physics.json (systems) + game/rules.json (game)
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
| **merchant** | "merchant", "shopkeeper", "item shop", "Recettear", "trader", "Moonlighter" | `yume-merchant-designer` | `yume-merchant-reviewer` |
| **racing** | "racing", "kart", "F-Zero", "Wipeout", "Trackmania", "Burnout" | `yume-racing-designer` | (future: yume-racing-reviewer) |
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

### Phase 2 — systems-designer (GDD → world physics)

Per ADR 0009, this skill now writes `world/physics.json` directly
(in addition to the rule-sketch document for review).

8. Invoke `yume-systems-designer` skill. Tool:
   `Skill(skill="yume-systems-designer", args=<GDD path + resolved questions>)`.
9. Skill produces `docs/games/<name>/rules-sketch.md` + `world/physics.json`
   under the data folder. May propose ADRs if new primitives needed.
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

### Phase 3.5 — game-rules-designer (game logic) ★ NEW per ADR 0009

15. Invoke `yume-game-rules-designer` skill. Tool:
    `Skill(skill="yume-game-rules-designer", args=<GDD + world/physics.json>)`.
16. Skill writes `game/rules.json` (scoring, win/lose, transitions,
    restart) and `game/flow.json` (level sequence + on-all-complete).
    For sandbox sims (no goals), this phase is SKIPPED — game/ folder
    stays empty.
17. Interactive: show game-logic decisions, ask approval. Autonomous: proceed.

### Phase 4 — asset-designer (visuals + audio + UI strings)

Per ADR 0009 expanded scope: also writes audio/cues.json + ui/strings.json.

18. Invoke `yume-asset-designer` skill. Tool:
    `Skill(skill="yume-asset-designer", args=<GDD + entities path + style flag>)`.
19. Skill updates `entity.visual.*` + `audio.*` fields, writes `scene.json`,
    `hud.json`, `audio/cues.json` (semantic event → sound mapping),
    `ui/strings.json` (localizable HUD text), and `asset_gen.json` if
    `--with-assets`.
20. Interactive: show visual + audio + string choices, ask approval. Autonomous: proceed.

### Phase 5 — qa-tester (verify)

18. Write the scene file `scenes/<name>_2d.tscn` from the standard
    template — JSON-driven games never hand-edit this. Use this exact
    body, replacing only `<name>`:

    ```
    [gd_scene load_steps=3 format=3]
    [ext_resource type="Script" path="res://scripts/engine/world.gd" id="1"]
    [ext_resource type="Script" path="res://scripts/engine/game_shell.gd" id="2"]
    [node name="World" type="Node"]
    script = ExtResource("1")
    data_root = "res://data/demo_<name>"
    auto_start = true
    verbose = true
    renderer_script = "res://scripts/renderer_2d/entity_sprite_2d.gd"
    [node name="GameShell" type="Node" parent="."]
    script = ExtResource("2")
    [node name="Camera2D" type="Camera2D" parent="."]
    position = Vector2(0, 0)
    ```

    No game-specific code; only data_root differs from other games.
    The universal `scenes/play.tscn` (with `--game=` cmdline arg) also
    works — but generating a per-game stub gives a cleaner UX:
    `godot --path . scenes/<name>_2d.tscn`.
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
22. **Autonomous fix-and-retry**: if qa-tester reports a small mechanical
    bug (ternary syntax, typo, missing field, position_scale mismatch),
    the orchestrator may apply the fix inline and re-run. Tier 2.6a
    structured engine errors + Tier 2.6r visual bug recognition make
    this safe. Never invent new logic; only fix what the report
    directly identifies. Limit: max 3 retry cycles before surfacing.
23. Interactive: show QA report + capture path, ask approval.
    Autonomous: proceed.

### Phase 6 — Optional: asset generation (only if --with-assets)

24. Invoke the offline `yume assets generate <data_root>` tool (Tier
    2.5k — defer to its own workflow; not part of this skill).
25. Re-run qa-tester to verify assets load.

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

- `docs/30_framework_primitives.md` — primitive contract
- `docs/32_mda_for_yume.md` — design vocabulary
- `docs/31_text_to_game_pipeline.md` — full pipeline architecture
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
- `yume-systems-designer` — Phase 2 (world physics rules — `world/physics.json`)
- `yume-content-designer` — Phase 3 (entities + initial state)
- `yume-game-rules-designer` — Phase 3.5 (game logic — `game/rules.json` + `game/flow.json`) ★ ADR 0009
- `yume-asset-designer` — Phase 4 (visuals + audio cues + UI strings)
- `yume-qa-tester` — Phase 5 (headless + visual + scenario QA)
- `yume-tech-director` — invariant guardian, on-demand

Behavioral tests are Tier 2.5h — see `tests/spec.md`.
