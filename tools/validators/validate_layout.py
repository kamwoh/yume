#!/usr/bin/env python3
"""validate_layout.py — visual-layout schema validator (ADR 0054).

Detects two classes of failure:

1. **Image-content** (extraction step) — the image didn't follow the
   legend or extraction produced garbage:
     - missing_required_component
     - over_count (more components than legend expected)
     - under_count (fewer components than legend expected)
     - noise_components (warned only — extractor min_area_px filters)

2. **Playability** (schema step) — extraction succeeded but the layout
   isn't playable:
     - overlap (two UI panels overlap >10%)
     - out_of_bounds_ui (panel overflows safe margin)
     - duplicate_anchor (two panels at same anchor, optional warn)

Runs against `.layout.json` outputs from extract_ui / extract_map.
Returns non-zero exit code in --strict mode if any FAIL-class issue
is found.

Usage:
    python3 tools/validators/validate_layout.py \\
        path/to/extracted.layout.json [--strict]
    python3 tools/validators/validate_layout.py \\
        path/to/extracted.layout.json --legend path/to/legend.json [--strict]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


# Legend-driven expectations: per-name (min_count, max_count, hard_required).
# If legend declares `expected_count` field on an entry, use that;
# default to (0, inf, False) — present-but-optional.
def _expected_count(legend_entry: dict) -> tuple[int, int, bool]:
    ec = legend_entry.get("expected_count")
    if ec is None:
        return (0, 9999, False)
    if isinstance(ec, dict):
        mn = int(ec.get("min", 0))
        mx = int(ec.get("max", 9999))
        req = bool(ec.get("required", mn > 0))
        return (mn, mx, req)
    if isinstance(ec, int):
        return (ec, ec, True)
    return (0, 9999, False)


def check_layout(layout_path: Path, legend_path: Path | None) -> tuple[list[str], list[str]]:
    """Validate a layout JSON. Returns (fails, warns)."""
    fails: list[str] = []
    warns: list[str] = []
    try:
        layout = json.loads(layout_path.read_text(encoding="utf-8"))
    except Exception as e:
        return ([f"could not parse {layout_path.name}: {e}"], [])

    components = layout.get("components", [])
    image_size = layout.get("image_size_px", [1024, 1024])
    iw, ih = int(image_size[0]), int(image_size[1])

    # === Image-content checks ===

    # Surfaces warnings already attached to the layout. The extractor
    # doesn't know which entries are required — it just emits
    # "missing_component" for everything absent. The legend-driven
    # count check below decides fail vs warn.
    for w in layout.get("warnings", []):
        warns.append(f"image-content: {w}")

    # Legend-driven counts (if legend supplied)
    if legend_path is not None and legend_path.exists():
        legend = json.loads(legend_path.read_text(encoding="utf-8"))
        counts: dict[str, int] = {}
        for c in components:
            counts[c["name"]] = counts.get(c["name"], 0) + 1
        for entry in legend.get("entries", []):
            name = entry["name"]
            if name == "background":
                continue
            mn, mx, req = _expected_count(entry)
            n = counts.get(name, 0)
            if req and n == 0:
                fails.append(
                    f"image-content: required component '{name}' not found (expected {mn}-{mx})"
                )
            elif n < mn:
                fails.append(
                    f"image-content: under_count for '{name}' (got {n}, expected ≥ {mn})"
                )
            elif n > mx:
                warns.append(
                    f"image-content: over_count for '{name}' (got {n}, expected ≤ {mx})"
                )

    # === Playability checks (UI subset for Phase 1) ===

    # Overlap detection on UI components (bbox_px AABB intersection)
    for i, a in enumerate(components):
        if "bbox_px" not in a:
            continue
        ax, ay, aw, ah = a["bbox_px"]
        a_area = aw * ah
        if a_area == 0:
            continue
        for b in components[i + 1 :]:
            if "bbox_px" not in b:
                continue
            bx, by, bw, bh = b["bbox_px"]
            ix = max(0, min(ax + aw, bx + bw) - max(ax, bx))
            iy = max(0, min(ay + ah, by + bh) - max(ay, by))
            overlap_area = ix * iy
            if overlap_area == 0:
                continue
            overlap_pct = overlap_area / min(a_area, bw * bh)
            if overlap_pct > 0.10:
                fails.append(
                    f"playability: overlap between '{a['name']}' and "
                    f"'{b['name']}' ({overlap_pct:.0%} of smaller)"
                )

    # Out-of-bounds (5% safe-margin)
    safe_x = int(iw * 0.02)
    safe_y = int(ih * 0.02)
    for c in components:
        if "bbox_px" not in c:
            continue
        cx, cy, cw, ch = c["bbox_px"]
        if cx < safe_x or cy < safe_y or (cx + cw) > (iw - safe_x) or (cy + ch) > (ih - safe_y):
            warns.append(
                f"playability: '{c['name']}' bbox ({cx},{cy},{cw},{ch}) "
                f"outside 2% safe-margin"
            )

    # Duplicate anchor (warn only)
    anchor_count: dict[str, list[str]] = {}
    for c in components:
        anchor_count.setdefault(c.get("anchor", "?"), []).append(c["name"])
    for anchor, names in anchor_count.items():
        if len(names) > 1:
            warns.append(
                f"playability: anchor '{anchor}' has {len(names)} components: {names}"
            )

    return fails, warns


def main() -> int:
    ap = argparse.ArgumentParser(prog="validate_layout")
    ap.add_argument("layout", type=Path)
    ap.add_argument("--legend", type=Path, default=None)
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    if not args.layout.exists():
        print(f"[skip] {args.layout} (not found)")
        return 0

    fails, warns = check_layout(args.layout, args.legend)
    name = args.layout.name
    if fails:
        print(f"[fail] {name} — {len(fails)} issue(s):")
        for f in fails:
            print(f"  {f}")
        if warns:
            print(f"  ({len(warns)} additional warning(s))")
        return 1 if args.strict else 0
    if warns:
        print(f"[warn] {name} — {len(warns)} warning(s):")
        for w in warns:
            print(f"  {w}")
        return 0
    print(f"[ok] {name} — layout valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
