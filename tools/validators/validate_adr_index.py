#!/usr/bin/env python3
"""validate_adr_index.py — keep the ADR index and ADR status true.

This validator is repo-wide. It takes no game argument. It checks three things:

1. Each `docs/adr/NNNN-*.md` has a row in `docs/adr/README.md`.
2. The status in that row starts with the same word as the `_Status:`
   line of the ADR file (accepted, proposed, superseded, ...).
3. Engine code (`godot/scripts/engine/**/*.gd`, tests excluded) cites
   only accepted ADRs. A citation of a proposed ADR means that code
   shipped while the decision record says it did not. A citation of a
   superseded ADR is a stale comment.

Empirical case 2026-10-16: ADRs 0068-0081 had no index rows. Six ADRs
(0029, 0036, 0043, 0075, 0079, 0080) said "proposed" while demos used
their code. entity.gd still described fields of the primitives that
ADR 0085 deleted.

Usage:
    python3 tools/validators/validate_adr_index.py [--strict]
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADR_DIR = ROOT / "docs" / "adr"
ENGINE = ROOT / "godot" / "scripts" / "engine"
CITE = re.compile(r"\bADRs? ?(\d{4})\b")


def status_word(text: str) -> str:
    """The first word of a status: accepted, proposed, superseded, ..."""
    text = re.sub(r"[*_`]", "", text).split("→")[-1]
    word = text.strip().lower().split(" ")[0].rstrip(".,;:(")
    return "accepted" if word.startswith(("accept", "approved")) else word


def adr_statuses() -> dict[str, str]:
    out = {}
    for f in sorted(ADR_DIR.glob("[0-9][0-9][0-9][0-9]-*.md")):
        m = re.search(r"^_?\**Status:?\**:?\s*(.+)$", f.read_text(encoding="utf-8"), re.M | re.I)
        out[f.name[:4]] = status_word(m.group(1)) if m else ""
    return out


def index_rows() -> dict[str, str]:
    rows = {}
    for line in (ADR_DIR / "README.md").read_text(encoding="utf-8").splitlines():
        m = re.match(r"\|\s*\[?(\d{4})(?:\]\(\./\d{4}-[^)]+\))?\s*\|[^|]*\|\s*([^|]+)\|", line)
        if m:
            rows[m.group(1)] = status_word(m.group(2))
    return rows


def check() -> list[str]:
    issues: list[str] = []
    statuses = adr_statuses()
    rows = index_rows()
    for n, st in statuses.items():
        if not st:
            issues.append(f"ADR {n}: no `_Status:` line")
        if n not in rows:
            issues.append(f"ADR {n}: no row in docs/adr/README.md")
        elif rows[n] != st:
            issues.append(f"ADR {n}: the index says `{rows[n]}`, the file says `{st}`")
    for f in sorted(ENGINE.rglob("*.gd")):
        if "tests" in f.parts:
            continue
        for i, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            for n in CITE.findall(line):
                st = statuses.get(n)
                if st and st != "accepted":
                    issues.append(f"{f.relative_to(ROOT)}:{i}: cites ADR {n}, which is `{st}`")
    return issues


def main() -> int:
    strict = "--strict" in sys.argv
    issues = check()
    for i in issues:
        print(f"  [adr_index] {i}")
    if not issues:
        print("[ok] ADR index")
        return 0
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main())
