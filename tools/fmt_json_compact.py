#!/usr/bin/env python3
"""fmt_json_compact.py — keep each JSON value on one line when it fits.

`json.dump` with indent 2 puts each number of `[0, 0.37, 0]` on its own
line. For this reason data/meshes.json had 7k lines, about 35k tokens for
an LLM to read. This script keeps the structure easy to scan, with one
primitive on each line, at about half the size. The script does not change
the content. It parses the output again and asserts that the data is equal.

Usage: python3 tools/fmt_json_compact.py FILE [FILE ...] [--width 110]
"""
import json
import sys
from pathlib import Path


def _fmt(v, indent: int, width: int) -> str:
    flat = json.dumps(v, ensure_ascii=False)
    if not isinstance(v, (dict, list)) or len(flat) + indent <= width or not v:
        return flat
    pad, inner = " " * indent, " " * (indent + 2)
    if isinstance(v, list):
        items = [inner + _fmt(x, indent + 2, width) for x in v]
        return "[\n" + ",\n".join(items) + "\n" + pad + "]"
    items = [f"{inner}{json.dumps(k, ensure_ascii=False)}: {_fmt(x, indent + 2, width)}"
             for k, x in v.items()]
    return "{\n" + ",\n".join(items) + "\n" + pad + "}"


def main(argv: list[str]) -> int:
    width = 110
    if "--width" in argv:
        i = argv.index("--width")
        width = int(argv[i + 1])
        del argv[i:i + 2]
    for name in argv:
        p = Path(name)
        data = json.loads(p.read_text(encoding="utf-8"))
        out = _fmt(data, 0, width) + "\n"
        assert json.loads(out) == data, f"round-trip mismatch: {p}"
        before = p.stat().st_size
        p.write_text(out, encoding="utf-8")
        print(f"{p}: {before} -> {len(out.encode())} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
