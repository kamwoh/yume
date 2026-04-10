# Yume Harness Engineering Improvement Plan

## Current Score vs Best Practices

| Practice | Current | Target | Priority |
|----------|---------|--------|----------|
| CLAUDE.md | ~250 lines, good content | < 200 lines, trim to essentials | MEDIUM |
| /yume skill | 6 commands, rules, docs refs | Add level design rules, 3D workflow | DONE |
| Lessons | 90+ lessons, auto-save | Keep growing, deduplicate periodically | ONGOING |
| Hooks | 3 hooks (JSON validate, hardcode check, session log) | Add pre-commit test, auto-capture after 3D changes | HIGH |
| Multi-agent | Used once (design team) | Define permanent roles: designer/builder/tester | HIGH |
| Test automation | 4-layer + auto-capture | Add visual regression (compare captures) | MEDIUM |
| Git safety | Manual commits | Auto-commit after passing tests | LOW |
| Context handoff | progress.md + task_plan.md | Add structured JSON state file | MEDIUM |

## Improvement Plan

### 1. Trim CLAUDE.md (MEDIUM)
- Audit current line count
- Move detailed docs/tables to separate files
- Keep only: stack overview, key commands, design principles, common pitfalls
- Target: < 200 lines

### 2. Add More Hooks (HIGH)
```json
// Pre-commit: ensure tests pass
{"event": "PreToolUse", "matcher": "Bash",
 "command": "if git commit detected → run yume test first"}

// Auto-capture after 3D location changes
{"event": "PostToolUse", "matcher": "Write",
 "command": "if location JSON changed → run auto_capture → save screenshots"}

// Lesson reminder after errors
{"event": "PostToolUse", "matcher": "Bash",
 "command": "if exit code != 0 → remind to yume learn"}
```

### 3. Multi-Agent Pattern (HIGH)
Define 3 agent roles that can work in parallel:

**Designer Agent** (Explore type, read-only):
- Analyzes requirements, references, design docs
- Outputs: room layouts, prop placement plans, camera configs
- Uses: level design rules, reference images, MIT course knowledge

**Builder Agent** (general-purpose):
- Reads designer output → generates JSON data + GDScript
- Follows framework templates, no hardcoded values
- Uses: pass0-5 prompts, asset_config, visual_config

**Tester Agent** (general-purpose):
- Runs yume test, auto-capture, auto-agent
- Reads screenshots → evaluates quality
- Reports: what works, what's broken, what needs redesign

```
User request → Designer plans → Builder creates → Tester verifies
                  ↑                                    |
                  └──── fix feedback ←─────────────────┘
```

### 4. Visual Regression Testing (MEDIUM)
- After each auto-capture, save as "baseline"
- Next capture → compare against baseline
- Report: "room changed — new objects, different lighting"
- Catch: accidental regressions (room that looked good now looks broken)

### 5. Structured State File (MEDIUM)
```json
// .claude/yume_state.json — machine-readable session state
{
  "current_project": "Yume3D",
  "current_phase": "level_design_study",
  "active_location": "dungeon_grid",
  "last_capture_count": 123,
  "last_test_result": "20 pass, 1 fail",
  "pending_fixes": ["barrel rotation", "wall textures", "camera distance"],
  "lessons_this_session": 5
}
```

### 6. Auto-Learn from Errors (LOW)
Hook that detects repeated errors and auto-saves lessons:
- Same GDScript error 3 times → auto `yume learn`
- Same JSON validation failure → auto `yume learn`
- Prevents re-learning the same lesson manually

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
