# Yume specialist agents

Six specialists that compose into the **text-to-game pipeline**. Each is
a Claude Code subagent (`.md` file with YAML frontmatter); each has a
distinct role and reads/writes its own slice of files.

The pipeline (linear, with feedback loops):

```
prose → game-designer → GDD
              ↓
        systems-designer → rule sketches + ADRs (if any)
              ↓
        content-designer → entities.json + world_rules.json
              ↓
        asset-designer → visual + audio fields
              ↓
        qa-tester → cascade verification + report
              ↓
        tech-director (cross-cutting) — gates engine changes
```

## The agents

| Agent | Role | Inputs | Outputs |
|---|---|---|---|
| `yume-game-designer` | Prose → GDD via MDA | User prose | `docs/games/<name>/GDD.md` |
| `yume-systems-designer` | GDD → rule sketches | GDD | `docs/games/<name>/rules-sketch.md` + ADRs (if any) |
| `yume-content-designer` | Sketches → JSON | rule sketches + GDD | `data/<name>/{entities, world_rules}.json` |
| `yume-asset-designer` | Aesthetics → visual/audio | GDD + entities.json | Updates `entity.visual.*` + optional `asset_gen.json` / `asset_catalog.json` |
| `yume-qa-tester` | JSON → empirical verification | data folder + GDD | `docs/games/<name>/qa-report.md` |
| `yume-tech-director` | Engine invariant guardian | Proposed engine changes | Approve/reject + run regression suite |

## Invocation

Via Claude Code:

```
@yume-game-designer build me a farming sim where moonlight grows crops faster
```

Or invoke through the unified skill (Tier 2.5g — not yet built):

```
/yume-design "a farming sim where moonlight grows crops faster"
```

## Collaboration protocol

Every agent applies the **Question → Options → Decision → Draft →
Approval** protocol from `CLAUDE.md`. Trivial changes skip 1-3.
Non-trivial changes (new primitives, structural choices) require all 5.

Agents don't silently override each other. If qa-tester finds an
unworkable rule, it reports → user routes back to content-designer
or systems-designer.

## Reference docs each agent reads

All agents share the contract:
- `docs/30_framework_primitives.md` — primitive vocabulary
- `docs/32_mda_for_yume.md` — design vocabulary
- `docs/31_text_to_game_pipeline.md` — pipeline architecture
- `.claude/rules/` — path-scoped rules

Per-agent specifics:
- game-designer reads MDA + non-goals
- systems-designer reads rule patterns from existing demos
- content-designer reads schema rules from `data-demo.md`
- asset-designer reads shapes.json + meshes.json catalogs
- qa-tester reads test_runner.gd patterns
- tech-director reads ADR formats + engine code

## Status

- ✅ All 6 agents written (this commit)
- 📋 `/yume-design` skill (2.5g) — orchestrates them in sequence
- 📋 Behavioral tests (2.5h) — given prompt X, expected output Y
