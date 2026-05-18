#!/usr/bin/env python3
"""validate_animate_scope.py — gate `visual.animate` + `visual.rig_type`
authoring per ADR 0053.

Fails (strict mode exits 1) when:
  - `visual.animate: true` declared without `visual.rig_type`.
  - `visual.rig_type` declared without `visual.animate: true`
    (avoids accidental no-ops).
  - `visual.rig_type` not in the allowed set.

Warns (non-strict, prints + exits 0) when:
  - `visual.animate: true` with no `visual.animation_state_rules` AND
    no `clip_alias` (mesh will animate but engine never drives state-
    switching).
  - `visual.rig_type: "others"` — Tripo's fallback rig. Budget for a
    wasted $0.10 prerigcheck call per entity.

Empirical case: ADR 0053 (2026-05-18) introduces the animation
pipeline. Before this validator, an author could write `animate:
true` and the pipeline would have no rig_type to send → API rejects
the rig task → wasted $0.10 prerigcheck spend per entity.
"""

import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent.parent
DATA_ROOT = ROOT / "godot" / "data"

ALLOWED_RIG_TYPES = (
    "biped", "quadruped", "hexapod", "octopod",
    "avian", "serpentine", "aquatic", "others",
)


def check_game(game_dir: Path, strict: bool) -> int:
    fails: list[str] = []
    warns: list[str] = []
    for jf in sorted((game_dir / "entities").rglob("*.json")):
        try:
            doc = json.loads(jf.read_text(encoding="utf-8"))
        except Exception:
            continue
        for d in doc.get("definitions", []):
            if not isinstance(d, dict):
                continue
            visual = d.get("visual") or {}
            if not isinstance(visual, dict):
                continue
            animate = bool(visual.get("animate", False))
            rig_type = visual.get("rig_type", None)
            did = d.get("id", "?")

            if animate and not rig_type:
                fails.append(
                    f"  {did:25s}  visual.animate=true but visual.rig_type "
                    f"is missing. Add rig_type from {ALLOWED_RIG_TYPES}."
                )
                continue
            if rig_type and not animate:
                fails.append(
                    f"  {did:25s}  visual.rig_type={rig_type!r} declared "
                    f"but visual.animate is false/absent. Either set "
                    f"animate=true or remove rig_type."
                )
                continue
            if rig_type and rig_type not in ALLOWED_RIG_TYPES:
                fails.append(
                    f"  {did:25s}  visual.rig_type={rig_type!r} not in "
                    f"{ALLOWED_RIG_TYPES}."
                )
                continue

            # Warnings (non-fatal)
            if animate:
                has_rules = bool(visual.get("animation_state_rules"))
                has_alias = bool(visual.get("clip_alias"))
                if not has_rules and not has_alias:
                    warns.append(
                        f"  {did:25s}  visual.animate=true but neither "
                        f"animation_state_rules nor clip_alias is set. "
                        f"Mesh will animate but engine won't drive state."
                    )
                if rig_type == "others":
                    warns.append(
                        f"  {did:25s}  visual.rig_type='others' (Tripo "
                        f"fallback) — prerigcheck may reject; budget for "
                        f"$0.10 waste per entity."
                    )

    name = game_dir.name
    if fails:
        print(f"[fail] {name} — {len(fails)} animate-scope issue(s):")
        for f in fails:
            print(f)
        if warns:
            print(f"  ({len(warns)} additional warning(s))")
        return 1 if strict else 0
    if warns:
        print(f"[warn] {name} — {len(warns)} animate-scope warning(s):")
        for w in warns:
            print(w)
        return 0
    print(f"[ok] {name} — animate-scope clean")
    return 0


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv
    if args:
        targets = [DATA_ROOT / a for a in args]
    else:
        targets = sorted(
            p for p in DATA_ROOT.iterdir() if p.is_dir() and p.name.startswith("demo_")
        )
    rc = 0
    for t in targets:
        if not t.exists():
            print(f"[skip] {t.name} (not found)")
            continue
        rc |= check_game(t, strict)
    return rc


if __name__ == "__main__":
    sys.exit(main())
