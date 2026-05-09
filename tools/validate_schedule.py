#!/usr/bin/env python3
"""validate_schedule.py — ADR 0029 sync-time validator.

Walks every per-game `entities.json` and `entities/*.json` under
godot/data/<game>/ and verifies that any entity def carrying a
`schedule` block is well-formed:

1. `schedule.slots` exists and is a non-empty array.
2. Every slot has `start` (number), `end` (number), `verb` (string).
3. `fallback_verb_by_tendency` (when present) is a string array.
4. `binds_to` (when present) parses as `<tag>.<field>` or `world.<field>`.
5. Slot intervals don't overlap (warning, not error — runtime
   uses first-match — but author should know).
6. Slot intervals collectively cover [0, wraps_at) OR `default_verb`
   is set (warning if neither — gaps fall through to "idle").
7. `location_tag` strings reference at least one entity tag in the
   same game (warning — flags typos).

Usage:
    python3 tools/validate_schedule.py                  # all games
    python3 tools/validate_schedule.py demo_aldenmere   # one game
    python3 tools/validate_schedule.py --strict         # exit 1 on warn

Exit codes:
    0 — clean
    1 — at least one broken schedule (in --strict mode: also warnings)
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GODOT_DATA = ROOT / "godot" / "data"


def load_json(path: Path):
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"[fail] parse error in {path}: {exc}")
        return None


def collect_tags_for_game(game_dir: Path) -> set:
    """Return all tags declared on entity defs in this game (for
    location_tag typo check). Walks entities.json + entities/*.json."""
    tags: set = set()
    for path in iter_entity_files(game_dir):
        data = load_json(path)
        if not isinstance(data, dict):
            continue
        for d in data.get("definitions", []) or []:
            if not isinstance(d, dict):
                continue
            for t in d.get("tags", []) or []:
                tags.add(str(t))
    return tags


def iter_entity_files(game_dir: Path):
    """Yield every entities.json file in this game (root + per-level
    + entities/ subfolder + chunks/)."""
    candidates = [
        game_dir / "entities.json",
    ]
    ent_subdir = game_dir / "entities"
    if ent_subdir.is_dir():
        candidates.extend(sorted(ent_subdir.glob("*.json")))
    levels_dir = game_dir / "levels"
    if levels_dir.is_dir():
        for lvl in sorted(levels_dir.iterdir()):
            if lvl.is_dir():
                candidates.append(lvl / "entities.json")
    chunks_dir = game_dir / "chunks"
    if chunks_dir.is_dir():
        for ch in sorted(chunks_dir.iterdir()):
            if ch.is_dir():
                candidates.append(ch / "entities.json")
    for c in candidates:
        if c.exists():
            yield c


def validate_slot(slot, slot_idx: int) -> list:
    """Returns list of (severity, message) tuples for one slot."""
    errs = []
    if not isinstance(slot, dict):
        errs.append(("error", f"slot[{slot_idx}]: not a dict"))
        return errs
    for key in ("start", "end", "verb"):
        if key not in slot:
            errs.append(("error", f"slot[{slot_idx}]: missing required key '{key}'"))
    if "start" in slot and not isinstance(slot["start"], (int, float)):
        errs.append(("error", f"slot[{slot_idx}].start: must be number"))
    if "end" in slot and not isinstance(slot["end"], (int, float)):
        errs.append(("error", f"slot[{slot_idx}].end: must be number"))
    if "verb" in slot and not isinstance(slot["verb"], str):
        errs.append(("error", f"slot[{slot_idx}].verb: must be string"))
    fb = slot.get("fallback_verb_by_tendency")
    if fb is not None:
        if not isinstance(fb, list):
            errs.append(("error",
                f"slot[{slot_idx}].fallback_verb_by_tendency: must be array of strings"))
        else:
            for j, v in enumerate(fb):
                if not isinstance(v, str):
                    errs.append(("error",
                        f"slot[{slot_idx}].fallback_verb_by_tendency[{j}]: not string"))
    return errs


def check_overlaps(slots: list, wraps_at: float) -> list:
    """Return list of (severity, msg) for any overlapping intervals.
    Wrap-around aware. Warning-level only — runtime uses first-match."""
    out = []
    intervals = []
    for i, s in enumerate(slots):
        if not isinstance(s, dict):
            continue
        start = s.get("start")
        end = s.get("end")
        if not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
            continue
        # Normalize wrap-around to two intervals for overlap math.
        if start > end:
            intervals.append((i, float(start), float(wraps_at)))
            intervals.append((i, 0.0, float(end)))
        else:
            intervals.append((i, float(start), float(end)))
    for a in range(len(intervals)):
        i_a, s_a, e_a = intervals[a]
        for b in range(a + 1, len(intervals)):
            i_b, s_b, e_b = intervals[b]
            if i_a == i_b:
                continue
            if s_a < e_b and s_b < e_a:
                out.append(("warning",
                    f"slots[{i_a}] and slots[{i_b}] intervals overlap "
                    f"({s_a}-{e_a}, {s_b}-{e_b}); first-match wins"))
    return out


def check_coverage(slots: list, wraps_at: float, default_verb: str) -> list:
    """Warn if intervals don't cover [0, wraps_at) AND default_verb is empty."""
    out = []
    if default_verb and default_verb != "idle":
        return out  # author opted in to a default
    # Build a sorted timeline of (point, +1/-1) deltas; check for any gap.
    points = []
    for s in slots:
        if not isinstance(s, dict):
            continue
        start = s.get("start")
        end = s.get("end")
        if not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
            continue
        if start > end:
            points.append((float(start), +1))
            points.append((float(wraps_at), -1))
            points.append((0.0, +1))
            points.append((float(end), -1))
        else:
            points.append((float(start), +1))
            points.append((float(end), -1))
    if not points:
        return out
    points.sort()
    cover = 0
    last = 0.0
    for x, delta in points:
        if cover == 0 and x > last + 0.001:
            out.append(("warning",
                f"slot coverage gap from {last} to {x}; default_verb (currently '{default_verb}') will fill"))
        cover += delta
        last = x
    if cover == 0 and last < wraps_at - 0.001:
        out.append(("warning",
            f"slot coverage gap from {last} to {wraps_at}; default_verb='{default_verb}' will fill"))
    return out


def validate_schedule(entity_id: str, schedule: dict, all_tags: set) -> list:
    """Returns list of (severity, message) tuples for one schedule block."""
    errs = []
    if not isinstance(schedule, dict):
        return [("error", f"{entity_id}: schedule must be a dict")]
    slots = schedule.get("slots")
    if not isinstance(slots, list) or len(slots) == 0:
        errs.append(("error", f"{entity_id}: schedule.slots must be non-empty array"))
        return errs
    # Validate each slot
    for i, s in enumerate(slots):
        for sev, msg in validate_slot(s, i):
            errs.append((sev, f"{entity_id}: {msg}"))
    # binds_to format check
    binds_to = schedule.get("binds_to")
    if binds_to is not None:
        if not isinstance(binds_to, str):
            errs.append(("error", f"{entity_id}: binds_to must be string"))
        elif "." not in binds_to:
            errs.append(("warning",
                f"{entity_id}: binds_to='{binds_to}' has no dot — "
                "expected '<tag>.<field>' or 'world.<field>'"))
    # Overlap + coverage checks (warnings only)
    wraps_at = float(schedule.get("wraps_at", 24.0))
    default_verb = str(schedule.get("default_verb", ""))
    errs.extend(("warning", f"{entity_id}: " + m)
                for sev, m in check_overlaps(slots, wraps_at) if sev == "warning")
    errs.extend(("warning", f"{entity_id}: " + m)
                for sev, m in check_coverage(slots, wraps_at, default_verb) if sev == "warning")
    # Location tag typo check
    for i, s in enumerate(slots):
        if not isinstance(s, dict):
            continue
        loc = s.get("location_tag")
        if isinstance(loc, str) and loc != "" and loc not in all_tags:
            errs.append(("warning",
                f"{entity_id}: slot[{i}].location_tag='{loc}' "
                "matches no entity tag in this game (typo?)"))
    return errs


def validate_game(game_dir: Path, strict: bool = False) -> int:
    """Validate one game's schedule blocks. Returns 0 (clean) or 1."""
    if not game_dir.is_dir():
        print(f"[skip] {game_dir} — not a directory")
        return 0
    all_tags = collect_tags_for_game(game_dir)
    found_schedule = False
    n_errors = 0
    n_warnings = 0
    for path in iter_entity_files(game_dir):
        data = load_json(path)
        if not isinstance(data, dict):
            continue
        for d in data.get("definitions", []) or []:
            if not isinstance(d, dict):
                continue
            schedule = d.get("schedule")
            if schedule is None:
                continue
            found_schedule = True
            entity_id = str(d.get("id", "<unknown>"))
            for sev, msg in validate_schedule(entity_id, schedule, all_tags):
                marker = "[fail]" if sev == "error" else "[warn]"
                print(f"{marker} {path.relative_to(ROOT)}: {msg}")
                if sev == "error":
                    n_errors += 1
                else:
                    n_warnings += 1
    if not found_schedule:
        return 0   # no schedules to validate; clean by definition
    if n_errors > 0:
        print(f"[validate_schedule] {game_dir.name}: "
              f"{n_errors} error(s), {n_warnings} warning(s)")
        return 1
    if strict and n_warnings > 0:
        print(f"[validate_schedule] {game_dir.name}: "
              f"{n_warnings} warning(s) under --strict")
        return 1
    if n_warnings > 0:
        print(f"[validate_schedule] {game_dir.name}: "
              f"clean (errors=0, {n_warnings} warning(s))")
    else:
        print(f"[validate_schedule] {game_dir.name}: clean")
    return 0


def main(argv: list) -> int:
    strict = "--strict" in argv
    args = [a for a in argv if not a.startswith("--")]
    if not args:
        # all games
        rc = 0
        for game in sorted(GODOT_DATA.iterdir()):
            if not game.is_dir():
                continue
            if game.name == "lib":
                continue
            rc = max(rc, validate_game(game, strict=strict))
        return rc
    # specific games by name
    rc = 0
    for name in args:
        rc = max(rc, validate_game(GODOT_DATA / name, strict=strict))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
