#!/usr/bin/env python3
"""
Static validator for the tick-rate contract (CLAUDE.md § "Tick rate
is the engine's heartbeat").

The engine default is `tick_seconds = 0.0167` (60Hz). A per-game
override in `scene.json` is legal, but per the contract it must be a
DELIBERATE design choice — documented inline so future readers know
WHY the demo deviates.

This validator fails when a demo's scene.json overrides tick_seconds
without a non-empty `_comment_tick` explaining the reason.

Empirical case 2026-05-16: yume-code-reviewer's first session review
flagged that sokoban (10Hz) and doomarena3d (20Hz) overrode the new
60Hz default with no inline reason. The contract was written but
not enforced; this validator closes the gap.

Usage:
    python3 tools/validate_tick_override.py             # warn (all demos)
    python3 tools/validate_tick_override.py --strict    # exit 1

Wired into scripts/play.sh as a non-blocking pre-launch check.
"""

import json
import sys
from pathlib import Path

DEFAULT_TICK = 0.0167  # 60Hz — matches Godot physics_fps default
EPSILON = 1e-4  # allow exact-match drift


def main() -> int:
    strict = "--strict" in sys.argv
    repo = Path(__file__).resolve().parent.parent.parent
    data = repo / "godot" / "data"
    if not data.is_dir():
        print(f"[validate_tick_override] data root missing: {data}")
        return 0

    issues: list[str] = []
    checked = 0
    for scene in sorted(data.glob("demo_*/scene.json")):
        checked += 1
        try:
            d = json.loads(scene.read_text())
        except Exception as exc:
            issues.append(f"{scene.relative_to(repo)}: JSON parse error: {exc}")
            continue
        if "tick_seconds" not in d:
            continue  # using engine default, fine
        ts = float(d["tick_seconds"])
        if abs(ts - DEFAULT_TICK) < EPSILON:
            continue  # matches default, no override
        # Override present — must have a documented reason
        reason = str(d.get("_comment_tick", "")).strip()
        if not reason:
            issues.append(
                f"{scene.relative_to(repo)}: tick_seconds={ts} "
                f"(override) but no `_comment_tick` field with reason. "
                f"Per CLAUDE.md § Tick rate is the engine's heartbeat, "
                f"per-game overrides need documented design intent."
            )

    if not issues:
        print(f"[validate_tick_override] ok — {checked} demo(s) scanned, all compliant")
        return 0

    print(f"[validate_tick_override] FAIL — {len(issues)} demo(s) override tick_seconds without reason:")
    for i in issues:
        print(f"  {i}")
    print(
        "\nFix: add `\"_comment_tick\": \"<one-sentence reason>\"` to the "
        "scene.json (alongside `tick_seconds`). Example reasons: "
        "\"turn-based, slow tick saves cycles\", \"shooter, 50ms input "
        "latency acceptable for genre\"."
    )
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main())
