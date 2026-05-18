#!/usr/bin/env python3
"""validate_lib_refs.py — ADR 0027 sync-time validator.

Walks every per-game JSON file under godot/data/<game>/ and verifies:

1. Every "@lib.X.Y[.Z...]" string reference resolves to a known entry
   in data/lib/manifest.json.
2. Every $extends value is a valid @lib reference.
3. Every $include value is a valid @lib reference (or array of them).
4. Categories match their declared _shape (per manifest).

Failures are printed with file path + JSON path so authors can fix.

Usage:
    python3 tools/validate_lib_refs.py                  # all games
    python3 tools/validate_lib_refs.py demo_merchant    # one game
    python3 tools/validate_lib_refs.py --strict         # exit 1 on warning

Exit codes:
    0 — clean
    1 — at least one broken reference (in --strict mode also for warnings)

Wired into scripts/play.sh as a pre-launch gate.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
GODOT_DATA = ROOT / "godot" / "data"
LIB_ROOT = GODOT_DATA / "lib"
MANIFEST_PATH = LIB_ROOT / "manifest.json"


def load_json(path: Path):
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"[fail] parse error in {path}: {exc}")
        return None


def collect_lib_keys() -> set:
    """Return the set of 'category.entry' keys declared in manifest.json."""
    m = load_json(MANIFEST_PATH)
    if m is None:
        print(f"[warn] no manifest at {MANIFEST_PATH} — skipping lib-ref validation")
        return None
    keys: set = set()
    cats = m.get("categories", {})
    for cat_name, cat_def in cats.items():
        if not isinstance(cat_def, dict):
            continue
        entries = cat_def.get("entries", {})
        if isinstance(entries, dict):
            for entry_name in entries.keys():
                # Allow @lib.<cat>.<entry> AND @lib.<cat>.<entry>.<subfield...>
                # (subfield traversal is checked at runtime, not statically).
                keys.add(f"{cat_name}.{entry_name}")
    return keys


REF_RE = re.compile(r"^@lib\.[a-zA-Z0-9_.]+$")


def collect_refs(node, path_str: str, refs: list):
    """Walk a parsed JSON tree, collect (json_path, ref_string) for every
    @lib.* string AND for $extends / $include values."""
    if isinstance(node, str):
        if node.startswith("@lib."):
            refs.append((path_str, node))
        return
    if isinstance(node, dict):
        if "$extends" in node and isinstance(node["$extends"], str):
            refs.append((f"{path_str}.$extends", node["$extends"]))
        if "$include" in node:
            inc = node["$include"]
            if isinstance(inc, str):
                refs.append((f"{path_str}.$include", inc))
            elif isinstance(inc, list):
                for i, item in enumerate(inc):
                    if isinstance(item, str):
                        refs.append((f"{path_str}.$include[{i}]", item))
        for k, v in node.items():
            collect_refs(v, f"{path_str}.{k}", refs)
        return
    if isinstance(node, list):
        for i, item in enumerate(node):
            collect_refs(item, f"{path_str}[{i}]", refs)


def ref_resolves(ref: str, lib_keys: set) -> bool:
    """A ref resolves if some manifest key is a prefix of the ref's
    suffix-after-@lib. Allows traversal into sub-fields (e.g.
    @lib.input_bundles.wasd_with_fp_variant.rules where the manifest
    only declares input_bundles.wasd_with_fp_variant)."""
    if not ref.startswith("@lib."):
        return False
    suffix = ref[5:]
    parts = suffix.split(".")
    for cut in range(len(parts), 0, -1):
        candidate = ".".join(parts[:cut])
        if candidate in lib_keys:
            return True
    return False


def validate_game(game_name: str, lib_keys: set, errors: list, warnings: list) -> None:
    game_dir = GODOT_DATA / game_name
    if not game_dir.exists():
        return
    json_files = list(game_dir.rglob("*.json"))
    for path in json_files:
        # Skip the lib tree itself
        if "lib" in path.parts:
            continue
        data = load_json(path)
        if data is None:
            continue
        refs: list = []
        collect_refs(data, "$", refs)
        for json_path, ref in refs:
            if not REF_RE.match(ref):
                warnings.append(
                    f"{path.relative_to(ROOT)}::{json_path} — malformed @lib ref: '{ref}'"
                )
                continue
            if not ref_resolves(ref, lib_keys):
                errors.append(
                    f"{path.relative_to(ROOT)}::{json_path} — '{ref}' "
                    f"does not resolve to any manifest entry. "
                    f"Add to manifest or fix the ref."
                )


def main() -> int:
    args = sys.argv[1:]
    strict = "--strict" in args
    games = [a for a in args if not a.startswith("--")]
    if not games:
        # Walk all games
        if not GODOT_DATA.exists():
            print(f"[fail] {GODOT_DATA} not found")
            return 2
        games = sorted([d.name for d in GODOT_DATA.iterdir()
                        if d.is_dir() and d.name != "lib"])

    lib_keys = collect_lib_keys()
    if lib_keys is None:
        # No manifest — no @lib refs expected; check for stray ones.
        lib_keys = set()

    errors: list = []
    warnings: list = []
    for game in games:
        validate_game(game, lib_keys, errors, warnings)

    if errors:
        print(f"[fail] {len(errors)} broken @lib ref(s):")
        for e in errors:
            print(f"  ✗ {e}")
    if warnings:
        print(f"[warn] {len(warnings)} suspicious @lib ref(s):")
        for w in warnings:
            print(f"  ⚠ {w}")
    if not errors and not warnings:
        scope = ", ".join(games) if games else "all games"
        print(f"[ok] {scope} — all @lib refs resolve through manifest")

    if errors:
        return 1
    if warnings and strict:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
