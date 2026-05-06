# Yume (夢)

JSON-driven game framework on Godot 4. The engine ships seven primitives
+ a small interpreter; each game's mechanics are pure JSON.

## Run a demo

Demos are not tracked in git — generate them locally via the
text-to-game pipeline (see below) or copy from a colleague's
working copy. Once a demo exists at `godot/data/demo_<name>/`:

```bash
./scripts/play.sh <name>        # falls back to scenes/play.tscn --game=<name>
```

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

- `godot/` — engine + demos (the live framework)
- `docs/30_framework_primitives.md` — the contract
- `docs/adr/` — architectural decisions
- `.claude/skills/yume-*/` — 28 specialist skills
- `CLAUDE.md` — full project instructions

Built around the principle: **engine = primitives + interpreter; games
= JSON content; Godot = exposed substrate** (per ADR 0021).
