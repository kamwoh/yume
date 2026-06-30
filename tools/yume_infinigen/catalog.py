"""Factory catalog (ADR 0074, Phase B5) — Yume-side, no bpy/infinigen import.

Greps the Infinigen source for factory class definitions so the driver can
validate a `--factory` name + list options BEFORE shelling into the slow
Blender env. (The authoritative spawnable check still happens in
gen_asset's resolver, which rejects part factories that aren't
AssetFactory subclasses — this is just a cheap typo gate + browser.)
"""
from __future__ import annotations

import re
from functools import lru_cache
from pathlib import Path

_FACTORY_RE = re.compile(r"^class\s+(\w+Factory)\b")

# Name fragments of INTERNAL part factories (assembled by a parent), so we
# can warn before a wasted Blender launch. Not exhaustive — the resolver is
# the real arbiter.
_PART_HINTS = (
    "Base", "Claw", "Leg", "Cap", "Stem", "Antenna", "Eye", "Fin", "Tail",
    "Body", "Part", "Growth", "Swarm", "School", "Branch",
)


@lru_cache(maxsize=4)
def list_factories(repo: str) -> dict:
    """Return {FactoryName: category} for every factory class under
    infinigen/assets/objects. Cached per repo path."""
    root = Path(repo) / "infinigen" / "assets" / "objects"
    out: dict[str, str] = {}
    if not root.is_dir():
        return out
    for py in root.rglob("*.py"):
        cat = py.relative_to(root).parts[0]
        try:
            for ln in py.read_text(errors="ignore").splitlines():
                m = _FACTORY_RE.match(ln)
                if m:
                    out.setdefault(m.group(1), cat)
        except OSError:
            continue
    return out


def looks_like_part(name: str) -> bool:
    return any(h in name for h in _PART_HINTS)


def format_catalog(repo: str) -> str:
    facs = list_factories(repo)
    by_cat: dict[str, list] = {}
    for name, cat in sorted(facs.items()):
        if looks_like_part(name):
            continue  # hide internal parts from the browse list
        by_cat.setdefault(cat, []).append(name)
    lines = [f"{len(facs)} factory classes ({sum(len(v) for v in by_cat.values())} standalone) under infinigen/assets/objects:"]
    for cat in sorted(by_cat):
        lines.append(f"  {cat:16s} {', '.join(by_cat[cat])}")
    return "\n".join(lines)
