---
name: yume-design
description: Run the Yume text-to-game pipeline. Orchestrates 7 specialist skills (yume-game-designer → game-planner → systems-designer → content-designer → asset-designer → qa-tester, plus tech-director on demand) with optional user-approval gates. Skills load into orchestrator context (no subagent spawn — Tier 2.6 architecture). Flags - `--autonomous` skips approval gates and runs end-to-end. `--plan-only` stops after the planning phases (GDD + world-plan) so the user can review before any JSON is committed. `--with-assets` invokes AI-gen pipeline. `--style=pixel-art|low-poly-3d|ascii` art-style hint. `--name=<slug>` game folder name.
---

# /yume-design — text-to-game pipeline

Turn a prose game description into a runnable Yume game.

## Usage

```
/yume-design <prose description of the game>
/yume-design "a farming sim where moonlight grows crops faster" --style=pixel-art --name=moonfarm
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

**Skills, not subagents (Tier 2.6 finding).** Earlier versions of this
pipeline spawned subagents via `Agent(subagent_type=...)`. Empirical
test in harvestcore QA (2026-05-02) showed subagent spawns can hit org
auth policies (`organization has disabled Claude subscription access`).
Skills load into the orchestrator's main context — same role prompts,
no auth boundary, lower latency, fewer moving parts.

**Autonomous mode.** If the user passes `--autonomous` in the prompt,
skip the per-phase user-approval gates and walk all phases in one
shot, surfacing only on hard failure or at the final wrap. Default
(no flag) is interactive: pause after each phase for user approval.

### Phase 0 — Setup (no skill load)

1. Parse the prose + flags. Detect `--autonomous`, `--name=<slug>`,
   `--style=<value>`, `--with-assets`.
2. Auto-suggest a `<name>` slug from the prose (e.g., "moonfarm" for
   the moonlight farming game) if `--name=` not given.
3. State the plan: paths, phases, autonomous-or-interactive mode.
4. Interactive mode: wait for explicit go-ahead. Autonomous: proceed.

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

**Rules layout**:
- Small (≤ 15 rules): single `world_rules.json`
- Medium (15-40): single `world_rules.json`, but ordered by category
  blocks with `_comment` headers
- Large (40+): `rules/` directory with category files
  (e.g. `rules/clock.json`, `rules/movement.json`, `rules/eating.json`)

**Always**:
- `scene.json`, `hud.json`, `world.json` are single-file (small enough)
- New shapes append to **`data/shapes.json` root**, NOT per-game
- Per-game scene `.tscn` is a 12-line template stub (auto-written by
  orchestrator at Phase 5; see template body in this doc)
- Universal `scenes/play.tscn` works for any game via `--game=` arg

State the chosen layout to the user (interactive) or proceed with it
(autonomous). Pass layout to each skill in its arg payload so it
writes files in the right structure:

```
LAYOUT CHOSEN:
- entity_layout: medium → entities/ directory
- rule_layout: small → single world_rules.json
- assets: code-draw shapes appended to data/shapes.json root
```

This step prevents per-skill drift — content-designer and asset-designer
both follow the orchestrator's chosen plan instead of inventing their own.

### Phase 1 — game-designer (prose → GDD)

5. Invoke `yume-game-designer` skill. Tool:
   `Skill(skill="yume-game-designer", args=<prose + name>)`.
6. The skill's instructions load into my context; I execute them and
   produce `docs/games/<name>/GDD.md`.
7. Interactive: show GDD summary, ask "Approve? (y / edit / reject)".
   Autonomous: produce a 5-line summary internally and proceed; resolve
   any "open questions" the GDD flags by best-judgment and document the
   resolution in my next-phase prompt to systems-designer.

### Phase 1b — game-planner (GDD → world plan)

7a. Invoke `yume-game-planner` skill. Tool:
    `Skill(skill="yume-game-planner", args=<GDD path>)`.
7b. Skill produces `docs/games/<name>/world-plan.md` — named NPCs,
    items, plants, events, town layout, day-1 onboarding flow.
7c. Interactive: show plan summary (cast count, item categories, key
    events) — ask user to approve.
    Autonomous: produce a 5-line summary internally and proceed.
7d. **If `--plan-only` flag was set**: stop here. Write a final
    summary listing the GDD path + world-plan path. Tell the user to
    re-invoke `/yume-design <name> --resume` once they've reviewed the
    plan to continue from Phase 2.

The world-plan is the single source of truth for named content
(NPCs, items, plants, events). All downstream skills read it:
- systems-designer references named entities when sketching rules
- content-designer wires names directly into entities/*.json
- asset-designer reads visual hints + applies consistent style

### Phase 2 — systems-designer (GDD → rule sketches)

8. Invoke `yume-systems-designer` skill. Tool:
   `Skill(skill="yume-systems-designer", args=<GDD path + resolved questions>)`.
9. Skill produces `docs/games/<name>/rules-sketch.md`. May propose ADRs
   at `docs/adr/NNNN-*.md` if new primitives needed.
10. **If ADR proposed → escalate to tech-director:**
    `Skill(skill="yume-tech-director", args=<ADR path + diff>)`.
    On rejection → re-invoke systems-designer without the new primitive.
    On accept → ADR status set to `accepted`, proceed.
11. Interactive: show sketch + ADRs, ask approval. Autonomous: proceed.

### Phase 3 — content-designer (sketches → JSON)

12. Invoke `yume-content-designer` skill. Tool:
    `Skill(skill="yume-content-designer", args=<sketch path + GDD path + design decisions>)`.
13. Skill writes `entities.json`, `world_rules.json`, optional `world.json`,
    `shapes.json` under `archetypes/core/templates/godot/data/demo_<name>/`.
14. Interactive: show file summary, ask approval. Autonomous: proceed.

### Phase 4 — asset-designer (visual + audio fields)

15. Invoke `yume-asset-designer` skill. Tool:
    `Skill(skill="yume-asset-designer", args=<GDD path + entities path + style flag>)`.
16. Skill updates `entity.visual.*` fields, extends `shapes.json`, and
    writes `asset_gen.json` if `--with-assets`.
17. Interactive: show visual choices, ask approval. Autonomous: proceed.

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
- `.claude/agents/yume/README.md` — agent index + handoff protocol
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
- Game name: 'moonfarm' (from prose). OK?
- 6 stages: GDD → sketches → content → assets → QA → wrap
- Code-draw visuals (no --with-assets flag)

Approval to start?

> yes

[Phase 1: invoking yume-game-designer...]
[GDD written: docs/games/moonfarm/GDD.md]

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

This skill is the orchestrator (Tier 2.5g). The 6 specialist skills it
invokes are at `.claude/skills/yume-<role>/`:

- `yume-game-designer` — Phase 1 (prose → GDD)
- `yume-systems-designer` — Phase 2 (GDD → rule sketches)
- `yume-content-designer` — Phase 3 (sketches → JSON)
- `yume-asset-designer` — Phase 4 (visual fields)
- `yume-qa-tester` — Phase 5 (headless verification)
- `yume-tech-director` — invariant guardian, on-demand

The legacy `.claude/agents/yume/*.md` subagents are kept as fallback
for users who configure `ANTHROPIC_API_KEY` and prefer subagent
isolation, but skills are the primary path (Tier 2.6 finding).

Behavioral tests are Tier 2.5h — see `tests/spec.md`.
