"""validate_camera_freeze.py — sync-time gate for camera-mode freeze policy.

Per yume-tech-director Invariant #10 (2026-05-20 extension): every
`_camera_*` function in `camera_director.gd` that captures the mouse
MUST honor screen_freeze_world / overlay_freeze_world by releasing the
mouse and early-returning when either is set.

Without this, ESC opens the pause menu but the camera function re-
captures the cursor every frame → pause-menu buttons become
un-clickable. Empirical case 2026-05-20: `_camera_free_cam` shipped
without the guard; user couldn't click pause-menu items while in
free-cam mode.

This validator scans `godot/scripts/engine/ui/widgets/camera_director.gd`
for functions named `_camera_*` that call `Input.set_mouse_mode(...
MOUSE_MODE_CAPTURED ...)` and verifies each also references
`freeze_world` within its body. Functions that don't capture the
mouse are exempt.

Usage:
    python3 tools/validators/validate_camera_freeze.py <game> [--strict]

(Game arg is unused — the check is engine-scoped, not per-game. Arg
exists for run_all.py uniformity.)
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CAMERA_DIRECTOR = ROOT / "godot" / "scripts" / "engine" / "ui" / "widgets" / "camera_director.gd"


def _split_functions(text: str) -> list[tuple[str, str]]:
    """Return [(func_name, body_text), ...] for every top-level func."""
    out: list[tuple[str, str]] = []
    # Match `func name(...) [-> type]:` at line start; body extends until
    # the NEXT `func` declaration at line start.
    pat = re.compile(r"^(func|static func)\s+(\w+)\s*\(", re.MULTILINE)
    matches = list(pat.finditer(text))
    for i, m in enumerate(matches):
        name = m.group(2)
        start = m.start()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        body = text[start:end]
        out.append((name, body))
    return out


def validate(strict: bool = False) -> int:
    if not CAMERA_DIRECTOR.exists():
        # Project may not have camera_director.gd (non-3d games). Skip silently.
        print(f"[validate_camera_freeze] camera_director.gd not found — skipping")
        return 0

    text = CAMERA_DIRECTOR.read_text(encoding="utf-8")
    functions = _split_functions(text)

    offenders: list[tuple[str, str]] = []
    for name, body in functions:
        if not name.startswith("_camera_"):
            continue
        if "MOUSE_MODE_CAPTURED" not in body:
            # Doesn't capture the mouse — guard not required.
            continue
        if "freeze_world" not in body:
            offenders.append((name, "captures mouse without freeze_world guard"))

    if not offenders:
        print(f"[ok] camera_director.gd — every mouse-capturing camera mode "
              f"honors freeze_world ({sum(1 for n, _ in functions if n.startswith('_camera_'))} "
              f"camera-mode function(s) inspected)")
        return 0

    header = "ERROR" if strict else "WARN "
    print(f"[{header}] camera_director.gd — {len(offenders)} camera-mode "
          f"function(s) missing freeze_world guard:", file=sys.stderr)
    for name, reason in offenders:
        print(f"  ✗ {name}() — {reason}", file=sys.stderr)
        print(f"    Add the freeze_world early-return pattern at function top.", file=sys.stderr)
        print(f"    See yume-tech-director SKILL.md Invariant #10 § camera-mode extension.", file=sys.stderr)
    print(f"\n    Empirical case 2026-05-20: _camera_free_cam shipped without",
          file=sys.stderr)
    print(f"    the guard; ESC opened pause menu but cursor stayed captured",
          file=sys.stderr)
    print(f"    → buttons un-clickable. User caught it post-merge.",
          file=sys.stderr)
    return 1 if strict else 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="validate_camera_freeze")
    ap.add_argument("game", nargs="?", default="(engine-scoped)",
                    help="Unused — included for run_all.py uniformity")
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()
    return validate(strict=args.strict)


if __name__ == "__main__":
    sys.exit(main())
