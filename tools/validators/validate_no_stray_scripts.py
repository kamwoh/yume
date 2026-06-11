#!/usr/bin/env python3
"""
Static validator: no .gd files under godot/data/.

Yume's contract (per .claude/rules/data-demo.md): `godot/data/` is
content-only. JSON entities, rules, scene config, screens, etc. NO
GDScript. The engine lives at `godot/scripts/engine/`.

Why this matters: Godot's `class_name` registry is global across the
project. A stray .gd under data/ with `class_name X` SHADOWS the real
engine class — same name wins last-loaded order, and dispatch silently
routes to whichever copy registered first. The user-visible symptom
is "this feature suddenly stopped working" with no error: the dispatch
match-arm in the stale version doesn't exist for the new effect type,
so the effect is a no-op.

Empirical case 2026-05-15: a stale `data/demo_aldenmere/effect_apply.gd`
(left over from May 10, never deleted because `cp -r src/. dst/` doesn't
remove orphans) shadowed `scripts/engine/core/effect_apply.gd`. The
stale copy predated `velocity_add_relative` dispatch. Result: every
WASD input fired correctly through query + flush, then EffectApply.apply
hit the stale `match type:` with no `velocity_add_relative` arm, so
the player NEVER moved in Aldenmere. Visible symptom user described
as "drift / pulls sideways" because NPC motion (velocity_set, which
the stale version DID handle) kept working — only the player's
camera-relative velocity_add_relative was dropped.

Per `godot/data/demo_*/` being gitignored, source is clean and the
stale file lived ONLY in the sync target (the YumeTemplate worktree).
But the same hazard applies to any tracked content folder.

Usage:
    python3 tools/validate_no_stray_scripts.py             # warn
    python3 tools/validate_no_stray_scripts.py --strict    # exit 1

Wired into scripts/play.sh's pre-launch checks. Agents/CI use --strict.
"""

import sys
from pathlib import Path


def scan(roots: list[Path]) -> list[Path]:
    out: list[Path] = []
    for r in roots:
        if r.is_dir():
            out.extend(sorted(r.rglob("*.gd")))
    return out


def main() -> int:
    strict = "--strict" in sys.argv
    repo = Path(__file__).resolve().parent.parent.parent
    # Source tree + sync target. Source is usually clean (data/demo_*/ is
    # gitignored so nothing tracks there), but the sync target accumulates
    # orphans across `cp -r` runs — that's where the empirical bug lived.
    import os
    sync_target = os.environ.get("YUME_TEMPLATE_DST", os.path.expanduser("~/.yume/YumeTemplate"))
    roots = [
        repo / "godot" / "data",
        Path(sync_target) / "data",
    ]

    stray = scan(roots)
    if not stray:
        print("[validate_no_stray_scripts] ok — no .gd under data/")
        return 0

    print(f"[validate_no_stray_scripts] FAIL — {len(stray)} stray .gd file(s) under data/:")
    for p in stray:
        try:
            rel = p.relative_to(repo)
        except ValueError:
            rel = p
        print(f"  {rel}")
    print("\nFix: delete these files. data/ is content-only (see .claude/rules/data-demo.md).")
    print("After delete, rebuild Godot's class cache: `godot --path <template> --headless --import`")
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main())
