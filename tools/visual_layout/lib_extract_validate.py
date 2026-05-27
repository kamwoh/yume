"""lib_extract_validate.py — Post-extraction validation pass for
stage-5 of the text-to-world pipeline (task #139).

Reads the extracted.json output of lib_extract_dispatch.dispatch_extraction
+ the original class_catalog.json (with expected_count + intent_type
per class) and produces a verdict:

  - Per-class count drift vs expected
  - Out-of-world-bounds instances
  - Pairwise overlap density (warn when >X% of instances overlap any
    other instance)
  - Missing classes (object_placement class with no instances)
  - Strategy-origin breakdown (lib_exact_match / lib_alias_match /
    default_with_override)

Verdict tiers: pass / warn / fail.
  pass — all checks green, ready for stage 6 (asset prompts).
  warn — drift or overlaps within tolerance; pipeline can continue
         but flag for review.
  fail — missing classes or out-of-bounds; pipeline should stop and
         re-run extraction (often a strategy mis-config).

Pure stdlib + math.
"""
from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any


DEFAULT_COUNT_TOLERANCE_PCT = 50.0
DEFAULT_OVERLAP_THRESHOLD_M = 0.5
DEFAULT_OVERLAP_MAX_PCT = 10.0


def _instance_radius(inst: dict) -> float:
    """Approximate footprint radius for overlap test. Uses
    scale[0] + scale[2] (X+Z extents) for boxes/cylinders/spheres."""
    scale = inst.get("scale", [1.0, 1.0, 1.0])
    return 0.5 * max(0.1, math.hypot(float(scale[0]), float(scale[2])))


def _check_bounds(
    instances: list[dict],
    world_size_m: tuple[float, float],
) -> list[dict]:
    """Flag instances whose position is outside [-W/2, +W/2]."""
    wx_m, wz_m = world_size_m
    half_x = wx_m * 0.5
    half_z = wz_m * 0.5
    out = []
    for inst in instances:
        x, _y, z = inst.get("position", [0, 0, 0])
        if abs(x) > half_x + 0.01 or abs(z) > half_z + 0.01:
            out.append({
                "id": inst["id"], "class": inst["class"],
                "position": [x, _y, z],
                "reason": "out_of_world_bounds",
            })
    return out


def _check_overlaps(
    instances: list[dict],
    threshold_m: float,
) -> tuple[int, list[tuple[str, str]]]:
    """Naive O(N^2) overlap test. Returns (overlap_count,
    sample_pairs). For N > 2000 the O(N^2) is heavy; caller should
    cap. Bucket-grid optimization deferred to a future pass."""
    pairs: list[tuple[str, str]] = []
    count = 0
    if len(instances) > 2000:
        return -1, []  # skipped — caller can show 'N/A'
    radii = [_instance_radius(inst) for inst in instances]
    pos = [tuple(inst.get("position", [0, 0, 0])) for inst in instances]
    overlap_set: set[str] = set()
    for i in range(len(instances)):
        xi, _yi, zi = pos[i]
        ri = radii[i]
        for j in range(i + 1, len(instances)):
            xj, _yj, zj = pos[j]
            rj = radii[j]
            d = math.hypot(xi - xj, zi - zj)
            slack = (ri + rj) - threshold_m
            if d < slack:
                count += 1
                overlap_set.add(instances[i]["id"])
                overlap_set.add(instances[j]["id"])
                if len(pairs) < 8:
                    pairs.append((instances[i]["id"], instances[j]["id"]))
    return count, pairs


def _per_class_counts(
    instances: list[dict],
    catalog: dict,
    count_tolerance_pct: float,
) -> dict[str, dict]:
    """Compare per-class counts to catalog's expected_count."""
    actual: dict[str, int] = {}
    for inst in instances:
        actual[inst["class"]] = actual.get(inst["class"], 0) + 1

    report: dict[str, dict] = {}
    for c in catalog.get("classes", []):
        if c.get("intent_type") != "object_placement":
            continue
        name = c["name"]
        expected = c.get("expected_count")
        n = actual.get(name, 0)
        entry: dict[str, Any] = {
            "actual": n,
            "expected": expected,
            "strategy_origin": c.get("strategy", {}).get(
                "strategy_origin", "unknown"
            ),
        }
        if expected is None or expected == 0:
            entry["verdict"] = "ok" if n > 0 else "missing"
        else:
            drift_pct = 100.0 * (n - expected) / expected if expected else 0.0
            entry["drift_pct"] = round(drift_pct, 1)
            if n == 0:
                entry["verdict"] = "missing"
            elif abs(drift_pct) > count_tolerance_pct:
                entry["verdict"] = "drift"
            else:
                entry["verdict"] = "ok"
        report[name] = entry
    return report


def validate(
    *,
    extracted: dict,
    catalog: dict,
    world_size_m: tuple[float, float] | None = None,
    count_tolerance_pct: float = DEFAULT_COUNT_TOLERANCE_PCT,
    overlap_threshold_m: float = DEFAULT_OVERLAP_THRESHOLD_M,
    overlap_max_pct: float = DEFAULT_OVERLAP_MAX_PCT,
) -> dict:
    """Run the full validation pass. Returns a report dict.

    extracted: the dict written by dispatch_extraction's caller
               (must include 'instances' + 'world_size_meters').
    catalog:   the class_catalog.json dict.
    """
    instances = extracted.get("instances", [])
    if world_size_m is None:
        wsm = extracted.get("world_size_meters", [80.0, 80.0])
        world_size_m = (float(wsm[0]), float(wsm[1]))

    per_class = _per_class_counts(instances, catalog, count_tolerance_pct)
    oob = _check_bounds(instances, world_size_m)
    overlap_count, overlap_pairs = _check_overlaps(
        instances, overlap_threshold_m
    )

    n_total = len(instances)
    overlap_pct = (
        100.0 * overlap_count / max(1, n_total) if overlap_count >= 0 else -1
    )

    # Strategy-origin breakdown
    origin_counts: dict[str, int] = {}
    for c in catalog.get("classes", []):
        if c.get("intent_type") != "object_placement":
            continue
        origin = c.get("strategy", {}).get("strategy_origin", "unknown")
        origin_counts[origin] = origin_counts.get(origin, 0) + 1

    # Verdict
    missing_classes = [n for n, e in per_class.items()
                       if e["verdict"] == "missing"]
    drift_classes = [n for n, e in per_class.items()
                     if e["verdict"] == "drift"]
    has_fail = bool(missing_classes) or bool(oob) or (
        overlap_pct >= 0 and overlap_pct > overlap_max_pct * 2
    )
    has_warn = bool(drift_classes) or (
        overlap_pct >= 0 and overlap_pct > overlap_max_pct
    )
    verdict = "fail" if has_fail else ("warn" if has_warn else "pass")

    return {
        "verdict": verdict,
        "n_instances": n_total,
        "world_size_meters": list(world_size_m),
        "per_class": per_class,
        "missing_classes": missing_classes,
        "drift_classes": drift_classes,
        "out_of_bounds": oob,
        "overlap": {
            "count": overlap_count,
            "pct": round(overlap_pct, 2) if overlap_count >= 0 else None,
            "threshold_m": overlap_threshold_m,
            "max_pct_allowed": overlap_max_pct,
            "sample_pairs": overlap_pairs,
            "skipped_o_n2": overlap_count < 0,
        },
        "strategy_origin_breakdown": origin_counts,
        "thresholds": {
            "count_tolerance_pct": count_tolerance_pct,
            "overlap_threshold_m": overlap_threshold_m,
            "overlap_max_pct": overlap_max_pct,
        },
    }


def format_report(report: dict) -> str:
    """Human-readable report (for stdout / log files)."""
    lines: list[str] = []
    verdict = report["verdict"]
    badge = {"pass": "PASS", "warn": "WARN", "fail": "FAIL"}[verdict]
    lines.append(f"[lib_extract_validate] verdict: {badge}")
    lines.append(f"  total instances: {report['n_instances']}")
    lines.append(f"  world size: {report['world_size_meters']} m")

    lines.append("  per-class:")
    for name, e in report["per_class"].items():
        actual = e["actual"]; expected = e.get("expected", "—")
        drift = e.get("drift_pct", None)
        origin = e.get("strategy_origin", "—")
        verdict_tag = e["verdict"]
        drift_str = f" ({drift:+.1f}%)" if drift is not None else ""
        lines.append(
            f"    {name:22s} actual={actual:<4d} expected={expected!s:<5s}"
            f"{drift_str}  [{verdict_tag}]  origin={origin}"
        )

    if report["missing_classes"]:
        lines.append(
            f"  MISSING: {report['missing_classes']}"
        )
    if report["drift_classes"]:
        lines.append(
            f"  DRIFT:   {report['drift_classes']}"
        )
    if report["out_of_bounds"]:
        lines.append(
            f"  OOB:     {len(report['out_of_bounds'])} instances"
        )

    ov = report["overlap"]
    if ov["skipped_o_n2"]:
        lines.append("  overlaps: skipped (N > 2000, O(N²) too heavy)")
    else:
        lines.append(
            f"  overlaps: {ov['count']} pairs ({ov['pct']:.2f}% — "
            f"max-allowed {ov['max_pct_allowed']}%)"
        )
        if ov["sample_pairs"]:
            for a, b in ov["sample_pairs"][:4]:
                lines.append(f"             {a} ↔ {b}")

    lines.append(
        f"  strategy-origin: {report['strategy_origin_breakdown']}"
    )
    return "\n".join(lines)


# ============================================================
# CLI
# ============================================================

if __name__ == "__main__":
    import argparse
    import sys
    parser = argparse.ArgumentParser()
    parser.add_argument("--extracted", required=True)
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--out", default=None, help="optional JSON report path")
    parser.add_argument("--count-tolerance-pct", type=float,
                        default=DEFAULT_COUNT_TOLERANCE_PCT)
    parser.add_argument("--overlap-threshold-m", type=float,
                        default=DEFAULT_OVERLAP_THRESHOLD_M)
    parser.add_argument("--overlap-max-pct", type=float,
                        default=DEFAULT_OVERLAP_MAX_PCT)
    parser.add_argument("--strict", action="store_true",
                        help="exit 1 if verdict != pass")
    args = parser.parse_args()

    extracted = json.loads(Path(args.extracted).read_text())
    catalog = json.loads(Path(args.catalog).read_text())
    report = validate(
        extracted=extracted, catalog=catalog,
        count_tolerance_pct=args.count_tolerance_pct,
        overlap_threshold_m=args.overlap_threshold_m,
        overlap_max_pct=args.overlap_max_pct,
    )
    print(format_report(report))
    if args.out:
        Path(args.out).write_text(json.dumps(report, indent=2))
        print(f"  (wrote JSON report to {args.out})")
    if args.strict and report["verdict"] != "pass":
        sys.exit(1)
