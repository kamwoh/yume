---
name: yume-design
description: Run the Yume text-to-game pipeline. Orchestrates 6 specialist agents (game-designer → systems-designer → content-designer → asset-designer → qa-tester) with user-approval gates between each stage. Optional flags `--with-assets` for AI-gen pipeline, `--style=pixel-art|low-poly-3d|ascii` for art-style hint, `--name=<slug>` for game folder name.
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
delegate to the 6 specialist agents in `.claude/agents/yume/`.

### Phase 0 — Setup (in my own context, no agent)

1. Parse the prose + flags.
2. Auto-suggest a `<name>` slug from the prose (e.g., "moonfarm" for
   the moonlight farming game).
3. **Show the user my plan** for the pipeline and confirm:
   - Game folder: `data/demo_<name>/`
   - GDD path: `docs/games/<name>/GDD.md`
   - Stages I'll run + approvals between each
4. Wait for explicit go-ahead before Phase 1.

### Phase 1 — game-designer (prose → GDD)

5. Invoke `yume-game-designer` agent with the prose. Tool:
   `Agent(subagent_type="yume-game-designer", prompt=<prose>)`.
6. Agent produces `docs/games/<name>/GDD.md`.
7. **Show user the GDD path + summary.** Ask: "Approve GDD? (y / edit /
   reject)"
8. On approve → Phase 2. On edit → re-invoke game-designer with user
   feedback. On reject → stop, report.

### Phase 2 — systems-designer (GDD → rule sketches)

9. Invoke `yume-systems-designer` with the GDD path. Tool:
   `Agent(subagent_type="yume-systems-designer", prompt=<GDD path + intent>)`.
10. Agent produces `docs/games/<name>/rules-sketch.md`. May also
    propose ADRs at `docs/adr/NNNN-*.md` if new primitives needed.
11. **If ADR proposed → escalate to tech-director:**
    Invoke `yume-tech-director` with the ADR path.
    On rejection → systems-designer iterates without the new primitive.
    On accept → ADR status set to `accepted`, proceed.
12. **Show user the sketch + any ADRs.** Ask: "Approve sketches?"
13. On approve → Phase 3.

### Phase 3 — content-designer (sketches → JSON)

14. Invoke `yume-content-designer` with sketch path + GDD path.
15. Agent writes:
    - `archetypes/core/templates/godot/data/demo_<name>/entities.json`
    - `archetypes/core/templates/godot/data/demo_<name>/world_rules.json`
16. **Show user the file paths + summary** (counts, key rules).
    Ask: "Approve content?"

### Phase 4 — asset-designer (visual + audio fields)

17. Invoke `yume-asset-designer` with GDD + entities path + style flag.
18. Agent updates `entity.visual.*` fields. If `--with-assets`, also
    writes `data/demo_<name>/asset_gen.json`.
19. **Show user the visual choices.** Ask: "Approve assets?"

### Phase 5 — qa-tester (verify)

20. Create scene files for the new game:
    - `archetypes/core/templates/godot/scenes/<name>_2d.tscn`
    - `archetypes/core/templates/godot/scenes/<name>_3d.tscn`
    (Pattern from existing demo scenes — copy + change `data_root`.)
21. Invoke `yume-qa-tester` with the data folder + GDD + scene paths.
22. Agent runs Godot headless, reads tick output, produces
    `docs/games/<name>/qa-report.md`.
23. **Show user the QA report.** If cascades fail / dead rules / runaway
    loops → loop back to content-designer or systems-designer.

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

This skill is the orchestrator (Tier 2.5g). The 6 agents it invokes
are at `.claude/agents/yume/`. Behavioral tests for this skill are
Tier 2.5h — see `tests/spec.md`.
