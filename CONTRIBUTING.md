# Contributing to Yume

Thanks for your interest! Yume is an experiment in a codebase **written by an
AI and designed to be operated by an AI** — so contributing here looks a little
different from a typical repo.

## The intended workflow: drive it with Claude

The conventions, build steps, run workflow, and design invariants live in
[`CLAUDE.md`](CLAUDE.md) and [`.claude/`](.claude/) precisely so that
[Claude Code](https://claude.com/claude-code) can operate the repo. The
recommended way to make changes is to **open the repo in Claude Code and ask in
plain English** — "add a `pathfind_to` variant", "generate a tower-defense
demo", "fix this validator". Claude knows the fiddly bits (syncing to the Godot
template, `--path .`, asset `--import`, the visual-QA gate).

You can absolutely contribute by hand too — the rest of this doc is for that.

## Setup

See [`INSTALLATION.md`](INSTALLATION.md): Godot 4.6.1 + a Python `venv`. Then:

```bash
./scripts/play.sh sokoban          # run a committed example
./scripts/play.sh sokoban --capture
# engine unit tests: see CLAUDE.md § "Running Godot"
```

Three committed examples run with **no API keys**: `demo_sokoban` (2D),
`demo_doomarena3d` (FPS), `demo_lanterns` (third-person). Generating *new*
games with `--scene` / `--with-assets` needs image-gen / Tripo keys, but the
no-flag path is always key-free.

## Conventions (please read before a PR)

- **Data drives everything** (Invariant #1) — game behavior is JSON, never
  game-specific GDScript. The engine is a fixed **primitives + interpreter**
  (Invariant #8). A new capability is either a composition of existing verbs
  (JSON) or a new primitive **with an ADR** under `docs/adr/`.
- **Path-scoped rules** in [`.claude/rules/`](.claude/rules/) gate edits to
  `scripts/engine/**`, `data/**`, `docs/**`, etc. Read the matching rule first.
- **Every primitive ships with a test** in `scripts/engine/tests/test_runner.gd`.
- **Post-mortem ritual**: when a bug surfaces, don't just fix it — find the
  skill/rule/validator that should have caught it and **harden that gate**
  (prefer an enforced test/validator over prose). See
  `.claude/rules/post-mortem.md`.
- **Don't commit generated/paid assets** (`.glb`, gen textures) — they're
  gitignored + regenerated; the committed example meshes are a deliberate,
  slimmed exception.
- **No trademarked game names** in code, commits, or tracked docs — use generic
  genre descriptors.
- **Pre-1.0**: replace outright, don't add deprecation shims/compat layers.

## Commits

- Match the surrounding style; keep changes surgical (touch only what the
  change requires).
- Co-author engine work from Claude:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## Issues & discussions

Bug reports, design questions, and "can Yume do X?" are all welcome — open an
issue. Be honest about scope (the README "Known gaps" table is the source of
truth for what's thin).
