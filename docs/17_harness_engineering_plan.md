# Yume Harness Engineering Improvement Plan

## Current Score vs Best Practices

| Practice | Current | Target | Status |
|----------|---------|--------|--------|
| CLAUDE.md | 182 lines | < 200 lines | ✅ DONE |
| /yume skill | 6 commands, rules, docs refs | Add level design rules, 3D workflow | ✅ DONE |
| Lessons | 101 lessons in ~/.yume/lessons/ | Keep growing, deduplicate periodically | ✅ ONGOING |
| Hooks | 5 hooks (pre-commit, JSON validate, hardcode check, error-learn, session log) | — | ✅ DONE |
| Multi-agent | 3 agents (designer/builder/tester) | Use in practice | ✅ DONE |
| Test automation | 4-layer + auto-capture + visual regression | — | ✅ DONE |
| Git safety | Manual commits | Auto-commit after passing tests | LOW |
| Context handoff | progress.md + task_plan.md + yume_state.json | — | ✅ DONE |

## Implementation (All Complete)

### 1. CLAUDE.md ✅
- 182 lines — under the 200-line target

### 2. Hooks ✅ (5 hooks in .claude/settings.json)

| Hook | Event | What it does |
|------|-------|-------------|
| Pre-commit test | PreToolUse:Bash | Detects `git commit`, runs validate_game_data.py first |
| Location JSON validate | PostToolUse:Write | Validates location JSON on write |
| Hardcode check | PostToolUse:Write | Scans GDScript for hardcoded Color/Vector values |
| Error-learn tracker | PostToolUse:Bash | Tracks failed commands, suggests `yume learn` after 3+ repeats |
| Session log | Stop | Logs timestamp to session_log.txt |

### 3. Multi-Agent Pattern ✅ (.claude/agents/)

| Agent | Type | Role |
|-------|------|------|
| designer.md | Explore (read-only) | Plans room layouts, camera configs, composition |
| builder.md | general-purpose | Generates JSON + GDScript from designer plans |
| tester.md | general-purpose | Runs tests, auto-capture, evaluates visual quality |

### 4. Visual Regression Testing ✅ (tools/visual_regression.py + CLI)
```bash
yume visual-regression <captures_dir> --save-baseline  # Save reference
yume visual-regression <captures_dir>                   # Compare against baseline
yume visual-regression <captures_dir> --json            # Machine-readable report
```
- Pixel-level diff with configurable threshold (default 5%)
- Reports: new/missing/changed captures with diff percentages
- Saves regression_report.json for automation

### 5. Structured State File ✅ (.claude/yume_state.json)
- Machine-readable: current project, phase, pending fixes, available models

### 6. Error-Learn Hook ✅
- Tracks error signatures in .claude/error_log.jsonl
- After same command fails 3+ times → prints reminder to save lesson

### 7. Lessons Knowledge Base ✅
- 101 lessons in ~/.yume/lessons/ (YAML, organized by archetype/system)
- CLI: `yume list-lessons`, `yume learn --problem "..." --fix "..."`

## What Makes Yume Unique as a Harness

Most Claude Code projects have: CLAUDE.md + git.
Yume has:
1. **Domain-specific skill** (/yume) with game dev commands
2. **Growing knowledge base** (90+ lessons persist across sessions)
3. **Automated visual QA** (auto-capture → Claude sees the game)
4. **Playthrough simulation** (Python simulates entire game without running it)
5. **Multi-layer testing** (data → systems → playthrough → Godot headless)
6. **Asset management UI** (web dashboard for all game assets)
7. **Framework-first** (templates, not one-off projects)

This is beyond typical harness engineering — it's a **domain-specific AI development environment** for game creation.
