#!/usr/bin/env python3
"""
Static validator for the `list` element (ADR 0076 — query-bound repeated UI).

`list` renders one copy of its `item` template per Query match, rewriting
every `<bind>.…` string in the template for that row. Everything this
validator checks is a SILENT failure at runtime — the screen still builds,
it just shows the wrong thing:

  (1) `from` / `item` missing        → the list renders zero rows, and a
                                       screen that should show the shop's
                                       stock shows an empty box.
  (2) a mistyped bind root           → `npc.properties.name` when `bind` is
                                       "row" is NOT substituted, so the
                                       button's label is the literal string
                                       "npc.properties.name".
  (3) `<bind>.…` outside any list    → same literal-string leak, but in a
                                       hand-authored element that never had
                                       a row to bind to.
  (4) `edge_of` malformed            → `row_edge.X` silently resolves to ""
                                       and the row shows a blank column.
  (5) `limit: 0` / negative          → no cap applies at all.

Row-substitution paths are recognisable because they carry a `.properties.`
or `.state.` segment — ordinary HUD bindings are two segments (`<tag>.<field>`
or `world.<field>`), so there is no overlap and no false-positive class.

Usage:
    python3 tools/validators/validate_ui_lists.py             # warn (all demos)
    python3 tools/validators/validate_ui_lists.py <game>      # one game
    python3 tools/validators/validate_ui_lists.py --strict    # exit 1 on error

Auto-registered by run_all.py (globs validate_*.py).
"""

import json
import sys
from pathlib import Path

# Path segments that only ever appear in a list-row substitution.
ROW_MARKERS = (".properties.", ".state.")

# Keys whose values are element templates or element lists.
CHILD_KEYS = ("elements", "children", "item", "empty")


def _row_refs(node, path, out):
    """Collect (string, json_path) for every string carrying a row marker."""
    if isinstance(node, str):
        if any(m in node for m in ROW_MARKERS):
            out.append((node, path))
    elif isinstance(node, dict):
        for k, v in node.items():
            _row_refs(v, f"{path}.{k}", out)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            _row_refs(v, f"{path}[{i}]", out)


def _check_list_element(spec, path, errors):
    """Validate one `list` element and its item template."""
    bind = str(spec.get("bind", "row"))

    if not isinstance(spec.get("from"), dict):
        errors.append((path, "list has no `from` query spec — it renders zero rows."))
    if not isinstance(spec.get("item"), dict):
        errors.append((path, "list has no `item` element template — it renders zero rows."))

    if "limit" in spec:
        lim = spec["limit"]
        if not isinstance(lim, int) or isinstance(lim, bool) or lim <= 0:
            errors.append((
                f"{path}.limit",
                f"`limit` must be a positive integer (got {lim!r}); "
                f"a non-positive limit disables the cap entirely.",
            ))

    if "edge_of" in spec:
        eo = spec["edge_of"]
        if not isinstance(eo, dict):
            errors.append((f"{path}.edge_of", "`edge_of` must be a dict."))
        else:
            if not str(eo.get("relation", "")):
                errors.append((
                    f"{path}.edge_of",
                    "`edge_of` needs a `relation` naming the edge type; "
                    "without it every `%s_edge.X` resolves to \"\"." % bind,
                ))
            if ("to" in eo) == ("from" in eo):
                errors.append((
                    f"{path}.edge_of",
                    "`edge_of` needs exactly one of `to` (edge row->to) or "
                    "`from` (edge from->row); it has "
                    + ("both" if "to" in eo else "neither") + ".",
                ))

    # Every row reference inside the template must use the declared bind.
    refs = []
    for key in ("item", "empty"):
        if isinstance(spec.get(key), dict):
            _row_refs(spec[key], f"{path}.{key}", refs)
    for s, rpath in refs:
        root = s.split(".", 1)[0]
        if root != bind:
            errors.append((
                rpath,
                f"row reference \"{s}\" uses root `{root}` but this list "
                f"declares bind `{bind}` — it will NOT be substituted and "
                f"renders as that literal string.",
            ))


def _walk(node, path, errors, inside_list):
    """Recurse the UI tree, validating lists and catching stray row refs."""
    if isinstance(node, dict):
        if node.get("type") == "list":
            _check_list_element(node, path, errors)
            # The list's own subtree is validated above; descend only into
            # nested lists so a list-inside-a-list is still checked.
            for key in ("item", "empty"):
                if isinstance(node.get(key), dict):
                    _walk(node[key], f"{path}.{key}", errors, True)
            return
        for k, v in node.items():
            _walk(v, f"{path}.{k}", errors, inside_list)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            _walk(v, f"{path}[{i}]", errors, inside_list)
    elif isinstance(node, str) and not inside_list:
        if any(m in node for m in ROW_MARKERS):
            errors.append((
                path,
                f"\"{node}\" looks like a list-row reference but is not inside "
                f"a `list` element — it renders as that literal string.",
            ))


def validate_game(game_dir: Path, repo: Path):
    errors = []
    for name in ("screens.json", "hud.json"):
        f = game_dir / name
        if not f.is_file():
            continue
        try:
            doc = json.loads(f.read_text())
        except Exception as exc:
            errors.append((str(f.relative_to(repo)), f"JSON parse error: {exc}"))
            continue
        _walk(doc, f"{name}$", errors, False)
    return errors


def main() -> int:
    strict = "--strict" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    repo = Path(__file__).resolve().parent.parent.parent
    data = repo / "godot" / "data"
    if not data.is_dir():
        print(f"[validate_ui_lists] data root missing: {data}")
        return 0

    games = [data / args[0]] if args else sorted(data.glob("demo_*"))
    total = 0
    for g in games:
        if not g.is_dir():
            continue
        errs = validate_game(g, repo)
        if errs:
            total += len(errs)
            print(f"[validate_ui_lists] FAIL — {g.name}")
            for path, msg in errs:
                print(f"  {path}: {msg}")

    if total == 0:
        print(f"[validate_ui_lists] ok — {len(games)} game(s) scanned")
        return 0
    print(
        f"\n{total} list-element issue(s). Each is a SILENT runtime failure: "
        f"the screen still builds, it just shows nothing or shows the raw "
        f"binding string. See docs/adr/0076-query-bound-repeated-ui.md."
    )
    return 1 if strict else 0


if __name__ == "__main__":
    sys.exit(main())
