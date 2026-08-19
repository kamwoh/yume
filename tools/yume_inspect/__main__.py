#!/usr/bin/env python3
"""python3 -m tools.yume_inspect <game> [-o out.html] [--stats]"""
import argparse
import json
import sys
from pathlib import Path

from .graph import build
from .render import render

REPO = Path(__file__).resolve().parents[2]


def main() -> int:
    ap = argparse.ArgumentParser(prog="yume_inspect")
    ap.add_argument("game", nargs="?", default="demo_thousandgate")
    ap.add_argument("-o", "--out", default=None,
                    help="default: docs/games/<name>/blueprint.html")
    ap.add_argument("--stats", action="store_true",
                    help="print the graph summary + findings, write nothing")
    ap.add_argument("--serve", action="store_true",
                    help="live server: edit the JSON and the graph redraws")
    ap.add_argument("--port", type=int, default=8777)
    ap.add_argument("--open", action="store_true", help="with --serve, open a browser")
    a = ap.parse_args()

    if a.serve:
        from .server import serve
        serve(a.game, a.port, a.open)
        return 0

    if a.stats:
        g = build(a.game)
        print(json.dumps(g["stats"], ensure_ascii=False, indent=2))
        for f in g["findings"]:
            print("  !", f["node"], "—", f["why"])
        return 1 if g["findings"] else 0

    out = Path(a.out) if a.out else (
        REPO / "docs" / "games" / a.game.replace("demo_", "") / "blueprint.html")
    out.parent.mkdir(parents=True, exist_ok=True)
    p = render(a.game, out)
    g = build(a.game)
    print(f"{p}")
    print("  " + "  ".join(f"{k} {v}" for k, v in g["stats"].items()))
    for f in g["findings"]:
        print("  ! " + f["why"] + "  <- " + f["node"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
