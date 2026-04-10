#!/usr/bin/env python3
"""Visual regression testing for Yume 3D captures.

Compares current auto-capture screenshots against saved baselines.
Reports: new captures, missing captures, and pixel-level differences.

Usage:
    python visual_regression.py <captures_dir> [--save-baseline] [--threshold 5.0]

Workflow:
    1. Run auto-capture in Godot → screenshots land in captures_dir
    2. First time: `--save-baseline` to save current state as reference
    3. After changes: run without flag → compares against baseline
    4. If changes are intentional: `--save-baseline` to update reference
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from datetime import datetime
from pathlib import Path


def image_hash(path: Path) -> str:
    """Fast file-level hash to detect any change."""
    import hashlib
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def pixel_diff_percent(img_a: Path, img_b: Path) -> float:
    """Compare two images pixel-by-pixel, return % of pixels that differ.

    Uses PIL if available, falls back to raw byte comparison.
    """
    try:
        from PIL import Image
        import numpy as np

        a = np.array(Image.open(img_a).convert("RGB"))
        b = np.array(Image.open(img_b).convert("RGB"))

        if a.shape != b.shape:
            return 100.0  # Different dimensions = fully different

        # Per-pixel absolute difference, mean across channels
        diff = np.abs(a.astype(float) - b.astype(float))
        # A pixel counts as "different" if mean channel diff > 10
        pixel_diffs = diff.mean(axis=2) > 10
        return float(pixel_diffs.sum()) / pixel_diffs.size * 100.0

    except ImportError:
        # Fallback: raw byte hash comparison (binary same/different)
        hash_a = image_hash(img_a)
        hash_b = image_hash(img_b)
        return 0.0 if hash_a == hash_b else 100.0


def save_baseline(captures_dir: Path, baseline_dir: Path) -> int:
    """Copy current captures as the baseline reference."""
    baseline_dir.mkdir(parents=True, exist_ok=True)

    # Clear old baseline
    for f in baseline_dir.glob("*.png"):
        f.unlink()

    count = 0
    for img in sorted(captures_dir.glob("*.png")):
        shutil.copy2(img, baseline_dir / img.name)
        count += 1

    # Save metadata
    meta = {
        "saved_at": datetime.now().isoformat(),
        "capture_count": count,
        "hashes": {
            img.name: image_hash(img)
            for img in sorted(captures_dir.glob("*.png"))
        },
    }
    (baseline_dir / "baseline_meta.json").write_text(json.dumps(meta, indent=2))

    print(f"Baseline saved: {count} captures → {baseline_dir}")
    return count


def compare(captures_dir: Path, baseline_dir: Path, threshold: float) -> dict:
    """Compare current captures against baseline. Return report."""
    current_files = {f.name for f in captures_dir.glob("*.png")}
    baseline_files = {f.name for f in baseline_dir.glob("*.png")}

    report = {
        "timestamp": datetime.now().isoformat(),
        "captures_dir": str(captures_dir),
        "baseline_dir": str(baseline_dir),
        "threshold_percent": threshold,
        "new_captures": sorted(current_files - baseline_files),
        "missing_captures": sorted(baseline_files - current_files),
        "changed": [],
        "unchanged": [],
        "total_current": len(current_files),
        "total_baseline": len(baseline_files),
    }

    # Compare shared files
    shared = sorted(current_files & baseline_files)
    for name in shared:
        current = captures_dir / name
        baseline = baseline_dir / name

        diff_pct = pixel_diff_percent(current, baseline)

        if diff_pct > threshold:
            report["changed"].append({
                "file": name,
                "diff_percent": round(diff_pct, 2),
            })
        else:
            report["unchanged"].append(name)

    return report


def print_report(report: dict) -> bool:
    """Pretty-print the comparison report. Returns True if regression detected."""
    has_regression = False

    print("\n" + "=" * 60)
    print("  VISUAL REGRESSION REPORT")
    print("=" * 60)
    print(f"  Captures: {report['total_current']}  |  Baseline: {report['total_baseline']}  |  Threshold: {report['threshold_percent']}%")
    print("-" * 60)

    if report["new_captures"]:
        print(f"\n  NEW ({len(report['new_captures'])} captures not in baseline):")
        for name in report["new_captures"]:
            print(f"    + {name}")

    if report["missing_captures"]:
        has_regression = True
        print(f"\n  MISSING ({len(report['missing_captures'])} baseline captures not found):")
        for name in report["missing_captures"]:
            print(f"    - {name}")

    if report["changed"]:
        has_regression = True
        print(f"\n  CHANGED ({len(report['changed'])} captures differ from baseline):")
        for item in report["changed"]:
            bar_len = min(int(item["diff_percent"] / 2), 40)
            bar = "█" * bar_len
            print(f"    ~ {item['file']:30s} {item['diff_percent']:6.1f}% {bar}")

    unchanged_count = len(report["unchanged"])
    print(f"\n  UNCHANGED: {unchanged_count} captures match baseline")

    print("\n" + "=" * 60)
    if has_regression:
        print("  RESULT: REGRESSION DETECTED")
        print("  Run with --save-baseline if changes are intentional.")
    else:
        print("  RESULT: ALL CLEAR — no visual regressions")
    print("=" * 60 + "\n")

    return has_regression


def main() -> None:
    parser = argparse.ArgumentParser(description="Visual regression testing for Yume captures")
    parser.add_argument("captures_dir", type=Path, help="Directory containing current captures")
    parser.add_argument("--save-baseline", action="store_true", help="Save current captures as baseline")
    parser.add_argument("--baseline-dir", type=Path, default=None, help="Baseline directory (default: captures_dir/../baseline)")
    parser.add_argument("--threshold", type=float, default=5.0, help="Pixel diff %% to count as changed (default: 5.0)")
    parser.add_argument("--json", action="store_true", help="Output report as JSON")
    args = parser.parse_args()

    captures_dir = args.captures_dir.resolve()
    if not captures_dir.exists():
        print(f"Error: captures directory not found: {captures_dir}")
        sys.exit(1)

    baseline_dir = (args.baseline_dir or captures_dir.parent / "baseline").resolve()

    if args.save_baseline:
        save_baseline(captures_dir, baseline_dir)
        sys.exit(0)

    if not baseline_dir.exists():
        print(f"No baseline found at {baseline_dir}")
        print("Run with --save-baseline first to create a reference.")
        sys.exit(1)

    report = compare(captures_dir, baseline_dir, args.threshold)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        has_regression = print_report(report)

    # Save report
    report_path = captures_dir.parent / "regression_report.json"
    report_path.write_text(json.dumps(report, indent=2))

    if has_regression:
        sys.exit(1)


if __name__ == "__main__":
    main()
