# Yume (夢)

JSON-driven game framework on Godot 4. The engine ships seven primitives
+ a small interpreter; each game's mechanics are pure JSON.

## Run a demo

```bash
./scripts/play.sh sokoban       # turn-based puzzle
./scripts/play.sh tinypond      # ecology sandbox
./scripts/play.sh doomarena3d   # FPS arena
```

Demos live under `archetypes/core/templates/godot/data/demo_<name>/`.

## Generate a new game

Launch Claude Code in this repo and invoke:

```
/yume-design "<your prose pitch>" --autonomous
```

Pipeline orchestrates 9 specialist skills (game-designer → reviewer →
planner → level-designer → systems-designer → game-rules-designer →
content-designer → asset-designer → qa-tester) and lands a working
game under `data/demo_<slug>/`.

## Architecture

- `archetypes/core/templates/godot/` — engine + demos (the live framework)
- `docs/30_framework_primitives.md` — the contract
- `docs/adr/` — architectural decisions
- `.claude/skills/yume-*/` — 28 specialist skills
- `CLAUDE.md` — full project instructions

Built around the principle: **engine = primitives + interpreter; games
= JSON content; Godot = exposed substrate** (per ADR 0021).
