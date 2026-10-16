#!/usr/bin/env python3
"""validate_claude_config.py — check that Claude Code loads .claude/ as we expect.

This validator is repo-wide. It takes no game argument. It checks four things:

1. Each `.claude/skills/<dir>/SKILL.md` starts with YAML frontmatter. The
   frontmatter must parse strictly. It must have `name: <dir>` and a
   `description` of 30-300 characters. A broken frontmatter causes no error.
   The router only shows a blank or cut description, and the model then
   never selects the skill.
2. Each `.claude/rules/*.md` has no frontmatter (always-on), or it sets
   its scope with a `paths:` list. `globs:` is the Cursor field. Claude
   Code ignores it and loads the rule on EVERY turn.
3. Each skill with `context: fork` has a `## Inputs and outputs` section
   (ADR 0082) with the labels Arguments, Output and Return. A forked
   skill sees no chat history. Without that
   section, the caller does not know which arguments to pass, and the
   skill does not know which file to write.
4. No skill, rule or CLAUDE.md runs Godot with an absolute `--path`.
   Godot aborts with "Invalid project path" and prints no test output.
   Use `cd "$TEMPLATE_DST"` and `--path .`, or `./scripts/play.sh`.
   Empirical case 2026-10-16: 8 skills kept their own copy of a capture
   command with `--path C:/.../YumeTemplate`.

Empirical case 2026-10-15: all 5 path-scoped rules used `globs:`. That
cost about 11k tokens on each turn. 14 of 42 skills had a fault: no
frontmatter, YAML that did not parse, or a ` #96` in the text. YAML read
` #96` as a comment and cut the description.

Usage:
    python3 tools/validators/validate_claude_config.py [--strict]
"""

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
DESC_MIN, DESC_MAX = 30, 300
FORK_LABELS = ("**Arguments.**", "**Output.**", "**Return.**")


def _frontmatter(text: str):
    """Return (dict, error). dict is None when there is no frontmatter."""
    if not text.startswith("---\n"):
        return None, None
    end = text.find("\n---\n", 4)
    if end < 0:
        return None, "frontmatter has no closing ---"
    try:
        data = yaml.safe_load(text[4:end]) or {}
    except yaml.YAMLError as e:
        return None, f"YAML error: {str(e).splitlines()[0]}"
    if not isinstance(data, dict):
        return None, "frontmatter is not a mapping"
    return data, None


def _check_fork_contract(where: str, text: str) -> list[str]:
    head = "\n## Inputs and outputs\n"
    if head not in text:
        return [f"{where}: `context: fork` needs a `## Inputs and outputs` section (ADR 0082)"]
    body = text.split(head, 1)[1].split("\n## ", 1)[0]
    return [f"{where}: § Inputs and outputs has no {label}"
            for label in FORK_LABELS if label not in body]


def check_skills() -> list[str]:
    issues: list[str] = []
    for d in sorted((ROOT / ".claude" / "skills").iterdir()):
        f = d / "SKILL.md"
        if not d.is_dir() or not f.exists():
            continue
        text = f.read_text(encoding="utf-8")
        fm, err = _frontmatter(text)
        where = f"skills/{d.name}"
        if err:
            issues.append(f"{where}: {err}")
            continue
        if fm is None:
            issues.append(f"{where}: no frontmatter, so the skill has no description")
            continue
        if fm.get("name") != d.name:
            issues.append(f"{where}: name is {fm.get('name')!r}, expected {d.name!r}")
        desc = str(fm.get("description") or "").strip()
        if not (DESC_MIN <= len(desc) <= DESC_MAX):
            issues.append(f"{where}: description is {len(desc)} chars "
                          f"(need {DESC_MIN}-{DESC_MAX})")
        if fm.get("context") == "fork":
            issues += _check_fork_contract(where, text)
    return issues


def check_rules() -> list[str]:
    issues: list[str] = []
    for f in sorted((ROOT / ".claude" / "rules").glob("*.md")):
        fm, err = _frontmatter(f.read_text(encoding="utf-8"))
        where = f"rules/{f.name}"
        if err:
            issues.append(f"{where}: {err}")
        elif fm is not None:
            if "globs" in fm:
                issues.append(f"{where}: uses `globs:` (ignored by Claude Code) "
                              "— use a `paths:` list")
            if "paths" in fm and not isinstance(fm["paths"], list):
                issues.append(f"{where}: `paths:` must be a YAML list")
    return issues


# `--path` followed by anything but `.`: a quoted variable, a placeholder,
# a Windows or /mnt path.
ABSOLUTE_PATH = re.compile(r"--path\s+(?!\.(\s|$|\\))[\"'$<A-Za-z/~]")


def check_godot_path() -> list[str]:
    files = sorted((ROOT / ".claude" / "skills").glob("*/SKILL.md"))
    files += sorted((ROOT / ".claude" / "rules").glob("*.md")) + [ROOT / "CLAUDE.md"]
    issues: list[str] = []
    for f in files:
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if ABSOLUTE_PATH.search(line):
                issues.append(f"{f.relative_to(ROOT)}:{n}: absolute Godot `--path`. Use "
                              "`cd \"$TEMPLATE_DST\"` and `--path .`, or ./scripts/play.sh")
    return issues


def main() -> int:
    strict = "--strict" in sys.argv
    issues = check_skills() + check_rules() + check_godot_path()
    for i in issues:
        print(f"  [claude_config] {i}")
    if not issues:
        print("[ok] .claude config")
        return 0
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main())
